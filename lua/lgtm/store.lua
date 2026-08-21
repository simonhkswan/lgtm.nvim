-- The explanation store: a directory of JSON files, one per changed file.
--
-- The agent writes into it directly. That is the whole reason it is a directory of
-- plain files rather than a value passed back through a pipe: one agent run covers
-- the entire PR, and a `Write` per file is how its results arrive one at a time
-- instead of in a single reply at the end. It also means the results are on disk,
-- inspectable, and individually replaceable — a file whose explanation is wrong
-- can be regenerated on its own without re-reading the rest of the change.
--
-- Named for the branch and merge base rather than hashed, so the directory is
-- something a person can open.

local M = {}

local function sanitise(s)
    return (tostring(s or "?"):gsub("[^%w%-%._]", "-"))
end

--- @param branch string
--- @param merge_base string
--- @param version number prompt version; part of the name because results produced
---        by an older prompt are not results for the current one
function M.dir(branch, merge_base, version)
    return vim.fs.joinpath(
        vim.fn.stdpath("cache"),
        "lgtm",
        "explain",
        string.format("%s-%s-v%d", sanitise(branch), (merge_base or "?"):sub(1, 7), version or 0)
    )
end

--- The filename the agent is told to use for a path. Reversing this is deliberately
--- not relied on: every file carries its own `path` field and that is what indexes
--- the store, so a slug the agent got slightly wrong still lands correctly.
function M.slug(path)
    return (path:gsub("/", "__")) .. ".json"
end

local function read_json(file)
    local fd = io.open(file, "r")
    if not fd then
        return nil
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    return (ok and type(decoded) == "table") and decoded or nil
end

local function write_json(file, data)
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    local fd = io.open(file, "w")
    if not fd then
        return false
    end
    fd:write(vim.json.encode(data))
    fd:close()
    return true
end

M.read_json = read_json
M.write_json = write_json

--- Every explanation in the store, indexed by the `path` field inside each file
--- rather than by filename.
--- @return table map path -> { path, explanations }
function M.load(dir)
    local out = {}
    if vim.fn.isdirectory(dir) == 0 then
        return out
    end
    for name, kind in vim.fs.dir(dir) do
        -- `_`-prefixed files are the plugin's own bookkeeping; the agent owns the
        -- rest of the directory.
        if kind == "file" and name:match("%.json$") and not name:match("^_") then
            local data = read_json(vim.fs.joinpath(dir, name))
            if data and type(data.path) == "string" and type(data.explanations) == "table" then
                out[data.path] = data
            end
        end
    end
    return out
end

--- The reviewer guide: the same run's one non-per-file output, splitting the
--- change into streams of work. Kept beside the explanations because it shares
--- their identity — a guide written against an older prompt or merge base is not
--- a guide for this one.
--- @return table|nil { features = { { title, summary, files = {paths} } } }
function M.load_guide(dir)
    local data = read_json(vim.fs.joinpath(dir, "guide.json"))
    if not (data and type(data.features) == "table") then
        return nil
    end
    local features = {}
    for _, f in ipairs(data.features) do
        if type(f) == "table" and type(f.title) == "string" then
            table.insert(features, {
                title = vim.trim(f.title),
                summary = type(f.summary) == "string" and f.summary or "",
                files = type(f.files) == "table" and f.files or {},
            })
        end
    end
    if #features == 0 then
        return nil
    end
    return { features = features }
end

--- Content hashes recorded when an explanation was first read, so a file edited in
--- the working pane can be reported as having outrun its explanation. Kept in a
--- file of the plugin's own rather than stamped into the agent's output, which may
--- still be being written.
local function shas_path(dir)
    return vim.fs.joinpath(dir, "_shas.json")
end

function M.shas(dir)
    return read_json(shas_path(dir)) or {}
end

function M.record_sha(dir, path, sha)
    local all = M.shas(dir)
    if all[path] == sha then
        return
    end
    all[path] = sha
    write_json(shas_path(dir), all)
end

function M.clear(dir)
    local n = 0
    if vim.fn.isdirectory(dir) == 0 then
        return 0
    end
    for name, kind in vim.fs.dir(dir) do
        if kind == "file" and vim.fn.delete(vim.fs.joinpath(dir, name)) == 0 then
            n = n + 1
        end
    end
    return n
end

--- Watch for files appearing. This is how a whole-PR run streams: each `Write` the
--- agent makes fires here, and the pane fills in for that file the moment it lands
--- rather than when the run finishes.
---
--- Coalesced, because one logical write produces several filesystem events and a
--- re-read per event would reload the whole directory a dozen times a second.
function M.watch(dir, cb)
    vim.fn.mkdir(dir, "p")
    local handle = vim.uv.new_fs_event()
    if not handle then
        return nil
    end
    local pending = false
    local ok = pcall(function()
        handle:start(dir, {}, function(err)
            if err or pending then
                return
            end
            pending = true
            vim.defer_fn(function()
                pending = false
                cb()
            end, 120)
        end)
    end)
    if not ok then
        pcall(function()
            handle:close()
        end)
        return nil
    end
    return handle
end

function M.unwatch(handle)
    if handle then
        pcall(function()
            handle:stop()
            handle:close()
        end)
    end
end

return M
