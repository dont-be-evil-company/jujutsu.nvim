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

local function apply_items(picker, texts)
  local items = items_from(texts)
  local list = picker and picker.list
  if type(list) == "table" then
    if type(list.set_items) == "function" then
      list:set_items(items)
      return
    end
    list.items = items
    if type(list.update) == "function" then list:update() end
  end
  if picker and type(picker.update) == "function" then picker:update() end
end

---@param opts { prompt?: string, entries: string[], allow_multi?: boolean, allow_free_text?: boolean, on_load_more?: fun(current: string[]): string[]|nil }
---@param cb fun(item: string|string[]|nil)
function M.pick(opts, cb)
  local finish = finish_once(cb)
  local choosing = false
  local entries = opts.entries or {}
  local picker_opts = {
    title = opts.prompt or "select",
    items = items_from(entries),
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
      if type(opts.on_load_more) == "function" and type(input_win) == "number" then
        local bufnr = vim.api.nvim_win_get_buf(input_win)
        if vim.api.nvim_buf_is_valid(bufnr) and not vim.b[bufnr].jujutsu_load_more then
          vim.b[bufnr].jujutsu_load_more = true
          local function load_more()
            local next_entries = opts.on_load_more(entries)
            if type(next_entries) ~= "table" then return end
            entries = next_entries
            opts.entries = entries
            apply_items(picker, entries)
          end
          local map_opts = { buffer = bufnr, silent = true, nowait = true, noremap = true }
          vim.keymap.set({ "n", "i" }, "<C-+>", load_more, map_opts)
          vim.keymap.set("n", "+", load_more, map_opts)
        end
      end
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
  }
  run_picker(picker_opts)
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
