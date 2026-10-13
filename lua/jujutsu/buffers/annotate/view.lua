local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

local SEP = "\x1f"

local ANNOTATE_TEMPLATE = table.concat({
  "commit.change_id().shortest(8)",
  "commit.author().name()",
  'commit_timestamp(commit).local().format("%Y-%m-%d")',
  "line_number",
  'if(first_line_in_hunk, "1", "0")',
  "commit.description().first_line()",
  "content",
}, ' ++ "\\x1f" ++ ')

---@class AnnotateLine
---@field change_id string
---@field author string
---@field date string
---@field line_number integer
---@field first_hunk boolean
---@field description string
---@field content string

---@class AnnotateView
---@field buf Buffer
---@field win integer|nil
---@field root string
---@field path string
---@field lines AnnotateLine[]
---@field selected_change string|nil
---@field focus_line integer|nil
---@field row_source table<integer, integer>
---@field line_rows table<integer, integer>

---@param root string
---@param path string
---@param revision? string
---@return AnnotateLine[], string|nil err
function M.fetch(root, path, revision)
  local builder = cli.file_annotate.template(ANNOTATE_TEMPLATE).paths(path)
  if revision and revision ~= "" then builder = builder.revision(revision) end
  local res = builder.call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if res.code ~= 0 then
    local err = table.concat(res.stderr or {}, "\n")
    if err == "" then err = "jj file annotate failed" end
    return {}, err
  end

  ---@type AnnotateLine[]
  local lines = {}
  for _, raw in ipairs(res.stdout or {}) do
    if raw ~= "" then
      local parts = vim.split(raw, SEP, { plain = true })
      if #parts >= 7 then
        local content = table.concat(parts, SEP, 7)
        content = content:gsub("\r?\n$", "")
        lines[#lines + 1] = {
          change_id = parts[1] or "",
          author = parts[2] or "",
          date = parts[3] or "",
          line_number = tonumber(parts[4]) or (#lines + 1),
          first_hunk = parts[5] == "1",
          description = parts[6] or "",
          content = content,
        }
      end
    end
  end
  return lines, nil
end

---@param root string
---@param win integer
---@param path string
---@return AnnotateView
function M.create(root, win, path)
  local buf = Buffer.create("jujutsu://annotate/" .. path, "jujutsu-annotate")
  vim.api.nvim_win_set_buf(win, buf.bufnr)
  buf.winid = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  return {
    buf = buf,
    win = win,
    root = root,
    path = path,
    lines = {},
    selected_change = nil,
    focus_line = nil,
    row_source = {},
    line_rows = {},
  }
end

---@param view AnnotateView
---@return integer
local function window_width(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then return vim.api.nvim_win_get_width(view.win) end
  return 120
end

---@param view AnnotateView
function M.render(view)
  local lines = {}
  local highlights = {}
  view.row_source = {}
  view.line_rows = {}

  local id_w, author_w, date_w = 8, 8, 10
  for _, row in ipairs(view.lines) do
    id_w = math.max(id_w, #row.change_id)
    author_w = math.max(author_w, math.min(#row.author, 16))
    date_w = math.max(date_w, #row.date)
  end
  author_w = math.min(author_w, 16)

  local width = window_width(view)
  local function meta_width(aw, dw)
    local n = id_w + 3
    if aw > 0 then n = n + aw + 2 end
    if dw > 0 then n = n + dw + 2 end
    return n
  end
  local aw, dw = author_w, date_w
  while width < meta_width(aw, dw) + 24 and aw > 0 do
    aw = math.max(0, aw - 4)
  end
  if width < meta_width(aw, dw) + 24 then dw = 0 end
  local stacked = width < meta_width(aw, dw) + 24

  local function line_hl_for(row)
    if view.focus_line and row.line_number == view.focus_line then return "JujutsuAnnotateCurrent" end
    if view.selected_change and row.change_id == view.selected_change then return "JujutsuAnnotateSelected" end
    return nil
  end

  local function push_meta(row)
    local id = row.change_id
    local id_pad = math.max(0, id_w - #id)
    local parts = { id .. string.rep(" ", id_pad) }
    local spans = { { #id, "JujutsuAnnotateHash" }, { id_pad, nil } }
    if aw > 0 then
      local author = row.author
      if #author > aw then author = author:sub(1, math.max(aw - 1, 1)) .. "…" end
      local author_pad = math.max(0, aw - #author)
      parts[#parts + 1] = author .. string.rep(" ", author_pad)
      spans[#spans + 1] = { 2, nil }
      spans[#spans + 1] = { #author, "JujutsuAnnotateAuthor" }
      spans[#spans + 1] = { author_pad, nil }
    end
    if dw > 0 then
      parts[#parts + 1] = row.date
      spans[#spans + 1] = { 2, nil }
      spans[#spans + 1] = { #row.date, "JujutsuAnnotateDate" }
    end
    return table.concat(parts, "  "), spans
  end

  for i, row in ipairs(view.lines) do
    local meta, spans = push_meta(row)
    local line_hl = line_hl_for(row)
    local first = #lines + 1
    view.line_rows[i] = first
    if stacked then
      lines[#lines + 1] = meta
      view.row_source[#lines] = i
      local col = 0
      for _, span in ipairs(spans) do
        local len, hl = span[1], span[2]
        if hl and len > 0 then
          highlights[#highlights + 1] = { line = #lines - 1, col = col, end_col = col + len, hl = hl }
        end
        col = col + len
      end
      if line_hl then highlights[#highlights + 1] = { line = #lines - 1, line_hl = line_hl } end
      lines[#lines + 1] = row.content
      view.row_source[#lines] = i
      if line_hl then highlights[#highlights + 1] = { line = #lines - 1, line_hl = line_hl } end
    else
      local sep = " │ "
      local text = meta .. sep .. row.content
      lines[#lines + 1] = text
      view.row_source[#lines] = i
      local col = 0
      for _, span in ipairs(spans) do
        local len, hl = span[1], span[2]
        if hl and len > 0 then
          highlights[#highlights + 1] = { line = #lines - 1, col = col, end_col = col + len, hl = hl }
        end
        col = col + len
      end
      highlights[#highlights + 1] = { line = #lines - 1, col = col, end_col = col + #sep, hl = "JujutsuSubtle" }
      if line_hl then highlights[#highlights + 1] = { line = #lines - 1, line_hl = line_hl } end
    end
  end

  if #lines == 0 then
    lines = { "(no annotate data)" }
    highlights = { { line = 0, col = 0, end_col = #"(no annotate data)", hl = "JujutsuSubtle" } }
  end

  Buffer.render(view.buf, lines, highlights)
end

---@param view AnnotateView
---@return integer|nil
function M.source_index(view)
  if not view.win or not vim.api.nvim_win_is_valid(view.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(view.win)[1]
  return view.row_source and view.row_source[lnum]
end

---@param view AnnotateView
---@param dir integer
function M.jump_hunk(view, dir)
  local idx = M.source_index(view) or 1
  local target
  if dir > 0 then
    for i = idx + 1, #view.lines do
      if view.lines[i].first_hunk then
        target = i
        break
      end
    end
  else
    local start_i = idx
    while start_i > 1 and not view.lines[start_i].first_hunk do
      start_i = start_i - 1
    end
    if start_i <= 1 then return end
    target = start_i - 1
    while target > 1 and not view.lines[target].first_hunk do
      target = target - 1
    end
  end
  if not target or not view.line_rows[target] then return end
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_cursor(view.win, { view.line_rows[target], 0 })
  end
end

---@param view AnnotateView
---@param line_number integer
function M.goto_line(view, line_number)
  if not view.win or not vim.api.nvim_win_is_valid(view.win) then return end
  for i, row in ipairs(view.lines) do
    if row.line_number == line_number and view.line_rows[i] then
      vim.api.nvim_win_set_cursor(view.win, { view.line_rows[i], 0 })
      return
    end
  end
end

---@param view AnnotateView
---@param change_id string|nil
---@param opts? { keep_cursor?: boolean }
function M.highlight_change(view, change_id, opts)
  opts = opts or {}
  local cursor
  if opts.keep_cursor and view.win and vim.api.nvim_win_is_valid(view.win) then
    cursor = vim.api.nvim_win_get_cursor(view.win)
  end
  view.selected_change = change_id
  M.render(view)
  if cursor and view.win and vim.api.nvim_win_is_valid(view.win) then
    local last = vim.api.nvim_buf_line_count(view.buf.bufnr)
    pcall(vim.api.nvim_win_set_cursor, view.win, { math.min(cursor[1], math.max(last, 1)), cursor[2] })
    return
  end
  if not change_id or change_id == "" then return end
  for i, row in ipairs(view.lines) do
    if row.change_id == change_id or change_id:sub(1, #row.change_id) == row.change_id then
      if view.win and vim.api.nvim_win_is_valid(view.win) and view.line_rows[i] then
        vim.api.nvim_win_set_cursor(view.win, { view.line_rows[i], 0 })
      end
      return
    end
  end
end

---@param view AnnotateView
function M.focus(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then vim.api.nvim_set_current_win(view.win) end
end

---@param view AnnotateView
function M.destroy(view)
  if not view then return end
  if view.buf and vim.api.nvim_buf_is_valid(view.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, view.buf.bufnr, { force = true })
  end
end

return M
