local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local util = require("jujutsu.util")

local M = {}

---@param path string
---@return string
local function detect_filetype(path)
  local ft = vim.filetype.match({ filename = path })
  return ft or ""
end

---@param lines string[]|nil
---@return string[]
local function ensure_lines(lines)
  if not lines or #lines == 0 then return { "" } end
  return lines
end

---@param root string
---@param rev string
---@param path string
---@return string[]
local function file_show(root, rev, path)
  local res = cli.file_show.revision(rev).paths(path).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if res.code ~= 0 then return {} end
  return res.stdout or {}
end

---@param win integer|nil
---@return boolean
local function win_valid(win) return win ~= nil and vim.api.nvim_win_is_valid(win) end

---@param win integer
local function apply_side_opts(win)
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "auto"
  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end
end

---@class DiffSplit
---@field left_buf Buffer
---@field right_buf Buffer
---@field left_win integer|nil
---@field right_win integer|nil
---@field root string
---@field uri_prefix string
---@field hidden_side "LEFT"|"RIGHT"|nil
---@field host_top? { x: number, y: number, w: number, h: number }

---@param root string
---@param left_win integer
---@param right_win integer
---@param opts? { uri_prefix?: string }
---@return DiffSplit
function M.create(root, left_win, right_win, opts)
  opts = opts or {}
  local prefix = opts.uri_prefix or "jujutsu://diff"
  local left_buf = Buffer.create(prefix .. "/a", "jujutsu-diff-split")
  local right_buf = Buffer.create(prefix .. "/b", "jujutsu-diff-split")
  -- Keep sides alive if a float/prompt briefly steals focus; wipe would drop the
  -- buffer when it is not displayed and can collapse a DiffView split.
  vim.bo[left_buf.bufnr].bufhidden = "hide"
  vim.bo[right_buf.bufnr].bufhidden = "hide"

  vim.api.nvim_win_set_buf(left_win, left_buf.bufnr)
  vim.api.nvim_win_set_buf(right_win, right_buf.bufnr)
  left_buf.winid = left_win
  right_buf.winid = right_win

  apply_side_opts(left_win)
  apply_side_opts(right_win)

  return {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    root = root,
    uri_prefix = prefix,
    hidden_side = nil,
    host_top = opts.host_top,
  }
end

---@param buf Buffer
---@param lines string[]
---@param name string
---@param ft string
local function set_content(buf, lines, name, ft)
  -- readonly and modifiable are independent; clear both before rewriting.
  vim.bo[buf.bufnr].readonly = false
  vim.bo[buf.bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buf.bufnr, "")
  pcall(vim.api.nvim_buf_set_name, buf.bufnr, name)
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, ensure_lines(lines))
  if ft ~= "" then
    vim.bo[buf.bufnr].filetype = ft
  else
    vim.bo[buf.bufnr].filetype = "jujutsu-diff-split"
  end
  vim.bo[buf.bufnr].modifiable = false
  vim.bo[buf.bufnr].modified = false
  vim.bo[buf.bufnr].readonly = true
end

---Attach treesitter for normal syntax highlighting (no DiffAdd wash).
---@param bufnr integer
---@param ft string
local function start_treesitter(bufnr, ft)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if ft == "" or ft == "jujutsu-diff-split" then
    pcall(vim.treesitter.stop, bufnr)
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.language.add, lang) then return end
  pcall(vim.treesitter.start, bufnr, lang)
end

local function diffoff_wins(state)
  for _, win in ipairs({ state.left_win, state.right_win }) do
    if win_valid(win) then
      pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
      pcall(function() vim.wo[win].diff = false end)
    end
  end
end

---Which pane to hide for a jj diff status letter (A/N/? → left empty; D → right empty).
---@param status string|nil
---@return "LEFT"|"RIGHT"|nil
function M.hide_side_for_status(status)
  local s = tostring(status or ""):sub(1, 1):upper()
  if s == "A" or s == "N" or s == "?" then return "LEFT" end
  if s == "D" then return "RIGHT" end
  return nil
end

---@param state DiffSplit
local function recreate_left(state)
  if not win_valid(state.right_win) then return end
  local cur = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.right_win)
  vim.cmd("leftabove vsplit")
  state.left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.left_win, state.left_buf.bufnr)
  state.left_buf.winid = state.left_win
  apply_side_opts(state.left_win)
  if win_valid(cur) then pcall(vim.api.nvim_set_current_win, cur) end
end

---@param state DiffSplit
local function recreate_right(state)
  if not win_valid(state.left_win) then return end
  local cur = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.left_win)
  vim.cmd("rightbelow vsplit")
  state.right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.right_win, state.right_buf.bufnr)
  state.right_buf.winid = state.right_win
  apply_side_opts(state.right_win)
  if win_valid(cur) then pcall(vim.api.nvim_set_current_win, cur) end
end

---@param state DiffSplit
---@param hide "LEFT"|"RIGHT"|nil
local function apply_host_layout(state, hide)
  local host = require("jujutsu.ui.host")
  local top = state.host_top or { x = 0, y = 0, w = 1, h = 0.75 }
  local function ensure(which, region)
    local win = state[which .. "_win"]
    local buf = state[which .. "_buf"]
    if not win_valid(win) then
      win = host.open(buf.bufnr, region, { border = "none", enter = false })
      state[which .. "_win"] = win
      buf.winid = win
      if win then apply_side_opts(win) end
    else
      host.place(win, region)
    end
  end
  local function drop(which)
    local win = state[which .. "_win"]
    if win_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    state[which .. "_win"] = nil
    state[which .. "_buf"].winid = nil
  end
  if hide == "LEFT" then
    drop("left")
    ensure("right", top)
  elseif hide == "RIGHT" then
    drop("right")
    ensure("left", top)
  else
    ensure("left", { x = top.x, y = top.y, w = top.w / 2, h = top.h })
    ensure("right", { x = top.x + top.w / 2, y = top.y, w = top.w / 2, h = top.h })
  end
  state.hidden_side = hide
end

---Ensure the visible layout matches `hide` ("LEFT" / "RIGHT" / nil = both).
---@param state DiffSplit
---@param hide "LEFT"|"RIGHT"|nil
local function apply_layout(state, hide)
  if state.host_top then
    apply_host_layout(state, hide)
    return
  end
  if hide ~= "LEFT" and not win_valid(state.left_win) then recreate_left(state) end
  if hide ~= "RIGHT" and not win_valid(state.right_win) then recreate_right(state) end

  if hide == "LEFT" then
    if not win_valid(state.right_win) then recreate_right(state) end
    if win_valid(state.left_win) then
      pcall(vim.api.nvim_win_close, state.left_win, true)
      state.left_win = nil
      state.left_buf.winid = nil
    end
  elseif hide == "RIGHT" then
    if not win_valid(state.left_win) then recreate_left(state) end
    if win_valid(state.right_win) then
      pcall(vim.api.nvim_win_close, state.right_win, true)
      state.right_win = nil
      state.right_buf.winid = nil
    end
  end

  state.hidden_side = hide
end

---Clear both sides to empty placeholders.
---@param state DiffSplit
function M.clear(state)
  if not state then return end
  diffoff_wins(state)
  apply_layout(state, nil)
  set_content(state.left_buf, { "" }, state.uri_prefix .. "/a", "")
  set_content(state.right_buf, { "" }, state.uri_prefix .. "/b", "")
end

---Show a 2-way Neovim diffsplit for path between two revisions.
---For added/new files the left pane is hidden; for deleted files the right pane is hidden.
---@param state DiffSplit
---@param left_rev string
---@param right_rev string
---@param path string
---@param opts? { status?: string }
function M.show_sides(state, left_rev, right_rev, path, opts)
  opts = opts or {}
  if not state or not path or path == "" then
    M.clear(state)
    return
  end

  local hide = M.hide_side_for_status(opts.status)
  local left_lines = hide == "LEFT" and {} or file_show(state.root, left_rev, path)
  local right_lines = hide == "RIGHT" and {} or file_show(state.root, right_rev, path)
  local ft = detect_filetype(path)

  diffoff_wins(state)
  apply_layout(state, hide)

  local safe = util.buf_name_path(path)
  set_content(state.left_buf, left_lines, state.uri_prefix .. "/a/" .. safe, ft)
  set_content(state.right_buf, right_lines, state.uri_prefix .. "/b/" .. safe, ft)

  if hide == nil then
    -- Side-by-side: keep diff highlighting; treesitter still runs underneath.
    start_treesitter(state.left_buf.bufnr, ft)
    start_treesitter(state.right_buf.bufnr, ft)
    if win_valid(state.left_win) then
      vim.api.nvim_win_call(state.left_win, function()
        vim.cmd("diffthis")
        vim.cmd("normal! gg")
      end)
    end
    if win_valid(state.right_win) then
      vim.api.nvim_win_call(state.right_win, function()
        vim.cmd("diffthis")
        vim.cmd("normal! gg")
      end)
    end
  else
    -- Added/deleted: single pane - no DiffAdd/DiffDelete wash, just treesitter.
    local win = hide == "LEFT" and state.right_win or state.left_win
    local buf = hide == "LEFT" and state.right_buf or state.left_buf
    if win_valid(win) then
      pcall(function() vim.wo[win].diff = false end)
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("diffoff")
        vim.cmd("normal! gg")
      end)
    end
    start_treesitter(buf.bufnr, ft)
  end
end

---Show parent → revision 2-way diff for a path.
---@param state DiffSplit
---@param rev string
---@param path string
---@param opts? { status?: string }
function M.show_file(state, rev, path, opts) M.show_sides(state, rev .. "-", rev, path, opts) end

---@param state DiffSplit
function M.destroy(state)
  if not state then return end
  diffoff_wins(state)
  for _, buf in ipairs({ state.left_buf, state.right_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf.bufnr) then
      vim.bo[buf.bufnr].modifiable = true
      pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    end
  end
end

return M
