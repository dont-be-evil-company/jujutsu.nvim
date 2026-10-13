local M = {}

local function finish_once(cb)
  local delivered = false
  return function(value)
    if delivered then return end
    delivered = true
    cb(value)
  end
end

---@param opts { prompt?: string, entries: string[], allow_multi?: boolean, allow_free_text?: boolean }
---@param cb fun(item: string|string[]|nil)
function M.pick(opts, cb)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local finish = finish_once(cb)
  local choosing = false

  pickers
    .new({}, {
      prompt_title = opts.prompt or "select",
      finder = finders.new_table({ results = opts.entries or {} }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        local pickers_mod = require("jujutsu.integrations.pickers")
        local win = vim.api.nvim_get_current_win()
        pickers_mod.claim(win, "insert")
        pcall(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          if not picker then return end
          for _, key in ipairs({ "prompt_win", "results_win", "preview_win" }) do
            if picker[key] then pickers_mod.raise(picker[key]) end
          end
        end)
        vim.api.nvim_create_autocmd("WinClosed", {
          pattern = tostring(win),
          once = true,
          callback = function()
            vim.schedule(function()
              if not choosing then finish(nil) end
            end)
          end,
        })
        actions.select_default:replace(function()
          choosing = true
          local picker = action_state.get_current_picker(prompt_bufnr)
          local query = action_state.get_current_line() or ""
          local value
          if opts.allow_multi then
            local multi = picker:get_multi_selection() or {}
            local out = {}
            for _, entry in ipairs(multi) do
              local text = entry.value or entry.ordinal or entry[1]
              if text and text ~= "" then out[#out + 1] = text end
            end
            if #out == 0 then
              local current = action_state.get_selected_entry()
              if current then out[1] = current.value or current.ordinal or current[1] end
            end
            value = #out > 0 and out or nil
          else
            local current = action_state.get_selected_entry()
            if current then value = current.value or current.ordinal or current[1] end
          end
          if (value == nil or value == "") and opts.allow_free_text then
            local trimmed = vim.trim(query)
            if trimmed ~= "" then value = trimmed end
          end
          actions.close(prompt_bufnr)
          vim.schedule(function() finish(value) end)
        end)
        return true
      end,
    })
    :find()
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
  end)
end

return M
