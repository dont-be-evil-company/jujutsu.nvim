local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local split_mod = require("jujutsu.buffers.diff.split")
local status_data = require("jujutsu.jj.status")

local M = {}

---@class DiffViewFile
---@field path string
---@field status string

---@class DiffView
---@field root string
---@field tabpage integer
---@field title string
---@field left_rev string
---@field right_rev string
---@field files DiffViewFile[] currently visible file list
---@field all_files DiffViewFile[] full PR/diff file list
---@field file_filter "all"|"comments"
---@field selected_path string|nil
---@field panel_buf Buffer
---@field panel_win integer
---@field split DiffSplit
---@field line_map table<integer, DiffViewFile|nil>
---@field closing boolean
---@field review ReviewSession|nil
---@field diverge { change_id: string, copies: DivergentCopy[], left: integer, right: integer }|nil
---@field copy_rows table<integer, integer>|nil

---@type DiffView|nil
local instance = nil

local function panel_height()
  local fh = config.values.file_history or {}
  return fh.panel_height or 16
end

---@return table
local function review_keys()
  local rev = (config.values.forge or {}).review or {}
  return rev.keymaps or {}
end

---@param view DiffView
---@return DiffViewFile[]
local function visible_files(view)
  if not view.review or view.file_filter ~= "comments" then return view.all_files or view.files or {} end
  local session_mod = require("jujutsu.review.session")
  session_mod.ensure_remote_comments(view.review)
  local with = session_mod.paths_with_comments(view.review)
  local out = {}
  for _, f in ipairs(view.all_files or {}) do
    if with[f.path] then table.insert(out, f) end
  end
  return out
end

local function refresh_overlays(view)
  if not view or not view.review or not view.selected_path then return end
  local overlay = require("jujutsu.review.overlay")
  local session_mod = require("jujutsu.review.session")
  session_mod.ensure_remote_comments(view.review)
  local comments = session_mod.overlay_comments_for_path(view.review, view.selected_path)
  overlay.render(view.split.left_buf.bufnr, comments, view.selected_path, "LEFT")
  overlay.render(view.split.right_buf.bufnr, comments, view.selected_path, "RIGHT")
end

local function focus_blocked()
  if require("jujutsu.finder").is_active() then return true end
  local cur = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(cur) then return false end
  local buf = vim.api.nvim_win_get_buf(cur)
  if vim.api.nvim_buf_is_valid(buf) then
    local ft = vim.bo[buf].filetype
    if ft == "jujutsu-finder" or ft == "jujutsu-input" or ft == "jujutsu-review-comment" then return true end
  end
  local cfg = vim.api.nvim_win_get_config(cur)
  return cfg.relative and cfg.relative ~= "" and (cfg.zindex or 0) >= 200
end

local function focus_view(view)
  if not view or view.closing then return end
  -- Don't yank focus away from an active picker or compose float.
  if focus_blocked() then return end
  if view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, view.tabpage)
  end
  if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
    pcall(vim.api.nvim_set_current_win, view.panel_win)
  end
end

local function close_view()
  if not instance or instance.closing then return end

  local function do_close()
    if not instance or instance.closing then return end
    instance.closing = true
    local tab = instance.tabpage
    local floating = instance.floating
    local wins = instance.wins
    if instance.review then pcall(require("jujutsu.review.session").save, instance.review) end
    if floating and wins then
      for _, w in ipairs(wins) do
        if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
      end
    end
    split_mod.destroy(instance.split)
    if instance.panel_buf and vim.api.nvim_buf_is_valid(instance.panel_buf.bufnr) then
      pcall(vim.api.nvim_buf_delete, instance.panel_buf.bufnr, { force = true })
    end
    instance = nil
    if not floating and tab and vim.api.nvim_tabpage_is_valid(tab) then
      local cur = vim.api.nvim_get_current_tabpage()
      if cur ~= tab then vim.api.nvim_set_current_tabpage(tab) end
      pcall(vim.cmd, "tabclose")
    end
  end

  if instance.review and instance.review.dirty and #(instance.review.comments or {}) > 0 then
    async.void(function()
      local choice = finder.pick({
        prompt = "Unsaved review comments",
        entries = { "Save & close", "Close without saving", "Cancel" },
      })
      if not choice or choice == "Cancel" then return end
      if choice == "Save & close" then require("jujutsu.review.session").save(instance.review) end
      do_close()
    end)
    return
  end
  do_close()
end

---@param builder any
---@param root string
---@return DiffViewFile[]
local function files_from_summary_builder(builder, root)
  local res = builder.summary.call({ cwd = root, hidden = true, remove_ansi = true })
  if res.code ~= 0 then return {} end
  local files = status_data.parse_diff_summary(res.stdout)
  return files
end

---@param s string
---@return string
local function esc_bar(s) return (s or ""):gsub("%%", "%%%%") end

---@param view DiffView
local function set_side_bars(view)
  local diverge = view.diverge
  if not diverge or not view.split then return end
  local function bar(copy, role, hint)
    if not copy then return "" end
    local detail = copy.commit_id or ""
    if copy.bookmarks and #copy.bookmarks > 0 then detail = detail .. " " .. table.concat(copy.bookmarks, " ") end
    if copy.description and copy.description ~= "" then detail = detail .. "  " .. copy.description end
    if #detail > 72 then detail = detail:sub(1, 71) .. "…" end
    return table.concat({
      "%#JujutsuHeaderLabel# ",
      esc_bar(role),
      " %#JujutsuCommitId#",
      esc_bar(detail),
      "%#JujutsuSubtle#  ",
      esc_bar(hint),
    })
  end
  local left = diverge.copies[diverge.left]
  local right = diverge.copies[diverge.right]
  local lwin = view.split.left_win
  local rwin = view.split.right_win
  if lwin and vim.api.nvim_win_is_valid(lwin) then vim.wo[lwin].winbar = bar(left, "Left", "1 keep") end
  if rwin and vim.api.nvim_win_is_valid(rwin) then vim.wo[rwin].winbar = bar(right, "Right", "2 keep") end
end

---@param view DiffView
local function render_panel(view)
  local lines = {}
  local highlights = {}
  view.line_map = {}
  view.copy_rows = {}
  view.files = visible_files(view)

  local function add(text, file, hls)
    table.insert(lines, text)
    local row = #lines
    view.line_map[row] = file
    for _, h in ipairs(hls or {}) do
      table.insert(highlights, {
        line = row - 1,
        col = h.col,
        end_col = h.end_col,
        hl = h.hl,
        line_hl = h.line_hl,
      })
    end
  end

  if view.diverge then
    local diverge = view.diverge
    local heading = string.format("Divergent %s (%d copies)", diverge.change_id, #diverge.copies)
    add(heading, nil, { { col = 0, end_col = #heading, hl = "JujutsuDivergent" } })
    local hint = "1 keep left    2 keep right    ]c / [c cycle    <CR> keep the copy under the cursor    q close"
    add(hint, nil, { { col = 0, end_col = #hint, hl = "JujutsuHint" } })
    for i, copy in ipairs(diverge.copies) do
      local roles = {}
      if i == diverge.left then roles[#roles + 1] = "left" end
      if i == diverge.right then roles[#roles + 1] = "right" end
      local role = #roles > 0 and ("  " .. table.concat(roles, " ")) or ""
      local marks = (copy.bookmarks and #copy.bookmarks > 0) and table.concat(copy.bookmarks, " ") or "-"
      local desc = (copy.description and copy.description ~= "") and copy.description or "(no description)"
      local num = tostring(i)
      local text = string.format("  %s  %s  %s  %s%s", num, copy.commit_id, marks, desc, role)
      local num_col = 2
      local id_col = num_col + #num + 2
      local mark_col = id_col + #copy.commit_id + 2
      local desc_col = mark_col + #marks + 2
      add(text, nil, {
        { col = num_col, end_col = num_col + #num, hl = "JujutsuPopupKey" },
        { col = id_col, end_col = id_col + #copy.commit_id, hl = "JujutsuCommitId" },
        { col = mark_col, end_col = mark_col + #marks, hl = "JujutsuBranch" },
        { col = desc_col, end_col = desc_col + #desc, hl = "JujutsuDescription" },
        { col = desc_col + #desc, end_col = #text, hl = "JujutsuDivergent" },
      })
      view.copy_rows[#lines] = i
    end
    add("", nil, {})
  end

  local total = #(view.all_files or view.files)
  local title = string.format("Diff %s (%d files)", view.title, total)
  if view.review then
    local filter = view.file_filter == "comments" and "comments" or "all"
    title = string.format(
      "Review %s (%d/%d files [%s], %d local, %d remote)",
      view.title,
      #view.files,
      total,
      filter,
      #(view.review.comments or {}),
      #(view.review.remote_comments or {})
    )
  end
  add(title, nil, { { col = 0, end_col = #title, hl = "JujutsuPopupHeading" } })
  local range = string.format("%s → %s", view.left_rev, view.right_rev)
  add(range, nil, { { col = 0, end_col = #range, hl = "JujutsuSubtle" } })
  add(view.root, nil, { { col = 0, end_col = #view.root, hl = "JujutsuSubtle" } })
  if view.review then
    local keys = review_keys()
    local hint = string.format(
      "c comment  %s reply  C file  S submit  %s filter  %s refresh  %s file-refresh  I conversation  ? help",
      keys.reply or "a",
      keys.filter or "f",
      keys.refresh_comments or "R",
      keys.refresh_file_comments or "gr"
    )
    add(hint, nil, { { col = 0, end_col = #hint, hl = "JujutsuHint" } })
  end
  add("", nil, {})

  if #view.files == 0 then
    local empty = view.file_filter == "comments" and "(no files with comments)" or "(no changes)"
    add(empty, nil, { { col = 0, end_col = #empty, hl = "JujutsuSubtle" } })
  else
    local session_mod = view.review and require("jujutsu.review.session") or nil
    for _, file in ipairs(view.files) do
      local selected = view.selected_path == file.path
      local reviewed = view.review and view.review.reviewed_files[file.path]
      local n_remote = 0
      local n_local = 0
      if session_mod and view.review then
        n_remote = #session_mod.remote_comments_for_path(view.review, file.path)
        for _, c in ipairs(view.review.comments or {}) do
          if c.path == file.path then n_local = n_local + 1 end
        end
      end
      local mark = reviewed and "✓" or " "
      local status = tostring(file.status or "?")
      local badge = ""
      if view.review and (n_remote > 0 or n_local > 0) then
        badge = string.format("  [%d↑ %d·]", n_remote, n_local)
      end
      local text = string.format("  %s %s %s%s", mark, status, file.path, badge)
      local status_col = 2 + #mark + 1
      local path_col = status_col + #status + 1
      local status_hl = require("jujutsu.hl").file_status(status)
      local hls = {
        { col = 2, end_col = 2 + #mark, hl = reviewed and "JujutsuReviewReviewed" or "JujutsuSubtle" },
        { col = status_col, end_col = status_col + #status, hl = status_hl },
        { col = path_col, end_col = path_col + #file.path, hl = "JujutsuFilePath" },
      }
      if badge ~= "" then table.insert(hls, { col = path_col + #file.path, end_col = #text, hl = "JujutsuSubtle" }) end
      if selected then table.insert(hls, { line_hl = "CursorLine" }) end
      add(text, file, hls)
    end
  end

  Buffer.render(view.panel_buf, lines, highlights)
  set_side_bars(view)
end

---@param view DiffView
---@param path? string
local function select_path(view, path)
  if not path then
    view.selected_path = nil
    render_panel(view)
    split_mod.clear(view.split)
    return
  end
  view.selected_path = path
  if view._comment_jump and view._comment_jump.path ~= path then view._comment_jump = nil end
  if view.review then require("jujutsu.review.session").ensure_remote_comments(view.review) end
  render_panel(view)
  for row, file in pairs(view.line_map) do
    if file and file.path == path then
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_win_set_cursor(view.panel_win, { row, 0 })
      end
      break
    end
  end
  local status = nil
  for _, f in ipairs(view.all_files or {}) do
    if f.path == path then
      status = f.status
      break
    end
  end
  if not status then
    for _, f in ipairs(view.files or {}) do
      if f.path == path then
        status = f.status
        break
      end
    end
  end
  split_mod.show_sides(view.split, view.left_rev, view.right_rev, path, { status = status })
  refresh_overlays(view)
end

---@param view DiffView
local function toggle_file_filter(view)
  if not view.review then return end
  view.file_filter = view.file_filter == "comments" and "all" or "comments"
  if view.file_filter == "comments" then require("jujutsu.review.session").ensure_remote_comments(view.review) end
  view.files = visible_files(view)
  render_panel(view)
  if view.selected_path then
    local still = false
    for _, f in ipairs(view.files) do
      if f.path == view.selected_path then
        still = true
        break
      end
    end
    if not still then
      if #view.files > 0 then
        select_path(view, view.files[1].path)
      else
        select_path(view, nil)
      end
      return
    end
  elseif #view.files > 0 then
    select_path(view, view.files[1].path)
    return
  end
  require("jujutsu.notify").info(
    view.file_filter == "comments" and "Showing files with comments" or "Showing all files"
  )
end

---@param view DiffView
local function refresh_all_comments(view)
  if not view.review then return end
  local session_mod = require("jujutsu.review.session")
  require("jujutsu.notify").info("Refreshing remote comments…")
  session_mod.refresh_remote_comments(view.review)
  render_panel(view)
  refresh_overlays(view)
  require("jujutsu.notify").info(string.format("Remote comments: %d", #(view.review.remote_comments or {})))
end

---@param view DiffView
local function refresh_file_comments(view)
  if not view.review then return end
  local path = view.selected_path
  if not path or path == "" then
    local row = view.panel_win
      and vim.api.nvim_win_is_valid(view.panel_win)
      and vim.api.nvim_win_get_cursor(view.panel_win)[1]
    local file = row and view.line_map[row]
    path = file and file.path
  end
  if not path then
    require("jujutsu.notify").warn("No file selected")
    return
  end
  local session_mod = require("jujutsu.review.session")
  require("jujutsu.notify").info("Refreshing comments for " .. path .. "…")
  session_mod.refresh_remote_comments_for_path(view.review, path)
  render_panel(view)
  if view.selected_path == path then refresh_overlays(view) end
  local n = #session_mod.remote_comments_for_path(view.review, path)
  require("jujutsu.notify").info(string.format("%s: %d remote comment(s)", path, n))
end

---@param view DiffView
---@param delta integer
local function select_adjacent(view, delta)
  if #view.files == 0 then return end
  local idx = 1
  for i, f in ipairs(view.files) do
    if f.path == view.selected_path then
      idx = i
      break
    end
  end
  local next_idx = idx + delta
  if next_idx < 1 or next_idx > #view.files then return end
  select_path(view, view.files[next_idx].path)
end

---@param view DiffView
local function open_description(view)
  local rev = view.right_rev
  if not rev or rev == "" then return end
  local res = cli.log.revisions(rev).no_graph.template("description").limit(1).call({
    cwd = view.root,
    hidden = true,
  })
  local lines = res.stdout or {}
  if #lines == 0 then lines = { "(no description set)" } end

  local buf = Buffer.create("jujutsu://diff/desc/" .. rev, "jujutsu-diff-desc")
  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(math.max(#lines + 2, 6), math.floor(vim.o.lines * 0.5))
  local win = require("jujutsu.ui.host").open_float(buf.bufnr, {
    width = width,
    height = height,
    title = " " .. rev .. " ",
    zindex = 90,
  })
  Buffer.render(buf, lines, {
    { line = 0, col = 0, end_col = #(lines[1] or ""), hl = "JujutsuDescription" },
  })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf.bufnr, silent = true })
  vim.keymap.set("n", "<esc>", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf.bufnr, silent = true })
end

---@param view DiffView
---@param side "LEFT"|"RIGHT"
---@param kind "line"|"range"|"file"|"review"
---@param start_line? integer
---@param end_line? integer
local function add_comment(view, side, kind, start_line, end_line)
  if not view.review then return end
  local comments_mod = require("jujutsu.review.comments")
  local session_mod = require("jujutsu.review.session")
  local ui = require("jujutsu.review.ui")
  local path = view.selected_path
  local prompt_title
  if kind == "file" then
    prompt_title = "File comment: " .. (path or "")
  elseif kind == "review" then
    prompt_title = "Review comment"
  elseif kind == "range" then
    prompt_title = string.format("Range %s:%d-%d", path or "?", start_line or 0, end_line or 0)
  else
    prompt_title = string.format("Line %s:%d", path or "?", end_line or start_line or 0)
  end

  ui.prompt_comment(prompt_title, {}, function(body)
    if not body then return end
    local comment = comments_mod.new({
      kind = kind,
      path = (kind ~= "review") and path or nil,
      side = (kind == "line" or kind == "range") and side or nil,
      line = end_line or start_line,
      start_line = kind == "range" and start_line or nil,
      body = body,
    })
    session_mod.add_comment(view.review, comment)
    render_panel(view)
    refresh_overlays(view)
  end)
end

---@param view DiffView
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return table|nil local pending comment at line
local function local_comment_at(view, side, line)
  if not view.review or not view.selected_path then return nil end
  for _, c in ipairs(view.review.comments or {}) do
    local kind = c.kind or "line"
    if
      not c.remote
      and c.path == view.selected_path
      and (kind == "line" or kind == "range")
      and (c.side or "RIGHT") == side
      and tonumber(c.line) == line
    then
      return c
    end
  end
  return nil
end

---@param view DiffView
local function edit_comment_at_cursor(view)
  if not view.review then return end
  local side = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr and "LEFT" or "RIGHT"
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comment = local_comment_at(view, side, line)
  if not comment then
    require("jujutsu.notify").warn("No unsubmitted comment on this line")
    return
  end
  local session_mod = require("jujutsu.review.session")
  local ui = require("jujutsu.review.ui")
  ui.prompt_comment("Edit comment", { initial = comment.body or "" }, function(body)
    if not body then return end
    session_mod.update_comment(view.review, comment.id, body)
    render_panel(view)
    refresh_overlays(view)
  end)
end

---@param view DiffView
local function delete_comment_at_cursor(view)
  if not view.review then return end
  local side = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr and "LEFT" or "RIGHT"
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comment = local_comment_at(view, side, line)
  if not comment then
    require("jujutsu.notify").warn("No unsubmitted comment on this line")
    return
  end
  local session_mod = require("jujutsu.review.session")
  if session_mod.remove_comment(view.review, comment.id) then
    render_panel(view)
    refresh_overlays(view)
    require("jujutsu.notify").info("Removed unsubmitted comment")
  end
end

---@param view DiffView
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return table[]
local function remote_comments_at(view, side, line)
  if not view.review or not view.selected_path then return {} end
  local session_mod = require("jujutsu.review.session")
  local out = {}
  for _, c in ipairs(session_mod.remote_comments_for_path(view.review, view.selected_path)) do
    if (c.side or "RIGHT") == side and tonumber(c.line) == line then table.insert(out, c) end
  end
  return out
end

---@param view DiffView
local function reply_at_cursor(view)
  if not view.review then return end
  local provider = require("jujutsu.forge.provider")
  local threads = require("jujutsu.review.threads")
  local ui = require("jujutsu.review.ui")
  local session_mod = require("jujutsu.review.session")
  local notify = require("jujutsu.notify")

  if not provider.supports_reply(view.review.remote) then
    notify.warn("Threaded replies are not supported for this forge")
    return
  end

  local side = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr and "LEFT" or "RIGHT"
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local candidates = {}
  for _, c in ipairs(remote_comments_at(view, side, line)) do
    if threads.can_reply(c) then table.insert(candidates, c) end
  end
  if #candidates == 0 then
    notify.warn("No remote comment to reply to on this line")
    return
  end

  local function do_reply(target)
    if not target then return end
    local title = string.format("Reply to @%s", target.author or "comment")
    ui.prompt_comment(title, {}, function(body)
      if not body or body == "" then return end
      local function post()
        local ok, err = provider.post_reply(view.review.root, view.review.number, {
          parent_id = target.id,
          discussion_id = target.discussion_id,
          body = body,
        }, view.review.remote)
        if ok then
          session_mod.refresh_remote_comments_for_path(view.review, view.selected_path)
          render_panel(view)
          refresh_overlays(view)
          notify.info("Reply posted")
          return
        end
        if view.review.remote and provider.is_auth_error(err) then
          notify.error(err or "Authentication failed")
          provider.handle_auth_failure(view.review.remote, function(updated)
            if updated then vim.schedule(function() require("jujutsu.async").void(post) end) end
          end)
          return
        end
        notify.error(err or "Failed to post reply")
      end
      require("jujutsu.async").void(post)
    end)
  end

  if #candidates == 1 then
    do_reply(candidates[1])
    return
  end

  local labels = {}
  local label_to_candidate = {}
  for _, c in ipairs(candidates) do
    local preview = (c.body or ""):gsub("\n", " ")
    if #preview > 60 then preview = preview:sub(1, 57) .. "..." end
    local depth = c.parent_id and "↳ " or ""
    local label = string.format("%s@%s: %s", depth, c.author or "?", preview)
    table.insert(labels, label)
    label_to_candidate[label] = c
  end
  async.void(function()
    local choice = finder.pick({ prompt = "Reply to comment", entries = labels })
    if choice then do_reply(label_to_candidate[tostring(choice)]) end
  end)
end

---Reveal a line in a diff window without leaving the caller focused elsewhere.
---Updates that window's cursor (required for `diffthis` / scrollbind) then restores focus.
---@param win integer
---@param line integer
---@param restore_win? integer
local function reveal_diff_line(win, line, restore_win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count < 1 then return end
  if line < 1 then line = 1 end
  if line > line_count then line = line_count end

  restore_win = restore_win or vim.api.nvim_get_current_win()
  -- Briefly enter the diff win so diff/scrollbind applies the new position.
  pcall(vim.api.nvim_set_current_win, win)
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  pcall(vim.cmd, "normal! zz")
  if restore_win and vim.api.nvim_win_is_valid(restore_win) then pcall(vim.api.nvim_set_current_win, restore_win) end
end

---Path to navigate: file under the panel cursor, else the currently shown file.
---@param view DiffView
---@return string|nil
local function jump_comment_path(view)
  if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
    local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
    local file = view.line_map[row]
    if file and file.path and file.path ~= "" then return file.path end
  end
  return view.selected_path
end

---Jump to next/prev comment.
---From the file list (`keep_focus`): scroll the matching diff side, stay on the panel.
---From a diff buffer: move the cursor in the current window.
---@param view DiffView
---@param direction integer 1 or -1
---@param opts? { keep_focus?: boolean }
local function jump_comment(view, direction, opts)
  opts = opts or {}
  if not view.review then return end
  local overlay = require("jujutsu.review.overlay")
  local session_mod = require("jujutsu.review.session")
  local notify = require("jujutsu.notify")
  local keep_focus = opts.keep_focus == true

  session_mod.ensure_remote_comments(view.review)

  local path = keep_focus and jump_comment_path(view) or view.selected_path
  if not path or path == "" then
    notify.warn("No file selected")
    return
  end

  -- From the file list, show the file under the cursor if it isn't already.
  if keep_focus and view.selected_path ~= path then select_path(view, path) end

  local all = session_mod.all_overlay_comments(view.review)
  local targets = overlay.comment_targets(all, path)
  if #targets == 0 then
    notify.warn("No comments on " .. path)
    return
  end

  if keep_focus then
    local nav = view._comment_jump
    local from_line = 0
    if nav and nav.path == path and type(nav.line) == "number" then from_line = nav.line end
    local target = overlay.next_comment_target(all, path, from_line, direction)
    if not target then return end
    local win = target.side == "LEFT" and view.split.left_win or view.split.right_win
    if not win or not vim.api.nvim_win_is_valid(win) then
      -- Added/deleted single-pane layout: jump on the visible side instead.
      win = view.split.right_win
      if not win or not vim.api.nvim_win_is_valid(win) then win = view.split.left_win end
    end
    if not win or not vim.api.nvim_win_is_valid(win) then
      notify.warn("Diff window is not available")
      return
    end
    view._comment_jump = { path = path, side = target.side, line = target.line }
    reveal_diff_line(win, target.line, view.panel_win)
    return
  end

  local side = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr and "LEFT" or "RIGHT"
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local next_line = overlay.next_comment_line(all, path, side, cur, direction)
  if not next_line then
    notify.warn("No comments on this side")
    return
  end
  view._comment_jump = { path = path, side = side, line = next_line }
  vim.api.nvim_win_set_cursor(0, { next_line, 0 })
  pcall(vim.cmd, "normal! zz")
end

---@param view DiffView
local function bind_review_keymaps(view)
  if not view.review then return end
  local ui = require("jujutsu.review.ui")
  local session_mod = require("jujutsu.review.session")

  local function side_for_buf(bufnr)
    if bufnr == view.split.left_buf.bufnr then return "LEFT" end
    return "RIGHT"
  end

  local function map_diff(lhs, rhs, desc)
    for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
      vim.keymap.set("n", lhs, rhs, {
        buffer = dbuf.bufnr,
        silent = true,
        noremap = true,
        desc = "jujutsu review: " .. desc,
      })
    end
  end

  map_diff("c", function()
    local side = side_for_buf(vim.api.nvim_get_current_buf())
    local line = vim.api.nvim_win_get_cursor(0)[1]
    add_comment(view, side, "line", line, line)
  end, "CommentLine")

  map_diff("C", function() add_comment(view, "RIGHT", "file") end, "CommentFile")

  for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
    vim.keymap.set("v", "c", function()
      local side = side_for_buf(dbuf.bufnr)
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      if start_line == end_line then
        add_comment(view, side, "line", start_line, end_line)
      else
        add_comment(view, side, "range", start_line, end_line)
      end
    end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu review: CommentRange" })
  end

  map_diff(";c", function() add_comment(view, "RIGHT", "review") end, "CommentReview")

  map_diff("e", function() edit_comment_at_cursor(view) end, "EditComment")
  map_diff("i", function() edit_comment_at_cursor(view) end, "EditComment")
  map_diff("x", function() delete_comment_at_cursor(view) end, "DeleteComment")

  local keys = review_keys()
  map_diff(keys.filter or "f", function() toggle_file_filter(view) end, "ToggleFileFilter")
  map_diff(keys.refresh_comments or "R", function() refresh_all_comments(view) end, "RefreshComments")
  map_diff(keys.refresh_file_comments or "gr", function() refresh_file_comments(view) end, "RefreshFileComments")
  map_diff(keys.reply or "a", function() reply_at_cursor(view) end, "ReplyComment")

  map_diff("m", function() jump_comment(view, 1) end, "NextComment")
  map_diff("M", function() jump_comment(view, -1) end, "PrevComment")

  map_diff("y", function() ui.copy_markdown(session_mod.markdown(view.review)) end, "YankMarkdown")

  map_diff("S", function()
    require("jujutsu.review.submit").pick_and_submit(view.review, function(ok)
      if ok then render_panel(view) end
    end)
  end, "Submit")

  local issue_open = ((config.values.issue_panel or {}).keymaps or {}).open or "I"
  map_diff(issue_open, function()
    if not view.review or not view.review.number then return end
    require("jujutsu.issue_panel").open({
      root = view.root,
      remote = view.review.remote,
      number = view.review.number,
      kind = "pr",
    })
  end, "IssuePanel")

  map_diff("o", function()
    local remote_mod = require("jujutsu.forge.remote")
    local rem = view.review.remote or remote_mod.detect(view.root)
    if not rem or not view.selected_path then
      require("jujutsu.notify").warn("No forge file to open")
      return
    end
    local side = side_for_buf(vim.api.nvim_get_current_buf())
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local commit = side == "LEFT" and (view.review.pr and view.review.pr.base_sha or view.left_rev)
      or (view.review.pr and view.review.pr.head_sha or view.right_rev)
    remote_mod.open_url(remote_mod.pr_file_url(rem, view.review.number, view.selected_path, {
      line = line,
      side = side,
      commit = commit,
    }))
  end, "OpenInBrowser")

  map_diff("?", function()
    local k = review_keys()
    ui.help(table.concat({
      "Review keymaps",
      "",
      "c        comment at cursor line",
      "C        file comment",
      "v/V + c  range comment",
      ";c       review-level comment",
      (k.reply or "a") .. "        reply to remote comment thread",
      "e / i    edit unsubmitted comment at cursor",
      "x        delete unsubmitted comment at cursor",
      "m / M    next / previous comment (diff: move cursor; file list: scroll only)",
      (k.filter or "f") .. "        toggle all files / files with comments",
      (k.refresh_comments or "R") .. "        refresh all remote comments (cache)",
      (k.refresh_file_comments or "gr") .. "       refresh remote comments for current file",
      "r        toggle file reviewed (panel)",
      "y        yank markdown",
      "S        submit review",
      "o        open file/PR line in browser",
      issue_open .. "        issue/PR conversation panel",
      "q        close",
    }, "\n"))
  end, "Help")
end

---@param view DiffView
---@param view DiffView
local function reload_diff_sides(view)
  local builder = cli.diff.from(view.left_rev).to(view.right_rev)
  view.all_files = files_from_summary_builder(builder, view.root)
  view.files = view.all_files
  local still = false
  for _, file in ipairs(view.files) do
    if file.path == view.selected_path then
      still = true
      break
    end
  end
  if still then
    select_path(view, view.selected_path)
  elseif #view.files > 0 then
    select_path(view, view.files[1].path)
  else
    view.selected_path = nil
    render_panel(view)
    split_mod.clear(view.split)
  end
end

---@param view DiffView
---@param index integer
local function keep_copy(view, index)
  local diverge = view.diverge
  if not diverge then return end
  local copy = diverge.copies[index]
  if not copy then return end
  local drop = {}
  for i, other in ipairs(diverge.copies) do
    if i ~= index then drop[#drop + 1] = other.commit_id end
  end
  if #drop == 0 then return end
  async.void(function()
    local noun = #drop == 1 and "copy" or "copies"
    local ok = finder.confirm(
      string.format("Keep %s and abandon %d other %s of %s?", copy.commit_id, #drop, noun, diverge.change_id)
    )
    if not ok then return end
    local res = cli.abandon.args(unpack(drop)).call({ cwd = view.root, hidden = false })
    if res and res.code == 0 then
      require("jujutsu.notify").info("Kept " .. copy.commit_id)
      close_view()
      require("jujutsu").refresh()
    end
  end)
end

---@param view DiffView
---@param which "left"|"right"
local function keep_side(view, which)
  local diverge = view.diverge
  if not diverge then return end
  keep_copy(view, which == "left" and diverge.left or diverge.right)
end

---@param view DiffView
---@param dir integer
local function cycle_copy(view, dir)
  local diverge = view.diverge
  if not diverge or #diverge.copies < 2 then return end
  if #diverge.copies == 2 then
    diverge.left, diverge.right = diverge.right, diverge.left
  else
    local key = dir > 0 and "right" or "left"
    local other = key == "right" and diverge.left or diverge.right
    local i = diverge[key]
    local n = #diverge.copies
    for _ = 1, n do
      i = ((i - 1 + dir) % n) + 1
      if i ~= other then break end
    end
    diverge[key] = i
  end
  view.left_rev = diverge.copies[diverge.left].commit_id
  view.right_rev = diverge.copies[diverge.right].commit_id
  reload_diff_sides(view)
end

local function bind_keymaps(view)
  local bufnr = view.panel_buf.bufnr
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, noremap = true, desc = "jujutsu: " .. desc })
  end

  map("q", close_view, "Close")
  map("<esc>", close_view, "Close")

  local function open_under_cursor()
    local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
    if view.copy_rows and view.copy_rows[row] then
      keep_copy(view, view.copy_rows[row])
      return
    end
    local file = view.line_map[row]
    if file then select_path(view, file.path) end
  end

  ---Open selected/cursor file in the forge web UI at the right-hand commit.
  local function open_file_in_browser()
    local remote_mod = require("jujutsu.forge.remote")
    local rem = (view.review and view.review.remote) or remote_mod.detect(view.root)
    if not rem then
      require("jujutsu.notify").warn("Could not detect forge remote")
      return
    end
    local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
    local file = view.line_map[row]
    local path = (file and file.path) or view.selected_path
    if not path or path == "" then
      require("jujutsu.notify").warn("No file selected")
      return
    end
    local commit = (view.review and view.review.pr and view.review.pr.head_sha) or view.right_rev or ""
    if commit == "" then
      require("jujutsu.notify").warn("No commit to open")
      return
    end
    remote_mod.open_url(remote_mod.file_url(rem, commit, path))
  end

  map("<cr>", open_under_cursor, "Open")
  if view.diverge then
    local function map_all(lhs, rhs, desc)
      map(lhs, rhs, desc)
      for _, buf in ipairs({ view.split.left_buf.bufnr, view.split.right_buf.bufnr }) do
        vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, noremap = true, desc = "jujutsu: " .. desc })
      end
    end
    map_all("1", function() keep_side(view, "left") end, "KeepLeft")
    map_all("2", function() keep_side(view, "right") end, "KeepRight")
    map_all("]c", function() cycle_copy(view, 1) end, "NextCopy")
    map_all("[c", function() cycle_copy(view, -1) end, "PrevCopy")
  end
  map("o", open_file_in_browser, "OpenInBrowser")
  map("<tab>", function() select_adjacent(view, 1) end, "NextFile")
  map("<s-tab>", function() select_adjacent(view, -1) end, "PrevFile")
  map("L", function() open_description(view) end, "Description")

  if view.review then
    local keys = review_keys()
    map("r", function()
      local row = vim.api.nvim_win_get_cursor(view.panel_win)[1]
      local file = view.line_map[row]
      if not file then return end
      require("jujutsu.review.session").toggle_reviewed(view.review, file.path)
      render_panel(view)
    end, "ToggleReviewed")
    map(keys.filter or "f", function() toggle_file_filter(view) end, "ToggleFileFilter")
    map(keys.refresh_comments or "R", function() refresh_all_comments(view) end, "RefreshComments")
    map(keys.refresh_file_comments or "gr", function() refresh_file_comments(view) end, "RefreshFileComments")
    map("m", function() jump_comment(view, 1, { keep_focus = true }) end, "NextComment")
    map("M", function() jump_comment(view, -1, { keep_focus = true }) end, "PrevComment")
    map("y", function()
      local md = require("jujutsu.review.session").markdown(view.review)
      require("jujutsu.review.ui").copy_markdown(md)
    end, "YankMarkdown")
    map("S", function()
      require("jujutsu.review.submit").pick_and_submit(view.review, function(ok)
        if ok then render_panel(view) end
      end)
    end, "Submit")
    local issue_open = ((config.values.issue_panel or {}).keymaps or {}).open or "I"
    map(issue_open, function()
      if not view.review or not view.review.number then return end
      require("jujutsu.issue_panel").open({
        root = view.root,
        remote = view.review.remote,
        number = view.review.number,
        kind = "pr",
      })
    end, "IssuePanel")
    map("?", function()
      local rk = review_keys()
      require("jujutsu.review.ui").help(table.concat({
        "Review keymaps",
        "",
        "c        comment at cursor line (diff)",
        "C        file comment (diff)",
        "v/V + c  range comment (diff)",
        ";c       review-level comment",
        (rk.reply or "a") .. "        reply to remote comment thread (diff)",
        "e / i    edit unsubmitted comment at cursor",
        "x        delete unsubmitted comment at cursor",
        "m / M    next / previous comment (diff: move cursor; file list: scroll only)",
        (rk.filter or "f") .. "        toggle all files / files with comments",
        (rk.refresh_comments or "R") .. "        refresh all remote comments (cache)",
        (rk.refresh_file_comments or "gr") .. "       refresh remote comments for current file",
        "r        toggle file reviewed",
        "y        yank markdown",
        "S        submit review",
        "o        open file in browser (panel) / PR line (diff)",
        issue_open .. "        issue/PR conversation panel",
        "q        close",
      }, "\n"))
    end, "Help")
  end

  for _, dbuf in ipairs({ view.split.left_buf, view.split.right_buf }) do
    vim.keymap.set("n", "q", close_view, { buffer = dbuf.bufnr, silent = true, noremap = true })
    vim.keymap.set("n", "<leader>e", function()
      if view.panel_win and vim.api.nvim_win_is_valid(view.panel_win) then
        vim.api.nvim_set_current_win(view.panel_win)
      end
    end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu: FocusDiffPanel" })
    -- Non-review diffs: open file at this side's commit + line. Review mode overrides via bind_review_keymaps.
    if not view.review then
      vim.keymap.set("n", "o", function()
        local remote_mod = require("jujutsu.forge.remote")
        local rem = remote_mod.detect(view.root)
        if not rem or not view.selected_path then
          require("jujutsu.notify").warn("No forge file to open")
          return
        end
        local is_left = vim.api.nvim_get_current_buf() == view.split.left_buf.bufnr
        local commit = is_left and view.left_rev or view.right_rev
        local line = vim.api.nvim_win_get_cursor(0)[1]
        remote_mod.open_url(remote_mod.file_url(rem, commit, view.selected_path, line))
      end, { buffer = dbuf.bufnr, silent = true, noremap = true, desc = "jujutsu: OpenInBrowser" })
    end
  end

  bind_review_keymaps(view)
end

---Open a side-by-side diff tab with a file list.
-- luacheck: ignore 631
---@param opts { cwd: string, title?: string, left?: string, right?: string, revision?: string, builder?: any, review?: ReviewSession, diverge?: { change_id: string, copies: DivergentCopy[], left: integer, right: integer } }
function M.open(opts)
  require("jujutsu.hl").setup()
  opts = opts or {}
  local root = opts.cwd
  if not root then return end

  if instance then close_view() end
  -- If close prompted, instance may still be open
  if instance then return end

  local left_rev, right_rev, title, files

  if opts.revision then
    left_rev = opts.revision .. "-"
    right_rev = opts.revision
    title = opts.title or opts.revision
    files = status_data.change_files(root, opts.revision)
  elseif opts.left and opts.right then
    left_rev = opts.left
    right_rev = opts.right
    title = opts.title or (left_rev .. ".." .. right_rev)
    local builder = opts.builder or cli.diff.from(left_rev).to(right_rev)
    files = files_from_summary_builder(builder, root)
  elseif opts.builder then
    left_rev = "@-"
    right_rev = "@"
    title = opts.title or "wc"
    files = files_from_summary_builder(opts.builder, root)
  else
    left_rev = "@-"
    right_rev = "@"
    title = opts.title or "wc"
    files = files_from_summary_builder(cli.diff, root)
  end

  if opts.review then
    title = opts.title or opts.review.title or title
    left_rev = opts.review.left_rev or left_rev
    right_rev = opts.review.right_rev or right_rev
  end

  local host = require("jujutsu.ui.host")
  local regions = host.diff_regions(panel_height())
  local tabpage, left_win, right_win, panel_win
  if regions then
    local laid = host.tiles({
      { key = "left", region = regions.left },
      { key = "right", region = regions.right },
      { key = "panel", region = regions.panel, enter = true },
    })
    left_win = laid.left
    right_win = laid.right
    panel_win = laid.panel
    tabpage = nil
  else
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    left_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    right_win = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    panel_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(panel_win, panel_height())
  end

  local panel_buf = Buffer.create("jujutsu://diff/panel/" .. title, "jujutsu-diff")
  vim.api.nvim_win_set_buf(panel_win, panel_buf.bufnr)
  panel_buf.winid = panel_win
  vim.wo[panel_win].cursorline = true
  vim.wo[panel_win].wrap = false
  if config.values.disable_line_numbers then
    vim.wo[panel_win].number = false
    vim.wo[panel_win].relativenumber = false
  end

  local split = split_mod.create(root, left_win, right_win, {
    uri_prefix = "jujutsu://diff/" .. require("jujutsu.util").buf_name_path(title),
    host_top = regions and regions.top or nil,
  })

  instance = {
    root = root,
    tabpage = tabpage,
    title = title,
    left_rev = left_rev,
    right_rev = right_rev,
    all_files = files or {},
    files = files or {},
    file_filter = "all",
    selected_path = nil,
    panel_buf = panel_buf,
    panel_win = panel_win,
    split = split,
    line_map = {},
    closing = false,
    review = opts.review,
    diverge = opts.diverge,
    copy_rows = {},
    floating = regions ~= nil,
    wins = { left_win, right_win, panel_win },
  }

  bind_keymaps(instance)
  render_panel(instance)

  if #instance.files > 0 then
    select_path(instance, instance.files[1].path)
  else
    split_mod.clear(split)
  end

  focus_view(instance)
  -- Picker UIs restore the previous window on deferred close callbacks; reclaim
  -- focus across a few ticks so we win that race reliably.
  local opened = instance
  for _, delay in ipairs({ 0, 30, 80, 160 }) do
    vim.defer_fn(function() focus_view(opened) end, delay)
  end

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("JujutsuDiffView", { clear = true }),
    callback = function()
      if not instance or instance.closing or not instance.tabpage then return end
      if not vim.api.nvim_tabpage_is_valid(instance.tabpage) then
        instance.closing = true
        split_mod.destroy(instance.split)
        if instance.panel_buf and vim.api.nvim_buf_is_valid(instance.panel_buf.bufnr) then
          pcall(vim.api.nvim_buf_delete, instance.panel_buf.bufnr, { force = true })
        end
        instance = nil
      end
    end,
  })

  -- Re-wrap comment virt_lines when the diff windows change size.
  if instance.review then
    local resize_gen = 0
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = "JujutsuDiffView",
      callback = function()
        if not instance or instance.closing or not instance.review then return end
        resize_gen = resize_gen + 1
        local gen = resize_gen
        vim.defer_fn(function()
          if gen ~= resize_gen then return end
          if instance and not instance.closing and instance.review then refresh_overlays(instance) end
        end, 50)
      end,
    })
  end
end

---Compatibility shim: old callers passed a git-format patch. Open WC-style view instead when possible.
---@param lines string[]
---@param title? string
function M.show(lines, title)
  local root = require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  if title == "trunk" or title == "main" or title == "master" then
    M.open({
      cwd = root,
      title = title,
      left = title == "trunk" and "trunk()" or title,
      right = "@",
    })
    return
  end
  if not lines or #lines == 0 or (lines[1] and lines[1]:match("^%(could not")) then
    require("jujutsu.notify").warn(lines and lines[1] or "No changes")
    return
  end
  M.open({ cwd = root, title = title or "diff" })
end

---Highlight helper kept for any external callers.
---@param line string
---@return string
function M.diff_line_hl(line)
  local first = line:sub(1, 1)
  if line:match("^@@") then
    return "JujutsuHunkHeader"
  elseif line:match("^diff ") or line:match("^index ") or line:match("^%-%-%-") or line:match("^%+%+%+") then
    return "JujutsuDiffHeader"
  elseif first == "+" then
    return "JujutsuDiffAdd"
  elseif first == "-" then
    return "JujutsuDiffDelete"
  end
  return "JujutsuDiffContext"
end

function M.close() close_view() end

---@return boolean
function M.is_open() return instance ~= nil end

---@return DiffView|nil
function M.instance() return instance end

return M
