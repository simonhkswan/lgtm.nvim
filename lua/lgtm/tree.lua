-- The changed-files panel.
--
-- Paths in a real PR run deep (ten levels is not unusual), so a naive tree
-- indents straight off the side of a 35-column window. Directory chains with a
-- single child are therefore collapsed into one row — "a/b/c" rather than three
-- nested rows — which is what GitHub's file tree does and what keeps this
-- readable.

local M = {}

local NS = vim.api.nvim_create_namespace("lgtm_tree")

local ICONS = {
    viewed = "✓",
    current = "●",
    unviewed = " ",
    open = "▾",
    closed = "▸",
}

--- Assemble a nested directory structure from a flat list of file entries.
local function build(entries)
    local root = { name = "", dirs = {}, dir_order = {}, files = {} }
    for _, e in ipairs(entries) do
        local parts = vim.split(e.path, "/", { plain = true })
        local node = root
        for i = 1, #parts - 1 do
            local part = parts[i]
            if not node.dirs[part] then
                node.dirs[part] = { name = part, dirs = {}, dir_order = {}, files = {} }
                table.insert(node.dir_order, part)
            end
            node = node.dirs[part]
        end
        table.insert(node.files, e)
    end
    return root
end

--- Fold "a" -> "b" -> "c" into a single node named "a/b/c" whenever each step
--- has exactly one child directory and no files of its own.
local function collapse(node)
    for _, name in ipairs(node.dir_order) do
        local child = node.dirs[name]
        collapse(child)
        local merged = name
        while #child.dir_order == 1 and #child.files == 0 do
            local only = child.dirs[child.dir_order[1]]
            merged = merged .. "/" .. only.name
            child = only
        end
        if merged ~= name then
            node.dirs[name] = nil
            node.dirs[merged] = child
            child.name = merged
            for i, n in ipairs(node.dir_order) do
                if n == name then
                    node.dir_order[i] = merged
                    break
                end
            end
        end
    end
end

--- Directories before files, then alphabetically — matching the sort you already
--- use in nvim-tree.
local function sort_node(node)
    table.sort(node.dir_order)
    table.sort(node.files, function(a, b)
        return a.path < b.path
    end)
    for _, name in ipairs(node.dir_order) do
        sort_node(node.dirs[name])
    end
end

local function devicon(path)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok then
        return nil, nil
    end
    local name = path:match("[^/]+$") or path
    local icon, hl = devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
    return icon, hl
end

--- The flat file order the rendered tree shows: directories before files at
--- every level, alphabetical within each. `git diff` hands entries over in
--- lexical path order, which interleaves root files between directories — so
--- next/prev navigation stepping through that list jumps around the tree.
--- Sorting the session's entries with this makes stepping follow the eye.
function M.display_order(entries)
    local root = build(entries)
    collapse(root)
    sort_node(root)
    local out = {}
    local function walk(node)
        for _, name in ipairs(node.dir_order) do
            walk(node.dirs[name])
        end
        for _, e in ipairs(node.files) do
            table.insert(out, e)
        end
    end
    walk(root)
    return out
end

--- Render the chapter picker into its own buffer: "All files", then one block per
--- chapter of the reviewer guide, each priced with the change it actually covers.
--- @param opts table { chapters, selected, width } — `chapters` rows are
---        { title, files, added, deleted, viewed }; `selected` is nil while every
---        file is shown.
--- @return table line -> { kind = "chapter", index } map (index 0 is All files)
function M.render_chapters(buf, opts)
    local width = opts.width or 40
    local lines, marks, line_map = {}, {}, {}

    local function chapter_row(idx, title, stats, selected)
        local marker = selected and ICONS.current or ICONS.unviewed
        local head = string.format(" %s ", marker)
        local room = width - vim.fn.strdisplaywidth(head) - 1
        if room >= 8 and vim.fn.strdisplaywidth(title) > room then
            title = title:sub(1, math.max(1, room - 1)) .. "…"
        end
        local text = head .. title
        table.insert(lines, text)
        local row = #lines - 1
        line_map[#lines] = { kind = "chapter", index = idx }
        table.insert(marks, {
            line = row,
            col = 1,
            end_col = 1 + #marker,
            hl = selected and "LgtmCurrent" or "Comment",
        })
        table.insert(marks, {
            line = row,
            col = #head,
            end_col = #text,
            hl = selected and "LgtmCurrentName" or "Normal",
        })
        if selected then
            table.insert(marks, { line = row, line_hl = "LgtmCurrentLine" })
        end
        if stats then
            local text2 = "     " .. stats
            table.insert(lines, text2)
            line_map[#lines] = { kind = "chapter", index = idx }
            table.insert(marks, { line = #lines - 1, col = 0, end_col = #text2, hl = "Comment" })
        end
    end

    chapter_row(0, "All files", nil, opts.selected == nil)
    for i, f in ipairs(opts.chapters or {}) do
        chapter_row(
            i,
            f.title,
            string.format("%d/%d viewed  ·  +%d −%d", f.viewed, f.files, f.added, f.deleted),
            opts.selected == i
        )
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, m in ipairs(marks) do
        if m.line_hl then
            vim.api.nvim_buf_set_extmark(buf, NS, m.line, 0, { line_hl_group = m.line_hl })
        else
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.line, m.col, {
                end_col = m.end_col,
                hl_group = m.hl,
            })
        end
    end

    return line_map
end

--- Render the tree into `buf`, returning the line -> entry map used for
--- navigation and cursor tracking.
--- @param opts table { entries, store, current_path, folded, header }
function M.render(buf, opts)
    local entries, store = opts.entries, opts.store
    local folded = opts.folded or {}

    local root = build(entries)
    collapse(root)
    sort_node(root)

    local lines, marks, line_map = {}, {}, {}

    local total_added, total_deleted = 0, 0
    for _, e in ipairs(entries) do
        total_added = total_added + e.added
        total_deleted = total_deleted + e.deleted
    end

    -- Width of the widest "+N" and "-M" in the whole list, so both sit in fixed
    -- columns. Right-aligning the pair as one blob instead leaves the plus signs
    -- ragged, which is exactly what makes a long list hard to scan.
    local wa, wd = 2, 2
    for _, e in ipairs(entries) do
        wa = math.max(wa, #("+" .. e.added))
        wd = math.max(wd, #("-" .. e.deleted))
    end

    -- Within what is on show, not store-wide: with a chapter selected the header
    -- reads as that chapter's own progress.
    local viewed = 0
    for _, e in ipairs(entries) do
        if store and store:is_viewed(e.path) then
            viewed = viewed + 1
        end
    end
    table.insert(lines, string.format(" %d files  +%d  -%d", #entries, total_added, total_deleted))
    table.insert(marks, { line = 0, col = 0, end_col = #lines[1], hl = "Title" })
    table.insert(lines, string.format(" %d/%d viewed  ·  %s", viewed, #entries, opts.header or ""))
    table.insert(marks, { line = 1, col = 0, end_col = #lines[2], hl = "Comment" })
    table.insert(lines, "")


    --- Break a collapsed chain like "a/b/c/d" into lines that fit, splitting on
    --- the separators. Eliding to "…/c/d" throws away the outer directories,
    --- which are exactly what tells two similarly-named leaves apart; wrapping
    --- keeps the whole path and costs only rows, which the panel has to spare.
    local function wrap_path(name, first_room, cont_room)
        local segments = {}
        for seg in name:gmatch("[^/]+") do
            table.insert(segments, seg)
        end

        local rows, current, room = {}, nil, first_room
        for i, seg in ipairs(segments) do
            local piece = (i < #segments) and (seg .. "/") or seg
            if current == nil then
                -- A single segment too long for an empty row can only be cut.
                if vim.fn.strdisplaywidth(piece) > room and room >= 4 then
                    piece = piece:sub(1, room - 1) .. "…"
                end
                current = piece
            elseif vim.fn.strdisplaywidth(current .. piece) <= room then
                current = current .. piece
            else
                table.insert(rows, current)
                current, room = piece, cont_room
            end
        end
        table.insert(rows, current or name)
        return rows
    end

    local function emit_dir(node, depth, path_prefix)
        -- One column per level, not two: at five levels deep the second column
        -- is pure cost, and it comes straight out of the filename's budget.
        local indent = string.rep(" ", depth)
        local full = path_prefix == "" and node.name or (path_prefix .. "/" .. node.name)
        local is_folded = folded[full]

        local width = opts.width or 40
        local head = indent .. (is_folded and ICONS.closed or ICONS.open) .. " "
        -- Continuation rows line up under the name, not under the marker, so a
        -- wrapped path reads as one thing rather than as a nested directory.
        local cont = indent .. "  "
        local rows = wrap_path(node.name, width - #indent - 2, math.max(4, width - #indent - 2))

        for i, row in ipairs(rows) do
            local text = (i == 1 and head or cont) .. row
            table.insert(lines, text)
            table.insert(marks, { line = #lines - 1, col = 0, end_col = #text, hl = "Directory" })
            -- Every row of a wrapped path addresses the same directory, so
            -- folding works with the cursor on any of them.
            line_map[#lines] = { kind = "dir", path = full }
        end

        return not is_folded, full
    end

    local function emit_file(e, depth)
        -- One column per level, not two: at five levels deep the second column
        -- is pure cost, and it comes straight out of the filename's budget.
        local indent = string.rep(" ", depth)
        local is_viewed = store and store:is_viewed(e.path) or false
        local is_current = e.path == opts.current_path

        local marker = is_current and ICONS.current or (is_viewed and ICONS.viewed or ICONS.unviewed)
        local icon, icon_hl = devicon(e.path)
        local name = e.path:match("[^/]+$") or e.path
        if e.status == "R" and e.old_path then
            name = name .. " ← " .. (e.old_path:match("[^/]+$") or e.old_path)
        end

        local prefix = string.format("%s%s %s ", indent, marker, icon or "")

        -- No + and - signs: LgtmCountAdd and LgtmCountDel already colour
        -- these cyan and red, so the signs only restate the colour and cost two
        -- columns on every row.
        local add_field, del_field
        if e.no_counts then
            add_field, del_field = string.rep(" ", wa - 1) .. "—", string.rep(" ", wd - 1) .. "—"
        else
            local a, d = tostring(e.added), tostring(e.deleted)
            add_field = string.rep(" ", wa - #a) .. a
            del_field = string.rep(" ", wd - #d) .. d
        end

        -- No status tag: the counts already carry it. An added file is N and 0,
        -- a deleted one 0 and N, a generated one a pair of dashes. The winbar
        -- names the status outright when the file is open, which is where it
        -- matters.
        local counts = "  " .. add_field .. " " .. del_field

        -- Deep nesting plus long filenames overruns a narrow panel, and the
        -- overrun falls on the right — exactly where the counts live. Keep the
        -- counts pinned to the right edge and shorten the name instead, eliding
        -- the middle so both the leading words and the extension survive.
        local width = opts.width or 40
        local room = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(counts) - 1
        if room >= 8 and vim.fn.strdisplaywidth(name) > room then
            -- Keep the extension and spend everything else on the head. Sibling
            -- files in a codebase share their tails far more often than their
            -- heads ("editable_project_document.py" vs "editable_patent_…"), so
            -- a balanced elision would render them indistinguishable.
            local ext = name:match("(%.[%w_]+)$") or ""
            if #ext > 7 then
                ext = ""
            end
            name = name:sub(1, math.max(1, room - #ext - 1)) .. "…" .. ext
        end

        local pad = math.max(0, width - vim.fn.strdisplaywidth(prefix .. name .. counts))
        local text = prefix .. name .. string.rep(" ", pad) .. counts
        table.insert(lines, text)
        local idx = #lines - 1
        line_map[#lines] = { kind = "file", entry = e }

        local col = #indent
        -- Marker
        table.insert(marks, {
            line = idx,
            col = col,
            end_col = col + #marker,
            hl = is_current and "LgtmCurrent" or (is_viewed and "LgtmViewed" or "Comment"),
        })
        if icon and icon_hl then
            local icol = col + #marker + 1
            table.insert(marks, { line = idx, col = icol, end_col = icol + #icon, hl = icon_hl })
        end
        -- Name: dimmed once viewed, bold while current.
        local ncol = #prefix
        table.insert(marks, {
            line = idx,
            col = ncol,
            end_col = ncol + #name,
            hl = is_current and "LgtmCurrentName" or (is_viewed and "LgtmViewed" or "Normal"),
        })

        -- Counts, coloured independently. These use foreground-only groups:
        -- DiffAdd/DiffDelete carry backgrounds in most colourschemes and would
        -- render here as solid blocks rather than as coloured numbers.
        local ccol = ncol + #name + pad
        local acol = ccol + 2
        local dcol = acol + #add_field + 1
        if e.no_counts then
            table.insert(marks, { line = idx, col = acol, end_col = dcol + #del_field, hl = "Comment" })
        else
            table.insert(marks, { line = idx, col = acol, end_col = acol + #add_field, hl = "LgtmCountAdd" })
            table.insert(marks, { line = idx, col = dcol, end_col = dcol + #del_field, hl = "LgtmCountDel" })
        end

        if is_current then
            table.insert(marks, { line = idx, line_hl = "LgtmCurrentLine" })
        end
    end

    local function walk(node, depth, path_prefix)
        for _, name in ipairs(node.dir_order) do
            local child = node.dirs[name]
            local expand, full = emit_dir(child, depth, path_prefix)
            if expand then
                walk(child, depth + 1, full)
            end
        end
        for _, e in ipairs(node.files) do
            emit_file(e, depth)
        end
    end

    walk(root, 0, "")

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for _, m in ipairs(marks) do
        if m.line_hl then
            vim.api.nvim_buf_set_extmark(buf, NS, m.line, 0, { line_hl_group = m.line_hl })
        else
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.line, m.col, {
                end_col = m.end_col,
                hl_group = m.hl,
            })
        end
    end

    return line_map
end

--- Highlight groups, linked to whatever the colourscheme already defines so this
--- looks native under nord without hard-coding colours.
--- @param diff_colors table|nil the configured diff_colors, so the tree's counts
---        use the same hues as the panes rather than drifting from them
function M.setup_highlights(diff_colors)
    local colors = require("lgtm.colors")
    local opts = type(diff_colors) == "table" and diff_colors or {}

    -- The current row is a band plus a bold name, not two stacked highlights.
    -- Linking the name to Search and the row to CursorLine put Search's
    -- foreground (#3B4252 under nord) on top of CursorLine's background (also
    -- #3B4252), so the filename was drawn in exactly the colour behind it and
    -- disappeared. Search is a "matched text" group and never belonged here.
    vim.api.nvim_set_hl(0, "LgtmCurrentLine", { link = "CursorLine" })
    vim.api.nvim_set_hl(0, "LgtmCurrentName", { bold = true })
    vim.api.nvim_set_hl(0, "LgtmCurrent", { fg = colors.accent("add", opts), bold = true })
    vim.api.nvim_set_hl(0, "LgtmViewed", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LgtmCountAdd", { fg = colors.accent("add", opts) })
    vim.api.nvim_set_hl(0, "LgtmCountDel", { fg = colors.accent("delete", opts) })
end

return M
