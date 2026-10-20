local finder = require("jujutsu.finder")
local notify = require("jujutsu.notify")

local M = {}

---@param root string
---@param group DivergentChange
function M.open(root, group)
  if not group or not group.copies or #group.copies < 2 then
    notify.warn("This change has nothing to compare")
    return
  end
  require("jujutsu.buffers.diff").open({
    cwd = root,
    title = group.change_id,
    left = group.copies[1].commit_id,
    right = group.copies[2].commit_id,
    diverge = {
      change_id = group.change_id,
      copies = group.copies,
      left = 1,
      right = math.min(2, #group.copies),
    },
  })
end

---Pick one divergent change, then open its compare view.
---@param root string
---@param groups DivergentChange[]
function M.choose(root, groups)
  if not groups or #groups == 0 then
    notify.info("No divergent changes")
    return
  end
  if #groups == 1 then
    M.open(root, groups[1])
    return
  end
  local labels = {}
  for _, group in ipairs(groups) do
    local desc = group.copies[1] and group.copies[1].description or ""
    if desc == "" then desc = "(no description)" end
    labels[#labels + 1] = string.format("%s  (%d)  %s", group.change_id, #group.copies, desc)
  end
  local choice = finder.pick({ prompt = "Divergent change", entries = labels })
  if not choice or choice == "" then return end
  for i, label in ipairs(labels) do
    if label == choice then
      M.open(root, groups[i])
      return
    end
  end
end

return M
