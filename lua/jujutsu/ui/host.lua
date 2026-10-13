local config = require("jujutsu.config")

local M = {}

local HOST_Z = 40
local CHILD_Z = 50

---@class HostRegion
---@field x number
---@field y number
---@field w number
---@field h number

---@class HostChild
---@field win integer
---@field kind "region"|"bottom"|"centered"
---@field region? HostRegion
---@field height? integer
---@field width? integer
---@field border? any
---@field title? string
---@field title_pos? string
---@field zindex? integer
---@field style? string

---@class HostSession
---@field win integer
---@field children HostChild[]
---@field next_z integer
---@field closing boolean

---@type HostSession|nil
local session = nil
local reflowing = false

local function valid(win) return win and vim.api.nvim_win_is_valid(win) end

function M.active() return session ~= nil and valid(session.win) and not session.closing end

function M.win()
  if M.active() then return session.win end
  return nil
end

---@return table
local function editor_float_config()
  local f = config.values.floating or {}
  local width = f.width or 0.8
  local height = f.height or 0.7
  if width < 1 then width = math.floor(vim.o.columns * width) end
  if height < 1 then height = math.floor(vim.o.lines * height) end
  width = math.max(20, math.min(math.floor(width), math.max(20, vim.o.columns - 2)))
  height = math.max(8, math.min(math.floor(height), math.max(8, vim.o.lines - 4)))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return {
    relative = f.relative or "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = f.style or "minimal",
    border = f.border or "rounded",
    zindex = HOST_Z,
  }
end

---@param region HostRegion
---@return integer row, integer col, integer width, integer height
local function region_cells(region)
  local hw = vim.api.nvim_win_get_width(session.win)
  local hh = vim.api.nvim_win_get_height(session.win)
  local col = math.floor(hw * region.x + 1e-6)
  local row = math.floor(hh * region.y + 1e-6)
  local width = math.floor(hw * region.w + 1e-6)
  local height = math.floor(hh * region.h + 1e-6)
  if width < 1 then width = 1 end
  if height < 1 then height = 1 end
  if col < 0 then col = 0 end
  if row < 0 then row = 0 end
  if col >= hw then col = hw - 1 end
  if row >= hh then row = hh - 1 end
  if col + width > hw then width = hw - col end
  if row + height > hh then height = hh - row end
  return row, col, math.max(1, width), math.max(1, height)
end

---@param child HostChild
---@return table
local function child_config(child)
  local cfg = {
    relative = "win",
    win = session.win,
    style = child.style or "minimal",
    border = child.border or "none",
    focusable = true,
    zindex = child.zindex or CHILD_Z,
  }
  if child.title then
    cfg.title = child.title
    cfg.title_pos = child.title_pos or "center"
  end
  if child.kind == "bottom" then
    local hw = vim.api.nvim_win_get_width(session.win)
    local hh = vim.api.nvim_win_get_height(session.win)
    local height = math.min(child.height or 8, math.max(1, hh - 1))
    cfg.row = math.max(0, hh - height)
    cfg.col = 0
    cfg.width = math.max(1, hw)
    cfg.height = height
  elseif child.kind == "centered" then
    local hw = vim.api.nvim_win_get_width(session.win)
    local hh = vim.api.nvim_win_get_height(session.win)
    local width = math.max(1, math.min(child.width or math.floor(hw * 0.8), hw))
    local height = math.max(1, math.min(child.height or math.floor(hh * 0.6), hh))
    cfg.width = width
    cfg.height = height
    cfg.row = math.max(0, math.floor((hh - height) / 2))
    cfg.col = math.max(0, math.floor((hw - width) / 2))
  else
    local row, col, width, height = region_cells(child.region or { x = 0, y = 0, w = 1, h = 1 })
    cfg.row = row
    cfg.col = col
    cfg.width = width
    cfg.height = height
  end
  return cfg
end

---@param child HostChild
local function apply_child(child)
  if not M.active() or not valid(child.win) then return end
  pcall(vim.api.nvim_win_set_config, child.win, child_config(child))
end

function M.reflow()
  if reflowing or not M.active() then return end
  reflowing = true
  pcall(vim.api.nvim_win_set_config, session.win, editor_float_config())
  for _, child in ipairs(session.children) do
    apply_child(child)
  end
  reflowing = false
end

local function reflow_children()
  if reflowing or not M.active() then return end
  reflowing = true
  for _, child in ipairs(session.children) do
    apply_child(child)
  end
  reflowing = false
end

---@param win integer
function M.attach(win)
  if session and session.win ~= win then
    local previous = session.children
    session = nil
    for _, child in ipairs(previous) do
      if valid(child.win) then pcall(vim.api.nvim_win_close, child.win, true) end
    end
  end
  session = {
    win = win,
    children = {},
    next_z = CHILD_Z,
    closing = false,
  }
  local cfg = vim.api.nvim_win_get_config(win)
  cfg.zindex = HOST_Z
  pcall(vim.api.nvim_win_set_config, win, cfg)

  local group = vim.api.nvim_create_augroup("JujutsuFloatHost", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local id = tonumber(ev.match)
      if not session then return end
      if id == session.win then
        vim.schedule(M.detach)
      else
        M.forget(id)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function() M.reflow() end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if reflowing or not M.active() then return end
      local windows = vim.v.event and vim.v.event.windows or {}
      for _, id in ipairs(windows) do
        if id == session.win then
          reflow_children()
          return
        end
      end
    end,
  })
end

function M.detach()
  if not session or session.closing then return end
  local children = session.children
  session.closing = true
  session = nil
  for _, child in ipairs(children) do
    if valid(child.win) then pcall(vim.api.nvim_win_close, child.win, true) end
  end
end

---@param bufnr integer
---@return integer win
function M.spawn(bufnr)
  local win = vim.api.nvim_open_win(bufnr, true, editor_float_config())
  M.attach(win)
  return win
end

---@param win integer|nil
function M.forget(win)
  if not session or not win then return end
  local kept = {}
  for _, child in ipairs(session.children) do
    if child.win ~= win and valid(child.win) then kept[#kept + 1] = child end
  end
  session.children = kept
end

---@param win integer|nil
---@return boolean
function M.owns(win)
  if not win or not M.active() then return false end
  for _, child in ipairs(session.children) do
    if child.win == win then return true end
  end
  return false
end

---@param win integer|nil
---@return HostRegion|nil
function M.region(win)
  if not session or not win then return nil end
  for _, child in ipairs(session.children) do
    if child.win == win then return child.region end
  end
  return nil
end

---@param win integer
---@param region HostRegion
function M.place(win, region)
  if not session then return end
  for _, child in ipairs(session.children) do
    if child.win == win then
      child.kind = "region"
      child.region = region
      apply_child(child)
      return
    end
  end
end

---@param bufnr integer
---@param region? HostRegion
---@param opts? table
---@return integer|nil
function M.open(bufnr, region, opts)
  if not M.active() then return nil end
  opts = opts or {}
  local z = opts.zindex or session.next_z
  session.next_z = math.max(session.next_z, z) + 1
  local child = {
    win = 0,
    kind = "region",
    region = region or { x = 0, y = 0, w = 1, h = 1 },
    border = opts.border or "none",
    title = opts.title,
    title_pos = opts.title_pos,
    zindex = z,
    style = opts.style or "minimal",
  }
  local enter = opts.enter ~= false
  local win = vim.api.nvim_open_win(bufnr, enter, child_config(child))
  child.win = win
  session.children[#session.children + 1] = child
  return win
end

---@param specs { key: string, region: HostRegion, enter?: boolean }[]
---@return table<string, integer>|nil
function M.tiles(specs)
  if not M.active() then return nil end
  local out = {}
  for _, spec in ipairs(specs) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    local win = M.open(buf, spec.region, { border = "none", enter = spec.enter == true })
    out[spec.key] = win
  end
  return out
end

---@param panel_lines? integer
---@return { left: HostRegion, right: HostRegion, panel: HostRegion, top: HostRegion }|nil
function M.diff_regions(panel_lines)
  if not M.active() then return nil end
  local hh = vim.api.nvim_win_get_height(session.win)
  local ph = math.min(math.max(panel_lines or 8, 3), math.max(3, hh - 3))
  local top_h = (hh - ph) / hh
  return {
    left = { x = 0, y = 0, w = 0.5, h = top_h },
    right = { x = 0.5, y = 0, w = 0.5, h = top_h },
    panel = { x = 0, y = top_h, w = 1, h = 1 - top_h },
    top = { x = 0, y = 0, w = 1, h = top_h },
  }
end

---@param bufnr integer
---@param frac? number
---@return integer|nil
function M.open_side(bufnr, frac)
  frac = frac or 0.45
  if frac > 1 then frac = 0.45 end
  frac = math.max(0.25, math.min(0.85, frac))
  return M.open(bufnr, { x = 1 - frac, y = 0, w = frac, h = 1 }, { border = "none" })
end

---@param path string
---@param how? string
---@return integer|nil
function M.open_file(path, how)
  if not M.active() then return nil end
  local bufnr = vim.fn.bufadd(path)
  vim.bo[bufnr].buflisted = true
  pcall(vim.fn.bufload, bufnr)
  local region = { x = 0, y = 0, w = 1, h = 1 }
  local border = "none"
  if how == "split" then
    region = { x = 0, y = 0.5, w = 1, h = 0.5 }
    border = "rounded"
  elseif how == "vsplit" then
    region = { x = 0.45, y = 0, w = 0.55, h = 1 }
    border = "rounded"
  end
  return M.open(bufnr, region, { border = border })
end

---@param height integer
---@param extra? { title?: string, title_pos?: string, zindex?: integer }
---@return table
function M.bottom_config(height, extra)
  extra = extra or {}
  local cfg
  if M.active() then
    local hw = vim.api.nvim_win_get_width(session.win)
    local hh = vim.api.nvim_win_get_height(session.win)
    height = math.min(height, math.max(1, hh - 1))
    cfg = {
      relative = "win",
      win = session.win,
      row = math.max(0, hh - height),
      col = 0,
      width = math.max(1, hw),
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = true,
      zindex = extra.zindex or 200,
    }
  else
    height = math.min(height, math.max(1, vim.o.lines - 2))
    cfg = {
      relative = "editor",
      row = math.max(0, vim.o.lines - height - 2),
      col = 0,
      width = vim.o.columns,
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = true,
      zindex = extra.zindex or 200,
    }
  end
  if extra.title then
    cfg.title = extra.title
    cfg.title_pos = extra.title_pos or "left"
  end
  return cfg
end

---@param win integer
---@param height integer
function M.track_bottom(win, height)
  if not M.active() or not valid(win) then return end
  session.children[#session.children + 1] = {
    win = win,
    kind = "bottom",
    height = height,
    border = "rounded",
    zindex = 200,
    style = "minimal",
  }
  session.next_z = math.max(session.next_z, 201)
end

---@param bufnr integer
---@param opts? { width?: integer, height?: integer, title?: string, title_pos?: string, border?: any, zindex?: integer, enter?: boolean }
---@return integer
function M.open_float(bufnr, opts)
  opts = opts or {}
  local enter = opts.enter ~= false
  if M.active() then
    local z = opts.zindex or 80
    session.next_z = math.max(session.next_z, z) + 1
    local child = {
      win = 0,
      kind = "centered",
      width = opts.width,
      height = opts.height,
      border = opts.border or "rounded",
      title = opts.title,
      title_pos = opts.title_pos or "center",
      zindex = z,
      style = "minimal",
    }
    local win = vim.api.nvim_open_win(bufnr, enter, child_config(child))
    child.win = win
    session.children[#session.children + 1] = child
    return win
  end
  local width = opts.width or math.floor(vim.o.columns * 0.6)
  local height = opts.height or math.floor(vim.o.lines * 0.4)
  width = math.max(1, math.min(width, vim.o.columns))
  height = math.max(1, math.min(height, vim.o.lines - 2))
  return vim.api.nvim_open_win(bufnr, enter, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title,
    title_pos = opts.title_pos or "center",
    zindex = opts.zindex or 80,
  })
end

return M
