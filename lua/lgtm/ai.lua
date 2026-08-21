-- Asking a model to explain the change, in phases.
--
-- One run per *chapter*, not one per PR and not one per file:
--
--   1. A fast guide run reads the PR and the stat and writes guide.json — the
--      change split into chapters of work.
--   2. One run per chapter, in parallel, each given its chapter and the diffs
--      of its files pasted directly into the prompt. Small prompts, and every
--      comment is written with its chapter in view.
--   3. A final run covers the files no chapter claimed, once the chapters are
--      done.
--
-- The earlier designs bracketed this one. A call per file re-sent the PR and
-- re-explored the same shared code dozens of times, and could not see that a
-- hunk in one file is explained by another. One call for the whole PR fixed
-- that but could not be parallelised, and on a large change the single prompt
-- either pasted too much or pasted nothing. A chapter is the natural unit in
-- between: the files that have to be read together, and nothing else.
--
-- Results arrive one file at a time because the agents *write* them, into a
-- directory the plugin watches (see store.lua). A run that dies leaves what it
-- wrote; relaunching resumes rather than repeating.
--
-- Explanations are keyed on line ranges in the new file, not on the plugin's
-- region indices, and mapped onto regions by overlap — forgiving of an agent
-- counting a boundary slightly differently.

local M = {}

-- Part of the store's identity: results produced by an older prompt are not results
-- for this one.
M.PROMPT_VERSION = 7

-- Phase 1: plan the review. This run writes ONE file and does nothing else.
local GUIDE_CONTRACT = [[
You are planning the review of a pull request: splitting it into chapters of
work so a reviewer can read one coherent piece at a time, and so follow-up
agents can explain each chapter with the right files in hand.

Work from the pull request description and the stat you are given, dipping into
`git diff` for a file only where the grouping is genuinely unclear. Be quick —
this run only plans the review; a second pass explains the files. If the
description already contains a reviewer guide or a table of work groups, follow
its grouping.

You produce no prose. Your entire output is ONE file, written with the Write
tool:

  <output_dir>/guide.json

{"chapters":[{"title":"...","summary":"...","files":["path/one.py","path/two.ts"]}]}

  * Usually 1 to 8 chapters. A chapter is one coherent piece of work, not a
    directory.
  * "title" is a one-line label for a narrow picker row: at most 48 characters,
    no trailing full stop.
  * "summary" is markdown for a detail pane: 2-6 sentences on what this chapter
    does, how its files relate, and where to start reading. `backticks` for
    identifiers.
  * "files" lists the chapter's paths EXACTLY as they appear in the stat. A
    file may appear in more than one chapter, or in none.
  * You cannot write anywhere except the output directory, by design.
]]

-- Phases 2 and 3: explain the files of one chapter (or the files no chapter
-- claimed), with their diffs in hand.
local EXPLAIN_CONTRACT = [[
You are explaining part of a pull request to a reviewer who is reading its diff
in their editor, file by file.

WHAT IS UNDER REVIEW is the cumulative difference between the base branch's merge
base and the working tree — the same thing GitHub shows on the PR. It is NOT the
branch's individual commits. A branch that adds a file and then amends a line of it
in a later commit is, under review, a branch that adds a file: the intermediate
commits are how it got here and are not the subject. Never explain a line in terms
of which commit last touched it, never cite a commit hash, and do not reach for
`git log` or `git blame` to find something to say. They are for background when a
diff is genuinely inexplicable without it, and they are never the answer.

START WITH WHAT THE CHANGE DOES, in its own terms, every time. If a file is new,
say what it introduces and what it is for. If a table is created, say what it
stores. Do this even when it is plain from the diff — the reviewer wants the change
described, and a "non-obvious insight" offered in place of that is a worse answer,
not a better one. Only once that is said do you add what it affects elsewhere, and
then any risk.

You may be given ONE CHAPTER of the PR: a title, a summary, and the files that
make it up. Explain each file as part of that chapter — when a change is only
explicable through the chapter's other files, name them. Files outside your list
are context, not work: read them where they explain yours, and never write
output for them.

You have read access to the whole repository, and it is what makes the second half
of that possible: a diff says a call gained an argument, and only the repository
says whether every caller was updated.

You produce no prose for the user. Your entire output is files written with the
Write tool, one per file in your list, into the output directory named in the
request. Prefix every filename with the run tag you are given — a file shared
between chapters is explained by each, and the tag is what keeps the runs from
overwriting one another:

  <output_dir>/<run_tag>.<the file's path with every / replaced by __>.json

Each contains exactly this, and nothing else:

{"path":"<the file's path, exactly as given to you>",
 "explanations":[{"start":120,"end":134,"title":"...","body":"..."}]}

  * "start" and "end" are line numbers in the NEW version of that file — the
    right-hand side of the diff. For a block that only deletes lines, use the new
    line number it sits after, for both.
  * One object per contiguous block of change. Where two blocks in a file are one
    change, either give one object spanning both or two objects with the same title
    and body; both read correctly to the reviewer.
  * "title" is one line, at most 60 characters, no trailing full stop.
  * "body" is 1-4 sentences of markdown. `backticks` for identifiers. First what the
    change does, then why and what it affects elsewhere — name the callers, callees
    or tests you found, and any other file in this PR it has to be read alongside.
    A risk last, and only a real one. Do not pad, but do not withhold the plain
    description either.
  * If a block is mechanical (an import, a rename applied wholesale, lines that only
    moved), say so in one short sentence rather than padding it.
  * A migration, a config file or a generated artefact is explained the same way as
    code: what it changes about the system. For a migration that means the table or
    column, its type, its nullability and what reads it — not its position in the
    revision graph, unless the graph is what the change alters.

Rules about the run itself:

  * WRITE EACH FILE AS SOON AS YOU HAVE FINISHED THAT FILE. Do not batch the writes
    to the end. The reviewer is watching the directory and reads each one as it
    appears, so a run that writes everything at the end is a run they wait for.
  * Do the file named as "open now" first, if one is, and write it before you read
    anything you do not need for it.
  * Most of your diffs are pasted into the request; fetch anything missing with
    `git diff`, Read and Grep rather than asking for it.
  * Generated files deserve one flat sentence, not a skip.
  * You cannot write anywhere except the output directory, by design. Do not try.
]]

local function pr_block(ctx)
    local pr = ctx.pr
    if type(pr) == "table" then
        return string.format(
            "<pull_request number=%q title=%q base=%q>\n%s\n</pull_request>",
            tostring(pr.number or "?"),
            tostring(pr.title or ""),
            tostring(pr.baseRefName or ctx.base_ref or "?"),
            vim.trim(pr.body or "(no description)")
        )
    end
    return string.format(
        "<pull_request>\nNo open pull request. Branch %s against %s.\n</pull_request>",
        ctx.branch or "?",
        ctx.base_ref or "?"
    )
end

local function stat_lines(entries)
    local stat = {}
    for _, e in ipairs(entries or {}) do
        table.insert(
            stat,
            string.format(
                "  %s%s  +%d -%d%s",
                e.path,
                e.old_path and (" (was " .. e.old_path .. ")") or "",
                e.added or 0,
                e.deleted or 0,
                e.generated and "  [generated]" or ""
            )
        )
    end
    return table.concat(stat, "\n")
end

local function change_block(ctx)
    return string.format(
        "<change base=%q merge_base=%q files=%d>\nRead any file's diff with:  git diff %s -- <path>\n\n%s\n</change>",
        ctx.base_ref or "?",
        ctx.merge_base or "?",
        #(ctx.entries or {}),
        ctx.merge_base or "?",
        stat_lines(ctx.entries)
    )
end

--- The guide run's prompt: the PR, the whole stat, the output directory.
--- @param ctx table { pr, branch, base_ref, merge_base, entries, out_dir }
function M.build_guide_prompt(ctx)
    return table.concat({
        pr_block(ctx),
        change_block(ctx),
        string.format("<output_dir>%s</output_dir>", ctx.out_dir),
        "Write guide.json for this change.",
    }, "\n\n")
end

--- An explain run's prompt: the PR, the full stat for orientation, the chapter
--- (if any), the run's file list, and as many of their diffs as the byte budget
--- allows — largest saving of the phased design, since a chapter's diffs are a
--- fraction of the PR's.
--- @param ctx table { pr, branch, base_ref, merge_base, entries, chapter,
---        paths, diffs (path -> text), current, out_dir, only, budget }
function M.build_explain_prompt(ctx)
    local parts = { pr_block(ctx), change_block(ctx) }

    if ctx.chapter then
        table.insert(
            parts,
            string.format(
                "<chapter title=%q>\n%s\n\nIts files:\n%s\n</chapter>",
                tostring(ctx.chapter.title or ""),
                vim.trim(ctx.chapter.summary or ""),
                "  " .. table.concat(ctx.chapter.files or {}, "\n  ")
            )
        )
    else
        table.insert(
            parts,
            "<chapter>\nThese files sit outside every chapter of the reviewer guide; explain them on their own terms.\n</chapter>"
        )
    end

    -- The run's diffs, open-now first, until the budget runs out. What does not
    -- fit is named so the agent knows to fetch it rather than assume it saw
    -- everything.
    local ordered = {}
    for _, p in ipairs(ctx.paths or {}) do
        if p == ctx.current then
            table.insert(ordered, 1, p)
        else
            table.insert(ordered, p)
        end
    end
    local budget = ctx.budget or 60000
    local spent, skipped = 0, {}
    for _, p in ipairs(ordered) do
        local diff = ctx.diffs and ctx.diffs[p] or nil
        if diff and diff ~= "" and spent + #diff <= budget then
            spent = spent + #diff
            table.insert(parts, string.format("<diff path=%q>\n%s\n</diff>", p, vim.trim(diff)))
        else
            table.insert(skipped, p)
        end
    end
    if #skipped > 0 then
        table.insert(
            parts,
            "<not_pasted>\nDiffs not pasted (fetch with git diff):\n  "
                .. table.concat(skipped, "\n  ")
                .. "\n</not_pasted>"
        )
    end

    table.insert(parts, string.format("<output_dir>%s</output_dir>", ctx.out_dir))
    table.insert(parts, string.format("<run_tag>%s</run_tag>", ctx.run_tag or "run"))

    if ctx.current then
        table.insert(parts, string.format("<open_now>%s</open_now>", ctx.current))
    end

    if ctx.only then
        table.insert(
            parts,
            "<regenerate_only>\n"
                .. table.concat(ctx.paths or {}, "\n")
                .. "\n</regenerate_only>\n\nExplain ONLY the files listed above, and write only those. "
                .. "Everything else in the change is already done, guide.json included; leave it alone."
        )
    else
        table.insert(
            parts,
            "<files>\n  "
                .. table.concat(ctx.paths or {}, "\n  ")
                .. "\n</files>\n\nExplain every file in <files>, and only those."
        )
    end

    return table.concat(parts, "\n\n")
end

--- Pull the JSON object out of a reply that may have wrapped it in a fence or a
--- sentence. Used for the CLI's own envelope.
local function extract_json(text)
    if type(text) ~= "string" then
        return nil
    end
    local body = text:match("```%s*json%s*\n(.-)```") or text:match("```%s*\n(.-)```") or text
    local first, last = body:find("{"), nil
    for i = #body, 1, -1 do
        if body:sub(i, i) == "}" then
            last = i
            break
        end
    end
    if not (first and last and last > first) then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, body:sub(first, last))
    return (ok and type(decoded) == "table") and decoded or nil
end

M.extract_json = extract_json

--- How much of `region` an explanation covering [s, e] accounts for.
local function overlap(region, s, e)
    return math.min(region.last, e) - math.max(region.first, s) + 1
end

--- Attach the agent's line-range explanations to the plugin's regions.
---
--- By best overlap, with a small slack for a citation that lands just off the end of
--- a block. Regions that come out on the same explanation become a group, stated
--- once on the first of them — which is how "one change made in three places" reads
--- as one piece of text rather than three copies.
--- @return table map region index -> { title, body, group = {indices}, lead = bool }
function M.map_to_regions(explanations, regions, slack)
    slack = slack or 3
    local chosen = {}
    for i, r in ipairs(regions or {}) do
        local best, best_score
        for j, e in ipairs(explanations or {}) do
            local s = tonumber(e.start) or tonumber(e["from"])
            local fin = tonumber(e["end"]) or s
            if s then
                if fin < s then
                    s, fin = fin, s
                end
                local score = overlap(r, s, fin)
                if score <= 0 then
                    -- Near miss: treat proximity as a weak match so a citation
                    -- that is a line or two out still lands.
                    local gap = math.max(s - r.last, r.first - fin)
                    if gap <= slack then
                        score = -gap
                    else
                        score = nil
                    end
                end
                if score and (best_score == nil or score > best_score) then
                    best, best_score = j, score
                end
            end
        end
        if best then
            chosen[i] = best
        end
    end

    local groups = {}
    for i = 1, #(regions or {}) do
        local j = chosen[i]
        if j then
            groups[j] = groups[j] or {}
            table.insert(groups[j], i)
        end
    end

    local out = {}
    for j, members in pairs(groups) do
        local e = explanations[j]
        for rank, i in ipairs(members) do
            out[i] = {
                title = type(e.title) == "string" and vim.trim(e.title) or "",
                body = type(e.body) == "string" and vim.trim(e.body) or "",
                group = members,
                lead = rank == 1,
            }
        end
    end
    return out
end

--- Start one run. Calls back on the main loop with (ok, err) when the process
--- ends; the results themselves arrive as files, not through here.
--- @param contract string the system-prompt contract for this run's phase
--- @param paths table { repo = <cwd>, out = <output dir> }
--- @param cfg table the `explain` config block
function M.run(prompt, contract, paths, cfg, cb)
    if vim.fn.executable(cfg.cmd[1]) ~= 1 then
        vim.schedule(function()
            cb(false, cfg.cmd[1] .. " is not on $PATH")
        end)
        return nil
    end

    -- The agent needs Write for its output, and there is no way to scope Write to a
    -- directory through --allowedTools: every parenthesised form of it is refused,
    -- and bare `Write` is unscoped. Verified. What does work is a deny rule in
    -- --settings, so writing anywhere in the repository is denied outright while the
    -- output directory, reached via --add-dir, stays writable. The working tree has
    -- the reviewer's unsaved edits in it; nothing here may touch it.
    local deny = {}
    for _, tool in ipairs({ "Write", "Edit", "MultiEdit", "NotebookEdit" }) do
        table.insert(deny, string.format("%s(/%s/**)", tool, paths.repo))
    end
    local settings = vim.json.encode({ permissions = { deny = deny } })

    local args = vim.deepcopy(cfg.cmd)
    vim.list_extend(args, {
        "-p",
        "--output-format",
        "json",
        "--no-session-persistence",
        "--permission-mode",
        "dontAsk",
        "--add-dir",
        paths.out,
        -- --allowedTools is variadic, so it is passed as a single argument and is
        -- never the last flag before anything positional: as the last flag it
        -- swallows what follows. (The prompt goes on stdin regardless.)
        "--allowedTools",
        table.concat(cfg.tools, " "),
        "--settings",
        settings,
        "--append-system-prompt",
        contract,
    })
    if cfg.model and cfg.model ~= "" then
        vim.list_extend(args, { "--model", cfg.model })
    end
    vim.list_extend(args, cfg.extra_args or {})

    -- Stdin, not argv: a prompt with a PR body and pasted diffs in it is well
    -- past what an argument can carry.
    return vim.system(args, {
        cwd = paths.repo,
        text = true,
        stdin = prompt,
        timeout = cfg.timeout,
    }, function(res)
        vim.schedule(function()
            if res.code == 0 then
                cb(true, nil)
                return
            end
            local why = vim.trim(res.stderr or "")
            if why == "" then
                why = res.signal ~= 0 and "timed out or was cancelled" or ("exit " .. tostring(res.code))
            end
            cb(false, why)
        end)
    end)
end

M.GUIDE_CONTRACT = GUIDE_CONTRACT
M.EXPLAIN_CONTRACT = EXPLAIN_CONTRACT

return M
