local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local hunks_mod = require("jujutsu.diff.hunks")
local watcher = require("jujutsu.watcher")

local M = {}

local SIGN_GROUP = "jujutsu_signs"
local NS = vim.api.nvim_create_namespace("jujutsu_signs")

---@class SignsBufState
---@field root string
---@field path string
---@field attached boolean

---@type table<integer, SignsBufState>
local buffers = {}

---@type integer|nil
local autocmd_group = nil

---@type table<string, boolean>
local watched_roots = {}

---One in-flight diff per repo. Per-buffer `jj diff` calls snapshot the whole
---working copy, and each snapshot writes `.jj`, which the watcher treats as a
---new edit. Overlapping those calls (they used to run inside `vim.wait`, which
---pumps timers) spawned a jj process per open buffer and froze the UI.
---@class SignsRootRefresh
---@field timer uv.uv_timer_t|nil
---@field seq integer
---@field running boolean
---@field again boolean
---@field want_snapshot boolean
---@field snapshotting boolean
---@field ignore_watcher_until integer

---@type table<string, SignsRootRefresh>
local root_refresh = {}

local REFRESH_DEBOUNCE_MS = 80
local DIFF_CHUNK = 40
local DIFF_TIMEOUT_MS = 120000
-- Longer than the fs watcher debounce so a diff's own `.jj` writes cannot
-- schedule the next diff after this one has already finished.
local WATCHER_QUIET_MS = 400

local SIGN_HL = {
  add = "JujutsuSignsAdd",
  change = "JujutsuSignsChange",
  delete = "JujutsuSignsDelete",
  topdelete = "JujutsuSignsDelete",
  changedelete = "JujutsuSignsChange",
}

local function signs_cfg() return config.values.signs or {} end

local function define_signs()
  local cfg = signs_cfg()
  for name, hl in pairs(SIGN_HL) do
    local entry = cfg[name] or {}
    vim.fn.sign_define("JujutsuSign" .. name, {
      text = entry.text or "",
      texthl = hl,
      numhl = "",
      linehl = "",
    })
  end
end

---@param abs string
---@param root string
---@return string|nil
local function relpath(abs, root)
  abs = vim.fn.fnamemodify(abs, ":p")
  root = vim.fn.fnamemodify(root, ":p")
  if root:sub(-1) ~= "/" then root = root .. "/" end
  if abs:sub(1, #root) ~= root then return nil end
  return abs:sub(#root + 1)
end

---@param bufnr integer
---@return string|nil root
---@return string|nil path
local function buffer_repo_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil, nil end
  local abs = vim.fn.fnamemodify(name, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")
  local root = cli.find_workspace_root(dir)
  if not root then return nil, nil end
  local path = relpath(abs, root)
  return root, path
end

---Map unified hunks to gitsigns-style per-line sign kinds on the new file.
---@param hunks DiffHunk[]
---@return table<integer, string> line -> add|change|delete|topdelete|changedelete
local function signs_from_hunks(hunks)
  ---@type table<integer, string>
  local result = {}

  for _, hunk in ipairs(hunks) do
    local new_lnum = hunk.new_start
    local i = 1
    local lines = hunk.lines or {}

    while i <= #lines do
      local prefix = lines[i]:sub(1, 1)
      if prefix == "-" or prefix == "+" then
        local ndel, nadd = 0, 0
        while i <= #lines and lines[i]:sub(1, 1) == "-" do
          ndel = ndel + 1
          i = i + 1
        end
        while i <= #lines and lines[i]:sub(1, 1) == "+" do
          nadd = nadd + 1
          i = i + 1
        end

        if nadd == 0 and ndel > 0 then
          if new_lnum <= 0 or hunk.new_count == 0 then
            result[1] = "topdelete"
          else
            -- Show deletion on the following line in the new file
            result[new_lnum] = result[new_lnum] == "add" and "changedelete" or "delete"
          end
        elseif ndel == 0 and nadd > 0 then
          for _ = 1, nadd do
            result[new_lnum] = "add"
            new_lnum = new_lnum + 1
          end
        else
          local paired = math.min(ndel, nadd)
          for j = 1, paired do
            if j == paired and ndel > nadd then
              result[new_lnum] = "changedelete"
            else
              result[new_lnum] = "change"
            end
            new_lnum = new_lnum + 1
          end
          for _ = paired + 1, nadd do
            result[new_lnum] = "add"
            new_lnum = new_lnum + 1
          end
        end
      elseif prefix == " " then
        new_lnum = new_lnum + 1
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  return result
end

---@param bufnr integer
local function clear_buf(bufnr)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

---@param bufnr integer
---@param line_signs table<integer, string>
local function place_buf(bufnr, line_signs)
  clear_buf(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for lnum, kind in pairs(line_signs) do
    if type(lnum) == "number" and lnum >= 1 and lnum <= line_count then
      vim.fn.sign_place(0, SIGN_GROUP, "JujutsuSign" .. kind, bufnr, {
        lnum = lnum,
        priority = 10,
      })
    end
  end
end

---@param root string
---@return SignsRootRefresh
local function root_state(root)
  local st = root_refresh[root]
  if not st then
    st = {
      seq = 0,
      running = false,
      again = false,
      want_snapshot = false,
      snapshotting = false,
      ignore_watcher_until = 0,
    }
    root_refresh[root] = st
  end
  return st
end

---Match `diff --git a/<path> b/<path>` against the paths we requested.
---jj does not quote paths that contain spaces, so the `b/` side is matched
---from the known path list (longest wins).
---@param line string
---@param paths string[]
---@return string|nil
local function diff_header_path(line, paths)
  if line:sub(1, 11) ~= "diff --git " then return nil end
  local best = nil
  for _, path in ipairs(paths) do
    local suffix = " b/" .. path
    if #line >= #suffix and line:sub(-#suffix) == suffix then
      if not best or #path > #best then best = path end
    end
  end
  return best
end

---@param lines string[]
---@param paths string[]
---@return table<string, string[]>
local function group_diff(lines, paths)
  ---@type table<string, string[]>
  local grouped = {}
  local current = nil
  for _, line in ipairs(lines) do
    local path = diff_header_path(line, paths)
    if path then
      current = {}
      grouped[path] = current
    elseif current then
      current[#current + 1] = line
    end
  end
  return grouped
end

---@param root string
---@param paths string[]
---@param grouped table<string, string[]>
local function apply_diff(root, paths, grouped)
  if config.values.disable_signs then return end
  ---@type table<string, string[]>
  local wanted = {}
  for _, path in ipairs(paths) do
    wanted[path] = grouped[path] or {}
  end
  for bufnr, state in pairs(buffers) do
    local lines = state.path and wanted[state.path]
    if
      lines
      and state.attached
      and state.root == root
      and vim.api.nvim_buf_is_valid(bufnr)
      and vim.bo[bufnr].buftype == ""
    then
      if #lines == 0 then
        clear_buf(bufnr)
      else
        place_buf(bufnr, signs_from_hunks(hunks_mod.parse_hunks(lines)))
      end
    end
  end
end

---@param fn fun()
---@param on_done fun(err: string|nil)
local function protected_void(fn, on_done)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, value = coroutine.resume(co, ...)
    if not ok then
      on_done(tostring(value))
      return
    end
    if coroutine.status(co) ~= "dead" then
      if type(value) == "function" then
        value(vim.schedule_wrap(step))
      else
        on_done("async protocol error")
      end
      return
    end
    on_done(nil)
  end
  step()
end

---@param root string
---@param snapshot boolean
local schedule_root

---@param st SignsRootRefresh
local function quiet_watcher(st) st.ignore_watcher_until = vim.uv.now() + WATCHER_QUIET_MS end

---@param root string
local function finish_root_refresh(root)
  local st = root_refresh[root]
  if not st then return end
  st.running = false
  st.snapshotting = false
  quiet_watcher(st)
  if config.values.disable_signs then return end
  if st.want_snapshot then
    st.again = false
    st.want_snapshot = false
    schedule_root(root, true)
    return
  end
  -- One non-snapshot follow-up. Watcher events from `--ignore-working-copy`
  -- itself must not chain or a lock file inside `.jj` refreshes forever.
  if st.again then
    st.again = false
    schedule_root(root, false)
  end
end

---@param root string
---@param snapshot boolean
local function run_root_refresh(root, snapshot)
  local st = root_state(root)
  if st.running then
    st.again = true
    if snapshot then st.want_snapshot = true end
    return
  end
  if config.values.disable_signs then return end

  ---@type string[]
  local paths = {}
  ---@type table<string, boolean>
  local seen = {}
  for bufnr, state in pairs(buffers) do
    if state.attached and state.root == root and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" then
      local buf_root, path = buffer_repo_path(bufnr)
      if not buf_root or buf_root ~= root or not path or path == "" then
        clear_buf(bufnr)
      else
        state.root = buf_root
        state.path = path
        if not seen[path] then
          seen[path] = true
          paths[#paths + 1] = path
        end
      end
    end
  end

  if #paths == 0 then
    st.again = false
    st.want_snapshot = false
    return
  end

  st.running = true
  st.snapshotting = snapshot == true
  st.again = false
  st.want_snapshot = false
  quiet_watcher(st)

  protected_void(function()
    local index = 1
    local first = true
    while index <= #paths do
      ---@type string[]
      local chunk = {}
      for _ = 1, DIFF_CHUNK do
        if index > #paths then break end
        chunk[#chunk + 1] = paths[index]
        index = index + 1
      end

      -- The first command snapshots once. Later chunks and watcher wakeups read
      -- that snapshot (`--ignore-working-copy`) so they do not write `.jj` and
      -- schedule themselves again.
      local builder = cli.diff.git
      if not (snapshot and first) then builder = builder.ignore_working_copy() end
      first = false
      local res = builder.paths(unpack(chunk)).call_async({
        cwd = root,
        hidden = true,
        timeout = DIFF_TIMEOUT_MS,
        on_error = function() return false end,
      })
      if not res or res.code ~= 0 then break end
      apply_diff(root, chunk, group_diff(res.stdout or {}, chunk))
    end
  end, function() finish_root_refresh(root) end)
end

---@param root string
---@param snapshot boolean true when the working copy may be ahead of the last snapshot
function schedule_root(root, snapshot)
  local st = root_state(root)
  if snapshot then st.want_snapshot = true end
  if st.running then
    st.again = true
    return
  end

  st.seq = st.seq + 1
  local seq = st.seq
  if not st.timer then
    st.timer = vim.uv.new_timer()
    if not st.timer then
      local snap = st.want_snapshot == true
      st.want_snapshot = false
      run_root_refresh(root, snap)
      return
    end
  end
  st.timer:stop()
  st.timer:start(REFRESH_DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      local live = root_refresh[root]
      if not live or live.seq ~= seq or live.running then return end
      local snap = live.want_snapshot == true
      live.want_snapshot = false
      run_root_refresh(root, snap)
    end)
  end)
end

---@param bufnr integer
local function schedule_refresh(bufnr)
  local state = buffers[bufnr]
  if not state then return end
  schedule_root(state.root, true)
end

---@param root string
local function ensure_root_watcher(root)
  if watched_roots[root] then return end
  watched_roots[root] = true
  -- `.jj` already moved, so read that snapshot. Events raised by our own
  -- `--ignore-working-copy` diff are ignored so the watcher cannot restoke itself.
  watcher.start(root, function()
    local st = root_refresh[root]
    if st and vim.uv.now() < st.ignore_watcher_until then
      if st.snapshotting then st.again = true end
      return
    end
    if st and st.running and not st.snapshotting then return end
    schedule_root(root, false)
  end, "signs:" .. root)
end

---@param bufnr integer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if config.values.disable_signs then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.bo[bufnr].buftype ~= "" then return end

  local root, path = buffer_repo_path(bufnr)
  if not root or not path then return end

  local state = buffers[bufnr]
  if state and state.attached then
    schedule_refresh(bufnr)
    return
  end

  buffers[bufnr] = {
    root = root,
    path = path,
    attached = true,
  }
  ensure_root_watcher(root)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = autocmd_group,
    callback = function() M.detach(bufnr) end,
  })

  schedule_refresh(bufnr)
end

---@param bufnr integer
function M.detach(bufnr)
  local state = buffers[bufnr]
  if not state then return end
  clear_buf(bufnr)
  buffers[bufnr] = nil
end

function M.refresh_all()
  if config.values.disable_signs then
    for bufnr in pairs(buffers) do
      clear_buf(bufnr)
    end
    return
  end
  ---@type table<string, boolean>
  local roots = {}
  for bufnr, state in pairs(buffers) do
    if state.attached and vim.api.nvim_buf_is_valid(bufnr) then roots[state.root] = true end
  end
  for root in pairs(roots) do
    schedule_root(root, true)
  end
end

function M.setup()
  define_signs()

  if autocmd_group then
    vim.api.nvim_clear_autocmds({ group = autocmd_group })
  else
    autocmd_group = vim.api.nvim_create_augroup("JujutsuSigns", { clear = true })
  end

  if config.values.disable_signs then
    for bufnr in pairs(buffers) do
      M.detach(bufnr)
    end
    for root in pairs(watched_roots) do
      watcher.stop("signs:" .. root)
    end
    watched_roots = {}
    for _, st in pairs(root_refresh) do
      if st.timer then
        st.timer:stop()
        st.timer:close()
        st.timer = nil
      end
      st.running = false
      st.snapshotting = false
      st.again = false
      st.want_snapshot = false
    end
    root_refresh = {}
    return
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = autocmd_group,
    callback = function(args) M.attach(args.buf) end,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
    group = autocmd_group,
    callback = function(args)
      if buffers[args.buf] then
        schedule_refresh(args.buf)
      else
        M.attach(args.buf)
      end
    end,
  })

  -- Attach currently open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then M.attach(bufnr) end
  end
end

return M
