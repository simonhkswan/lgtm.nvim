-- Laying out a PR description for a narrow pane.
--
-- A GitHub PR body is written for a browser roughly a thousand pixels wide, and
-- two things in it break badly in a side pane:
--
--   * Paragraphs are single unbroken lines, often several hundred characters.
--   * Reviewer-guide tables reach ~700 characters a row, most of it prose in the
--     last column. No column arithmetic rescues that; the table shape itself is
--     what does not fit.
--
-- So paragraphs are wrapped here rather than by 'wrap' (which cannot indent
-- continuations to match a bullet), and tables are reflowed into blocks: the
-- first column becomes a heading, short numeric columns a meta line, the prose
-- underneath. Nothing is dropped.
--
-- Inline markup is stripped and replaced with highlights. This is done by hand
-- rather than with treesitter's conceal because the text has to be measured
-- *after* the markers are gone: wrapping around `**` and backticks that are
-- about to become invisible gives ragged, short-looking lines.

local M = {}

--- Underscore emphasis only counts at a word boundary. Without this,
--- `IMAGE_INDEX_001` reads as IMAGE + italic INDEX + 001 and the identifier is
--- silently mangled into IMAGEINDEX001 — which is exactly the kind of name these
--- descriptions are full of. CommonMark draws the same line.
local function at_word_boundary(text, s, e)
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = text:sub(e + 1, e + 1)
    return not before:match("[%w_]") and not after:match("[%w_]")
end

--- Inline constructs, longest-first so ** is not read as two *.
local INLINE = {
    { pat = "^`([^`]+)`", kind = "code" },
    { pat = "^%*%*([^%*]+)%*%*", kind = "bold" },
    { pat = "^__([^_]+)__", kind = "bold", guard = at_word_boundary },
    { pat = "^%*([^%*]+)%*", kind = "italic" },
    { pat = "^_([^_]+)_", kind = "italic", guard = at_word_boundary },
    { pat = "^%[([^%]]+)%]%b()", kind = "link" },
}

local HL = {
    code = "LgtmMdCode",
    bold = "LgtmMdBold",
    italic = "LgtmMdItalic",
    link = "LgtmMdLink",
}

--- Remove inline markers, returning the bare text plus the byte ranges the
--- markers used to delimit, so they can be re-applied as highlights.
--- @return string plain, table spans  each { s, e, kind } 1-based, inclusive
local function strip_inline(text)
    local out, spans = {}, {}
    local i, len, plain_len = 1, #text, 0
    while i <= len do
        local matched = false
        for _, rule in ipairs(INLINE) do
            local s, e, inner = text:find(rule.pat, i)
            if s == i and (not rule.guard or rule.guard(text, s, e)) then
                -- Recurse: markup nests, and `**`code`**` is common in these
                -- bodies. Matching the outer pair and inserting its capture
                -- verbatim would leave the inner backticks in the text.
                -- `inner` is always shorter than `text`, so this terminates.
                local inner_plain, inner_spans = strip_inline(inner)
                local start = plain_len + 1
                table.insert(out, inner_plain)
                plain_len = plain_len + #inner_plain
                -- For a link the capture is the label; the URL is dropped, since
                -- it is unreachable from a preview buffer anyway and costs the
                -- width the label needs.
                table.insert(spans, { s = start, e = plain_len, kind = rule.kind })
                for _, sp in ipairs(inner_spans) do
                    table.insert(spans, { s = start + sp.s - 1, e = start + sp.e - 1, kind = sp.kind })
                end
                i = e + 1
                matched = true
                break
            end
        end
        if not matched then
            table.insert(out, text:sub(i, i))
            plain_len = plain_len + 1
            i = i + 1
        end
    end
    return table.concat(out), spans
end

M.strip_inline = strip_inline

--- Wrap `text` to `width`, carrying `spans` onto the produced lines.
--- Words wider than the line (URLs) overflow rather than being cut: a severed
--- URL is worse than a long line, and 'wrap' catches it visually.
--- @return table lines, table marks  each { line, col, end_col, hl } 0-based line
local function wrap_spans(text, spans, width, indent, first_indent)
    indent = indent or ""
    first_indent = first_indent or indent
    local room = math.max(8, width - #indent)

    -- Word positions in `text`, so spans can be mapped onto the output.
    local lines, ranges = {}, {}
    local line, line_start, line_end = nil, nil, nil
    local pos = 1
    while pos <= #text do
        local s, e = text:find("%S+", pos)
        if not s then
            break
        end
        local word = text:sub(s, e)
        if line == nil then
            line, line_start, line_end = word, s, e
        elseif vim.fn.strdisplaywidth(line .. " " .. word) <= room then
            line, line_end = line .. " " .. word, e
        else
            table.insert(lines, line)
            table.insert(ranges, { line_start, line_end })
            line, line_start, line_end = word, s, e
        end
        pos = e + 1
    end
    if line then
        table.insert(lines, line)
        table.insert(ranges, { line_start, line_end })
    end
    if #lines == 0 then
        return {}, {}
    end

    local marks = {}
    for idx, l in ipairs(lines) do
        local pad = (idx == 1) and first_indent or indent
        lines[idx] = pad .. l
        local rs, re = ranges[idx][1], ranges[idx][2]
        for _, sp in ipairs(spans or {}) do
            -- Only the part of the span falling on this line.
            local s = math.max(sp.s, rs)
            local e = math.min(sp.e, re)
            if s <= e then
                -- Offsets shift by the leading whitespace this line dropped and
                -- by the indent it gained.
                local col = #pad + (s - rs)
                table.insert(marks, {
                    line = idx - 1,
                    col = col,
                    end_col = col + (e - s + 1),
                    hl = HL[sp.kind],
                })
            end
        end
    end
    return lines, marks
end

--- Wrap without inline handling, for callers that only need line breaking.
function M.wrap(text, width, indent)
    local plain, spans = strip_inline(text)
    return (wrap_spans(plain, spans, width, indent))
end

--- Append `lines`/`marks` from a wrap onto the running output.
local function emit(out, marks, lines, line_marks)
    local base = #out
    for _, l in ipairs(lines) do
        table.insert(out, l)
    end
    for _, m in ipairs(line_marks) do
        table.insert(marks, { line = base + m.line, col = m.col, end_col = m.end_col, hl = m.hl })
    end
end

local function is_table_row(line)
    return line:match("^%s*|.*|%s*$") ~= nil
end

--- A table's delimiter row: |---|:--:|---:| and friends.
local function is_table_delim(line)
    return line:match("^%s*|[%s:%-|]+|%s*$") ~= nil and line:match("%-%-") ~= nil
end

local function split_row(line)
    local cells = {}
    -- Trim the outer pipes first so an empty leading/trailing cell is not
    -- invented by the split.
    local body = line:match("^%s*|(.*)|%s*$") or line
    for cell in (body .. "|"):gmatch("(.-)|") do
        table.insert(cells, vim.trim(cell))
    end
    return cells
end

--- Reflow one table into blocks. `headers` names the columns so the meta line
--- can label the numbers it prints.
local function render_table(headers, rows, width, out, marks)
    for _, cells in ipairs(rows) do
        if #cells > 0 then
            local title = cells[1] ~= "" and cells[1] or (headers[1] or "")
            local plain, spans = strip_inline(title)
            local l, m = wrap_spans(plain, spans, width, "  ")
            -- The row's own heading, so it reads as a block title rather than as
            -- the first line of the prose beneath it.
            for _, mk in ipairs(m) do
                mk.hl = mk.hl or "LgtmMdH3"
            end
            emit(out, marks, l, m)
            for i = 1, #l do
                table.insert(marks, { line = #out - #l + i - 1, col = 0, end_col = #l[i], hl = "LgtmMdH3" })
            end

            -- Middle columns are short — counts, LOC — so they read better on
            -- one line together than as separate rows.
            local meta = {}
            for i = 2, #cells - 1 do
                local v = cells[i]
                if v ~= "" then
                    local label = headers[i] or ""
                    -- "Num files" -> "4 files"; a bare number is meaningless
                    -- alone, but the full header is too wide to repeat.
                    if v:match("^%d+$") and label:lower():match("file") then
                        v = v .. " files"
                    end
                    table.insert(meta, v)
                end
            end
            if #meta > 0 then
                table.insert(out, "    " .. table.concat(meta, "  ·  "))
                table.insert(marks, { line = #out - 1, col = 0, end_col = #out[#out], hl = "LgtmMdMeta" })
            end

            local prose = cells[#cells]
            if #cells > 1 and prose ~= "" then
                local p, ps = strip_inline(prose)
                emit(out, marks, wrap_spans(p, ps, width, "      "))
            end
            table.insert(out, "")
        end
    end
end

--- Format a PR body for a pane `width` columns wide.
--- @return table lines, table marks  each { line, hl } or { line, col, end_col, hl }
function M.format(body, width)
    width = math.max(30, (width or 80) - 2)
    local src = vim.split(body or "", "\n", { plain = true })
    local out, marks = {}, {}

    local i = 1
    local in_code = false
    while i <= #src do
        local line = (src[i]:gsub("\r", ""))

        -- Fenced code passes through untouched: wrapping or stripping markers
        -- inside it would corrupt the code.
        if line:match("^%s*```") then
            in_code = not in_code
            -- The fence itself is dropped; the block is shown by its background,
            -- so the delimiters would only be two rows of punctuation.
            i = i + 1
        elseif in_code then
            table.insert(out, line)
            -- eol carries the highlight to the right edge of the window. Without
            -- it the block is only as wide as each line's text, so it renders as
            -- ragged word-shaped patches and blank lines vanish entirely.
            table.insert(marks, { line = #out - 1, hl = "LgtmMdBlock", eol = true })
            i = i + 1

        -- Template scaffolding renders as noise; content between markers is kept.
        elseif line:match("^%s*<!%-%-.*%-%->%s*$") then
            i = i + 1

        -- Blockquotes, including GitHub's alert callouts (> [!NOTE]). The whole
        -- run is consumed together: each source line is one long paragraph, so
        -- wrapping them independently would break the quote into ragged pieces.
        elseif line:match("^%s*>") then
            local para, label = {}, nil
            while i <= #src and src[i]:match("^%s*>") do
                local content = src[i]:gsub("^%s*>%s?", "")
                local alert = content:match("^%[!(%u+)%]%s*$")
                if alert then
                    label = alert
                elseif vim.trim(content) == "" then
                    table.insert(para, "")
                else
                    table.insert(para, content)
                end
                i = i + 1
            end
            if #out > 0 and out[#out] ~= "" then
                table.insert(out, "")
            end
            if label then
                table.insert(out, "▏ " .. label)
                table.insert(marks, { line = #out - 1, col = 0, end_col = #out[#out], hl = "LgtmMdAlert" })
            end
            for _, p in ipairs(para) do
                if p == "" then
                    table.insert(out, "▏")
                    table.insert(marks, { line = #out - 1, col = 0, end_col = #out[#out], hl = "LgtmMdQuote" })
                else
                    local plain, spans = strip_inline(p)
                    local l, m = wrap_spans(plain, spans, width - 2, "▏ ")
                    emit(out, marks, l, m)
                    -- The gutter bar, marked after the text so the inline spans
                    -- above sit on top of it rather than under it.
                    for k = #out - #l + 1, #out do
                        table.insert(marks, { line = k - 1, col = 0, end_col = #("▏"), hl = "LgtmMdQuote" })
                    end
                end
            end
            table.insert(out, "")

        -- A table: consume the whole run, then reflow it.
        elseif is_table_row(line) and src[i + 1] and is_table_delim(src[i + 1]) then
            local headers = split_row(line)
            local rows = {}
            i = i + 2
            while i <= #src and is_table_row(src[i]) do
                table.insert(rows, split_row(src[i]))
                i = i + 1
            end
            render_table(headers, rows, width, out, marks)
        else
            local hashes, text = line:match("^(#+)%s+(.*)$")
            if hashes then
                if #out > 0 and out[#out] ~= "" then
                    table.insert(out, "")
                end
                local plain = strip_inline(text)
                local level = #hashes
                local hl = level <= 2 and "LgtmMdH1" or (level == 3 and "LgtmMdH2" or "LgtmMdH3")
                table.insert(out, plain)
                table.insert(marks, { line = #out - 1, col = 0, end_col = #plain, hl = hl })
                -- A rule under the top-level headings gives the eye somewhere to
                -- rest in a long description.
                if level <= 2 then
                    table.insert(out, string.rep("─", math.min(width, vim.fn.strdisplaywidth(plain) + 2)))
                    table.insert(marks, { line = #out - 1, col = 0, end_col = #out[#out], hl = "LgtmMdRule" })
                end
                i = i + 1
            else
                local bullet, rest = line:match("^(%s*)[%-%*%+]%s+(.*)$")
                if bullet then
                    local plain, spans = strip_inline(rest)
                    -- Continuations line up under the text, not the marker, so a
                    -- wrapped bullet still reads as one item.
                    local l, m = wrap_spans(plain, spans, width, bullet .. "  ", bullet .. "• ")
                    emit(out, marks, l, m)
                    i = i + 1
                elseif vim.trim(line) == "" then
                    -- Collapse runs of blank lines; templates leave a lot behind.
                    if #out > 0 and out[#out] ~= "" then
                        table.insert(out, "")
                    end
                    i = i + 1
                else
                    local plain, spans = strip_inline(line)
                    local lead = line:match("^%s*")
                    emit(out, marks, wrap_spans(vim.trim(plain), spans, width, lead))
                    i = i + 1
                end
            end
        end
    end

    return out, marks
end

--- Write formatted lines and their highlights into a buffer.
function M.apply(buf, lines, marks)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    local ns = vim.api.nvim_create_namespace("lgtm_md")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks or {}) do
        local text = lines[m.line + 1] or ""
        if m.eol and m.hl then
            -- line_hl_group, not hl_eol: hl_eol only applies to a highlight that
            -- spans more than one line, so on a single-line span it is silently
            -- ignored and a fenced block stays text-shaped. This fills the row to
            -- the window edge, blank lines included.
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line, 0, { line_hl_group = m.hl })
        else
            local col = math.min(m.col or 0, #text)
            local end_col = math.min(m.end_col or #text, #text)
            if m.hl and end_col > col then
                pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line, col, {
                    end_row = m.line,
                    end_col = end_col,
                    hl_group = m.hl,
                })
            end
        end
    end
end

--- Lay out a pull request: heading, metadata, then the formatted body.
--- @param pr table|false|nil  false means "no PR", nil means "still loading"
--- @return table lines, table marks
function M.render_pr(pr, branch, width, note)
    if pr == nil then
        return { "", "  loading…" }, {}
    end
    local lines, marks = {}, {}
    if not pr then
        vim.list_extend(lines, { "", "  No open pull request for this branch.", "", "  " .. branch })
        if note then
            table.insert(lines, "  " .. note)
        end
        return lines, marks
    end

    for _, l in ipairs(M.wrap(string.format("#%d  %s", pr.number or 0, pr.title or ""), width - 2)) do
        table.insert(lines, l)
        table.insert(marks, { line = #lines - 1, hl = "LgtmMdH1" })
    end
    local meta = string.format(
        "%s%s  ·  %s → %s  ·  +%d −%d across %d files",
        pr.isDraft and "draft " or "",
        (pr.state or ""):lower(),
        branch,
        pr.baseRefName or "?",
        pr.additions or 0,
        pr.deletions or 0,
        pr.changedFiles or 0
    )
    for _, l in ipairs(M.wrap(meta, width - 2)) do
        table.insert(lines, l)
        table.insert(marks, { line = #lines - 1, hl = "LgtmMdMeta" })
    end
    if pr.author and pr.author.login then
        table.insert(lines, "by " .. pr.author.login .. "   " .. (pr.url or ""))
        table.insert(marks, { line = #lines - 1, hl = "LgtmMdMeta" })
    end
    table.insert(lines, "")

    local body_lines, body_marks = M.format(pr.body, width)
    local offset = #lines
    vim.list_extend(lines, body_lines)
    for _, m in ipairs(body_marks) do
        -- Carry col/end_col/eol across. Dropping them turns every inline span
        -- into a whole-line mark, painting entire paragraphs in the code colour.
        table.insert(marks, { line = m.line + offset, col = m.col, end_col = m.end_col, hl = m.hl, eol = m.eol })
    end
    return lines, marks
end

--- Lay out one stream of the reviewer guide: its one-line title, its stats, then
--- its summary — the same shape render_pr gives the PR itself, so switching
--- streams reads as the pane changing subject rather than changing form.
--- @param feature table { title, summary }
--- @param stats table|nil { files, added, deleted, viewed }
--- @return table lines, table marks
function M.render_feature(feature, stats, width)
    local lines, marks = {}, {}
    for _, l in ipairs(M.wrap(feature.title or "", width - 2)) do
        table.insert(lines, l)
        table.insert(marks, { line = #lines - 1, hl = "LgtmMdH1" })
    end
    if stats then
        local meta = string.format(
            "%d files  ·  +%d −%d  ·  %d/%d viewed",
            stats.files or 0,
            stats.added or 0,
            stats.deleted or 0,
            stats.viewed or 0,
            stats.files or 0
        )
        for _, l in ipairs(M.wrap(meta, width - 2)) do
            table.insert(lines, l)
            table.insert(marks, { line = #lines - 1, hl = "LgtmMdMeta" })
        end
    end
    table.insert(lines, "")

    local body_lines, body_marks = M.format(feature.summary or "", width)
    local offset = #lines
    vim.list_extend(lines, body_lines)
    for _, m in ipairs(body_marks) do
        table.insert(marks, { line = m.line + offset, col = m.col, end_col = m.end_col, hl = m.hl, eol = m.eol })
    end
    return lines, marks
end

--- @param diff_colors table|nil shares lgtm's palette maths, so the code chip
---        is positioned against the real background rather than guessed
function M.setup_highlights(diff_colors)
    local colors = require("lgtm.colors")
    local opts = type(diff_colors) == "table" and diff_colors or {}
    local code = (opts.code or {})

    vim.api.nvim_set_hl(0, "LgtmMdH1", { link = "Title" })
    vim.api.nvim_set_hl(0, "LgtmMdH2", { link = "Function" })
    vim.api.nvim_set_hl(0, "LgtmMdH3", { link = "Identifier" })
    vim.api.nvim_set_hl(0, "LgtmMdRule", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmMdMeta", { link = "Comment" })
    -- Inline code gets a chip plus a tinted foreground: the chip marks the span
    -- without a fifth hue shouting across 75 of them, and the tint keeps it
    -- legible as code rather than as a grey smudge. Both are derived — the chip
    -- from the background's own hue, so it tracks the colourscheme.
    local bg_hue = colors.background_hsl(opts)
    local chip = colors.shade(code.hue or bg_hue, code.sat or 0.28, code.l or 0.075, opts)
    vim.api.nvim_set_hl(0, "LgtmMdCode", {
        bg = chip,
        fg = code.fg or colors.shade(code.fg_hue or 193, code.fg_sat or 0.42, code.fg_l or 0.50, opts),
    })
    -- Fenced blocks share the chip so the two read as one idea, but carry no
    -- foreground of their own: the block is often plain output, not code.
    vim.api.nvim_set_hl(0, "LgtmMdBlock", { bg = chip })
    vim.api.nvim_set_hl(0, "LgtmMdBold", { bold = true })
    vim.api.nvim_set_hl(0, "LgtmMdItalic", { italic = true })
    vim.api.nvim_set_hl(0, "LgtmMdLink", { link = "Underlined" })
    vim.api.nvim_set_hl(0, "LgtmMdQuote", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmMdAlert", { link = "WarningMsg" })
end

return M
