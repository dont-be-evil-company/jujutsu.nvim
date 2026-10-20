<div align="center">

![jujutsu.nvim Logo](assets/logo-256x256.png)

# jujutsu.nvim

A `Magit`-style [`Jujutsu (jj)`](https://github.com/jj-vcs/jj)
interface for Neovim.

---

Inspired by [`Neogit`](https://github.com/neogitorg/neogit)
rewritten without required plugin dependencies.

[Screenshots 📸](https://github.com/dont-be-evil-company/jujutsu.nvim/wiki/Screenshots)

</div>

## Recent Changes

See [`CHANGELOG.md`](CHANGELOG.md) for a full list of changes.

## Requirements

- Neovim 0.12+
- [`jj`](https://jj-vcs.github.io/jj/) on your `PATH`

**No required Neovim plugins.

### Optional 3rd party plugins

`jujutsu.nvim` comes with batteries included,
but you can optionally install external plugins for additional/different features.

#### Diff Viewer

The built-in diff viewer should work perfectly fine,
but if you absolutely must, you can install one of the following diff viewers and
pick it in the setup:

- [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) or
- [`codediff.nvim`](https://github.com/esmuellert/codediff.nvim)

```lua
local jj = require("jujutsu")
jj.setup({
  integrations = {
    -- nil = auto-detect, true = force, false = disable
    diffview = nil,
    codediff = nil,
  },
  -- "diffview" | "codediff" | nil = auto
  diff_viewer = nil,
})
```

#### Fuzzy Finder/Picker

Selections (revisions, bookmarks, PRs, …) use the built-in fuzzy finder
unless `picker` is set (see below).

```lua
local jj = require("jujutsu")
jj.setup({
  -- nil | "builtin" | "auto" | "telescope" | "fzf-lua" | "snacks" | "mini" | function
  picker = nil,
})
```

## Installation (`lazy.nvim`)

```lua
{
  "dont-be-evil-company/jujutsu.nvim",
  lazy = true,
  -- optional deps:
  -- dependencies = { "sindrets/diffview.nvim" },
  keys = {
    {
      "<leader>gg",
      function()
        require("jujutsu").open()
      end,
      desc = "Jujutsu",
    },
  },
  opts = {}, -- passed to setup()
}
```

There are **no** user commands (`:Jujutsu` isn't registered).
Use the Lua API.

## Lua API

```lua
local jj = require("jujutsu")

jj.setup({
  kind = "tab", -- tab | split | vsplit | floating | replace | auto | ...
  -- With kind = "floating", popups, diffs, panels, and the finder open inside that float.
  picker = nil, -- nil | "builtin" | "auto" | "telescope" | "fzf-lua" | "snacks" | "mini" | function
  mappings = {
    -- set a key to false to disable a default
    status = {
      ["q"] = "Close",
      ["x"] = "Discard",
    },
    popup = {
      ["c"] = "ChangePopup",
      ["b"] = "BookmarkPopup",
    },
  },
  integrations = {
    -- nil = auto-detect, true = force, false = disable
    diffview = nil,
    codediff = nil,
  },
  diff_viewer = nil, -- "diffview" | "codediff" | nil = auto
  file_history = { limit = 200, panel_height = 16 },
  annotate = { panel_height = 16 },
  disable_signs = false, -- gutter jjsigns (add/change/delete)
  signs = {
    item = { ">", "v" },
    section = { ">", "v" },
    add = { text = "┃" },
    change = { text = "┃" },
    delete = { text = "▁" },
    topdelete = { text = "▔" },
    changedelete = { text = "~" },
  },
  forge = { pr_integration = true },
  commit_date_format = "absolute", -- "absolute" | "relative" | strftime (e.g. "%Y-%m-%d %H:%M")
  log_date_format = "absolute",
})

jj.open()                              -- status buffer
jj.open({ kind = "split" })
jj.open({ cwd = vim.fn.expand("%:p:h") })
jj.open({ "change" })                  -- open a popup by name
jj.close()
jj.refresh()
jj.annotate()                          -- annotate current buffer at cursor line
jj.annotate({ path = "src/main.lua", line = 10 })
jj.review()                            -- pick an open PR/MR and review it
jj.review({ number = 15 })             -- open a specific PR/MR
jj.forge_popup()                       -- Magit-style forge hub (PRs, issues, CI)
jj.issue_panel()                       -- conversation panel (prompt for kind + number)
jj.issue_panel({ number = 12, kind = "issue" })
jj.get_presence()                      -- current jujutsu UI context (kind, path, revision, root)

-- Bindable action for your own keymaps:
vim.keymap.set("n", "<leader>jc", jj.action("change", "commit"))
vim.keymap.set("n", "<leader>jb", jj.annotate)
vim.keymap.set("n", "<leader>jr", jj.review)
vim.keymap.set("n", "<leader>jg", jj.forge_popup)
vim.keymap.set("n", "<leader>ji", jj.issue_panel)
```

### Popup Names

- `help`
- `change`
- `bookmark`
- `diff`
- `fetch`
- `forge`
- `log`
- `remote`
- `push`
- `rebase`
- `squash`
- `undo`
- `workspace`

## jjsigns

Gutter signs for working-copy line changes (like gitsigns, display-only).
Driven by `jj diff --git` against `@` parents. Refreshes on buffer enter /
write / focus and when `.jj` changes.

Disable with `disable_signs = true`, or customize glyphs via `signs.add` /
`signs.change` / `signs.delete` / `signs.topdelete` / `signs.changedelete`.

## Annotate

`jj file annotate` blame view: annotated lines on top, commits that touched the
file in a bottom panel (same idea as `dc`). Selecting a commit highlights its
lines in the annotate buffer.

- Magit: Diff popup `da` (file under cursor)
- Lua: `require("jujutsu").annotate()` (current buffer + cursor line)

## Forge hub (PRs, issues, CI)

Magit-style hub for forge workflows across GitHub, GitLab, Bitbucket, and
Forgejo/Codeberg. Actions are gated by per-forge capabilities (unsupported
ops are hidden).

**Entry points**

- Status popup key `g` (ForgePopup)
- `require("jujutsu").forge_popup()`

**Groups**


| Key | Action |
|-----|--------|
| `r` | Review open PR/MR (DiffView) |
| `p` | Browse / search PRs (filters: state, assignee/author, label, query) |
| `P` | Create PR (title, body, head/base, draft when supported) |
| `o` | Open PR by number (conversation panel) |
| `i` | Browse / search issues |
| `I` | Create issue |
| `n` | Open issue/PR by number (prompt) |
| `c` | List CI runs (open URL / cancel when allowed) |
| `t` | Trigger workflow / pipeline |


Label colors from the forge (bg/fg) are rendered in the conversation panel.

## PR / MR review

Tuicr-inspired code review on top of the built-in DiffView (file panel +
side-by-side). Existing inline comments from the forge (GitHub/GitLab/…) are
loaded and shown as cyan overlays; your new local comments are yellow until
you submit or yank markdown.

**Providers**


| Provider | Transport | Credentials |
|----------|-----------|-------------|
| GitHub | `gh` | `gh auth login` |
| GitLab | `glab` | `glab auth login` |
| Codeberg / Forgejo | `curl` REST | Prompted per host and stored under `stdpath("data")/jujutsu/credentials.json`, or `FORGEJO_TOKEN` / `CODEBERG_TOKEN` / `forge.forgejo.token` |
| Bitbucket Cloud | `curl` REST | Prompted per workspace (**Atlassian email** + API token) and stored in the same file, or `BITBUCKET_USER` + `BITBUCKET_TOKEN` / `forge.bitbucket.*`. |


> [!NOTE]
> Bitbucket API token scopes (create at [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens)):
> - `read:pullrequest:bitbucket`
> - `write:pullrequest:bitbucket`
> - `read:issue:bitbucket`
> - `write:issue:bitbucket`
> - `read:pipeline:bitbucket`
> - `write:pipeline:bitbucket`
> - `read:workspace:bitbucket` - **required to list assignees / PR reviewers** (workspace members). Without it, the assignee picker shows “No assignable users found”.
>
> After adding scopes,
> delete the stored entry (or reenter credentials on the next 401) so the new token is used.
> Credentials live under `stdpath("data")/jujutsu/credentials.json`.

On HTTP 401, review asks whether to supply new credentials or delete the stored ones.

**Entry points**

- Forge popup `g` → `r` (Review open PR/MR)
- `require("jujutsu").review()` / `.review({ number = 15 })`

**Review keymaps** (in DiffView review mode)


| Key | Action |
|-----|--------|
| `c` | Comment at cursor line |
| `a` | Reply to remote comment thread on this line |
| `C` | File comment |
| visual `c` | Range comment |
| `;c` | Review-level comment |
| `e` / `i` | Edit unsubmitted comment at cursor |
| `x` | Delete unsubmitted comment at cursor |
| `f` | Toggle all files / files with comments |
| `R` | Refresh all remote comments (in-memory cache) |
| `gr` | Refresh remote comments for the current file |
| `m` / `M` | Next / previous comment (in diff: move cursor; in file list: scroll diff, keep panel focus) |
| `r` | Toggle file reviewed (panel) |
| `y` | Yank structured markdown |
| `S` | Submit (Comment / Approve / Request changes; Draft on GitHub only) |
| `I` | Open Issue/PR conversation side panel |
| `o` | Open in browser (file at commit / PR line / conversation URL) |
| `?` | Help |


Sessions persist under `stdpath("data")/jujutsu/reviews/`. Bitbucket / Forgejo credentials persist under `stdpath("data")/jujutsu/credentials.json`.

```lua
forge = {
  pr_integration = true,
  review = {
    enabled = true,
    wrap_comments = true, -- wrap virt_line comments to the diff window
    wrap_width = nil, -- optional fixed column; nil = fit window
    render_markdown = true, -- treesitter-highlight virt_line comment bodies
    comment_indent = 4, -- fixed spaces before body lines (header is separate)
    keymaps = {
      filter = "f", -- all files <-> files with comments
      refresh_comments = "R", -- refresh full remote comment cache
      refresh_file_comments = "gr", -- refresh cache + overlays for current file
      reply = "a", -- reply to a remote inline comment thread
    },
  },
  bitbucket = { user = vim.env.BITBUCKET_USER, token = vim.env.BITBUCKET_TOKEN },
  forgejo = { token = vim.env.CODEBERG_TOKEN },
  hosts = {}, -- e.g. ["git.example.com"] = "gitlab"
},
issue_panel = {
  enabled = true,
  width = 0.38,
  min_width = 48,
  max_width = 90,
  position = "right",
  render_markdown = true, -- treesitter-highlight description/comment bodies
  keymaps = {
    close = "q",
    refresh = "r",
    comment = "c",
    edit_comment = "e",
    delete_comment = "x",
    edit_topic = "E",
    labels = "l",
    close_topic = "C",
    open = "I",
    browser = "o",
  },
},
```

## Issue / PR conversation panel

Full-height right split showing the selected issue or
pull request with its conversation (description + chronological comments).
Description and comment bodies are highlighted as markdown by default (all forges);
author/date headers stay plain. Labels use forge colors when available.

Inline review threads (including nested replies) stay in
the DiffView overlays; press `a` on a commented line to reply.

**Open from**

- Forge popup `g` (browse / open by number / create)
- Review DiffView: `I` (configurable via `issue_panel.keymaps.open`)
- Status / log: `I` - uses the PR number on a PR-annotated bookmark when present, otherwise prompts for kind + number
- API: `require("jujutsu").issue_panel()` / `.issue_panel({ number = 12, kind = "issue" })`

**Panel keys:** `c` comment · `e` edit comment · `x` delete comment · `l` labels · `E` edit title/body · `C` close/merge · `r` refresh · `o` open in browser · `q` close

Works on GitHub (`gh`), GitLab (`glab`), Bitbucket, and Forgejo/Codeberg (capabilities vary; unsupported actions are no-ops with a warning).

In DiffView, `o` is context-aware: file list opens the file at the PR head commit; the side-by-side diff opens the file in the PR at the cursor line.

## Status Buffer

Shows working-copy / parent headers,
conflicts,
file changes (inline diffs via `<Tab>`),
recent commits, and bookmarks.

### Default Popups (Lowercase)


| Key | Popup |
|-----|--------|
| `?` | Help |
| `b` | Bookmark |
| `c` | Change |
| `d` | Diff |
| `dd` | Working-copy side-by-side diff |
| `dc` | Change history (file under cursor → that path; revision → focus that change; else repo-wide) |
| `da` | Annotate file under cursor (`jj file annotate` + file history panel) |
| `dr` | Range side-by-side diff |
| `dt` | Trunk/main/master..@ side-by-side diff |
| `f` | Fetch |
| `g` | Forge (PRs, issues, CI, review) |
| `l` | Log |
| `m` | Remote |
| `p` | Push |
| `r` | Rebase |
| `s` | Squash |
| `u` | Undo |
| `w` | Workspace |


### Context Actions (Uppercase / Misc)


| Key | Action |
|-----|--------|
| `D` | Describe change under cursor |
| `E` | Edit change under cursor |
| `O` | New change on revision |
| `B` | New change before |
| `F` | Forget / track bookmark |
| `P` | Split change (opens split popup; visual-select hunks then `P`→`f`) |
| `S` | Open `--stat` view for change under cursor |
| `o` | Open in browser (forge) |
| `x` | Discard file / abandon change / delete bookmark |
| `q` | Close |
| `<C-r>` | Refresh |
| `<Tab>` | Toggle section / file diff / recent commit / bookmark history |
| `<CR>` | Open file / commit |


In the log view, `S` opens the `--stat` view and `P` opens the split popup for the
revision under the cursor.

Remap with:

```lua
require("jujutsu").setup({
  mappings = {
    status = { ["P"] = "Split" },
    log_view = { ["P"] = "Split" },
    -- or bind a popup key: popup = { ["P"] = "SplitPopup" },
  },
  stat_view = { kind = "vsplit" }, -- or "tab" / "split"
})
```

## `Lualine` Integration

> [!NOTE]
> oh-my-posh-style, with an ahead counter when
> you are not on the bookmark.

Colored `+` / `~` / `-` **line** counts for the working-copy diff (repo-wide),
plus the working-copy change id (prefixed with ``) and the **closest**
bookmark(s) on ancestors of `@`.

Uses the color API of `lualine`, so the **section background is preserved**.
Counts refresh on write / `cwd` change / focus (not every buffer switch).

**Important:** `components()` returns a *list* of components. Flatten it into the
section - do not put the list itself as one entry.

```lua
require("lualine").setup({
  sections = {
    -- default jujutsu lualine widget
    lualine_a = { "mode", "jujutsu" },
    -- jj widgets first, then your items:
    lualine_b = require("jujutsu.lualine").prepend({ "branch" }),

    -- your items first, then jj widgets:
    lualine_x = require("jujutsu.lualine").append({
      "kulala",
      "encoding",
      "fileformat",
      "filetype",
    }),

    -- or flatten manually:
    -- lualine_b = vim.list_extend({ "branch" }, require("jujutsu.lualine").components()),

    -- single plain component (one color, safe as `{ ... }`):
    -- lualine_b = { require("jujutsu.lualine").component() },
  },
})
```

Helpers: `require("jujutsu.lualine").rev()`, `.bookmark()`, `.diff()`, `.status()`.

Override any mapping in `setup({ mappings = ... })`, or set `use_default_keymaps = false` and define all yourself.

## License

See the [LICENSE](LICENSE) file for details.
