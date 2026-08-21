# lgtm.nvim

Review your branch's PR diff without leaving the editor — and fix things while
you're in there.

![Picking a branch and opening its PR diff](assets/pick-and-open.gif)

- **Edit in place.** The right-hand pane is the real working-tree file, not a
  copy. See a problem, fix it, `:w`, keep reviewing. The diff updates as you
  save.
- **AI comments, on demand.** Toggle in a third column of per-change notes,
  written by an agent that read the whole repository — not just the diff.
- **GitHub-style review flow.** PR description, changed-file tree, viewed
  ticks that persist across sessions, generated files pre-ticked and out of
  your way.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "simonhkswan/lgtm.nvim",
    dependencies = {
        "nvim-tree/nvim-web-devicons",       -- optional: file icons in the tree
        "nvim-telescope/telescope.nvim",     -- optional: only for :LgtmPick
    },
    cmd = { "LgtmEdit", "LgtmClose", "LgtmPick", "LgtmPr", "LgtmExplain" },
    keys = { { "<leader>gd", "<cmd>LgtmEdit<CR>", desc = "PR diff review" } },
    config = function()
        require("lgtm").setup({})
    end,
}
```

Requires Neovim 0.10+ and `git`. Optional: `gh` detects the PR's target branch
and fetches its description; `claude` powers the AI comments column.

## The review view

```
:LgtmEdit
```

Opens a tab with the PR description and file tree on the left, then the file
as it is on the target branch (read-only), then the real file on disk
(editable):

```
┌──────────────────┬──────────────────┬──────────────────┬───────────────────┐
│ #19624 ENG-9436… │                  │                  │                   │
│ open · → dev     │ BASE (read-only) │ WORKING          │ AI COMMENTS       │
│ +4997 −370       │ the file as it   │ (editable)       │ (on demand)       │
├──────────────────┤ is on the PR     │ the real file on │ per-hunk notes    │
│ changed files    │ target branch    │ disk — edit, :w  │ from an agent     │
│  81 files        │                  │                  │ that read the     │
│  12/81 viewed    │                  │                  │ repo              │
└──────────────────┴──────────────────┴──────────────────┴───────────────────┘
```

Diff highlighting, alignment and scroll locking all come from Vim's built-in
diff mode. The comparison is against the **merge base** — the same diff GitHub
shows on the PR — and against the **working tree**, so uncommitted edits show
up too.

The target branch is detected from the PR via `gh`, and falls back to your
config, `origin/HEAD`, then `origin/dev`/`origin/main`/`origin/master`. Or
pass one explicitly: `:LgtmEdit origin/release-2`.

### Keys

| Key | Where | Action |
|---|---|---|
| `m` / `n` | any pane | next / previous changed file |
| `<PageDown>` / `<PageUp>` | any pane | same, alternate binding |
| `M` / `N` | any pane | next / previous stream of work |
| `<S-PageDown>` / `<S-PageUp>` | any pane | same, alternate binding |
| `<End>` | any pane | toggle viewed — ticking advances to the next file |
| `<leader>ge` | any pane | toggle the AI comments column |
| `]c` / `[c` | diff panes | next / previous hunk (Vim built-in) |
| `<CR>` | tree | open file, or fold a directory |
| `v` | tree | toggle viewed |
| `q` | tree | close the session |

All bindings are buffer-local to the session's panes and configurable through
`keys`. Note that `m`/`n` shadow Vim's search-repeat inside those panes; rebind
them (for example back to `]f`/`[f`) if that matters to you.

Viewed ticks persist per branch, so a half-finished review resumes where you
left it. Ticks are dropped for files that changed after you ticked them.
Generated files (`-diff` / `linguist-generated` in `.gitattributes`) come
pre-ticked, as on GitHub.

## The AI comments column

![The AI comments column explaining a change](assets/explain.gif)

```
:LgtmExplain          toggle           <leader>ge
:LgtmExplain!         regenerate just the file you are on
```

One block per change region, aligned with the diff and scrolling with it:

```
┌────────────────────────────┬──────────────────────────────────────┐
│  def build_name(idx):      │  ▌ 120–134   +15 −3                  │
│ -    return f"IMG {idx}"   │  Move the naming rule out of the walk│
│ +    return allocate(idx)  │    Both editors walked the document  │
│                            │    and formatted the label inline;   │
│                            │    `image-name-allocation.ts` is now │
│                            │    the single statement of the rule. │
│  def walk(doc):            │                                      │
│      for node in doc:      │  ▌ 402   +1 −1                       │
│ -        n = build_name(i) │    ↑ one change with 120–134         │
└────────────────────────────┴──────────────────────────────────────┘
```

One headless `claude` run covers the whole PR. It gets the PR description and
explores the repository itself, so it can connect a hunk in one file to what
moved in another. Results stream in a file at a time — the file you have open
arrives first — and are cached per branch, so a second session costs nothing.

The agent runs with write access **denied inside your repository**, so it
cannot touch your working tree. Its notes explain what each change does and
what it affects elsewhere, against the full branch diff — never commit
archaeology.

Nothing runs until you toggle the column in; plenty of reviews do not want a
model call per file.

### Streams of work

The same run also writes a reviewer guide: the PR split into its streams of
work, each with a one-line title, a summary, and the files it touches. Once it
lands, a stream picker opens as its own pane between the PR description and the
file tree. The picker comes and goes with the comments column — one
`<leader>ge` toggles the pair, and toggling off drops any stream filter back to
all files:

```
│ 󰙴 STREAMS                            │
│ ● All files                          │
│   Cross-editor IMG. N allocation     │
│     0/4 viewed  ·  +435 −0           │
│   E2E coverage for inline images     │
│     2/3 viewed  ·  +118 −6           │
```

Both AI panes — the picker and the comments column — carry a `󰙴` header, so
generated content is labelled at a glance.

`<CR>` on a stream narrows the file tree — and paging, and the viewed-advance —
to that stream's files, and the description pane swaps to the stream's summary.
"All files" restores the full tree and the PR body. A file can belong to
several streams or to none, and the guide is cached with the explanations, so
it is there instantly on the next session.

## Picking a branch

```
:LgtmPick
```

A Telescope picker over your local branches, with the PR description and the
branch's changed files (with your viewed progress) previewed beside it.
`<CR>` opens the review — in the branch's worktree if it has one, otherwise
checking it out where you are. It refuses rather than touching uncommitted
work.

## Reviewing a PR that is not local yet

```
:LgtmPr 1234      fetch that PR's branch and open the review
:LgtmPr           pick from the repository's open PRs
```

For when someone asks "can you check my branch?". The bare form lists open
PRs, newest first (up to `pr_limit`, 1000 by default), searchable by number,
title, branch, and author, with the PR body as the preview; either form runs
`gh pr checkout` — fork PRs included — and opens the review. Requires `gh`, refuses over uncommitted work, and reuses an
existing worktree or checkout when the branch is already local.

## Options

```lua
require("lgtm").setup({
    base_branch = nil,          -- fallback when there's no PR and origin/HEAD is unset
    tree_width = 60,            -- width of the left column
    desc_height = 0.45,         -- fraction of it given to the PR description
    base_width = nil,           -- fixed width for the base pane; nil splits evenly
    include_untracked = true,   -- show files git doesn't know about yet
    advance = "next",           -- after ticking: "next" | "next_unviewed" | "none"
    generated = "skip",         -- "skip" pre-ticks generated files; "show" doesn't
    ruler = true,               -- change-position strip on the working pane's edge
    explain = {                 -- the AI comments column
        width = 76,
        cmd = { "claude" },     -- argv prefix; the headless flags are added
        model = "sonnet",       -- "" omits --model
        timeout = 1800000,      -- the whole run, not the first file
    },
    diff_colors = {},           -- calmer diff tints derived from your theme;
                                -- false keeps the colourscheme's own colours
    keys = { ... },             -- see defaults in lua/lgtm/init.lua
})
```

The full option set, including the AI agent's tool allow-list and the diff
colour tuning knobs, is documented in `lua/lgtm/init.lua`.

Set `LGTM_NO_GH=1` to skip the `gh` lookup entirely.
