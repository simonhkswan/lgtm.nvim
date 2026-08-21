-- Git plumbing: locating the repo, resolving the PR's base branch, and building
-- the changed-file list.
--
-- Two details drive most of the design here:
--
--   * The diff is taken against the *merge base*, not the tip of the base
--     branch, so it shows your changes rather than everything that has landed on
--     dev since you branched. That is what GitHub shows on the PR.
--   * `git diff <merge_base>` is deliberately given no second ref, which diffs
--     against the working tree. Committed and uncommitted changes both appear,
--     so edits made in the right-hand pane show up immediately.

local M = {}

-- Run git synchronously. Returns stdout lines plus the exit code, so callers can
-- distinguish "no output" from "command failed" (git show exits 128 for a path
-- that does not exist in the base commit, which is how added files are spotted).
local function git(args, cwd, raw)
    local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
    if raw then
        return res.stdout or "", res.code
    end
    local out = vim.split(res.stdout or "", "\n", { plain = true })
    while #out > 0 and out[#out] == "" do
        table.remove(out)
    end
    return out, res.code
end

M.git = git

local function git_one(args, cwd)
    local out, code = git(args, cwd)
    if code ~= 0 or not out[1] then
        return nil
    end
    return out[1]
end

--- Repository root for `path`. Works inside git worktrees, where `.git` is a
--- file rather than a directory.
function M.root(path)
    return git_one({ "rev-parse", "--show-toplevel" }, path)
end

--- The shared git directory. For a worktree this is the common `.bare`/`.git`
--- rather than the per-worktree one, which is what makes viewed-marks follow a
--- branch across worktrees instead of being stranded in one checkout.
function M.common_dir(cwd)
    local dir = git_one({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, cwd)
    if dir then
        return dir
    end
    -- Older git without --path-format; fall back to the possibly-relative form.
    return git_one({ "rev-parse", "--git-common-dir" }, cwd)
end

function M.branch(cwd)
    return git_one({ "rev-parse", "--abbrev-ref", "HEAD" }, cwd)
end

--- Local branches, most recently committed first — which is the order you want
--- when picking one to review.
--- @return table list of { name, date, subject }
function M.local_branches(cwd)
    local out = git({
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)\t%(committerdate:relative)\t%(contents:subject)",
        "refs/heads",
    }, cwd)
    local branches = {}
    for _, line in ipairs(out) do
        local name, date, subject = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
        if name and name ~= "" then
            table.insert(branches, { name = name, date = date, subject = subject })
        end
    end
    return branches
end

--- Branch name -> worktree path, for branches currently checked out somewhere.
--- In a bare-plus-worktrees layout most of the interesting branches already have
--- a directory of their own, and switching to it beats checking anything out.
function M.worktrees(cwd)
    local out = git({ "worktree", "list", "--porcelain" }, cwd)
    local map, path = {}, nil
    for _, line in ipairs(out) do
        local p = line:match("^worktree (.+)$")
        if p then
            path = p
        end
        local ref = line:match("^branch refs/heads/(.+)$")
        if ref and path then
            map[ref] = path
        end
    end
    return map
end

--- Paths with uncommitted changes. A checkout across a dirty tree either fails
--- or silently drags the changes along, so this gates it.
function M.dirty_files(cwd)
    local out = git({ "status", "--porcelain", "--untracked-files=no" }, cwd)
    local files = {}
    for _, line in ipairs(out) do
        local path = line:match("^..%s+(.+)$")
        if path then
            -- Renames arrive as "old -> new"; git also quotes any path holding a
            -- space or non-ASCII, which would otherwise reach the message.
            path = path:gsub("^.* %-> ", "")
            path = path:gsub('^"(.*)"$', "%1")
            table.insert(files, path)
        end
    end
    return files
end

local PR_FIELDS = "number,title,body,author,state,baseRefName,additions,deletions,changedFiles,url,isDraft"

--- The open PR for `branch`, fetched asynchronously — gh goes to the network, so
--- a synchronous call would stall the UI on every selection change.
--- Calls back with the decoded PR, or `false` when there is none.
function M.pr_view(branch, cwd, cb)
    if vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        vim.schedule(function()
            cb(false)
        end)
        return
    end
    local args = { "gh", "pr", "view" }
    if branch then
        table.insert(args, branch)
    end
    vim.list_extend(args, { "--json", PR_FIELDS })
    vim.system(args, { cwd = cwd, text = true }, function(res)
        local pr = false
        if res.code == 0 then
            local ok, decoded = pcall(vim.json.decode, res.stdout or "")
            if ok then
                pr = decoded
            end
        end
        vim.schedule(function()
            cb(pr)
        end)
    end)
end

--- Open PRs on the repository, fetched asynchronously. Calls back with a list
--- of decoded PRs, or (nil, why) when gh cannot answer.
---
--- Deliberately light: only the fields a picker row needs. A repository can
--- have a lot of open PRs, and hundreds of full bodies with diff stats is a
--- heavy answer to a question whose display is one line each. The full PR is
--- fetched per selection instead, by the previewer — which is what makes a
--- generous limit affordable.
function M.pr_list(cwd, limit, cb)
    if vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        vim.schedule(function()
            cb(nil, "the GitHub CLI (gh) is not available")
        end)
        return
    end
    vim.system(
        { "gh", "pr", "list", "--limit", tostring(limit or 1000), "--json", "number,title,headRefName,author,isDraft" },
        { cwd = cwd, text = true },
        function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    cb(nil, vim.trim(res.stderr or "gh pr list failed"))
                    return
                end
                local ok, decoded = pcall(vim.json.decode, res.stdout or "")
                if ok and type(decoded) == "table" then
                    cb(decoded)
                else
                    cb(nil, "could not parse gh output")
                end
            end)
        end
    )
end

--- One PR by number, asynchronously.
function M.pr_by_number(number, cwd, cb)
    if vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        vim.schedule(function()
            cb(nil, "the GitHub CLI (gh) is not available")
        end)
        return
    end
    vim.system(
        { "gh", "pr", "view", tostring(number), "--json", PR_FIELDS .. ",headRefName" },
        { cwd = cwd, text = true },
        function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    cb(nil, vim.trim(res.stderr or "gh pr view failed"))
                    return
                end
                local ok, decoded = pcall(vim.json.decode, res.stdout or "")
                cb(ok and type(decoded) == "table" and decoded or nil, ok and nil or "could not parse gh output")
            end)
        end
    )
end

--- `gh pr checkout`: fetches the PR's branch — fork PRs included — and checks
--- it out, which is what makes a teammate's PR reviewable locally in one step.
function M.pr_checkout(number, cwd, cb)
    vim.system({ "gh", "pr", "checkout", tostring(number) }, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            cb(res.code == 0, vim.trim(res.stderr or ""))
        end)
    end)
end

function M.checkout(branch, cwd)
    local res = vim.system({ "git", "checkout", branch }, { cwd = cwd, text = true }):wait()
    if res.code ~= 0 then
        return false, vim.trim((res.stderr or "") .. (res.stdout or ""))
    end
    return true
end

local function ref_exists(ref, cwd)
    local _, code = git({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, cwd)
    return code == 0
end

--- Ask the GitHub CLI for the PR's actual target branch.
--- Returns nil when gh is missing, unauthenticated, or there is no PR yet.
local function gh_base(cwd, timeout)
    if vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        return nil
    end
    local res = vim.system(
        { "gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName" },
        { cwd = cwd, text = true }
    ):wait(timeout or 8000)
    if res.code ~= 0 then
        return nil
    end
    local name = vim.trim(res.stdout or "")
    return name ~= "" and name or nil
end

--- Resolve the base ref to diff against, first hit wins:
---   1. an explicit argument to :LgtmEdit
---   2. the real PR target, via gh
---   3. a configured base_branch
---   4. origin/HEAD
---   5. the first of origin/dev, origin/main, origin/master that exists
--- Returns the ref name and a label describing where it came from.
function M.resolve_base(cwd, opts)
    opts = opts or {}

    if opts.explicit and opts.explicit ~= "" then
        return opts.explicit, "argument"
    end

    local from_gh = gh_base(cwd, opts.gh_timeout)
    if from_gh then
        -- gh reports a bare branch name; prefer the remote-tracking ref so the
        -- comparison is against the pushed state rather than a stale local copy.
        if ref_exists("origin/" .. from_gh, cwd) then
            return "origin/" .. from_gh, "gh"
        elseif ref_exists(from_gh, cwd) then
            return from_gh, "gh"
        end
    end

    if opts.base_branch and ref_exists(opts.base_branch, cwd) then
        return opts.base_branch, "config"
    end

    local head = git_one({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, cwd)
    if head and head ~= "origin/HEAD" and ref_exists(head, cwd) then
        return head, "origin/HEAD"
    end

    for _, candidate in ipairs({ "origin/dev", "origin/main", "origin/master" }) do
        if ref_exists(candidate, cwd) then
            return candidate, "fallback"
        end
    end

    return nil, nil
end

--- @param head string|nil defaults to HEAD; name a branch to find its merge base
---        without checking it out.
function M.merge_base(base, cwd, head)
    return git_one({ "merge-base", base, head or "HEAD" }, cwd)
end

-- Split a NUL-delimited git response into fields, dropping the trailing empty.
local function nul_fields(text)
    local fields = vim.split(text, "\0", { plain = true })
    while #fields > 0 and fields[#fields] == "" do
        table.remove(fields)
    end
    return fields
end

--- Which paths git has been told not to diff, via .gitattributes.
--- Files marked `-diff` or `linguist-generated` are generated artefacts that
--- GitHub collapses in its PR view. numstat reports no counts for them even
--- though they are ordinary text, so they need flagging separately.
local function generated_paths(paths, cwd)
    local flagged = {}
    if #paths == 0 then
        return flagged
    end
    -- -z makes check-attr expect NUL-delimited input as well as output; feeding
    -- it newlines gets the whole list read as a single path.
    local res = vim.system(
        { "git", "check-attr", "-z", "--stdin", "diff", "linguist-generated" },
        { cwd = cwd, text = true, stdin = table.concat(paths, "\0") .. "\0" }
    ):wait()
    if res.code ~= 0 then
        return flagged
    end
    -- Records are triples: path, attribute, value.
    local fields = nul_fields(res.stdout or "")
    for i = 1, #fields - 2, 3 do
        local path, attr, value = fields[i], fields[i + 1], fields[i + 2]
        if (attr == "diff" and (value == "unset" or value == "false")) or (attr == "linguist-generated" and value == "true") then
            flagged[path] = true
        end
    end
    return flagged
end

--- Every file changed between the merge base and the working tree.
--- Each entry: { path, old_path, status, added, deleted, generated, no_counts }
--- `status` is one of "A", "M", "D", "R", "U" (untracked).
--- @param opts table `head` diffs against that ref instead of the working tree,
---        which is how a branch can be inspected without checking it out.
function M.changed_files(merge_base, cwd, opts)
    opts = opts or {}
    local head = opts.head
    local entries, order = {}, {}

    local function entry(path)
        if not entries[path] then
            entries[path] = { path = path, added = 0, deleted = 0, status = "M" }
            table.insert(order, path)
        end
        return entries[path]
    end

    -- Counts. Renames arrive as three fields (added, deleted, old, new) because
    -- -z splits the rename pair out rather than using the "old => new" form.
    -- With no second ref this diffs against the working tree, which is what
    -- picks up uncommitted edits; naming a head instead inspects a branch
    -- without disturbing whatever is checked out.
    local function diff_args(...)
        local args = { "diff", ... }
        table.insert(args, merge_base)
        if head then
            table.insert(args, head)
        end
        return args
    end

    local numstat = git(diff_args("--numstat", "-z", "-M"), cwd, true)
    local fields = nul_fields(numstat)
    local i = 1
    while i <= #fields do
        local counts = fields[i]
        local added, deleted, path = counts:match("^(%S+)\t(%S+)\t(.*)$")
        if not added then
            break
        end
        local old_path
        if path == "" then
            -- Rename: the two paths follow as separate NUL-delimited fields.
            old_path, path = fields[i + 1], fields[i + 2]
            i = i + 3
        else
            i = i + 1
        end
        local e = entry(path)
        e.old_path = old_path
        -- "-" means git declined to diff it: either genuinely binary or marked
        -- -diff in .gitattributes. Which one is settled later, by content.
        e.no_counts = added == "-"
        e.added = tonumber(added) or 0
        e.deleted = tonumber(deleted) or 0
    end

    -- Statuses and rename detection.
    local namestatus = git(diff_args("--name-status", "-z", "-M"), cwd, true)
    fields = nul_fields(namestatus)
    i = 1
    while i <= #fields do
        local status = fields[i]
        if status:match("^R") then
            local old_path, path = fields[i + 1], fields[i + 2]
            local e = entry(path)
            e.status, e.old_path = "R", old_path
            i = i + 3
        else
            local path = fields[i + 1]
            if not path then
                break
            end
            entry(path).status = status:sub(1, 1)
            i = i + 2
        end
    end

    -- Untracked files are invisible to git diff but matter mid-edit.
    -- Untracked files belong to a working tree, so they are meaningless when
    -- inspecting a branch by ref.
    if opts.include_untracked ~= false and not head then
        local untracked = git({ "ls-files", "--others", "--exclude-standard", "-z" }, cwd, true)
        for _, path in ipairs(nul_fields(untracked)) do
            local e = entry(path)
            e.status = "U"
            -- pcall: an unreadable untracked path (a broken symlink, say) must
            -- not take the whole session down with it.
            local lines = 0
            pcall(function()
                for _ in io.lines((cwd or ".") .. "/" .. path) do
                    lines = lines + 1
                end
            end)
            e.added = lines
        end
    end

    local flagged = generated_paths(order, cwd)
    local list = {}
    for _, path in ipairs(order) do
        local e = entries[path]
        e.generated = flagged[path] or false
        table.insert(list, e)
    end

    return list
end

--- The unified diff for one path, as the model is shown it.
---
--- Wider context than a review pane needs (`-U8`): the agent reads the diff
--- before it reads the repository, and context lines are the cheapest way to
--- tell it what a hunk sits inside.
--- @param entry table a changed-file entry, for its status and rename pair
function M.file_diff(merge_base, entry, cwd)
    -- Untracked files are invisible to `git diff`, so they are diffed against
    -- nothing; --no-index exits 1 when the two differ, which is the normal case
    -- here rather than a failure.
    if entry.status == "U" then
        local out = git({ "diff", "--no-index", "-U8", "--", "/dev/null", entry.path }, cwd, true)
        return out
    end
    local args = { "diff", "-M", "-U8", merge_base, "--", entry.path }
    -- A rename only reads as one when both ends of the pair are in the pathspec;
    -- with just the new path git reports an added file and the reviewer loses the
    -- fact that anything moved.
    if entry.old_path then
        table.insert(args, entry.old_path)
    end
    return (git(args, cwd, true))
end

--- Contents of `path` at `rev`. Returns nil when the file did not exist there,
--- which is how added files are detected (git show exits 128).
function M.show(rev, path, cwd)
    local out, code = git({ "show", rev .. ":" .. path }, cwd, true)
    if code ~= 0 then
        return nil
    end
    return out
end

--- Text is anything without a NUL byte in the first chunk. Checked against real
--- content rather than trusting numstat, which also reports "-" for files merely
--- marked -diff in .gitattributes.
function M.is_binary(text)
    return text:sub(1, 8000):find("\0", 1, true) ~= nil
end

return M
