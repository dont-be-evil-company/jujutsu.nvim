local Process = require("jujutsu.process")
local util = require("jujutsu.util")

local M = {}

local k_state = {}
local k_config = {}
local k_command = {}

local commands = {}

local function define_command(name, cfg) commands[name] = cfg or {} end

define_command("status", {})
define_command("log", {
  flags = { no_graph = "--no-graph", patch = "-p", summary = "-s", stat = "--stat", reversed = "--reversed" },
  options = { template = "-T", revisions = "-r", limit = "-n" },
})
define_command("diff", {
  flags = {
    summary = "-s",
    stat = "--stat",
    git = "--git",
    color_words = "--color-words",
    types = "--types",
    name_only = "--name-only",
  },
  options = { revision = "-r", from = "--from", to = "--to", context = "--context", tool = "--tool" },
})
define_command("show", {
  flags = { summary = "-s", stat = "--stat", git = "--git", color_words = "--color-words" },
  options = { template = "-T", tool = "--tool" },
})
define_command("describe", {
  flags = { no_edit = "--no-edit", reset_author = "--reset-author", stdin = "--stdin" },
  options = { message = "-m", revision = "-r" },
})
define_command("new", {
  flags = { no_edit = "--no-edit", insert_before = "--insert-before", insert_after = "--insert-after" },
  options = { message = "-m" },
  aliases = {
    revisions = function(tbl, state)
      return function(...)
        for _, v in ipairs({ ... }) do
          table.insert(state.arguments, v)
        end
        return tbl
      end
    end,
  },
})
define_command("commit", {
  flags = { reset_author = "--reset-author" },
  options = { message = "-m" },
})
define_command("squash", {
  flags = {
    interactive = "-i",
    keep_emptied = "--keep-emptied",
    use_destination_message = "--use-destination-message",
  },
  options = { revision = "-r", from = "--from", into = "--into", message = "-m" },
})
define_command("split", {
  flags = {
    interactive = "-i",
    parallel = "--parallel",
    editor = "--editor",
  },
  options = {
    revision = "-r",
    message = "-m",
    tool = "--tool",
    onto = "--onto",
    insert_after = "--insert-after",
    insert_before = "--insert-before",
  },
})
define_command("edit", {})
define_command("abandon", {})
define_command("restore", {
  options = { from = "--from", to = "--to", revision = "-r" },
})
define_command("rebase", {
  flags = {
    skip_emptied = "--skip-emptied",
    keep_divergent = "--keep-divergent",
    simplify_parents = "--simplify-parents",
  },
  options = {
    source = "-s",
    branch = "-b",
    revision = "-r",
    destination = "-d",
    before = "--before",
    after = "--after",
  },
})
define_command("duplicate", {
  options = { revision = "-r", destination = "-d" },
})
define_command("resolve", {
  flags = { list = "--list" },
  options = { revision = "-r", tool = "--tool" },
})
define_command("bookmark list", {
  flags = { all = "--all", all_remotes = "--all-remotes" },
  options = { template = "-T", revisions = "-r" },
})
define_command("bookmark create", { options = { revision = "-r" } })
define_command("bookmark move", {
  flags = { allow_backwards = "--allow-backwards" },
  options = { to = "--to", from = "--from" },
})
define_command("bookmark delete", {})
define_command("bookmark forget", {})
define_command("bookmark track", { options = { remote = "--remote" } })
define_command("bookmark untrack", { options = { remote = "--remote" } })
define_command("bookmark rename", { flags = { overwrite_existing = "--overwrite-existing" } })
define_command("bookmark set", {
  flags = { allow_backwards = "--allow-backwards" },
  options = { revision = "-r" },
})
define_command("git push", {
  flags = { all = "--all", dry_run = "--dry-run", deleted = "--deleted" },
  options = { bookmark = "--bookmark", change = "--change", remote = "--remote", revisions = "--revisions" },
})
define_command("git fetch", {
  flags = { all_remotes = "--all-remotes" },
  options = { remote = "--remote", bookmark = "--bookmark" },
})
define_command("git remote add", {})
define_command("git remote remove", {})
define_command("git remote rename", {})
define_command("git remote list", {})
define_command("undo", {})
define_command("redo", {})
define_command("op restore", { options = { what = "--what" } })
define_command("op log", {
  flags = { no_graph = "--no-graph" },
  options = { template = "-T", limit = "-n" },
})
define_command("revert", {
  options = { revision = "-r", destination = "-d" },
})
define_command("diffedit", {
  options = { revision = "-r", from = "--from", to = "--to" },
})
define_command("file list", { options = { revision = "-r" } })
define_command("file untrack", {})
define_command("file annotate", {
  options = { template = "-T", revision = "-r" },
  -- `jj file annotate` takes a single file path (`parse_file_path`), not a fileset.
  fileset_paths = false,
})
define_command("file show", { options = { revision = "-r" } })
define_command("workspace add", {
  options = { name = "--name", revision = "-r", message = "-m", sparse_patterns = "--sparse-patterns" },
})
define_command("workspace forget", {})
define_command("workspace list", { options = { template = "-T" } })
define_command("workspace rename", {})
define_command("workspace root", { options = { name = "--name" } })
define_command("workspace update-stale", {})

local readonly_commands = {
  ["log"] = true,
  ["show"] = true,
  ["bookmark list"] = true,
  ["op log"] = true,
  ["file list"] = true,
  ["file annotate"] = true,
  ["file show"] = true,
  ["git remote list"] = true,
  ["workspace list"] = true,
  ["workspace root"] = true,
}

---@param command string
---@param arg string
---@return string
local function literal_bookmark_arg(command, arg)
  if command == "bookmark list" then return arg end
  if command:match("^bookmark") then return util.bookmark_literal(arg) end
  return arg
end

local mt_builder = {}

mt_builder.__index = function(tbl, action)
  local state = rawget(tbl, k_state)
  local config = rawget(tbl, k_config)

  if action == "args" or action == "arguments" then
    return function(...)
      local command = rawget(tbl, k_command)
      for _, v in ipairs({ ... }) do
        table.insert(state.arguments, literal_bookmark_arg(command, tostring(v)))
      end
      return tbl
    end
  elseif action == "files" or action == "paths" then
    return function(...)
      for _, v in ipairs({ ... }) do
        local path = tostring(v)
        -- Wrap concrete paths as root-file:"…" so ()[]*? stay literal for fileset
        -- args. Commands that take a plain path (e.g. `file annotate`) opt out.
        if config.fileset_paths ~= false then path = util.fileset_literal(path) end
        table.insert(state.files, path)
      end
      return tbl
    end
  elseif action == "input" or action == "stdin" then
    return function(value)
      state.input = value
      return tbl
    end
  elseif action == "env" then
    return function(cfg)
      state.env = vim.tbl_extend("force", state.env, cfg)
      return tbl
    end
  elseif action == "config" then
    ---Pass a global `jj --config NAME=VALUE` (before the subcommand).
    ---@param name string
    ---@param value string TOML-encoded value, e.g. `"curved"` or `true`
    return function(name, value)
      table.insert(state.configs, { name = name, value = value })
      return tbl
    end
  elseif action == "call" then
    return function(opts) return M._call(tbl, opts) end
  elseif action == "call_async" then
    return function(opts) return M._call_async(tbl, opts) end
  elseif action == "ignore_working_copy" then
    ---Skip the working-copy snapshot. Use this for refreshes triggered by `.jj`
    ---itself so a snapshot write cannot schedule another snapshot.
    return function()
      state.ignore_working_copy = true
      return tbl
    end
  end

  if config.flags and config.flags[action] then
    table.insert(state.options, config.flags[action])
    return tbl
  end

  if config.options and config.options[action] then
    return function(value)
      table.insert(state.options, config.options[action])
      if value ~= nil then
        local v = tostring(value)
        local command = rawget(tbl, k_command)
        if action == "bookmark" or (action == "branch" and command == "rebase") then v = util.bookmark_literal(v) end
        table.insert(state.options, v)
      end
      return tbl
    end
  end

  if config.aliases and config.aliases[action] then return config.aliases[action](tbl, state) end

  error("Unknown flag/option for jj " .. rawget(tbl, k_command) .. ": " .. action)
end

mt_builder.__tostring = function(tbl) return table.concat(M._build_cmd(tbl), " ") end

local function new_builder(command, config)
  return setmetatable({
    [k_state] = {
      options = {},
      arguments = {},
      files = {},
      configs = {},
      input = nil,
      env = {},
    },
    [k_config] = config or {},
    [k_command] = command,
  }, mt_builder)
end

function M._build_cmd(tbl, opts)
  opts = opts or {}
  local state = rawget(tbl, k_state)
  local command = rawget(tbl, k_command)
  local jj_bin = require("jujutsu.jj.shell").resolve_jj()
  local color = opts.color or "never"
  local cmd = { jj_bin, "--no-pager", "--color=" .. color }

  for _, c in ipairs(state.configs or {}) do
    table.insert(cmd, "--config")
    table.insert(cmd, c.name .. "=" .. c.value)
  end

  if state.ignore_working_copy or readonly_commands[command] then table.insert(cmd, "--ignore-working-copy") end

  for word in command:gmatch("%S+") do
    table.insert(cmd, word)
  end

  vim.list_extend(cmd, state.options)
  vim.list_extend(cmd, state.arguments)
  if #state.files > 0 then
    table.insert(cmd, "--")
    vim.list_extend(cmd, state.files)
  end

  return cmd
end

---@param opts? table
---@return string|nil
local function resolve_cwd(opts)
  if opts and opts.cwd then return opts.cwd end
  local ok, repo = pcall(require, "jujutsu.jj.repository")
  if ok and repo.current and repo.current.root then return repo.current.root end
  return vim.fn.getcwd()
end

function M._call(tbl, opts)
  opts = opts or {}
  local state = rawget(tbl, k_state)
  local cmd = M._build_cmd(tbl)
  local res = Process.run({
    cmd = cmd,
    cwd = resolve_cwd(opts),
    env = state.env,
    input = state.input,
    timeout = opts.timeout,
    suppress_console = opts.hidden ~= false and (opts.suppress_console ~= false),
    on_error = opts.on_error,
  })
  assert(res)
  if opts.trim then
    res.stdout = util.trim_blank(res.stdout)
    res.stderr = util.trim_blank(res.stderr)
  end
  if opts.remove_ansi ~= false then
    res.stdout = util.remove_ansi_lines(res.stdout)
    res.stderr = util.remove_ansi_lines(res.stderr)
  end
  return res
end

function M._call_async(tbl, opts)
  opts = opts or {}
  local state = rawget(tbl, k_state)
  local cmd = M._build_cmd(tbl)
  local res = Process.await({
    cmd = cmd,
    cwd = resolve_cwd(opts),
    env = state.env,
    input = state.input,
    timeout = opts.timeout,
    suppress_console = opts.hidden ~= false and (opts.suppress_console ~= false),
    on_error = opts.on_error,
  })
  if opts.trim then
    res.stdout = util.trim_blank(res.stdout)
    res.stderr = util.trim_blank(res.stderr)
  end
  if opts.remove_ansi ~= false then
    res.stdout = util.remove_ansi_lines(res.stdout)
    res.stderr = util.remove_ansi_lines(res.stderr)
  end
  return res
end

setmetatable(M, {
  __index = function(_, k)
    local command_name = k:gsub("_", " ")
    local cfg = commands[command_name]
    if cfg then return new_builder(command_name, cfg) end
    local hyphenated = command_name:gsub("(%S+) (%S+)$", "%1-%2")
    if hyphenated ~= command_name then
      cfg = commands[hyphenated]
      if cfg then return new_builder(hyphenated, cfg) end
    end
    cfg = commands[k]
    if cfg then return new_builder(k, cfg) end
    error("Unknown jj command: " .. k)
  end,
})

---@type table<string, string|false>
local workspace_root_cache = {}

local function find_jj_root(dir)
  local path = util.normalize_path(dir)
  while path and path ~= "" do
    if vim.uv.fs_stat(path .. "/.jj") then return path end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end
  return nil
end

---@param dir? string
---@return string|nil
function M.find_workspace_root(dir)
  dir = dir or vim.fn.getcwd()
  local key = vim.fn.fnamemodify(dir, ":p")
  if workspace_root_cache[key] ~= nil then
    local cached = workspace_root_cache[key]
    return cached ~= false and cached or nil
  end
  local root = find_jj_root(dir)
  if root then
    workspace_root_cache[key] = root
    return root
  end
  workspace_root_cache[key] = false
  return nil
end

function M.is_inside_workspace(dir) return M.find_workspace_root(dir) ~= nil end

function M.clear_cache() workspace_root_cache = {} end

return M
