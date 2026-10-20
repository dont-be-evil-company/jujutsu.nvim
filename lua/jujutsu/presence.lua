---@class JujutsuPresence
---@field kind string
---@field root? string
---@field path? string
---@field revision? string
---@field label string

local M = {}

---@param s string|nil
---@return string|nil
local function decode(s)
  if not s then return s end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

---@param bufnr integer
---@param buffer { bufnr: integer }|nil
---@return boolean
local function buf_matches(bufnr, buffer) return buffer ~= nil and buffer.bufnr == bufnr end

---@param name string
---@return JujutsuPresence|nil
local function parse_uri(name)
  local rest = name:match("^jujutsu://(.+)$")
  if not rest then return nil end

  local head, tail = rest:match("^([^/]+)/(.*)$")
  if not head then
    head, tail = rest, nil
  end

  if head == "status" then
    return { kind = "status", label = "status" }
  elseif head == "log" then
    return { kind = "log", label = "log", revision = tail }
  elseif head == "op-log" then
    return { kind = "op_log", label = "op-log" }
  elseif head == "stat" then
    return { kind = "stat", label = "stat", revision = tail }
  elseif head == "describe" then
    return { kind = "describe", label = "describe", revision = tail }
  elseif head == "history" then
    return { kind = "history", label = "history" }
  elseif head == "process" then
    return { kind = "process", label = "process" }
  elseif head == "workspaces" then
    return { kind = "workspaces", label = "workspaces" }
  elseif head == "remotes" then
    return { kind = "remotes", label = "remotes" }
  elseif head == "popup" then
    return { kind = "popup", label = tail or "popup" }
  elseif head == "ci" then
    return { kind = "ci", label = "ci" }
  elseif head == "issue" then
    local kind, number = (tail or ""):match("^([^/]+)/(.+)$")
    return {
      kind = "issue",
      label = (kind and number) and (kind .. " #" .. number) or "issue",
    }
  elseif head == "review-comment" or head == "markdown-scratch" then
    return { kind = "review", label = "review" }
  elseif head == "file-history" then
    local presence = { kind = "file_history", label = "file-history" }
    local desc_id = tail and tail:match("^desc/(.+)$")
    if desc_id then presence.revision = desc_id end
    return presence
  elseif head == "annotate" then
    local presence = { kind = "annotate", label = "annotate" }
    local path = tail
    if path and path:match("^panel/") then path = path:sub(7) end
    if path and path ~= "" then presence.path = decode(path) end
    return presence
  elseif head == "merge" then
    local role, path = (tail or ""):match("^([^/]+)/(.+)$")
    return {
      kind = "merge",
      label = role or "merge",
      path = path and decode(path) or nil,
    }
  elseif head == "diff" then
    local presence = { kind = "diff", label = "diff" }
    tail = tail or ""
    local panel_title = tail:match("^panel/(.*)$")
    local desc_rev = tail:match("^desc/(.*)$")
    local titled_title, titled_file = tail:match("^([^/]+)/[ab]/(.*)$")
    local titled_empty = tail:match("^([^/]+)/[ab]$")
    local fh_file = tail:match("^[ab]/(.*)$")

    if panel_title then
      presence.revision = decode(panel_title)
      presence.label = presence.revision or "diff"
    elseif desc_rev then
      presence.revision = decode(desc_rev)
    elseif titled_file then
      presence.revision = decode(titled_title)
      presence.path = decode(titled_file)
    elseif titled_empty then
      presence.revision = decode(titled_empty)
    elseif fh_file then
      presence.path = decode(fh_file)
    end
    return presence
  end

  return { kind = head, label = head }
end

---@param presence JujutsuPresence
---@param bufnr integer
local function enrich_status(presence, bufnr)
  local ok, status = pcall(require, "jujutsu.buffers.status")
  if not ok then return end
  local inst = status.instance and status.instance()
  if not inst or not buf_matches(bufnr, inst.buf) then return end
  presence.root = inst.root or presence.root
  if vim.api.nvim_get_current_buf() ~= bufnr then return end
  local env = status.get_env and status.get_env()
  if not env then return end
  presence.path = env.path or presence.path
  presence.revision = env.commit or presence.revision
end

---@param presence JujutsuPresence
---@param bufnr integer
local function enrich_diff(presence, bufnr)
  local ok, diff = pcall(require, "jujutsu.buffers.diff")
  if not ok then return end
  local inst = diff.instance and diff.instance()
  if not inst then return end
  local belongs = buf_matches(bufnr, inst.panel_buf)
    or (inst.split and (buf_matches(bufnr, inst.split.left_buf) or buf_matches(bufnr, inst.split.right_buf)))
  if not belongs then return end
  presence.root = inst.root or presence.root
  presence.path = inst.selected_path or presence.path
  presence.revision = inst.right_rev or inst.title or presence.revision
end

---@param presence JujutsuPresence
---@param bufnr integer
local function enrich_annotate(presence, bufnr)
  local ok, annotate = pcall(require, "jujutsu.buffers.annotate")
  if not ok then return end
  local inst = annotate.instance and annotate.instance()
  if not inst then return end
  local belongs = buf_matches(bufnr, inst.view and inst.view.buf) or buf_matches(bufnr, inst.panel and inst.panel.buf)
  if not belongs then return end
  presence.root = inst.root or presence.root
  presence.path = inst.path or presence.path
end

---@param presence JujutsuPresence
---@param bufnr integer
local function enrich_file_history(presence, bufnr)
  local ok, fh = pcall(require, "jujutsu.buffers.file_history")
  if not ok then return end
  local inst = fh.instance and fh.instance()
  if not inst then return end
  local belongs = buf_matches(bufnr, inst.panel and inst.panel.buf)
    or (inst.diff and (buf_matches(bufnr, inst.diff.left_buf) or buf_matches(bufnr, inst.diff.right_buf)))
  if not belongs then return end
  presence.root = inst.root or presence.root
  if inst.panel then
    presence.path = inst.panel.selected_path or inst.panel.path or presence.path
    presence.revision = inst.panel.selected_change or presence.revision
  end
end

---@param presence JujutsuPresence
local function enrich_root(presence)
  if presence.root then return end
  local ok, repo = pcall(require, "jujutsu.jj.repository")
  if ok and repo.root then presence.root = repo.root() end
end

---Describe what the user is currently looking at in the jujutsu UI.
---@param bufnr? integer
---@return JujutsuPresence|nil
function M.get_presence(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  local presence = parse_uri(vim.api.nvim_buf_get_name(bufnr))
  if not presence then return nil end

  if presence.kind == "status" then
    enrich_status(presence, bufnr)
  elseif presence.kind == "diff" then
    enrich_diff(presence, bufnr)
    -- File-history split sides also use jujutsu://diff/a|b/...
    if not presence.root then enrich_file_history(presence, bufnr) end
  elseif presence.kind == "annotate" then
    enrich_annotate(presence, bufnr)
  elseif presence.kind == "file_history" then
    enrich_file_history(presence, bufnr)
  else
    enrich_root(presence)
  end

  enrich_root(presence)
  return presence
end

return M
