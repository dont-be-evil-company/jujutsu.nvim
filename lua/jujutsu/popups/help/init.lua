local builder = require("jujutsu.popup.builder")
local config = require("jujutsu.config")

local M = {}

function M.create(env)
  local status_maps = config.values.mappings.status or {}
  local popup_maps = config.values.mappings.popup or {}

  local b = builder.builder():name("HelpPopup"):group_heading("Popups")
  for key, name in pairs(popup_maps) do
    if name then b:action(key, tostring(name), function() end, { persist_popup = true }) end
  end
  b:new_action_group("Status")
  -- Show a sample of useful status mappings
  local order = { "q", "<c-r>", "<tab>", "x", "R", "D", "E", "O", "B", "F", "P", "S", "o", "<cr>", "1", "2", "3", "4" }
  for _, key in ipairs(order) do
    local name = status_maps[key]
    if name then b:action(key, tostring(name), function() end, { persist_popup = true }) end
  end
  local p = b:env(env or {}):build()
  p:show()
  return p
end

return M
