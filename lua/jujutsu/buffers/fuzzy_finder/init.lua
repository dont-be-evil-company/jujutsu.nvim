local M = {}

---@param needle string
---@param haystack string
---@return number|nil
local function score_match(needle, haystack)
  if needle == "" then return 0 end
  needle, haystack = needle:lower(), haystack:lower()
  local ni, score, prev = 1, 0, 0
  for hi = 1, #haystack do
    if haystack:sub(hi, hi) == needle:sub(ni, ni) then
      score = score + 1
      if prev + 1 == hi then score = score + 2 end
      if hi == 1 or haystack:sub(hi - 1, hi - 1):match("[%s%p_/]") then score = score + 3 end
      prev = hi
      ni = ni + 1
      if ni > #needle then return score - (#haystack - #needle) * 0.01 end
    end
  end
  return nil
end

---@class FuzzyFinderOpts
---@field prompt? string
---@field entries string[]|{text:string}[]
---@field allow_multi? boolean
---@field allow_free_text? boolean
---@field on_select fun(item: string|string[]|nil)
---@field on_open? fun(win: integer, bufnr: integer)
---@field on_refresh? fun() optional callback after forge cache refresh

---@param opts FuzzyFinderOpts
function M.open(opts)
  local cursor_mod = require("jujutsu.ui.cursor")
  cursor_mod.push_typing({ insert_capable = true })
  local prompt = opts.prompt or "select"
  local allow_multi = opts.allow_multi or false
  local allow_free_text = opts.allow_free_text or false
  local entries = {}
  for _, e in ipairs(opts.entries or {}) do
    table.insert(entries, type(e) == "table" and (e.text or tostring(e[1])) or tostring(e))
  end

  local query, cursor = "", 1
  local selected = {}
  local filtered = {}
  local closed = false
  local result_set = false
  local result_value = nil ---@type string|string[]|nil
  local redrawing = false
  local ns = vim.api.nvim_create_namespace("jujutsu-finder")
  local augroup = vim.api.nvim_create_augroup("JujutsuFinder" .. tostring(vim.uv.hrtime()), { clear = true })

  local height = math.max(10, math.floor(vim.o.lines * 0.4))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].copilot_enabled = false
  vim.bo[bufnr].complete = ""
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "jujutsu-finder"

  local host = require("jujutsu.ui.host")
  if host.active() then
    height = math.min(height, math.max(4, math.floor(vim.api.nvim_win_get_height(host.win()) * 0.45)))
  end
  local win = vim.api.nvim_open_win(bufnr, true, host.bottom_config(height, { title = " " .. prompt .. " " }))
  host.track_bottom(win, height)
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  if type(opts.on_open) == "function" then opts.on_open(win, bufnr) end

  local function teardown()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    pcall(vim.cmd, "stopinsert")
    vim.schedule(function()
      if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
      cursor_mod.pop_typing({ insert_capable = true })
      opts.on_select(result_value)
    end)
  end

  local function finish(result)
    if result_set then return end
    result_set = true
    result_value = result
    teardown()
  end

  local function abort() finish(nil) end

  local function refilter()
    filtered = {}
    for _, text in ipairs(entries) do
      local s = score_match(query, text)
      if s then table.insert(filtered, { text = text, score = s }) end
    end
    table.sort(filtered, function(a, b) return a.score > b.score end)
    cursor = math.max(1, math.min(cursor, math.max(#filtered, 1)))
  end

  local function current() return filtered[cursor] and filtered[cursor].text end

  local function redraw()
    if closed or not vim.api.nvim_buf_is_valid(bufnr) then return end
    redrawing = true
    refilter()

    local col = 2 + #query
    if vim.api.nvim_win_is_valid(win) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
      if ok and cur and cur[1] == 1 then col = math.max(2, cur[2]) end
    end

    local lines = { "> " .. query }
    local max_results = math.max(1, height - 2)
    local shown = 0
    for i, item in ipairs(filtered) do
      if shown >= max_results then break end
      local mark = selected[item.text] and "*" or " "
      local cur = i == cursor and ">" or " "
      table.insert(lines, string.format("%s%s %s", cur, mark, item.text))
      shown = shown + 1
    end
    if #filtered == 0 then
      table.insert(lines, allow_free_text and "  (no matches - Enter to use typed text)" or "  (no matches)")
    end

    local hint = allow_multi and "<cr> confirm  <tab> toggle  <c-n>/<c-p> move  <esc> abort  <c-l> refresh"
      or "<cr> confirm  <c-n>/<c-p> move  <esc> abort  <c-l> refresh"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_lines = { { { "  " .. hint, "Comment" } } },
      virt_lines_above = false,
    })

    if vim.api.nvim_win_is_valid(win) then
      local max_col = 2 + #query
      pcall(vim.api.nvim_win_set_cursor, win, { 1, math.min(col, max_col) })
    end
    redrawing = false
  end

  local function sync_query_from_buf()
    if closed or redrawing then return end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Collapse multi-line paste into the query line.
    local raw = lines[1] or ""
    if #lines > 1 then
      for i = 2, #lines do
        -- Ignore result lines we rendered (start with ">/ " markers or spaces).
        local l = lines[i]
        if l and not l:match("^[> ][* ] ") and not l:match("^%s*%(no matches") then raw = raw .. l end
      end
    end
    local next_query = raw:gsub("^>%s?", ""):gsub("[\r\n]", "")
    if next_query ~= query then
      query = next_query
      cursor = 1
    end
    redraw()
  end

  local function do_select()
    if allow_multi then
      local list = {}
      for t, on in pairs(selected) do
        if on then table.insert(list, t) end
      end
      if #list == 0 and current() then list = { current() } end
      finish(#list > 0 and list or nil)
    else
      local value = current()
      if not value and allow_free_text then
        value = query:match("^%s*(.-)%s*$")
        if value == "" then value = nil end
      end
      finish(value)
    end
  end

  local function move(delta)
    if #filtered == 0 then return end
    cursor = math.max(1, math.min(cursor + delta, #filtered))
    redraw()
  end

  local map = function(modes, key, fn)
    vim.keymap.set(modes, key, fn, { buffer = bufnr, silent = true, noremap = true, nowait = true })
  end

  map({ "n", "i" }, "<cr>", function() vim.schedule(do_select) end)
  map({ "n", "i" }, "<c-c>", function() vim.schedule(abort) end)
  map({ "n", "i" }, "<esc>", function() vim.schedule(abort) end)
  map("n", "q", function() vim.schedule(abort) end)
  map({ "n", "i" }, "<c-n>", function() move(1) end)
  map({ "n", "i" }, "<down>", function() move(1) end)
  map({ "n", "i" }, "<c-p>", function() move(-1) end)
  map({ "n", "i" }, "<up>", function() move(-1) end)
  map({ "n", "i" }, "<tab>", function()
    if allow_multi and current() then
      selected[current()] = not selected[current()]
      cursor = math.min(cursor + 1, math.max(#filtered, 1))
      redraw()
    elseif current() then
      query = current()
      redraw()
    end
  end)
  -- Keep insert-mode <C-r> free for register paste; use <C-l> for cache refresh.
  map({ "n", "i" }, "<c-l>", function()
    local cache = require("jujutsu.forge.cache")
    if type(opts.on_refresh) == "function" then
      cache.with_refresh(function() opts.on_refresh() end)
      redraw()
    else
      cache.clear()
      require("jujutsu.notify").info("Forge cache cleared")
    end
  end)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = sync_query_from_buf,
  })

  -- Keep the cursor on the query line while typing.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      if closed or redrawing or not vim.api.nvim_win_is_valid(win) then return end
      local cur = vim.api.nvim_win_get_cursor(win)
      if cur[1] ~= 1 then
        local col = math.min(cur[2], 2 + #query)
        pcall(vim.api.nvim_win_set_cursor, win, { 1, math.max(2, col) })
      elseif cur[2] < 2 then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 })
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if not result_set then abort() end
    end,
  })

  redraw()
  -- Closing another UI (e.g. Diff popup) before open can leave focus elsewhere.
  local function reclaim()
    if closed then return end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
      pcall(vim.api.nvim_set_current_win, win)
      local mode = vim.api.nvim_get_mode().mode
      if not mode:match("^[iR]") then pcall(vim.cmd, "startinsert") end
      pcall(vim.cmd, "redraw")
    end
  end
  reclaim()
  for _, delay in ipairs({ 10, 30, 60, 100, 180, 300, 500, 800, 1200 }) do
    vim.defer_fn(reclaim, delay)
  end
  vim.cmd("startinsert!")
end

---@param opts { prompt?: string, entries: any[], allow_multi?: boolean, allow_free_text?: boolean }
---@return string|string[]|nil
function M.pick(opts)
  local async = require("jujutsu.async")
  local co = coroutine.running()
  if co then
    return async.await(
      function(cb)
        M.open({
          prompt = opts.prompt,
          entries = opts.entries,
          allow_multi = opts.allow_multi,
          allow_free_text = opts.allow_free_text,
          on_select = cb,
        })
      end
    )
  end
  local result, done = nil, false
  M.open({
    prompt = opts.prompt,
    entries = opts.entries,
    allow_multi = opts.allow_multi,
    allow_free_text = opts.allow_free_text,
    on_select = function(item)
      result = item
      done = true
    end,
  })
  vim.wait(1e9, function() return done end, 40)
  return result
end

return M
