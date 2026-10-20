local config = require("jujutsu.config")

local M = {}

---@param bufnr integer
---@param map_set string  -- "status" | "popup" | "log_view" | "finder" | "commit_editor" | "merge"
---@param actions table<string, function|string>
---@param opts? { buffer?: integer, mode?: string }
function M.apply(bufnr, map_set, actions, opts)
  opts = opts or {}

  local maps = config.values.mappings[map_set] or {}
  local mode = opts.mode or "n"

  for key, action_name in pairs(maps) do
    if action_name and action_name ~= false then
      local fn = actions[action_name]
      if type(action_name) == "function" then fn = action_name end
      if fn then
        vim.keymap.set(mode, key, fn, {
          buffer = bufnr,
          silent = true,
          noremap = true,
          desc = "jujutsu: " .. (type(action_name) == "string" and action_name or "custom"),
        })
      end
    end
  end
end

---@param popup_name string  e.g. "ChangePopup" -> require popups.change
local popup_module = {
  HelpPopup = "help",
  BookmarkPopup = "bookmark",
  ChangePopup = "change",
  DiffPopup = "diff",
  FetchPopup = "fetch",
  ForgePopup = "forge",
  LogPopup = "log",
  RemotePopup = "remote",
  PushPopup = "push",
  RebasePopup = "rebase",
  SquashPopup = "squash",
  SplitPopup = "split",
  UndoPopup = "undo",
  WorkspacePopup = "workspace",
}

---@param bufnr integer
---@param get_env? fun(): table
function M.apply_popup_maps(bufnr, get_env)
  local maps = config.values.mappings.popup or {}
  for key, action_name in pairs(maps) do
    if action_name then
      local mod = popup_module[action_name]
      if mod then
        vim.keymap.set("n", key, function()
          local env = get_env and get_env() or {}
          require("jujutsu.popups." .. mod).create(env)
        end, {
          buffer = bufnr,
          silent = true,
          noremap = true,
          desc = "jujutsu: " .. action_name,
        })
      end
    end
  end
end

return M
