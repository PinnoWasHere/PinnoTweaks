local addonName, ns = ...

-- Fill opacity, a light or dark fill, and the bar background's color, for
-- each frame on the Frames page.
--
-- Daylight UI paints every color mode as always. After-hooks on its fill and
-- background painters put the scope's look back on what they just painted,
-- keyed by the bar (Gradients.lua maps bars to scopes). The hooks are on only
-- while some scope wears a look. Every Daylight UI internal used is checked at
-- login; with one missing, nothing is installed and the rows stay dimmed.

local API = DaylightUI.API
local Bars, Grad = ns.Bars, ns.Gradients
local me = API.For(addonName)

local Fills = { installed = false }
ns.Fills = Fills

local OPACITY, LOOK, LIGHT = "fillOpacity", "fillLook", "fillLight"
local BACK, STATE, DEAD, OFFLINE = "backColor", "backState", "backDead", "backOffline"
Fills.OPACITY, Fills.LOOK, Fills.LIGHT = OPACITY, LOOK, LIGHT
Fills.BACK, Fills.STATE, Fills.DEAD, Fills.OFFLINE = BACK, STATE, DEAD, OFFLINE

-- The light layer's texture (look.md, owner-approved: pastel light mode).
local WHITE = "Interface\\Buttons\\WHITE8x8" -- look-ok: owner-approved pastel layer, docs/reference/look.md

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- As Grad.INTERNALS: { owner, name, table getter, module?, type? }.
local core, modNs = Grad.Core, Grad.ModNs
Fills.INTERNALS = {
    { "Style", "NoteFill", core("Style") },
    { "Style", "NoteFillRGB", core("Style") },
    { "Style", "FillStops", core("Style") },
    { "Style", "PaintAccentBar", core("Style") },
    { "Style", "ShowModShading", core("Style") },
    { "Style", "FollowMods", core("Style") },
    { "Style", "MOD_SHADING_MIN", core("Style"), nil, "number" },
    { "Style", "FollowFill", core("Style") },
    { "Style", "SameMasks", core("Style") },
    { "Style", "SetBarColor", core("Style") },
    { "Style", "SetBarGradient", core("Style") },
    { "Style", "BarBack", core("Style") },
    { "Style", "BackAlphaOf", core("Style") },
    { "Style", "FlatSweep", core("Style") },
    { "Style", "Gradient", core("Style") },
    { "Gradients", "Orientation", core("Gradients") },
    { "Style", "Soften", core("Style") },
    { "Style", "BAR_BACK_DIM", core("Style"), nil, "number" },
    { "Style", "NEUTRAL", core("Style"), nil, "table" },
    { "Health", "GRADIENT", core("Health"), nil, "table" },
    { "Health", "GradientAt", core("Health") },
    { "Gradients", "PaintClassLayers", core("Gradients") },
    { "UF", "PaintHealth", modNs("UnitFrames", "UF"), "UnitFrames" },
    { "UF", "SetBackColor", modNs("UnitFrames", "UF"), "UnitFrames" },
    { "UF", "BackAlpha", modNs("UnitFrames", "UF"), "UnitFrames" },
    { "UF", "DARK_FILL", modNs("UnitFrames", "UF"), "UnitFrames", "table" },
    { "CastBar", "Painted", modNs("UnitFrames", "CastBar"), "UnitFrames" },
    { "Plate", "Painted", modNs("Nameplates", "Plate"), "Nameplates" },
    { "Plate", "SetBackColor", modNs("Nameplates", "Plate"), "Nameplates" },
}

function Fills.Missing() return Grad.MissingIn(Fills.INTERNALS) end

-- ---------------------------------------------------------------------
-- Settings, read once per change
-- ---------------------------------------------------------------------

local looks = {} -- scope -> { opacity, look, light, back, state, dead, offline }
local readFrom   -- the bars settings table the cache was read from

local function forget()
    for k in pairs(looks) do looks[k] = nil end
    readFrom = nil
end

local function unit01(v, default)
    if type(v) ~= "number" then return default end
    return math.max(0, math.min(1, v))
end

local LOOKS = { light = true, dark = true }
local BACKS = { value = true, class = true }

-- The dead and offline pickers' defaults, from Daylight UI by reference (look.md).
local function rgb(t) return { t[1], t[2], t[3] } end
local DEAD_COLOR, OFFLINE_COLOR = rgb(DaylightUI.Style.NEUTRAL), rgb(API.Colors().OFF)

local function color(v, default)
    if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
        return v
    end
    return default
end

-- A scope's look. A profile switch replaces the settings table, which empties
-- the cache.
function Fills.Resolve(scope)
    local now = API.GetSetting(Bars.MODULE, "bars")
    if now ~= readFrom then
        forget()
        readFrom = now
    end
    local c = looks[scope]
    if not c then
        local look, back = Bars.Get(scope, LOOK), Bars.Get(scope, BACK)
        c = {
            opacity = unit01(Bars.Get(scope, OPACITY), 1),
            look = LOOKS[look] and look or "daylight",
            light = unit01(Bars.Get(scope, LIGHT), 0),
            back = BACKS[back] and back or "daylight",
            state = Bars.Get(scope, STATE) == true,
            dead = color(Bars.Get(scope, DEAD), DEAD_COLOR),
            offline = color(Bars.Get(scope, OFFLINE), OFFLINE_COLOR),
        }
        looks[scope] = c
    end
    return c
end

-- True while the scope wears any look of this file.
local function wears(c) return c.opacity < 1 or c.look ~= "daylight" or c.back ~= "daylight" or c.state end

-- True while the scope's background follows game events.
local function listens(c) return c.back == "value" or c.state end

-- ---------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------

local Style, UF, Health -- Daylight UI's Style, unit frames and health colors, set at login
local barScope, barFrame, barPart = Grad.barScope, Grad.barFrame, Grad.barPart
local frameBars, frameKind = Grad.frameBars, Grad.frameKind
local frameUnit, framePreview = Grad.frameUnit, Grad.framePreview

local fillBar = setmetatable({}, { __mode = "k" })  -- fill texture -> its bar
local fadedTo = setmetatable({}, { __mode = "k" })  -- bar -> the alpha its fill was last given, while below 1
local layersOf = setmetatable({}, { __mode = "k" }) -- bar -> its hidden-class layers
local grainOf = setmetatable({}, { __mode = "k" })  -- bar -> Daylight UI's MOD grain over its fill
local grainOn = setmetatable({}, { __mode = "k" })  -- bar -> whether Daylight UI wants that grain shown
local lightOf = setmetatable({}, { __mode = "k" })  -- bar -> our light layer over its fill
local tintOf = setmetatable({}, { __mode = "k" })   -- bar -> { r, g, b } its painter last gave it
local stateOn = setmetatable({}, { __mode = "k" })  -- bar -> true while it wears a dead or offline background
local sweepOn = setmetatable({}, { __mode = "k" })  -- bar -> true while it shows the Daylight sweep
Fills.lightOf = lightOf

-- Real units' frames, filed by unit for the game events (Fills.Sync).
local byUnit = {} -- unit -> { [frame] = true }
local filed = setmetatable({}, { __mode = "k" }) -- frame -> the unit it is filed under

local function file(frame)
    local u = not framePreview[frame] and frameUnit[frame] or nil
    local was = filed[frame]
    if was == u then return end
    if was and byUnit[was] then byUnit[was][frame] = nil end
    if u then
        local set = byUnit[u]
        if not set then
            set = setmetatable({}, { __mode = "k" })
            byUnit[u] = set
        end
        set[frame] = true
    end
    filed[frame] = u
end

local UNIT_KINDS = { unit = true, party = true, raid = true, partypet = true }
local DARK_KINDS = { nameplate = true, castbar = true, platecast = true, swing = true }

local function lookOf(bar)
    local scope = barScope[bar]
    return scope and Fills.Resolve(scope) or nil
end

-- Dark is Daylight UI's own on unit frame health, so ours paints power,
-- nameplate, cast and swing bars.
local function darkable(bar)
    return barPart[bar] == "power" or DARK_KINDS[frameKind[barFrame[bar]]] == true
end

local function darkOn(bar, c) return c.look == "dark" and UF ~= nil and darkable(bar) end

-- The alpha a bar's fill wears. A fill of three or more colors keeps 1: its
-- colors are MOD pieces, which ignore alpha.
local function alphaOf(bar, c)
    if not Fills.installed or c.opacity >= 1 then return 1 end
    local fill = bar:GetStatusBarTexture()
    if fill and Style.FillStops(fill) then return 1 end
    return c.opacity
end

-- True while the bar's fill is mostly faded, so a MOD layer over it (which
-- ignores alpha) goes, as Daylight UI's own rule does for a faded bar.
function Fills.Faded(bar)
    if not Fills.installed then return false end
    local c = lookOf(bar)
    return c ~= nil and alphaOf(bar, c) < Style.MOD_SHADING_MIN
end
Grad.Faded = Fills.Faded

-- How solid the bar's empty part is: the frame page's own, else the Colors
-- page's for unit frames; the bar's own elsewhere.
local function backAlpha(bar)
    if UNIT_KINDS[frameKind[barFrame[bar]]] and UF then
        local own = bar.backLook
        if type(own) == "table" and type(own.alpha) == "number" then return own.alpha end
        return UF.BackAlpha()
    end
    return Style.BackAlphaOf(bar)
end

-- How bright the empty part is next to its fill: the frame page's own, else
-- the Colors page's for unit frames; Daylight UI's dim elsewhere.
local function backBright(bar)
    if UNIT_KINDS[frameKind[barFrame[bar]]] then
        local own = bar.backLook
        if type(own) == "table" and type(own.bright) == "number" then return own.bright end
        local k = API.GetSetting("UnitFrames", "colors.backBrightness")
        if type(k) == "number" then return k end
    end
    return Style.BAR_BACK_DIM
end

local function fadeLayers(bar, a, dark)
    local layers = layersOf[bar]
    if not layers then return end
    for _, tex in pairs(layers) do
        if tex:IsShown() then
            if dark then tex:Hide() else tex:SetAlpha(a) end
        end
    end
end

-- Daylight UI's grain over the Daylight sweep is MOD too: hidden while the
-- fill is faded, handed back to Daylight UI's own rule after.
local function syncGrain(bar)
    local t = grainOf[bar]
    if not t then return end
    if Fills.Faded(bar) then t:Hide() else Style.ShowModShading(t, bar, grainOn[bar]) end
end

-- The light layer: white in ADD over the fill, pinned to it and cut by its
-- masks. It reads no color, so it lifts any mode, secret colors included.
local function applyLight(bar, c, a)
    local t = lightOf[bar]
    if c.look ~= "light" or c.light <= 0 then
        if t then t:Hide() end
        return
    end
    local fill = bar:GetStatusBarTexture()
    if not t then
        t = bar:CreateTexture(nil, "ARTWORK", nil, 3)
        t:SetTexture(WHITE)
        t:SetBlendMode("ADD")
        Style.FollowFill(bar, t)
        lightOf[bar] = t
    end
    Style.SameMasks(t, fill)
    t:SetAlpha(c.light * a)
    t:Show()
end

-- ---------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------

local busy = false -- true while Fills.lua paints a fill itself

-- The color a painter gave the bar, kept for Dark's empty part. It may be
-- secret: it only goes back into SetVertexColor.
local function setTint(bar, r, g, b)
    local t = tintOf[bar]
    if not t then
        t = {}
        tintOf[bar] = t
    end
    t[1], t[2], t[3] = r, g, b
end

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- A real unit's bar (a sample frame has none of its own).
local function unitOf(bar)
    local frame = barFrame[bar]
    if framePreview[frame] then return nil end
    return frameUnit[frame] or nil
end

-- Dead, ghost or offline, players only, or nil. A secret flag can't be
-- tested, so the bar then keeps the look it has, as in UF.UnitState.
local function flag(fn, u)
    local v = fn(u)
    return not secret(v) and v == true
end

local function stateOf(u)
    local isPlayer = UnitIsPlayer(u)
    if secret(isPlayer) or isPlayer ~= true then return nil end
    local on = UnitIsConnected(u)
    if not secret(on) and on == false then return "offline" end
    if flag(UnitIsGhost, u) or flag(UnitIsDead, u) then return "dead" end
    return nil
end

local function stateBack(bar, back, c)
    local u = unitOf(bar)
    local s = u and stateOf(u)
    stateOn[bar] = s and true or nil
    if not s then return false end
    local col = s == "offline" and c.offline or c.dead
    back:SetVertexColor(col[1], col[2], col[3], backAlpha(bar))
    return true
end

-- The health colors as a client curve, each at the background's brightness,
-- so a secret health or power picks its color without Lua reading it.
-- Rebuilt when Daylight UI's softness or brightness changes.
local curves = {} -- brightness -> curve, or false when the client has none
local function curveFor(k)
    local c = curves[k]
    if c ~= nil then return c or nil end
    c = false
    if C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor then
        c = C_CurveUtil.CreateColorCurve() or false
        if c then
            if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Linear) end
            for _, stop in ipairs(Health.GRADIENT) do
                local r, g, b = Style.Soften(stop[2][1], stop[2][2], stop[2][3])
                c:AddPoint(stop[1], CreateColor(r * k, g * k, b * k, 1))
            end
        end
    end
    curves[k] = c
    return c or nil
end

-- A sample bar's fill fraction: plain numbers on a preview, else nil.
local function sampleFraction(bar)
    local v = bar:GetValue()
    local lo, hi = bar:GetMinMaxValues()
    if secret(v) or secret(lo) or secret(hi) then return nil end
    if type(v) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then return nil end
    return (v - lo) / (hi - lo)
end

-- By value: green to red with the bar's health or power. pct is a unit frame
-- sample's health percent.
local function valueBack(bar, back, pct)
    local k, a = backBright(bar), backAlpha(bar)
    local u = unitOf(bar)
    if not u then
        local f = pct and pct / 100 or sampleFraction(bar)
        if not f then return false end
        local r, g, b = Health.GradientAt(f)
        back:SetVertexColor(r * k, g * k, b * k, a)
        return true
    end
    local curve = curveFor(k)
    if not curve then return false end
    local col
    if barPart[bar] == "power" then col = UnitPowerPercent(u, nil, false, curve)
    else col = UnitHealthPercent(u, true, curve) end
    if type(col) ~= "table" or not col.GetRGB then return false end
    local r, g, b = col:GetRGB()
    back:SetVertexColor(r, g, b, a)
    return true
end

-- By class: a player's class color at the background's brightness. NPCs keep
-- Daylight UI's. A sample shows its own color.
local function classBack(bar, back)
    local k, a = backBright(bar), backAlpha(bar)
    local u = unitOf(bar)
    if not u then
        local t = tintOf[bar]
        if not t or secret(t[1]) or secret(t[2]) or secret(t[3]) then return false end
        back:SetVertexColor(t[1] * k, t[2] * k, t[3] * k, a)
        return true
    end
    local isPlayer = UnitIsPlayer(u)
    if secret(isPlayer) or isPlayer ~= true then return false end
    local _, token = UnitClass(u)
    if secret(token) or type(token) ~= "string" then return false end
    local r, g, b = API.ClassColor(token)
    if type(r) ~= "number" then return false end
    back:SetVertexColor(r * k, g * k, b * k, a)
    return true
end

-- Dark's empty part in the bar's own full color, as Daylight UI's Dark health.
-- A unit frame page's own background look wins, as it does there.
local function darkBack(bar, back)
    if UNIT_KINDS[frameKind[barFrame[bar]]] and bar.backLook then return end
    local t = tintOf[bar]
    if sweepOn[bar] then
        local r, g, b = Style.FlatSweep()
        back:SetVertexColor(r, g, b, backAlpha(bar))
    elseif t then
        back:SetVertexColor(t[1], t[2], t[3], backAlpha(bar))
    end
end

-- After a background paint: dead and offline first, then By value or By
-- class (health and power bars), then Dark. A scope at Daylight UI's leaves
-- every background mode of Daylight UI's alone.
local function paintBack(bar, pct)
    if busy then return end
    local c = lookOf(bar)
    if not c then return end
    local back = Style.BarBack(bar)
    if not back then return end
    if barPart[bar] ~= "bar" then
        if c.state and stateBack(bar, back, c) then return end
        if c.back == "value" and valueBack(bar, back, pct) then return end
        if c.back == "class" and classBack(bar, back) then return end
    end
    if darkOn(bar, c) then darkBack(bar, back) end
end

-- After a fill paint: Dark, then the fill's alpha. A texture has one alpha,
-- shared with its color, so every paint resets it to 1.
-- The colors a fill was last painted with, kept to paint them again with an
-- alpha: a status bar's fill ignores SetAlpha in this client, so its alpha
-- rides in its colors. They may be secret: they only go back into a setter.
local laid = setmetatable({}, { __mode = "k" }) -- bar -> { r1, g1, b1, r2, g2, b2, two }

local function unpackColor(c)
    if type(c) ~= "table" then return nil end
    if c.r ~= nil then return c.r, c.g, c.b end
    return c[1], c[2], c[3]
end

local function laidOf(bar)
    local t = laid[bar]
    if not t then
        t = {}
        laid[bar] = t
    end
    return t
end

-- Style.NoteFill's colors: one, or a pair in painting order.
local function remember(bar, lo, hi)
    local t = laidOf(bar)
    t[1], t[2], t[3] = unpackColor(lo)
    t.two = hi ~= nil
    if t.two then t[4], t[5], t[6] = unpackColor(hi) end
end

local function rememberRGB(bar, r, g, b)
    local t = laidOf(bar)
    t[1], t[2], t[3], t.two = r, g, b, false
end

-- The way a fill's pair runs: the scope's own direction, else the painter's
-- (the accent's is always horizontal), else the Gradients page's.
local function orientationOf(bar, own)
    local dir = Grad.Resolve(barScope[bar])
    return dir or own or DaylightUI.Gradients.Orientation()
end

-- The fill's last colors again, at alpha a. The Daylight sweep is an image
-- painted white.
local function fadeFill(bar, fill, a, own)
    if sweepOn[bar] then
        fill:SetVertexColor(1, 1, 1, a)
        return
    end
    local t = laid[bar]
    if not (t and t[1] ~= nil) then return end
    if t.two then
        Style.Gradient(fill, orientationOf(bar, own), t[1], t[2], t[3], a, t[4], t[5], t[6], a)
    else
        fill:SetVertexColor(t[1], t[2], t[3], a)
    end
end

-- After a fill paint: Dark, or the faded colors. own is the painter's
-- direction when it isn't the Gradients page's.
local function paintFill(bar, own)
    if busy then return end
    local c = lookOf(bar)
    if not c then return end
    local fill = bar:GetStatusBarTexture()
    if not fill then return end
    local dark = darkOn(bar, c)
    local a = alphaOf(bar, c)
    if dark then
        local d = UF.DARK_FILL
        busy = true
        fill:SetVertexColor(d[1], d[2], d[3], a)
        -- Noted, so a many-color fill's pieces come off and Flow reads the dark.
        Style.NoteFillRGB(fill, d[1], d[2], d[3])
        busy = false
        fadeLayers(bar, a, true)
    elseif a < 1 then
        fadeFill(bar, fill, a, own)
    end
    local t = lightOf[bar]
    if t and t:IsShown() then t:SetAlpha(c.light * a) end
end

-- After a mapping or a setting change: the fill's alpha and light now, its
-- class layers and grain. Gradients.lua's own fill texture goes on first.
local function applyBar(bar)
    local fill = bar:GetStatusBarTexture()
    if not fill then return end
    fillBar[fill] = bar
    file(barFrame[bar])
    if not Fills.installed then return end
    local c = lookOf(bar)
    if not c then return end
    local a = alphaOf(bar, c)
    if a < 1 or fadedTo[bar] then
        if darkOn(bar, c) then
            local d = UF.DARK_FILL
            fill:SetVertexColor(d[1], d[2], d[3], a)
        else
            fadeFill(bar, fill, a)
        end
        fadeLayers(bar, a, false)
        fadedTo[bar] = a < 1 and a or nil
    end
    syncGrain(bar)
    applyLight(bar, c, a)
end
Fills.ApplyBar = applyBar
Grad.OnBar(applyBar)

-- ---------------------------------------------------------------------
-- The hooks
-- ---------------------------------------------------------------------

-- Style.NoteFill: nearly every fill paint ends in it or NoteFillRGB.
local function afterNote(tex, lo, hi)
    local bar = fillBar[tex]
    if not bar or busy then return end
    remember(bar, lo, hi)
    paintFill(bar)
end

-- Style.NoteFillRGB: a one-color fill, whose color is the bar's own.
local function afterNoteRGB(tex, r, g, b)
    local bar = fillBar[tex]
    if not bar or busy then return end
    rememberRGB(bar, r, g, b)
    setTint(bar, r, g, b)
    paintFill(bar)
end

-- Style.PaintAccentBar: its last white has no note; its pair runs horizontally.
local function afterAccent(bar)
    if barScope[bar] then paintFill(bar, "HORIZONTAL") end
end

-- UF.SetBackColor, Style.SetBarColor, Plate.SetBackColor: a background paint.
local function afterBack(bar, r, g, b)
    if busy or not barScope[bar] then return end
    setTint(bar, r, g, b)
    paintBack(bar)
end

-- Style.SetBarGradient: the Daylight sweep on or off. With Gradients off it
-- paints flat instead, as Daylight UI decides it there. The sweep paints its
-- own background.
local function afterSweep(bar, on)
    if not barScope[bar] then return end
    sweepOn[bar] = (on and not DaylightUI.Gradients.Flat()) or nil
    paintBack(bar)
end

-- A frame's painter (CastBar.Painted, Plate.Painted): Dark again over a fill
-- written with no note (a plugin's white, a secret tapped color), and the
-- background. Such a fill's colors aren't known, so it isn't faded.
local function afterFrame(frame)
    local bars = frameBars[frame]
    if not bars then return end
    for i = 1, #bars do
        local bar = bars[i]
        local c = lookOf(bar)
        if c and darkOn(bar, c) then paintFill(bar) end
        paintBack(bar)
    end
end

-- UF.PaintHealth: r, g, b is the unit's own color, pct a sample's health.
local function afterHealth(f, r, g, b, pct)
    local bars = frameBars[f]
    if not bars then return end
    for i = 1, #bars do
        local bar = bars[i]
        local health = barPart[bar] == "health"
        if health then setTint(bar, r, g, b) end
        paintFill(bar)
        paintBack(bar, health and pct or nil)
    end
end

-- Gradients.PaintClassLayers: a hidden class's layers over the fill.
local function afterLayers(layers)
    if type(layers) ~= "table" then return end
    local _, any = next(layers)
    local bar = any and any:GetParent()
    if not (bar and barScope[bar]) then return end
    layersOf[bar] = layers
    local c = lookOf(bar)
    if not c then return end
    local a, dark = alphaOf(bar, c), darkOn(bar, c)
    if a < 1 or dark then fadeLayers(bar, a, dark) end
end

-- Style.ShowModShading: Daylight UI's grain shown or not.
local function afterShading(t, bar, on)
    if not (bar and barScope[bar]) then return end
    grainOf[bar], grainOn[bar] = t, on == true
    if on and Fills.Faded(bar) then t:Hide() end
end

-- Style.FollowMods: Daylight UI shows the grain again as its bar's alpha moves.
local function afterMods()
    for bar, t in pairs(grainOf) do
        if t:IsShown() and Fills.Faded(bar) then t:Hide() end
    end
end

-- { owner, name, fn, module? }. Hooks of a module that is off are skipped.
local HOOKS = {
    { "Style", "NoteFill", afterNote },
    { "Style", "NoteFillRGB", afterNoteRGB },
    { "Style", "PaintAccentBar", afterAccent },
    { "Style", "SetBarColor", afterBack },
    { "Style", "SetBarGradient", afterSweep },
    { "Style", "ShowModShading", afterShading },
    { "Style", "FollowMods", afterMods },
    { "Gradients", "PaintClassLayers", afterLayers },
    { "UF", "PaintHealth", afterHealth, "UnitFrames" },
    { "UF", "SetBackColor", afterBack, "UnitFrames" },
    { "CastBar", "Painted", afterFrame, "UnitFrames" },
    { "Plate", "Painted", afterFrame, "Nameplates" },
    { "Plate", "SetBackColor", afterBack, "Nameplates" },
}
Fills.HOOKS = HOOKS

local tables = {}  -- owner name -> Daylight UI's table, set at login
local handles = {} -- the hooks on now

local function unhookAll()
    for i = #handles, 1, -1 do
        me.Unhook(handles[i])
        handles[i] = nil
    end
end

-- Puts every hook on, or none. Returns false and the refused one's name.
local function hookAll()
    for _, h in ipairs(HOOKS) do
        if not h[4] or API.IsModuleEnabled(h[4]) then
            local handle = me.Hook(tables[h[1]], h[2], h[3])
            if not handle then
                unhookAll()
                return false, h[1] .. "." .. h[2]
            end
            handles[#handles + 1] = handle
        end
    end
    return true
end

-- Game events for By value and dead or offline backgrounds, filed by unit.
local POWER_EVENTS = { UNIT_POWER_UPDATE = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true }
local EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_CONNECTION", "UNIT_FLAGS",
    "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER" }

-- A background again after an event. A bar that leaves a dead or offline
-- background gets Daylight UI's own paint back first.
local function refresh(bar)
    local was = stateOn[bar]
    paintBack(bar)
    if was and not stateOn[bar] then Grad.Repaint(barFrame[bar]) end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, unit)
    local set = byUnit[unit]
    if not set then return end
    local power = POWER_EVENTS[event] == true
    for frame in pairs(set) do
        local bars = frameUnit[frame] == unit and frameBars[frame]
        if bars then
            for i = 1, #bars do
                if not power or barPart[bars[i]] == "power" then refresh(bars[i]) end
            end
        end
    end
end)

local listening = false

local function anyLook()
    local any, hear = false, false
    for _, s in ipairs(Bars.SCOPES) do
        local c = Fills.Resolve(s.key)
        if wears(c) then any = true end
        if listens(c) then hear = true end
    end
    return any, hear
end

local function listen(on)
    if on == listening then return end
    listening = on
    for _, e in ipairs(EVENTS) do
        if on then events:RegisterEvent(e) else events:UnregisterEvent(e) end
    end
end

-- The hooks are on while some scope wears a look, so Daylight UI's painters
-- carry no extra call otherwise. The events likewise.
function Fills.Sync()
    if not Fills.installed then return end
    local want, hear = anyLook()
    if want and #handles == 0 then
        local ok, name = hookAll()
        if not ok then
            Fills.installed = false
            Fills.broken = { name }
            listen(false)
            DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": fill looks are off. Daylight UI refused a hook on " .. name .. ".")
            return
        end
    elseif not want and #handles > 0 then
        unhookAll()
    end
    listen(want and hear)
end

function Fills.Hooked() return #handles > 0 end
function Fills.Listening() return listening end

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------

local KINDS = { "unit", "party", "raid", "partypet", "castbar", "platecast", "nameplate", "swing" }

-- Does a bar of the scope (or one following Look) wear three or more colors?
local function manyColors(scope)
    for bar, s in pairs(barScope) do
        if s == scope or (scope == "all" and not Bars.Custom(s, "fill")) then
            local fill = bar:GetStatusBarTexture()
            if fill and Style.FillStops(fill) then return true end
        end
    end
    return false
end

function Fills.OpacityOff(scope)
    return not Fills.installed or manyColors(scope)
end

Bars.AddTweak({
    key = OPACITY, card = "fill", label = "Fill opacity", type = "slider", default = 1, kinds = KINDS,
    min = 0, max = 1, step = 0.05, unit = "%",
    desc = "How solid the bar's fill is. Below 100% the background shows through it, and this frame's bar effects (Flow, Tide) turn off. Off while the bar wears three or more colors: those draw at full strength whatever the opacity.",
    disabled = Fills.OpacityOff,
})

-- Dark is offered where Daylight UI has none of its own: power, nameplate,
-- cast and swing bars, and Look (which reaches them).
local DARK_SCOPES = { all = true, castbar = true, targetcast = true, focuscast = true, platecast = true,
    nameplate = true }
for _, swing in pairs(ns.SwingBars.SCOPE) do DARK_SCOPES[swing] = true end
for _, power in pairs(Grad.POWER_SCOPE) do
    if power ~= "all" then DARK_SCOPES[power] = true end
end
Fills.DARK_SCOPES = DARK_SCOPES

local LOOK_VALUES = { daylight = "Daylight UI's", light = "Light", dark = "Dark" }
local LOOK_ORDER = { "daylight", "light", "dark" }
local LIGHT_VALUES = { daylight = LOOK_VALUES.daylight, light = LOOK_VALUES.light }
local LIGHT_ORDER = { "daylight", "light" }

Bars.AddTweak({
    key = LOOK, card = "fill", label = "Fill look", type = "dropdown", default = "daylight", kinds = KINDS,
    values = LOOK_VALUES, order = LOOK_ORDER,
    valuesOf = function(scope)
        if DARK_SCOPES[scope] then return LOOK_VALUES, LOOK_ORDER end
        return LIGHT_VALUES, LIGHT_ORDER
    end,
    desc = "Light lifts the fill toward white. Dark paints power, nameplate, cast and swing bars near-black with the empty part in the bar's own color, like Daylight UI's Dark health (unit frame health has that on Daylight UI's Colors page). Either turns this frame's bar effects (Flow, Tide) off.",
    disabled = function() return not Fills.installed end,
})

Bars.AddTweak({
    key = LIGHT, card = "fill", label = "Light amount", type = "slider", default = 0.3, kinds = KINDS,
    min = 0, max = 1, step = 0.05, unit = "%",
    desc = "How far Light lifts the fill.",
    disabled = function(scope) return not Fills.installed or Bars.Get(scope, LOOK) ~= "light" end,
})

-- The background rows are for health and power bars.
local BACK_KINDS = { "unit", "party", "raid", "partypet", "nameplate" }

-- Rows read the settings live: Daylight UI redraws the page before the cache
-- hears a change.
local function stateOff(scope) return not Fills.installed or Bars.Get(scope, STATE) ~= true end

Bars.AddTweak({
    key = BACK, card = "background", label = "Bar background color", type = "dropdown", default = "daylight", kinds = BACK_KINDS,
    values = { daylight = "Daylight UI's", value = "By value", class = "By class" },
    order = { "daylight", "value", "class" },
    desc = "The color of the bar's empty part. By value runs green to red with the bar's health or power. By class uses a player's class color; NPCs keep Daylight UI's.",
    disabled = function() return not Fills.installed end,
})

Bars.AddTweak({
    key = STATE, card = "background", label = "Dead and offline backgrounds", type = "toggle", default = false, kinds = BACK_KINDS,
    desc = "A dead or offline player's bars get the background colors below.",
    disabled = function() return not Fills.installed end,
})

Bars.AddTweak({
    key = DEAD, card = "background", label = "Dead background", type = "color", default = DEAD_COLOR, kinds = BACK_KINDS,
    desc = "The empty part's color while a player is dead or a ghost.",
    disabled = stateOff,
})

Bars.AddTweak({
    key = OFFLINE, card = "background", label = "Offline background", type = "color", default = OFFLINE_COLOR, kinds = BACK_KINDS,
    desc = "The empty part's color while a player is offline.",
    disabled = stateOff,
})

-- Daylight UI's softness or brightness rebuilds the By value curves. A
-- many-color fill comes and goes with its color settings, so the open Frames
-- page redraws its dimmed rows (Gradients.lua's workaround).
local function settingChanged(scope, path)
    if type(path) ~= "string" then return end
    if scope == "general" and (path == "softness" or path == "brightness") then
        for k in pairs(curves) do curves[k] = nil end
    end
    if (scope == "UnitFrames" or scope == "Nameplates" or scope == "general") and path:find("[Gg]radient") then
        Grad.RedrawSoon()
    end
end

-- ---------------------------------------------------------------------
-- Effects, changes and login
-- ---------------------------------------------------------------------

-- Each look is a fill look: the bar's effects go off (Gradients.lua's
-- override). Dark leaves unit frame health alone, so its effects stay.
Grad.AddFxLook(function(scope, module, path)
    if not Fills.installed then return false end
    local c = Fills.Resolve(scope)
    if c.opacity < 1 or c.look == "light" then return true end
    return c.look == "dark" and not (module == "UnitFrames" and path:find("%.health%.") ~= nil)
end)

Grad.BeforeRepaint(function()
    forget()
    Fills.Sync()
end)

-- Checks every internal, then hooks in when a scope wears a look. Gradients.lua
-- maps the bars, so with it off this is off too.
function Fills.Start()
    if Fills.installed or Fills.broken then return end
    local missing = Grad.installed and Fills.Missing() or { "Gradients.lua's frame map" }
    if #missing > 0 then
        Fills.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": fill looks are off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    Style = DaylightUI.Style
    for _, e in ipairs(Fills.INTERNALS) do tables[e[1]] = e[3]() end
    UF, Health = tables.UF, tables.Health
    Fills.installed = true
    me.On("SettingChanged", settingChanged)
    Fills.Sync()
    if not Fills.installed then return end

    -- Frames painted before login take the saved settings now.
    for frame, scope in pairs(Grad.frameScope) do
        local p = Grad.powerScope[frame]
        if wears(Fills.Resolve(scope)) or (p and wears(Fills.Resolve(p))) then Grad.Repaint(frame) end
    end
    for bar in pairs(barScope) do
        Grad.ApplyFill(bar)
        applyBar(bar)
    end
    Grad.SyncFx()
end

me.On("Login", Fills.Start)
