local cli = require("jujutsu.jj.cli")

local M = {}

local TOOL = "jujutsu-nvim-merge"

---@param s string
---@return string
local function toml_basic(s)
  s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. s .. '"'
end

---@param path string
---@return string|nil
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data or ""
end

---@param root string
---@param path string
---@return string
local function abs_path(root, path)
  if path:sub(1, 1) == "/" then return path end
  if root:sub(-1) == "/" then return root .. path end
  return root .. "/" .. path
end

---@param data string|nil
---@return boolean
local function is_binary(data) return data ~= nil and data:find("\0", 1, true) ~= nil end

---@param id string|nil
---@param commit string|nil
---@return boolean
local function looks_like_rev(id, commit)
  if not id or not commit then return false end
  -- Default jj change ids are [k-z]; commit prefixes are hex. Reject marker words.
  return id:match("^[k-z]+$") ~= nil and #id >= 3 and commit:match("^[0-9a-fA-F]+$") ~= nil and #commit >= 6
end

---@param text string
---@return { change_id: string, commit_id: string, subject: string }[]
function M.parse_marker_labels(text)
  local out = {}
  local seen = {}
  local patterns = {
    'to:%s*(%w+)%s+(%w+)%s+"(.*)"',
    "to:%s*(%w+)%s+(%w+)%s+(.*)$",
    '^[<>=+%-%|]+%s+(%w+)%s+(%w+)%s+"(.*)"%s*$',
    "^[<>=+%-%|]+%s+(%w+)%s+(%w+)%s+(.*)$",
  }
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if not line:match("Contents of") and not line:match("merge base") then
      for _, pat in ipairs(patterns) do
        local id, commit, subject = line:match(pat)
        if looks_like_rev(id, commit) and not seen[id] then
          seen[id] = true
          subject = (subject or ""):gsub('^"', ""):gsub('"$', ""):gsub("%s+$", "")
          out[#out + 1] = { change_id = id, commit_id = commit, subject = subject }
          break
        end
      end
    end
  end
  return out
end

---@param root string
---@return { change_id: string, commit_id: string, subject: string }[]
local function parents_of_at(root)
  local tmpl =
    'parents.map(|p| p.change_id().short(12) ++ "\\x1f" ++ p.commit_id().short(12) ++ "\\x1f" ++ p.description().first_line()).join("\\n")'
  local res = cli.log.no_graph.revisions("@").template(tmpl).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if not res or res.code ~= 0 then return {} end
  local out = {}
  for _, line in ipairs(res.stdout or {}) do
    if line ~= "" then
      local id, commit, subject = line:match("^(.-)\x1f(.-)\x1f(.*)$")
      if id and id ~= "" then
        out[#out + 1] = {
          change_id = id,
          commit_id = commit or "",
          subject = subject or "",
        }
      end
    end
  end
  return out
end

---@param root string
---@param rev string
---@param path string
---@return string[]|nil
local function file_at(root, rev, path)
  local res = cli.file_show.revision(rev).paths(path).call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  if not res or res.code ~= 0 then return nil end
  return res.stdout or {}
end

---@param lines string[]|nil
---@param side string[]
---@return boolean
local function same_lines(lines, side)
  if not lines then return false end
  if #lines ~= #side then return false end
  for i = 1, #lines do
    if lines[i] ~= (side[i]:gsub("\r$", "")) then return false end
  end
  return true
end

---`jj resolve --list` prints `path    N-sided conflict`. The path can contain spaces.
---@param line string
---@return string|nil
function M.parse_list_line(line)
  if not line or line == "" or line:match("^Hint:") or line:match("^Error:") then return nil end
  local path = line:match("^(.-)%s+%d+%-sided conflict%s*$")
  if path and path ~= "" then return path end
  if line:match("%d+%-sided conflict") then return nil end
  return line
end

---@param root string
---@return string[] conflicts
---@return boolean ok
function M.list(root)
  local res = cli.resolve.list.call({
    cwd = root,
    hidden = true,
    on_error = function() return false end,
  })
  local conflicts = {}
  if not res then return conflicts, false end
  if res.code ~= 0 then
    -- Exit 2 with this message means the revision has no file conflicts.
    local text = table.concat(res.stderr or {}, "\n") .. "\n" .. table.concat(res.stdout or {}, "\n")
    if text:find("No conflicts found", 1, true) then return conflicts, true end
    return conflicts, false
  end
  for _, line in ipairs(res.stdout or {}) do
    local path = M.parse_list_line(line)
    if path then conflicts[#conflicts + 1] = path end
  end
  return conflicts, true
end

---Copy base/left/right for one conflicted path. Exit 1 from the tool leaves the conflict in place.
---@param root string
---@param path string
---@return table|nil sides
---@return string|nil err
function M.export(root, path)
  local dir = vim.fn.tempname() .. "-jj-merge"
  vim.fn.mkdir(dir, "p")
  if vim.fn.isdirectory(dir) ~= 1 then return nil, "Could not create a temp directory" end
  local script = dir .. "/export.sh"
  vim.fn.writefile({
    "#!/bin/sh",
    "set -eu",
    'dest="${JJNVIM_MERGE_DIR:?}"',
    'cp "$1" "$dest/base"',
    'cp "$2" "$dest/left"',
    'cp "$3" "$dest/right"',
    "exit 1",
  }, script)
  vim.fn.setfperm(script, "rwxr-xr-x")

  local res = cli.resolve
    .tool(TOOL)
    .config("merge-tools." .. TOOL .. ".program", toml_basic(script))
    .config("merge-tools." .. TOOL .. ".merge-args", '["$base","$left","$right"]')
    .paths(path)
    .env({ JJNVIM_MERGE_DIR = dir })
    .call({
      cwd = root,
      hidden = true,
      on_error = function() return false end,
    })

  local base = read_raw(dir .. "/base")
  local left = read_raw(dir .. "/left")
  local right = read_raw(dir .. "/right")
  vim.fn.delete(dir, "rf")

  if base == nil or left == nil or right == nil then
    local err = res and table.concat(res.stderr or {}, "\n") or ""
    if err == "" then err = "Could not read conflict sides for " .. path end
    return nil, err
  end

  local model = require("jujutsu.merge.model")
  local wc = read_raw(abs_path(root, path)) or ""
  local labels = M.parse_marker_labels(wc)
  local left_lines = model.split_bytes(left)
  local right_lines = model.split_bytes(right)
  local parents = parents_of_at(root)

  ---@type { side: "left"|"right", parent: table }[]
  local matched = {}
  for _, parent in ipairs(parents) do
    local lines = file_at(root, parent.change_id, path)
    if same_lines(lines, left_lines) then
      matched[#matched + 1] = { side = "left", parent = parent }
    elseif same_lines(lines, right_lines) then
      matched[#matched + 1] = { side = "right", parent = parent }
    end
  end

  -- The working-copy parent is Current. The other conflict side is Incoming.
  local incoming_side = "left"
  local current_side = "right"
  local incoming = { change_id = "", subject = "" }
  local current = { change_id = "", subject = "" }

  if #matched >= 1 then
    current_side = matched[1].side
    incoming_side = current_side == "left" and "right" or "left"
    current = { change_id = matched[1].parent.change_id, subject = matched[1].parent.subject }
  end
  if #matched >= 2 and matched[2].side ~= current_side then
    incoming_side = matched[2].side
    incoming = { change_id = matched[2].parent.change_id, subject = matched[2].parent.subject }
  end

  if incoming.change_id == "" then
    for _, label in ipairs(labels) do
      if label.change_id ~= current.change_id then
        incoming = { change_id = label.change_id, subject = label.subject }
        break
      end
    end
  end
  if current.change_id == "" then
    for _, label in ipairs(labels) do
      if label.change_id ~= incoming.change_id then
        current = { change_id = label.change_id, subject = label.subject }
        break
      end
    end
  end

  return {
    base = base,
    left = left,
    right = right,
    marker_len = model.marker_len_in(wc),
    incoming_side = incoming_side,
    current_side = current_side,
    incoming = incoming,
    current = current,
    binary = is_binary(base) or is_binary(left) or is_binary(right),
    path = path,
  }
end

return M
