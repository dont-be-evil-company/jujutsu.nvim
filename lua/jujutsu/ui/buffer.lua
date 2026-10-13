local config = require("jujutsu.config")
local window = require("jujutsu.ui.window")

local M = {}

---@class Buffer
---@field bufnr integer
---@field winid integer|nil
---@field name string
---@field filetype string
---@field extmarks integer

---@param name string
---@param filetype string
---@return Buffer
function M.create(name, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, bufnr, name)

  return {
    bufnr = bufnr,
    winid = nil,
    name = name,
    filetype = filetype,
    ns = vim.api.nvim_create_namespace("jujutsu_" .. filetype),
  }
end

---@param buf Buffer
---@param kind? string
---@return integer
function M.open(buf, kind)
  buf.winid = window.open(kind, buf.bufnr)
  return buf.winid
end

---@param buf Buffer
---@param lines string[]
---@param highlights? { line: integer, col?: integer, end_col?: integer, hl?: string, line_hl?: string }[]
function M.render(buf, lines, highlights)
  vim.bo[buf.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(buf.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf.bufnr, buf.ns, 0, -1)
  for _, h in ipairs(highlights or {}) do
    local opts = {
      hl_mode = "combine",
      priority = 100,
    }
    if h.line_hl then opts.line_hl_group = h.line_hl end
    if h.hl then
      local line_text = lines[h.line + 1] or ""
      local col = h.col or 0
      local end_col = h.end_col or #line_text
      if end_col > #line_text then end_col = #line_text end
      if col < end_col then
        opts.end_col = end_col
        opts.hl_group = h.hl
        vim.api.nvim_buf_set_extmark(buf.bufnr, buf.ns, h.line, col, opts)
      elseif h.line_hl then
        vim.api.nvim_buf_set_extmark(buf.bufnr, buf.ns, h.line, 0, {
          line_hl_group = h.line_hl,
          hl_mode = "combine",
          priority = 100,
        })
      end
    elseif h.line_hl then
      vim.api.nvim_buf_set_extmark(buf.bufnr, buf.ns, h.line, 0, {
        line_hl_group = h.line_hl,
        hl_mode = "combine",
        priority = 100,
      })
    end
  end
  vim.bo[buf.bufnr].modifiable = false
  vim.bo[buf.bufnr].modified = false
end

---@param buf Buffer
function M.focus(buf)
  if buf.winid and vim.api.nvim_win_is_valid(buf.winid) then
    vim.api.nvim_set_current_win(buf.winid)
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf.bufnr then
      buf.winid = win
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

---Reclaim focus after popup/picker teardown (often steals WinEnter).
---@param buf Buffer
---@param opts? { delays?: integer[] }
function M.ensure_focus(buf, opts)
  opts = opts or {}
  local delays = opts.delays or { 0, 30, 80, 160, 320 }
  local function try()
    if not buf or not vim.api.nvim_buf_is_valid(buf.bufnr) then return end
    local cur = vim.api.nvim_get_current_win()
    if require("jujutsu.finder").is_active() then return end
    if vim.api.nvim_win_is_valid(cur) then
      local cfg = vim.api.nvim_win_get_config(cur)
      local z = cfg.zindex or 0
      if cfg.relative and cfg.relative ~= "" and z >= 200 then return end
      local cur_buf = vim.api.nvim_win_get_buf(cur)
      if vim.api.nvim_buf_is_valid(cur_buf) then
        local ft = vim.bo[cur_buf].filetype
        if ft == "jujutsu-finder" or ft == "jujutsu-input" then return end
      end
    end
    M.focus(buf)
  end
  for _, delay in ipairs(delays) do
    if delay == 0 then
      vim.schedule(try)
    else
      vim.defer_fn(try, delay)
    end
  end
end

---@param buf Buffer
function M.close(buf)
  if buf.winid and vim.api.nvim_win_is_valid(buf.winid) then
    local cfg = vim.api.nvim_win_get_config(buf.winid)
    local floating = cfg.relative and cfg.relative ~= ""
    local wins = vim.api.nvim_tabpage_list_wins(0)
    if floating or #wins > 1 then
      vim.api.nvim_win_close(buf.winid, true)
    else
      vim.cmd("b#")
    end
  end
  if vim.api.nvim_buf_is_valid(buf.bufnr) then vim.api.nvim_buf_delete(buf.bufnr, { force = true }) end
end

---@param buf Buffer
---@return boolean
function M.is_open(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf.bufnr) then return false end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf.bufnr then return true end
  end
  return false
end

function M.apply_buffer_opts(bufnr)
  if config.values.disable_line_numbers then vim.b[bufnr].jujutsu = true end
  vim.bo[bufnr].textwidth = 0
end

return M
