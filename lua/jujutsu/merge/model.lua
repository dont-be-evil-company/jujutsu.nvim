-- Three-way merge of a base and two sides.
-- `left` / `right` are jj's conflict sides (add 0 and add 1). Snapshot conflict
-- markers have to keep that order. Incoming / Current is only a display mapping.

local M = {}

local HL = {
  add = "JujutsuMergeAdd",
  delete = "JujutsuMergeDelete",
  filler = "JujutsuMergeFiller",
  conflict = "JujutsuMergeConflict",
  combined = "JujutsuMergeCombined",
}

---@param data string|nil
---@return string[], boolean ended_with_newline
function M.split_bytes(data)
  if not data or data == "" then return {}, false end
  local nl = data:sub(-1) == "\n"
  if nl then data = data:sub(1, -2) end
  if data == "" then return {}, true end
  local lines = {}
  local rest = data
  while true do
    local nl_at = rest:find("\n", 1, true)
    if not nl_at then
      lines[#lines + 1] = rest
      break
    end
    lines[#lines + 1] = rest:sub(1, nl_at - 1)
    rest = rest:sub(nl_at + 1)
  end
  return lines, nl
end

---@param lines string[]
---@param min_len integer
---@return integer
function M.marker_len_for(lines, min_len)
  local len = math.max(min_len or 7, 7)
  local found = 0
  for _, line in ipairs(lines) do
    local b = line:byte(1)
    if b then
      local i = 1
      while line:byte(i) == b do
        i = i + 1
      end
      local run = i - 1
      local ch = string.char(b)
      local marker = ch == "<" or ch == ">" or ch == "=" or ch == "+" or ch == "-" or ch == "|" or ch == "%"
      local nxt = line:byte(run + 1)
      if marker and run >= 7 and (not nxt or nxt == 32 or nxt == 9) and run > found then found = run end
    end
  end
  if found >= len then len = found + 4 end
  return len
end

---@param text string
---@return integer
function M.marker_len_in(text)
  local lines = M.split_bytes(text)
  local found = 0
  for _, line in ipairs(lines) do
    if line:match("^<<<<<<<") or line:match("^<<<<<<<+") then
      local run = line:match("^(<+)")
      if run and #run > found then found = #run end
    end
  end
  return math.max(found, 7)
end

---@param a string[]
---@param b string[]
---@return integer[][]
local function diff_hunks(a, b)
  local as = table.concat(a, "\n")
  local bs = table.concat(b, "\n")
  if #a > 0 then as = as .. "\n" end
  if #b > 0 then bs = bs .. "\n" end
  -- Myers keeps matching braces and blank lines as context. Histogram folds them
  -- into a neighboring hunk and the two sides no longer line up.
  local hunks = vim.text.diff(as, bs, { result_type = "indices", algorithm = "myers" })
  return hunks or {}
end

---@param h integer[]
---@return table
local function hunk_item(h, side)
  local sa, ca = h[1], h[2]
  if ca == 0 then return { insert_only = true, insert_at = sa, side = side, hunk = h } end
  if sa < 1 then sa = 1 end
  return { insert_only = false, lo = sa, hi = sa + ca, side = side, hunk = h }
end

---@param item table
---@return integer, integer, boolean
local function span_of(item)
  if item.insert_only then return item.insert_at, item.insert_at, true end
  return item.lo, item.hi, false
end

---@param a table
---@param b table
---@return boolean
local function overlaps(a, b)
  local a_lo, a_hi, a_pt = span_of(a)
  local b_lo, b_hi, b_pt = span_of(b)
  if a_pt and b_pt then return a_lo == b_lo end
  if a_pt then return b_lo <= a_lo and a_lo < b_hi end
  if b_pt then return a_lo <= b_lo and b_lo < a_hi end
  return a_lo < b_hi and b_lo < a_hi
end

---@param items table[]
---@return table[]
local function cluster_items(items)
  table.sort(items, function(a, b)
    local function key(item)
      if item.insert_only then return item.insert_at, 1 end
      return item.lo, 0
    end
    local ak, as = key(a)
    local bk, bs = key(b)
    if ak ~= bk then return ak < bk end
    return as < bs
  end)
  local clusters = {}
  local cur = nil
  local function touches(cluster, item)
    for _, existing in ipairs(cluster) do
      if overlaps(existing, item) then return true end
    end
    return false
  end
  for _, item in ipairs(items) do
    if cur and touches(cur, item) then
      cur[#cur + 1] = item
    else
      cur = { item }
      clusters[#clusters + 1] = cur
    end
  end
  return clusters
end

---@param a string[]
---@param b string[]
---@return boolean
local function same_text(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

---@param lines string[]
---@param lo integer
---@param hi integer
---@return string[]
local function slice(lines, lo, hi)
  local out = {}
  for i = lo, hi - 1 do
    out[#out + 1] = lines[i] or ""
  end
  return out
end

---@param hunks integer[][]
local function sort_hunks(hunks)
  table.sort(hunks, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
end

---@param side string[]
---@param hunks integer[][]
---@return string[]
local function inserted_lines(side, hunks)
  local out = {}
  for _, h in ipairs(hunks) do
    local sb, cb = h[3], h[4]
    for n = sb, sb + cb - 1 do
      out[#out + 1] = side[n] or ""
    end
  end
  return out
end

---Side's text for base lines [lo, hi). Unchanged base lines inside the span are kept.
---@param base string[]
---@param side string[]
---@param hunks integer[][]
---@param lo integer
---@param hi integer
---@return string[]
local function apply_hunks(base, side, hunks, lo, hi)
  sort_hunks(hunks)
  local out = {}
  local i = lo
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 then
      if sa >= lo and sa < hi then
        while i <= sa and i < hi do
          out[#out + 1] = base[i] or ""
          i = i + 1
        end
        for n = sb, sb + cb - 1 do
          out[#out + 1] = side[n] or ""
        end
      end
    elseif sa + ca > lo and sa < hi then
      while i < sa do
        out[#out + 1] = base[i] or ""
        i = i + 1
      end
      for n = sb, sb + cb - 1 do
        out[#out + 1] = side[n] or ""
      end
      i = sa + ca
    end
  end
  while i < hi do
    out[#out + 1] = base[i] or ""
    i = i + 1
  end
  return out
end

---@param base string[]
---@param side string[]
---@param hunks integer[][]
---@param lo integer
---@param hi integer
---@return { text: string, kind: string }[]
local function annotate(base, side, hunks, lo, hi)
  sort_hunks(hunks)
  local rows = {}
  local function add(text, kind) rows[#rows + 1] = { text = text, kind = kind } end
  local i = lo
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 then
      if sa >= lo and sa < hi then
        while i <= sa and i < hi do
          add(base[i] or "", "context")
          i = i + 1
        end
        for n = sb, sb + cb - 1 do
          add(side[n] or "", "add")
        end
      end
    elseif sa + ca > lo and sa < hi then
      while i < sa do
        add(base[i] or "", "context")
        i = i + 1
      end
      for n = sa, sa + ca - 1 do
        add(base[n] or "", "delete")
      end
      for n = sb, sb + cb - 1 do
        add(side[n] or "", "add")
      end
      i = sa + ca
    end
  end
  while i < hi do
    add(base[i] or "", "context")
    i = i + 1
  end
  return rows
end

---@param side string[]
---@param hunks integer[][]
---@return { text: string, kind: string }[]
local function annotate_insert(side, hunks)
  local rows = {}
  for _, line in ipairs(inserted_lines(side, hunks)) do
    rows[#rows + 1] = { text = line, kind = "add" }
  end
  if #rows == 0 then rows[1] = { text = "", kind = "filler" } end
  return rows
end

---@param cluster table[]
---@param id integer
---@param base string[]
---@param left string[]
---@param right string[]
---@return table
local function region_from(cluster, id, base, left, right)
  local left_hunks, right_hunks = {}, {}
  local insert_only = true
  local insert_at = nil
  local lo, hi = nil, nil
  for _, item in ipairs(cluster) do
    if item.side == "left" then
      left_hunks[#left_hunks + 1] = item.hunk
    else
      right_hunks[#right_hunks + 1] = item.hunk
    end
    if item.insert_only then
      insert_at = item.insert_at
    else
      insert_only = false
      lo = lo and math.min(lo, item.lo) or item.lo
      hi = hi and math.max(hi, item.hi) or item.hi
    end
  end
  local region = {
    id = id,
    conflict = #left_hunks > 0 and #right_hunks > 0,
    left_change = #left_hunks > 0,
    right_change = #right_hunks > 0,
    left_hunks = left_hunks,
    right_hunks = right_hunks,
    insert_only = insert_only,
  }
  if insert_only then
    region.insert_at = insert_at or 0
    region.base_lines = {}
    region.left_lines = inserted_lines(left, left_hunks)
    region.right_lines = inserted_lines(right, right_hunks)
  else
    region.lo = lo
    region.hi = hi
    region.base_lines = slice(base, lo, hi)
    region.left_lines = apply_hunks(base, left, left_hunks, lo, hi)
    region.right_lines = apply_hunks(base, right, right_hunks, lo, hi)
  end
  if region.conflict and same_text(region.left_lines, region.right_lines) then
    -- Both sides edited this span and landed on the same text.
    region.conflict = false
    region.take_left = true
    region.take_right = true
  elseif region.conflict then
    region.take_left = false
    region.take_right = false
  else
    region.take_left = region.left_change
    region.take_right = region.right_change
  end
  return region
end

---@class MergeBuild
---@field base_lines string[]
---@field left_lines string[]
---@field right_lines string[]
---@field base_nl boolean
---@field left_nl boolean
---@field right_nl boolean
---@field marker_len integer
---@field incoming_side "left"|"right"
---@field incoming { change_id: string, subject: string }
---@field current { change_id: string, subject: string }

---@param input MergeBuild
---@return table
function M.build(input)
  local base = input.base_lines or {}
  local left = input.left_lines or {}
  local right = input.right_lines or {}
  local items = {}
  for _, h in ipairs(diff_hunks(base, left)) do
    items[#items + 1] = hunk_item(h, "left")
  end
  for _, h in ipairs(diff_hunks(base, right)) do
    items[#items + 1] = hunk_item(h, "right")
  end
  local regions = {}
  for _, cluster in ipairs(cluster_items(items)) do
    regions[#regions + 1] = region_from(cluster, #regions + 1, base, left, right)
  end
  local content_lines = {}
  vim.list_extend(content_lines, base)
  vim.list_extend(content_lines, left)
  vim.list_extend(content_lines, right)
  return {
    base = base,
    left = left,
    right = right,
    base_nl = input.base_nl ~= false,
    left_nl = input.left_nl ~= false,
    right_nl = input.right_nl ~= false,
    marker_len = M.marker_len_for(content_lines, input.marker_len or 7),
    incoming_side = input.incoming_side == "right" and "right" or "left",
    incoming = input.incoming or { change_id = "", subject = "" },
    current = input.current or { change_id = "", subject = "" },
    regions = regions,
  }
end

---@param state table
---@param id integer
---@return table|nil
function M.region(state, id)
  for _, region in ipairs(state.regions) do
    if region.id == id then return region end
  end
end

---@param state table
---@return integer
function M.unresolved(state)
  local n = 0
  for _, region in ipairs(state.regions) do
    if region.conflict and not region.take_left and not region.take_right then n = n + 1 end
  end
  return n
end

---@param state table
---@param id integer
---@param side "left"|"right"
---@return boolean
function M.toggle_side(state, id, side)
  local region = M.region(state, id)
  if not region then return false end
  if side == "left" and not region.left_change then return false end
  if side == "right" and not region.right_change then return false end
  local key = "take_" .. side
  region[key] = not region[key]
  return true
end

---Cycle a conflict: neither, incoming, current, both.
---@param state table
---@param id integer
---@return boolean
function M.cycle(state, id)
  local region = M.region(state, id)
  if not region then return false end
  if not region.conflict then
    local side = region.left_change and "left" or "right"
    return M.toggle_side(state, id, side)
  end
  local inc = state.incoming_side
  local cur = inc == "left" and "right" or "left"
  local ti = region["take_" .. inc]
  local tc = region["take_" .. cur]
  if not ti and not tc then
    region["take_" .. inc] = true
  elseif ti and not tc then
    region["take_" .. inc] = false
    region["take_" .. cur] = true
  elseif tc and not ti then
    region["take_" .. inc] = true
  else
    region["take_" .. inc] = false
    region["take_" .. cur] = false
  end
  return true
end

---@param state table
---@param side "left"|"right"
function M.take_all(state, side)
  local other = side == "left" and "right" or "left"
  for _, region in ipairs(state.regions) do
    if region.conflict then
      region["take_" .. side] = true
      region["take_" .. other] = false
    end
  end
end

---@param state table
---@param id integer
---@return boolean
function M.take_both(state, id)
  local region = M.region(state, id)
  if not region or not region.conflict then return false end
  region.take_left = true
  region.take_right = true
  return true
end

---@param state table
---@param id integer|nil
---@param dir integer
---@return table|nil
function M.step_conflict(state, id, dir)
  local idx = 0
  for i, region in ipairs(state.regions) do
    if region.id == id then
      idx = i
      break
    end
  end
  local i = idx == 0 and (dir > 0 and 1 or #state.regions) or (idx + dir)
  while i >= 1 and i <= #state.regions do
    if state.regions[i].conflict then return state.regions[i] end
    i = i + dir
  end
end

---@param ch string
---@param len integer
---@param suffix string
---@return string
local function marker(ch, len, suffix) return string.rep(ch, len) .. " " .. suffix end

---@param state table
---@param side "left"|"right"
---@return string
local function side_label(state, side)
  local incoming = side == state.incoming_side
  local info = incoming and state.incoming or state.current
  local parts = { incoming and "Incoming" or "Current" }
  if info.change_id and info.change_id ~= "" then parts[#parts + 1] = info.change_id end
  if info.subject and info.subject ~= "" then parts[#parts + 1] = info.subject end
  return table.concat(parts, " ")
end

---@param state table
---@param region table
---@param index integer
---@param count integer
---@return string[]
local function unresolved_lines(state, region, index, count)
  local len = state.marker_len
  local lines = { marker("<", len, string.format("conflict %d of %d", index, count)) }
  local function section(ch, label, content)
    lines[#lines + 1] = marker(ch, len, label)
    for _, line in ipairs(content) do
      lines[#lines + 1] = line
    end
  end
  -- Side #1 is jj add(0), side #2 is add(1). Labels are display names only.
  section("+", side_label(state, "left"), region.left_lines)
  section("-", "base", region.base_lines)
  section("+", side_label(state, "right"), region.right_lines)
  lines[#lines + 1] = marker(">", len, string.format("conflict %d of %d ends", index, count))
  return lines
end

---@param state table
---@param region table
---@return string[]|nil, string
local function chosen_lines(state, region)
  local inc = state.incoming_side
  local cur = inc == "left" and "right" or "left"
  if region.conflict then
    if not region.take_left and not region.take_right then return nil, "conflict" end
    local lines = {}
    local function append(side)
      local block = side == "left" and region.left_lines or region.right_lines
      for _, line in ipairs(block) do
        lines[#lines + 1] = line
      end
    end
    if region["take_" .. inc] then append(inc) end
    if region["take_" .. cur] then append(cur) end
    local kind = (region.take_left and region.take_right) and "combined" or "add"
    return lines, kind
  end
  if region.left_change and region.right_change then
    if region.take_left or region.take_right then return region.left_lines, "add" end
    return region.base_lines, "context"
  end
  local side = region.left_change and "left" or "right"
  if region["take_" .. side] then
    local block = side == "left" and region.left_lines or region.right_lines
    return block, "add"
  end
  return region.base_lines, "context"
end

---@param rows { text: string, kind: string }[]
---@param n integer
local function pad_rows(rows, n)
  while #rows < n do
    rows[#rows + 1] = { text = "", kind = "filler" }
  end
end

---@param region table
---@param state table
---@param side "left"|"right"
---@return { text: string, kind: string }[]
local function pane_rows(region, state, side)
  local lines = side == "left" and state.left or state.right
  local hunks = side == "left" and region.left_hunks or region.right_hunks
  if region.insert_only then return annotate_insert(lines, hunks) end
  if #hunks == 0 then
    local rows = {}
    for _, line in ipairs(region.base_lines) do
      rows[#rows + 1] = { text = line, kind = "context" }
    end
    if #rows == 0 then rows[1] = { text = "", kind = "filler" } end
    return rows
  end
  return annotate(state.base, lines, hunks, region.lo, region.hi)
end

---@param rows { text: string, kind: string }[]
---@param side "left"|"right"
---@param region table
---@return integer|nil
local function checkbox_index(rows, side, region)
  local changed = side == "left" and region.left_change or region.right_change
  if not changed then return nil end
  for i, row in ipairs(rows) do
    if row.kind == "add" or row.kind == "delete" then return i end
  end
  return 1
end

---@param state table
---@return table
function M.render(state)
  local left_rows, right_rows = {}, {}
  local result_lines, result_kinds = {}, {}
  local row_region, row_result = {}, {}
  local result_region = {}
  local unresolved = M.unresolved(state)
  local conflict_i = 0

  local function add_context(from, to)
    for i = from, to do
      local text = state.base[i] or ""
      left_rows[#left_rows + 1] = { text = text, kind = "context" }
      right_rows[#right_rows + 1] = { text = text, kind = "context" }
      result_lines[#result_lines + 1] = text
      result_kinds[#result_kinds + 1] = "context"
      row_region[#row_region + 1] = 0
      row_result[#row_result + 1] = #result_lines
      result_region[#result_region + 1] = 0
    end
  end

  local cursor = 1
  for _, region in ipairs(state.regions) do
    if region.insert_only then
      local through = region.insert_at or 0
      if through >= cursor then add_context(cursor, through) end
      cursor = through + 1
    else
      if region.lo > cursor then add_context(cursor, region.lo - 1) end
      cursor = region.hi
    end

    region.display_row = #left_rows + 1
    region.result_row = #result_lines + 1

    local lrows = pane_rows(region, state, "left")
    local rrows = pane_rows(region, state, "right")
    pad_rows(lrows, #rrows)
    pad_rows(rrows, #lrows)
    region.check_left = checkbox_index(lrows, "left", region)
    region.check_right = checkbox_index(rrows, "right", region)

    local chosen, kind = chosen_lines(state, region)
    local produced
    if not chosen then
      conflict_i = conflict_i + 1
      produced = unresolved_lines(state, region, conflict_i, unresolved)
      kind = "conflict"
    else
      produced = chosen
    end
    local result_at = #result_lines + 1
    if #produced == 0 then result_at = math.max(#result_lines, 1) end
    for _, line in ipairs(produced) do
      result_lines[#result_lines + 1] = line
      result_kinds[#result_kinds + 1] = kind
      result_region[#result_region + 1] = region.id
    end
    if #produced > 0 then region.result_row = result_at end

    for i = 1, #lrows do
      left_rows[#left_rows + 1] = lrows[i]
      right_rows[#right_rows + 1] = rrows[i]
      row_region[#row_region + 1] = region.id
      local dest = result_at
      if #produced > 1 then dest = result_at + math.min(i - 1, #produced - 1) end
      row_result[#row_result + 1] = dest
    end
  end
  if cursor <= #state.base then add_context(cursor, #state.base) end

  local function texts(rows)
    local lines = {}
    for _, row in ipairs(rows) do
      lines[#lines + 1] = row.text
    end
    return lines
  end

  local function highlights(rows, kinds)
    local hl = {}
    local src = rows or kinds
    for i, item in ipairs(src) do
      local kind = rows and item.kind or item
      local group = HL[kind]
      if group then hl[#hl + 1] = { line = i - 1, line_hl = group } end
    end
    return hl
  end

  local incoming_checks, current_checks = {}, {}
  for _, region in ipairs(state.regions) do
    local function put(which, rel, taken)
      if not rel then return end
      local line = region.display_row + rel - 2
      local entry = { line = line, taken = taken, region = region.id }
      if which == state.incoming_side then
        incoming_checks[#incoming_checks + 1] = entry
      else
        current_checks[#current_checks + 1] = entry
      end
    end
    put("left", region.check_left, region.take_left)
    put("right", region.check_right, region.take_right)
  end

  local function pane(side)
    local rows = side == "left" and left_rows or right_rows
    return texts(rows), highlights(rows)
  end

  local inc = state.incoming_side
  local cur = inc == "left" and "right" or "left"
  local incoming_lines, incoming_hl = pane(inc)
  local current_lines, current_hl = pane(cur)

  local first_conflict_row, first_conflict_result
  for _, region in ipairs(state.regions) do
    if region.conflict then
      first_conflict_row = region.display_row
      first_conflict_result = region.result_row
      break
    end
  end

  return {
    incoming_lines = incoming_lines,
    current_lines = current_lines,
    incoming_hl = incoming_hl,
    current_hl = current_hl,
    result_lines = result_lines,
    result_hl = highlights(nil, result_kinds),
    incoming_checks = incoming_checks,
    current_checks = current_checks,
    row_region = row_region,
    row_result = row_result,
    result_region = result_region,
    unresolved = unresolved,
    first_conflict_row = first_conflict_row,
    first_conflict_result = first_conflict_result,
  }
end

---@param state table
---@return string, integer
function M.file_text(state)
  local rendered = M.render(state)
  local lines = rendered.result_lines
  local unresolved = rendered.unresolved
  local function keep_nl() return state.base_nl or state.left_nl or state.right_nl or unresolved > 0 end
  if #lines == 0 then return keep_nl() and "\n" or "", unresolved end
  local text = table.concat(lines, "\n")
  if keep_nl() then text = text .. "\n" end
  return text, unresolved
end

return M
