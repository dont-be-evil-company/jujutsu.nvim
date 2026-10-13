local M = {}

local function finish_once(cb)
  local delivered = false
  return function(value)
    if delivered then return end
    delivered = true
    cb(value)
  end
end

local function current_query()
  local ok, picker = pcall(require("mini.pick").get_picker_opts)
  if not ok or type(picker) ~= "table" then return "" end
  local query = picker.query
  if type(query) == "string" then return query end
  if type(query) == "table" then return table.concat(query, "") end
  return ""
end

---@param opts { prompt?: string, entries: string[], allow_multi?: boolean, allow_free_text?: boolean }
---@param cb fun(item: string|string[]|nil)
---@param input_mode? boolean
function M.pick(opts, cb, input_mode)
  local MiniPick = require("mini.pick")
  local finish = finish_once(cb)
  local choosing = false
  local mappings = nil
  if opts.allow_free_text or input_mode then
    mappings = {
      accept_query = {
        char = "<C-y>",
        func = function()
          local query = vim.trim(current_query())
          if query == "" and not input_mode then return end
          choosing = true
          finish(query)
          pcall(MiniPick.stop)
        end,
      },
    }
  end

  MiniPick.start({
    source = {
      items = opts.entries or {},
      name = opts.prompt or "select",
      choose = function(item)
        choosing = true
        finish(item)
      end,
      choose_marked = opts.allow_multi and function(items)
        choosing = true
        finish(items)
      end or nil,
    },
    mappings = mappings,
  })

  local state = MiniPick.get_picker_state()
  local windows = state and state.windows or {}
  local mod = require("jujutsu.integrations.pickers")
  local prompt = windows.prompt or windows.input or windows.main
  -- mini.pick handles keys itself; insert mode would swallow them.
  if type(prompt) == "number" then mod.claim(prompt, "window") end
  for _, id in pairs(windows) do
    if type(id) == "number" then mod.raise(id) end
  end
  local main = windows.main
  if main then
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(main),
      once = true,
      callback = function()
        vim.schedule(function()
          if not choosing then finish(nil) end
        end)
      end,
    })
  end
end

---@param opts { prompt?: string, default?: string, allow_empty?: boolean }
---@param cb fun(value: string|nil)
function M.input(opts, cb)
  local entries = {}
  if opts.default and opts.default ~= "" then entries[1] = opts.default end
  M.pick({
    prompt = opts.prompt or "input",
    entries = entries,
    allow_free_text = true,
  }, function(value)
    if type(value) == "table" then value = value[1] end
    if value == nil then
      cb(nil)
    elseif value == "" and not opts.allow_empty then
      cb(nil)
    else
      cb(value)
    end
  end, true)
end

return M
