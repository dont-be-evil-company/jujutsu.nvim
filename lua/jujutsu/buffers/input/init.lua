local M = {}

---@class InputBufferOpts
---@field prompt? string
---@field default? string
---@field allow_empty? boolean if false, Enter on empty aborts (returns nil)
---@field placeholder? string hint shown when value is empty
---@field on_submit fun(value: string|nil) nil = aborted
---@field on_open? fun(win: integer, bufnr: integer)
---@field on_refresh? fun() optional callback after forge cache refresh

---Single-line text input float using real insert mode (paste, arrows, etc. work).
---@param opts InputBufferOpts
function M.open(opts)
  opts = opts or {}
  local cursor_mod = require("jujutsu.ui.cursor")
  cursor_mod.push_typing({ insert_capable = true })
  local prompt = opts.prompt or "input"
  local allow_empty = opts.allow_empty == true
  local placeholder = opts.placeholder or (allow_empty and "Leave empty to skip" or "Type a value")
  local closed = false
  local result_set = false
  local result_value = nil ---@type string|nil
  local ns = vim.api.nvim_create_namespace("jujutsu-input")
  local augroup = vim.api.nvim_create_augroup("JujutsuInput" .. tostring(vim.uv.hrtime()), { clear = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].copilot_enabled = false
  vim.bo[bufnr].complete = ""
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "jujutsu-input"

  local height = 4
  local host = require("jujutsu.ui.host")
  local win = vim.api.nvim_open_win(bufnr, true, host.bottom_config(height, { title = " " .. prompt .. " " }))
  host.track_bottom(win, height)
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  if type(opts.on_open) == "function" then opts.on_open(win, bufnr) end

  local function current_value()
    if not vim.api.nvim_buf_is_valid(bufnr) then return "" end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return table.concat(lines, ""):gsub("[\r\n]", "")
  end

  local function teardown(result)
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    -- Capture value before destroying the buffer if caller already decided.
    if not result_set then
      result_set = true
      result_value = result
    end
    pcall(vim.cmd, "stopinsert")
    -- Defer close so we aren't tearing down mid insert-mode keymap.
    vim.schedule(function()
      if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
      cursor_mod.pop_typing({ insert_capable = true })
      opts.on_submit(result_value)
    end)
  end

  local function refresh_hints()
    if closed or not vim.api.nvim_buf_is_valid(bufnr) then return end
    local value = current_value()
    local hint = string.format(
      "<cr> confirm  <esc>/<c-c> abort  <c-l> refresh forge cache%s",
      allow_empty and "  (empty ok)" or ""
    )
    local virt = {}
    if value == "" then table.insert(virt, { { "  " .. placeholder, "Comment" } }) end
    table.insert(virt, { { "  " .. hint, "Comment" } })
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, 0, 0, {
      virt_lines = virt,
      virt_lines_above = false,
    })
  end

  ---Keep a single physical line (paste may insert newlines).
  local function normalize_to_one_line()
    if closed or not vim.api.nvim_buf_is_valid(bufnr) then return end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines <= 1 and not ((lines[1] or ""):find("[\r\n]")) then
      refresh_hints()
      return
    end
    local value = table.concat(lines, ""):gsub("[\r\n]", "")
    local col = #value
    if vim.api.nvim_win_is_valid(win) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
      if ok and cur and cur[1] == 1 then col = math.min(cur[2], #value) end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { value })
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_cursor, win, { 1, col }) end
    refresh_hints()
  end

  local function submit()
    if closed or result_set then return end
    local trimmed = vim.trim(current_value())
    result_set = true
    if trimmed == "" then
      result_value = allow_empty and "" or nil
    else
      result_value = trimmed
    end
    teardown(result_value)
  end

  local function abort()
    if closed or result_set then return end
    result_set = true
    result_value = nil
    teardown(nil)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { opts.default or "" })
  refresh_hints()

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = normalize_to_one_line,
  })

  -- Only treat dismiss-without-submit as abort. Confirm sets result_set first so a
  -- WinClosed from our own teardown cannot overwrite the entered value with nil.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if not result_set then abort() end
    end,
  })

  local map = function(modes, key, fn)
    vim.keymap.set(modes, key, fn, { buffer = bufnr, silent = true, noremap = true, nowait = true })
  end

  map({ "n", "i" }, "<cr>", function()
    -- Schedule so insert-mode <CR> finishes before we tear down the float.
    vim.schedule(submit)
  end)
  map({ "n", "i" }, "<c-c>", function() vim.schedule(abort) end)
  map({ "n", "i" }, "<esc>", function() vim.schedule(abort) end)
  map("n", "q", function() vim.schedule(abort) end)
  -- Keep insert-mode <C-r> free for register paste (<C-r>+, <C-r>*).
  map({ "n", "i" }, "<c-l>", function()
    local cache = require("jujutsu.forge.cache")
    if type(opts.on_refresh) == "function" then
      cache.with_refresh(function() opts.on_refresh() end)
    else
      cache.clear()
      require("jujutsu.notify").info("Forge cache cleared")
    end
  end)

  local col = #(opts.default or "")
  pcall(vim.api.nvim_win_set_cursor, win, { 1, col })
  vim.cmd("startinsert!")
end

return M
