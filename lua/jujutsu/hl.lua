local M = {}

---@param name string
---@return string|nil
local function get_fg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then return nil end
  if hl.link then return get_fg(hl.link) end
  if hl.reverse and hl.bg then return string.format("#%06x", hl.bg) end
  if hl.fg then return string.format("#%06x", hl.fg) end
  return nil
end

---@param name string
---@return string|nil
local function get_bg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then return nil end
  if hl.link then return get_bg(hl.link) end
  if hl.reverse and hl.fg then return string.format("#%06x", hl.fg) end
  if hl.bg then return string.format("#%06x", hl.bg) end
  return nil
end

---@param hex string
---@return integer, integer, integer
local function parse_hex(hex)
  hex = hex:gsub("#", "")
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

---Shade a hex color toward black (negative) or white (positive). factor in roughly -1..1
---@param hex string
---@param factor number
---@return string
local function shade(hex, factor)
  local r, g, b = parse_hex(hex)
  if factor > 0 then
    r = math.floor(r + (255 - r) * factor)
    g = math.floor(g + (255 - g) * factor)
    b = math.floor(b + (255 - b) * factor)
  else
    local f = 1 + factor
    r = math.floor(r * f)
    g = math.floor(g * f)
    b = math.floor(b * f)
  end
  return string.format("#%02x%02x%02x", r, g, b)
end

local function palette()
  local dark = vim.o.bg ~= "light"
  local bg_factor = dark and 1 or -1
  local bg = get_bg("Normal") or (dark and "#22252A" or "#eeeeee")
  local fg = get_fg("Normal") or (dark and "#fcfcfc" or "#22252A")
  local red = get_fg("DiffDelete") or get_fg("DiagnosticError") or "#E06C75"
  local orange = get_fg("SpecialChar") or get_fg("WarningMsg") or "#ffcb6b"
  local yellow = get_fg("DiffChange") or "#FFE082"
  local green = get_fg("DiffAdd") or get_fg("DiagnosticOk") or "#C3E88D"
  local cyan = get_fg("Operator") or get_fg("DiagnosticInfo") or "#89ddff"
  local blue = get_fg("Function") or get_fg("Macro") or "#82AAFF"
  local purple = get_fg("Statement") or get_fg("Include") or "#C792EA"
  local grey = get_fg("Comment") or (dark and "#7a7a7a" or "#8a8a8a")

  return {
    fg = fg,
    bg0 = bg,
    bg1 = shade(bg, bg_factor * 0.04),
    bg2 = shade(bg, bg_factor * 0.08),
    bg3 = shade(bg, bg_factor * 0.12),
    grey = grey,
    red = red,
    bg_red = shade(red, bg_factor * -0.18),
    line_red = get_bg("DiffDelete") or shade(red, bg_factor * -0.55),
    orange = orange,
    yellow = yellow,
    green = green,
    bg_green = shade(green, bg_factor * -0.18),
    line_green = get_bg("DiffAdd") or shade(green, bg_factor * -0.55),
    cyan = cyan,
    bg_cyan = shade(cyan, bg_factor * -0.18),
    blue = blue,
    purple = purple,
    bg_purple = shade(purple, bg_factor * -0.18),
    md_purple = shade(purple, 0.18),
    bold = true,
    italic = true,
  }
end

function M.setup()
  local p = palette()
  ---@type table<string, vim.api.keyset.highlight>
  local groups = {
    JujutsuNormal = { link = "Normal" },
    JujutsuSubtle = { fg = p.grey },
    JujutsuHint = { fg = p.grey },
    JujutsuSectionHeader = { fg = p.purple, bold = p.bold },
    JujutsuSectionCount = { fg = p.grey },
    JujutsuFold = { fg = p.grey, bold = p.bold },
    JujutsuBranch = { fg = p.blue, bold = p.bold },
    JujutsuRemoteBranch = { fg = p.green, bold = p.bold },
    JujutsuTag = { fg = p.orange, bold = p.bold },
    JujutsuChangeId = { fg = p.purple },
    JujutsuChangeIdPrefix = { fg = p.purple, bold = p.bold },
    JujutsuChangeIdRest = { fg = p.cyan },
    JujutsuCommitId = { fg = p.cyan },
    JujutsuDescription = { fg = p.green },
    JujutsuObjectId = { fg = p.cyan },
    JujutsuFilePath = { link = "Normal" },
    JujutsuFileMode = { fg = p.blue, bold = p.bold, italic = p.italic },
    JujutsuFileAdded = { fg = p.green, bold = p.bold, italic = p.italic },
    JujutsuFileModified = { fg = p.blue, bold = p.bold, italic = p.italic },
    JujutsuFileDeleted = { fg = p.red, bold = p.bold, italic = p.italic },
    JujutsuFileUntracked = { fg = p.grey, italic = p.italic },
    JujutsuFileRenamed = { fg = p.purple, bold = p.bold, italic = p.italic },
    JujutsuConflict = { fg = p.yellow, bold = p.bold },
    JujutsuDivergent = { fg = p.orange, bold = p.bold },
    JujutsuMergeAdd = { fg = p.bg_green, bg = p.line_green },
    JujutsuMergeDelete = { fg = p.bg_red, bg = p.line_red },
    JujutsuMergeCombined = { fg = p.yellow, bg = p.bg3 },
    JujutsuMergeConflict = { fg = p.yellow, bg = p.bg2 },
    JujutsuMergeFiller = { bg = p.bg1 },
    JujutsuMergeTake = { fg = p.bg_green, bold = p.bold },
    JujutsuMergeOpen = { fg = p.yellow, bold = p.bold },
    -- Full-line diff colors (neoJJ-style backgrounds)
    JujutsuHunkHeader = { fg = p.bg0, bg = p.md_purple, bold = p.bold },
    JujutsuDiffHeader = { fg = p.blue, bg = p.bg3, bold = p.bold },
    JujutsuDiffAdd = { fg = p.bg_green, bg = p.line_green },
    JujutsuDiffDelete = { fg = p.bg_red, bg = p.line_red },
    JujutsuDiffContext = { bg = p.bg1 },
    JujutsuCommitHeader = { fg = p.bg0, bg = p.bg_cyan, bold = p.bold },
    JujutsuCommitViewDescription = { fg = p.green },
    JujutsuWorkingCopy = { fg = p.green, bold = p.bold },
    JujutsuHeaderLabel = { fg = p.purple, bold = p.bold },
    JujutsuPopupHeading = { fg = p.blue, bold = p.bold },
    JujutsuPopupKey = { fg = p.purple, bold = p.bold },
    JujutsuPopupAction = { fg = p.fg },
    JujutsuPopupSwitchOn = { fg = p.orange },
    JujutsuPopupSwitchOff = { fg = p.grey },
    JujutsuCursorLine = { link = "CursorLine" },
    JujutsuObjectSelected = { link = "Visual" },
    JujutsuForgePR = { fg = p.purple, bold = p.bold },
    JujutsuReviewHeaderSplitter = { fg = p.grey, bg = p.bg1 },
    JujutsuReviewComment = { fg = p.white, bg = p.bg1 },
    JujutsuReviewSign = { fg = p.white, bold = p.bold, bg = p.bg1 },
    JujutsuReviewRemote = { fg = p.white, bg = p.bg1 },
    JujutsuReviewReply = { fg = p.white, italic = p.italic, bg = p.bg1 },
    JujutsuReviewRemoteSign = { fg = p.cyan, bold = p.bold, bg = p.bg1 },
    JujutsuReviewAuthor = { fg = p.blue, bold = p.bold, bg = p.bg1 },
    JujutsuReviewDate = { fg = p.grey, bg = p.bg1 },
    JujutsuReviewReviewed = { fg = p.green, bold = p.bold, bg = p.bg1 },
    JujutsuStatGraph = { fg = p.grey },
    JujutsuGraph = { fg = p.grey },
    JujutsuStatAdd = { fg = p.bg_green, bold = p.bold },
    JujutsuStatDelete = { fg = p.bg_red, bold = p.bold },
    JujutsuStatSigGood = { fg = p.bg_green, bold = p.bold },
    JujutsuStatSigBad = { fg = p.bg_red, bold = p.bold },
    JujutsuStatSigUnknown = { fg = p.yellow, bold = p.bold },
    JujutsuLualineAdd = { fg = p.bg_green, bold = p.bold },
    JujutsuLualineChange = { fg = p.yellow, bold = p.bold },
    JujutsuLualineDelete = { fg = p.bg_red, bold = p.bold },
    JujutsuLualineRev = { fg = p.cyan, bold = p.bold },
    JujutsuLualineBookmark = { fg = p.blue, bold = p.bold },
    JujutsuSignsAdd = { fg = p.bg_green, bold = p.bold },
    JujutsuSignsChange = { fg = p.yellow, bold = p.bold },
    JujutsuSignsDelete = { fg = p.bg_red, bold = p.bold },
    JujutsuAnnotateHash = { fg = p.purple },
    JujutsuAnnotateAuthor = { fg = p.blue },
    JujutsuAnnotateDate = { fg = p.grey },
    JujutsuAnnotateCurrent = { bg = p.bg2 },
    JujutsuAnnotateSelected = { bg = p.bg3 },
    JujutsuIssueTitle = { fg = p.fg, bold = p.bold },
    JujutsuIssueBody = { fg = p.fg },
    JujutsuIssueHeading = { fg = p.purple, bold = p.bold },
    JujutsuIssueList = { fg = p.fg },
    JujutsuIssueCode = { fg = p.cyan, bg = p.bg1 },
    JujutsuIssueLabel = { fg = p.orange },
    JujutsuIssueCommentAuthor = { fg = p.blue, bold = p.bold },
    JujutsuIssueStateOpen = { fg = p.green, bold = p.bold },
    JujutsuIssueStateClosed = { fg = p.red, bold = p.bold },
    JujutsuIssueStateMerged = { fg = p.purple, bold = p.bold },
    JujutsuIssueStateDraft = { fg = p.grey, bold = p.bold },
    JujutsuCiSuccess = { fg = p.green, bold = p.bold },
    JujutsuCiFailure = { fg = p.red, bold = p.bold },
    JujutsuCiPending = { fg = p.yellow, bold = p.bold },
    JujutsuCiWarning = { fg = p.orange, bold = p.bold },
    JujutsuCiId = { fg = p.green },
    JujutsuCiCommand = { fg = p.cyan },
  }

  for name, opts in pairs(groups) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

function M.attach_autocmd()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("JujutsuHighlights", { clear = true }),
    callback = function()
      M.setup()
      pcall(require("jujutsu.ansi").clear_hl_cache)
    end,
  })
end

---Highlight group for a jj/git-style file status letter (A/M/D/R/?/…).
---@param st string|nil
---@return string
function M.file_status(st)
  if st == "A" or st == "N" then return "JujutsuFileAdded" end
  if st == "D" then return "JujutsuFileDeleted" end
  if st == "?" then return "JujutsuFileUntracked" end
  if st == "R" or st == "C" then return "JujutsuFileRenamed" end
  return "JujutsuFileModified"
end

return M
