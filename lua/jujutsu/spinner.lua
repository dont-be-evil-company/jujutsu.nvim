local config = require("jujutsu.config")

local M = {}

local SPINNER_FRAMES = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local MIN_VISIBLE_MS = 250

---@type "juu"|"block"|nil
local backend = nil
---@type any
local juu_handle = nil
---@type fun()|nil
local block_stop = nil
---@type integer|nil
local started_at = nil

local function truncate(msg, max)
  if #msg <= max then return msg end
  return msg:sub(1, max - 3) .. "..."
end

local function juu_available() return config.check_integration("juu") end

---@param msg string
---@return boolean
local function start_juu(msg)
  local ok, progress = pcall(require, "juu.progress")
  if not ok or not progress or not progress.handle then return false end

  juu_handle = progress.handle.create({
    title = "jujutsu",
    message = msg,
    client = { name = "jujutsu" },
    cancellable = false,
  })
  juu_handle:report({ title = "jujutsu", message = msg })
  backend = "juu"
  return true
end

local function stop_juu()
  if juu_handle then
    pcall(function() juu_handle:finish() end)
    juu_handle = nil
  end
end

--- Centered floating block with animated spinner (snap.nvim-style).
---@param text string
---@return fun()
local function show_loading_block(text)
  text = truncate(text, 60)

  local original_win = vim.api.nvim_get_current_win()
  local original_mouse = vim.opt.mouse

  vim.opt.mouse = ""
  local win_width = math.min(vim.o.columns - 4, #text + 10)
  local win_height = 3

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local host = require("jujutsu.ui.host")
  local win = host.open_float(buf, {
    width = win_width,
    height = win_height,
    border = "rounded",
    zindex = 300,
  })

  local map_opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "<Esc>", "<Nop>", map_opts)

  local frame_idx = 1
  local timer = vim.uv.new_timer()

  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { string.format("  %s  %s", SPINNER_FRAMES[frame_idx], text) })
  vim.cmd("redraw")

  local update_callback = vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(win) then
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      return
    end

    while vim.fn.getchar(0) ~= 0 do
      -- Discard buffered keypresses while the command runs
    end

    local line = string.format("  %s  %s", SPINNER_FRAMES[frame_idx], text)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { line })
    frame_idx = (frame_idx % #SPINNER_FRAMES) + 1
  end)

  timer:start(0, 80, update_callback)

  return function()
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
    end
    vim.opt.mouse = original_mouse
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    -- Don't yank focus back onto a stale window if a picker already opened.
    if original_win and vim.api.nvim_win_is_valid(original_win) then
      local cur = vim.api.nvim_get_current_win()
      local cur_cfg = vim.api.nvim_win_is_valid(cur) and vim.api.nvim_win_get_config(cur) or {}
      local cur_ft = ""
      if vim.api.nvim_win_is_valid(cur) then
        local b = vim.api.nvim_win_get_buf(cur)
        if vim.api.nvim_buf_is_valid(b) then cur_ft = vim.bo[b].filetype or "" end
      end
      local picker_z = (cur_cfg.zindex or 0) >= 200
      local picker_focused = cur_ft == "jujutsu-finder"
        or cur_ft == "jujutsu-input"
        or (cur_cfg.relative and cur_cfg.relative ~= "" and picker_z)
        or require("jujutsu.finder").is_active()
      if not picker_focused then pcall(vim.api.nvim_set_current_win, original_win) end
    end
  end
end

---@param msg string
local function start_block(msg)
  block_stop = show_loading_block(msg)
  backend = "block"
end

local function stop_block()
  if block_stop then
    block_stop()
    block_stop = nil
  end
end

---@param msg? string
---@param on_ready? fun()
function M.start(msg, on_ready)
  if config.values.process_spinner == false then
    if on_ready then on_ready() end
    return
  end

  M.stop()
  msg = msg or "Running…"
  started_at = vim.uv.now()

  local function ready()
    vim.schedule(function()
      if on_ready then on_ready() end
    end)
  end

  if juu_available() and start_juu(msg) then
    ready()
    return
  end

  -- Important: in some call sites we block using `vim.wait()`, so relying on
  -- `vim.schedule()` to create the floating window can prevent the UI from
  -- painting. Start the block immediately, but keep `on_ready()` scheduled.
  start_block(msg)
  ready()
end

---@param cb? fun()
function M.stop(cb)
  local function cleanup()
    if backend == "juu" then
      stop_juu()
    elseif backend == "block" then
      stop_block()
    end
    backend = nil
    started_at = nil
    if cb then cb() end
  end

  if not backend or not started_at then
    cleanup()
    return
  end

  local elapsed = vim.uv.now() - started_at
  if elapsed < MIN_VISIBLE_MS then
    vim.defer_fn(cleanup, MIN_VISIBLE_MS - elapsed)
    return
  end

  cleanup()
end

---@return boolean
function M.active() return backend ~= nil end

return M
