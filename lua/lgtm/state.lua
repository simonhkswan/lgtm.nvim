-- Persistence of "viewed" marks.
--
-- Marks are keyed on the *shared* git directory plus the branch name, not the
-- working directory. In a bare-plus-worktrees layout several checkouts share one
-- git dir, so keying this way means review progress follows the branch: check
-- the same branch out in a different worktree and your ticks come with it.
--
-- Each mark records a hash of the file's contents at the moment it was ticked.
-- If the file has changed since, the mark is dropped on load — a review of an
-- older version of the file is not a review of this one.

local M = {}

local function state_path()
    return vim.fs.joinpath(vim.fn.stdpath("data"), "lgtm", "state.json")
end

local function read_all()
    local path = state_path()
    local fd = io.open(path, "r")
    if not fd then
        return {}
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    return (ok and type(decoded) == "table") and decoded or {}
end

local function write_all(data)
    local path = state_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fd = io.open(path, "w")
    if not fd then
        return false
    end
    fd:write(vim.json.encode(data))
    fd:close()
    return true
end

--- Hash of a file's current contents, or nil if it cannot be read (deleted
--- files, for instance, which can never go stale).
local function content_hash(abs_path)
    local fd = io.open(abs_path, "rb")
    if not fd then
        return nil
    end
    local content = fd:read("*a")
    fd:close()
    return vim.fn.sha256(content)
end

M.content_hash = content_hash

--- A session's slice of the state file.
--- @param common_dir string shared git dir, from git.common_dir()
--- @param branch string current branch name
local Store = {}
Store.__index = Store

function M.open(common_dir, branch, root)
    local self = setmetatable({}, Store)
    self.key = (common_dir or "?") .. "::" .. (branch or "?")
    self.root = root
    self.dirty = false
    local all = read_all()
    local entry = all[self.key]
    self.files = (type(entry) == "table" and type(entry.files) == "table") and entry.files or {}
    self.base_sha = type(entry) == "table" and entry.base_sha or nil
    return self
end

--- Drop marks whose file has changed since it was ticked. Called once when a
--- session opens, against the file list it is about to display.
function Store:prune(entries)
    for _, e in ipairs(entries) do
        local mark = self.files[e.path]
        if mark and mark.viewed then
            local current = content_hash(vim.fs.joinpath(self.root, e.path))
            -- A file that has vanished keeps its mark; only a genuine change to
            -- readable content invalidates the review.
            if current and mark.sha and current ~= mark.sha then
                self.files[e.path] = nil
                self.dirty = true
            end
        end
    end
end

function Store:is_viewed(path)
    local mark = self.files[path]
    return mark ~= nil and mark.viewed == true
end

function Store:set_viewed(path, viewed)
    if viewed then
        self.files[path] = { viewed = true, sha = content_hash(vim.fs.joinpath(self.root, path)) }
    else
        self.files[path] = nil
    end
    self.dirty = true
end

--- Toggle and report the resulting state, so callers can decide whether to
--- advance (only a transition into "viewed" moves you on).
function Store:toggle(path)
    local now = not self:is_viewed(path)
    self:set_viewed(path, now)
    return now
end

function Store:count_viewed()
    local n = 0
    for _, mark in pairs(self.files) do
        if mark.viewed then
            n = n + 1
        end
    end
    return n
end

function Store:save(base_sha)
    if not self.dirty then
        return
    end
    local all = read_all()
    all[self.key] = { base_sha = base_sha or self.base_sha, files = self.files }
    if write_all(all) then
        self.dirty = false
    end
end

return M
