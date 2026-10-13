local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local spinner = require("jujutsu.spinner")
local util = require("jujutsu.util")

---@class ProcessResult
---@field stdout string[]
---@field stderr string[]
---@field code integer
---@field time number
---@field cmd string

---@class ProcessOpts
---@field cmd string[]
---@field cwd? string
---@field env? table<string, string>
---@field input? string
---@field suppress_console? boolean
---@field timeout? integer milliseconds; the process is killed on expiry
---@field on_error? fun(res: ProcessResult): boolean

local M = {}

---@param res ProcessResult
---@return boolean
local function has_output(res) return #util.trim_blank(res.stdout) > 0 or #util.trim_blank(res.stderr) > 0 end

---@param res ProcessResult
---@param ok boolean
---@param suppress_console boolean
---@param had_spinner boolean
---@return boolean
local function should_show_console(res, ok, suppress_console, had_spinner)
  if suppress_console or not config.values.auto_show_console then return false end
  local when = config.values.auto_show_console_on or "output"
  if when == "never" then return false end
  if when == "always" then return true end
  if when == "error" then return not ok end
  -- Successful spinner-backed commands should not pop a console split afterward.
  if had_spinner and ok then return false end
  return has_output(res)
end

---@param res ProcessResult
local function show_error(res)
  local err = table.concat(util.remove_ansi_lines(util.trim_blank(res.stderr)), "\n")
  if err == "" then err = table.concat(util.remove_ansi_lines(util.trim_blank(res.stdout)), "\n") end
  if err ~= "" then notify.error(err) end
end

---@param opts ProcessOpts
---@param cb? fun(res: ProcessResult)
---@return ProcessResult|nil
function M.run(opts, cb)
  local cmd = opts.cmd
  local suppress_console = opts.suppress_console == true
  local show_spinner = not suppress_console
  local had_spinner = false
  local start = vim.uv.now()
  local stdout, stderr = {}, {}
  local stdout_buf, stderr_buf = "", ""

  local function append(acc, buf, data)
    if not data or data == "" then return buf end
    if type(data) ~= "string" then data = tostring(data) end
    buf = buf .. data
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      table.insert(acc, (buf:sub(1, nl - 1):gsub("\r$", "")))
      buf = buf:sub(nl + 1)
    end
    return buf
  end

  local env = nil
  if opts.env and next(opts.env) then
    env = vim.tbl_extend("force", vim.fn.environ(), opts.env)
    env.TERM = env.TERM or "xterm-256color"
  end

  local sync_done, sync_result = false, nil
  local finished = false

  local function deliver(res)
    if cb then
      cb(res)
    else
      sync_result = res
      sync_done = true
    end
  end

  local function finish(code)
    if finished then return end
    finished = true
    if stdout_buf ~= "" then table.insert(stdout, stdout_buf) end
    if stderr_buf ~= "" then table.insert(stderr, stderr_buf) end
    ---@type ProcessResult
    local res = {
      stdout = stdout,
      stderr = stderr,
      code = code or -1,
      time = (vim.uv.now() - start) / 1000,
      cmd = table.concat(cmd, " "),
    }

    local ok = code == 0
    local function after_spinner()
      if not suppress_console then
        if should_show_console(res, ok, suppress_console, had_spinner) then
          require("jujutsu.buffers.process").show_result(res)
        elseif not ok then
          local show = true
          if opts.on_error then show = opts.on_error(res) end
          if show then show_error(res) end
        end
      end

      pcall(function() require("jujutsu.history").push(res) end)
      deliver(res)
    end

    if had_spinner then
      spinner.stop(after_spinner)
    else
      after_spinner()
    end
  end

  local sys_opts = {
    cwd = opts.cwd,
    stdin = opts.input,
    text = true,
    stdout = function(_, data) stdout_buf = append(stdout, stdout_buf, data) end,
    stderr = function(_, data) stderr_buf = append(stderr, stderr_buf, data) end,
  }
  if env then sys_opts.env = env end
  -- Default covers user-facing commands. Background callers pass a shorter timeout
  -- so a stuck `jj` (snapshot, gpg, lock) cannot pin a refresh forever.
  local timeout_ms = opts.timeout or (1000 * 60 * 10)
  if opts.timeout then sys_opts.timeout = opts.timeout end

  local function launch()
    vim.system(cmd, sys_opts, function(obj)
      vim.schedule(function() finish(obj.code) end)
    end)
  end

  -- Hidden sync calls must not pump autocmds, timers, or the statusline. Those
  -- callbacks start more `jj` jobs; nested `vim.wait` then freezes the UI while
  -- the processes pile up. `SystemObj:wait` only runs fast events.
  if not show_spinner and not cb then
    local completed = vim.system(cmd, sys_opts):wait(timeout_ms)
    finish(completed and completed.code or -1)
    return sync_result
  end

  if show_spinner then
    had_spinner = true
    spinner.start(util.command_label(cmd), launch)
  else
    launch()
  end

  if cb then return nil end

  vim.wait(timeout_ms, function() return sync_done end, 20)
  return sync_result
end

---Run and await inside async coroutine.
---@param opts ProcessOpts
---@return ProcessResult
function M.await(opts)
  local async = require("jujutsu.async")
  return async.await(function(cb) M.run(opts, cb) end)
end

return M
