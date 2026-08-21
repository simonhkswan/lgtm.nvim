-- Telescope picker: choose a branch, see its PR and its changed files, open it.
--
-- Telescope's stock layouts give you one preview window. This uses its
-- `create_layout` hook to build the windows directly, so the right-hand side can
-- be split: the PR description above, the changed-file tree below. Telescope
-- still drives `preview` through its previewer; the tree window is ours and is
-- filled from the same callback.
--
-- Both halves need data that is slow to get — `gh pr view` is a network call and
-- the file list means a merge-base plus two diffs — so everything is cached per
-- branch and fetched asynchronously, with the panes drawing a placeholder first.

local git = require("lgtm.git")
local markdown = require("lgtm.markdown")
local state = require("lgtm.state")
local tree = require("lgtm.tree")

local M = {}

-- One string for every pane, and re-asserted wherever Telescope overwrites it:
-- interiors on the editor's Normal, borders and titles on groups derived from
-- FloatBorder/FloatTitle with the background dropped (see make_layout).
M.WINHL = "Normal:Normal,FloatBorder:LgtmPickerBorder,FloatTitle:LgtmPickerTitle"

local function notify(msg, level)
    vim.notify("lgtm: " .. msg, level or vim.log.levels.INFO)
end

--- Per-branch caches, keyed by branch name. Cleared when the picker closes so a
--- second run sees fresh data.
local cache = { pr = {}, files = {} }

local function set_lines(buf, lines)
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
    end
end

--- Fetch the PR for a branch, memoised. Arrowing through 23 branches would
--- otherwise fire a network call per keystroke.
local function fetch_pr(branch, cwd, cb)
    if cache.pr[branch] ~= nil then
        cb(cache.pr[branch])
        return
    end
    git.pr_view(branch, cwd, function(pr)
        cache.pr[branch] = pr
        cb(pr)
    end)
end

--- Changed files for a branch, computed against its own merge base with the
--- PR's target. Cached: this is two git diffs and a merge-base per branch.
local function branch_files(branch, cwd, base_ref)
    if cache.files[branch] then
        return cache.files[branch]
    end
    local base = base_ref or "origin/HEAD"
    local merge_base = git.merge_base(base, cwd, branch)
    if not merge_base then
        cache.files[branch] = { entries = {}, base = base }
        return cache.files[branch]
    end
    local entries = git.changed_files(merge_base, cwd, { head = branch, include_untracked = false })
    cache.files[branch] = { entries = entries, base = base, merge_base = merge_base }
    return cache.files[branch]
end

--- Fill the lower-right window with the same tree the diff view uses, so the
--- picker and the review look like one tool.
local function render_tree(buf, win, branch, cwd, base_ref, common_dir)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    local data = branch_files(branch, cwd, base_ref)
    if #data.entries == 0 then
        set_lines(buf, { "", "  No changes against " .. (data.base or "base") .. "." })
        return
    end
    -- Viewed marks are keyed by branch, so a branch you have already started
    -- reviewing shows its progress here before you open it.
    local store = state.open(common_dir, branch, cwd)
    store:prune(data.entries)

    vim.bo[buf].modifiable = true
    tree.render(buf, {
        entries = data.entries,
        store = store,
        folded = {},
        header = data.base,
        -- Capped rather than filling the window: the counts are right-aligned to
        -- this width, and across a 118-column pane that strands them a long way
        -- from the filenames they belong to.
        width = math.min(win and vim.api.nvim_win_get_width(win) or 72, 72),
    })
    vim.bo[buf].modifiable = false
end

--- Build the four-window layout: results and prompt on the left, PR description
--- top-right, changed files bottom-right.
local function make_layout(tree_state)
    return function(picker)
        local Layout = require("telescope.pickers.layout")

        -- The panes map Normal to the editor's Normal, but border cells are drawn
        -- with FloatBorder, whose background most themes set to the darker float
        -- background — so the box-drawing characters sit in dark cells against
        -- the editor background. Keep the theme's border foreground and drop the
        -- background: an unset bg falls through to the window's Normal.
        local fb = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
        vim.api.nvim_set_hl(0, "LgtmPickerBorder", { fg = fb.fg })
        local ft = vim.api.nvim_get_hl(0, { name = "FloatTitle", link = false })
        vim.api.nvim_set_hl(0, "LgtmPickerTitle", { fg = ft.fg, bold = ft.bold })

        local function win(enter, opts)
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].bufhidden = "wipe"
            local id = vim.api.nvim_open_win(
                buf,
                enter,
                vim.tbl_extend("force", {
                    relative = "editor",
                    style = "minimal",
                    border = "rounded",
                    zindex = 50,
                }, opts)
            )
            vim.wo[id].winhighlight = M.WINHL
            return Layout.Window({ bufnr = buf, winid = id })
        end

        local function destroy(w)
            if w then
                if vim.api.nvim_win_is_valid(w.winid) then
                    pcall(vim.api.nvim_win_close, w.winid, true)
                end
                if vim.api.nvim_buf_is_valid(w.bufnr) then
                    pcall(vim.api.nvim_buf_delete, w.bufnr, { force = true })
                end
            end
        end

        local function geometry()
            local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
            local width = math.floor(cols * 0.94)
            local height = math.floor(lines * 0.88)
            local col = math.floor((cols - width) / 2)
            local row = math.floor((lines - height) / 2)
            -- Branch names in this repo run long, so the list gets a real share
            -- of the width rather than the usual narrow strip.
            local left = math.floor(width * 0.42)
            local right = width - left - 2
            -- The description gets the top; the tree needs less room and is
            -- easier to scan short.
            local top = math.floor(height * 0.55)
            local bottom = height - top - 4
            return { width = width, height = height, col = col, row = row, left = left, right = right, top = top, bottom = bottom }
        end

        return Layout({
            picker = picker,
            mount = function(self)
                local g = geometry()
                self.results = win(false, {
                    width = g.left,
                    height = g.height - 3,
                    row = g.row,
                    col = g.col,
                    title = " branches ",
                })
                self.prompt = win(true, {
                    width = g.left,
                    height = 1,
                    row = g.row + g.height - 2,
                    col = g.col,
                    title = " pick a branch ",
                })
                self.preview = win(false, {
                    width = g.right,
                    height = g.top,
                    row = g.row,
                    col = g.col + g.left + 2,
                    title = " pull request ",
                })
                -- Ours, not Telescope's: the fourth window it has no slot for.
                local files = win(false, {
                    width = g.right,
                    height = g.bottom,
                    row = g.row + g.top + 2,
                    col = g.col + g.left + 2,
                    title = " changed files ",
                })
                tree_state.win, tree_state.buf = files.winid, files.bufnr
                tree_state.window = files
                vim.wo[files.winid].wrap = false
                vim.wo[files.winid].cursorline = false
            end,
            unmount = function(self)
                destroy(tree_state.window)
                tree_state.win, tree_state.buf, tree_state.window = nil, nil, nil
                destroy(self.results)
                destroy(self.prompt)
                destroy(self.preview)
            end,
            update = function() end,
        })
    end
end

function M.open(opts)
    opts = opts or {}
    local ok_telescope = pcall(require, "telescope")
    if not ok_telescope then
        notify("telescope.nvim is not available", vim.log.levels.ERROR)
        return
    end

    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")

    local cwd = opts.cwd or vim.fn.getcwd()
    local root = git.root(cwd)
    if not root then
        notify("not inside a git repository", vim.log.levels.ERROR)
        return
    end

    cache.pr, cache.files = {}, {}
    local diff_colors = opts.diff_colors or require("lgtm").config.diff_colors
    markdown.setup_highlights(diff_colors)
    -- The tree paints its counts with extmarks, not syntax, so the groups have
    -- to exist before it renders. lgtm.open does this for the diff view; the
    -- picker reaches the same renderer without going through it.
    tree.setup_highlights(diff_colors)

    local common_dir = git.common_dir(root)
    local worktrees = git.worktrees(root)
    local current = git.branch(root)
    local base_ref = select(1, git.resolve_base(root, { base_branch = opts.base_branch, gh_timeout = 2000 }))

    local branches = git.local_branches(root)
    if #branches == 0 then
        notify("no local branches")
        return
    end

    local entries = {}
    for _, b in ipairs(branches) do
        table.insert(entries, {
            name = b.name,
            date = b.date,
            subject = b.subject,
            worktree = worktrees[b.name],
            is_current = b.name == current,
        })
    end

    local tree_state = {}

    local previewer = previewers.new_buffer_previewer({
        title = "Pull request",
        get_buffer_by_name = function(_, entry)
            return entry.value.name
        end,
        define_preview = function(self, entry)
            local branch = entry.value.name
            local buf, win = self.state.bufnr, self.state.winid
            -- Deliberately not filetype=markdown: the markers are already gone
            -- and the styling is applied as extmarks, so a markdown parser would
            -- only find syntax that is no longer there.
            vim.bo[buf].filetype = "lgtm-pr"
            if win and vim.api.nvim_win_is_valid(win) then
                -- The body is hard-wrapped to the pane, so this only catches
                -- what cannot be broken at a space — long URLs, mostly.
                vim.wo[win].wrap = true
                vim.wo[win].linebreak = true
                vim.wo[win].breakindent = true
                vim.wo[win].conceallevel = 2
                -- Telescope's buffer previewer overwrites winhl with
                -- "Normal:TelescopePreviewNormal" on every preview, which drops
                -- the FloatBorder mapping and reverts this pane's border to the
                -- theme's dark float background. Put ours back.
                vim.wo[win].winhighlight = M.WINHL
            end
            if tree_state.win and vim.api.nvim_win_is_valid(tree_state.win) then
                vim.wo[tree_state.win].winhighlight = M.WINHL
            end
            local width = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_width(win) or 80
            markdown.apply(buf, markdown.render_pr(nil, branch, width, entry.value.worktree))
            fetch_pr(branch, root, function(pr)
                -- The selection may have moved on while gh was out.
                local sel = action_state.get_selected_entry()
                if sel and sel.value.name ~= branch then
                    return
                end
                markdown.apply(buf, markdown.render_pr(pr, branch, width, entry.value.worktree))
            end)
            -- The tree is ours to fill; do it from the same callback so it always
            -- agrees with whatever the description is showing.
            if tree_state.buf then
                set_lines(tree_state.buf, { "", "  loading…" })
                vim.schedule(function()
                    local sel = action_state.get_selected_entry()
                    if sel and sel.value.name == branch then
                        pcall(render_tree, tree_state.buf, tree_state.win, branch, root, base_ref, common_dir)
                    end
                end)
            end
        end,
    })

    pickers
        .new({}, {
            prompt_title = "PR diff — pick a branch",
            create_layout = make_layout(tree_state),
            finder = finders.new_table({
                results = entries,
                entry_maker = function(e)
                    local marker = e.is_current and "●" or (e.worktree and "○" or " ")
                    local where = e.worktree and vim.fn.fnamemodify(e.worktree, ":t") or ""
                    local display = string.format("%s %-58s %-11s %s", marker, e.name:sub(1, 58), e.date, where)
                    return {
                        value = e,
                        display = display,
                        ordinal = e.name .. " " .. (e.subject or ""),
                    }
                end,
            }),
            sorter = conf.generic_sorter({}),
            previewer = previewer,
            attach_mappings = function(prompt_bufnr)
                actions.select_default:replace(function()
                    local entry = action_state.get_selected_entry()
                    if not entry then
                        return
                    end
                    actions.close(prompt_bufnr)
                    M.open_branch(entry.value, root)
                end)
                return true
            end,
        })
        :find()
end

--- Checking out across uncommitted work either fails or drags it along, so
--- stop and say what is in the way rather than deciding for them.
--- @return boolean true when the checkout must not proceed
local function refuse_if_dirty(root, what)
    local dirty = git.dirty_files(root)
    if #dirty == 0 then
        return false
    end
    local shown = {}
    for i = 1, math.min(5, #dirty) do
        table.insert(shown, "    " .. dirty[i])
    end
    if #dirty > 5 then
        table.insert(shown, string.format("    …and %d more", #dirty - 5))
    end
    notify(
        string.format(
            "cannot check out %s — %d file%s modified\n%s\n  commit or stash, then try again",
            what,
            #dirty,
            #dirty == 1 and "" or "s",
            table.concat(shown, "\n")
        ),
        vim.log.levels.WARN
    )
    return true
end

--- Open the diff view for a chosen branch: switch to its worktree if it has one,
--- otherwise check it out where we are.
function M.open_branch(entry, root)
    local lgtm = require("lgtm")

    if entry.worktree then
        lgtm.open(nil, { cwd = entry.worktree })
        return
    end

    if entry.is_current then
        lgtm.open(nil, { cwd = root })
        return
    end

    if refuse_if_dirty(root, entry.name) then
        return
    end

    local ok, err = git.checkout(entry.name, root)
    if not ok then
        notify("checkout failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
    end
    notify("checked out " .. entry.name)
    lgtm.open(nil, { cwd = root })
end

--- Get a PR's branch local and open the review: the branch's worktree if it has
--- one, the current checkout if it is already there, otherwise `gh pr checkout`
--- — which fetches fork branches too.
function M.checkout_pr(pr, root)
    local lgtm = require("lgtm")
    local head = pr.headRefName

    if head then
        local wt = git.worktrees(root)[head]
        if wt then
            lgtm.open(nil, { cwd = wt })
            return
        end
        if git.branch(root) == head then
            lgtm.open(nil, { cwd = root })
            return
        end
    end

    if refuse_if_dirty(root, string.format("PR #%s", pr.number)) then
        return
    end

    notify(string.format("checking out PR #%s (%s)…", pr.number, head or "?"))
    git.pr_checkout(pr.number, root, function(ok, err)
        if not ok then
            notify("gh pr checkout failed: " .. (err ~= "" and err or "unknown error"), vim.log.levels.ERROR)
            return
        end
        notify("checked out " .. (head or ("PR #" .. pr.number)))
        lgtm.open(nil, { cwd = root })
    end)
end

--- Review a PR that may not be local yet. With a number, fetch that PR and open
--- it directly; without one, a picker over the repository's open PRs, searchable
--- by number, title, branch and author. Deliberately gh-backed and on demand —
--- the branch picker stays local-only.
function M.open_pr(number, opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()
    local root = git.root(cwd)
    if not root then
        notify("not inside a git repository", vim.log.levels.ERROR)
        return
    end
    if vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        notify("reviewing PRs from GitHub needs the GitHub CLI (gh)", vim.log.levels.ERROR)
        return
    end

    if number then
        notify("fetching PR #" .. number .. "…")
        git.pr_by_number(number, root, function(pr, err)
            if not pr then
                notify("could not fetch PR #" .. number .. (err and (": " .. err) or ""), vim.log.levels.WARN)
                return
            end
            M.checkout_pr(pr, root)
        end)
        return
    end

    local ok_telescope = pcall(require, "telescope")
    if not ok_telescope then
        notify("telescope.nvim is not available — use :LgtmPr <number> instead", vim.log.levels.ERROR)
        return
    end

    notify("fetching open PRs…")
    git.pr_list(root, opts.pr_limit or require("lgtm").config.pr_limit, function(prs, err)
        if not prs then
            notify(err or "gh pr list failed", vim.log.levels.WARN)
            return
        end
        if #prs == 0 then
            notify("no open PRs")
            return
        end

        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        local previewers = require("telescope.previewers")

        markdown.setup_highlights(opts.diff_colors or require("lgtm").config.diff_colors)

        -- The list rows are deliberately light (see git.pr_list); the body and
        -- the diff stats are fetched here, per highlighted PR, and memoised so
        -- arrowing back to a row costs nothing.
        local full = {}
        local previewer = previewers.new_buffer_previewer({
            title = "Pull request",
            get_buffer_by_name = function(_, entry)
                return tostring(entry.value.number)
            end,
            define_preview = function(self, entry)
                local number = entry.value.number
                local buf, win = self.state.bufnr, self.state.winid
                vim.bo[buf].filetype = "lgtm-pr"
                if win and vim.api.nvim_win_is_valid(win) then
                    vim.wo[win].wrap = true
                    vim.wo[win].linebreak = true
                    vim.wo[win].breakindent = true
                end
                local width = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_width(win) or 80
                local function draw(pr)
                    if buf and vim.api.nvim_buf_is_valid(buf) then
                        markdown.apply(buf, markdown.render_pr(pr, entry.value.headRefName or "?", width))
                    end
                end
                if full[number] then
                    draw(full[number])
                    return
                end
                -- nil renders the "loading…" placeholder.
                draw(nil)
                git.pr_by_number(number, root, function(pr)
                    if not pr then
                        return
                    end
                    full[number] = pr
                    -- The selection may have moved on while gh was out.
                    local sel = action_state.get_selected_entry()
                    if sel and sel.value.number == number then
                        draw(pr)
                    end
                end)
            end,
        })

        pickers
            .new({}, {
                prompt_title = "Open pull requests",
                finder = finders.new_table({
                    results = prs,
                    entry_maker = function(pr)
                        local author = pr.author and pr.author.login or ""
                        local display = string.format(
                            "%s#%-5s %-56s %s",
                            pr.isDraft and "◌ " or "",
                            tostring(pr.number),
                            (pr.title or ""):sub(1, 56),
                            author
                        )
                        return {
                            value = pr,
                            display = display,
                            -- Number, title, branch and author are all searchable,
                            -- so "check out my branch" works from any of them.
                            ordinal = string.format(
                                "%s %s %s %s",
                                tostring(pr.number),
                                pr.title or "",
                                pr.headRefName or "",
                                author
                            ),
                        }
                    end,
                }),
                sorter = conf.generic_sorter({}),
                previewer = previewer,
                attach_mappings = function(prompt_bufnr)
                    actions.select_default:replace(function()
                        local entry = action_state.get_selected_entry()
                        if not entry then
                            return
                        end
                        actions.close(prompt_bufnr)
                        M.checkout_pr(entry.value, root)
                    end)
                    return true
                end,
            })
            :find()
    end)
end

return M
