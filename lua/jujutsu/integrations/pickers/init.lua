local config = require("jujutsu.config")

local M = {}

local active_depth = 0

local ORDER = { "snacks", "mini", "fzf-lua", "telescope" }

---@param entry any
---@return string
function M.entry_text(entry)
  if type(entry) == "table" then return entry.text or tostring(entry[1] or "") end
  return tostring(entry)
end

---@param entries any[]|nil
---@return string[]
function M.texts(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    local text = M.entry_text(entry)
    if text ~= "" then out[#out + 1] = text end
  end
  return out
end

---Match the built-in finder: multi returns a list, single returns a string.
---@param value any
---@param opts? { allow_multi?: boolean }
---@return string|string[]|nil
function M.normalize(value, opts)
  opts = opts or {}
  if value == nil then return nil end
  if opts.allow_multi then
    if type(value) == "string" then return value ~= "" and { value } or nil end
    if type(value) ~= "table" then return { tostring(value) } end
    local out = {}
    for _, item in ipairs(value) do
      local text = type(item) == "table" and M.entry_text(item) or tostring(item)
      if text ~= "" then out[#out + 1] = text end
    end
    return #out > 0 and out or nil
  end
  if type(value) == "table" then
    local text = M.entry_text(value[1] or value)
    return text ~= "" and text or nil
  end
  local text = tostring(value)
  return text ~= "" and text or nil
end

---@param name string
---@return boolean
function M.available(name)
  if name == "snacks" then
    local ok, snacks = pcall(require, "snacks")
    return ok and type(snacks) == "table" and snacks.picker ~= nil
  end
  if name == "mini" then return pcall(require, "mini.pick") end
  if name == "fzf-lua" then return pcall(require, "fzf-lua") end
  if name == "telescope" then return pcall(require, "telescope.pickers") and pcall(require, "telescope.finders") end
  return false
end

---@return string provider
---@return function|nil custom
function M.resolve()
  local spec = config.values.picker
  if type(spec) == "function" then return "function", spec end
  if spec == nil or spec == "builtin" then return "builtin" end
  if spec == "auto" then
    for _, name in ipairs(ORDER) do
      if M.available(name) then return name end
    end
    return "builtin"
  end
  if type(spec) == "string" and M.available(spec) then return spec end
  if spec ~= nil and spec ~= "builtin" then
    require("jujutsu.notify").warn("Picker '" .. tostring(spec) .. "' is not available; using the built-in finder")
  end
  return "builtin"
end

function M.set_active(on)
  if on then
    active_depth = active_depth + 1
  else
    active_depth = math.max(0, active_depth - 1)
  end
end

function M.is_active() return active_depth > 0 end

---Above the floating host (40) and its children, below the process spinner (300).
local PICKER_Z = 250

local PROMPT_KIND = {
  fzf = "terminal",
  TelescopePrompt = "insert",
  snacks_picker_input = "insert",
  snacks_input = "insert",
}

local RAISE_FT = {
  fzf = true,
  TelescopePrompt = true,
  TelescopeResults = true,
  TelescopePreview = true,
  snacks_picker_input = true,
  snacks_picker_list = true,
  snacks_input = true,
}

local pin_win = nil
local pin_kind = nil
local focus_armed = false

---@param win integer
function M.raise(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local cfg = vim.api.nvim_win_get_config(win)
  if not cfg.relative or cfg.relative == "" then return end
  if (cfg.zindex or 0) >= PICKER_Z then return end
  cfg.zindex = PICKER_Z
  pcall(vim.api.nvim_win_set_config, win, cfg)
end

---@param win integer
---@return string|nil
local function kind_of(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  return PROMPT_KIND[vim.bo[buf].filetype]
end

local function raise_known()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) and RAISE_FT[vim.bo[buf].filetype] then M.raise(win) end
    end
  end
  if pin_win then M.raise(pin_win) end
end

---@return integer|nil win
---@return string|nil kind
local function resolve_prompt()
  if pin_win and vim.api.nvim_win_is_valid(pin_win) then return pin_win, kind_of(pin_win) or pin_kind end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local kind = kind_of(win)
    if kind then return win, kind end
  end
  return nil, nil
end

---@param win integer
---@param kind string|nil
local function enter_prompt(win, kind)
  if vim.api.nvim_get_current_win() ~= win then pcall(vim.api.nvim_set_current_win, win) end
  if vim.api.nvim_get_current_win() ~= win then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local mode = vim.api.nvim_get_mode().mode
  if kind == "terminal" then
    -- The scratch buffer exists before termopen. startinsert then inserts into fzf.
    local ready = vim.bo[buf].buftype == "terminal" or vim.bo[buf].filetype == "fzf"
    if ready and mode ~= "t" then pcall(vim.cmd, "startinsert") end
  elseif kind == "insert" then
    if mode ~= "t" and not mode:match("^[iR]") then pcall(vim.cmd, "startinsert") end
  end
end

---Keep the external picker focused. Status and popup teardown often steal WinEnter.
---@param win? integer
---@param kind? "terminal"|"insert"|"window"
function M.claim(win, kind)
  if win then
    pin_win = win
    pin_kind = kind
  end
  if focus_armed then return end
  focus_armed = true

  local deadline = vim.uv.now() + 1500
  local group = vim.api.nvim_create_augroup("JujutsuExternalPickerFocus", { clear = true })
  local focusing = false

  local function stop()
    focus_armed = false
    pin_win = nil
    pin_kind = nil
    pcall(vim.api.nvim_del_augroup_by_name, "JujutsuExternalPickerFocus")
  end

  local function focus()
    if focusing then return end
    if not M.is_active() or vim.uv.now() > deadline then
      stop()
      return
    end
    focusing = true
    raise_known()
    local target, prompt_kind = resolve_prompt()
    if target then enter_prompt(target, prompt_kind) end
    focusing = false
  end

  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "WinNew", "WinLeave" }, {
    group = group,
    callback = function() vim.schedule(focus) end,
  })

  local delay = 0
  while delay <= 1200 do
    if delay == 0 then
      vim.schedule(focus)
    else
      vim.defer_fn(focus, delay)
    end
    delay = delay == 0 and 10 or (delay < 100 and delay + 20 or delay + 50)
  end
  vim.defer_fn(function()
    if focus_armed and vim.uv.now() > deadline then stop() end
  end, 1600)
end

local adapters = {
  snacks = function() return require("jujutsu.integrations.pickers.snacks") end,
  mini = function() return require("jujutsu.integrations.pickers.mini") end,
  ["fzf-lua"] = function() return require("jujutsu.integrations.pickers.fzf") end,
  telescope = function() return require("jujutsu.integrations.pickers.telescope") end,
}

---@param provider string
---@param opts { prompt?: string, entries?: any[], allow_multi?: boolean, allow_free_text?: boolean, on_load_more?: fun(current: string[]): string[]|nil }
---@param cb fun(item: string|string[]|nil)
---@return boolean opened
function M.open(provider, opts, cb)
  local payload = {
    prompt = opts.prompt,
    entries = M.texts(opts.entries),
    allow_multi = opts.allow_multi,
    allow_free_text = opts.allow_free_text,
    on_load_more = opts.on_load_more,
  }
  if provider == "function" then
    local fn = config.values.picker
    local ok = pcall(fn, payload, cb)
    if not ok then cb(nil) end
    return true
  end
  local load = adapters[provider]
  if not load then return false end
  local ok, adapter = pcall(load)
  if not ok or type(adapter) ~= "table" or type(adapter.pick) ~= "function" then return false end
  local ran, err = pcall(adapter.pick, payload, cb)
  if not ran then
    require("jujutsu.notify").warn("Picker " .. provider .. " failed: " .. tostring(err))
    cb(nil)
  end
  M.claim()
  return true
end

---@param provider string
---@param opts { prompt?: string, default?: string, allow_empty?: boolean, placeholder?: string }
---@param cb fun(value: string|nil)
---@return boolean opened
function M.input(provider, opts, cb)
  if provider == "function" then return false end
  local load = adapters[provider]
  if not load then return false end
  local ok, adapter = pcall(load)
  if not ok or type(adapter) ~= "table" or type(adapter.input) ~= "function" then return false end
  local ran, err = pcall(adapter.input, opts, cb)
  if not ran then
    require("jujutsu.notify").warn("Picker input " .. provider .. " failed: " .. tostring(err))
    cb(nil)
  end
  M.claim()
  return true
end

return M
