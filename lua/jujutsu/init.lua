local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")
local notify = require("jujutsu.notify")
local repository = require("jujutsu.jj.repository")

local M = {}
local did_setup = false

---@param opts? table
function M.setup(opts)
  if vim.fn.has("nvim-0.10") ~= 1 then
    notify.error("jujutsu.nvim requires Neovim 0.10+")
    return
  end
  if did_setup then
    config.setup(opts)
    require("jujutsu.signs").setup()
    return
  end
  did_setup = true
  config.setup(opts)
  require("jujutsu.hl").setup()
  require("jujutsu.hl").attach_autocmd()
  require("jujutsu.signs").setup()
  M.autocmd_group = vim.api.nvim_create_augroup("Jujutsu", { clear = false })
end

local function ensure_setup()
  if not did_setup then M.setup({}) end
end

local function construct_opts(opts)
  opts = opts or {}
  if opts.cwd and not opts.no_expand then opts.cwd = vim.fn.expand(opts.cwd) end
  opts.cwd = opts.cwd or vim.fn.getcwd()
  opts._workspace_root = cli.find_workspace_root(opts.cwd)
  return opts
end

local popup_names = {
  bookmark = true,
  change = true,
  commit = true, -- alias for change
  diff = true,
  fetch = true,
  help = true,
  log = true,
  push = true,
  rebase = true,
  remote = true,
  squash = true,
  split = true,
  undo = true,
  workspace = true,
}

---@class OpenOpts
---@field cwd? string
---@field kind? string
---@field [1]? string popup name

---@param opts? OpenOpts
function M.open(opts)
  ensure_setup()
  opts = construct_opts(opts)

  if not opts._workspace_root then
    notify.error(("`%s` is not a jj workspace"):format(opts.cwd))
    return
  end

  repository.instance(opts.cwd)

  if opts[1] ~= nil then
    local name = opts[1]
    if name == "commit" then name = "change" end
    if not popup_names[name] then
      notify.error("Invalid popup: " .. tostring(opts[1]))
      return
    end
    -- Open status first if needed, then popup
    local status = require("jujutsu.buffers.status")
    if not status.instance() then status.open(opts._workspace_root, opts.cwd, opts) end
    require("jujutsu.popups." .. name).create({
      root = opts._workspace_root,
    })
    return
  end

  require("jujutsu.buffers.status").open(opts._workspace_root, opts.cwd, opts)
end

function M.close()
  local status = require("jujutsu.buffers.status")
  status.close()
end

function M.refresh()
  local status = require("jujutsu.buffers.status")
  if status.instance() then status.refresh() end
  pcall(function() require("jujutsu.lualine").refresh() end)
  pcall(function() require("jujutsu.signs").refresh_all() end)
end

function M.focus()
  local status = require("jujutsu.buffers.status")
  status.focus()
end

---Create a bindable action for custom user keymaps.
---@param popup string
---@param action string
---@param args? string[]
---@return function
function M.action(popup, action, args)
  args = args or {}
  return function()
    ensure_setup()
    local ok, actions = pcall(require, "jujutsu.popups." .. popup .. ".actions")
    if not ok then
      notify.error("Invalid popup: " .. popup)
      return
    end
    local fn = actions[action]
    if not fn then
      notify.error(("Invalid action %s for %s"):format(action, popup))
      return
    end
    local async = require("jujutsu.async")
    async.void(function()
      fn({
        close = function() end,
        state = { env = {} },
        get_arguments = function() return args end,
        get_internal_arguments = function() return {} end,
      })
      vim.schedule(function() M.refresh() end)
    end)
  end
end

---Annotate the current buffer (or opts.path) with jj file annotate.
---@class AnnotateOpts
---@field bufnr? integer
---@field line? integer
---@field path? string absolute or repo-relative path
---@field revision? string
---@field cwd? string

---@param opts? AnnotateOpts
function M.annotate(opts)
  ensure_setup()
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.api.nvim_win_get_cursor(0)[1]

  local root ---@type string|nil
  local path ---@type string|nil

  if opts.path and opts.path ~= "" then
    local given = opts.path
    local as_abs = vim.fn.fnamemodify(given, ":p")
    if given:sub(1, 1) == "/" or (vim.uv.fs_stat(as_abs) and given:find("/", 1, true)) then
      root = cli.find_workspace_root(opts.cwd or vim.fn.fnamemodify(as_abs, ":h"))
      if not root then
        notify.error("not a jj workspace")
        return
      end
      local root_slash = root:sub(-1) == "/" and root or (root .. "/")
      if as_abs:sub(1, #root_slash) ~= root_slash then
        notify.warn("file is outside the jj workspace")
        return
      end
      path = as_abs:sub(#root_slash + 1)
    else
      root = cli.find_workspace_root(opts.cwd or vim.fn.getcwd())
      if not root then
        notify.error("not a jj workspace")
        return
      end
      path = given
    end
  else
    local name = vim.api.nvim_buf_get_name(bufnr)
    if not name or name == "" then
      notify.warn("annotate requires a file")
      return
    end
    local abs = vim.fn.fnamemodify(name, ":p")
    root = cli.find_workspace_root(opts.cwd or vim.fn.fnamemodify(abs, ":h"))
    if not root then
      notify.error("not a jj workspace")
      return
    end
    local root_slash = root:sub(-1) == "/" and root or (root .. "/")
    if abs:sub(1, #root_slash) ~= root_slash then
      notify.warn("file is outside the jj workspace")
      return
    end
    path = abs:sub(#root_slash + 1)
  end

  require("jujutsu.buffers.annotate").open(root, {
    path = path,
    line = line,
    revision = opts.revision,
  })
end

---Open the three-pane merge editor for a working-copy conflict.
---@class ResolveOpts
---@field cwd? string
---@field root? string
---@field path? string repo-relative or absolute path

---@param opts? ResolveOpts
function M.resolve(opts)
  ensure_setup()
  opts = opts or {}
  if opts.cwd and not opts.root then opts.root = cli.find_workspace_root(opts.cwd) end
  require("jujutsu.buffers.merge").open(opts)
end

---Open a forge PR/MR review (DiffView + local comments + submit via gh/glab/REST).
---@class ReviewOpts
---@field cwd? string
---@field root? string
---@field number? integer|string

---@param opts? ReviewOpts
function M.review(opts)
  ensure_setup()
  opts = opts or {}
  if opts.cwd and not opts.root then opts.root = cli.find_workspace_root(opts.cwd) or opts.cwd end
  require("jujutsu.review").open(opts)
end

---@class IssuePanelOpts
---@field cwd? string
---@field root? string
---@field number? integer|string
---@field kind? "issue"|"pr"

---Open the Issue/PR conversation side panel.
---@param opts? IssuePanelOpts
function M.issue_panel(opts)
  ensure_setup()
  opts = opts or {}
  if opts.cwd and not opts.root then opts.root = cli.find_workspace_root(opts.cwd) or opts.cwd end
  require("jujutsu.issue_panel").open(opts)
end

---Open the Magit-style Forge popup (PRs, issues, CI, review).
---@param opts? { cwd?: string, root?: string }
function M.forge_popup(opts)
  ensure_setup()
  opts = opts or {}
  local root = opts.root or opts.cwd
  if opts.cwd and not opts.root then root = cli.find_workspace_root(opts.cwd) or opts.cwd end
  root = root or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  require("jujutsu.popups.forge").create({ root = root })
end

---Describe what the user is currently looking at in the jujutsu UI.
---@param bufnr? integer
---@return JujutsuPresence|nil
function M.get_presence(bufnr) return require("jujutsu.presence").get_presence(bufnr) end

function M.get_config() return config.values end

M.config = config
M.cli = cli

return M
