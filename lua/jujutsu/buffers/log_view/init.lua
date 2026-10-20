local Buffer = require("jujutsu.ui.buffer")
local Graph = require("jujutsu.buffers.log_view.graph")
local async = require("jujutsu.async")
local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local mappings = require("jujutsu.ui.mappings")

local M = {}

local SEP, REC = "\x1f", "\x1e"

local function field_template(fields)
  local parts = { string.format('"\\x01" ++ %s', fields[1]) }
  for i = 2, #fields do
    table.insert(parts, string.format('"\\x1f" ++ %s', fields[i]))
  end
  return table.concat(parts, " ++ ") .. ' ++ "\\x1e"'
end

---Split change id into shortest unique prefix + rest for neoJJ-style coloring.
---@param change_id string
---@param shortest? string
---@return string, string, integer
local function split_change_id(change_id, shortest)
  local short = change_id:sub(1, 8)
  local prefix_len = shortest and math.min(#shortest, #short) or math.min(4, #short)
  if prefix_len < 1 then prefix_len = 1 end
  return short:sub(1, prefix_len), short:sub(prefix_len + 1), prefix_len
end

---@param graph_cfg table
---@return string
local function toml_string(value) return vim.inspect(tostring(value)) end

---@param root string
---@param revset? string
function M.open(root, revset)
  revset = revset or "all()"
  local buf = Buffer.create("jujutsu://log/" .. revset, "jujutsu-log")
  Buffer.open(buf, config.values.log_view.kind or "tab")

  local tmpl = field_template({
    "change_id.short(8)",
    "commit_id.short(8)",
    'bookmarks.join(",")',
    "description.first_line()",
    'if(conflict, "true", "false")',
    'if(empty, "true", "false")',
    'if(current_working_copy, "true", "false")',
    "change_id.shortest(4)",
    'if(immutable, "true", "false")',
    'if(divergent, "true", "false")',
  })

  local line_map = {}

  local function refresh()
    local graph_cfg = (config.values.log_view and config.values.log_view.graph) or {}
    local graph_enabled = graph_cfg.enabled ~= false
    local symbols = graph_cfg.symbols or {}
    local style = graph_cfg.style or "curved"

    local builder = cli.log.revisions(revset).template(tmpl).limit(200)
    if graph_enabled then
      builder = builder.config("ui.graph.style", toml_string(style))
    else
      builder = builder.no_graph
    end

    local res = builder.call({ cwd = root, hidden = true })
    local lines = {}
    local highlights = {}
    line_map = {}

    local function emit_revision(graph_prefix, rec)
      local f = vim.split(rec:gsub("\n", ""), SEP, { plain = true })
      if not f[1] or f[1] == "" then return end

      local change_id = f[1]
      local commit_id = f[2] or ""
      local bookmarks = (f[3] and f[3] ~= "") and vim.split(f[3], ",", { plain = true }) or {}
      local desc = (f[4] and f[4] ~= "") and f[4] or "(no description set)"
      local conflict = f[5] == "true"
      local empty = f[6] == "true"
      local working_copy = f[7] == "true"
      local shortest = f[8] or ""
      local immutable = f[9] == "true"
      local divergent = f[10] == "true"

      local parts = {}
      local hls = {}
      local col = 0

      local function push(str, hl)
        table.insert(parts, str)
        if hl and #str > 0 then table.insert(hls, { col = col, end_col = col + #str, hl = hl }) end
        col = col + #str
      end

      if graph_enabled and graph_prefix and graph_prefix ~= "" then
        local node = Graph.node_symbol(symbols, {
          working_copy = working_copy,
          immutable = immutable,
          conflict = conflict,
        })
        push(Graph.rewrite_node(graph_prefix, node), "JujutsuGraph")
      end

      local prefix, rest = split_change_id(change_id, shortest)
      local id_prefix_hl = working_copy and "JujutsuWorkingCopy" or "JujutsuChangeIdPrefix"
      local id_rest_hl = working_copy and "JujutsuWorkingCopy" or "JujutsuChangeIdRest"
      push(prefix, id_prefix_hl)
      if rest ~= "" then push(rest, id_rest_hl) end

      push(" ", nil)
      push(commit_id:sub(1, 8), "JujutsuCommitId")

      for _, bm in ipairs(bookmarks) do
        push(" ", nil)
        push(bm, "JujutsuBranch")
      end

      push(" ", nil)
      push(desc, desc ~= "(no description set)" and "JujutsuDescription" or "JujutsuSubtle")

      local status_parts = {}
      if empty then table.insert(status_parts, "empty") end
      if conflict then table.insert(status_parts, "conflict") end
      if divergent then table.insert(status_parts, "divergent") end
      if #status_parts > 0 then
        local status_hl = divergent and "JujutsuDivergent" or (conflict and "JujutsuConflict" or "JujutsuSubtle")
        push(" (" .. table.concat(status_parts, ", ") .. ")", status_hl)
      end

      local row = #lines + 1
      lines[row] = table.concat(parts)
      for _, h in ipairs(hls) do
        table.insert(highlights, {
          line = row - 1,
          col = h.col,
          end_col = h.end_col,
          hl = h.hl,
        })
      end
      line_map[row] = {
        change_id = change_id,
        commit_id = commit_id,
        bookmarks = bookmarks,
        description = f[4] or "",
        conflict = conflict,
        empty = empty,
        divergent = divergent,
        working_copy = working_copy,
        immutable = immutable,
      }
    end

    local text = table.concat(res.stdout, "\n")
    -- Physical lines matter for graph connectors; a line may hold multiple
    -- sentinel/RS records when --no-graph packs output without newlines.
    for raw_line in (text .. "\n"):gmatch("(.-)\n") do
      if not raw_line:find(Graph.SENTINEL, 1, true) then
        if graph_enabled and raw_line:match("%S") then
          local drawn = Graph.rewrite_elided(raw_line, symbols.elided or "~")
          local row = #lines + 1
          lines[row] = drawn
          if #drawn > 0 then
            table.insert(highlights, { line = row - 1, col = 0, end_col = #drawn, hl = "JujutsuGraph" })
          end
        end
      else
        local pos = 1
        local first = true
        while true do
          local s, e = raw_line:find(Graph.SENTINEL, pos, true)
          if not s then break end
          local graph_prefix = first and raw_line:sub(1, s - 1) or ""
          first = false
          local rec_end = raw_line:find(REC, e + 1, true)
          local rec
          if rec_end then
            rec = raw_line:sub(e + 1, rec_end - 1)
            pos = rec_end + 1
          else
            rec = raw_line:sub(e + 1)
            pos = #raw_line + 1
          end
          emit_revision(graph_prefix, rec)
        end
      end
    end

    if #lines == 0 then
      lines = { "(empty log)" }
      highlights = {
        { line = 0, col = 0, end_col = #"(empty log)", hl = "JujutsuSubtle" },
      }
    end
    Buffer.render(buf, lines, highlights)
  end

  local function under_cursor()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return line_map[row]
  end

  local function run(builder)
    async.void(function()
      builder.call_async({ cwd = root, hidden = false })
      vim.schedule(refresh)
      require("jujutsu").refresh()
    end)
  end

  mappings.apply(buf.bufnr, "log_view", {
    Close = function() Buffer.close(buf) end,
    RefreshBuffer = refresh,
    OpenCommit = function()
      local c = under_cursor()
      if c then require("jujutsu.buffers.commit_view").open(root, c.change_id) end
    end,
    OpenStat = function()
      local c = under_cursor()
      if c then require("jujutsu.buffers.stat_view").open(root, c.change_id) end
    end,
    Edit = function()
      local c = under_cursor()
      if c then run(cli.edit.args(c.change_id)) end
    end,
    Split = function()
      local c = under_cursor()
      require("jujutsu.popups.split").create({
        root = root,
        commit = c and c.change_id or nil,
        change = c,
      })
    end,
    NewOn = function()
      local c = under_cursor()
      if c then run(cli.new.args(c.change_id)) end
    end,
    Describe = function()
      local c = under_cursor()
      if c then
        require("jujutsu.buffers.editor").open({
          root = root,
          revision = c.change_id,
          on_submit = function()
            refresh()
            require("jujutsu").refresh()
          end,
        })
      end
    end,
    Abandon = function()
      local c = under_cursor()
      if c then
        async.void(function()
          if finder.confirm("Abandon " .. c.change_id .. "?") then run(cli.abandon.args(c.change_id)) end
        end)
      end
    end,
    SetBookmark = function()
      local c = under_cursor()
      if not c then return end
      local name = require("jujutsu.finder").pick_bookmark({
        prompt = "Bookmark name",
        cwd = root,
        allow_free_text = true,
        local_only = true,
      })
      if name and name ~= "" then run(cli.bookmark_set.revision(c.change_id).args(name)) end
    end,
    IssuePanel = function() require("jujutsu.issue_panel").open({ root = root }) end,
  })

  refresh()
end

return M
