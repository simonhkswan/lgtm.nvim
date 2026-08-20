-- The change ruler: a one-column strip down the right edge of the working pane
-- showing where every hunk sits in the file as a whole, plus a marker for the
-- part you are currently looking at.
--
-- Scrolling tells you what is under the cursor but never how much of the file is
-- involved or how the changes are distributed — whether this is one rewritten
-- function or forty scattered one-line edits. The ruler answers that at a glance
-- and does not move as you scroll, so it doubles as a position indicator.
--
-- It is a non-focusable float overlaying the pane's last column, the same
-- approach scrollbar plugins take. Being a float, it belongs to the tabpage and
-- shows up in nvim_tabpage_list_wins, so anything iterating the session's
-- windows has to skip it.

local colors = require("lgtm.colors")

local M = {}

local NS = vim.api.nvim_create_namespace("lgtm_ruler")

local CHARS = {
    change = "▐",
    empty = "▕",
}

function M.setup_highlights(diff_colors)
    local opts = type(diff_colors) == "table" and diff_colors or {}
    vim.api.nvim_set_hl(0, "LgtmRulerAdd", { fg = colors.accent("add", opts) })
    vim.api.nvim_set_hl(0, "LgtmRulerDel", { fg = colors.accent("delete", opts) })
    -- The unchanged majority of the file: present enough to give the bar a
    -- length, faint enough not to read as content.
    vim.api.nvim_set_hl(0, "LgtmRulerEmpty", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmRulerView", { link = "CursorLine" })
end

--- Which rows of a `height`-row strip each hunk falls in, in working-pane lines.
local function rows_for_hunks(hunks, total, height)
    local rows = {}
    if not hunks or total < 1 then
        return rows
    end
    local function row_of(line)
        return math.min(height, math.max(1, math.ceil(line / total * height)))
    end
    for _, h in ipairs(hunks) do
        local start_b, count_b, count_a = h[3], h[4], h[2]
        -- A hunk with no lines on this side is a pure deletion: it has no extent
        -- in the working file, only a position, so mark the single row it sits
        -- against rather than nothing at all.
        local first = row_of(start_b)
        local last = count_b > 0 and row_of(start_b + count_b - 1) or first
        local kind = count_b > 0 and "add" or "del"
        for r = first, last do
            -- A row already carrying additions keeps them: on a compressed bar a
            -- modification is more usefully shown as present than as removed.
            if rows[r] ~= "add" then
                rows[r] = kind
            end
        end
        if count_b > 0 and count_a > 0 then
            rows[first] = "add"
        end
    end
    return rows
end

function M.close(session)
    if session.ruler_win and vim.api.nvim_win_is_valid(session.ruler_win) then
        pcall(vim.api.nvim_win_close, session.ruler_win, true)
    end
    session.ruler_win = nil
    session.ruler_buf = nil
end

--- Draw (or redraw) the ruler for the session's current file.
function M.update(session)
    if not session.cfg.ruler then
        return
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end

    local height = vim.api.nvim_win_get_height(win)
    local width = vim.api.nvim_win_get_width(win)
    if height < 3 or width < 10 then
        M.close(session)
        return
    end

    if not (session.ruler_buf and vim.api.nvim_buf_is_valid(session.ruler_buf)) then
        session.ruler_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[session.ruler_buf].buftype = "nofile"
        vim.bo[session.ruler_buf].bufhidden = "hide"
    end

    local config = {
        relative = "win",
        win = win,
        anchor = "NE",
        row = 0,
        col = width,
        width = 1,
        height = height,
        focusable = false,
        style = "minimal",
        zindex = 40,
        noautocmd = true,
    }
    if session.ruler_win and vim.api.nvim_win_is_valid(session.ruler_win) then
        pcall(vim.api.nvim_win_set_config, session.ruler_win, config)
    else
        local ok, w = pcall(vim.api.nvim_open_win, session.ruler_buf, false, config)
        if not ok then
            return
        end
        session.ruler_win = w
        vim.wo[w].winhighlight = "Normal:LgtmRulerEmpty"
    end

    local buf = vim.api.nvim_win_get_buf(session.working_win)
    local total = math.max(1, vim.api.nvim_buf_line_count(buf))
    local rows = rows_for_hunks(session.hunks, total, height)

    -- Which rows the viewport covers, so the strip also says where you are.
    local top = vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
    end)
    local bot = vim.api.nvim_win_call(win, function()
        return vim.fn.line("w$")
    end)
    local view_first = math.min(height, math.max(1, math.ceil(top / total * height)))
    local view_last = math.min(height, math.max(view_first, math.ceil(bot / total * height)))

    local lines = {}
    for i = 1, height do
        lines[i] = rows[i] and CHARS.change or CHARS.empty
    end
    vim.api.nvim_buf_set_lines(session.ruler_buf, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(session.ruler_buf, NS, 0, -1)
    for i = 1, height do
        local hl = rows[i] == "add" and "LgtmRulerAdd" or (rows[i] == "del" and "LgtmRulerDel" or "LgtmRulerEmpty")
        vim.api.nvim_buf_set_extmark(session.ruler_buf, NS, i - 1, 0, {
            end_col = #lines[i],
            hl_group = hl,
            line_hl_group = (i >= view_first and i <= view_last) and "LgtmRulerView" or nil,
        })
    end
end

return M
