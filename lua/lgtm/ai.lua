-- Asking a model to explain the change, once, for the whole PR.
--
-- One invocation covers every file. The alternative — a call per file — re-sent the
-- PR description and the stat on every one of them and re-explored the same shared
-- code eighty times over, which is most of the cost for none of the understanding:
-- a hunk in one file is often only explicable by what moved in another, and a
-- per-file call cannot see it.
--
-- Results arrive one file at a time because the agent *writes* them, into a
-- directory the plugin watches (see store.lua). That is what keeps a single call
-- from meaning a single wait: the pane fills in for each file as its `Write` lands.
-- It also paces the agent — each file is a discrete tool call rather than one
-- enormous reply that thins out towards the end.
--
-- Explanations are keyed on line ranges in the new file, not on the plugin's region
-- indices. Sending a region list for every file would be a large prompt to build
-- and would stall the pane enumerating hunks for the whole PR before the agent
-- could start; the ranges are mapped onto regions by overlap instead, which is
-- forgiving of the agent counting a boundary slightly differently.

local M = {}

-- Part of the store's identity: results produced by an older prompt are not results
-- for this one.
M.PROMPT_VERSION = 5

local CONTRACT = [[
You are explaining a pull request to a reviewer who is reading its diff in their
editor, file by file.

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

You have read access to the whole repository, and it is what makes the second half
of that possible: a diff says a call gained an argument, and only the repository
says whether every caller was updated.

You produce no prose for the user. Your entire output is files written with the
Write tool, one per changed file, into the output directory named in the request:

  <output_dir>/<the file's path with every / replaced by __>.json

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

BEFORE the per-file explanations, write one more file:

  <output_dir>/guide.json

a reviewer's guide that splits the change into its streams of work — the distinct
things this PR does, each touching its own subset of files:

{"features":[{"title":"...","summary":"...","files":["path/one.py","path/two.ts"]}]}

  * Derive the streams from the diff itself: skim the stat and the shape of the
    change, and use the PR description where it helps. If the description already
    contains a reviewer guide or a table of work groups, follow its grouping.
  * Usually 1 to 8 streams. A stream is one coherent piece of work, not a
    directory.
  * "title" is a one-line label for a narrow picker row: at most 48 characters,
    no trailing full stop.
  * "summary" is markdown for a detail pane: 2-6 sentences on what this stream
    does, how its files relate, and where to start reading. `backticks` for
    identifiers.
  * "files" lists the stream's paths EXACTLY as they appear in the stat. A file
    may appear in more than one stream, or in none.
  * Write guide.json FIRST, before any deep per-file reading — it unlocks
    navigation in the reviewer's editor. Refine it at the end only if the deep
    read proved its grouping wrong.
  * The guide then frames the per-file work: explain each file as part of its
    stream, and when a change is only explicable through the stream's other
    files, name them.

Rules about the run itself:

  * WRITE EACH FILE AS SOON AS YOU HAVE FINISHED THAT FILE. Do not batch the writes
    to the end. The reviewer is watching the directory and reads each one as it
    appears, so a run that writes everything at the end is a run they wait for.
  * Do the file named as "open now" first, before anything else, and write it before
    you read anything you do not need for it.
  * Cover every file in the list, except any listed as already done — those are
    results from an earlier run and must be left alone. Generated files deserve one
    flat sentence, not a skip.
  * Read what you need with `git diff`, Read and Grep rather than asking for it.
  * You cannot write anywhere except the output directory, by design. Do not try.
]]

--- @param ctx table { pr, branch, base_ref, merge_base, entries, current, out_dir }
function M.build_prompt(ctx)
    local parts = {}

    local pr = ctx.pr
    if type(pr) == "table" then
        table.insert(
            parts,
            string.format(
                "<pull_request number=%q title=%q base=%q>\n%s\n</pull_request>",
                tostring(pr.number or "?"),
                tostring(pr.title or ""),
                tostring(pr.baseRefName or ctx.base_ref or "?"),
                vim.trim(pr.body or "(no description)")
            )
        )
    else
        table.insert(
            parts,
            string.format(
                "<pull_request>\nNo open pull request. Branch %s against %s.\n</pull_request>",
                ctx.branch or "?",
                ctx.base_ref or "?"
            )
        )
    end

    -- The diffs themselves are deliberately not pasted in. The agent has git and a
    -- merge base, so it can read exactly what it needs — which on an 80-file change
    -- is a fraction of what pasting all of it would have cost.
    local stat = {}
    for _, e in ipairs(ctx.entries or {}) do
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

    table.insert(
        parts,
        string.format(
            "<change base=%q merge_base=%q files=%d>\nRead any file's diff with:  "
                .. "git diff %s -- <path>\n\n%s\n</change>",
            ctx.base_ref or "?",
            ctx.merge_base or "?",
            #(ctx.entries or {}),
            ctx.merge_base or "?",
            table.concat(stat, "\n")
        )
    )

    -- The diff of the file the reviewer is looking at, inline. Every other file is
    -- left for the agent to fetch — pasting all of them would be most of the cost of
    -- the run — but the first one is worth grounding directly, so its explanation
    -- starts from what the change actually is rather than from whatever the agent
    -- decides to go and look at first.
    if ctx.current_diff and ctx.current_diff ~= "" then
        table.insert(
            parts,
            string.format(
                "<diff path=%q>\n%s\n</diff>",
                ctx.current or "?",
                vim.trim(ctx.current_diff)
            )
        )
    end

    table.insert(parts, string.format("<output_dir>%s</output_dir>", ctx.out_dir))

    -- What an earlier run already produced. Named explicitly so a run that was
    -- cancelled, timed out, or thinned out towards the end can be relaunched and
    -- pick up where it stopped instead of paying for all of it again.
    if ctx.done and #ctx.done > 0 then
        table.insert(
            parts,
            string.format(
                "<already_done count=%d>\n%s\n</already_done>",
                #ctx.done,
                table.concat(ctx.done, "\n")
            )
        )
    end

    if ctx.guide_done then
        table.insert(parts, "<guide_done>guide.json is already written; leave it alone.</guide_done>")
    end

    if ctx.only and #ctx.only > 0 then
        table.insert(
            parts,
            "<regenerate_only>\n"
                .. table.concat(ctx.only, "\n")
                .. "\n</regenerate_only>\n\nExplain ONLY the files listed above, and write only those. "
                .. "Everything else in the change is already done, guide.json included; leave it alone."
        )
    else
        table.insert(
            parts,
            string.format(
                "<open_now>%s</open_now>\n\nExplain every file in the change, starting with the one open now.",
                ctx.current or (ctx.entries and ctx.entries[1] and ctx.entries[1].path) or "?"
            )
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

--- Start the run. Calls back on the main loop with (ok, err) when the process ends;
--- the results themselves arrive as files, not through here.
--- @param cfg table the `explain` config block
--- @param paths table { repo = <cwd>, out = <output dir> }
function M.run(prompt, paths, cfg, cb)
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
        CONTRACT,
    })
    if cfg.model and cfg.model ~= "" then
        vim.list_extend(args, { "--model", cfg.model })
    end
    vim.list_extend(args, cfg.extra_args or {})

    -- Stdin, not argv: a prompt with a PR body and an 80-file stat in it is well
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

return M
