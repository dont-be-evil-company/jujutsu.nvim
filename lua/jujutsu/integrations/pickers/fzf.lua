local M = {}

local PICKER_Z = 250

local function finish_once(cb)
  local delivered = false
  return function(value)
    if delivered then return end
    delivered = true
    cb(value)
  end
end

---@param selected string[]|nil
---@param fzf_opts table|nil
---@param entries string[]
---@param allow_free_text boolean|nil
---@return string|string[]|nil
local function selection_value(selected, fzf_opts, entries, allow_free_text, allow_multi)
  selected = selected or {}
  local known = {}
  for _, text in ipairs(entries or {}) do
    known[text] = true
  end
  local hits = {}
  for _, text in ipairs(selected) do
    if known[text] then hits[#hits + 1] = text end
  end
  if allow_multi and #hits > 0 then return hits end
  if not allow_multi and hits[1] then return hits[1] end
  if allow_free_text then
    local query = fzf_opts and fzf_opts.last_query or nil
    if (not query or query == "") and selected[1] and not known[selected[1]] then query = selected[1] end
    if type(query) == "string" then
      query = vim.trim(query)
      if query ~= "" then return query end
    end
  end
  if allow_multi then return #hits > 0 and hits or nil end
  return hits[1]
end

---Selection lists are not file pickers. A preview window also steals the prompt.
---@param on_close fun()
---@return table
local function winopts(on_close)
  local prev_on_create
  pcall(function() prev_on_create = require("fzf-lua.config").globals.winopts.on_create end)
  return {
    -- Force a float. A user split is hidden behind the floating host and never receives keys.
    split = false,
    zindex = PICKER_Z,
    preview = { hidden = true },
    on_create = function(e)
      if type(prev_on_create) == "function" then pcall(prev_on_create, e) end
      if e and e.winid then require("jujutsu.integrations.pickers").claim(e.winid, "terminal") end
    end,
    on_close = on_close,
  }
end

---@param opts { prompt?: string, entries: string[], allow_multi?: boolean, allow_free_text?: boolean }
---@param cb fun(item: string|string[]|nil)
function M.pick(opts, cb)
  local fzf = require("fzf-lua")
  local finish = finish_once(cb)
  local choosing = false
  local fzf_opts = {}
  if opts.allow_multi then fzf_opts["--multi"] = true end
  if opts.allow_free_text then fzf_opts["--print-query"] = true end

  fzf.fzf_exec(opts.entries or {}, {
    prompt = (opts.prompt or "select") .. "> ",
    previewer = false,
    fzf_opts = fzf_opts,
    winopts = winopts(function()
      vim.schedule(function()
        if not choosing then finish(nil) end
      end)
    end),
    actions = {
      ["default"] = function(selected, o)
        choosing = true
        finish(selection_value(selected, o, opts.entries or {}, opts.allow_free_text, opts.allow_multi))
      end,
    },
  })
end

---@param opts { prompt?: string, default?: string, allow_empty?: boolean }
---@param cb fun(value: string|nil)
function M.input(opts, cb)
  local fzf = require("fzf-lua")
  local finish = finish_once(cb)
  local choosing = false
  local entries = {}
  if opts.default and opts.default ~= "" then entries[1] = opts.default end
  local fzf_opts = { ["--print-query"] = true }
  if opts.default and opts.default ~= "" then fzf_opts["--query"] = opts.default end

  fzf.fzf_exec(entries, {
    prompt = (opts.prompt or "input") .. "> ",
    previewer = false,
    fzf_opts = fzf_opts,
    winopts = winopts(function()
      vim.schedule(function()
        if not choosing then finish(nil) end
      end)
    end),
    actions = {
      ["default"] = function(selected, o)
        choosing = true
        local query = o and o.last_query or nil
        if (not query or query == "") and selected and selected[1] then query = selected[1] end
        query = type(query) == "string" and query or ""
        if query == "" and not opts.allow_empty then
          finish(nil)
        else
          finish(query)
        end
      end,
    },
  })
end

return M
