local cli = require("jujutsu.jj.cli")
local config = require("jujutsu.config")

local M = {}

---@class ForgeRemote
---@field provider "github"|"gitlab"|"bitbucket"|"forgejo"
---@field host string
---@field web_host string
---@field owner string
---@field repo string
---@field url string

---@param host string
---@return string|nil kind
local function host_kind(host)
  host = host:lower()
  local hosts = (config.values.forge and config.values.forge.hosts) or {}
  if hosts[host] then return hosts[host] end
  if host == "github.com" then return "github" end
  if host == "gitlab.com" or host:find("gitlab", 1, true) then return "gitlab" end
  if host == "ssh.bitbucket.org" or host == "bitbucket.org" then return "bitbucket" end
  if host == "codeberg.org" or host:match("%.forgejo%.org$") then return "forgejo" end
  return nil
end

---@param url string
---@return ForgeRemote|nil
function M.parse_url(url)
  if not url or url == "" then return nil end
  url = url:gsub("%.git$", "")

  local host, path, web_host
  if url:match("^git@") then
    host, path = url:match("^git@([^:]+):(.+)$")
  elseif url:match("^ssh://") then
    host, path = url:match("^ssh://[^@]*@?([^/]+)/(.+)$")
  elseif url:match("^https?://") then
    host, path = url:match("^https?://([^/]+)/(.+)$")
  end
  if not host or not path then return nil end

  -- strip port from host
  host = host:gsub(":%d+$", "")
  web_host = host
  local kind = host_kind(host)
  if not kind then return nil end

  path = path:gsub("^/+", ""):gsub("/+$", "")
  local owner, repo
  if kind == "gitlab" then
    -- support nested groups: group/sub/repo
    local parts = vim.split(path, "/", { plain = true })
    if #parts < 2 then return nil end
    repo = parts[#parts]
    owner = table.concat(vim.list_slice(parts, 1, #parts - 1), "/")
  else
    if kind == "bitbucket" then web_host = web_host:gsub("^ssh%.", "") end
    owner, repo = path:match("^([^/]+)/([^/]+)")
  end

  if not owner or not repo then return nil end

  return {
    provider = kind,
    host = host,
    web_host = web_host,
    owner = owner,
    repo = repo,
    url = url,
  }
end

---@param root string
---@return ForgeRemote|nil
function M.detect(root)
  local res = cli.git_remote_list.call({ cwd = root, hidden = true })
  local origin = nil
  local first = nil
  for _, line in ipairs(res.stdout or {}) do
    local name, url = line:match("^(%S+)%s+(%S+)")
    if name and url then
      local parsed = M.parse_url(url)
      if parsed then
        if name == "origin" then
          origin = parsed
          break
        end
        if not first then first = parsed end
      end
    end
  end
  return origin or first
end

---@param remote ForgeRemote
---@param commit string
---@return string
function M.commit_url(remote, commit)
  if remote.provider == "github" then
    return string.format("https://%s/%s/%s/commit/%s", remote.web_host, remote.owner, remote.repo, commit)
  elseif remote.provider == "gitlab" then
    return string.format("https://%s/%s/%s/-/commit/%s", remote.web_host, remote.owner, remote.repo, commit)
  elseif remote.provider == "bitbucket" then
    return string.format("https://%s/%s/%s/commits/%s", remote.web_host, remote.owner, remote.repo, commit)
  else
    return string.format("https://%s/%s/%s/commit/%s", remote.web_host, remote.owner, remote.repo, commit)
  end
end

---@param remote ForgeRemote
---@return string
function M.repo_url(remote) return string.format("https://%s/%s/%s", remote.web_host, remote.owner, remote.repo) end

---@param remote ForgeRemote
---@param number integer|string
---@param kind? "issue"|"pr"
---@return string
function M.topic_url(remote, number, kind)
  kind = kind or "pr"
  local n = tostring(number)
  if remote.provider == "github" then
    local seg = kind == "issue" and "issues" or "pull"
    return string.format("https://%s/%s/%s/%s/%s", remote.web_host, remote.owner, remote.repo, seg, n)
  elseif remote.provider == "gitlab" then
    local seg = kind == "issue" and "issues" or "merge_requests"
    return string.format("https://%s/%s/%s/-/%s/%s", remote.web_host, remote.owner, remote.repo, seg, n)
  elseif remote.provider == "bitbucket" then
    if kind == "issue" then
      return string.format("https://%s/%s/%s/issues/%s", remote.web_host, remote.owner, remote.repo, n)
    end
    return string.format("https://%s/%s/%s/pull-requests/%s", remote.web_host, remote.owner, remote.repo, n)
  else
    -- forgejo / gitea
    local seg = kind == "issue" and "issues" or "pulls"
    return string.format("https://%s/%s/%s/%s/%s", remote.web_host, remote.owner, remote.repo, seg, n)
  end
end

---@param path string
---@return string
local function encode_path(path)
  path = path:gsub("^/+", "")
  return (path:gsub("([^%w%-%._~/])", function(c) return string.format("%%%02X", string.byte(c)) end))
end

---@param s string
---@return string|nil
local function md5_hex(s)
  local obj = vim.system({ "openssl", "md5" }, { text = true, stdin = s }):wait()
  if obj.code ~= 0 then return nil end
  local out = obj.stdout or ""
  return out:match("([a-fA-F0-9][a-fA-F0-9]+)%s*$")
end

---File at a commit (optional line). Used from the DiffView file list / non-PR diffs.
---@param remote ForgeRemote
---@param commit string
---@param path string
---@param line? integer
---@return string
function M.file_url(remote, commit, path, line)
  path = path or ""
  local enc = encode_path(path)
  local url
  if remote.provider == "github" then
    url = string.format("https://%s/%s/%s/blob/%s/%s", remote.web_host, remote.owner, remote.repo, commit, enc)
  elseif remote.provider == "gitlab" then
    url = string.format("https://%s/%s/%s/-/blob/%s/%s", remote.web_host, remote.owner, remote.repo, commit, enc)
  elseif remote.provider == "bitbucket" then
    url = string.format("https://%s/%s/%s/src/%s/%s", remote.web_host, remote.owner, remote.repo, commit, enc)
  else
    url = string.format("https://%s/%s/%s/src/commit/%s/%s", remote.web_host, remote.owner, remote.repo, commit, enc)
  end
  if line and line > 0 then
    if remote.provider == "bitbucket" then
      url = url .. "#lines-" .. tostring(line)
    else
      url = url .. "#L" .. tostring(line)
    end
  end
  return url
end

---File within a PR/MR at an optional line (diff buffer). Falls back to file_url when needed.
---@param remote ForgeRemote
---@param number integer|string
---@param path string
---@param opts? { line?: integer, side?: "LEFT"|"RIGHT", commit?: string }
---@return string
function M.pr_file_url(remote, number, path, opts)
  opts = opts or {}
  local line = opts.line
  local side = opts.side or "RIGHT"
  local n = tostring(number)
  path = path or ""

  if remote.provider == "github" then
    local hash = md5_hex(path)
    if hash and line and line > 0 then
      local anchor_side = side == "LEFT" and "L" or "R"
      return string.format(
        "https://%s/%s/%s/pull/%s/files#diff-%s%s%d",
        remote.web_host,
        remote.owner,
        remote.repo,
        n,
        hash,
        anchor_side,
        line
      )
    end
    local base = string.format("https://%s/%s/%s/pull/%s/files", remote.web_host, remote.owner, remote.repo, n)
    if opts.commit and opts.commit ~= "" then return M.file_url(remote, opts.commit, path, line) end
    return base
  elseif remote.provider == "gitlab" then
    local url =
      string.format("https://%s/%s/%s/-/merge_requests/%s/diffs", remote.web_host, remote.owner, remote.repo, n)
    if line and line > 0 and path ~= "" then
      -- GitLab deep-links are uneven; blob at head is more reliable when we have a commit.
      if opts.commit and opts.commit ~= "" then return M.file_url(remote, opts.commit, path, line) end
      return url
    end
    return url
  elseif remote.provider == "bitbucket" then
    local url = string.format("https://%s/%s/%s/pull-requests/%s/diff", remote.web_host, remote.owner, remote.repo, n)
    if path ~= "" then
      url = url .. "#chg-" .. path:gsub(" ", "%20")
      if line and line > 0 then url = url .. "T" .. tostring(line) end
    end
    return url
  else
    -- forgejo
    if opts.commit and opts.commit ~= "" then return M.file_url(remote, opts.commit, path, line) end
    return string.format("https://%s/%s/%s/pulls/%s/files", remote.web_host, remote.owner, remote.repo, n)
  end
end

---@param url string|nil
---@return boolean
function M.open_url(url)
  if not url or url == "" then
    require("jujutsu.notify").warn("No URL to open")
    return false
  end
  vim.ui.open(url)
  return true
end

return M
