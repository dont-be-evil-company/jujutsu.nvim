local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local extract = require("jujutsu.merge.extract")
local finder = require("jujutsu.finder")
local mappings = require("jujutsu.ui.mappings")
local model = require("jujutsu.merge.model")
local notify = require("jujutsu.notify")
local util = require("jujutsu.util")

local M = {}

local NS = vim.api.nvim_create_namespace("jujutsu_merge")

---@class MergeView
---@field root string
---@field path string
---@field full string
---@field files string[]
---@field index integer
---@field state table|nil
---@field rendered table|nil
---@field manual boolean
---@field painting boolean
---@field result_snapshot string[]|nil
---@field syncing boolean
---@field closing boolean
---@field floating boolean
---@field tabpage integer|nil
---@field incoming_win integer
---@field current_win integer
---@field result_win integer
---@field incoming_buf integer
---@field current_buf integer
---@field result_buf integer
---@field wins integer[]
---@field bufs integer[]

---@type MergeView|nil
local instance

---@param root string
---@param path string
---@return string
local function abs_path(root, path)
  if path:sub(1, 1) == "/" then return path end
  if root:sub(-1) == "/" then return root .. path end
  return root .. "/" .. path
end

---@param root string
---@param path string
---@return string
local function rel_path(root, path)
  if path:sub(1, 1) ~= "/" then return path end
  local abs = vim.fn.fnamemodify(path, ":p")
  local rootp = vim.fn.fnamemodify(root, ":p")
  if rootp:sub(-1) ~= "/" then rootp = rootp .. "/" end
  if abs:sub(1, #rootp) == rootp then return abs:sub(#rootp + 1) end
  return path
end

---@param path string
---@param text string
---@return boolean, string|nil
local function write_text(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, err or ("could not write " .. path) end
  local ok, werr = f:write(text)
  f:close()
  if not ok then return false, werr or ("could not write " .. path) end
  return true
end

---@param full string
local function edit_file(full)
  if vim.fn.filereadable(full) ~= 1 then return end
  local host = require("jujutsu.ui.host")
  if host.active() then
    host.open_file(full, "edit")
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(full))
end

---@param s string
---@param n integer
---@return string
local function trunc(s, n)
  s = s or ""
  if #s <= n then return s end
  return s:sub(1, math.max(1, n - 1)) .. "…"
end

---@param s string
---@return string
local function esc_bar(s) return (s or ""):gsub("%%", "%%%%") end

---@param title string
---@param detail string
---@param hint string
---@return string
local function winbar(title, detail, hint)
  return table.concat({
    "%#JujutsuHeaderLabel# ",
    esc_bar(title),
    " %#JujutsuChangeId#",
    esc_bar(detail),
    "%#JujutsuSubtle#  ",
    esc_bar(hint),
  })
end

---@param info { change_id: string, subject: string }
---@return string
local function label_detail(info)
  local parts = {}
  if info.change_id ~= "" then parts[#parts + 1] = info.change_id end
  local subject = (info.subject or ""):gsub("%s+", " ")
  if subject ~= "" then parts[#parts + 1] = trunc(subject, 48) end
  return table.concat(parts, " ")
end

local function update_winbar()
  if not instance or not instance.state then return end
  local state = instance.state
  local unresolved = instance.rendered and instance.rendered.unresolved or model.unresolved(state)
  local result_hint
  if instance.manual then
    result_hint = "edited   <CR> accept"
  elseif unresolved > 0 then
    result_hint = string.format("%d unresolved   <CR> accept", unresolved)
  else
    result_hint = "<CR> accept"
  end
  local function set(win, text)
    if win and vim.api.nvim_win_is_valid(win) then vim.wo[win].winbar = text end
  end
  set(instance.incoming_win, winbar("Incoming", label_detail(state.incoming), "A take all"))
  set(instance.current_win, winbar("Current", label_detail(state.current), "C take all"))
  set(instance.result_win, winbar("Result", trunc(instance.path, 48), result_hint))
end

---@param win integer
---@param line integer|nil
local function set_cursor(win, line)
  if not win or not vim.api.nvim_win_is_valid(win) or not line then return end
  local max = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  line = math.max(1, math.min(line, math.max(max, 1)))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
end

---@param buf integer
---@param lines string[]
---@param hls { line: integer, line_hl: string }[]
---@param checks { line: integer, taken: boolean }[]|nil
---@param modifiable boolean
local function paint_buf(buf, lines, hls, checks, modifiable)
  if #lines == 0 then lines = { "" } end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local count = #lines
  for _, h in ipairs(hls or {}) do
    if h.line >= 0 and h.line < count then
      vim.api.nvim_buf_set_extmark(buf, NS, h.line, 0, {
        line_hl_group = h.line_hl,
        hl_mode = "combine",
        priority = 200,
      })
    end
  end
  for _, c in ipairs(checks or {}) do
    if c.line >= 0 and c.line < count then
      local text = c.taken and "✓" or "☐"
      local hl = c.taken and "JujutsuMergeTake" or "JujutsuMergeOpen"
      local ok = pcall(vim.api.nvim_buf_set_extmark, buf, NS, c.line, 0, {
        sign_text = text,
        sign_hl_group = hl,
        priority = 200,
      })
      if not ok and not c.taken then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, c.line, 0, {
          sign_text = "·",
          sign_hl_group = hl,
          priority = 200,
        })
      end
    end
  end
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
end

---@param a string[]|nil
---@param b string[]|nil
---@return boolean
local function same_lines(a, b)
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

---@param jump boolean
local function paint(jump)
  if not instance or not instance.state then return end
  local cursors
  if not jump then
    cursors = {
      incoming = vim.api.nvim_win_is_valid(instance.incoming_win)
        and vim.api.nvim_win_get_cursor(instance.incoming_win)[1],
      current = vim.api.nvim_win_is_valid(instance.current_win)
        and vim.api.nvim_win_get_cursor(instance.current_win)[1],
      result = vim.api.nvim_win_is_valid(instance.result_win) and vim.api.nvim_win_get_cursor(instance.result_win)[1],
    }
  end
  instance.painting = true
  for _, win in ipairs(instance.wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = false
      vim.wo[win].cursorbind = false
    end
  end
  local rendered = model.render(instance.state)
  instance.rendered = rendered
  paint_buf(instance.incoming_buf, rendered.incoming_lines, rendered.incoming_hl, rendered.incoming_checks, false)
  paint_buf(instance.current_buf, rendered.current_lines, rendered.current_hl, rendered.current_checks, false)
  paint_buf(instance.result_buf, rendered.result_lines, rendered.result_hl, nil, true)
  local keep_nl = instance.state.base_nl or instance.state.left_nl or instance.state.right_nl or rendered.unresolved > 0
  vim.bo[instance.result_buf].eol = keep_nl
  vim.bo[instance.result_buf].fixeol = false
  -- TextChanged for this write arrives after paint() returns, with painting
  -- already cleared. Remember the text so that echo is not a hand edit.
  instance.result_snapshot = vim.api.nvim_buf_get_lines(instance.result_buf, 0, -1, false)
  instance.manual = false
  instance.painting = false
  if vim.api.nvim_win_is_valid(instance.incoming_win) then
    vim.wo[instance.incoming_win].scrollbind = true
    vim.wo[instance.incoming_win].cursorbind = true
  end
  if vim.api.nvim_win_is_valid(instance.current_win) then
    vim.wo[instance.current_win].scrollbind = true
    vim.wo[instance.current_win].cursorbind = true
  end
  if jump then
    local row = rendered.first_conflict_row or 1
    local result_row = rendered.first_conflict_result or 1
    set_cursor(instance.incoming_win, row)
    set_cursor(instance.current_win, row)
    set_cursor(instance.result_win, result_row)
    if vim.api.nvim_win_is_valid(instance.result_win) then vim.api.nvim_set_current_win(instance.result_win) end
  elseif cursors then
    set_cursor(instance.incoming_win, cursors.incoming)
    set_cursor(instance.current_win, cursors.current)
    set_cursor(instance.result_win, cursors.result)
  end
  update_winbar()
end

---@param win integer
---@return integer|nil
local function region_id_in(win, line)
  if not instance or not instance.rendered then return nil end
  local id
  if win == instance.result_win then
    id = instance.rendered.result_region[line]
  else
    id = instance.rendered.row_region[line]
  end
  if not id or id == 0 then return nil end
  return id
end

local function region_at_cursor()
  if not instance then return nil end
  local win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(win)[1]
  return region_id_in(win, line), win
end

---@param fn fun()
local function with_rebuild(fn)
  async.void(function()
    if not instance then return end
    if instance.manual then
      local ok = finder.confirm("Rebuild the result and discard edits?")
      if not ok then return end
    end
    fn()
    if instance then paint(false) end
  end)
end

local function toggle_at(win, line)
  if not instance or not instance.state then return end
  local id = region_id_in(win, line)
  if not id then return end
  with_rebuild(function()
    if not instance then return end
    if win == instance.result_win then
      model.cycle(instance.state, id)
      return
    end
    local side
    if win == instance.incoming_win then
      side = instance.state.incoming_side
    else
      side = instance.state.incoming_side == "left" and "right" or "left"
    end
    model.toggle_side(instance.state, id, side)
  end)
end

local function focus_next(dir)
  if not instance then return end
  local order = { instance.incoming_win, instance.current_win, instance.result_win }
  local cur = vim.api.nvim_get_current_win()
  local idx = 1
  for i, win in ipairs(order) do
    if win == cur then
      idx = i
      break
    end
  end
  local nxt = ((idx - 1 + dir) % #order) + 1
  local win = order[nxt]
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
end

local function jump_conflict(dir)
  if not instance or not instance.state then return end
  local id = region_at_cursor()
  local region = model.step_conflict(instance.state, id, dir)
  if not region then return end
  set_cursor(instance.incoming_win, region.display_row)
  set_cursor(instance.current_win, region.display_row)
  set_cursor(instance.result_win, region.result_row)
end

---@param root string
---@param path string
---@param sides table
---@return boolean
local function take_binary(root, path, sides)
  local choice = finder.pick({
    prompt = "Binary conflict in " .. path,
    entries = { "Take incoming", "Take current", "Cancel" },
  })
  if choice ~= "Take incoming" and choice ~= "Take current" then return false end
  local incoming_bytes = sides.incoming_side == "left" and sides.left or sides.right
  local current_bytes = sides.incoming_side == "left" and sides.right or sides.left
  local bytes = choice == "Take incoming" and incoming_bytes or current_bytes
  local ok, werr = write_text(abs_path(root, path), bytes)
  if not ok then
    notify.error(werr or "could not write")
    return false
  end
  require("jujutsu").refresh()
  notify.info("Resolved " .. path)
  return true
end

---@param view MergeView
---@param sides table
---@param path string
---@param index integer
---@return boolean
local function present(view, sides, path, index)
  local base_lines, base_nl = model.split_bytes(sides.base)
  local left_lines, left_nl = model.split_bytes(sides.left)
  local right_lines, right_nl = model.split_bytes(sides.right)
  view.path = path
  view.full = abs_path(view.root, path)
  view.index = index
  view.manual = false
  view.state = model.build({
    base_lines = base_lines,
    left_lines = left_lines,
    right_lines = right_lines,
    base_nl = base_nl,
    left_nl = left_nl,
    right_nl = right_nl,
    marker_len = sides.marker_len,
    incoming_side = sides.incoming_side,
    incoming = sides.incoming,
    current = sides.current,
  })
  local ok_ft, ft = pcall(vim.filetype.match, { filename = path })
  if not ok_ft then ft = nil end
  for _, buf in ipairs(view.bufs) do
    if ft and ft ~= "" then vim.bo[buf].filetype = ft end
  end
  local encoded = util.buf_name_path(path)
  pcall(vim.api.nvim_buf_set_name, view.incoming_buf, "jujutsu://merge/incoming/" .. encoded)
  pcall(vim.api.nvim_buf_set_name, view.current_buf, "jujutsu://merge/current/" .. encoded)
  pcall(vim.api.nvim_buf_set_name, view.result_buf, "jujutsu://merge/result/" .. encoded)
  paint(true)
  return true
end

---@param view MergeView
---@param path string
---@param index integer
---@return boolean
local function show_path(view, path, index)
  local sides, err = extract.export(view.root, path)
  if not sides then
    notify.error(err or ("Could not read conflict sides for " .. path))
    return false
  end
  if sides.binary then
    take_binary(view.root, path, sides)
    return false
  end
  return present(view, sides, path, index)
end

local function shift_file(dir)
  async.void(function()
    if not instance or #instance.files == 0 then return end
    if instance.manual then
      local ok = finder.confirm("Discard edits and open another file?")
      if not ok then return end
    end
    local idx = instance.index + dir
    if idx < 1 then idx = #instance.files end
    if idx > #instance.files then idx = 1 end
    show_path(instance, instance.files[idx], idx)
  end)
end

local function listed(files, path)
  for i, p in ipairs(files) do
    if p == path then return i end
  end
end

---Conflict under the cursor: the status row, or the file in the current buffer.
---@param root string
---@param files string[]
---@return string|nil
local function cursor_conflict(root, files)
  local status = require("jujutsu.buffers.status").instance()
  if status and status.buf and vim.api.nvim_get_current_buf() == status.buf.bufnr and status.line_map then
    local item = status.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    local path = item and item.data and (item.data.path or (item.data.file and item.data.file.path))
    if path and listed(files, path) then return path end
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and not name:match("^jujutsu://") then
    local rel = rel_path(root, vim.fn.fnamemodify(name, ":p"))
    if listed(files, rel) then return rel end
  end
end

local function after_write(path, want_partial)
  local root = instance and instance.root or ""
  local files, listed_ok = extract.list(root)
  if not listed_ok then
    notify.error("Could not refresh conflicts after writing " .. path)
    require("jujutsu").refresh()
    return
  end
  local still = listed(files, path) ~= nil
  require("jujutsu").refresh()
  if not instance then return end
  instance.files = files
  if want_partial and not still then
    notify.error("jj did not keep the remaining conflicts in " .. path)
    return
  end
  if not want_partial and still then
    notify.warn(path .. " is still conflicted")
    return
  end
  if still then
    notify.info("Wrote " .. path)
    local idx = listed(files, path)
    if idx then instance.index = idx end
    return
  end
  notify.info("Resolved " .. path)
  if #files == 0 then
    M.close()
    return
  end
  local idx = math.min(instance.index, #files)
  if idx < 1 then idx = 1 end
  show_path(instance, files[idx], idx)
end

local function accept()
  async.void(function()
    if not instance or not instance.state then return end
    local path = instance.path
    local manual = instance.manual
    local text, unresolved
    if manual then
      local lines = vim.api.nvim_buf_get_lines(instance.result_buf, 0, -1, false)
      local eol = vim.bo[instance.result_buf].eol
      if #lines == 0 or (#lines == 1 and lines[1] == "" and not eol) then
        text = ""
      else
        text = table.concat(lines, "\n")
        if eol then text = text .. "\n" end
      end
      unresolved = 0
    else
      text, unresolved = model.file_text(instance.state)
      if unresolved > 0 then
        local noun = unresolved == 1 and "conflict" or "conflicts"
        local ok = finder.confirm(("%d %s still open. Write a partial resolution?"):format(unresolved, noun))
        if not ok then return end
      end
    end
    local ok, err = write_text(instance.full, text)
    if not ok then
      notify.error(err or "could not write")
      return
    end
    instance.manual = false
    after_write(path, (not manual) and unresolved > 0)
  end)
end

function M.close()
  if not instance or instance.closing then return end
  instance.closing = true
  local tab = instance.tabpage
  local floating = instance.floating
  local wins = instance.wins
  local bufs = instance.bufs
  pcall(vim.api.nvim_del_augroup_by_name, "JujutsuMerge")
  if floating then
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
  end
  instance = nil
  if not floating and tab and vim.api.nvim_tabpage_is_valid(tab) then
    if vim.api.nvim_get_current_tabpage() ~= tab then pcall(vim.api.nvim_set_current_tabpage, tab) end
    pcall(vim.cmd, "tabclose")
  end
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
end

---@param buf integer
---@param actions table
local function bind(buf, actions)
  mappings.apply(buf, "merge", actions)
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    local win = mouse.winid
    if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then return end
    vim.api.nvim_set_current_win(win)
    if mouse.line > 0 then pcall(vim.api.nvim_win_set_cursor, win, { mouse.line, 0 }) end
    local info = vim.fn.getwininfo(win)[1]
    local textoff = info and info.textoff or 0
    if mouse.wincol <= textoff then toggle_at(win, mouse.line) end
  end, { buffer = buf, silent = true, noremap = true, desc = "jujutsu: merge checkbox" })
end

---@param win integer
---@param buf integer
local function configure_win(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = not config.values.disable_line_numbers
  wo.relativenumber = false
  wo.signcolumn = "yes"
  wo.foldenable = false
  wo.cursorline = true
  wo.scrolloff = 0
  wo.winhighlight = "WinBar:JujutsuNormal"
  pcall(function() wo.winfixbuf = true end)
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].undolevels = 1000
  return buf
end

local function layout()
  local host = require("jujutsu.ui.host")
  local incoming_buf = make_buf()
  local current_buf = make_buf()
  local result_buf = make_buf()
  local hw = host.win()
  local panel_lines = hw and math.max(8, math.floor(vim.api.nvim_win_get_height(hw) * 0.45)) or 12
  local regions = host.diff_regions(panel_lines)
  local incoming_win, current_win, result_win, tabpage
  local floating = false
  if regions then
    local laid = host.tiles({
      { key = "incoming", region = regions.left },
      { key = "current", region = regions.right },
      { key = "result", region = regions.panel, enter = true },
    })
    if laid then
      incoming_win = laid.incoming
      current_win = laid.current
      result_win = laid.result
      floating = true
    end
  end
  if not incoming_win then
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    incoming_win = vim.api.nvim_get_current_win()
    -- `rightbelow` keeps Incoming on the left when 'splitright' is off.
    vim.cmd("rightbelow vsplit")
    current_win = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    result_win = vim.api.nvim_get_current_win()
    local height = math.max(8, math.floor((vim.o.lines - vim.o.cmdheight) * 0.42))
    vim.api.nvim_win_set_height(result_win, height)
  end
  configure_win(incoming_win, incoming_buf)
  configure_win(current_win, current_buf)
  configure_win(result_win, result_buf)
  return {
    incoming_win = incoming_win,
    current_win = current_win,
    result_win = result_win,
    incoming_buf = incoming_buf,
    current_buf = current_buf,
    result_buf = result_buf,
    tabpage = tabpage,
    floating = floating,
    wins = { incoming_win, current_win, result_win },
    bufs = { incoming_buf, current_buf, result_buf },
  }
end

local function attach_actions(view)
  local actions = {
    Close = function()
      async.void(function()
        if not instance then return end
        if instance.manual then
          local ok = finder.confirm("Discard merge edits?")
          if not ok then return end
        end
        M.close()
      end)
    end,
    Toggle = function()
      local win = vim.api.nvim_get_current_win()
      local line = vim.api.nvim_win_get_cursor(win)[1]
      toggle_at(win, line)
    end,
    TakeAllIncoming = function()
      with_rebuild(function()
        if instance and instance.state then model.take_all(instance.state, instance.state.incoming_side) end
      end)
    end,
    TakeAllCurrent = function()
      with_rebuild(function()
        if not instance or not instance.state then return end
        local side = instance.state.incoming_side == "left" and "right" or "left"
        model.take_all(instance.state, side)
      end)
    end,
    TakeBoth = function()
      local id = region_at_cursor()
      if not id then return end
      with_rebuild(function()
        if instance and instance.state then model.take_both(instance.state, id) end
      end)
    end,
    NextConflict = function() jump_conflict(1) end,
    PrevConflict = function() jump_conflict(-1) end,
    NextFile = function() shift_file(1) end,
    PrevFile = function() shift_file(-1) end,
    Accept = accept,
    ResetResult = function()
      with_rebuild(function() end)
    end,
    FocusNext = function() focus_next(1) end,
    FocusPrev = function() focus_next(-1) end,
  }
  for _, buf in ipairs(view.bufs) do
    bind(buf, actions)
  end

  local group = vim.api.nvim_create_augroup("JujutsuMerge", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = view.result_buf,
    callback = function()
      if not instance or instance.painting or instance.closing then return end
      if not vim.api.nvim_buf_is_valid(instance.result_buf) then return end
      local lines = vim.api.nvim_buf_get_lines(instance.result_buf, 0, -1, false)
      if same_lines(lines, instance.result_snapshot) then return end
      instance.manual = true
      vim.api.nvim_buf_clear_namespace(instance.result_buf, NS, 0, -1)
      update_winbar()
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(ev)
      if not instance or instance.painting or instance.syncing or instance.closing then return end
      local win = tonumber(ev.match)
      if win ~= instance.incoming_win and win ~= instance.current_win then return end
      if vim.api.nvim_get_current_win() == instance.result_win then return end
      local rendered = instance.rendered
      if not rendered then return end
      local top = vim.fn.line("w0", win)
      local dest = rendered.row_result[top] or 1
      if dest < 1 then dest = 1 end
      instance.syncing = true
      pcall(vim.api.nvim_win_call, instance.result_win, function() vim.fn.winrestview({ topline = dest }) end)
      instance.syncing = false
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if not instance or instance.closing then return end
      local win = tonumber(ev.match)
      for _, ours in ipairs(instance.wins) do
        if ours == win then
          vim.schedule(function()
            if instance and not instance.closing then M.close() end
          end)
          return
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
        local bufs = instance.bufs
        instance = nil
        for _, buf in ipairs(bufs) do
          if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        end
      end
    end,
  })
end

---@param opts { root: string, path?: string, files?: string[] }
local function open_in_coroutine(opts)
  require("jujutsu.hl").setup()
  local root = opts.root
  if not root then
    notify.error("not a jj workspace")
    return
  end
  local files, listed_ok
  if opts.files then
    files = opts.files
  else
    files, listed_ok = extract.list(root)
    if not listed_ok then
      notify.error("Could not list conflicts")
      return
    end
  end
  local explicit = opts.path and rel_path(root, opts.path) or nil
  local path = (explicit and explicit ~= "") and explicit or cursor_conflict(root, files)
  if path and path ~= "" then
    local idx = listed(files, path)
    if not idx and explicit then
      files[#files + 1] = path
      idx = #files
    end
    if idx then
      path = files[idx]
    else
      path = nil
    end
  end
  if not path or path == "" then
    if #files == 0 then
      notify.info("No conflicts")
      return
    end
    if #files == 1 then
      path = files[1]
    else
      path = finder.pick({ prompt = "Resolve conflict", entries = files })
      if not path or path == "" then return end
    end
  end
  local index = listed(files, path) or 1
  local sides, err = extract.export(root, path)
  if not sides then
    notify.error(err or ("Could not read conflict sides for " .. path))
    edit_file(abs_path(root, path))
    return
  end
  if sides.binary then
    take_binary(root, path, sides)
    return
  end

  if instance then M.close() end
  local laid = layout()
  instance = laid
  instance.root = root
  instance.files = files
  instance.path = path
  instance.full = abs_path(root, path)
  instance.index = index
  instance.manual = false
  instance.painting = false
  instance.syncing = false
  instance.closing = false
  attach_actions(instance)
  present(instance, sides, path, index)
end

---@class ResolveOpenOpts
---@field root? string
---@field cwd? string
---@field path? string

---@param opts? ResolveOpenOpts
function M.open(opts)
  if not coroutine.running() then
    async.void(function() M.open(opts) end)
    return
  end
  opts = opts or {}
  local root = opts.root
  if not root then root = cli.find_workspace_root(opts.cwd or vim.fn.getcwd()) end
  open_in_coroutine({ root = root, path = opts.path })
end

function M.is_open() return instance ~= nil end

return M
