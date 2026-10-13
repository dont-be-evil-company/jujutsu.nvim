local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local panel_mod = require("jujutsu.buffers.file_history.panel")
local view_mod = require("jujutsu.buffers.annotate.view")

local M = {}

---@class AnnotateSession
---@field root string
---@field path string
---@field tabpage integer
---@field view AnnotateView
---@field panel FileHistoryPanel
---@field closing boolean

---@type AnnotateSession|nil
local instance = nil

local function cfg() return config.values.annotate or {} end

local function close_view()
  if not instance or instance.closing then return end
  instance.closing = true
  local tab = instance.tabpage
  local floating = instance.floating
  local wins = instance.wins
  if floating and wins then
    for _, w in ipairs(wins) do
      if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
  end
  view_mod.destroy(instance.view)
  panel_mod.destroy(instance.panel)
  instance = nil
  if not floating and tab and vim.api.nvim_tabpage_is_valid(tab) then
    local cur = vim.api.nvim_get_current_tabpage()
    if cur ~= tab then vim.api.nvim_set_current_tabpage(tab) end
    pcall(vim.cmd, "tabclose")
  end
end

---@param session AnnotateSession
---@param entry FileHistoryEntry
---@param opts? { keep_cursor?: boolean }
local function select_change(session, entry, opts)
  opts = opts or {}
  session.panel.selected_change = entry.change_id
  session.panel.selected_path = session.path
  panel_mod.render(session.panel, #session.panel.entries)
  panel_mod.goto_entry(session.panel, entry, session.path)
  view_mod.highlight_change(session.view, entry.change_id, { keep_cursor = opts.keep_cursor })
end

---@param session AnnotateSession
---@param delta integer
local function select_adjacent(session, delta)
  local entries = session.panel.entries
  if #entries == 0 then return end
  local cur_idx = 1
  for i, e in ipairs(entries) do
    if e.change_id == session.panel.selected_change then
      cur_idx = i
      break
    end
  end
  local next_idx = cur_idx + delta
  if next_idx < 1 or next_idx > #entries then return end
  select_change(session, entries[next_idx])
end

local function ids_match(a, b)
  if not a or not b or a == "" or b == "" then return false end
  return a == b or a:sub(1, #b) == b or b:sub(1, #a) == a
end

---@param session AnnotateSession
---@param line AnnotateLine
---@return FileHistoryEntry[]
local function affecting_commits(session, line)
  local commits = {}
  local seen = {}
  for _, entry in ipairs(session.panel.entries) do
    if not seen[entry.change_id] then
      for _, row in ipairs(session.view.lines) do
        if ids_match(entry.change_id, row.change_id) then
          seen[entry.change_id] = true
          commits[#commits + 1] = entry
          break
        end
      end
    end
  end
  local found = false
  for _, entry in ipairs(commits) do
    if ids_match(entry.change_id, line.change_id) then
      found = true
      break
    end
  end
  if not found and line.change_id ~= "" then
    table.insert(commits, 1, {
      change_id = line.change_id,
      description = line.description ~= "" and line.description or "(no description set)",
    })
  end
  return commits
end

---@param session AnnotateSession
---@param change_id string
local function open_file_diff(session, change_id)
  require("jujutsu.buffers.file_history").open(session.root, {
    path = session.path,
    revision = change_id,
  })
end

---@param session AnnotateSession
local function open_drill(session)
  local idx = view_mod.source_index(session.view)
  local line = idx and session.view.lines[idx]
  if not line then
    notify.warn("No annotate line under the cursor")
    return
  end
  local cli = require("jujutsu.jj.cli")
  local res = cli.log.revisions(line.change_id).no_graph.template("description").limit(1).call({
    cwd = session.root,
    hidden = true,
    on_error = function() return false end,
  })
  local desc = (res.code == 0 and res.stdout) or {}
  if #desc == 0 then desc = { line.description ~= "" and line.description or "(no description set)" } end

  local commits = affecting_commits(session, line)
  local lines = {}
  local highlights = {}
  local function add(text, spans, line_hl)
    lines[#lines + 1] = text
    local row = #lines - 1
    for _, span in ipairs(spans or {}) do
      if span.hl and span.end_col > span.col then
        highlights[#highlights + 1] = {
          line = row,
          col = span.col,
          end_col = span.end_col,
          hl = span.hl,
          line_hl = line_hl,
        }
        line_hl = nil
      end
    end
    if line_hl then highlights[#highlights + 1] = { line = row, line_hl = line_hl } end
  end

  local header = string.format("%s  %s  %s", line.change_id, line.author, line.date)
  local author_col = #line.change_id + 2
  local date_col = author_col + #line.author + 2
  add(header, {
    { col = 0, end_col = #line.change_id, hl = "JujutsuAnnotateHash" },
    { col = author_col, end_col = author_col + #line.author, hl = "JujutsuAnnotateAuthor" },
    { col = date_col, end_col = date_col + #line.date, hl = "JujutsuAnnotateDate" },
  })
  add("")
  local empty_desc = #desc == 1 and (desc[1] == "" or desc[1] == "(no description set)")
  for _, text in ipairs(desc) do
    add(text, {
      { col = 0, end_col = #text, hl = empty_desc and "JujutsuSubtle" or "JujutsuDescription" },
    })
  end
  add("")
  local line_label = "Line " .. tostring(line.line_number)
  add(line_label, { { col = 0, end_col = #line_label, hl = "JujutsuSectionHeader" } })
  add(line.content)
  add("")
  local section = "Affecting commits"
  add(section, { { col = 0, end_col = #section, hl = "JujutsuSectionHeader" } })
  local ranges = {}
  local select_line = #lines + 1
  for _, entry in ipairs(commits) do
    local description = entry.description or ""
    local text = string.format("%s  %s", entry.change_id, description)
    local selected = ids_match(entry.change_id, line.change_id)
    local desc_hl = description == "(no description set)" and "JujutsuSubtle" or "JujutsuDescription"
    add(text, {
      { col = 0, end_col = #entry.change_id, hl = "JujutsuChangeIdPrefix" },
      { col = #entry.change_id + 2, end_col = #text, hl = desc_hl },
    }, selected and "JujutsuAnnotateSelected" or nil)
    ranges[#lines] = entry
    if selected then select_line = #lines end
  end
  add("")
  local hint = "<cr> file diff   q close"
  add(hint, { { col = 0, end_col = #hint, hl = "JujutsuHint" } })

  local Buffer = require("jujutsu.ui.buffer")
  local buf = Buffer.create("jujutsu://annotate/drill/" .. line.change_id, "jujutsu-annotate-drill")
  local width = math.min(88, math.floor(vim.o.columns * 0.7))
  local height = math.min(math.max(#lines + 2, 8), math.floor(vim.o.lines * 0.6))
  local win = require("jujutsu.ui.host").open_float(buf.bufnr, {
    width = width,
    height = height,
    title = " Line " .. tostring(line.line_number) .. " ",
    zindex = 90,
  })
  require("jujutsu.hl").setup()
  Buffer.render(buf, lines, highlights)
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_set_cursor, win, { select_line, 0 }) end

  local function close_drill()
    if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if session.view and session.view.win and vim.api.nvim_win_is_valid(session.view.win) then
      pcall(vim.api.nvim_set_current_win, session.view.win)
    end
  end
  local function open_selected()
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local entry = ranges[lnum]
    local change_id = entry and entry.change_id or line.change_id
    close_drill()
    open_file_diff(session, change_id)
  end
  vim.keymap.set("n", "q", close_drill, { buffer = buf.bufnr, silent = true, noremap = true })
  vim.keymap.set("n", "<esc>", close_drill, { buffer = buf.bufnr, silent = true, noremap = true })
  vim.keymap.set("n", "<cr>", open_selected, { buffer = buf.bufnr, silent = true, noremap = true })
end

---@param session AnnotateSession
local function bind_keymaps(session)
  local function map(bufnr, lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu: " .. desc,
    })
  end

  local panel_buf = session.panel.buf.bufnr
  local view_buf = session.view.buf.bufnr

  for _, bufnr in ipairs({ panel_buf, view_buf }) do
    map(bufnr, "q", close_view, "Close")
    map(bufnr, "<esc>", close_view, "Close")
  end

  map(panel_buf, "<cr>", function()
    local item = panel_mod.under_cursor(session.panel)
    if item and item.entry then select_change(session, item.entry) end
  end, "HighlightChange")

  map(panel_buf, "o", function()
    local item = panel_mod.under_cursor(session.panel)
    if item and item.entry then select_change(session, item.entry) end
  end, "HighlightChange")

  map(panel_buf, "<tab>", function() select_adjacent(session, 1) end, "NextChange")
  map(panel_buf, "<s-tab>", function() select_adjacent(session, -1) end, "PrevChange")

  map(panel_buf, "y", function()
    local item = panel_mod.under_cursor(session.panel)
    local entry = item and item.entry
    if not entry and session.panel.selected_change then
      for _, e in ipairs(session.panel.entries) do
        if e.change_id == session.panel.selected_change then
          entry = e
          break
        end
      end
    end
    if entry then
      vim.fn.setreg("+", entry.change_id)
      vim.fn.setreg('"', entry.change_id)
      notify.info("Yanked " .. entry.change_id)
    end
  end, "YankChangeId")

  map(view_buf, "<leader>e", function() panel_mod.focus(session.panel) end, "FocusHistoryPanel")
  map(panel_buf, "<leader>e", function() view_mod.focus(session.view) end, "FocusAnnotate")
  map(view_buf, "<cr>", function() open_drill(session) end, "DrillDown")
  map(view_buf, "]c", function() view_mod.jump_hunk(session.view, 1) end, "NextHunk")
  map(view_buf, "[c", function() view_mod.jump_hunk(session.view, -1) end, "PrevHunk")
end

---Open annotate view for a path, with file history panel at the bottom.
---@param root string
---@param opts? { path?: string, line?: integer, revision?: string }
function M.open(root, opts)
  opts = opts or {}
  require("jujutsu.hl").setup()

  local path = opts.path
  if not path or path == "" then
    notify.warn("annotate requires a file path")
    return
  end

  if instance then close_view() end

  local acfg = cfg()
  local panel_height = acfg.panel_height
    or (config.values.file_history and config.values.file_history.panel_height)
    or 16
  local limit = (config.values.file_history and config.values.file_history.limit) or 200

  local ann_lines, err = view_mod.fetch(root, path, opts.revision)
  if err then
    notify.error(err)
    return
  end

  local host = require("jujutsu.ui.host")
  local regions = host.diff_regions(panel_height)
  local tabpage, view_win, panel_win
  if regions then
    local laid = host.tiles({
      { key = "view", region = regions.top },
      { key = "panel", region = regions.panel, enter = true },
    })
    view_win = laid.view
    panel_win = laid.panel
    tabpage = nil
  else
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    view_win = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    panel_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(panel_win, panel_height)
  end

  local view = view_mod.create(root, view_win, path)
  local panel = panel_mod.create(root, panel_win, path, "jujutsu://annotate/panel/" .. path)

  instance = {
    root = root,
    path = path,
    tabpage = tabpage,
    view = view,
    panel = panel,
    closing = false,
    floating = regions ~= nil,
    wins = { view_win, panel_win },
  }

  view.lines = ann_lines
  view.focus_line = opts.line
  view_mod.render(view)

  panel.entries = panel_mod.load_entries(root, limit, path)
  panel_mod.render(panel, #panel.entries)
  bind_keymaps(instance)

  if opts.line then view_mod.goto_line(view, opts.line) end

  -- Pre-select the change that owns the focused line
  if opts.line then
    for _, row in ipairs(ann_lines) do
      if row.line_number == opts.line then
        local idx = panel_mod.find_entry_index(panel.entries, row.change_id, root)
        if idx then select_change(instance, panel.entries[idx]) end
        break
      end
    end
  elseif #panel.entries > 0 then
    panel.selected_change = panel.entries[1].change_id
    panel_mod.render(panel, #panel.entries)
  end

  view_mod.focus(view)

  local group = vim.api.nvim_create_augroup("JujutsuAnnotate", { clear = true })
  local syncing = false
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = view.buf.bufnr,
    callback = function()
      if syncing or not instance or instance.closing then return end
      local src = view_mod.source_index(instance.view)
      local row = src and instance.view.lines[src]
      if not row or row.change_id == "" or row.change_id == instance.panel.selected_change then return end
      local eindex = panel_mod.find_entry_index(instance.panel.entries, row.change_id, instance.root)
      if not eindex then return end
      syncing = true
      select_change(instance, instance.panel.entries[eindex], { keep_cursor = true })
      syncing = false
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function(ev)
      if not instance or instance.closing or not instance.view.win then return end
      if ev.event == "WinResized" then
        local hit = false
        local windows = vim.v.event and vim.v.event.windows or {}
        for _, id in ipairs(windows) do
          if id == instance.view.win then hit = true end
        end
        if not hit then return end
      end
      local src = view_mod.source_index(instance.view)
      view_mod.render(instance.view)
      local win = instance.view.win
      if src and instance.view.line_rows and instance.view.line_rows[src] and vim.api.nvim_win_is_valid(win) then
        if vim.api.nvim_get_current_win() == win then
          pcall(vim.api.nvim_win_set_cursor, win, { instance.view.line_rows[src], 0 })
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if not instance or instance.closing or not instance.tabpage then return end
      if not vim.api.nvim_tabpage_is_valid(instance.tabpage) then
        instance.closing = true
        view_mod.destroy(instance.view)
        panel_mod.destroy(instance.panel)
        instance = nil
      end
    end,
  })
end

function M.close() close_view() end

---@return boolean
function M.is_open() return instance ~= nil end

---@return table|nil
function M.instance() return instance end

return M
