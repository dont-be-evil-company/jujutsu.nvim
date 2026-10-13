local M = {}

local function finish_once(cb)
  local delivered = false
  return function(value)
    if delivered then return end
    delivered = true
    cb(value)
  end
end

local function items_from(entries)
  local items = {}
  for _, text in ipairs(entries or {}) do
    items[#items + 1] = { text = text, value = text }
  end
  return items
end

local function item_text(item)
  if type(item) ~= "table" then return tostring(item or "") end
  return item.text or item.value or ""
end

local function query_of(picker)
  local input = picker and picker.input
  local filter = input and input.filter
  local pattern = filter and (filter.pattern or filter.search)
  if type(pattern) == "string" then return pattern end
  return ""
end

local function run_picker(picker_opts)
  local snacks = require("snacks")
  local picker = snacks.picker
  if type(picker) == "table" and type(picker.pick) == "function" then
    picker.pick(picker_opts)
    return
  end
  if type(picker) == "function" then
    picker(picker_opts)
    return
  end
  error("snacks.picker is unavailable")
end

---@param opts { prompt?: string, entries: string[], allow_multi?: boolean, allow_free_text?: boolean }
---@param cb fun(item: string|string[]|nil)
function M.pick(opts, cb)
  local finish = finish_once(cb)
  local choosing = false
  run_picker({
    title = opts.prompt or "select",
    items = items_from(opts.entries),
    layout = { preset = "select" },
    format = function(item) return { { item_text(item) } } end,
    on_show = function(picker)
      local mod = require("jujutsu.integrations.pickers")
      local input = picker and picker.input
      local input_win = input and (input.win and (input.win.win or input.win) or input)
      if type(input_win) == "number" then mod.claim(input_win, "insert") end
      local list = picker and picker.list
      local list_win = list and (list.win and (list.win.win or list.win) or list)
      if type(list_win) == "number" then mod.raise(list_win) end
    end,
    confirm = function(picker, item)
      choosing = true
      local value
      if opts.allow_multi and picker.selected then
        local selected = picker:selected({ fallback = true }) or {}
        local out = {}
        for _, it in ipairs(selected) do
          local text = item_text(it)
          if text ~= "" then out[#out + 1] = text end
        end
        value = #out > 0 and out or nil
      else
        local text = item_text(item)
        value = text ~= "" and text or nil
      end
      if (value == nil or value == "") and opts.allow_free_text then
        local query = vim.trim(query_of(picker))
        if query ~= "" then value = query end
      end
      pcall(function() picker:close() end)
      vim.schedule(function() finish(value) end)
    end,
    on_close = function()
      vim.schedule(function()
        if not choosing then finish(nil) end
      end)
    end,
  })
end

---@param opts { prompt?: string, default?: string, allow_empty?: boolean }
---@param cb fun(value: string|nil)
function M.input(opts, cb)
  local snacks = require("snacks")
  if type(snacks.input) ~= "function" then
    M.pick({
      prompt = opts.prompt,
      entries = opts.default and opts.default ~= "" and { opts.default } or {},
      allow_free_text = true,
    }, function(value)
      if type(value) == "table" then value = value[1] end
      if value == nil or (value == "" and not opts.allow_empty) then
        cb(nil)
      else
        cb(value)
      end
    end)
    return
  end
  local finish = finish_once(cb)
  snacks.input({
    prompt = opts.prompt or "input",
    default = opts.default,
  }, function(value)
    if value == nil then
      finish(nil)
    elseif value == "" and not opts.allow_empty then
      finish(nil)
    else
      finish(value)
    end
  end)
end

return M
