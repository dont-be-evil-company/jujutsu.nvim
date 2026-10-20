local cli = require("jujutsu.jj.cli")

local M = {}

local SEP, REC = "\x1f", "\x1e"

local TEMPLATE = table.concat({
  'change_id.short(12) ++ "\\x1f" ++',
  'commit_id.short(12) ++ "\\x1f" ++',
  'bookmarks.join(",") ++ "\\x1f" ++',
  'description.first_line() ++ "\\x1e"',
}, " ")

---@class DivergentCopy
---@field commit_id string
---@field description string
---@field bookmarks string[]

---@class DivergentChange
---@field change_id string
---@field copies DivergentCopy[]

---Visible commits that share a change id.
---@param root string
---@return DivergentChange[]
function M.list(root)
  local res = cli.log.revisions("divergent()").no_graph.template(TEMPLATE).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if not res or res.code ~= 0 then return {} end

  ---@type table<string, DivergentChange>
  local by_id = {}
  local order = {}
  local text = table.concat(res.stdout or {}, "\n")
  for rec in (text .. REC):gmatch("(.-)" .. REC) do
    rec = rec:gsub("\n", "")
    if rec ~= "" and not rec:match("^Hint:") then
      local change_id, commit_id, marks, description =
        rec:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$")
      if change_id and change_id ~= "" and commit_id and commit_id ~= "" then
        local group = by_id[change_id]
        if not group then
          group = { change_id = change_id, copies = {} }
          by_id[change_id] = group
          order[#order + 1] = group
        end
        local bookmarks = {}
        if marks and marks ~= "" then bookmarks = vim.split(marks, ",", { plain = true }) end
        group.copies[#group.copies + 1] = {
          commit_id = commit_id,
          description = description or "",
          bookmarks = bookmarks,
        }
      end
    end
  end
  return order
end

---@param groups DivergentChange[]|nil
---@param change_id string|nil
---@return DivergentChange|nil
function M.find(groups, change_id)
  if not groups or not change_id or change_id == "" then return nil end
  for _, group in ipairs(groups) do
    if group.change_id == change_id then return group end
    if group.change_id:sub(1, #change_id) == change_id or change_id:sub(1, #group.change_id) == group.change_id then
      return group
    end
  end
end

return M
