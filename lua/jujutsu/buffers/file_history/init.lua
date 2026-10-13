local Buffer = require("jujutsu.ui.buffer")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local diff_mod = require("jujutsu.buffers.diff.split")
local panel_mod = require("jujutsu.buffers.file_history.panel")

local M = {}

---@class FileHistoryView
---@field root string
---@field tabpage integer
---@field panel FileHistoryPanel
---@field diff DiffSplit
---@field closing boolean

---@type FileHistoryView|nil
local instance = nil

local function cfg() return config.values.file_history or {} end

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
  diff_mod.destroy(instance.diff)
  panel_mod.destroy(instance.panel)
  instance = nil
  if not floating and tab and vim.api.nvim_tabpage_is_valid(tab) then
    local cur = vim.api.nvim_get_current_tabpage()
    if cur ~= tab then vim.api.nvim_set_current_tabpage(tab) end
    pcall(vim.cmd, "tabclose")
  end
end

---@param view FileHistoryView
---@param entry FileHistoryEntry
---@param path? string
local function select_file(view, entry, path)
  local prefer = view.panel.path
  panel_mod.ensure_files(entry, view.root, prefer)
  if not path then
    if prefer and prefer ~= "" then
      path = prefer
    elseif entry.files and #entry.files > 0 then
      path = entry.files[1].path
    else
      path = nil
    end
  end

  view.panel.selected_change = entry.change_id
  view.panel.selected_path = path
  if not view.panel.path and not entry.open then
    entry.open = true
    panel_mod.ensure_files(entry, view.root, prefer)
  end
  panel_mod.render(view.panel, #view.panel.entries)
  panel_mod.goto_entry(view.panel, entry, path)

  if path then
    diff_mod.show_file(view.diff, entry.change_id, path)
  else
    diff_mod.clear(view.diff)
  end
end

---@param view FileHistoryView
---@param entry FileHistoryEntry
local function toggle_fold(view, entry)
  if view.panel.path and view.panel.path ~= "" then
    -- Single-file mode: no folds; open the path diff instead
    select_file(view, entry, view.panel.path)
    return
  end
  entry.open = not entry.open
  if entry.open then panel_mod.ensure_files(entry, view.root, view.panel.path) end
  panel_mod.render(view.panel, #view.panel.entries)
  panel_mod.goto_entry(view.panel, entry)
end

---@param view FileHistoryView
---@param delta integer
local function select_adjacent(view, delta)
  local entries = view.panel.entries
  if #entries == 0 then return end
  local prefer = view.panel.path
  local single_file = prefer and prefer ~= ""

  local cur_idx = 1
  for i, e in ipairs(entries) do
    if e.change_id == view.panel.selected_change then
      cur_idx = i
      break
    end
  end

  if single_file then
    local next_idx = cur_idx + delta
    if next_idx < 1 or next_idx > #entries then return end
    select_file(view, entries[next_idx], prefer)
    return
  end

  local entry = entries[cur_idx]
  panel_mod.ensure_files(entry, view.root, prefer)
  local files = entry.files or {}
  local path = view.panel.selected_path
  local file_idx = 0
  for i, f in ipairs(files) do
    if f.path == path then
      file_idx = i
      break
    end
  end

  if delta > 0 then
    if file_idx > 0 and file_idx < #files then
      select_file(view, entry, files[file_idx + 1].path)
      return
    end
    local next_idx = cur_idx + 1
    if next_idx > #entries then return end
    local next_entry = entries[next_idx]
    next_entry.open = true
    panel_mod.ensure_files(next_entry, view.root, prefer)
    local npath = next_entry.files and next_entry.files[1] and next_entry.files[1].path
    select_file(view, next_entry, npath)
  else
    if file_idx > 1 then
      select_file(view, entry, files[file_idx - 1].path)
      return
    end
    local prev_idx = cur_idx - 1
    if prev_idx < 1 then return end
    local prev_entry = entries[prev_idx]
    prev_entry.open = true
    panel_mod.ensure_files(prev_entry, view.root, prefer)
    local files_prev = prev_entry.files or {}
    local ppath = files_prev[#files_prev] and files_prev[#files_prev].path
    select_file(view, prev_entry, ppath)
  end
end

---@param view FileHistoryView
local function open_description(view)
  local item = panel_mod.under_cursor(view.panel)
  local entry = item and item.entry
  if not entry then
    if view.panel.selected_change then
      for _, e in ipairs(view.panel.entries) do
        if e.change_id == view.panel.selected_change then
          entry = e
          break
        end
      end
    end
  end
  if not entry then return end

  local res = cli.log.revisions(entry.change_id).no_graph.template("description").limit(1).call({
    cwd = view.root,
    hidden = true,
  })
  local lines = res.stdout or {}
  if #lines == 0 then lines = { "(no description set)" } end

  local buf = Buffer.create("jujutsu://file-history/desc/" .. entry.change_id, "jujutsu-file-history-desc")
  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(math.max(#lines + 2, 6), math.floor(vim.o.lines * 0.5))
  local win = require("jujutsu.ui.host").open_float(buf.bufnr, {
    width = width,
    height = height,
    title = " " .. entry.change_id .. " ",
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

---@param view FileHistoryView
local function bind_keymaps(view)
  local bufnr = view.panel.buf.bufnr
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, noremap = true, desc = "jujutsu: " .. desc })
  end

  map("q", close_view, "Close")
  map("<esc>", close_view, "Close")

  map("<cr>", function()
    local item = panel_mod.under_cursor(view.panel)
    if not item or not item.entry then return end
    if view.panel.path and view.panel.path ~= "" then
      select_file(view, item.entry, view.panel.path)
      return
    end
    if item.kind == "file" and item.file then
      select_file(view, item.entry, item.file.path)
    elseif item.kind == "change" then
      panel_mod.ensure_files(item.entry, view.root, view.panel.path)
      if item.entry.files and #item.entry.files == 1 then
        item.entry.open = true
        select_file(view, item.entry, item.entry.files[1].path)
      else
        toggle_fold(view, item.entry)
      end
    end
  end, "OpenOrToggle")

  map("o", function()
    local item = panel_mod.under_cursor(view.panel)
    if not item or not item.entry then return end
    if view.panel.path and view.panel.path ~= "" then
      select_file(view, item.entry, view.panel.path)
      return
    end
    if item.kind == "file" and item.file then
      select_file(view, item.entry, item.file.path)
    else
      panel_mod.ensure_files(item.entry, view.root, view.panel.path)
      local path = item.entry.files and item.entry.files[1] and item.entry.files[1].path
      item.entry.open = true
      select_file(view, item.entry, path)
    end
  end, "Open")

  map("<tab>", function() select_adjacent(view, 1) end, "NextEntry")
  map("<s-tab>", function() select_adjacent(view, -1) end, "PrevEntry")

  map("za", function()
    local item = panel_mod.under_cursor(view.panel)
    if item and item.entry then toggle_fold(view, item.entry) end
  end, "ToggleFold")

  map("zo", function()
    local item = panel_mod.under_cursor(view.panel)
    if item and item.entry and not item.entry.open then toggle_fold(view, item.entry) end
  end, "OpenFold")

  map("zc", function()
    local item = panel_mod.under_cursor(view.panel)
    if item and item.entry and item.entry.open then toggle_fold(view, item.entry) end
  end, "CloseFold")

  map("y", function()
    local item = panel_mod.under_cursor(view.panel)
    local entry = item and item.entry
    if not entry and view.panel.selected_change then
      for _, e in ipairs(view.panel.entries) do
        if e.change_id == view.panel.selected_change then
          entry = e
          break
        end
      end
    end
    if entry then
      vim.fn.setreg("+", entry.change_id)
      vim.fn.setreg('"', entry.change_id)
      require("jujutsu.notify").info("Yanked " .. entry.change_id)
    end
  end, "YankChangeId")

  map("L", function() open_description(view) end, "Description")

  -- Also allow q from diff buffers
  for _, dbuf in ipairs({ view.diff.left_buf, view.diff.right_buf }) do
    vim.keymap.set("n", "q", close_view, { buffer = dbuf.bufnr, silent = true, noremap = true })
    vim.keymap.set("n", "<leader>e", function() panel_mod.focus(view.panel) end, {
      buffer = dbuf.bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu: FocusHistoryPanel",
    })
  end
end

---Open DiffviewFileHistory-style change history.
---@param root string
---@param opts? { revision?: string, path?: string }
function M.open(root, opts)
  opts = opts or {}
  require("jujutsu.hl").setup()

  if instance then close_view() end

  local fh = cfg()
  local limit = fh.limit or 200
  local panel_height = fh.panel_height or 16
  local path = opts.path

  local host = require("jujutsu.ui.host")
  local regions = host.diff_regions(panel_height)
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
    vim.api.nvim_win_set_height(panel_win, panel_height)
  end

  local panel = panel_mod.create(root, panel_win, path)
  local diff = diff_mod.create(root, left_win, right_win, { host_top = regions and regions.top or nil })

  instance = {
    root = root,
    tabpage = tabpage,
    panel = panel,
    diff = diff,
    closing = false,
    floating = regions ~= nil,
    wins = { left_win, right_win, panel_win },
  }

  panel.entries = panel_mod.load_entries(root, limit, path)
  panel_mod.render(panel, #panel.entries)
  bind_keymaps(instance)

  local idx = panel_mod.find_entry_index(panel.entries, opts.revision, root)
  if not idx and #panel.entries > 0 then idx = 1 end

  if idx then
    local entry = panel.entries[idx]
    if not path then entry.open = true end
    panel_mod.ensure_files(entry, root, path)
    local selected_path = path
    if not selected_path and entry.files and entry.files[1] then selected_path = entry.files[1].path end
    -- Prefer cursor path when present in this change's files
    if path and entry.files then
      for _, f in ipairs(entry.files) do
        if f.path == path then
          selected_path = path
          break
        end
      end
    end
    select_file(instance, entry, selected_path)
  else
    diff_mod.clear(diff)
  end

  panel_mod.focus(panel)

  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("JujutsuFileHistory", { clear = true }),
    callback = function()
      if not instance or instance.closing or not instance.tabpage then return end
      if not vim.api.nvim_tabpage_is_valid(instance.tabpage) then
        instance.closing = true
        diff_mod.destroy(instance.diff)
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
