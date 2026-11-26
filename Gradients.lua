local addonName, ns = ...

-- Gradient direction, flip and fill texture for each frame on the Frames page.
--
-- Daylight UI keeps painting every color mode. Wraps and hooks on its own
-- gradient painters turn the gradient the frame's way and flip it, keyed by
-- the bar being painted. A fill texture is a second texture over the fill in
-- MOD, so Daylight UI's own texture and colors stay under it. Bars come from the frame events, mapped to the
-- Frames page's scopes. Every Daylight UI internal used is checked at login;
-- with one missing, nothing is installed and the rows stay dimmed.

local API = DaylightUI.API
local Bars = ns.Bars
local me = API.For(addonName)

local Grad = { installed = false }
ns.Gradients = Grad

local DIR, FLIP, FILL = "gradientDirection", "gradientFlip", "fillTexture"
Grad.DIR, Grad.FLIP, Grad.FILL = DIR, FLIP, FILL

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- Each is { owner, name, table getter, module?, type? }. A module's internals
-- count only while that module is on. type is what the entry must be
-- ("function" unless given). docs/reference/daylight-internals.md lists them all.
local function core(key) return function() return DaylightUI[key] end end
Grad.Core = core
local function modNs(module, key)
    return function()
        local mod = DaylightUI:GetModule(module)
        return mod and type(mod.ns) == "table" and mod.ns[key] or nil
    end
end
Grad.ModNs = modNs

Grad.INTERNALS = {
    { "Gradients", "Paint", core("Gradients") },
    { "Gradients", "PaintFrom", core("Gradients") },
    { "Gradients", "PaintStops", core("Gradients") },
    { "Gradients", "PaintClassLayers", core("Gradients") },
    { "Gradients", "Colors", core("Gradients") },
    { "Gradients", "Flat", core("Gradients") },
    { "Gradients", "Orientation", core("Gradients") },
    { "Style", "PaintBarStops", core("Style") },
    { "Style", "PaintAccentBar", core("Style") },
    { "Style", "ClearBarStops", core("Style") },
    { "Style", "FillColors", core("Style") },
    { "Style", "FillStops", core("Style") },
    { "Style", "NoteFill", core("Style") },
    { "Style", "Gradient", core("Style") },
    { "Style", "AccentSweep", core("Style") },
    { "Style", "SetBarGradient", core("Style") },
    { "Style", "FollowFill", core("Style") },
    { "Style", "SameMasks", core("Style") },
    { "OptionsPanel", "Show", core("OptionsPanel") },
    { "OptionsPanel", "Current", core("OptionsPanel") },
    { "OptionsPanel", "Refresh", core("OptionsPanel") },
    { "OptionsPanel", "IsShown", core("OptionsPanel") },
    { "UF", "UpdateAll", modNs("UnitFrames", "UF"), "UnitFrames" },
    { "CastBar", "ApplyColor", modNs("UnitFrames", "CastBar"), "UnitFrames" },
    { "Plate", "UpdateAll", modNs("Nameplates", "Plate"), "Nameplates" },
}

-- The internals of a list that are missing now, as "Owner.Name" strings.
function Grad.MissingIn(list)
    local out = {}
    for _, e in ipairs(list) do
        if not e[4] or API.IsModuleEnabled(e[4]) then
            local t = e[3]()
            if type(t) ~= "table" or type(t[e[2]]) ~= (e[5] or "function") then out[#out + 1] = e[1] .. "." .. e[2] end
        end
    end
    return out
end

function Grad.Missing() return Grad.MissingIn(Grad.INTERNALS) end

-- ---------------------------------------------------------------------
-- Frames and their bars
-- ---------------------------------------------------------------------

local UNIT_KINDS = { unit = true, party = true, raid = true, partypet = true }
local KIND_SCOPE = { party = "party", raid = "raid", partypet = "pet", nameplate = "nameplate", platecast = "platecast" }
local UNIT_SCOPE = { player = "player", target = "target", focus = "focus", pet = "pet" }
local CAST_SCOPE = { player = "castbar", target = "targetcast", focus = "focuscast" }

-- A frame's scope on the Frames page. A frame with no scope of its own (the
-- target's target, a party member's cast bar) follows All frames.
function Grad.ScopeOf(kind, unit)
    local s = KIND_SCOPE[kind]
    if s then return s end
    if kind == "unit" then
        if type(unit) ~= "string" then return "all" end
        if UNIT_SCOPE[unit] then return UNIT_SCOPE[unit] end
        if unit:find("^arena%d") then return "arena" end
        return "all"
    end
    if kind == "castbar" then return type(unit) == "string" and CAST_SCOPE[unit] or "all" end
    return nil
end

-- A power bar's scope, from its frame's. Frames with no scope of their own
-- follow All frames for both bars.
local POWER_SCOPE = { player = "playerpower", target = "targetpower", focus = "focuspower", pet = "petpower",
    party = "partypower", raid = "raidpower", arena = "arenapower", nameplate = "platepower", all = "all" }
Grad.POWER_SCOPE = POWER_SCOPE

local frameKind = setmetatable({}, { __mode = "k" })  -- frame -> kind
local frameScope = setmetatable({}, { __mode = "k" }) -- frame -> its scope (its health bar's)
local powerScope = setmetatable({}, { __mode = "k" }) -- frame -> its power bar's scope
local barScope = setmetatable({}, { __mode = "k" })   -- status bar -> scope
local frameBars = setmetatable({}, { __mode = "k" })  -- frame -> its bars, a list
local barFrame = setmetatable({}, { __mode = "k" })   -- status bar -> its frame
local barPart = setmetatable({}, { __mode = "k" })    -- status bar -> "health", "power" or "bar"
local frameUnit = setmetatable({}, { __mode = "k" })  -- frame -> its unit, or false
local framePreview = setmetatable({}, { __mode = "k" }) -- frame -> true for a sample frame
Grad.barScope, Grad.frameScope, Grad.powerScope = barScope, frameScope, powerScope
Grad.frameBars, Grad.barFrame, Grad.barPart = frameBars, barFrame, barPart
Grad.frameUnit, Grad.framePreview, Grad.frameKind = frameUnit, framePreview, frameKind

-- Other files' fn(bar). Each runs after a bar is mapped and after each
-- repaint a setting change makes.
local barListeners = {}
function Grad.OnBar(fn) barListeners[#barListeners + 1] = fn end
local function barDone(bar)
    for i = 1, #barListeners do barListeners[i](bar) end
end

local BAR_PARTS = { unit = { "health", "power" }, party = { "health", "power" }, raid = { "health", "power" },
    partypet = { "health", "power" }, nameplate = { "health", "power" }, castbar = { "bar" }, platecast = { "bar" } }

-- Maps a frame's bars to its scope. Parts can come later than the frame, so
-- each frame event maps again.
local function map(kind, frame, unit, isPreview)
    local scope = Grad.ScopeOf(kind, unit)
    local names = BAR_PARTS[kind]
    if not scope or not names then return end
    frameKind[frame], frameScope[frame], powerScope[frame] = kind, scope, POWER_SCOPE[scope]
    frameUnit[frame], framePreview[frame] = type(unit) == "string" and unit or false, isPreview == true
    local parts = API.Parts(frame)
    if not parts then return end
    local list = frameBars[frame] or {}
    frameBars[frame] = list
    local n = 0
    for _, name in ipairs(names) do
        local bar = parts[name]
        if type(bar) == "table" and bar.GetStatusBarTexture then
            barScope[bar] = name == "power" and POWER_SCOPE[scope] or scope
            barFrame[bar], barPart[bar] = frame, name
            n = n + 1
            list[n] = bar
            if Grad.ApplyFill then Grad.ApplyFill(bar) end
            barDone(bar)
        end
    end
    for i = #list, n + 1, -1 do list[i] = nil end
end
Grad.Map = map

-- A bar with no frame events (Swing.lua's swing bars): its own frame of one
-- bar, mapped once.
function Grad.MapBar(frame, kind, scope, bar)
    frameKind[frame], frameScope[frame], powerScope[frame] = kind, scope, nil
    frameUnit[frame], framePreview[frame] = false, false
    frameBars[frame] = frameBars[frame] or {}
    frameBars[frame][1] = bar
    barScope[bar], barFrame[bar], barPart[bar] = scope, frame, "bar"
    if Grad.ApplyFill then Grad.ApplyFill(bar) end
    barDone(bar)
end

-- ---------------------------------------------------------------------
-- Settings, read once per change
-- ---------------------------------------------------------------------

local dirOf, flipOf, fillOf = {}, {}, {}
local readFrom -- the bars settings table the cache was read from

-- The fill textures (look.md, owner-approved additions), by setting value.
-- look-ok: owner-approved fill textures, docs/reference/look.md
local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
Grad.FILES = { diagonal = MEDIA .. "fill-diagonal.tga", radial = MEDIA .. "fill-radial.tga" }

local function forget()
    for k in pairs(dirOf) do dirOf[k] = nil end
    for k in pairs(flipOf) do flipOf[k] = nil end
    for k in pairs(fillOf) do fillOf[k] = nil end
    readFrom = nil
end

-- A scope's direction ("HORIZONTAL", "VERTICAL" or nil for Daylight UI's), flip,
-- and fill texture (a file, or nil for Daylight UI's). A profile switch
-- replaces the settings table, which empties the cache.
function Grad.Resolve(scope)
    local now = API.GetSetting(Bars.MODULE, "bars")
    if now ~= readFrom then
        forget()
        readFrom = now
    end
    local d = dirOf[scope]
    if d == nil then
        local v = Bars.Get(scope, DIR)
        d = (v == "HORIZONTAL" or v == "VERTICAL") and v or false
        dirOf[scope] = d
        flipOf[scope] = Bars.Get(scope, FLIP) == true
        fillOf[scope] = Grad.FILES[Bars.Get(scope, FILL)] or false
    end
    return d or nil, flipOf[scope], fillOf[scope] or nil
end

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------

local KINDS = { "unit", "party", "raid", "partypet", "castbar", "platecast", "nameplate", "swing" }

-- Color modes that paint a two-color gradient Daylight UI's painters lay.
local GRAD_HEALTH = { classGradient = true, customGradient = true }
local GRAD_POWER = { gradient = true, customGradient = true }
local GRAD_CAST = { pair = true, customGradient = true }

local function uf(path) return API.GetSetting("UnitFrames", path) end
local function np(path) return API.GetSetting("Nameplates", path) end

-- A unit frame's health and power modes: its own (key's), else the Look page's.
-- The accent mode is a gradient while the accent is the class or custom pair.
local function healthGradient(key)
    local own = key and uf(key .. ".colorHealth")
    local mode = (own and own ~= "global") and own or uf("colors.health")
    if mode == "accent" then
        local kind = DaylightUI.Style.AccentSweep()
        return kind == "class" or kind == "custom"
    end
    return GRAD_HEALTH[mode] == true
end

local function powerGradient(key)
    local own = key and uf(key .. ".colorPower")
    local mode = (own and own ~= "global") and own or uf("colors.power")
    return GRAD_POWER[mode] == true
end

-- Cast bars: a pair or custom fill, and on your own bar a spell given its color.
local function castGradient(own)
    if GRAD_CAST[uf("casts.fill")] then return true end
    local list = own and uf("casts.spellColors")
    return type(list) == "table" and #list > 0
end

-- Nameplates: a class or custom health gradient, enemy or friendly. Every power
-- color there is a gradient, so a power bar shown is one.
local function plateGradient()
    return GRAD_HEALTH[np("healthColor")] == true or GRAD_HEALTH[np("friendly.healthColor")] == true
end
local function platePowerGradient() return np("power") == true or np("friendly.power") == true end

-- Does a scope paint a gradient in its color modes? Frames with no page of
-- their own (arena, party pets, the target's target) read the Look page's.
local HAS_GRADIENT = {
    player = function() return healthGradient("player") end,
    target = function() return healthGradient("target") end,
    focus = function() return healthGradient("focus") end,
    pet = function() return healthGradient("pet") or healthGradient(nil) end,
    arena = function() return healthGradient(nil) end,
    party = function() return healthGradient("party") end,
    raid = function() return healthGradient("raid") end,
    playerpower = function() return powerGradient("player") end,
    targetpower = function() return powerGradient("target") end,
    focuspower = function() return powerGradient("focus") end,
    petpower = function() return powerGradient("pet") or powerGradient(nil) end,
    arenapower = function() return powerGradient(nil) end,
    partypower = function() return powerGradient("party") end,
    raidpower = function() return powerGradient("raid") end,
    platepower = platePowerGradient,
    castbar = function() return castGradient(true) end,
    targetcast = function() return castGradient(false) end,
    focuscast = function() return castGradient(false) end,
    nameplate = plateGradient,
    platecast = function() return GRAD_CAST[np("castFill")] == true end,
}
Grad.HAS_GRADIENT = HAS_GRADIENT

-- All frames reaches every scope that follows it, and the frames with no scope.
local function hasGradient(scope)
    if scope ~= "all" then return HAS_GRADIENT[scope]() end
    if healthGradient("targettarget") or powerGradient(nil) or castGradient(false) then return true end
    for key, fn in pairs(HAS_GRADIENT) do
        if not Bars.Custom(key) and fn() then return true end
    end
    return false
end

-- True while the scope's direction rows can't act: the internals check failed,
-- Gradients is off, or none of the scope's color modes is a gradient (class,
-- one color, dark, By health, the Daylight gradient).
function Grad.Off(scope)
    if not Grad.installed then return true end
    if DaylightUI.Gradients.Flat() then return true end
    return not hasGradient(scope)
end

-- Workaround for a Daylight UI bug (docs/reference/core-prs.md): in game, a
-- row dimmed by disabled() shows at full alpha until the page refreshes again,
-- after its first show or after a color mode changes on another page. So the
-- Frames page refreshes itself a frame and 0.3 s after it shows, and once
-- (debounced) after a setting its rows read changes while it is open. Remove
-- once Daylight UI redraws them itself.

local PAGE_ID = Bars.MODULE .. "." .. Bars.PAGE.id
Grad.PAGE_ID = PAGE_ID
local redrawQueued = false

local function ourPage()
    local panel = DaylightUI.OptionsPanel
    return panel.IsShown() and panel.Current() == PAGE_ID
end

local function redraw()
    if ourPage() then DaylightUI.OptionsPanel.Refresh() end
end

function Grad.RedrawSoon()
    if redrawQueued or not ourPage() then return end
    redrawQueued = true
    C_Timer.After(0, function()
        redrawQueued = false
        redraw()
    end)
end

local function pageShown(id)
    if id ~= PAGE_ID then return end
    C_Timer.After(0, redraw)
    C_Timer.After(0.3, redraw)
end

-- The settings the dimming reads, by scope.
local READS = {
    UnitFrames = function(path)
        return path == "colors.health" or path == "colors.power" or path == "casts.fill"
            or path == "casts.spellColors" or path == "swing.fill" or path == "swing.enabled"
            or path:find("%.colorHealth$") ~= nil or path:find("%.colorPower$") ~= nil
    end,
    Nameplates = function(path)
        return path == "healthColor" or path == "friendly.healthColor" or path == "power"
            or path == "friendly.power" or path == "castFill"
    end,
    general = function(path) return path == "gradients.off" or path == "accent" end,
}

local function settingChanged(scope, path)
    local reads = READS[scope]
    if reads and type(path) == "string" and reads(path) then Grad.RedrawSoon() end
end

local OFF_HINT = " Off while the frame's bar colors have no gradient (class, one color, dark, By health, the Daylight gradient) or Gradients is off."

Bars.AddTweak({
    key = DIR, label = "Gradient direction", type = "dropdown", default = "daylight", kinds = KINDS,
    values = { daylight = "Daylight UI's", HORIZONTAL = "Horizontal", VERTICAL = "Vertical" },
    order = { "daylight", "HORIZONTAL", "VERTICAL" },
    desc = "Which way the color runs along the bar. Daylight UI's follows its Gradients page. Horizontal or Vertical turns this frame's bar effects (Flow, Tide) off while set." .. OFF_HINT,
    disabled = Grad.Off,
})

Bars.AddTweak({
    key = FLIP, label = "Flip gradient", type = "toggle", default = false, kinds = KINDS,
    desc = "Runs the colors the other way. The target's mirroring still applies." .. OFF_HINT,
    disabled = Grad.Off,
})

Bars.AddTweak({
    key = FILL, label = "Fill texture", type = "dropdown", default = "daylight", kinds = KINDS,
    values = { daylight = "Daylight UI's", diagonal = "Diagonal", radial = "Radial" },
    order = { "daylight", "diagonal", "radial" },
    desc = "A light-to-dark shape laid over the bar's own texture and colors. Diagonal and Radial turn this frame's bar effects (Flow, Tide) off while on. The Daylight gradient keeps its own look.",
    disabled = function() return not Grad.installed end,
})

-- ---------------------------------------------------------------------
-- The painters
-- ---------------------------------------------------------------------

-- Daylight UI's own painters run as always. These turn what they painted the
-- scope's way: a direction, and a flip on top of Daylight UI's own mirroring
-- of the target (horizontal only). Each returns at once for a bar with no
-- scope or a scope left at Daylight UI's, and none makes a table.

local G, Style -- Daylight UI's Gradients and Style, set at login
local lastMirror = setmetatable({}, { __mode = "k" }) -- bar -> the mirror its painter was given
local lastDir = setmetatable({}, { __mode = "k" })    -- bar -> the direction its pieces were pinned in

-- Lays a fill's painted colors in direction o, swapped with swap. A swapped
-- pair is noted too, so Flow rolls the colors on show.
local function relay(tex, o, a, b, swap)
    if swap then a, b = b, a end
    Style.Gradient(tex, o, a[1], a[2], a[3], 1, b[1], b[2], b[3], 1)
    if swap then Style.NoteFill(tex, a, b) end
end

-- The fill to re-lay, or nil: a two-color gradient Daylight UI just painted.
local function fillOf(bar)
    local tex = bar:GetStatusBarTexture()
    if type(tex) ~= "table" or not tex.SetGradient or Style.FillStops(tex) then return nil end
    return tex
end

-- Gradients.Paint: the pair again, in the scope's direction and flip.
local function afterPaint(bar, key, _, mirror)
    local scope = barScope[bar]
    if not scope then return end
    lastMirror[bar] = mirror == true
    local dir, flip = Grad.Resolve(scope)
    if not (dir or flip) or G.Flat() then return end
    local tex = fillOf(bar)
    if not tex then return end
    local own = G.Orientation()
    local o = dir or own
    local was = mirror == true and own == "HORIZONTAL"
    local want = (mirror == true and o == "HORIZONTAL") ~= flip
    if o == own and want == was then return end
    local lo, hi = G.Colors(key, want)
    if not lo then return end
    tex:SetGradient(o, lo, hi)
    Style.NoteFill(tex, lo, hi)
end

-- Gradients.PaintFrom: a pair made from one color, in the Gradients direction.
local function afterFrom(bar)
    local scope = barScope[bar]
    if not scope then return end
    local dir, flip = Grad.Resolve(scope)
    if not (dir or flip) or G.Flat() then return end
    local own = G.Orientation()
    local o = dir or own
    if o == own and not flip then return end
    local tex = fillOf(bar)
    if not tex then return end
    local a, b = Style.FillColors(tex)
    if a then relay(tex, o, a, b, flip) end
end

-- Style.PaintAccentBar: the class or custom accent's pair, always horizontal.
-- The Daylight sweep is an image, left alone.
local function afterAccent(bar)
    local scope = barScope[bar]
    if not scope then return end
    local dir, flip = Grad.Resolve(scope)
    if not (dir or flip) then return end
    local kind = Style.AccentSweep()
    if kind ~= "class" and kind ~= "custom" then return end
    local o = dir or "HORIZONTAL"
    if o == "HORIZONTAL" and not flip then return end
    local tex = fillOf(bar)
    if not tex then return end
    local a, b = Style.FillColors(tex)
    if a then relay(tex, o, a, b, flip) end
end

-- Gradients.PaintStops: the scope's direction goes in as its own, so its
-- mirror rule (horizontal only) follows it.
local function wrapStops(original, bar, cfg, paintBack, mirror, orientation)
    local scope = barScope[bar]
    if scope then
        lastMirror[bar] = mirror == true
        local dir = Grad.Resolve(scope)
        if dir then orientation = dir end
    end
    return original(bar, cfg, paintBack, mirror, orientation)
end

-- Style.PaintBarStops: the scope's direction, and the flip on the mirror.
-- Pieces pinned the other way come off first, since an unchanged list skips
-- the repaint.
local function wrapBarStops(original, bar, stops, paintBack, orientation, mirror)
    local scope = barScope[bar]
    if scope then
        local dir, flip = Grad.Resolve(scope)
        if dir or flip then
            orientation = dir or orientation or "HORIZONTAL"
            mirror = (mirror == true and orientation == "HORIZONTAL") ~= flip
        end
        local o = orientation or "HORIZONTAL"
        if lastDir[bar] ~= o then
            if lastDir[bar] then Style.ClearBarStops(bar) end
            lastDir[bar] = o
        end
    end
    return original(bar, stops, paintBack, orientation, mirror)
end

-- Gradients.PaintClassLayers: shown class layers (a class the game hides)
-- follow their bar. The bar's mirror comes from its fill's last painter.
local function afterLayers(layers, _, mode, flipped)
    if mode ~= "classGradient" or type(layers) ~= "table" then return end
    local _, any = next(layers)
    local bar = any and any:GetParent()
    local scope = bar and barScope[bar]
    if not scope then return end
    local dir, flip = Grad.Resolve(scope)
    if not (dir or flip) or G.Flat() then return end
    local own = G.Orientation()
    local o = dir or own
    local mirror = lastMirror[bar]
    if mirror == nil then mirror = flipped == true and own == "HORIZONTAL" end
    local want = (mirror and o == "HORIZONTAL") ~= flip
    if o == own and want == (flipped == true) then return end
    for token, tex in pairs(layers) do
        if tex:IsShown() then
            local lo, hi = G.Colors(token, want)
            if lo then tex:SetGradient(o, lo, hi) end
        end
    end
end

-- ---------------------------------------------------------------------
-- Fill textures
-- ---------------------------------------------------------------------

-- The texture lies over the fill in MOD, pinned to the fill's corners and cut
-- by its masks, so it grows with the fill (no size or value is read) and
-- multiplies onto Daylight UI's own texture and colors. The Daylight sweep is
-- an image of its own and goes without it. A MOD texture ignores alpha, so it
-- also goes while Grad.Faded(bar) says the fill is mostly faded (Fills.lua).

local sweepOf = setmetatable({}, { __mode = "k" }) -- bar -> showing the Daylight sweep
local overlay = setmetatable({}, { __mode = "k" }) -- bar -> our texture over its fill
Grad.overlay, Grad.sweepOf = overlay, sweepOf

local function overlayOf(bar)
    local t = overlay[bar]
    if not t then
        t = bar:CreateTexture(nil, "ARTWORK", nil, 4)
        t:SetBlendMode("MOD")
        Style.FollowFill(bar, t)
        t:Hide()
        overlay[bar] = t
    end
    return t
end

-- Shows the scope's texture over a bar's fill, or hides it.
function Grad.ApplyFill(bar)
    local scope = barScope[bar]
    if not scope then return end
    local _, _, file = Grad.Resolve(scope)
    if file and not sweepOf[bar] and not (Grad.Faded and Grad.Faded(bar)) then
        local fill = bar:GetStatusBarTexture()
        if not fill then return end
        local t = overlayOf(bar)
        t:SetTexture(file, "CLAMP", "CLAMP")
        Style.SameMasks(t, fill)
        t:Show()
    elseif overlay[bar] then
        overlay[bar]:Hide()
    end
end
local applyFill = Grad.ApplyFill

-- Style.SetBarGradient: the Daylight sweep on or off.
local function wrapSweep(original, bar, on)
    local sweep = original(bar, on)
    if barScope[bar] then
        sweep = sweep == true
        if sweepOf[bar] ~= sweep then
            sweepOf[bar] = sweep
            applyFill(bar)
        end
    end
    return sweep
end

-- Bar effects (Flow, Tide) draw over the fill in Daylight UI's own direction,
-- and only horizontal (Daylight UI turns them off on an upright bar). So a
-- custom direction or a fill texture turns its frames' effects to none with
-- me.Override, and gives them back when it's off.
-- Each is { module, setting path }; All frames' list covers frames with no
-- scope of their own.
-- bar is "health" or "power"; each key a UnitFrames frame page.
local function fxList(bar, ...)
    local out = {}
    for _, key in ipairs({ ... }) do out[#out + 1] = { "UnitFrames", key .. ".barFx." .. bar .. ".style" } end
    return out
end
Grad.FX = {
    player = fxList("health", "player"), target = fxList("health", "target"), focus = fxList("health", "focus"),
    pet = fxList("health", "pet", "partyPet"), arena = fxList("health", "arena"), party = fxList("health", "party"),
    raid = fxList("health", "raid", "raid20", "raid40"),
    playerpower = fxList("power", "player"), targetpower = fxList("power", "target"),
    focuspower = fxList("power", "focus"), petpower = fxList("power", "pet", "partyPet"),
    arenapower = fxList("power", "arena"), partypower = fxList("power", "party"),
    raidpower = fxList("power", "raid", "raid20", "raid40"),
    castbar = { { "UnitFrames", "playerCastbar.barFx.style" } },
    targetcast = { { "UnitFrames", "targetCastbar.barFx.style" } },
    focuscast = { { "UnitFrames", "focusCastbar.barFx.style" } },
    nameplate = { { "Nameplates", "barFx.health.style" } },
    platepower = { { "Nameplates", "barFx.power.style" } },
    platecast = { { "Nameplates", "barFx.cast.style" } },
    all = fxList("health", "targettarget", "focustarget", "partyTarget"),
}
for _, e in ipairs(fxList("power", "targettarget", "focustarget", "partyTarget")) do table.insert(Grad.FX.all, e) end
table.insert(Grad.FX.all, { "UnitFrames", "partyCastbar.barFx.style" })

local held = {}   -- "module:path" -> the Override handle, or false when refused
local wanted = {} -- reused each sync

-- Other files' fill looks. fn(scope, module, path) is true while the scope
-- wears one on the bar that effect setting animates.
local fxLooks = {}
function Grad.AddFxLook(fn) fxLooks[#fxLooks + 1] = fn end

local function wearsLook(scope, e)
    for i = 1, #fxLooks do
        if fxLooks[i](scope, e[1], e[2]) then return true end
    end
    return false
end

-- Holds an Override on every effect setting whose scope has its own direction,
-- a fill texture or another fill look, and lets go of the rest.
function Grad.SyncFx()
    for k in pairs(wanted) do wanted[k] = nil end
    if Grad.installed then
        for scope, list in pairs(Grad.FX) do
            local dir, _, file = Grad.Resolve(scope)
            for _, e in ipairs(list) do
                if dir or file or wearsLook(scope, e) then wanted[e[1] .. ":" .. e[2]] = e end
            end
        end
    end
    for k, h in pairs(held) do
        if not wanted[k] then
            held[k] = nil
            if h then API.Off(h) end
        end
    end
    for k, e in pairs(wanted) do
        if held[k] == nil and API.IsModuleEnabled(e[1]) then held[k] = me.Override(e[1], e[2], "none") or false end
    end
end

local HOOKS = {
    { "Style", "SetBarGradient", wrapSweep, "wrap" },
    { "Gradients", "PaintStops", wrapStops, "wrap" },
    { "Style", "PaintBarStops", wrapBarStops, "wrap" },
    { "Gradients", "Paint", afterPaint },
    { "Gradients", "PaintFrom", afterFrom },
    { "Style", "PaintAccentBar", afterAccent },
    { "Gradients", "PaintClassLayers", afterLayers },
}
Grad.HOOKS = HOOKS

-- The painters' hooks are on only while some scope has its own direction,
-- flip or fill texture, so Daylight UI's painters run untouched otherwise.
local hookHandles = {}

local function unhookAll()
    for i = #hookHandles, 1, -1 do
        me.Unhook(hookHandles[i])
        hookHandles[i] = nil
    end
end

-- Puts every hook on, or none. Returns false and the refused one's name.
local function hookAll()
    local tables = { Gradients = G, Style = Style }
    for _, h in ipairs(HOOKS) do
        local handle
        if h[4] == "wrap" then handle = me.Wrap(tables[h[1]], h[2], h[3])
        else handle = me.Hook(tables[h[1]], h[2], h[3]) end
        if not handle then
            unhookAll()
            return false, h[1] .. "." .. h[2]
        end
        hookHandles[#hookHandles + 1] = handle
    end
    return true
end

local function anyLook()
    for _, s in ipairs(Bars.SCOPES) do
        local dir, flip, file = Grad.Resolve(s.key)
        if dir or flip or file then return true end
    end
    return false
end

function Grad.SyncHooks()
    if not Grad.installed then return end
    local want = anyLook()
    if want and #hookHandles == 0 then
        local ok, name = hookAll()
        if not ok then
            Grad.installed = false
            Grad.broken = { name }
            DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": gradient direction is off. Daylight UI refused a hook on "
                .. name .. ".")
        end
    elseif not want and #hookHandles > 0 then
        unhookAll()
    end
end

function Grad.Hooked() return #hookHandles > 0 end

-- ---------------------------------------------------------------------
-- Repaint after a change
-- ---------------------------------------------------------------------

local function moduleNs(module)
    local mod = DaylightUI:GetModule(module)
    return mod and mod.ns
end

-- Other files' repaint for a kind of their own: kind -> fn(frame).
Grad.REPAINT = {}

-- Daylight UI paints the frame again. Many-color pieces come off first so they
-- pin again in the new direction. A nameplate's cast bar takes the change on
-- its next cast.
function Grad.Repaint(frame)
    local bars = frameBars[frame]
    if bars then
        for i = 1, #bars do Style.ClearBarStops(bars[i]) end
    end
    local kind = frameKind[frame]
    if UNIT_KINDS[kind] then
        moduleNs("UnitFrames").UF.UpdateAll(frame)
    elseif kind == "castbar" then
        moduleNs("UnitFrames").CastBar.ApplyColor(frame)
    elseif kind == "nameplate" then
        if frame.isSample then
            if type(frame.sampleRepaint) == "function" then frame.sampleRepaint() end
        elseif frame.unit then
            moduleNs("Nameplates").Plate.UpdateAll(frame)
        end
    elseif Grad.REPAINT[kind] then
        Grad.REPAINT[kind](frame)
    end
end

-- Other files' fn(scope). Each runs on a scope's change, before the repaint.
local changeListeners = {}
function Grad.BeforeRepaint(fn) changeListeners[#changeListeners + 1] = fn end

-- Repaints every frame a scope's change reaches, and puts on or takes off its
-- fill texture and the bar effect overrides. All frames' reaches each frame
-- that follows it.
Bars.OnChanged(function(scope)
    forget()
    if not Grad.installed then return end
    Grad.SyncHooks()
    if not Grad.installed then return end
    for i = 1, #changeListeners do changeListeners[i](scope) end
    Grad.SyncFx()
    for frame, s in pairs(frameScope) do
        local p = powerScope[frame]
        if s == scope or p == scope or (scope == "all" and (not Bars.Custom(s) or (p and not Bars.Custom(p)))) then
            Grad.Repaint(frame)
            local bars = frameBars[frame]
            if bars then
                for i = 1, #bars do
                    applyFill(bars[i])
                    barDone(bars[i])
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------
-- Login
-- ---------------------------------------------------------------------

-- Checks every internal, then installs the frame map, and the painters' hooks
-- while a scope needs them. With one missing, it installs nothing and says so
-- once in chat.
function Grad.Start()
    if Grad.installed or Grad.broken then return end
    local missing = Grad.Missing()
    if #missing > 0 then
        Grad.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": gradient direction is off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    G, Style = DaylightUI.Gradients, DaylightUI.Style
    Grad.installed = true
    Grad.SyncHooks()
    if not Grad.installed then return end
    me.Hook(DaylightUI.OptionsPanel, "Show", pageShown)
    me.On("SettingChanged", settingChanged)
    me.On("FrameMade", map)
    me.On("FrameUnitChanged", map)
    me.On("FrameStyled", map)
    me.On("FrameRemoved", function(_, frame)
        if frameUnit[frame] then frameUnit[frame] = false end
    end)

    -- Frames painted before login take the saved settings now.
    for frame, scope in pairs(frameScope) do
        local dir, flip, file = Grad.Resolve(scope)
        local p = powerScope[frame]
        local pdir, pflip, pfile
        if p then pdir, pflip, pfile = Grad.Resolve(p) end
        if dir or flip or file or pdir or pflip or pfile then Grad.Repaint(frame) end
    end
    for bar in pairs(barScope) do applyFill(bar) end
    Grad.SyncFx()
end

me.On("Login", Grad.Start)
