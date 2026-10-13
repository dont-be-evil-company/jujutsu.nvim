local notify = require("jujutsu.notify")

local M = {}

---Reclaim focus for a float that opens after picker/input teardown (status/issue
---panel often steals WinEnter). Time-boxed like finder.ensure_picker_focus.
---@param target_win integer
---@param filetype string
local function ensure_float_focus(target_win, filetype)
  local deadline = vim.uv.now() + 1500
  local group = vim.api.nvim_create_augroup("JujutsuCommentFocus", { clear = true })

  local function focus()
    if vim.uv.now() > deadline then
      pcall(vim.api.nvim_del_augroup_by_name, "JujutsuCommentFocus")
      return false
    end
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      if vim.api.nvim_get_current_win() ~= target_win then pcall(vim.api.nvim_set_current_win, target_win) end
      local mode = vim.api.nvim_get_mode().mode
      if not mode:match("^[iR]") then pcall(vim.cmd, "startinsert") end
      pcall(vim.cmd, "redraw")
      return true
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == filetype then
          pcall(vim.api.nvim_set_current_win, win)
          local mode = vim.api.nvim_get_mode().mode
          if not mode:match("^[iR]") then pcall(vim.cmd, "startinsert") end
          pcall(vim.cmd, "redraw")
          return true
        end
      end
    end
    return false
  end

  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "WinNew", "WinLeave" }, {
    group = group,
    callback = function() vim.schedule(focus) end,
  })
  local delay = 0
  while delay <= 1500 do
    if delay == 0 then
      vim.schedule(focus)
    else
      vim.defer_fn(focus, delay)
    end
    delay = delay == 0 and 10 or (delay < 100 and delay + 20 or delay + 50)
  end
  vim.defer_fn(function() pcall(vim.api.nvim_del_augroup_by_name, "JujutsuCommentFocus") end, 1600)
end

---@param title string
---@param opts? { initial?: string, allow_empty?: boolean }
---@param on_done fun(body: string|nil) nil means aborted
function M.prompt_comment(title, opts, on_done)
  if type(opts) == "function" then
    on_done = opts
    opts = {}
  end
  opts = opts or {}
  local initial = opts.initial or ""
  local allow_empty = opts.allow_empty == true
  local origin_win = vim.api.nvim_get_current_win()
  local cursor_mod = require("jujutsu.ui.cursor")
  cursor_mod.push_typing({ insert_capable = true })

  local buf = vim.api.nvim_create_buf(false, true)
  -- acwrite so :w triggers BufWriteCmd; hide (not wipe) so float teardown cannot
  -- cascade into DiffView splits. Avoid plain "markdown" filetype - preview
  -- plugins often open a split on FileType and collapse the review layout.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = true
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, string.format("jujutsu://review-comment/%d", buf))
  vim.bo[buf].filetype = "jujutsu-review-comment"
  pcall(vim.treesitter.start, buf, "markdown")

  local body_lines = initial ~= "" and vim.split(initial, "\n", { plain = true }) or { "" }
  local lines = vim.list_extend(vim.deepcopy(body_lines), {
    "",
    "-- :w save  <C-c> abort",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Prefer a taller float when editing existing (long) bodies.
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(math.max(16, #body_lines + 4), math.floor(vim.o.lines * 0.7))
  local win = require("jujutsu.ui.host").open_float(buf, {
    width = width,
    height = height,
    title = " " .. title .. " ",
    zindex = 200,
  })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  -- Stop any leftover finder focus reclaim from fighting for the previous window.
  pcall(vim.api.nvim_del_augroup_by_name, "JujutsuPickerFocus")
  ensure_float_focus(win, "jujutsu-review-comment")
  vim.cmd("startinsert")

  local done = false

  local function get_body()
    if not vim.api.nvim_buf_is_valid(buf) then return "" end
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body_acc = {}
    for _, line in ipairs(all) do
      if not line:match("^%-%- :w ") then table.insert(body_acc, line) end
    end
    while #body_acc > 0 and body_acc[#body_acc]:match("^%s*$") do
      table.remove(body_acc)
    end
    return table.concat(body_acc, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local function cleanup_and_finish(body)
    if done then return end
    done = true
    pcall(vim.api.nvim_del_augroup_by_name, "JujutsuCommentFocus")
    -- Never destroy the float/buffer inside BufWriteCmd's call stack - that can
    -- close an underlying DiffView split. Defer cleanup + callback.
    vim.schedule(function()
      pcall(vim.cmd, "stopinsert")
      cursor_mod.pop_typing({ insert_capable = true })
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      if origin_win and vim.api.nvim_win_is_valid(origin_win) then pcall(vim.api.nvim_set_current_win, origin_win) end
      on_done(body)
    end)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local body = get_body()
      vim.bo[buf].modified = false
      if body == "" and not allow_empty then
        cleanup_and_finish(nil)
      else
        cleanup_and_finish(body)
      end
    end,
  })

  -- Abort if the float is dismissed without going through our keymaps (:q, etc.).
  -- `done` is already set for intentional closes, so this is a no-op then.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() cleanup_and_finish(nil) end,
  })

  local map_opts = { buffer = buf, silent = true, noremap = true }
  vim.keymap.set({ "n", "i" }, "<C-c>", function() cleanup_and_finish(nil) end, map_opts)
  vim.keymap.set("n", "q", function() cleanup_and_finish(nil) end, map_opts)
end

---@param events string[]
---@param on_done fun(event: string|nil)
function M.pick_submit_event(events, on_done)
  vim.schedule(function()
    require("jujutsu.async").void(function()
      local finder = require("jujutsu.finder")
      local entries = {}
      local map = {}
      for _, e in ipairs(events) do
        local label = e
        if e == "COMMENT" then
          label = "Comment"
        elseif e == "APPROVE" then
          label = "Approve"
        elseif e == "REQUEST_CHANGES" then
          label = "Request changes"
        elseif e == "DRAFT" then
          label = "Draft (GitHub pending)"
        end
        table.insert(entries, label)
        map[label] = e
      end
      local choice = finder.pick({ prompt = "Submit review as", entries = entries })
      if not choice then
        on_done(nil)
        return
      end
      on_done(map[tostring(choice)])
    end)
  end)
end

---@param text string
function M.help(text)
  local lines = vim.split(text, "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(60, math.floor(vim.o.columns * 0.6))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  local win = require("jujutsu.ui.host").open_float(buf, {
    width = width,
    height = height,
    title = " Review help ",
    zindex = 90,
  })
  local close = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<esc>", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "?", close, { buffer = buf, silent = true })
end

function M.copy_markdown(md)
  vim.fn.setreg("+", md)
  vim.fn.setreg('"', md)
  notify.info("Review copied to clipboard")
end

return M
