-- Diff colours for the two code panes.
--
-- Vim paints DiffAdd/DiffChange across the *entire* line, including the empty
-- space past the end of the text, and there is no option to clip it. With stock
-- colourscheme values that reads as a saturated bar rather than as highlighting,
-- and competes with the syntax colours underneath it.
--
-- Two ideas fix that:
--
--   * Keep the line tint dark and low-saturation, so it sits behind the code
--     instead of on top of it, and let the changed *characters* be a slightly
--     lighter shade of the same hue rather than a contrasting colour. A second
--     hue in the mix is what makes stock diff colouring noisy.
--   * Colour each pane by what it means. Vim has a single DiffChange group for
--     both sides, but the highlights are applied through a per-window namespace,
--     so the base pane can read as "removed" and the working pane as "added" —
--     the way every diff outside Vim presents it.
--
-- Tints are derived from the colourscheme's own diff hues, at a fixed saturation
-- and a lightness pinned just above the background, so this tracks the active
-- theme rather than assuming nord.

local M = {}

-- Only the *hue* of these is used — saturation and lightness are rebuilt against
-- the actual background — so they are safe defaults under any colourscheme.
--
-- Additions are cyan rather than green on purpose. Red/green is precisely the
-- pair that protanopia and deuteranopia collapse, which is why most modern diff
-- tools pair red with blue instead; it also separates more cleanly from the
-- greens that syntax highlighting tends to spend on strings and comments.
-- Per-side specs. `hue` is in degrees; `line_l` and `word_l` are lightness
-- offsets from the background, so the palette re-seats itself on any theme.
--
-- The offsets are negative: the tint is *darker* than the background, not
-- lighter. That is the part that matters. A light, low-saturation wash has to be
-- bright to register at all, and then it competes with the syntax colours drawn
-- on top of it. A dark, near-fully-saturated one reads clearly as a coloured row
-- while staying visually behind the code.
--
-- 202 degrees, not the ~193 of a typical theme's cyan: at this darkness cyan
-- reads as teal rather than as blue.
local SIDES = {
    add = { hue = 202, sat = 0.97, line_l = -0.079, word_l = -0.020 },
    delete = { hue = 0, sat = 0.97, line_l = -0.037, word_l = 0.021 },
}

-- Many colourschemes (nord among them) leave Normal's background unset and let
-- the terminal's own background show through, so there is nothing to read it
-- from. Everything here is positioned relative to the background, so guessing
-- too light makes every tint too bright. Override with diff_colors.background.
local FALLBACK_BG = "#22272F"

local function hl(name)
    local ok, spec = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and spec or {}
end

local function to_rgb(n)
    if type(n) ~= "number" then
        return nil
    end
    return { math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }
end

local function hex_to_rgb(hex)
    local n = tonumber(hex:sub(2), 16)
    return to_rgb(n)
end

local function to_hex(rgb)
    return string.format("#%02X%02X%02X", rgb[1], rgb[2], rgb[3])
end

local function rgb_to_hsl(rgb)
    local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local l = (max + min) / 2
    if max == min then
        return 0, 0, l
    end
    local d = max - min
    local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
    local h
    if max == r then
        h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then
        h = (b - r) / d + 2
    else
        h = (r - g) / d + 4
    end
    return h / 6, s, l
end

local function hue_to_rgb(p, q, t)
    if t < 0 then
        t = t + 1
    end
    if t > 1 then
        t = t - 1
    end
    if t < 1 / 6 then
        return p + (q - p) * 6 * t
    end
    if t < 1 / 2 then
        return q
    end
    if t < 2 / 3 then
        return p + (q - p) * (2 / 3 - t) * 6
    end
    return p
end

local function hsl_to_rgb(h, s, l)
    if s == 0 then
        local v = math.floor(l * 255 + 0.5)
        return { v, v, v }
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return {
        math.floor(hue_to_rgb(p, q, h + 1 / 3) * 255 + 0.5),
        math.floor(hue_to_rgb(p, q, h) * 255 + 0.5),
        math.floor(hue_to_rgb(p, q, h - 1 / 3) * 255 + 0.5),
    }
end

local function normal_bg(opts)
    local override = opts and opts.background
    if type(override) == "string" and override:sub(1, 1) == "#" then
        return hex_to_rgb(override)
    end
    return to_rgb(hl("Normal").bg) or hex_to_rgb(FALLBACK_BG)
end

--- Build a colour at `hue` degrees, `sat`, and a lightness `offset` from the
--- background. Positioning against the background rather than picking absolute
--- values is what lets the same numbers work on a near-black terminal and on a
--- lighter one.
local function shade(hue, sat, offset, opts)
    local _, _, bg_l = rgb_to_hsl(normal_bg(opts))
    local l = math.min(0.95, math.max(0.02, bg_l + offset))
    return to_hex(hsl_to_rgb((hue % 360) / 360, sat, l))
end

M.shade = shade

--- The background's own hue (degrees) and saturation, for callers building
--- something meant to blend with the page rather than stand out from it.
function M.background_hsl(opts)
    local h, s = rgb_to_hsl(normal_bg(opts))
    return h * 360, s
end

--- The resolved spec for one side, after user overrides.
local function side_spec(kind, opts)
    local spec = vim.deepcopy(SIDES[kind])
    local override = opts and opts[kind]
    if type(override) == "table" then
        spec = vim.tbl_extend("force", spec, override)
    end
    return spec
end

--- Highlights for one side of the diff.
--- @param kind string "add" for the working pane, "delete" for the base pane
function M.side_palette(kind, opts)
    local s = side_spec(kind, opts)
    return {
        line = shade(s.hue, s.sat, s.line_l, opts),
        word = shade(s.hue, s.sat, s.word_l, opts),
    }
end

--- A readable foreground in the same hue, for the tree's +/- counts, so the
--- panel and the panes speak one colour language.
function M.accent(kind, opts)
    local s = side_spec(kind, opts)
    local _, _, bg_l = rgb_to_hsl(normal_bg(opts))
    -- Foregrounds need to clear the background by a wide margin to stay legible,
    -- so these are built from the hue rather than from the pane tints.
    return to_hex(hsl_to_rgb((s.hue % 360) / 360, 0.45, math.min(0.78, bg_l + 0.45)))
end
--- Apply the palette. Each window gets its own namespace so the base pane can
--- read as removals and the working pane as additions, and so the rest of
--- Neovim's diffs keep the colourscheme's own styling.
function M.apply(base_win, working_win, opts)
    local sides = {
        { win = base_win, kind = "delete", ns = "lgtm_hl_base" },
        { win = working_win, kind = "add", ns = "lgtm_hl_work" },
    }

    for _, side in ipairs(sides) do
        if side.win and vim.api.nvim_win_is_valid(side.win) then
            local ns = vim.api.nvim_create_namespace(side.ns)
            local p = M.side_palette(side.kind, opts)

            -- Lines present on only this side, and the changed-line body.
            vim.api.nvim_set_hl(ns, "DiffAdd", { bg = p.line })
            vim.api.nvim_set_hl(ns, "DiffChange", { bg = p.line })
            -- The characters that actually differ: same hue, one step lighter.
            vim.api.nvim_set_hl(ns, "DiffText", { bg = p.word })
            -- Filler rows are structural padding that keeps the two sides level.
            -- Colouring them by side reads backwards — a filler in the base pane
            -- marks content added on the *other* side — so keep them neutral and
            -- nearly invisible, and hide the '-' glyphs entirely.
            -- Filler takes the background's own hue and saturation and simply
            -- lifts the lightness, so it reads as the background a shade paler
            -- rather than as a slab of foreign grey. Both panes get the same
            -- value: deriving it from each side's hue instead left the base pane
            -- a washed-out red that looked brown beside the working pane.
            --
            -- Lighter rather than darker, because a filler carries no text and is
            -- only visible at all by its contrast with the surrounding page.
            local f = (opts and opts.filler) or {}
            local bh, bs, bl = rgb_to_hsl(normal_bg(opts))
            local fl = math.min(0.95, math.max(0.02, bl + (f.l or 0.05)))
            local filler = to_hex(hsl_to_rgb(f.hue and (f.hue % 360) / 360 or bh, f.sat or bs, fl))
            vim.api.nvim_set_hl(ns, "DiffDelete", { bg = filler, fg = filler })

            -- Fold summary lines. The colourscheme's Folded sits at almost the
            -- same lightness as its own background (#4C566A on #3B4252 under
            -- nord), which is why the text is hard to read. Keep the background
            -- quiet and lift the foreground well clear of it.
            local fold = (opts and opts.fold) or {}
            vim.api.nvim_set_hl(ns, "Folded", {
                bg = to_hex(hsl_to_rgb(bh, bs, math.min(0.95, bl + (fold.bg_l or 0.035)))),
                fg = to_hex(hsl_to_rgb(bh, bs * 0.6, math.min(0.95, bl + (fold.fg_l or 0.30)))),
                italic = true,
            })

            -- The textwidth guide. A full-strength stripe down a pane this
            -- narrow competes with the diff tints it crosses.
            local cc = (opts and opts.colorcolumn) or {}
            vim.api.nvim_set_hl(ns, "ColorColumn", {
                bg = to_hex(hsl_to_rgb(bh, bs, math.min(0.95, bl + (cc.l or 0.022)))),
            })

            vim.api.nvim_win_set_hl_ns(side.win, ns)
        end
    end
end

return M
