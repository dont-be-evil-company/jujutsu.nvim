local config = require("jujutsu.config")
local notify = require("jujutsu.notify")

local M = {}

---@class JujutsuTermOpts
---@field cwd? string
---@field title? string
---@field on_exit? fun(code: integer)

---Run a command in a real terminal (PTY) so jj TUIs like `:builtin` work.
---@param cmd string[]
---@param opts? JujutsuTermOpts
function M.run(cmd, opts)
  opts = opts or {}
  if type(cmd) ~= "table" or #cmd == 0 then
    notify.error("Invalid interactive command")
    return
  end

  local prev_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "jujutsu-term"

  local host = require("jujutsu.ui.host")
  local win
  if host.active() then
    win = host.open(buf, { x = 0, y = 0, w = 1, h = 1 }, {
      border = "none",
      title = opts.title or " jujutsu ",
      title_pos = "center",
      zindex = 70,
    })
  else
    local f = config.values.floating or {}
    local width = f.width or 0.9
    local height = f.height or 0.85
    if width < 1 then width = math.floor(vim.o.columns * width) end
    if height < 1 then height = math.floor(vim.o.lines * height) end
    width = math.max(20, math.min(width, vim.o.columns))
    height = math.max(10, math.min(height, vim.o.lines - 2))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    win = vim.api.nvim_open_win(buf, true, {
      relative = f.relative or "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = f.border or "rounded",
      title = opts.title or " jujutsu ",
      title_pos = "center",
    })
  end

  local closed = false
  local function cleanup(code)
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    if vim.api.nvim_win_is_valid(prev_win) then pcall(vim.api.nvim_set_current_win, prev_win) end
    if opts.on_exit then opts.on_exit(code or -1) end
    pcall(function() require("jujutsu").refresh() end)
  end

  vim.keymap.set("n", "q", function()
    -- If still running, job will exit when the buffer is wiped.
    cleanup(-1)
  end, { buffer = buf, silent = true, nowait = true })

  local job = vim.fn.termopen(cmd, {
    cwd = opts.cwd or vim.fn.getcwd(),
    on_exit = function(_, code)
      vim.schedule(function() cleanup(code) end)
    end,
  })

  if job <= 0 then
    notify.error("Failed to start interactive command")
    cleanup(-1)
    return
  end

  vim.cmd("startinsert")
end

return M
