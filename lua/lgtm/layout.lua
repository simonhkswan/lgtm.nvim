-- Window construction and the diff-pair lifecycle.
--
-- Everything visual about the diff itself — highlighting, filler lines that keep
-- the two sides aligned, scroll locking, character-level intra-line marking —
-- comes from Vim's built-in diff mode. Neovim 0.12 already defaults `diffopt` to
-- include `linematch` and `inline:char`, so nothing here reimplements any of it.
--
-- The session lives in its own tab page, which leaves the rest of your windows
-- untouched and makes teardown a single tab close.

local colors = require("lgtm.colors")
local git = require("lgtm.git")

local M = {}

--- Vim's diff mode pairs every window in the tab that has 'diff' set, so the
--- previous pair must be dismantled before a new one is built or the groups
--- bleed into one another.
local function clear_diff(win)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
            vim.cmd("diffoff")
        end)
    end
end

--- Fold summary line. The stock foldtext repeats the first line of the code it
--- is hiding, padded with dots — which is both the loudest thing on screen and
--- the least useful, since the whole point of the fold is that this region did
--- not change.
function M.foldtext()
    local count = vim.v.foldend - vim.v.foldstart + 1
    return string.format("  ⋯ %d unchanged lines", count)
end

-- `fold: ` stops the fold line being padded to full width with dots; the rest
-- are the box-drawing junctions Neovim uses to draw window separators once there
-- are no per-window statuslines to act as one.
local FILLCHARS =
    "fold: ,horiz:─,horizup:┴,horizdown:┬,vert:│,vertleft:┤,vertright:├,verthoriz:┼"

--- Window options shared by the two code panes.
local function configure_pane(win)
    -- Diff mode sets foldcolumn=2; it is empty except for a marker beside a
    -- closed fold, which the fold line already announces.
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldtext = "v:lua.require'lgtm.layout'.foldtext()"
    vim.wo[win].fillchars = FILLCHARS
    vim.wo[win].wrap = false
end

M.configure_pane = configure_pane

local function scratch(name)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    if name then
        pcall(vim.api.nvim_buf_set_name, buf, name)
    end
    return buf
end

--- Build the three windows: tree on the far left, base in the middle, working
--- file on the right.
function M.create(cfg)
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    -- With laststatus=2 every window gets its own statusline, so the split
    -- between the description and the tree renders a full status bar across the
    -- middle of the layout — and a plugin like vim-airline reclaims it on its
    -- own autocmds, so setting the window's statusline is not enough to stop it.
    -- A global statusline removes them all and lets Neovim draw real separators
    -- from fillchars instead. Saved so the session can put it back.
    local saved = { laststatus = vim.o.laststatus, fillchars = vim.o.fillchars }
    if cfg.global_statusline ~= false then
        vim.o.laststatus = 3
        vim.o.fillchars = FILLCHARS
    end

    -- Start with the working window, then peel the other two off to its left so
    -- the final left-to-right order is tree | base | working.
    local working_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(working_win, scratch(nil))

    vim.cmd("leftabove vsplit")
    local base_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(base_win, scratch(nil))

    vim.cmd("leftabove vsplit")
    local tree_win = vim.api.nvim_get_current_win()
    local tree_buf = scratch("lgtm://tree")
    vim.api.nvim_win_set_buf(tree_win, tree_buf)
    vim.api.nvim_win_set_width(tree_win, cfg.tree_width or 35)
    -- Left column plus base width comes straight out of the working pane, which
    -- is the one being edited. Leave it unset to split the remainder evenly.
    if cfg.base_width then
        vim.api.nvim_win_set_width(base_win, cfg.base_width)
    end

    -- The left column is split the same way the branch picker splits its right
    -- one: what the PR says on top, what it touches underneath.
    vim.cmd("leftabove split")
    local desc_win = vim.api.nvim_get_current_win()
    local desc_buf = scratch("lgtm://pr")
    vim.api.nvim_win_set_buf(desc_win, desc_buf)
    local column_height = vim.api.nvim_win_get_height(tree_win) + vim.api.nvim_win_get_height(desc_win)
    vim.api.nvim_win_set_height(desc_win, math.floor(column_height * (cfg.desc_height or 0.45)))

    vim.bo[desc_buf].filetype = "lgtm-pr"
    vim.wo[desc_win].number = false
    vim.wo[desc_win].relativenumber = false
    vim.wo[desc_win].signcolumn = "no"
    vim.wo[desc_win].colorcolumn = ""
    vim.wo[desc_win].cursorline = false
    vim.wo[desc_win].winfixwidth = true
    -- The body is hard-wrapped to the pane; this only catches what cannot break
    -- at a space, which is long URLs.
    vim.wo[desc_win].wrap = true
    vim.wo[desc_win].linebreak = true
    vim.wo[desc_win].breakindent = true

    vim.bo[tree_buf].filetype = "lgtm-tree"
    vim.wo[tree_win].number = false
    vim.wo[tree_win].relativenumber = false
    vim.wo[tree_win].wrap = false
    vim.wo[tree_win].signcolumn = "no"
    vim.wo[tree_win].cursorline = true
    vim.wo[tree_win].winfixwidth = true
    vim.wo[tree_win].colorcolumn = ""

    -- Muted diff colours, scoped to these two windows only.
    if cfg.diff_colors ~= false then
        colors.apply(base_win, working_win, cfg.diff_colors or {})
    end

    return {
        tab = tab,
        tree_win = tree_win,
        tree_buf = tree_buf,
        desc_win = desc_win,
        desc_buf = desc_buf,
        base_win = base_win,
        working_win = working_win,
        saved_opts = saved,
    }
end

-- Winbar text is a statusline expression, so a literal % in a path would be read
-- as a format item. Only the dynamic parts get escaped — the highlight-group
-- markers this builds are deliberate.
local function esc(s)
    return (tostring(s):gsub("%%", "%%%%"))
end

local function set_winbar(win, text)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.wo[win].winbar = text
    end
end

--- Split a path so the directory can be dimmed and the filename emphasised.
--- The name is what you are looking for; the path is context.
local function split_path(path, budget)
    local dir, name = path:match("^(.*/)([^/]+)$")
    if not dir then
        return "", path
    end
    local room = budget - #name
    -- With a long filename there may be no room for any directory at all. Drop
    -- it rather than letting it through: an over-long winbar is truncated
    -- wholesale by Neovim, which eats the filename from the left and leaves the
    -- one piece that actually matters unreadable.
    if room < 6 then
        return "", name
    end
    -- Elide from the left: the deepest directory is the informative end, and it
    -- is the part sitting next to the filename.
    if #dir > room then
        dir = "…" .. dir:sub(-(room - 1))
    end
    return dir, name
end

-- The AI headers' ramp: magenta washing outward to pink-white, one shade per
-- letter, the last covering the tail. These are the RGB values of the xterm
-- steps 201→207→213→219→225 — the same wash codex's `ultra` effort wears.
local AI_RAMP = { "#ff00ff", "#ff5fff", "#ff87ff", "#ffafff", "#ffd7ff" }

--- Paint a winbar label one character per ramp shade. The result is a
--- statusline expression; feed it plain ASCII only.
function M.ai_label(text)
    local parts = {}
    for i = 1, #text do
        table.insert(parts, string.format("%%#LgtmWinbarAI%d#%s", math.min(i, #AI_RAMP), text:sub(i, i)))
    end
    return table.concat(parts)
end

function M.setup_winbar_highlights()
    -- No background: a statusline highlight with one would read as a bar again,
    -- which is the thing being removed.
    vim.api.nvim_set_hl(0, "LgtmDivider", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmWinbarLabel", { link = "Title" })
    vim.api.nvim_set_hl(0, "LgtmWinbarDim", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LgtmWinbarName", { bold = true })
    vim.api.nvim_set_hl(0, "LgtmWinbarBadge", { link = "WarningMsg" })
    -- The headers of the AI-generated panes — the stream picker and the
    -- explanation column — so generated content is labelled at a glance. The
    -- icon takes the ramp's full magenta; the label washes out across it.
    for i, fg in ipairs(AI_RAMP) do
        vim.api.nvim_set_hl(0, "LgtmWinbarAI" .. i, { fg = fg, bold = true })
    end
    vim.api.nvim_set_hl(0, "LgtmWinbarAIIcon", { fg = AI_RAMP[1], bold = true })
end

--- Show one file's before/after pair.
--- @param session table the live session
--- @param entry table a changed-file entry from git.changed_files
function M.show_file(session, entry)
    local cfg, root = session.cfg, session.root

    clear_diff(session.base_win)
    clear_diff(session.working_win)

    local base_path = entry.old_path or entry.path
    local rel = entry.path

    -- Left: the file as it exists on the base branch.
    local base_buf = scratch(string.format("lgtm://%s/%s", session.merge_base:sub(1, 7), base_path))
    local base_note, raw
    if entry.status == "A" or entry.status == "U" then
        -- Added on this branch: there is no base version, so the left pane is
        -- deliberately empty and every line reads as an addition.
        base_note = "(new file)"
    else
        raw = git.show(session.merge_base, base_path, root)
        if not raw then
            base_note = "(not in base)"
        end
    end

    local diffable = true
    if raw and git.is_binary(raw) then
        diffable, base_note = false, "(binary)"
        raw = nil
    end

    vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, raw and vim.split(raw, "\n", { plain = true }) or {})
    vim.bo[base_buf].modifiable = false
    vim.api.nvim_win_set_buf(session.base_win, base_buf)

    -- Right: the actual working-tree file, opened normally so it is editable and
    -- writable. Deleted files have nothing to open, so they get a placeholder.
    local abs = vim.fs.joinpath(root, entry.path)
    local working_note
    if entry.status == "D" or vim.fn.filereadable(abs) == 0 then
        local buf = scratch("lgtm://deleted/" .. entry.path)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  This file is deleted on this branch.", "" })
        vim.bo[buf].modifiable = false
        vim.api.nvim_win_set_buf(session.working_win, buf)
        working_note, diffable = "(deleted)", false
    else
        local size = vim.fn.getfsize(abs)
        vim.api.nvim_win_call(session.working_win, function()
            vim.cmd("edit " .. vim.fn.fnameescape(abs))
        end)
        local wbuf = vim.api.nvim_win_get_buf(session.working_win)
        if size > (cfg.max_file_size or 1024 * 1024) then
            diffable, working_note = false, "(too large to diff)"
        end
        -- Give the base pane the same filetype so it is syntax-highlighted too.
        vim.bo[base_buf].filetype = vim.bo[wbuf].filetype
    end

    if diffable then
        vim.api.nvim_win_call(session.base_win, function()
            vim.cmd("diffthis")
        end)
        vim.api.nvim_win_call(session.working_win, function()
            vim.cmd("diffthis")
        end)
    end

    -- After diffthis, which resets foldcolumn to the diffopt default.
    configure_pane(session.base_win)
    configure_pane(session.working_win)

    -- Hunk boundaries, kept so the panes can be realigned after a scroll that
    -- bypassed 'scrollbind'. Same options Neovim's diff mode uses, so the
    -- mapping agrees with the filler lines actually drawn on screen.
    session.hunks = nil
    if diffable then
        local base_text = table.concat(vim.api.nvim_buf_get_lines(base_buf, 0, -1, false), "\n")
        local work_buf = vim.api.nvim_win_get_buf(session.working_win)
        local work_text = table.concat(vim.api.nvim_buf_get_lines(work_buf, 0, -1, false), "\n")
        local ok, hunks = pcall(vim.diff, base_text, work_text, {
            result_type = "indices",
            algorithm = "histogram",
            indent_heuristic = true,
            linematch = 40,
        })
        session.hunks = ok and hunks or nil
    end


    local index, total = session.index, #session.entries

    local function bar(win, label, badge, trailing)
        badge = badge or ""
        -- Budget the path against what is actually left after the fixed parts,
        -- per pane, since the two carry different badges and trailing text.
        -- Display width, not byte length: ✓ and · are multi-byte and would
        -- otherwise be over-counted against the budget.
        local w = vim.fn.strdisplaywidth
        local avail = vim.api.nvim_win_get_width(win)
        local fixed = 3 + w(label) + 2 + (badge ~= "" and (2 + w(badge)) or 0) + 2 + w(trailing)
        local room = math.max(8, avail - fixed)
        local dir, name = split_path(rel, room)

        -- Last resort: with a long filename and a wide badge even the bare name
        -- can overrun, and Neovim truncates an over-long winbar from the left —
        -- eating the filename and leaving the one part that matters unreadable.
        if w(dir) + w(name) > room then
            dir = ""
            if w(name) > room then
                local ext = name:match("(%.[%w_]+)$") or ""
                if #ext > 7 then
                    ext = ""
                end
                name = name:sub(1, math.max(1, room - #ext - 1)) .. "…" .. ext
            end
        end

        local parts = {
            "%#LgtmWinbarLabel# ",
            esc(label),
            "  %#LgtmWinbarDim#",
            esc(dir),
            "%#LgtmWinbarName#",
            esc(name),
        }
        if badge ~= "" then
            table.insert(parts, "  %#LgtmWinbarBadge#" .. esc(badge))
        end
        -- Two spaces before %= guarantee a gap: %= fills to the right edge, so
        -- without them a long path butts straight up against the status text.
        table.insert(parts, "  %#LgtmWinbarDim#%=" .. esc(trailing) .. " ")
        return table.concat(parts)
    end

    -- Terse badges: every character here is taken from the filename's budget.
    local status = ({ A = "new", U = "untracked", D = "deleted", R = "renamed" })[entry.status]
    if entry.generated then
        status = "generated"
    end

    set_winbar(
        session.base_win,
        bar(session.base_win, "BASE", base_note, session.base_ref .. " @ " .. session.merge_base:sub(1, 7))
    )
    set_winbar(
        session.working_win,
        bar(
            session.working_win,
            "WORKING",
            working_note or status,
            (session.store:is_viewed(entry.path) and "✓ viewed   " or "") .. string.format("file %d/%d", index, total)
        )
    )
end

--- Map a line in one pane to the line beside it in the other, using the hunk
--- boundaries the diff was built from.
---
--- This is approximate in one direction. Where a pane sits inside a run of
--- filler lines, many lines on the other side share the same position, so the
--- relationship is not invertible and the result there is a best guess. It is
--- accurate everywhere else, which is enough to keep the panes together.
local function map_line(hunks, lnum, forward)
    local offset = 0
    for _, h in ipairs(hunks or {}) do
        local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
        if not forward then
            sa, ca, sb, cb = sb, cb, sa, ca
        end
        if ca == 0 then
            -- This side has no lines in the hunk: vim.diff reports the position
            -- as the line the other side's block hangs *after*, not a line the
            -- hunk covers, so it must not consume one here.
            if lnum <= sa then
                break
            end
            offset = offset + cb
        else
            if lnum < sa then
                break
            end
            if lnum < sa + ca then
                -- Inside a hunk the two sides have different line counts, so
                -- advancing one does not always advance the other. Scrolling
                -- through a pure insertion leaves the opposite pane parked where
                -- the insertion hangs off, which is what the clamp does.
                local within = math.min(lnum - sa, math.max(cb - 1, 0))
                return math.max(1, sb + within)
            end
            offset = offset + (cb - ca)
        end
    end
    return math.max(1, lnum + offset)
end

--- Realign the panes after one of them scrolled without 'scrollbind' having run,
--- which is what happens when the mouse wheel turns over an unfocused window.
---
--- The partner's view is set directly rather than by replaying scroll commands.
--- Replaying makes scrollbind move this window in turn, firing WinScrolled
--- again, and the two panes chase each other to the end of the file.
function M.sync_scroll(session, scrolled)
    local other = scrolled == session.base_win and session.working_win or session.base_win
    if not (vim.api.nvim_win_is_valid(scrolled) and vim.api.nvim_win_is_valid(other)) then
        return
    end
    local top = vim.api.nvim_win_call(scrolled, function()
        return vim.fn.line("w0")
    end)
    local target = map_line(session.hunks, top, scrolled == session.base_win)
    vim.api.nvim_win_call(other, function()
        local view = vim.fn.winsaveview()
        if view.topline ~= target then
            view.topline = target
            view.lnum = math.max(view.lnum, target)
            vim.fn.winrestview(view)
        end
    end)
end

function M.close(session)
    -- Global options the session borrowed, handed straight back.
    if session.saved_opts then
        vim.o.laststatus = session.saved_opts.laststatus
        vim.o.fillchars = session.saved_opts.fillchars
    end
    clear_diff(session.base_win)
    clear_diff(session.working_win)
    if session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
        -- Closing the tab takes the whole layout with it.
        local current = vim.api.nvim_get_current_tabpage()
        if current == session.tab then
            vim.cmd("tabclose")
        else
            vim.api.nvim_set_current_tabpage(session.tab)
            vim.cmd("tabclose")
        end
    end
end

return M
