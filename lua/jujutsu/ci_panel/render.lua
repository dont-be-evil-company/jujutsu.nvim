local ansi = require("jujutsu.ansi")
local gh_log = require("jujutsu.ci_panel.gh_log")
local model = require("jujutsu.ci_panel.model")

local M = {}

---@param lines string[]
---@param highlights table[]
---@param text string
---@param hl? string
---@param line_hl? string
local function push(lines, highlights, text, hl, line_hl)
  table.insert(lines, text)
  local row = #lines - 1
  if hl then
    table.insert(highlights, { line = row, col = 0, end_col = #text, hl = hl, line_hl = line_hl })
  elseif line_hl then
    table.insert(highlights, { line = row, line_hl = line_hl })
  end
end

---@param lines string[]
---@param highlights table[]
---@param text string
---@param col integer
---@param hl string
local function push_seg(lines, highlights, text, col, hl)
  local row = #lines - 1
  table.insert(highlights, { line = row, col = col, end_col = col + #text, hl = hl })
end

---@param run ForgeCiRun
---@return string
local function run_headline(run)
  local title = run.title or run.name or run.id
  local wf = run.workflow or ""
  if wf ~= "" and wf ~= title then return string.format("%s · %s", title, wf) end
  return title
end

---@param text string
---@param width integer
---@return string[]
function M.wrap_text(text, width)
  text = text or ""
  width = math.max(1, math.floor(width or 1))
  if text == "" then return { "" } end
  local out = {}
  local cur = ""
  local function push_word(word)
    if #word > width then
      if cur ~= "" then
        out[#out + 1] = cur
        cur = ""
      end
      local rest = word
      while #rest > width do
        out[#out + 1] = rest:sub(1, width)
        rest = rest:sub(width + 1)
      end
      cur = rest
      return
    end
    if cur == "" then
      cur = word
    elseif #cur + 1 + #word <= width then
      cur = cur .. " " .. word
    else
      out[#out + 1] = cur
      cur = word
    end
  end
  for word in text:gmatch("%S+") do
    push_word(word)
  end
  if cur ~= "" then out[#out + 1] = cur end
  if #out == 0 then out[1] = "" end
  return out
end

local COLUMN_ORDER = { "status", "title", "workflow", "branch", "event", "elapsed", "age" }
local COLUMN_LABEL = {
  status = "STATUS",
  title = "TITLE",
  workflow = "WORKFLOW",
  branch = "BRANCH",
  event = "EVENT",
  elapsed = "ELAPSED",
  age = "AGE",
}

---Choose a table or wrapped card for the CI list.
---@param width integer
---@return { mode: "table"|"card", width: integer, cols?: table<string, integer>, rule?: integer }
function M.plan_columns(width)
  width = math.max(1, math.floor(width or 100))
  if width < 72 then return { mode = "card", width = width } end
  local cols = {
    status = 6,
    title = 42,
    workflow = 14,
    branch = 12,
    event = 8,
    elapsed = 8,
    age = 10,
  }
  local function total()
    local n, count = 0, 0
    for _, key in ipairs(COLUMN_ORDER) do
      if cols[key] > 0 then
        n = n + cols[key]
        count = count + 1
      end
    end
    return n + math.max(0, count - 1) * 2
  end
  for _, key in ipairs({ "elapsed", "event", "branch", "workflow" }) do
    if total() <= width then break end
    cols[key] = 0
  end
  while total() > width and cols.title > 12 do
    cols.title = cols.title - math.min(cols.title - 12, total() - width)
  end
  while total() > width and cols.age > 4 do
    cols.age = cols.age - math.min(cols.age - 4, total() - width)
  end
  if total() > width then return { mode = "card", width = width } end
  local spare = width - total()
  if spare > 0 then cols.title = cols.title + spare end
  return { mode = "table", width = width, cols = cols, rule = width }
end

local function visible_columns(cols)
  local keys = {}
  for _, key in ipairs(COLUMN_ORDER) do
    if cols[key] > 0 then keys[#keys + 1] = key end
  end
  return keys
end

local function fit_cell(text, width)
  if width <= 0 then return nil end
  text = tostring(text or "")
  return model.pad(model.truncate(text, width), width)
end

---@param runs ForgeCiRun[]
---@param remote ForgeRemote
---@param opts? { has_more?: boolean, list_limit?: integer, width?: integer }
---@return string[], table[], { item_ranges: table[] }
function M.build_list(runs, remote, opts)
  opts = opts or {}
  local lines, highlights = {}, {}
  local item_ranges = {}
  local width = opts.width or 100
  local plan = M.plan_columns(width)
  push(lines, highlights, string.format("CI runs · %s/%s", remote.owner, remote.repo), "JujutsuPopupHeading")
  push(lines, highlights, "", nil)

  if plan.mode == "table" then
    local cols = plan.cols
    local keys = visible_columns(cols)
    local header_cells = {}
    for _, key in ipairs(keys) do
      header_cells[#header_cells + 1] = fit_cell(COLUMN_LABEL[key], cols[key])
    end
    push(lines, highlights, table.concat(header_cells, "  "), "JujutsuSectionHeader")
    push(lines, highlights, string.rep("─", math.max(1, math.min(width, plan.rule or width))), "JujutsuSubtle")

    for _, run in ipairs(runs or {}) do
      local eff = model.effective_status(run.status, run.conclusion)
      local icon, icon_hl = model.status_icon(eff)
      local elapsed = model.elapsed_text(run.elapsed, run.started_at, run.updated_at)
      local age = model.format_age(run.created_at or run.started_at)
      local values = {
        status = icon,
        title = run.title or run.name or "?",
        workflow = run.workflow or "?",
        branch = run.branch or "?",
        event = run.event or "?",
        elapsed = elapsed,
        age = age,
      }
      local cells = {}
      for _, key in ipairs(keys) do
        cells[#cells + 1] = fit_cell(values[key], cols[key])
      end
      local start_line = #lines
      table.insert(lines, table.concat(cells, "  "))
      local row = #lines - 1
      table.insert(highlights, { line = row, col = 0, end_col = cols.status, hl = icon_hl })
      table.insert(item_ranges, { start_line = start_line, end_line = row, kind = "run", run = run })
    end
  else
    push(lines, highlights, string.rep("─", math.max(1, width)), "JujutsuSubtle")
    for _, run in ipairs(runs or {}) do
      local eff = model.effective_status(run.status, run.conclusion)
      local icon, icon_hl = model.status_icon(eff)
      local elapsed = model.elapsed_text(run.elapsed, run.started_at, run.updated_at)
      local age = model.format_age(run.created_at or run.started_at)
      local meta_parts = {}
      local function add_meta(value)
        value = value ~= nil and tostring(value) or ""
        if value ~= "" and value ~= "?" then meta_parts[#meta_parts + 1] = value end
      end
      add_meta(run.workflow)
      add_meta(run.branch)
      add_meta(run.event)
      add_meta(elapsed)
      add_meta(age)
      local gap = "  "
      local indent = string.rep(" ", #icon + #gap)
      local title_width = math.max(8, width - #indent)
      local title_lines = M.wrap_text(tostring(run.title or run.name or "?"), title_width)
      local meta_lines = M.wrap_text(table.concat(meta_parts, " · "), title_width)
      local start_line = #lines
      for i, title_line in ipairs(title_lines) do
        if i == 1 then
          table.insert(lines, icon .. gap .. title_line)
          table.insert(highlights, { line = #lines - 1, col = 0, end_col = #icon, hl = icon_hl })
        else
          table.insert(lines, indent .. title_line)
        end
      end
      for _, meta_line in ipairs(meta_lines) do
        if meta_line ~= "" then table.insert(lines, indent .. meta_line) end
      end
      table.insert(item_ranges, { start_line = start_line, end_line = #lines - 1, kind = "run", run = run })
    end
  end

  if #(runs or {}) == 0 then push(lines, highlights, "(no CI runs)", "JujutsuSubtle") end
  if opts.has_more and opts.list_limit then
    push(lines, highlights, "", nil)
    local next_limit = opts.list_limit * 2
    local start_line = #lines
    push(lines, highlights, string.format("+ Load more… (%d → %d)", opts.list_limit, next_limit), "JujutsuHint")
    table.insert(item_ranges, { start_line = start_line, end_line = #lines - 1, kind = "load_more" })
  end
  push(lines, highlights, "", nil)
  local hints = "<cr> open run   o browser   r refresh   q close"
  if opts.has_more then hints = "+ load more   " .. hints end
  push(lines, highlights, hints, "JujutsuHint")
  return lines, highlights, { item_ranges = item_ranges }
end

---@param detail ForgeCiRunDetail
---@return string[], table[], { item_ranges: table[] }
function M.build_run(detail)
  local lines, highlights = {}, {}
  local item_ranges = {}
  local run = detail.run
  local eff = model.effective_status(run.status, run.conclusion)
  local icon, icon_hl = model.status_icon(eff)
  local headline = icon .. " " .. run_headline(run) .. " · " .. tostring(run.id)
  push(lines, highlights, headline, icon_hl)
  local trigger = "Triggered"
  if run.event and run.event ~= "" then trigger = trigger .. " via " .. run.event end
  local age = model.format_age(run.created_at or run.started_at)
  if age ~= "" then trigger = trigger .. " " .. age end
  push(lines, highlights, trigger, "JujutsuSubtle")
  push(lines, highlights, "", nil)
  push(lines, highlights, "JOBS", "JujutsuSectionHeader")

  for _, job in ipairs(detail.jobs or {}) do
    local j_eff = model.effective_status(job.status, job.conclusion)
    local j_icon, j_icon_hl = model.status_icon(j_eff)
    local elapsed = model.elapsed_text(job.elapsed, job.started_at, job.completed_at)
    local text =
      string.format("%s %s in %s (ID %s)", j_icon, job.name or "?", elapsed ~= "" and elapsed or "?", tostring(job.id))
    local start_line = #lines
    push(lines, highlights, text, j_icon_hl)
    local row = #lines - 1
    local id_str = tostring(job.id)
    local id_col = text:find(id_str, 1, true)
    if id_col then push_seg(lines, highlights, id_str, id_col - 1, "JujutsuCiId") end
    table.insert(item_ranges, { start_line = start_line, end_line = row, kind = "job", job = job, run = run })
  end
  if #(detail.jobs or {}) == 0 then push(lines, highlights, "(no jobs)", "JujutsuSubtle") end

  local annotations = detail.annotations or {}
  if #annotations > 0 then
    push(lines, highlights, "", nil)
    push(lines, highlights, "ANNOTATIONS", "JujutsuSectionHeader")
    for _, ann in ipairs(annotations) do
      local prefix = ann.level == "error" and "✗ " or "! "
      local hl = ann.level == "error" and "JujutsuCiFailure" or "JujutsuCiWarning"
      push(lines, highlights, prefix .. (ann.message or ""), hl)
      if ann.context and ann.context ~= "" then push(lines, highlights, ann.context, "JujutsuSubtle") end
    end
  end

  push(lines, highlights, "", nil)
  if run.url and run.url ~= "" then push(lines, highlights, "View this run: " .. run.url, "JujutsuSubtle") end
  push(lines, highlights, "", nil)
  push(
    lines,
    highlights,
    "<cr> open job   l logs   o browser   x cancel   r refresh   <bs> back   q close",
    "JujutsuHint"
  )
  return lines, highlights, { item_ranges = item_ranges }
end

---@param detail ForgeCiJobDetail
---@param caps table
---@return string[], table[], { item_ranges: table[] }
function M.build_job(detail, caps)
  local lines, highlights = {}, {}
  local item_ranges = {}
  local run = detail.run
  local job = detail.job
  local run_eff = model.effective_status(run.status, run.conclusion)
  local run_icon = select(1, model.status_icon(run_eff))
  push(lines, highlights, run_icon .. " " .. run_headline(run) .. " · " .. tostring(run.id), "JujutsuSubtle")
  local age = model.format_age(run.created_at or run.started_at)
  if age ~= "" then push(lines, highlights, "Triggered " .. age, "JujutsuSubtle") end
  push(lines, highlights, "", nil)

  local j_eff = model.effective_status(job.status, job.conclusion)
  local j_icon, j_icon_hl = model.status_icon(j_eff)
  local elapsed = model.elapsed_text(job.elapsed, job.started_at, job.completed_at)
  local header =
    string.format("%s %s in %s (ID %s)", j_icon, job.name or "?", elapsed ~= "" and elapsed or "?", tostring(job.id))
  push(lines, highlights, header, j_icon_hl)
  push(lines, highlights, "", nil)

  local steps = job.steps or {}
  if #steps > 0 then
    for _, step in ipairs(steps) do
      local s_eff = model.effective_status(step.status, step.conclusion)
      local s_icon, s_icon_hl = model.status_icon(s_eff)
      push(lines, highlights, s_icon .. " " .. (step.name or "?"), s_icon_hl)
    end
  else
    push(lines, highlights, "(no steps)", "JujutsuSubtle")
  end

  local annotations = detail.annotations or {}
  if #annotations > 0 then
    push(lines, highlights, "", nil)
    push(lines, highlights, "ANNOTATIONS", "JujutsuSectionHeader")
    for _, ann in ipairs(annotations) do
      push(lines, highlights, "! " .. (ann.message or ""), "JujutsuCiWarning")
      if ann.context and ann.context ~= "" then push(lines, highlights, ann.context, "JujutsuSubtle") end
    end
  end

  push(lines, highlights, "", nil)
  if caps and caps.ci and caps.ci.logs then push(lines, highlights, "Press l to view full job log", "JujutsuHint") end
  if run.url and run.url ~= "" then push(lines, highlights, "View this run: " .. run.url, "JujutsuSubtle") end
  push(lines, highlights, "", nil)
  local hints = "o browser"
  if caps and caps.ci and caps.ci.logs then hints = "l logs   " .. hints end
  push(lines, highlights, hints .. "   r refresh   <bs> back   q close", "JujutsuHint")
  return lines, highlights, { item_ranges = item_ranges }
end

---@param lines string[]
---@param highlights table[]
---@param row integer
---@param col integer
---@param text string
---@param hl string
---@param line_hl? string
local function push_at(lines, highlights, row, col, text, hl, line_hl)
  if #lines <= row then
    while #lines <= row do
      table.insert(lines, "")
    end
  end
  local line = lines[row + 1] or ""
  lines[row + 1] = line .. text
  if hl then
    table.insert(highlights, { line = row, col = col, end_col = col + #text, hl = hl, line_hl = line_hl })
  elseif line_hl then
    table.insert(highlights, { line = row, line_hl = line_hl })
  end
end

---@param lines string[]
---@param highlights table[]
---@param parsed GhLogLine
---@param indent? string
local function append_gh_line(lines, highlights, parsed, indent)
  if parsed.skip then return end
  indent = indent or ""

  local row = #lines
  table.insert(lines, indent)
  local col = #indent

  if parsed.timestamp and parsed.timestamp ~= "" then
    local ts = parsed.timestamp .. " "
    push_at(lines, highlights, row, col, ts, "JujutsuSubtle")
    col = col + #ts
  end

  local kind = parsed.kind or "plain"
  local text = parsed.text or ""

  if kind == "group" or kind == "section" then
    push_at(lines, highlights, row, col, text, "JujutsuSectionHeader")
    return
  end
  if kind == "warning" then
    push_at(lines, highlights, row, col, text, "JujutsuCiWarning")
    return
  end
  if kind == "error" then
    push_at(lines, highlights, row, col, text, "JujutsuCiFailure")
    return
  end
  if kind == "notice" then
    push_at(lines, highlights, row, col, text, "JujutsuCiPending")
    return
  end
  if kind == "debug" then
    push_at(lines, highlights, row, col, text, "JujutsuSubtle")
    return
  end
  if kind == "command" then
    push_at(lines, highlights, row, col, text, "JujutsuCiCommand")
    return
  end

  local content_plain, hls = ansi.line_to_highlights(text, row, col)
  lines[row + 1] = (lines[row + 1] or ""):sub(1, col) .. content_plain
  vim.list_extend(highlights, hls)
end

---@param lines string[]
---@param highlights table[]
---@param line string
---@param parsed? GhLogLine
---@param indent? string
local function append_log_line(lines, highlights, line, parsed, indent)
  indent = indent or ""
  if parsed then
    append_gh_line(lines, highlights, parsed, indent)
    return
  end

  local stripped = ansi.strip(line)
  if stripped:match("^── .+ ──$") then return end

  if gh_log.looks_like_gh_actions(line) or gh_log.looks_like_gh_actions(stripped) then
    append_gh_line(lines, highlights, gh_log.parse(line), indent)
    return
  end

  local row = #lines
  local plain, line_hls = ansi.line_to_highlights(line, row, #indent)
  table.insert(lines, indent .. plain)
  vim.list_extend(highlights, line_hls)
end

---@param lines string[]
---@param highlights table[]
---@param item_ranges table[]
---@param nodes CiLogNode[]
---@param folds table<string, boolean>
---@param depth? integer
local function render_log_nodes(lines, highlights, item_ranges, nodes, folds, depth)
  depth = depth or 0
  local config = require("jujutsu.config")
  local signs = config.values.signs.section or { ">", "v" }
  local indent = string.rep("  ", depth)

  for _, node in ipairs(nodes or {}) do
    if node.kind == "group" then
      local folded = folds[node.id] ~= false
      if node.skipped then folded = true end
      local sign = signs[folded and 1 or 2]
      local title = node.title or "(untitled)"
      local count_text = node.skipped and "(skipped)" or string.format("(%d)", node.count or 0)
      local body = string.format("%s %s %s", sign, title, count_text)
      local text = indent .. body
      local start_line = #lines
      table.insert(lines, text)
      local row = #lines - 1
      local base = #indent
      table.insert(highlights, { line = row, col = base, end_col = base + #sign, hl = "JujutsuFold" })
      table.insert(highlights, {
        line = row,
        col = base + #sign + 1,
        end_col = base + #sign + 1 + #title,
        hl = "JujutsuSectionHeader",
      })
      table.insert(highlights, {
        line = row,
        col = base + #sign + 1 + #title + 1,
        end_col = #text,
        hl = node.skipped and "JujutsuSubtle" or "JujutsuSectionCount",
      })
      table.insert(item_ranges, {
        start_line = start_line,
        end_line = row,
        kind = "log_group",
        group_id = node.id,
        folded = folded,
        skipped = node.skipped,
      })
      if not folded and not node.skipped then
        render_log_nodes(lines, highlights, item_ranges, node.children, folds, depth + 1)
      end
    else
      append_log_line(lines, highlights, node.raw or "", node.parsed, indent)
    end
  end
end

---@param job ForgeCiJob
---@param log_lines string[]
---@param opts? { folds?: table<string, boolean>, tree?: CiLogNode[] }
---@return string[], table[], { item_ranges: table[], tree: CiLogNode[], folds: table<string, boolean> }
function M.build_logs(job, log_lines, opts)
  opts = opts or {}
  local lines, highlights = {}, {}
  local item_ranges = {}
  local tree = opts.tree or gh_log.build_tree(log_lines or {}, {
    steps = job and job.steps or nil,
  })
  local folds = opts.folds
  if not folds then
    local ci = require("jujutsu.config").values.ci_panel or {}
    folds = gh_log.default_folds(tree, ci.logs_folded ~= false)
  end

  push(lines, highlights, string.format("Log · ID %s", tostring(job.id)), "JujutsuPopupHeading")
  push(lines, highlights, "", nil)
  if #(log_lines or {}) == 0 then
    push(lines, highlights, "(empty log)", "JujutsuSubtle")
  else
    render_log_nodes(lines, highlights, item_ranges, tree, folds)
  end
  push(lines, highlights, "", nil)
  push(lines, highlights, "<tab>/za fold   zA fold recursive   <bs> back   q close", "JujutsuHint")
  return lines, highlights, { item_ranges = item_ranges, tree = tree, folds = folds }
end

---@param message string
---@return string[], table[]
function M.build_loading(message)
  return { message or "Loading…" }, { { line = 0, col = 0, end_col = #(message or ""), hl = "JujutsuSubtle" } }
end

---@param message string
---@return string[], table[]
function M.build_error(message)
  local lines, highlights = {}, {}
  push(lines, highlights, "Error", "JujutsuConflict")
  for _, line in ipairs(vim.split(tostring(message or ""), "\n", { plain = true })) do
    push(lines, highlights, line, "JujutsuSubtle")
  end
  push(lines, highlights, "", nil)
  push(lines, highlights, "r refresh   q close", "JujutsuHint")
  return lines, highlights
end

return M
