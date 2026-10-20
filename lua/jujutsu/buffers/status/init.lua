local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local mappings = require("jujutsu.ui.mappings")
local notify = require("jujutsu.notify")
local status_data = require("jujutsu.jj.status")
local watcher = require("jujutsu.watcher")

---@class StatusItem
--luacheck: ignore
---@field type string  -- "section" | "file" | "change_file" | "change" | "bookmark" | "conflict" | "divergent" | "header" | "diff" | "hint" | "load_more"
---@field text string
---@field hl? string
---@field line_hl? string  -- full-line highlight group (diff backgrounds)
---@field highlights? { col: integer, end_col: integer, hl: string }[]
---@field data? table
---@field folded? boolean
---@field depth? integer

local M = {}

---@param path string
---@param how string
---@return boolean
local function open_in_host(path, how)
  local host = require("jujutsu.ui.host")
  if not host.active() then return false end
  host.open_file(path, how)
  return true
end

--luacheck: ignore
---@type { buf: table, root: string, data: StatusData|nil, items: StatusItem[], line_map: table<integer, StatusItem>, folds: table<string, boolean>, open_diffs: table<string, boolean>, open_changes: table<string, boolean>, open_bookmarks: table<string, boolean>, bookmark_limits: table<string, integer>, recent_limit: integer, refreshing: boolean }|nil
local instance

local function default_commit_limit() return config.values.status.recent_commit_count or 10 end

---@param key string
---@return integer
local function bookmark_commit_limit(key)
  return (instance.bookmark_limits and instance.bookmark_limits[key]) or default_commit_limit()
end

local function status_hl(st) return require("jujutsu.hl").file_status(st) end

local function mode_text(st)
  local t = config.values.status.mode_text
    or {
      M = "modified",
      A = "added",
      D = "deleted",
      R = "renamed",
      C = "copied",
      ["?"] = "untracked",
      N = "new file",
    }
  return t[st] or st
end

---@param dline string
---@return string
local function diff_line_hl(dline)
  local first = dline:sub(1, 1)
  if dline:match("^@@") then
    return "JujutsuHunkHeader"
  elseif dline:match("^diff ") or dline:match("^index ") or dline:match("^%-%-%-") or dline:match("^%+%+%+") then
    return "JujutsuDiffHeader"
  elseif first == "+" then
    return "JujutsuDiffAdd"
  elseif first == "-" then
    return "JujutsuDiffDelete"
  end
  return "JujutsuDiffContext"
end

---@param change_id string
---@param path string
---@return string
local function change_diff_key(change_id, path) return "#" .. change_id .. "/" .. path end

---@param change_id string
local function clear_change_diffs(change_id)
  local prefix = "#" .. change_id .. "/"
  for key in pairs(instance.open_diffs) do
    if key:sub(1, #prefix) == prefix then instance.open_diffs[key] = nil end
  end
end

---@param change ChangeInfo
local function load_change_files(change)
  change.files = status_data.change_files(instance.root, change.change_id)
  for _, file in ipairs(change.files) do
    local key = change_diff_key(change.change_id, file.path)
    if instance.open_diffs[key] then file.diff = status_data.file_diff(instance.root, file.path, change.change_id) end
  end
end

---@param change ChangeInfo
local function sync_change_files(change)
  local id = change.change_id
  local files = change.files
  for _, c in ipairs(instance.data.recent or {}) do
    if c.change_id == id then c.files = files end
  end
  for _, bm in ipairs(instance.data.bookmarks or {}) do
    for _, c in ipairs(bm.commits or {}) do
      if c.change_id == id then c.files = files end
    end
  end
end

---@param bm { name: string, remote?: string }
---@return string
local function bookmark_key(bm) return status_data.bookmark_ref(bm) end

---@param bm table
local function load_bookmark_commits(bm)
  local key = bookmark_key(bm)
  local limit = bookmark_commit_limit(key)
  bm.commits = status_data.bookmark_commits(instance.root, bm, limit)
  for _, change in ipairs(bm.commits) do
    if instance.open_changes[change.change_id] then load_change_files(change) end
  end
end

local function clear_item_diffs()
  instance.open_diffs = {}
  instance.open_changes = {}
  instance.open_bookmarks = {}
end

---@param add fun(item: StatusItem)
---@param file FileStatus
---@param opts { indent?: string, item_type?: string, change?: ChangeInfo, open_key?: string, bookmark_key?: string }
local function add_file_with_diff(add, file, opts)
  opts = opts or {}
  local indent = opts.indent or "  "
  local item_type = opts.item_type or "file"
  local open_key = opts.open_key or file.path
  local open = instance.open_diffs[open_key]
  local isign = (config.values.signs.item or { ">", "v" })[open and 2 or 1]
  local mode = mode_text(file.status)
  local text = string.format("%s%s %s %s", indent, isign, mode, file.path)
  local col_sign = #indent
  local col_mode = col_sign + #isign + 1
  add({
    type = item_type,
    text = text,
    highlights = {
      { col = col_sign, end_col = col_sign + #isign, hl = "JujutsuFold" },
      { col = col_mode, end_col = col_mode + #mode, hl = status_hl(file.status) },
    },
    data = { file = file, change = opts.change, diff_key = open_key, bookmark_key = opts.bookmark_key },
  })
  if open and file.diff then
    local diff_indent = indent .. "  "
    for di, dline in ipairs(file.diff) do
      add({
        type = "diff",
        text = diff_indent .. dline,
        line_hl = diff_line_hl(dline),
        data = {
          file = file,
          change = opts.change,
          diff_index = di,
          diff_key = open_key,
          bookmark_key = opts.bookmark_key,
        },
      })
    end
  end
end

---@param parts string[]
---@param highlights { col: integer, end_col: integer, hl: string }[]
---@param col integer
---@param change ChangeInfo
local function append_divergent(parts, highlights, col, change)
  if not change.divergent then return end
  local mark = " (divergent)"
  table.insert(parts, mark)
  table.insert(highlights, { col = col, end_col = col + #mark, hl = "JujutsuDivergent" })
end

---@param add fun(item: StatusItem)
---@param change ChangeInfo
---@param opts? { indent?: string, file_indent?: string, bookmark_key?: string }
local function add_change_row(add, change, opts)
  opts = opts or {}
  local indent = opts.indent or "  "
  local file_indent = opts.file_indent or (indent .. "    ")
  local open = instance.open_changes[change.change_id]
  local isign = (config.values.signs.item or { ">", "v" })[open and 2 or 1]
  local highlights = {}
  local parts = { indent, isign, " " }
  local col = #indent

  table.insert(highlights, { col = col, end_col = col + #isign, hl = "JujutsuFold" })
  col = col + #isign + 1

  table.insert(parts, change.change_id)
  table.insert(highlights, { col = col, end_col = col + #change.change_id, hl = "JujutsuChangeIdPrefix" })
  col = col + #change.change_id

  table.insert(parts, " ")
  col = col + 1
  table.insert(parts, change.commit_id)
  table.insert(highlights, { col = col, end_col = col + #change.commit_id, hl = "JujutsuCommitId" })
  col = col + #change.commit_id

  if change.timestamp and change.timestamp ~= "" then
    table.insert(parts, " ")
    col = col + 1
    table.insert(parts, change.timestamp)
    table.insert(highlights, { col = col, end_col = col + #change.timestamp, hl = "JujutsuSubtle" })
    col = col + #change.timestamp
  end

  if #change.bookmarks > 0 then
    for _, bm in ipairs(change.bookmarks) do
      table.insert(parts, " ")
      col = col + 1
      table.insert(parts, bm)
      table.insert(highlights, { col = col, end_col = col + #bm, hl = "JujutsuBranch" })
      col = col + #bm
    end
  end

  table.insert(parts, " ")
  col = col + 1
  local desc = change.description ~= "" and change.description or "(no description set)"
  table.insert(parts, desc)
  table.insert(highlights, {
    col = col,
    end_col = col + #desc,
    hl = change.description ~= "" and "JujutsuDescription" or "JujutsuSubtle",
  })
  col = col + #desc
  append_divergent(parts, highlights, col, change)

  add({
    type = "change",
    text = table.concat(parts),
    highlights = highlights,
    data = { change = change, bookmark_key = opts.bookmark_key },
  })

  if open then
    local files = change.files or {}
    if #files == 0 then
      add({ type = "hint", text = file_indent .. "(empty)", hl = "JujutsuSubtle" })
    else
      for _, file in ipairs(files) do
        add_file_with_diff(add, file, {
          indent = file_indent,
          item_type = "change_file",
          change = change,
          open_key = change_diff_key(change.change_id, file.path),
          bookmark_key = opts.bookmark_key,
        })
      end
    end
  end
end

---@param add fun(item: StatusItem)
---@param bm table
local function add_bookmark_row(add, bm)
  local key = bookmark_key(bm)
  local can_expand = not bm.deleted and ((bm.change_id and bm.change_id ~= "") or key ~= "")
  local open = can_expand and instance.open_bookmarks[key]
  local isign = can_expand and (config.values.signs.item or { ">", "v" })[open and 2 or 1] or " "
  local name = key
  local pr = bm.pr and string.format(" #%d", bm.pr) or ""
  local detail = string.format("%s %s %s", bm.change_id or "", bm.commit_id or "", bm.description or "")
  local text = string.format("  %s %s%s %s", isign, name, pr, detail)
  local name_hl = bm.remote ~= "" and "JujutsuRemoteBranch" or "JujutsuBranch"
  local col_sign = 2
  local col_name = col_sign + #isign + 1
  local highlights = {
    { col = col_sign, end_col = col_sign + #isign, hl = "JujutsuFold" },
    { col = col_name, end_col = col_name + #name, hl = name_hl },
  }
  if pr ~= "" then
    table.insert(highlights, {
      col = col_name + #name,
      end_col = col_name + #name + #pr,
      hl = "JujutsuForgePR",
    })
  end
  table.insert(highlights, {
    col = col_name + #name + #pr + 1,
    end_col = #text,
    hl = "JujutsuObjectId",
  })
  if bm.divergent then
    local mark = " (divergent)"
    text = text .. mark
    table.insert(highlights, { col = #text - #mark, end_col = #text, hl = "JujutsuDivergent" })
  end
  add({
    type = "bookmark",
    text = text,
    highlights = highlights,
    data = { bookmark = bm, bookmark_key = key, can_expand = can_expand },
  })

  if open then
    local commits = bm.commits or {}
    if #commits == 0 then
      add({ type = "hint", text = "      (no commits)", hl = "JujutsuSubtle" })
    else
      for _, change in ipairs(commits) do
        add_change_row(add, change, {
          indent = "      ",
          file_indent = "          ",
          bookmark_key = key,
        })
      end
      local limit = bookmark_commit_limit(key)
      if #commits >= limit then
        local next_limit = limit * 2
        add({
          type = "load_more",
          text = string.format("      + Load more… (%d → %d)", limit, next_limit),
          hl = "JujutsuHint",
          data = {
            section = "bookmark",
            bookmark = bm,
            bookmark_key = key,
            next_limit = next_limit,
          },
        })
      end
    end
  end
end

---@param change ChangeInfo
---@param label string
---@return string, { col: integer, end_col: integer, hl: string }[]
local function format_change_line(change, label)
  local highlights = {}
  local pad = config.values.status.HEAD_padding or 10
  local parts = {}

  local label_text = string.format("%-" .. pad .. "s", label)
  table.insert(parts, label_text)
  table.insert(highlights, {
    col = 0,
    end_col = #label_text,
    hl = label == "Change" and "JujutsuWorkingCopy" or "JujutsuHeaderLabel",
  })

  local col = #label_text + 1 -- space after label
  table.insert(parts, " ")

  local change_id = change.change_id
  table.insert(parts, change_id)
  table.insert(highlights, { col = col, end_col = col + #change_id, hl = "JujutsuChangeIdPrefix" })
  col = col + #change_id

  if config.values.status.show_head_commit_hash then
    table.insert(parts, " ")
    col = col + 1
    local commit_id = change.commit_id
    table.insert(parts, commit_id)
    table.insert(highlights, { col = col, end_col = col + #commit_id, hl = "JujutsuCommitId" })
    col = col + #commit_id
  end

  if change.bookmarks and #change.bookmarks > 0 then
    for _, bm in ipairs(change.bookmarks) do
      table.insert(parts, " ")
      col = col + 1
      table.insert(parts, bm)
      table.insert(highlights, { col = col, end_col = col + #bm, hl = "JujutsuBranch" })
      col = col + #bm
    end
  end

  table.insert(parts, " ")
  col = col + 1
  local desc = change.description ~= "" and change.description or "(no description set)"
  table.insert(parts, desc)
  table.insert(highlights, {
    col = col,
    end_col = col + #desc,
    hl = change.description ~= "" and "JujutsuDescription" or "JujutsuSubtle",
  })
  col = col + #desc
  append_divergent(parts, highlights, col, change)

  return table.concat(parts), highlights
end

local function ensure_folds()
  if not instance then return end
  local sections = config.values.sections
  instance.folds = instance.folds
    or {
      files = sections.files.folded,
      conflicts = sections.conflicts.folded,
      recent = sections.recent.folded,
      divergent = sections.divergent and sections.divergent.folded,
      bookmarks = sections.bookmarks.folded,
      head = config.values.status.HEAD_folded,
    }
  instance.open_diffs = instance.open_diffs or {}
  instance.open_changes = instance.open_changes or {}
  instance.open_bookmarks = instance.open_bookmarks or {}
  instance.bookmark_limits = instance.bookmark_limits or {}
end

---@return StatusItem[], table<integer, StatusItem>
local function build_items()
  local data = instance.data
  local items = {}
  local line_map = {}
  ensure_folds()

  local function add(item) table.insert(items, item) end

  if not config.values.disable_hint then
    add({
      type = "hint",
      text = "Hint: ? help  |  c change  |  b bookmark  |  l log  |  p push  |  u undo  |  + more  |  <tab> fold  |  q quit",
      hl = "JujutsuHint",
    })
    add({ type = "blank", text = "" })
  end

  -- Working copy / parent headers
  if data.working_copy then
    local text, highlights = format_change_line(data.working_copy, "Change")
    add({
      type = "header",
      text = text,
      highlights = highlights,
      data = { change = data.working_copy, kind = "working_copy" },
    })
  end
  if data.parent then
    local text, highlights = format_change_line(data.parent, "Parent")
    add({
      type = "header",
      text = text,
      highlights = highlights,
      data = { change = data.parent, kind = "parent" },
    })
  end
  add({ type = "blank", text = "" })

  local function section(key, title, count, render_body)
    local sec = config.values.sections[key]
    if sec and sec.hidden then return end
    local folded = instance.folds[key]
    local sign = (config.values.signs.section or { ">", "v" })[folded and 1 or 2]
    local count_text = string.format("(%d)", count)
    local text = string.format("%s %s %s", sign, title, count_text)
    local highlights = {
      { col = 0, end_col = #sign, hl = "JujutsuFold" },
      { col = #sign + 1, end_col = #sign + 1 + #title, hl = "JujutsuSectionHeader" },
      {
        col = #sign + 1 + #title + 1,
        end_col = #text,
        hl = "JujutsuSectionCount",
      },
    }
    add({
      type = "section",
      text = text,
      highlights = highlights,
      data = { section = key },
      folded = folded,
    })
    if not folded then render_body() end
    add({ type = "blank", text = "" })
  end

  -- Conflicts
  if #data.conflicts > 0 then
    section("conflicts", "Conflicts", #data.conflicts, function()
      local resolve_key
      for key, action in pairs(config.values.mappings.status or {}) do
        if action == "Resolve" then
          resolve_key = key
          break
        end
      end
      if resolve_key then
        add({
          type = "hint",
          text = "    " .. resolve_key .. " resolve in the merge editor",
          hl = "JujutsuHint",
        })
      end
      for _, path in ipairs(data.conflicts) do
        add({
          type = "conflict",
          text = "    " .. path,
          hl = "JujutsuConflict",
          data = { path = path },
        })
      end
    end)
  end

  -- Divergent changes (same change id, more than one commit)
  local divergent = data.divergent or {}
  if #divergent > 0 then
    section("divergent", "Divergent", #divergent, function()
      local resolve_key
      for key, action in pairs(config.values.mappings.status or {}) do
        if action == "Resolve" then
          resolve_key = key
          break
        end
      end
      if resolve_key then
        add({
          type = "hint",
          text = "    " .. resolve_key .. " compare copies and keep one",
          hl = "JujutsuHint",
        })
      end
      for _, group in ipairs(divergent) do
        local desc = group.copies[1] and group.copies[1].description or ""
        local same = true
        for _, copy in ipairs(group.copies) do
          if copy.description ~= desc then
            same = false
            break
          end
        end
        if desc == "" then desc = "(no description)" end
        if not same then desc = "descriptions differ" end
        local count = string.format("(%d)", #group.copies)
        local text = string.format("    %s  %s  %s", group.change_id, count, desc)
        local id_end = 4 + #group.change_id
        add({
          type = "divergent",
          text = text,
          highlights = {
            { col = 4, end_col = id_end, hl = "JujutsuChangeIdPrefix" },
            { col = id_end + 2, end_col = id_end + 2 + #count, hl = "JujutsuDivergent" },
            { col = id_end + 2 + #count + 2, end_col = #text, hl = same and "JujutsuDescription" or "JujutsuSubtle" },
          },
          data = { divergent = group, change = { change_id = group.change_id, divergent = true } },
        })
      end
    end)
  end

  -- Files
  section("files", "Working copy changes", #data.files, function()
    if #data.files == 0 then
      add({ type = "hint", text = "    (empty)", hl = "JujutsuHint" })
      return
    end
    for _, file in ipairs(data.files) do
      add_file_with_diff(add, file, { indent = "  ", item_type = "file" })
    end
  end)

  -- Recent
  section("recent", "Recent commits", #data.recent, function()
    for _, change in ipairs(data.recent) do
      add_change_row(add, change)
    end
    local limit = instance.recent_limit or default_commit_limit()
    if #data.recent >= limit then
      local next_limit = limit * 2
      local label = string.format("    + Load more… (%d → %d)", limit, next_limit)
      add({
        type = "load_more",
        text = label,
        hl = "JujutsuHint",
        data = { section = "recent", next_limit = next_limit },
      })
    end
  end)

  -- Bookmarks
  local show_remote = config.values.sections.bookmarks.show_remote ~= false
  local show_deleted = config.values.sections.bookmarks.show_deleted ~= false
  local visible_bms = {}
  for _, bm in ipairs(data.bookmarks) do
    if bm.remote ~= "git" and (show_remote or bm.remote == "") and (show_deleted or not bm.deleted) then
      table.insert(visible_bms, bm)
    end
  end
  table.sort(visible_bms, function(a, b)
    local a_remote = a.remote ~= ""
    local b_remote = b.remote ~= ""
    if a_remote ~= b_remote then return not a_remote end
    if a.timestamp ~= b.timestamp then return (a.timestamp or "") > (b.timestamp or "") end
    return a.name < b.name
  end)
  section("bookmarks", "Bookmarks", #visible_bms, function()
    for _, bm in ipairs(visible_bms) do
      add_bookmark_row(add, bm)
    end
  end)

  for i, item in ipairs(items) do
    line_map[i] = item
  end
  return items, line_map
end

local function redraw()
  if not instance or not Buffer.is_open(instance.buf) then return end
  local items, line_map = build_items()
  instance.items = items
  instance.line_map = line_map
  local lines = {}
  local highlights = {}
  for i, item in ipairs(items) do
    lines[i] = item.text
    if item.line_hl then table.insert(highlights, {
      line = i - 1,
      line_hl = item.line_hl,
    }) end
    if item.highlights then
      for _, h in ipairs(item.highlights) do
        table.insert(highlights, {
          line = i - 1,
          col = h.col,
          end_col = h.end_col,
          hl = h.hl,
        })
      end
    elseif item.hl and item.text ~= "" then
      table.insert(highlights, {
        line = i - 1,
        col = 0,
        end_col = #item.text,
        hl = item.hl,
      })
    end
  end
  local cursor = { 1, 0 }
  if instance.buf.winid and vim.api.nvim_win_is_valid(instance.buf.winid) then
    cursor = vim.api.nvim_win_get_cursor(instance.buf.winid)
  end
  Buffer.render(instance.buf, lines, highlights)
  if instance.buf.winid and vim.api.nvim_win_is_valid(instance.buf.winid) then
    local max = math.max(1, #lines)
    local row = math.min(cursor[1], max)
    pcall(vim.api.nvim_win_set_cursor, instance.buf.winid, { row, 0 })
  end
end

function M.refresh()
  if not instance or instance.refreshing then return end
  instance.refreshing = true
  async.void(function()
    local ok, data = pcall(status_data.fetch, instance.root, {
      recent_limit = instance.recent_limit,
    })
    instance.refreshing = false
    if not ok then
      notify.error("Failed to refresh status: " .. tostring(data))
      return
    end
    instance.data = data
    -- Re-fetch open WC diffs
    for path, open in pairs(instance.open_diffs or {}) do
      if open and not path:match("^#") then
        for _, f in ipairs(data.files) do
          if f.path == path then f.diff = status_data.file_diff(instance.root, path) end
        end
      end
    end
    -- Re-fetch open recent-commit file lists / nested diffs
    for _, change in ipairs(data.recent) do
      if instance.open_changes[change.change_id] then load_change_files(change) end
    end
    -- Re-fetch open bookmark commit lists
    for _, bm in ipairs(data.bookmarks) do
      local key = bookmark_key(bm)
      if instance.open_bookmarks[key] then load_bookmark_commits(bm) end
    end
    vim.schedule(redraw)
  end)
end

---Double the recent-commits limit and reload that section.
local function load_more_recent()
  if not instance or not instance.data then return end
  local current = instance.recent_limit or default_commit_limit()
  instance.recent_limit = current * 2
  if instance.refreshing then return end
  instance.refreshing = true
  async.void(function()
    local ok, recent = pcall(status_data.log_changes, instance.root, "ancestors(@-)", instance.recent_limit)
    instance.refreshing = false
    if not ok then
      notify.error("Failed to load more commits: " .. tostring(recent))
      return
    end
    instance.data.recent = recent
    for _, change in ipairs(recent) do
      if instance.open_changes[change.change_id] then load_change_files(change) end
    end
    vim.schedule(redraw)
  end)
end

---Double a bookmark's commit limit and reload its history.
---@param bm table
---@param key? string
local function load_more_bookmark(bm, key)
  if not instance or not instance.data or not bm then return end
  key = key or bookmark_key(bm)
  if key == "" then return end
  instance.bookmark_limits = instance.bookmark_limits or {}
  local current = bookmark_commit_limit(key)
  instance.bookmark_limits[key] = current * 2
  instance.open_bookmarks[key] = true
  if instance.refreshing then return end
  instance.refreshing = true
  async.void(function()
    local ok, err = pcall(load_bookmark_commits, bm)
    instance.refreshing = false
    if not ok then
      notify.error("Failed to load more bookmark commits: " .. tostring(err))
      return
    end
    for _, b in ipairs(instance.data.bookmarks or {}) do
      if bookmark_key(b) == key then b.commits = bm.commits end
    end
    vim.schedule(redraw)
  end)
end

local function item_under_cursor()
  if not instance then return nil end
  local win = instance.buf.winid
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return instance.line_map[row]
end

---Resolve which commit list to expand from the cursor item.
---@param item StatusItem|nil
---@return "recent"|"bookmark", table|nil bookmark, string|nil bookmark_key
local function resolve_load_more_target(item)
  if item and item.data then
    if item.data.section == "bookmark" or item.data.bookmark_key then
      local key = item.data.bookmark_key
      local bm = item.data.bookmark
      if not bm and key and instance.data then
        for _, b in ipairs(instance.data.bookmarks or {}) do
          if bookmark_key(b) == key then
            bm = b
            break
          end
        end
      end
      if bm then return "bookmark", bm, key or bookmark_key(bm) end
    end
    if item.type == "bookmark" and item.data.bookmark then
      local key = item.data.bookmark_key or bookmark_key(item.data.bookmark)
      if instance.open_bookmarks[key] then return "bookmark", item.data.bookmark, key end
    end
  end
  return "recent", nil, nil
end

local function load_more()
  local kind, bm, key = resolve_load_more_target(item_under_cursor())
  if kind == "bookmark" then
    load_more_bookmark(bm, key)
  else
    load_more_recent()
  end
end

local function get_change_from_item(item)
  if not item or not item.data then return nil end
  if item.data.change then return item.data.change end
  if item.data.bookmark then
    return {
      change_id = item.data.bookmark.change_id or item.data.bookmark.target,
      bookmarks = { item.data.bookmark.name },
    }
  end
  return nil
end

local function after_action() M.refresh() end

local function run_jj(fn)
  async.void(function()
    fn()
    vim.schedule(after_action)
  end)
end

---Capture file/hunk selection from the cursor or active visual range.
---Call this while visual mode is still active (e.g. before opening a popup).
---@return { path: string, mode: "file"|"hunks", hunk_indices: integer[], file: FileStatus }|nil
function M.capture_selection()
  if not instance or not instance.line_map then return nil end

  local mode = vim.fn.mode()
  local first, last = vim.fn.line("."), vim.fn.line(".")
  if mode == "v" or mode == "V" or mode == "\22" then
    first = vim.fn.line("v")
    last = vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  ---@type table<string, { file: FileStatus, on_file: boolean, hunks: table<integer, boolean> }>
  local by_path = {}
  for row = first, last do
    local it = instance.line_map[row]
    -- Only working-copy files participate in hunk selection / split.
    if it and it.type ~= "change_file" and it.data and it.data.file then
      local file = it.data.file
      local path = file.path
      by_path[path] = by_path[path] or { file = file, on_file = false, hunks = {} }
      if it.type == "file" then
        by_path[path].on_file = true
      elseif it.type == "diff" and not it.data.change and file.diff and it.data.diff_index then
        local parsed = require("jujutsu.diff.hunks").parse_hunks(file.diff)
        local idx = require("jujutsu.diff.hunks").hunk_index_at(parsed, it.data.diff_index)
        if idx ~= nil then by_path[path].hunks[idx] = true end
      end
    end
  end

  -- Prefer the path under the anchor cursor/end of selection.
  local prefer = instance.line_map[last] or instance.line_map[first]
  if prefer and (prefer.type == "change_file" or (prefer.data and prefer.data.change and prefer.type == "diff")) then
    prefer = nil
  end
  local prefer_path = prefer and prefer.data and prefer.data.file and prefer.data.file.path

  local path = prefer_path
  if not path or not by_path[path] then path = next(by_path) end
  if not path then return nil end

  local entry = by_path[path]
  local indices = {}
  for idx in pairs(entry.hunks) do
    indices[#indices + 1] = idx
  end
  table.sort(indices)

  if #indices > 0 then
    return {
      path = path,
      mode = "hunks",
      hunk_indices = indices,
      file = entry.file,
    }
  end
  if entry.on_file or (prefer and prefer.type == "file") then
    return {
      path = path,
      mode = "file",
      hunk_indices = {},
      file = entry.file,
    }
  end
  -- Cursor on a diff header line with no hunk match → treat as file
  return {
    path = path,
    mode = "file",
    hunk_indices = {},
    file = entry.file,
  }
end

local function get_env(opts)
  opts = opts or {}
  local item = item_under_cursor()
  local change = get_change_from_item(item)
  local path = item and item.data and item.data.file and item.data.file.path or nil
  local env = {
    item = item,
    change = change,
    commit = change and change.change_id or nil,
    path = path,
    root = instance and instance.root,
  }
  if opts.with_selection then env.selection = M.capture_selection() end
  return env
end

---Conflicted local bookmark under the cursor, including rows expanded from it.
---@param item StatusItem|nil
---@return table|nil
local function conflicted_bookmark(item)
  if not item or not item.data or not instance or not instance.data then return nil end
  local function local_conflict(bm) return bm and bm.conflict and (bm.remote or "") == "" and bm or nil end
  local direct = local_conflict(item.data.bookmark)
  if direct then return direct end
  local key = item.data.bookmark_key
  if not key then return nil end
  for _, bm in ipairs(instance.data.bookmarks or {}) do
    if bookmark_key(bm) == key then return local_conflict(bm) end
  end
end

---The divergent change under the cursor.
---The second return is true when the section header should open the picker.
---@param item StatusItem|nil
---@return DivergentChange|nil
---@return boolean|nil pick
local function divergent_target(item)
  if not item or not instance or not instance.data then return nil end
  local groups = instance.data.divergent or {}
  if item.type == "section" and item.data and item.data.section == "divergent" then return nil, true end
  if item.type == "divergent" and item.data and item.data.divergent then return item.data.divergent end
  local change = item.data and item.data.change
  if not change then return nil end
  local group = require("jujutsu.jj.divergent").find(groups, change.change_id)
  if group then return group end
end

---@param root string
---@param bm table
local function resolve_bookmark_conflict(root, bm)
  local sides, err = require("jujutsu.jj.bookmark").conflict_sides(root, bm.name)
  if not sides then
    notify.error(err or ("Could not read bookmark " .. bm.name))
    return
  end
  if #sides == 0 then
    notify.warn(bm.name .. " has no sides to choose")
    return
  end
  local labels = {}
  for _, side in ipairs(sides) do
    local subject = side.subject ~= "" and side.subject or "(no description)"
    labels[#labels + 1] = string.format("%s %s %s", side.change_id, side.commit_id, subject)
  end
  local choice = finder.pick({ prompt = "Keep side of " .. bm.name, entries = labels })
  if not choice or choice == "" then return end
  local side
  for i, label in ipairs(labels) do
    if label == choice then
      side = sides[i]
      break
    end
  end
  if not side then return end
  local res = require("jujutsu.jj.cli").bookmark_set.allow_backwards
    .revision(side.change_id)
    .args(bm.name)
    .call({ cwd = root, hidden = false })
  if res and res.code == 0 then
    notify.info("Resolved bookmark " .. bm.name)
    require("jujutsu").refresh()
  end
end

local function bind_actions(bufnr)
  local actions = {
    Close = function() M.close() end,
    RefreshBuffer = function() M.refresh() end,
    LoadMore = function() load_more() end,
    LoadMoreRecent = function() load_more() end, -- alias
    Toggle = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "load_more" then
        load_more()
        return
      end
      if item.type == "section" and item.data and item.data.section then
        instance.folds[item.data.section] = not instance.folds[item.data.section]
        redraw()
      elseif item.type == "file" and item.data and item.data.file then
        local path = item.data.file.path
        if instance.open_diffs[path] then
          instance.open_diffs[path] = nil
        else
          instance.open_diffs[path] = true
          item.data.file.diff = status_data.file_diff(instance.root, path)
          for _, f in ipairs(instance.data.files) do
            if f.path == path then f.diff = item.data.file.diff end
          end
        end
        redraw()
      elseif item.type == "change" and item.data and item.data.change then
        local change = item.data.change
        local id = change.change_id
        if instance.open_changes[id] then
          instance.open_changes[id] = nil
          clear_change_diffs(id)
          change.files = nil
          sync_change_files(change)
        else
          instance.open_changes[id] = true
          load_change_files(change)
          sync_change_files(change)
        end
        redraw()
      elseif item.type == "bookmark" and item.data and item.data.bookmark and item.data.can_expand then
        local bm = item.data.bookmark
        local key = item.data.bookmark_key or bookmark_key(bm)
        if instance.open_bookmarks[key] then
          instance.open_bookmarks[key] = nil
          bm.commits = nil
        else
          instance.open_bookmarks[key] = true
          load_bookmark_commits(bm)
          for _, b in ipairs(instance.data.bookmarks) do
            if bookmark_key(b) == key then b.commits = bm.commits end
          end
        end
        redraw()
      elseif item.type == "change_file" and item.data and item.data.file and item.data.change then
        local change = item.data.change
        local path = item.data.file.path
        local key = item.data.diff_key or change_diff_key(change.change_id, path)
        if instance.open_diffs[key] then
          instance.open_diffs[key] = nil
        else
          instance.open_diffs[key] = true
          item.data.file.diff = status_data.file_diff(instance.root, path, change.change_id)
          for _, f in ipairs(change.files or {}) do
            if f.path == path then f.diff = item.data.file.diff end
          end
          sync_change_files(change)
        end
        redraw()
      end
    end,
    OpenFold = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "section" and item.data then
        instance.folds[item.data.section] = false
        redraw()
      elseif item.type == "bookmark" and item.data and item.data.bookmark and item.data.can_expand then
        local bm = item.data.bookmark
        local key = item.data.bookmark_key or bookmark_key(bm)
        if not instance.open_bookmarks[key] then
          instance.open_bookmarks[key] = true
          load_bookmark_commits(bm)
          redraw()
        end
      elseif item.type == "change" and item.data and item.data.change then
        local change = item.data.change
        if not instance.open_changes[change.change_id] then
          instance.open_changes[change.change_id] = true
          load_change_files(change)
          sync_change_files(change)
          redraw()
        end
      elseif (item.type == "file" or item.type == "change_file") and item.data and item.data.file then
        local key = item.data.diff_key or item.data.file.path
        if not instance.open_diffs[key] then
          instance.open_diffs[key] = true
          local rev = item.data.change and item.data.change.change_id or nil
          item.data.file.diff = status_data.file_diff(instance.root, item.data.file.path, rev)
          if item.data.change then sync_change_files(item.data.change) end
          redraw()
        end
      end
    end,
    CloseFold = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "section" and item.data then
        instance.folds[item.data.section] = true
        redraw()
      elseif item.type == "bookmark" and item.data and item.data.bookmark then
        local key = item.data.bookmark_key or bookmark_key(item.data.bookmark)
        if instance.open_bookmarks[key] then
          instance.open_bookmarks[key] = nil
          item.data.bookmark.commits = nil
          redraw()
        end
      elseif item.type == "change" and item.data and item.data.change then
        local id = item.data.change.change_id
        if instance.open_changes[id] then
          instance.open_changes[id] = nil
          clear_change_diffs(id)
          item.data.change.files = nil
          sync_change_files(item.data.change)
          redraw()
        end
      elseif (item.type == "file" or item.type == "change_file") and item.data and item.data.file then
        local key = item.data.diff_key or item.data.file.path
        if instance.open_diffs[key] then
          instance.open_diffs[key] = nil
          redraw()
        end
      end
    end,
    Depth1 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = true
      end
      clear_item_diffs()
      redraw()
    end,
    Depth2 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      clear_item_diffs()
      redraw()
    end,
    Depth3 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      redraw()
    end,
    Depth4 = function()
      for k in pairs(instance.folds) do
        instance.folds[k] = false
      end
      for _, f in ipairs(instance.data.files) do
        instance.open_diffs[f.path] = true
        f.diff = status_data.file_diff(instance.root, f.path)
      end
      for _, change in ipairs(instance.data.recent) do
        instance.open_changes[change.change_id] = true
        load_change_files(change)
      end
      for _, bm in ipairs(instance.data.bookmarks) do
        if not bm.deleted and bm.remote ~= "git" then
          local key = bookmark_key(bm)
          instance.open_bookmarks[key] = true
          load_bookmark_commits(bm)
        end
      end
      redraw()
    end,
    MoveDown = function() vim.cmd("normal! j") end,
    MoveUp = function() vim.cmd("normal! k") end,
    GoToFile = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "load_more" then
        load_more()
        return
      end
      if item.type == "change" then
        local change = get_change_from_item(item)
        if change and change.change_id and change.change_id ~= "" then
          require("jujutsu.buffers.commit_view").open(instance.root, change.change_id)
        end
        return
      end
      if item.data and item.data.file then
        local path = instance.root .. "/" .. item.data.file.path
        if not open_in_host(path, "edit") then vim.cmd("edit " .. vim.fn.fnameescape(path)) end
        return
      end
      if item.data and item.data.path then
        local path = instance.root .. "/" .. item.data.path
        if not open_in_host(path, "edit") then vim.cmd("edit " .. vim.fn.fnameescape(path)) end
        return
      end
      -- Change / Parent / bookmark target → commit view
      local change = get_change_from_item(item)
      if change and change.change_id and change.change_id ~= "" then
        require("jujutsu.buffers.commit_view").open(instance.root, change.change_id)
      end
    end,
    OpenStat = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item) or (instance.data and instance.data.working_copy)
      if change and change.change_id and change.change_id ~= "" then
        require("jujutsu.buffers.stat_view").open(instance.root, change.change_id)
      end
    end,
    VSplitOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if not path then return end
      local full = instance.root .. "/" .. path
      if not open_in_host(full, "vsplit") then vim.cmd("vsplit " .. vim.fn.fnameescape(full)) end
    end,
    SplitOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if not path then return end
      local full = instance.root .. "/" .. path
      if not open_in_host(full, "split") then vim.cmd("split " .. vim.fn.fnameescape(full)) end
    end,
    TabOpen = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.file and item.data.file.path or item.data.path)
      if not path then return end
      local full = instance.root .. "/" .. path
      if not open_in_host(full, "tab") then vim.cmd("tabedit " .. vim.fn.fnameescape(full)) end
    end,
    Discard = function()
      local item = item_under_cursor()
      if not item then return end
      if item.type == "file" and item.data.file then
        local path = item.data.file.path
        async.void(function()
          if finder.confirm("Restore " .. path .. "?") then
            run_jj(function() return cli.restore.paths(path).call_async({ cwd = instance.root, hidden = false }) end)
          end
        end)
      elseif item.type == "change" or item.type == "header" then
        local change = get_change_from_item(item)
        if change then
          async.void(function()
            if finder.confirm("Abandon " .. change.change_id .. "?") then
              run_jj(
                function() return cli.abandon.args(change.change_id).call_async({ cwd = instance.root, hidden = false }) end
              )
            end
          end)
        end
      elseif item.type == "bookmark" and item.data.bookmark then
        local bm = item.data.bookmark
        local name = bm.remote ~= "" and (bm.name .. "@" .. bm.remote) or bm.name
        async.void(function()
          if finder.confirm("Delete bookmark " .. name .. "?") then
            run_jj(
              function() return cli.bookmark_delete.args(name).call_async({ cwd = instance.root, hidden = false }) end
            )
          end
        end)
      end
    end,
    Untrack = function()
      local item = item_under_cursor()
      if item and item.type == "file" and item.data.file then
        run_jj(
          function()
            return cli.file_untrack.paths(item.data.file.path).call_async({ cwd = instance.root, hidden = false })
          end
        )
      end
    end,
    Describe = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item) or (instance.data and instance.data.working_copy)
      if change then
        require("jujutsu.buffers.editor").open({
          revision = change.change_id,
          root = instance.root,
          on_submit = after_action,
        })
      end
    end,
    Edit = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      if change then
        run_jj(
          function() return cli.edit.args(change.change_id).call_async({ cwd = instance.root, hidden = false }) end
        )
      end
    end,
    Split = function() require("jujutsu.popups.split").create(get_env({ with_selection = true })) end,
    NewOn = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      local rev = change and change.change_id or "@"
      run_jj(function() return cli.new.args(rev).call_async({ cwd = instance.root, hidden = false }) end)
    end,
    NewBefore = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      local rev = change and change.change_id or "@"
      run_jj(function() return cli.new.insert_before.args(rev).call_async({ cwd = instance.root, hidden = false }) end)
    end,
    ForgetBookmark = function()
      local item = item_under_cursor()
      if item and item.type == "bookmark" and item.data.bookmark then
        local bm = item.data.bookmark
        if bm.remote ~= "" then
          run_jj(
            function()
              return require("jujutsu.jj.bookmark").track(bm.name .. "@" .. bm.remote).call_async({
                cwd = instance.root,
                hidden = false,
              })
            end
          )
        else
          run_jj(
            function() return cli.bookmark_forget.args(bm.name).call_async({ cwd = instance.root, hidden = false }) end
          )
        end
      end
    end,
    OpenBrowser = function() require("jujutsu.forge").open_under_cursor(get_env()) end,
    IssuePanel = function()
      local item = item_under_cursor()
      local number = nil
      if item and item.type == "bookmark" and item.data and item.data.bookmark and item.data.bookmark.pr then
        number = item.data.bookmark.pr
      end
      require("jujutsu.issue_panel").open({
        root = instance.root,
        number = number,
        kind = number and "pr" or nil,
      })
    end,
    YankSelected = function()
      local item = item_under_cursor()
      if not item then return end
      local text = item.text:match("^%s*(.-)%s*$") or item.text
      if item.data and item.data.change then
        text = item.data.change.change_id
      elseif item.data and item.data.file then
        text = item.data.file.path
      elseif item.data and item.data.bookmark then
        text = item.data.bookmark.name
      end
      vim.fn.setreg("+", text)
      notify.info("Yanked " .. text)
    end,
    CommandHistory = function() require("jujutsu.buffers.process").show_history() end,
    Command = function()
      async.void(function()
        local input = finder.input({ prompt = "jj " })
        if not input or input == "" then return end
        local args = vim.split(input, "%s+")
        local jj = require("jujutsu.jj.shell").resolve_jj()
        run_jj(
          function()
            return require("jujutsu.process").await({
              cmd = vim.list_extend({ jj, "--no-pager" }, args),
              cwd = instance.root,
              suppress_console = false,
            })
          end
        )
      end)
    end,
    ShowRefs = function()
      local item = item_under_cursor()
      local change = get_change_from_item(item)
      if change then notify.info(string.format("change=%s commit=%s", change.change_id, change.commit_id)) end
    end,
    NextSection = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for i = row + 1, #instance.items do
        if instance.items[i].type == "section" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end,
    PreviousSection = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for i = row - 1, 1, -1 do
        if instance.items[i].type == "section" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end,
    GoToPreviousHunkHeader = function() vim.fn.search("^\\s*@@", "bW") end,
    GoToNextHunkHeader = function() vim.fn.search("^\\s*@@", "W") end,
    Resolve = function()
      local item = item_under_cursor()
      local path = item and item.data and (item.data.path or (item.data.file and item.data.file.path))
      local conflicts = instance.data and instance.data.conflicts or {}
      local function is_conflict(p)
        for _, conflict in ipairs(conflicts) do
          if conflict == p then return true end
        end
      end
      if path and not is_conflict(path) then path = nil end
      local root = instance.root
      local bm = conflicted_bookmark(item)
      if not path and bm then
        async.void(function() resolve_bookmark_conflict(root, bm) end)
        return
      end
      local group, pick = divergent_target(item)
      if not path and (group or pick) then
        local groups = instance.data and instance.data.divergent or {}
        async.void(function()
          local view = require("jujutsu.buffers.divergent")
          if pick then
            view.choose(root, groups)
          else
            view.open(root, group)
          end
        end)
        return
      end
      async.void(
        function()
          require("jujutsu.buffers.merge").open({
            root = root,
            path = path,
          })
        end
      )
    end,
  }

  mappings.apply(bufnr, "status", actions)
  mappings.apply_popup_maps(bufnr, get_env)
  -- Visual-mode Split so hunk ranges can be selected before opening the popup.
  local status_maps = require("jujutsu.config").values.mappings.status or {}
  for key, name in pairs(status_maps) do
    if name == "Split" and actions.Split then
      vim.keymap.set("x", key, actions.Split, {
        buffer = bufnr,
        silent = true,
        noremap = true,
        desc = "jujutsu: Split",
      })
    end
  end
end

---@param root string
---@param cwd string
---@param opts? { kind?: string }
---@return table
function M.open(root, cwd, opts)
  opts = opts or {}
  if instance and Buffer.is_open(instance.buf) then
    Buffer.focus(instance.buf)
    M.refresh()
    return instance
  end

  local buf = Buffer.create("jujutsu://status", "jujutsu")
  Buffer.open(buf, opts.kind or config.values.kind)
  Buffer.apply_buffer_opts(buf.bufnr)

  instance = {
    buf = buf,
    root = root,
    cwd = cwd,
    data = nil,
    items = {},
    line_map = {},
    folds = nil,
    open_diffs = {},
    open_changes = {},
    open_bookmarks = {},
    bookmark_limits = {},
    recent_limit = config.values.status.recent_commit_count or 10,
    refreshing = false,
  }

  bind_actions(buf.bufnr)
  watcher.start(root, function() M.refresh() end)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf.bufnr,
    once = true,
    callback = function()
      watcher.stop()
      instance = nil
    end,
  })

  M.refresh()
  return instance
end

function M.close()
  if instance then
    watcher.stop()
    Buffer.close(instance.buf)
    instance = nil
  end
end

function M.instance() return instance end

function M.focus()
  if instance then Buffer.focus(instance.buf) end
end

function M.get_env() return get_env() end

return M
