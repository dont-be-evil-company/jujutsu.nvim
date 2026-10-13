local Buffer = require("jujutsu.ui.buffer")
local async = require("jujutsu.async")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")
local model = require("jujutsu.issue_panel.model")
local notify = require("jujutsu.notify")
local provider = require("jujutsu.forge.provider")
local remote_mod = require("jujutsu.forge.remote")
local render = require("jujutsu.issue_panel.render")

local M = {}

---@class IssuePanelState
---@field buf Buffer
---@field win integer
---@field root string
---@field remote ForgeRemote
---@field number integer|string
---@field kind "issue"|"pr"
---@field topic ForgeTopic|nil
---@field comments ForgeConversationComment[]
---@field comment_ranges { start_line: integer, end_line: integer, comment: ForgeConversationComment }[]
---@field closing boolean

---@type IssuePanelState|nil
local instance = nil
local last_width = nil

---@return table
local function cfg() return config.values.issue_panel or {} end

---@return integer
local function panel_width()
  local c = cfg()
  local cols = vim.o.columns
  local w = c.width or 0.38
  if w > 0 and w < 1 then w = math.floor(cols * w) end
  w = math.floor(w)
  local min_w = c.min_width or 48
  local max_w = c.max_width or 90
  if last_width then w = last_width end
  return math.max(min_w, math.min(max_w, w, cols - 20))
end

---@return boolean
local function render_markdown_enabled()
  local v = cfg().render_markdown
  if v == nil then return true end
  return v and true or false
end

local function paint(state, payload)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf.bufnr) then return end
  local markdown = render_markdown_enabled()
  local lines, highlights, meta = render.build(payload, { markdown = markdown })
  state.comment_ranges = (meta and meta.comment_ranges) or {}
  Buffer.render(state.buf, lines, highlights)
  if markdown then
    pcall(vim.treesitter.start, state.buf.bufnr, "markdown")
  else
    pcall(vim.treesitter.stop, state.buf.bufnr)
  end
end

local function close_panel()
  if not instance or instance.closing then return end
  local state = instance
  state.closing = true
  instance = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    last_width = vim.api.nvim_win_get_width(state.win)
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.buf.bufnr, { force = true })
  end
end

---@param state IssuePanelState
---@param opts? { refresh?: boolean }
local function fetch_and_render(state, opts)
  opts = opts or {}
  paint(state, { loading = true })
  async.void(function()
    local function load()
      local topic, terr = provider.get_topic(state.root, state.number, { kind = state.kind }, state.remote)
      if not topic then
        if
          provider.is_auth_error(terr) and (state.remote.provider == "bitbucket" or state.remote.provider == "forgejo")
        then
          provider.handle_auth_failure(state.remote, function(updated)
            if updated then vim.schedule(function() fetch_and_render(state) end) end
          end)
          return
        end
        if instance == state then paint(state, { error = terr or "Failed to load" }) end
        return
      end
      local comments, cerr = provider.list_comments(state.root, state.number, { kind = state.kind }, state.remote)
      if cerr and provider.is_auth_error(cerr) then
        provider.handle_auth_failure(state.remote, function(updated)
          if updated then vim.schedule(function() fetch_and_render(state) end) end
        end)
        return
      end
      if instance ~= state then return end
      local normalized = model.normalize(topic, comments or {})
      state.topic = normalized.topic
      state.comments = normalized.comments
      state.kind = normalized.topic.kind
      paint(state, { topic = state.topic, comments = state.comments, error = cerr })
    end
    if opts.refresh then
      require("jujutsu.forge.cache").with_refresh(load)
    else
      load()
    end
  end)
end

---@param state IssuePanelState
---@return ForgeConversationComment|nil
local function comment_under_cursor(state)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1 -- 0-based
  for _, range in ipairs(state.comment_ranges or {}) do
    if row >= range.start_line and row <= range.end_line then return range.comment end
  end
  return nil
end

---@param state IssuePanelState
local function compose_comment(state)
  require("jujutsu.review.ui").prompt_comment("Comment on #" .. tostring(state.number), {}, function(body)
    if not body or vim.trim(body) == "" then
      notify.warn("Empty comment not submitted")
      return
    end
    async.void(function()
      local ok, err = provider.post_comment(state.root, state.number, body, { kind = state.kind }, state.remote)
      if not ok then
        if provider.is_auth_error(err) then
          provider.handle_auth_failure(state.remote, function(updated)
            if updated then vim.schedule(function() compose_comment(state) end) end
          end)
          return
        end
        notify.error(err or "Failed to post comment")
        return
      end
      notify.info("Comment posted")
      fetch_and_render(state)
    end)
  end)
end

---@param state IssuePanelState
local function edit_comment(state)
  local caps = provider.capabilities(state.remote)
  if not caps.comments.update then
    notify.warn("Editing comments is not supported for " .. state.remote.provider)
    return
  end
  local comment = comment_under_cursor(state)
  if not comment then
    notify.warn("Place the cursor on a comment")
    return
  end
  if comment.kind == "review" then
    notify.warn("Review summary comments cannot be edited here")
    return
  end
  require("jujutsu.review.ui").prompt_comment("Edit comment", { initial = comment.body or "" }, function(body)
    if not body or vim.trim(body) == "" then
      notify.warn("Empty comment not saved")
      return
    end
    async.void(function()
      local ok, err =
        provider.update_comment(state.root, state.number, comment.id, body, { kind = state.kind }, state.remote)
      if not ok then
        notify.error(err or "Failed to update comment")
        return
      end
      notify.info("Comment updated")
      fetch_and_render(state)
    end)
  end)
end

---@param state IssuePanelState
local function delete_comment(state)
  local caps = provider.capabilities(state.remote)
  if not caps.comments.delete then
    notify.warn("Deleting comments is not supported for " .. state.remote.provider)
    return
  end
  local comment = comment_under_cursor(state)
  if not comment then
    notify.warn("Place the cursor on a comment")
    return
  end
  if comment.kind == "review" then
    notify.warn("Review summary comments cannot be deleted here")
    return
  end
  async.void(function()
    pcall(vim.cmd, "redraw!")
    async.sleep(30)
    local choice = finder.pick({
      prompt = "Delete this comment?",
      entries = { { text = "Delete" }, { text = "Cancel" } },
    })
    if choice ~= "Delete" then return end
    local ok, err = provider.delete_comment(state.root, state.number, comment.id, { kind = state.kind }, state.remote)
    if not ok then
      notify.error(err or "Failed to delete comment")
      return
    end
    notify.info("Comment deleted")
    fetch_and_render(state)
  end)
end

---@param state IssuePanelState
local function edit_topic(state)
  if not state.topic then return end
  local caps = provider.capabilities(state.remote)
  local can = (state.kind == "pr" and caps.prs.update) or (state.kind == "issue" and caps.issues.update)
  if not can then
    notify.warn("Updating is not supported for " .. state.remote.provider)
    return
  end
  async.void(function()
    pcall(vim.cmd, "redraw!")
    async.sleep(30)
    local what = finder.pick({
      prompt = "Edit",
      entries = {
        { text = "Title" },
        { text = "Body" },
        { text = "Title and body" },
      },
    })
    if not what then return end

    local opts = {}
    if what == "Title" or what == "Title and body" then
      local title = finder.input({
        prompt = "Title",
        default = state.topic.title or "",
      })
      if title == nil then return end
      opts.title = vim.trim(title)
      if opts.title == "" then
        notify.warn("Title cannot be empty")
        return
      end
    end

    local function apply_update()
      async.void(function()
        local ok, err
        if state.kind == "pr" then
          ok, err = provider.update_pr(state.root, state.number, opts, state.remote)
        else
          ok, err = provider.update_issue(state.root, state.number, opts, state.remote)
        end
        if not ok then
          notify.error(err or "Failed to update")
          return
        end
        notify.info("Updated")
        fetch_and_render(state)
      end)
    end

    if what == "Body" or what == "Title and body" then
      -- Defer past finder focus-reclaim so the compose float keeps focus.
      vim.defer_fn(function()
        require("jujutsu.review.ui").prompt_comment("Edit body", {
          initial = state.topic.body or "",
          allow_empty = true,
        }, function(body)
          -- nil = aborted; do not clear or patch
          if body == nil then return end
          opts.body = body
          apply_update()
        end)
      end, 60)
    else
      apply_update()
    end
  end)
end

---@param state IssuePanelState
local function edit_labels(state)
  local caps = provider.capabilities(state.remote)
  local can = (state.kind == "pr" and caps.prs.labels) or (state.kind == "issue" and caps.issues.labels)
  if not can then
    notify.warn("Labels are not supported for " .. state.remote.provider)
    return
  end
  async.void(function()
    local labels, err = provider.list_repo_labels(state.root, state.remote)
    if err then
      notify.error(err)
      return
    end
    if #labels == 0 then
      notify.warn("No repository labels found")
      return
    end
    local current = {}
    for _, l in ipairs(state.topic and state.topic.labels or {}) do
      current[l.name] = true
    end
    local entries = {}
    for _, lab in ipairs(labels) do
      local mark = current[lab.name] and "[x] " or "[ ] "
      table.insert(entries, { text = mark .. lab.name, label = lab })
    end
    pcall(vim.cmd, "redraw!")
    if coroutine.running() then async.sleep(50) end
    local selected = finder.pick({
      prompt = "Select labels (tab toggle, enter confirm)",
      entries = entries,
      allow_multi = true,
    })
    if not selected then return end
    local names = {}
    local list = type(selected) == "table" and selected or { selected }
    for _, s in ipairs(list) do
      local name = tostring(s):gsub("^%[[ x]%]%s*", "")
      if name ~= "" then table.insert(names, name) end
    end
    local ok, uerr
    if state.kind == "pr" then
      ok, uerr = provider.update_pr(state.root, state.number, { labels = names }, state.remote)
    else
      ok, uerr = provider.update_issue(state.root, state.number, { labels = names }, state.remote)
    end
    if not ok then
      notify.error(uerr or "Failed to update labels")
      return
    end
    notify.info("Labels updated")
    fetch_and_render(state)
  end)
end

---@param user ForgeUser
---@return string
local function assignee_display(user)
  if user.name and user.name ~= "" and user.name ~= user.login then return user.name .. " (@" .. user.login .. ")" end
  return user.login
end

---@param state IssuePanelState
local function edit_assignees(state)
  local caps = provider.capabilities(state.remote)
  local can = (state.kind == "pr" and caps.prs.assignees) or (state.kind == "issue" and caps.issues.assignees)
  if not can then
    notify.warn("Assignees are not supported for " .. state.remote.provider)
    return
  end
  local multi = (state.kind == "pr" and caps.prs.multi_assignees) or caps.issues.multi_assignees
  async.void(function()
    local users, err = provider.list_assignable_users(state.root, state.remote)
    if err then
      notify.error(err)
      return
    end
    if #users == 0 then
      notify.warn("No assignable users found")
      return
    end
    local current = {}
    for _, a in ipairs(state.topic and state.topic.assignees or {}) do
      current[a] = true
    end
    local text_to_login = {}
    local entries = {}
    local none_key = "__none__"
    if not multi then
      local has = next(current) ~= nil
      local none_text = has and "[ ] (none)" or "[x] (none)"
      text_to_login[none_text] = none_key
      table.insert(entries, { text = none_text })
    end
    for _, user in ipairs(users) do
      local mark = current[user.login] and "[x] " or "[ ] "
      local text = mark .. assignee_display(user)
      text_to_login[text] = user.login
      table.insert(entries, { text = text })
    end
    local prompt
    if state.remote.provider == "bitbucket" and state.kind == "pr" then
      prompt = multi and "Select reviewers (tab toggle, enter confirm)" or "Select reviewer"
    elseif multi then
      prompt = "Select assignees (tab toggle, enter confirm)"
    else
      prompt = "Select assignee"
    end
    pcall(vim.cmd, "redraw!")
    if coroutine.running() then async.sleep(50) end
    local selected = finder.pick({
      prompt = prompt,
      entries = entries,
      allow_multi = multi,
    })
    if not selected then return end
    local logins = {}
    local list = type(selected) == "table" and selected or { selected }
    for _, s in ipairs(list) do
      local login = text_to_login[tostring(s)]
      if login == none_key then
        logins = {}
        break
      elseif login and login ~= "" then
        table.insert(logins, login)
      end
    end
    if not multi and #logins > 1 then logins = { logins[1] } end
    local ok, uerr
    if state.kind == "pr" then
      ok, uerr = provider.update_pr(state.root, state.number, { assignees = logins }, state.remote)
    else
      ok, uerr = provider.update_issue(state.root, state.number, { assignees = logins }, state.remote)
    end
    if not ok then
      notify.error(uerr or "Failed to update assignees")
      return
    end
    if state.remote.provider == "bitbucket" and state.kind == "pr" then
      notify.info("Reviewers updated")
    else
      notify.info("Assignees updated")
    end
    fetch_and_render(state)
  end)
end

---@param state IssuePanelState
local function close_topic(state)
  local caps = provider.capabilities(state.remote)
  if state.kind == "pr" then
    local choices = {}
    if caps.prs.close then table.insert(choices, { text = "Close" }) end
    if caps.prs.merge then table.insert(choices, { text = "Merge" }) end
    table.insert(choices, { text = "Cancel" })
    async.void(function()
      pcall(vim.cmd, "redraw!")
      async.sleep(30)
      local choice = finder.pick({ prompt = "PR action", entries = choices })
      if not choice or choice == "Cancel" then return end
      if choice == "Close" then
        local ok, err = provider.close_pr(state.root, state.number, state.remote)
        if not ok then
          notify.error(err or "Failed")
          return
        end
        notify.info("Closed")
        fetch_and_render(state)
        return
      end
      if choice == "Merge" then
        local method = finder.pick({
          prompt = "Merge method",
          entries = { { text = "merge" }, { text = "squash" }, { text = "rebase" } },
        })
        if not method then return end
        local mok, merr = provider.merge_pr(state.root, state.number, { method = method }, state.remote)
        if not mok then
          notify.error(merr or "Failed to merge")
          return
        end
        notify.info("Merged")
        fetch_and_render(state)
      end
    end)
  else
    if not caps.issues.close then
      notify.warn("Closing issues is not supported for " .. state.remote.provider)
      return
    end
    async.void(function()
      pcall(vim.cmd, "redraw!")
      async.sleep(30)
      local choice = finder.pick({
        prompt = "Close this issue?",
        entries = { { text = "Close" }, { text = "Cancel" } },
      })
      if choice ~= "Close" then return end
      local ok, err = provider.close_issue(state.root, state.number, state.remote)
      if not ok then
        notify.error(err or "Failed to close")
        return
      end
      notify.info("Closed")
      fetch_and_render(state)
    end)
  end
end

---@param state IssuePanelState
local function bind_keymaps(state)
  local keys = cfg().keymaps or {}
  local map = function(lhs, rhs, desc)
    if not lhs or lhs == false then return end
    vim.keymap.set("n", lhs, rhs, {
      buffer = state.buf.bufnr,
      silent = true,
      noremap = true,
      desc = "jujutsu issue panel: " .. desc,
    })
  end
  map(keys.close or "q", close_panel, "Close")
  map(keys.refresh or "r", function() fetch_and_render(state, { refresh = true }) end, "Refresh")
  map(keys.comment or "c", function() compose_comment(state) end, "Comment")
  map(keys.edit_comment or "e", function() edit_comment(state) end, "EditComment")
  map(keys.delete_comment or "x", function() delete_comment(state) end, "DeleteComment")
  map(keys.edit_topic or "E", function() edit_topic(state) end, "EditTopic")
  map(keys.labels or "l", function() edit_labels(state) end, "Labels")
  map(keys.assignees or "a", function() edit_assignees(state) end, "Assignees")
  map(keys.close_topic or "C", function() close_topic(state) end, "CloseTopic")
  map(keys.browser or "o", function()
    local url = state.topic and state.topic.url
    if not url or url == "" then url = remote_mod.topic_url(state.remote, state.number, state.kind) end
    remote_mod.open_url(url)
  end, "OpenInBrowser")
end

---@param opts { root: string, remote: ForgeRemote, number: integer|string, kind?: "issue"|"pr" }
local function open_panel(opts)
  if cfg().enabled == false then
    notify.warn("Issue panel is disabled (issue_panel.enabled = false)")
    return
  end
  if instance then close_panel() end

  local buf = Buffer.create(
    string.format("jujutsu://issue/%s/%s", tostring(opts.kind or "pr"), tostring(opts.number)),
    "markdown"
  )
  vim.bo[buf.bufnr].modifiable = false

  local host = require("jujutsu.ui.host")
  local win
  if host.active() then
    local frac = cfg().width or 0.38
    if type(frac) ~= "number" or frac <= 0 or frac > 1 then frac = 0.38 end
    win = host.open_side(buf.bufnr, frac)
  else
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf.bufnr)
    vim.cmd("wincmd L")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(win, panel_width())
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  buf.winid = win

  instance = {
    buf = buf,
    win = win,
    root = opts.root,
    remote = opts.remote,
    number = opts.number,
    kind = opts.kind or "pr",
    comments = {},
    comment_ranges = {},
    closing = false,
  }
  bind_keymaps(instance)
  paint(instance, { loading = true })
  fetch_and_render(instance)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if instance and instance.win == win then instance = nil end
    end,
  })
end

---@param opts? { cwd?: string, root?: string, number?: integer|string, kind?: "issue"|"pr", remote?: ForgeRemote }
function M.open(opts)
  opts = opts or {}
  local root = opts.root or opts.cwd or require("jujutsu.jj.repository").root() or vim.fn.getcwd()
  local rem = opts.remote or remote_mod.detect(root)
  if not rem then
    notify.error("Could not detect forge remote")
    return
  end

  local function proceed(number, kind)
    local function go() open_panel({ root = root, remote = rem, number = number, kind = kind }) end
    if rem.provider == "bitbucket" or rem.provider == "forgejo" then
      provider.ensure_auth(rem, function(ok)
        if ok then vim.schedule(go) end
      end)
    else
      go()
    end
  end

  if opts.number then
    proceed(opts.number, opts.kind or "pr")
    return
  end

  async.void(function()
    pcall(vim.cmd, "redraw!")
    async.sleep(30)
    local kind = finder.pick({
      prompt = "Open conversation for",
      entries = {
        { text = "Pull request / MR" },
        { text = "Issue" },
      },
    })
    if not kind then return end
    local as_kind = kind:find("Issue", 1, true) and "issue" or "pr"
    local num = finder.input({
      prompt = (as_kind == "pr" and "PR/MR" or "Issue") .. " number",
    })
    if not num or vim.trim(num) == "" then return end
    proceed(vim.trim(num), as_kind)
  end)
end

function M.close() close_panel() end

function M.toggle(opts)
  if instance then
    close_panel()
    return
  end
  M.open(opts)
end

function M.refresh()
  if instance then fetch_and_render(instance, { refresh = true }) end
end

---@return boolean
function M.is_open() return instance ~= nil end

---@return IssuePanelState|nil
function M.instance() return instance end

return M
