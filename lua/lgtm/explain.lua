-- The explanation column: a fourth pane, right of the working file, carrying one
-- block per hunk and scrolling with it.
--
-- Not created with the session. A review often does not need it — the diff is the
-- diff — and it costs an agent invocation per file, so it is opened on demand and
-- populated at that moment.
--
-- One block per *region*, not per hunk. A region is a run of hunks with no fold
-- between them, which is what the reviewer sees as one contiguous block of
-- change. Explaining raw `vim.diff` hunks instead spends a block on every
-- consequence of a nearby edit — a line that moved because four lines above it
-- were deleted is its own hunk, and it is not its own change.
--
-- Alignment is anchored, not row-for-row. A block of prose about a two-line hunk
-- is taller than the hunk it describes, so padding the pane to the working file's
-- length cannot both keep every block level with its hunk and keep them from
-- colliding. Instead each hunk is an anchor pairing a working-file line with an
-- explanation line, and the pane's top is interpolated between the two anchors
-- the viewport currently sits between — then clamped so the block for the hunk
-- you are actually looking at stays on screen. Landing exactly on a hunk puts its
-- explanation exactly at the top; between hunks the pane slides.

local ai = require("lgtm.ai")
local colors = require("lgtm.colors")
local git = require("lgtm.git")
local markdown = require("lgtm.markdown")
local state = require("lgtm.state")
local store = require("lgtm.store")

local M = {}

local PAD_NS = vim.api.nvim_create_namespace("lgtm_explain_pad")

--- Guards the write-back into the pane's own view, which fires WinScrolled and
--- would otherwise re-enter through the session's scroll autocmd.
local syncing = false

function M.setup_highlights(diff_colors)
    local opts = type(diff_colors) == "table" and diff_colors or {}
    vim.api.nvim_set_hl(0, "LgtmExplainHead", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmExplainTitle", { bold = true })
    vim.api.nvim_set_hl(0, "LgtmExplainMeta", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LgtmExplainAdd", { fg = colors.accent("add", opts) })
    vim.api.nvim_set_hl(0, "LgtmExplainDel", { fg = colors.accent("delete", opts) })
    -- No "active block" highlight: the panes are aligned row for row, so which
    -- explanation belongs to what you are looking at is answered by where it is.
end

function M.is_open(session)
    return session ~= nil
        and session.explain_win ~= nil
        and vim.api.nvim_win_is_valid(session.explain_win)
end

-- ---------------------------------------------------------------------------
-- The store
--
-- One directory per branch and merge base, one JSON file per changed file, written
-- by the agent itself. See store.lua for why that shape.
-- ---------------------------------------------------------------------------

local function store_dir(session)
    return store.dir(session.branch, session.merge_base, ai.PROMPT_VERSION)
end

--- The full change. `session.entries` is the list the tree is showing, and a
--- selected stream narrows it — but the run, its progress and its resume list are
--- always about every file in the PR.
local function all_entries(session)
    return session.all_entries or session.entries
end

--- How far the run has got, for the pane's own progress line.
local function progress(session)
    local done = 0
    for _ in pairs(session.explain_store or {}) do
        done = done + 1
    end
    return done, #all_entries(session)
end

--- Files in the change with no explanation yet.
local function outstanding(session)
    local out = {}
    for _, e in ipairs(all_entries(session)) do
        if not (session.explain_store or {})[e.path] then
            table.insert(out, e.path)
        end
    end
    return out
end

--- Drop this branch's store. Exposed as :LgtmExplainClearCache, because a prompt
--- this long is worth iterating on and stale results hide the change.
function M.clear_store(session)
    if not session then
        return 0
    end
    session.explain_store = {}
    local n = store.clear(store_dir(session))
    -- The guide is part of the store, so clearing one clears the other; the
    -- stream picker follows it off the screen.
    if session.guide then
        session.guide, session.guide_json = nil, nil
        if session.on_guide then
            session.on_guide()
        end
    end
    return n
end

--- The reviewer guide for this branch, if a run has written one.
function M.load_guide(session)
    return store.load_guide(store_dir(session))
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Where a hunk sits in the working file: a range when it has lines there, a
--- single position when it only removes.
local function hunk_span(h)
    local count_a, start_b, count_b = h[2], h[3], h[4]
    if count_b > 0 then
        return start_b, start_b + count_b - 1, count_b, count_a
    end
    return start_b, start_b, 0, count_a
end

local function span_label(first, last, added)
    if added == 0 then
        return "after " .. first
    elseif first == last then
        return tostring(first)
    end
    return string.format("%d–%d", first, last)
end

--- Unchanged lines within `context` of a change are left unfolded by Vim, so a
--- gap of 2*context or less between two hunks is never collapsed and the two read
--- as one region on screen.
local function diff_context()
    for _, part in ipairs(vim.split(vim.o.diffopt or "", ",", { plain = true })) do
        local n = part:match("^context:(%d+)$")
        if n then
            -- `context:0` means one, not zero: "folds require a line in between,
            -- also for a deleted line". Taking it literally would make the merge
            -- rule stricter than the folds it is meant to model.
            return math.max(1, tonumber(n))
        end
    end
    -- Absent from diffopt, which is the default, and Vim then uses six.
    return 6
end

--- Collapse hunks into the regions the reviewer actually sees.
--- @param view_height number|nil rows in the code pane; caps the merge distance
--- @return table list of { first, last, base_last, added, removed, hunks }
local function build_regions(hunks, context, view_height)
    -- Folds are why two hunks read as one region, but `context:999999` is the
    -- documented way to disable folding altogether, and that would otherwise
    -- collapse a whole file of scattered changes into a single block. Two changes
    -- that cannot be on screen together are not one region whatever the fold
    -- settings say, so the pane's height is the ceiling.
    local limit = math.min(2 * context, view_height or math.huge)
    local out = {}
    for i, h in ipairs(hunks or {}) do
        local first, last, added, removed = hunk_span(h)
        -- Where the region ends on the base side. When a side has no lines in the
        -- hunk `vim.diff` reports the line the other side's block hangs after, so
        -- that is already the last line this side covers.
        local base_last = h[2] > 0 and (h[1] + h[2] - 1) or h[1]
        local prev = out[#out]
        if prev and (first - prev.last - 1) <= limit then
            prev.last = math.max(prev.last, last)
            prev.base_last = math.max(prev.base_last, base_last)
            prev.added = prev.added + added
            prev.removed = prev.removed + removed
            table.insert(prev.hunks, i)
        else
            table.insert(out, {
                first = first,
                last = last,
                base_last = base_last,
                added = added,
                removed = removed,
                hunks = { i },
            })
        end
    end
    return out
end

M._build_regions = build_regions

--- Display rows the code pane leaves beside region `i`, from its first line up to
--- the next region's. Display rows, not buffer lines: the gap between two regions
--- is a closed fold plus its context, which is a dozen rows however many hundred
--- lines it stands for. That is the number an explanation has to fit inside.
--- Display rows the working pane needs for buffer lines 1..line-1 — which is the
--- screen row that line sits on, counted from the top of the buffer.
---
--- Display rows rather than buffer lines is the whole basis of the alignment: folds,
--- diff filler and virtual lines are all already folded into this number, so a
--- canvas indexed by it needs to reproduce none of them.
local function rows_above(win, line)
    if line <= 1 then
        return 0
    end
    local ok, h = pcall(vim.api.nvim_win_text_height, win, { start_row = 0, end_row = line - 2 })
    return (ok and h and h.all) or (line - 1)
end

local function total_rows(win)
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    local ok, h = pcall(vim.api.nvim_win_text_height, win, { start_row = 0, end_row = count - 1 })
    return (ok and h and h.all) or count
end

--- Everything the laid-out pane depends on: the width, which sets how the prose
--- wraps and therefore every block's height, and the screen row each region sits on.
--- Both change without anything regenerating — the pane is resized, a fold is opened
--- — so both are watched rather than assumed fixed.
---
--- The rows are measured rather than inferred from the fold state. Probing folds
--- directly is what the first attempt did, by asking whether the line after a region
--- was folded — and that line is always inside the region's own unfolded context, so
--- opening every fold in the file changed nothing it could see.
local function layout_signature(session)
    if not M.is_open(session) then
        return nil
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return nil
    end
    local parts = { vim.api.nvim_win_get_width(session.explain_win) }
    for _, r in ipairs(session.explain_regions or {}) do
        table.insert(parts, rows_above(win, r.first))
    end
    table.insert(parts, total_rows(win))
    return table.concat(parts, ":")
end

--- Blank display rows inserted below a region, so the next region is pushed far
--- enough down the screen that this region's explanation fits beside it.
---
--- Virtual lines rather than real ones: the working pane is the file itself, and
--- padding it with blank lines would mean editing the thing under review. They go
--- into both code panes at the same logical line — the end of the region's trailing
--- context, where the fold begins — because those context lines are unchanged and
--- therefore common to the two sides, so the same offset lands on the same row in
--- each and the panes stay level with one another.
local function clear_padding(session)
    for _, buf in ipairs(session.explain_padded or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, PAD_NS, 0, -1)
        end
    end
    session.explain_padded = {}
end

--- @param deficits table region index -> extra rows wanted below it
local function apply_padding(session, deficits)
    clear_padding(session)
    if session.cfg.explain.pad == false or not M.is_open(session) then
        return false
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(session.base_win)) then
        return false
    end
    if vim.tbl_isempty(deficits) then
        return false
    end

    local wbuf = vim.api.nvim_win_get_buf(win)
    local bbuf = vim.api.nvim_win_get_buf(session.base_win)
    local wcount = vim.api.nvim_buf_line_count(wbuf)
    local bcount = vim.api.nvim_buf_line_count(bbuf)
    local regions = session.explain_regions or {}
    local context = diff_context()

    local touched, seen = {}, {}
    for i, need in pairs(deficits) do
        local r = regions[i]
        if r then
            local virt = {}
            for _ = 1, need do
                table.insert(virt, { { "", "NonText" } })
            end
            -- Never past the start of the next region, and never the buffer's final
            -- line: virtual lines attached there are not counted as display rows —
            -- measurably, nvim_win_text_height returns the unpadded number — so a
            -- region at the end of the file would be given room that does not exist.
            local ceiling = regions[i + 1] and (regions[i + 1].first - 1) or math.huge
            for buf, row in pairs({
                [wbuf] = math.min(r.last + context, ceiling, math.max(1, wcount - 1)) - 1,
                [bbuf] = math.min((r.base_last or r.last) + context, math.max(1, bcount - 1)) - 1,
            }) do
                if row >= 0 then
                    pcall(vim.api.nvim_buf_set_extmark, buf, PAD_NS, row, 0, { virt_lines = virt })
                    if not seen[buf] then
                        seen[buf] = true
                        table.insert(touched, buf)
                    end
                end
            end
        end
    end
    session.explain_padded = touched
    return true
end

--- One block per region: its lines and their highlights, with no position yet.
---
--- Deliberately one per region even where the agent grouped several: the group's
--- text is stated once, on the first of them, and the others point back at it. A
--- block per *group* would put the blocks out of file order the moment a group
--- straddled an ungrouped region.
local function build_blocks(session, by_region, width)
    local text_width = math.max(20, width - 4)
    local blocks = {}

    for i, r in ipairs(session.explain_regions or {}) do
        local lines, marks = {}, {}
        local function emit(line, hl, col, end_col)
            table.insert(lines, line)
            if hl then
                table.insert(marks, { line = #lines - 1, col = col or 0, end_col = end_col or #line, hl = hl })
            end
        end

        local head = string.format("  ▌ %s", span_label(r.first, r.last, r.added))
        local counts = string.format("   +%d −%d", r.added, r.removed)
        table.insert(lines, head .. counts)
        local row = #lines - 1
        table.insert(marks, { line = row, col = 0, end_col = #head, hl = "LgtmExplainHead" })
        local plus_at = #head + 3
        local plus_len = #string.format("+%d", r.added)
        table.insert(marks, { line = row, col = plus_at, end_col = plus_at + plus_len, hl = "LgtmExplainAdd" })
        table.insert(marks, {
            line = row,
            col = plus_at + plus_len + 1,
            end_col = #head + #counts,
            hl = "LgtmExplainDel",
        })

        local e = by_region and by_region[i]
        if not e then
            emit("    …", "LgtmExplainMeta", 0, 5)
        elseif not e.lead then
            local lead = session.explain_regions[e.group[1]]
            emit("    ↑ one change with " .. span_label(lead.first, lead.last, lead.added), "LgtmExplainMeta")
        else
            if e.title ~= "" then
                for _, l in ipairs(markdown.wrap(e.title, text_width, "  ")) do
                    emit(l, "LgtmExplainTitle")
                end
            end
            -- Two spaces of lead on every body line: markdown.format takes a line's
            -- own indent as the indent for its wrapped continuations, so this is how
            -- a bullet's second line lands under its text.
            local indented = {}
            for _, l in ipairs(vim.split(e.body, "\n", { plain = true })) do
                table.insert(indented, "  " .. l)
            end
            local body_lines, body_marks = markdown.format(table.concat(indented, "\n"), text_width)
            local offset = #lines
            vim.list_extend(lines, body_lines)
            for _, m in ipairs(body_marks) do
                table.insert(marks, {
                    line = m.line + offset,
                    col = m.col,
                    end_col = m.end_col,
                    hl = m.hl,
                    eol = m.eol,
                })
            end
        end

        blocks[i] = { lines = lines, marks = marks }
    end
    return blocks
end

--- Lay the blocks out on a canvas indexed by the working pane's display rows, so
--- canvas line N is screen row N of the diff and every block starts level with its
--- own region.
---
--- Where a block is taller than the rows between its region and the next, it reports
--- the shortfall rather than overlapping: the caller pads the code panes to open the
--- gap and lays out again. That is the only reason padding exists.
--- @return table lines, table marks, table positions, table deficits
local function place_blocks(session, blocks)
    local win = session.working_win
    local regions = session.explain_regions or {}
    local lines, marks, positions, deficits = {}, {}, {}, {}

    for i, block in ipairs(blocks) do
        local target = rows_above(win, regions[i].first)
        if #lines > target then
            -- The previous block has run into this one's row. Ask for the difference
            -- below the previous region and lay out again.
            deficits[i - 1] = (deficits[i - 1] or 0) + (#lines - target)
        else
            for _ = #lines + 1, target do
                table.insert(lines, "")
            end
        end
        positions[i] = { line = #lines, count = #block.lines }
        local offset = #lines
        vim.list_extend(lines, block.lines)
        for _, m in ipairs(block.marks) do
            table.insert(marks, {
                line = m.line + offset,
                col = m.col,
                end_col = m.end_col,
                hl = m.hl,
                eol = m.eol,
            })
        end
    end

    -- Out to the full height of the diff, so the pane can be scrolled to the end of
    -- the file rather than stopping at the last explanation.
    for _ = #lines + 1, total_rows(win) do
        table.insert(lines, "")
    end
    return lines, marks, positions, deficits
end

--- Lay out, pad, lay out again. Two passes is enough: the first discovers every
--- shortfall, the padding opens exactly those gaps, and the second sees the rows it
--- asked for. A third is allowed only because padding is clamped near the end of the
--- file and can come up short there.
local function render(session, by_region, width)
    local blocks = build_blocks(session, by_region, width)
    if #blocks == 0 then
        session.explain_blocks = {}
        markdown.apply(session.explain_buf, { "", "  Nothing to explain in this file." }, {
            { line = 1, col = 0, end_col = 40, hl = "LgtmExplainMeta" },
        })
        return
    end

    clear_padding(session)
    local lines, marks, positions
    for _ = 1, 3 do
        local deficits
        lines, marks, positions, deficits = place_blocks(session, blocks)
        if vim.tbl_isempty(deficits) or not apply_padding(session, deficits) then
            break
        end
    end

    session.explain_blocks = positions
    markdown.apply(session.explain_buf, lines, marks)
    session.explain_layout_width = width
    session.explain_sig = layout_signature(session)
end


local function render_status(session, headline, detail)
    if not (session.explain_buf and vim.api.nvim_buf_is_valid(session.explain_buf)) then
        return
    end
    local width = vim.api.nvim_win_get_width(session.explain_win or 0)
    local lines, marks = { "", "  " .. headline }, {}
    table.insert(marks, { line = 1, col = 0, end_col = #lines[2], hl = "LgtmExplainTitle" })
    for _, l in ipairs(markdown.wrap(detail or "", math.max(20, width - 4), "  ")) do
        table.insert(lines, l)
        table.insert(marks, { line = #lines - 1, col = 0, end_col = #l, hl = "LgtmExplainMeta" })
    end
    session.explain_blocks = {}
    session.explain_sig, session.explain_layout_width = nil, nil
    clear_padding(session)
    markdown.apply(session.explain_buf, lines, marks)
end

local function set_winbar(session, entry, note)
    if not M.is_open(session) then
        return
    end
    local name = entry and entry.path or ""
    note = note or ""
    -- Budget the path against the pane, the same way layout.bar does. Neovim
    -- truncates an over-long winbar from the LEFT, so without this a long path
    -- pushes the sparkle and the EXPLAIN label off the edge and the bar reads
    -- as a bare filename. Elide the path from its own left instead: the
    -- deepest directories and the filename are the informative end.
    local w = vim.fn.strdisplaywidth
    local avail = vim.api.nvim_win_get_width(session.explain_win)
    local fixed = w(" 󰙴 EXPLAIN  ") + (note ~= "" and (w(note) + 3) or 1)
    local room = math.max(8, avail - fixed)
    if w(name) > room then
        name = "…" .. name:sub(-(room - 1))
    end
    local text = table.concat({
        -- The sparkle, then the label in the magenta wash: this pane's content
        -- is generated, and the same mark sits on the stream picker.
        "%#LgtmWinbarAIIcon# 󰙴 " .. require("lgtm.layout").ai_label("EXPLAIN") .. "  %#LgtmWinbarDim#",
        (name:gsub("%%", "%%%%")),
        "  %=",
        (note:gsub("%%", "%%%%")),
        " ",
    })
    vim.wo[session.explain_win].winbar = text
end

-- ---------------------------------------------------------------------------
-- Alignment
-- ---------------------------------------------------------------------------

--- Interpolate a working-file line onto an explanation line, between the two
--- anchors it falls between.
--- Put the explanation pane at the same screen row as the working pane.
---
--- Measured, not calculated. The obvious arithmetic — count the display rows above
--- the top line and put that canvas line at the top — is wrong in a way that took a
--- probe to see: `nvim_win_text_height` does not count virtual lines attached to the
--- last line of the range it is given, and `winsaveview().topfill` *does* count those
--- same rows when they are showing above the top line. Subtracting one from the other
--- therefore removes the padding twice, and the pane sits exactly `pad` rows out.
---
--- So instead: take a region whose first line is on screen, ask where that line
--- actually is with `screenpos`, and put its block on the same row. Region lines are
--- the reliable reference — never inside a fold, and their canvas position was
--- computed from the same measurement.
function M.sync(session)
    if syncing or not M.is_open(session) then
        return
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end

    local view = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
    end)
    -- The pane's first drawn row, which is NOT where the top line's text is: diff
    -- filler and padding above it are drawn first, and `topfill` counts them. Getting
    -- this wrong is what put the pane exactly `topfill` rows out. The explanation pane
    -- has neither, so its first drawn row is simply its top line.
    local top_row = vim.fn.screenpos(win, view.topline, 1).row - (view.topfill or 0)

    local target
    if top_row > 0 then
        for i, r in ipairs(session.explain_regions or {}) do
            local block = (session.explain_blocks or {})[i]
            local row = block and vim.fn.screenpos(win, r.first, 1).row or 0
            if row > 0 then
                -- The region sits (row - top_row) rows below the top line's own row;
                -- put its block the same distance below the canvas line at the top.
                target = block.line + 1 - (row - top_row)
                break
            end
        end
    end
    if not target then
        -- Nothing to anchor on: no region on screen, or the top line is not rendered.
        -- Fall back to counting, which is right everywhere the padding is not.
        target = rows_above(win, view.topline) + 1
    end
    target = math.max(1, math.min(target, vim.api.nvim_buf_line_count(session.explain_buf)))

    syncing = true
    pcall(vim.api.nvim_win_call, session.explain_win, function()
        local v = vim.fn.winsaveview()
        if v.topline ~= target then
            v.topline = target
            v.lnum = math.max(v.lnum, target)
            vim.fn.winrestview(v)
        end
    end)
    syncing = false
end

--- Re-lay-out the pane when something it was measured against has moved: the pane
--- was resized, so every block re-wraps to a different height, or a fold was opened
--- or closed, so the regions sit on different screen rows.
---
--- Never regenerates — it works from what is already in the store, so it costs no
--- model call. Called from the session's cursor and scroll autocmds and guarded by
--- the signature, so it is a no-op on almost every one of them.
function M.relayout_if_stale(session)
    if not M.is_open(session) then
        return
    end
    local entry = session.entries[session.index]
    local data = entry and (session.explain_store or {})[entry.path] or nil
    if not data then
        -- Still waiting on the run, or showing an error. Nothing laid out to redo.
        return
    end
    local sig = layout_signature(session)
    if sig == nil or sig == session.explain_sig then
        return
    end
    -- Stamped before the work, not after: laying out re-pads, which fires the scroll
    -- autocmd that called this, and the stamp is what stops that re-entering.
    session.explain_sig = sig

    render(
        session,
        ai.map_to_regions(data.explanations, session.explain_regions),
        vim.api.nvim_win_get_width(session.explain_win)
    )
    M.sync(session)
end

-- ---------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------

local function stop_timer(session)
    if session.explain_timer then
        pcall(function()
            session.explain_timer:stop()
            session.explain_timer:close()
        end)
        session.explain_timer = nil
    end
end

--- Stop the run. Called when the session closes, not when the reviewer pages: a
--- whole-PR run is doing work for every file, so paging away from the one that
--- started it is not a reason to throw the rest of it away.
local function stop_run(session)
    stop_timer(session)
    if session.explain_job then
        pcall(function()
            session.explain_job:kill(15)
        end)
        session.explain_job = nil
    end
end

M.stop_run = stop_run

local function render_progress(session, entry)
    local done, total = progress(session)
    local secs = session.explain_started and math.floor((vim.uv.now() - session.explain_started) / 1000) or 0
    local note = session.explain_job
        and string.format("%d of %d files · %ds", done, total, secs)
        or string.format("%d of %d files", done, total)
    render_status(
        session,
        "generating…",
        note
            .. "\n\nOne agent is explaining the whole change, so each file is written with the"
            .. " rest of it in view. Files appear here as it finishes them — this one is"
            .. " being done first."
    )
    set_winbar(session, entry, note)
end

--- Start the agent if there is work outstanding and nothing already running.
--- @param opts table|nil `only` regenerates just those paths
local function ensure_run(session, opts)
    opts = opts or {}
    local cfg = session.cfg.explain

    if session.explain_job then
        if not opts.only then
            -- A full run is already covering this file. Waiting is the whole point.
            return
        end
        -- A targeted regeneration displaces it. Everything already written stays on
        -- disk, and relaunching later resumes from there.
        stop_run(session)
    end

    local todo = opts.only or outstanding(session)
    if #todo == 0 then
        return
    end

    -- `session.pr` is nil while the gh lookup is in flight and false once it has
    -- answered that there is no PR. Worth a short wait for the difference: the
    -- description is the statement of intent the entire run is written against, and
    -- unlike the per-file design there is no second chance at it.
    if session.pr == nil and (session.explain_pr_waited or 0) < (cfg.pr_wait or 3000) then
        session.explain_pr_waited = (session.explain_pr_waited or 0) + 300
        vim.defer_fn(function()
            if M.is_open(session) then
                ensure_run(session, opts)
            end
        end, 300)
        return
    end

    local dir = store_dir(session)
    vim.fn.mkdir(dir, "p")
    local entry = session.entries[session.index]
    local done = {}
    if not opts.only then
        for path in pairs(session.explain_store or {}) do
            table.insert(done, path)
        end
    end

    -- Only the open file's diff is pasted in; the rest the agent fetches itself.
    local current_diff
    if entry then
        current_diff = git.file_diff(session.merge_base, entry, session.root) or ""
        local cap = cfg.max_diff_bytes or 60000
        if #current_diff > cap then
            current_diff = current_diff:sub(1, cap) .. "\n[diff truncated at " .. cap .. " bytes]\n"
        end
    end

    local prompt = ai.build_prompt({
        pr = session.pr,
        current_diff = current_diff,
        branch = session.branch,
        base_ref = session.base_ref,
        merge_base = session.merge_base,
        entries = all_entries(session),
        current = entry and entry.path or nil,
        out_dir = dir,
        done = done,
        guide_done = session.guide ~= nil,
        only = opts.only,
    })

    session.explain_started = vim.uv.now()
    session.explain_job = ai.run(prompt, { repo = session.root, out = dir }, cfg, function(ok, err)
        stop_timer(session)
        session.explain_job = nil
        if not M.is_open(session) then
            return
        end
        -- The results are files, so a failed run is not necessarily an empty one:
        -- whatever it wrote before dying is still there and still good.
        M.reload(session)
        if not ok then
            local left = #outstanding(session)
            if left > 0 then
                vim.notify(
                    string.format("lgtm: the explanation run ended early (%s), %d file(s) unexplained", err, left),
                    vim.log.levels.WARN
                )
            end
        end
    end)

    if session.explain_job then
        local timer = vim.uv.new_timer()
        session.explain_timer = timer
        timer:start(1000, 1000, vim.schedule_wrap(function()
            if not (M.is_open(session) and session.explain_job) then
                return
            end
            local e = session.entries[session.index]
            if e and not (session.explain_store or {})[e.path] then
                render_progress(session, e)
            end
        end))
    end
end

--- Re-read the store and show the current file if its explanation has arrived.
--- Called from the directory watcher, so this is what makes a single whole-PR run
--- appear one file at a time.
function M.reload(session)
    if not M.is_open(session) then
        return
    end
    local before = (session.explain_store or {})[(session.entries[session.index] or {}).path]
    session.explain_store = store.load(store_dir(session))
    -- The guide arrives through the same watcher as the explanations — it is the
    -- run's first write. Compared as JSON so a refinement at the end of the run
    -- also lands.
    local guide = store.load_guide(store_dir(session))
    if guide then
        local encoded = vim.json.encode(guide)
        if encoded ~= session.guide_json then
            session.guide, session.guide_json = guide, encoded
            if session.on_guide then
                session.on_guide()
            end
        end
    end
    local entry = session.entries[session.index]
    if not entry then
        return
    end
    local now = session.explain_store[entry.path]
    if now and not before then
        M.refresh(session)
    elseif not now and session.explain_job then
        render_progress(session, entry)
    end
end

--- Show the current file: from the store if it is there, otherwise a progress line
--- while the run gets to it.
--- @param opts table|nil `force` regenerates this one file
function M.refresh(session, opts)
    if not M.is_open(session) then
        return
    end
    opts = opts or {}
    local entry = session.entries[session.index]
    if not entry then
        return
    end

    -- No hunks means the pane below is not a diff: binary, deleted, too large.
    -- There is nothing to key an explanation to.
    if not session.hunks or #session.hunks == 0 then
        session.explain_regions = {}
        render_status(
            session,
            "no diff to explain",
            "This file is shown without a diff — binary, deleted, or over `max_file_size`."
        )
        set_winbar(session, entry, "")
        return
    end

    session.explain_regions = build_regions(
        session.hunks,
        diff_context(),
        vim.api.nvim_win_get_height(session.working_win)
    )
    session.explain_store = session.explain_store or store.load(store_dir(session))

    local data = not opts.force and session.explain_store[entry.path] or nil
    if data then
        local dir = store_dir(session)
        -- An explanation is of the file as it was when it was written. Edit the file
        -- in the working pane and it may no longer describe what is there.
        local sha = state.content_hash(vim.fs.joinpath(session.root, entry.path))
        local recorded = store.shas(dir)[entry.path]
        local stale = false
        if recorded == nil then
            store.record_sha(dir, entry.path, sha)
        elseif sha and recorded ~= sha then
            stale = true
        end

        render(
            session,
            ai.map_to_regions(data.explanations, session.explain_regions),
            vim.api.nvim_win_get_width(session.explain_win)
        )
        set_winbar(session, entry, stale and "stale — :LgtmExplain!" or "")
        M.sync(session)
        return
    end

    if opts.force then
        -- Make the arrival of the replacement observable to the watcher, and stop
        -- the old text being shown as though it were the new.
        pcall(vim.fn.delete, vim.fs.joinpath(store_dir(session), store.slug(entry.path)))
        session.explain_store[entry.path] = nil
        store.record_sha(store_dir(session), entry.path, nil)
    end

    render_progress(session, entry)
    ensure_run(session, opts.force and { only = { entry.path } } or nil)
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local function target_width(session)
    local cfg = session.cfg
    local want = cfg.explain.width or 76
    -- What is left once the three existing panes have had their minimum. The
    -- working pane is the one being edited, so it is the last thing to give up
    -- columns.
    local room = vim.o.columns - (cfg.tree_width or 60) - (cfg.base_width or 60) - 40
    return math.max(24, math.min(want, room)), room
end

function M.open(session)
    if M.is_open(session) then
        return true
    end
    if not (session.working_win and vim.api.nvim_win_is_valid(session.working_win)) then
        return false
    end

    local width, room = target_width(session)
    if room < 24 then
        vim.notify(
            "lgtm: not enough width for the explanation pane — narrow tree_width or base_width",
            vim.log.levels.WARN
        )
        return false
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, "lgtm://explain")
    vim.bo[buf].filetype = "lgtm-explain"

    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(session.working_win)
    vim.cmd("noautocmd rightbelow vsplit")
    local win = vim.api.nvim_get_current_win()

    -- A split inherits the window options of the window it came from, and the
    -- working pane is in diff mode. Left alone, the new window joins the diff
    -- group as a third participant and fills both real panes with filler lines.
    vim.wo[win].diff = false
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldcolumn = "0"
    vim.api.nvim_win_set_buf(win, buf)

    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].colorcolumn = ""
    vim.wo[win].cursorline = false
    vim.wo[win].winfixwidth = true
    -- No soft wrapping, and this one is load-bearing rather than cosmetic: the
    -- alignment holds because canvas line N is screen row N, and a line that wrapped
    -- would take two rows and put everything below it out by one. The prose is
    -- already hard-wrapped to the pane by markdown.format, so the only thing this
    -- clips is a token too long to break — an unspaced URL — which is worth one
    -- truncated line against every block being level with its region.
    vim.wo[win].wrap = false
    vim.api.nvim_win_set_width(win, width)

    vim.api.nvim_set_current_win(prev)

    -- Extmarks are buffer-scoped, so without this the padding would also show in
    -- any other window on the same file. Experimental API, hence the pcall: if it
    -- is not there the padding still works, it is just not confined to the panes.
    pcall(vim.api.nvim__ns_set, PAD_NS, { wins = { session.base_win, session.working_win } })

    session.explain_win = win
    session.explain_buf = buf

    -- Each Write the agent makes fires this, which is what turns one whole-PR run
    -- into results that arrive a file at a time.
    session.explain_watch = store.watch(store_dir(session), function()
        M.reload(session)
    end)
    return true
end

function M.close(session)
    stop_run(session)
    store.unwatch(session.explain_watch)
    session.explain_watch = nil
    clear_padding(session)
    if session.explain_win and vim.api.nvim_win_is_valid(session.explain_win) then
        pcall(vim.api.nvim_win_close, session.explain_win, true)
    end
    if session.explain_buf and vim.api.nvim_buf_is_valid(session.explain_buf) then
        pcall(vim.api.nvim_buf_delete, session.explain_buf, { force = true })
    end
    session.explain_win, session.explain_buf = nil, nil
    session.explain_blocks = nil
    session.explain_regions = nil
    session.explain_sig, session.explain_layout_width = nil, nil
end

return M
