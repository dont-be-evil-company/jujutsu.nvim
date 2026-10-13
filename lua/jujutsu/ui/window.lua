local config = require("jujutsu.config")
local host = require("jujutsu.ui.host")

local M = {}

---@param kind? string
---@param bufnr integer
---@return integer win
function M.open(kind, bufnr)
  kind = kind or config.values.kind or "tab"
  local win

  if host.active() then
    win = host.open(bufnr, { x = 0, y = 0, w = 1, h = 1 }, { border = "none" })
  elseif kind == "floating" then
    win = host.spawn(bufnr)
  elseif kind == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "replace" then
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split" or kind == "split_below" then
    vim.cmd("belowright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split_above" or kind == "split_above_all" then
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "split_below_all" then
    vim.cmd("botright split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "vsplit" then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif kind == "auto" then
    if vim.api.nvim_win_get_width(0) >= 160 then return M.open("vsplit", bufnr) end
    return M.open("split", bufnr)
  else
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  if config.values.disable_line_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end

  return win
end

return M
