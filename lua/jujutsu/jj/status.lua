local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local time = require("jujutsu.jj.time")

local M = {}

-- Build a jj template that emits fields separated by unit separator + record separator
local function field_template(fields)
  local parts = {}
  for i, f in ipairs(fields) do
    if i > 1 then
      table.insert(parts, string.format('"\\x1f" ++ %s', f))
    else
      table.insert(parts, f)
    end
  end
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e"'
end

local WC_TEMPLATE = field_template({
  "change_id.short(8)",
  "commit_id.short(8)",
  'bookmarks.join(",")',
  "description.first_line()",
  'if(conflict, "true", "false")',
  'if(empty, "true", "false")',
  'if(divergent, "true", "false")',
})

local function log_template()
  return field_template({
    "change_id.short(8)",
    "commit_id.short(8)",
    'bookmarks.join(",")',
    "description.first_line()",
    'if(conflict, "true", "false")',
    'if(empty, "true", "false")',
    time.timestamp_expr("author", "log"),
    'if(divergent, "true", "false")',
  })
end

local REAL_SEP = "\x1f"
local REAL_REC = "\x1e"

---@class ChangeInfo
---@field change_id string
---@field commit_id string
---@field bookmarks string[]
---@field description string
---@field conflict boolean
---@field empty? boolean
---@field divergent? boolean
---@field timestamp? string
---@field files? FileStatus[]

---@class FileStatus
---@field path string
---@field status string
---@field diff? string[]

---@class StatusData
---@field working_copy ChangeInfo|nil
---@field parent ChangeInfo|nil
---@field files FileStatus[]
---@field conflicts string[]
---@field divergent DivergentChange[]
---@field recent ChangeInfo[]
--luacheck: ignore
---@field bookmarks { name: string, remote: string, change_id: string, commit_id: string, description: string, target: string, conflict: boolean, deleted: boolean }[]
---@field root string

---@param line string
---@return string[]
local function split_fields(line) return vim.split(line, REAL_SEP, { plain = true }) end

---@param text string
---@return ChangeInfo[]
local function parse_records(text)
  local records = {}
  for rec in (text .. REAL_REC):gmatch("(.-)" .. REAL_REC) do
    if rec ~= "" then
      local fields = split_fields(rec:gsub("\n", ""))
      if fields[1] and fields[1] ~= "" then
        local bookmarks = {}
        if fields[3] and fields[3] ~= "" then bookmarks = vim.split(fields[3], ",", { plain = true }) end
        table.insert(records, {
          change_id = fields[1] or "",
          commit_id = fields[2] or "",
          bookmarks = bookmarks,
          description = fields[4] or "",
          conflict = fields[5] == "true",
          empty = fields[6] == "true",
          timestamp = (fields[8] == "true" or fields[8] == "false") and (fields[7] or "") or "",
          divergent = fields[8] == "true" or (not fields[8] and fields[7] == "true"),
        })
      end
    end
  end
  return records
end

---@param summary_lines string[]
---@return FileStatus[], string[]
function M.parse_diff_summary(summary_lines)
  local files = {}
  local conflicts = {}
  for _, line in ipairs(summary_lines) do
    local status, path = line:match("^([MADRC?])%s+(.+)$")
    if not status then
      status, path = line:match("^(%S+)%s+(.+)$")
    end
    if status and path then
      if status == "C" or line:lower():find("conflict") then table.insert(conflicts, path) end
      table.insert(files, { path = path, status = status:sub(1, 1) })
    end
  end
  return files, conflicts
end

---@param root string
---@param opts? { recent_limit?: integer }
---@return StatusData
function M.fetch(root, opts)
  opts = opts or {}
  local call_opts = { cwd = root, hidden = true, trim = false }

  local wc_res = cli.log.revisions("@").no_graph.template(WC_TEMPLATE).limit(1).call(call_opts)
  local parent_res = cli.log.revisions("@-").no_graph.template(WC_TEMPLATE).limit(1).call(call_opts)

  local recent_count = opts.recent_limit or config.values.status.recent_commit_count or 10
  local recent = M.log_changes(root, "ancestors(@-)", recent_count)

  local diff_res = cli.diff.summary.call(call_opts)
  local bookmarks = require("jujutsu.jj.bookmark").list(root)

  local working_copy = parse_records(table.concat(wc_res.stdout, "\n"))[1]
  local parent = parse_records(table.concat(parent_res.stdout, "\n"))[1]

  local files, conflicts_from_diff = M.parse_diff_summary(diff_res.stdout)

  local resolve_res = cli.resolve.list.call(vim.tbl_extend("force", call_opts, {
    on_error = function() return false end,
  }))
  local conflicts = {}
  local parse_conflict_path = require("jujutsu.merge.extract").parse_list_line
  for _, line in ipairs(resolve_res and resolve_res.stdout or {}) do
    local p = parse_conflict_path(line)
    if p then table.insert(conflicts, p) end
  end
  if #conflicts == 0 then conflicts = conflicts_from_diff end

  pcall(function() bookmarks = require("jujutsu.forge").annotate_bookmarks(bookmarks, root) end)

  return {
    working_copy = working_copy,
    parent = parent,
    files = files,
    conflicts = conflicts,
    divergent = require("jujutsu.jj.divergent").list(root),
    recent = recent,
    bookmarks = bookmarks,
    root = root,
  }
end

---@param root string
---@param revset string
---@param limit? integer
---@return ChangeInfo[]
function M.log_changes(root, revset, limit)
  limit = limit or config.values.status.recent_commit_count or 10
  local res = cli.log.revisions(revset).no_graph.template(log_template()).limit(limit).call({
    cwd = root,
    hidden = true,
    trim = false,
    remove_ansi = true,
  })
  if res.code ~= 0 then return {} end
  return parse_records(table.concat(res.stdout, "\n"))
end

---@param bm { name: string, remote?: string }
---@return string
function M.bookmark_ref(bm)
  if bm.remote and bm.remote ~= "" then return bm.name .. "@" .. bm.remote end
  return bm.name
end

---@param root string
---@param bm { name: string, remote?: string, change_id?: string, deleted?: boolean }
---@param limit? integer
---@return ChangeInfo[]
function M.bookmark_commits(root, bm, limit)
  if bm.deleted then return {} end
  local ref = M.bookmark_ref(bm)
  if ref == "" and bm.change_id and bm.change_id ~= "" then ref = bm.change_id end
  if not ref or ref == "" then return {} end
  return M.log_changes(root, string.format("ancestors(%s)", ref), limit)
end

---@param root string
---@param rev string
---@return FileStatus[]
function M.change_files(root, rev)
  local res = cli.diff.revision(rev).summary.call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 then return {} end
  local files = M.parse_diff_summary(res.stdout)
  return files
end

---@param root string
---@param path string
---@param rev? string
---@return string[]
function M.file_diff(root, path, rev)
  -- Prefer git-format so lines start with +/-/@@ (needed for coloring)
  local builder = rev and cli.diff.revision(rev).git.paths(path) or cli.diff.git.paths(path)
  local res = builder.call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 or #res.stdout == 0 then
    builder = rev and cli.diff.revision(rev).paths(path) or cli.diff.paths(path)
    res = builder.call({ cwd = root, hidden = true, remove_ansi = true })
  end
  return res.stdout
end

return M
