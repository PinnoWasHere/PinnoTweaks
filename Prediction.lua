local addonName, ns = ...

-- Heal and absorb prediction on unit-frame health bars, per scope on the
-- Frames page: incoming heals split into yours and others', absorbs in a
-- chosen style, heal absorbs, and a glow while the shield is bigger than the
-- room for it.
--
-- While a scope wears any of these, me.Override turns Daylight UI's own heal
-- and absorb bars off on its frames, and ours draw both. Every bar sits in a
-- clip frame on the health bar's rectangle, so nothing draws outside it. Each
-- bar hangs off one edge only (a fill's moving edge, or the bar's own), never
-- between two moving edges.
--
-- Amounts come from the game's heal prediction calculator and may be secret.
-- They only reach SetMinMaxValues, SetValue and SetAlphaFromBoolean. A bar's
-- alpha rides in its color, since a status bar's fill ignores SetAlpha.
--
-- Hooks and events run only while a scope wears a prediction look. Every
-- Daylight UI internal used is checked at login; with one missing, nothing is
-- installed and the rows stay dimmed.

local API = DaylightUI.API
local Bars, Grad = ns.Bars, ns.Gradients
local me = API.For(addonName)

local Pred = { installed = false }
ns.Prediction = Pred

local HEALS, MINE, OTHERS = "predHeals", "predHealColor", "predOtherColor"
local ABSORB, ABSORB_COLOR, OVER_COLOR = "predAbsorb", "predAbsorbColor", "predOverColor"
local HEAL_ABSORB, HEAL_ABSORB_COLOR, GLOW = "predHealAbsorb", "predHealAbsorbColor", "predGlow"
Pred.HEALS, Pred.MINE, Pred.OTHERS = HEALS, MINE, OTHERS
Pred.ABSORB, Pred.ABSORB_COLOR, Pred.OVER_COLOR = ABSORB, ABSORB_COLOR, OVER_COLOR
Pred.HEAL_ABSORB, Pred.HEAL_ABSORB_COLOR, Pred.GLOW = HEAL_ABSORB, HEAL_ABSORB_COLOR, GLOW

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- As Grad.INTERNALS: { owner, name, table getter, module?, type? }.
local core, modNs = Grad.Core, Grad.ModNs
local ufTable = modNs("UnitFrames", "UF")
Pred.INTERNALS = {
    { "Style", "Bar", core("Style") },
    { "Style", "BarBack", core("Style") },
    { "Style", "AngleFill", core("Style") },
    { "Style", "GetFillAngle", core("Style") },
    { "Style", "ClipLike", core("Style") },
    { "Style", "SameMasks", core("Style") },
    { "UF", "ShieldTexture", ufTable },
    { "UF", "PREDICTION", ufTable, nil, "table" },
    { "UF", "OVERSHIELD", ufTable, nil, "table" },
    { "UF", "HEAL_OVERFLOW", ufTable, nil, "number" },
}

-- The fields read inside UF.PREDICTION and UF.OVERSHIELD, with their types.
local function field(path, kind)
    return function()
        local t = ufTable()
        for part in path:gmatch("[^.]+") do
            if type(t) ~= "table" then return false end
            t = t[part]
        end
        return type(t) == kind
    end
end
Pred.FIELDS = {
    { "UF.PREDICTION.heals.alpha", field("PREDICTION.heals.alpha", "number") },
    { "UF.PREDICTION.absorbs.alpha", field("PREDICTION.absorbs.alpha", "number") },
    { "UF.OVERSHIELD.stripes", field("OVERSHIELD.stripes", "string") },
    { "UF.OVERSHIELD.glow", field("OVERSHIELD.glow", "string") },
    { "UF.OVERSHIELD.alpha", field("OVERSHIELD.alpha", "number") },
    { "UF.OVERSHIELD.glowWidth", field("OVERSHIELD.glowWidth", "number") },
}

function Pred.Missing()
    local out = Grad.MissingIn(Pred.INTERNALS)
    if #out == 0 then
        for _, f in ipairs(Pred.FIELDS) do
            if not f[2]() then out[#out + 1] = f[1] end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Settings, read once per change
-- ---------------------------------------------------------------------

local INK = API.Colors()
local function rgb(c) return { c[1], c[2], c[3] } end
local function isColor(v)
    return type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number"
end

-- A Daylight UI unit-frame color's shipped default, copied at load (look.md,
-- 2026-11-26). The .toc's OptionalDeps loads the unit frames first.
local function ufDefault(key)
    local mod = DaylightUI:GetModule("UnitFrames")
    local d = mod and type(mod.ns) == "table" and type(mod.ns.DEFAULTS) == "table" and mod.ns.DEFAULTS.colors
    local c = type(d) == "table" and d[key]
    return isColor(c) and rgb(c) or rgb(INK.TEXT)
end

local DEFAULTS = {
    [MINE] = ufDefault("healColor"),
    [OTHERS] = rgb(INK.GOOD),
    [ABSORB_COLOR] = ufDefault("absorbColor"),
    [OVER_COLOR] = ufDefault("overshieldColor"),
    [HEAL_ABSORB_COLOR] = rgb(INK.BAD),
}
Pred.DEFAULTS = DEFAULTS

local function color(v, key) return isColor(v) and v or DEFAULTS[key] end

-- Unit-frame health scopes only. Nameplates keep Daylight UI's prediction.
Pred.SCOPES = { all = true, player = true, target = true, focus = true, pet = true, party = true, raid = true,
    arena = true }

-- Each scope's Daylight UI frame pages, whose predictHeals and predictAbsorbs
-- are overridden while it wears a look. Look's covers frames with no
-- scope of their own.
Pred.KEYS = {
    player = { "player" }, target = { "target" }, focus = { "focus" }, pet = { "pet", "partyPet" },
    arena = { "arena" }, party = { "party" }, raid = { "raid", "raid20", "raid40" },
    all = { "targettarget", "focustarget", "partyTarget" },
}

local STYLES = { daylight = true, normal = true, reversed = true, start = true }

local glowValues, glowOrder = { off = "Off" }, { "off" }
for _, s in ipairs(API.GlowStyles()) do
    if type(s) == "table" and type(s.key) == "string" and s.key ~= "off" then
        glowValues[s.key] = s.label or s.key
        glowOrder[#glowOrder + 1] = s.key
    end
end

local looks = {}
local readFrom

local function forget()
    for k in pairs(looks) do looks[k] = nil end
    readFrom = nil
end

-- A scope's look. worn: any piece differs from Daylight UI's. A profile
-- switch replaces the settings table, which empties the cache.
function Pred.Resolve(scope)
    local now = API.GetSetting(Bars.MODULE, "bars")
    if now ~= readFrom then
        forget()
        readFrom = now
    end
    local c = looks[scope]
    if not c then
        local absorb = Bars.Get(scope, ABSORB)
        local glow = Bars.Get(scope, GLOW)
        c = {
            split = Bars.Get(scope, HEALS) == "split",
            mine = color(Bars.Get(scope, MINE), MINE),
            others = color(Bars.Get(scope, OTHERS), OTHERS),
            absorb = STYLES[absorb] and absorb or "daylight",
            absorbColor = color(Bars.Get(scope, ABSORB_COLOR), ABSORB_COLOR),
            overColor = color(Bars.Get(scope, OVER_COLOR), OVER_COLOR),
            healAbsorb = Bars.Get(scope, HEAL_ABSORB) == true,
            healAbsorbColor = color(Bars.Get(scope, HEAL_ABSORB_COLOR), HEAL_ABSORB_COLOR),
            glow = (type(glow) == "string" and glowValues[glow] and glow ~= "off") and glow or nil,
        }
        c.worn = c.split or c.absorb ~= "daylight" or c.healAbsorb or c.glow ~= nil
        looks[scope] = c
    end
    return c
end

-- ---------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------

local Style, UF -- Daylight UI's Style and UF, set at login
local barScope, barFrame, barPart = Grad.barScope, Grad.barFrame, Grad.barPart
local frameUnit, framePreview, frameKind = Grad.frameUnit, Grad.framePreview, Grad.frameKind

local UNIT_KINDS = { unit = true, party = true, raid = true, partypet = true }
local GROUP_KINDS = { party = true, raid = true }

local function weak() return setmetatable({}, { __mode = "k" }) end
local partsOf = weak()  -- health bar -> its pieces
local wearing = weak()  -- health bar -> its resolved look while worn
local calcOf = weak()   -- health bar -> its heal prediction calculator
local overflowOf = weak() -- calculator -> the overflow it was given
local wedgeOf = weak()  -- piece -> its wedge bar
local Wedge = weak()    -- wedge -> true
Pred.partsOf, Pred.wedgeOf, Pred.calcOf = partsOf, wedgeOf, calcOf

function Pred.Wears(bar) return wearing[bar] ~= nil end

local function uf(path) return API.GetSetting("UnitFrames", path) end

-- Real units' bars, filed by unit for the game events.
local byUnit = {}
local filed = weak()

local function file(bar, u)
    local was = filed[bar]
    if was == u then return end
    if was and byUnit[was] then byUnit[was][bar] = nil end
    if u then
        local set = byUnit[u]
        if not set then
            set = weak()
            byUnit[u] = set
        end
        set[bar] = true
    end
    filed[bar] = u
end

-- A sample frame's own data (test mode, the options preview), or nil.
local function sampleOf(frame)
    local t = frame and frame.test
    return type(t) == "table" and t or nil
end

-- A real unit's bar, or nil for a sample frame or a frame with no unit now.
local function unitOf(bar)
    local frame = barFrame[bar]
    if framePreview[frame] or sampleOf(frame) then return nil end
    return frameUnit[frame] or nil
end

-- ---------------------------------------------------------------------
-- The pieces
-- ---------------------------------------------------------------------

-- how: "chain" hangs off the previous fill's moving edge; "lead" runs back
-- over the fill from its moving edge; "start" runs from the bar's own start;
-- "end" runs back from the bar's far end.
local PIECES = {
    mine = { heal = true, how = "chain" },
    others = { heal = true, how = "chain" },
    absorb = { how = "chain" },
    over = { how = "end", line = true },
    rev = { how = "lead" },
    revTwin = { how = "lead" },
    start = { how = "start" },
    startTwin = { how = "start" },
    healAbsorb = { how = "lead" },
}
local ORDER = { "mine", "others", "absorb", "over", "rev", "revTwin", "start", "startTwin", "healAbsorb" }
Pred.PIECES = PIECES

local function zero(s)
    s:SetMinMaxValues(0, 1)
    s:SetValue(0)
end

-- A heal bar is Daylight UI's own seamless bar; a shield bar takes the game's
-- stripes, as Daylight UI's absorbs do.
local function newBar(clip, heal)
    local s
    if heal then
        s = Style.Bar(clip, "seamless")
        Style.BarBack(s):Hide()
    else
        s = CreateFrame("StatusBar", nil, clip)
        s:SetStatusBarTexture(UF.OVERSHIELD.stripes)
    end
    zero(s)
    return s
end

local function piece(p, key)
    local s = p[key]
    if s then return s end
    local def = PIECES[key]
    s = newBar(p.clip, def.heal)
    local fill = p.bar:GetStatusBarTexture()
    Style.ClipLike(s:GetStatusBarTexture(), fill)
    if def.how == "chain" then
        local w = newBar(p.clip, def.heal)
        w.mask = w:CreateMaskTexture()
        w:GetStatusBarTexture():AddMaskTexture(w.mask)
        Style.ClipLike(w:GetStatusBarTexture(), fill)
        w:Hide()
        wedgeOf[s], Wedge[w] = w, true
    end
    if def.line then
        s.line = s:CreateTexture(nil, "OVERLAY")
        s.line:SetTexture(UF.OVERSHIELD.glow)
        s.line:SetBlendMode("ADD")
        Style.ClipLike(s.line, fill)
    end
    s:Hide()
    p[key] = s
    return s
end

local function make(bar)
    local clip = CreateFrame("Frame", nil, bar:GetParent())
    clip:SetAllPoints(bar)
    clip:SetClipsChildren(true)
    local p = { bar = bar, clip = clip }
    -- The glow: a gate whose alpha follows the over-shield flag, and a strip
    -- at the bar's far end that wears the glow or the static line.
    p.gate = CreateFrame("Frame", nil, clip)
    p.gate:SetAllPoints(clip)
    p.strip = CreateFrame("Frame", nil, p.gate)
    p.strip.line = p.strip:CreateTexture(nil, "OVERLAY")
    p.strip.line:SetAllPoints(p.strip)
    p.strip.line:SetTexture(UF.OVERSHIELD.glow)
    p.strip.line:SetBlendMode("ADD")
    p.strip.line:Hide()
    p.gate:Hide()
    -- The clip has the bar's size, so bars as long as the health bar follow it.
    clip:SetScript("OnSizeChanged", function(_, w, h) Pred.Resize(p, w, h) end)
    partsOf[bar] = p
    return p
end

-- ---------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------

local function plain(v) return type(v) == "number" and not (issecretvalue and issecretvalue(v)) end

-- The two corners of an edge: TOP/BOTTOM of LEFT or RIGHT, or LEFT/RIGHT of
-- TOP or BOTTOM on an upright bar.
local function corners(edge, upright)
    if upright then return edge .. "LEFT", edge .. "RIGHT" end
    return "TOP" .. edge, "BOTTOM" .. edge
end

-- Every piece that runs from an edge is as long as the health bar.
function Pred.Resize(p, w, h)
    local long = p.upright and h or w
    if not plain(long) then return end
    for _, key in ipairs(ORDER) do
        local s = p[key]
        local how = PIECES[key].how
        if s and (how == "chain" or how == "lead") then
            if p.upright then s:SetHeight(long) else s:SetWidth(long) end
        end
    end
end

-- Lays one chained piece off anchor's moving edge, with its wedge.
local function chain(p, s, anchor, g)
    s:ClearAllPoints()
    s:SetPoint(g.b1, anchor, g.l1)
    s:SetPoint(g.b2, anchor, g.l2)
    s:SetReverseFill(g.rev)
    Style.AngleFill(s, g.side, g.cut, g.under)
    -- A wedge fills the triangle between the previous fill's angled edge and
    -- this piece's square start. Its range is 0..1, so any amount fills it and
    -- none empties it.
    local w = wedgeOf[s]
    if g.cut > 0 and not g.under then
        w:ClearAllPoints()
        w:SetPoint(g.l1, anchor, g.l1)
        w:SetPoint(g.l2, anchor, g.l2)
        w:SetWidth(g.cut)
        w:SetOrientation("HORIZONTAL")
        local trail = g.side == "left" and "mask-trail-l.png" or "mask-trail-r.png"
        w.mask:SetTexture(API.Media(trail), "CLAMP", "CLAMP") -- look-ok: Daylight UI's own trail mask, by API.Media
        w.mask:ClearAllPoints()
        w.mask:SetPoint(g.b1, w, g.b1)
        w.mask:SetPoint(g.b2, w, g.b2)
        w.mask:SetWidth(4 * g.cut)
        w.on = true
    else
        w.on = false
        w:Hide()
    end
end

-- A piece over the fill, from its moving edge back toward the bar's start.
-- It wears the fill's own masks, so its start leans with the fill's end.
local function lead(p, s, g)
    local fill = p.bar:GetStatusBarTexture()
    s:ClearAllPoints()
    s:SetPoint(g.l1, fill, g.l1)
    s:SetPoint(g.l2, fill, g.l2)
    s:SetReverseFill(not g.rev)
    Style.SameMasks(s:GetStatusBarTexture(), fill)
end

-- The pieces' places, from the health bar's orientation, fill direction and
-- angled end. Nothing reads a size or place of a piece or a fill.
local geo = {}
local function lay(bar, c)
    local p = partsOf[bar]
    local upright = bar:GetOrientation() == "VERTICAL"
    local rev = bar:GetReverseFill() == true
    local side, cut, under
    if not upright then side, cut, under = Style.GetFillAngle(bar) end
    if not (side and plain(cut) and cut > 0) then side, cut, under = nil, 0, nil end
    p.upright = upright
    local leadEdge = upright and (rev and "BOTTOM" or "TOP") or (rev and "LEFT" or "RIGHT")
    local backEdge = upright and (rev and "TOP" or "BOTTOM") or (rev and "RIGHT" or "LEFT")
    local g = geo
    g.rev, g.side, g.cut, g.under = rev, side, cut, under == true
    g.l1, g.l2 = corners(leadEdge, upright)
    g.b1, g.b2 = corners(backEdge, upright)

    -- Under Daylight UI's texts (the health bar's level + 3), as its own bars.
    local level = bar:GetFrameLevel() + 1
    p.clip:SetFrameLevel(level)
    local orientation = upright and "VERTICAL" or "HORIZONTAL"
    for _, key in ipairs(ORDER) do
        local s = p[key]
        if s then
            s:SetOrientation(orientation)
            s:SetFrameLevel(level + ((key == "over" or key == "revTwin" or key == "startTwin") and 1 or 0))
        end
    end

    -- Heals, then absorbs in the Normal or Daylight UI's style, each off the last.
    local anchor = bar:GetStatusBarTexture()
    for _, key in ipairs({ "mine", "others", "absorb" }) do
        local s = p[key]
        if s and p.want[key] then
            chain(p, s, anchor, g)
            wedgeOf[s]:SetFrameLevel(level)
            anchor = s:GetStatusBarTexture()
        end
    end
    for _, key in ipairs({ "rev", "revTwin", "healAbsorb" }) do
        if p[key] and p.want[key] then lead(p, p[key], g) end
    end
    for _, key in ipairs({ "start", "startTwin" }) do
        local s = p[key]
        if s and p.want[key] then
            s:ClearAllPoints()
            s:SetAllPoints(bar)
            s:SetReverseFill(rev)
            Style.AngleFill(s, side, cut, under)
        end
    end
    -- From the bar's far end back over the health (from its start when
    -- Daylight UI's overshield is reversed). Its line sits on its moving edge.
    local o = p.over
    if o and p.want.over then
        local fromEnd = not (c.absorb == "daylight" and uf("colors.overshieldReverse") == true)
        local back = rev ~= fromEnd
        o:ClearAllPoints()
        o:SetAllPoints(bar)
        o:SetReverseFill(back)
        local edge = upright and (back and "BOTTOM" or "TOP") or (back and "LEFT" or "RIGHT")
        local a1, a2 = corners(edge, upright)
        local fill = o:GetStatusBarTexture()
        o.line:ClearAllPoints()
        if upright then
            o.line:SetPoint("LEFT", fill, a1)
            o.line:SetPoint("RIGHT", fill, a2)
            o.line:SetHeight(UF.OVERSHIELD.glowWidth)
            o.line:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
        else
            o.line:SetPoint("TOP", fill, a1)
            o.line:SetPoint("BOTTOM", fill, a2)
            o.line:SetWidth(UF.OVERSHIELD.glowWidth)
            o.line:SetTexCoord(0, 1, 0, 1)
        end
    end
    -- The glow strip lies inside the bar along its far end.
    local strip = p.strip
    p.gate:SetFrameLevel(level + 1)
    strip:SetFrameLevel(level + 1)
    strip:ClearAllPoints()
    strip:SetPoint(g.l1, bar, g.l1)
    strip:SetPoint(g.l2, bar, g.l2)
    if upright then
        strip:SetHeight(UF.OVERSHIELD.glowWidth)
        strip.line:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
    else
        strip:SetWidth(UF.OVERSHIELD.glowWidth)
        strip.line:SetTexCoord(0, 1, 0, 1)
    end
    local w, h = p.clip:GetSize()
    Pred.Resize(p, w, h)
end
Pred.Lay = lay

-- ---------------------------------------------------------------------
-- Colors and textures
-- ---------------------------------------------------------------------

local function paint(s, c, a)
    s:SetStatusBarColor(c[1], c[2], c[3], a)
    local w = wedgeOf[s]
    if w then w:SetStatusBarColor(c[1], c[2], c[3], a) end
end

local function texture(s, file, tile)
    for _, b in ipairs({ s, wedgeOf[s] }) do
        local t = b:GetStatusBarTexture()
        t:SetTexture(file, tile and "REPEAT" or nil, tile and "REPEAT" or nil)
        if t.SetHorizTile then
            t:SetHorizTile(tile == true)
            t:SetVertTile(tile == true)
        end
    end
end

-- Which pieces a look shows.
local function wants(p, c)
    local w = p.want or {}
    p.want = w
    local daylight, normal = c.absorb == "daylight", c.absorb == "normal"
    w.mine = true
    w.others = c.split
    w.absorb = daylight or normal
    w.over = normal or (daylight and uf("colors.overshield") ~= false)
    w.rev, w.revTwin = c.absorb == "reversed", c.absorb == "reversed"
    w.start, w.startTwin = c.absorb == "start", c.absorb == "start"
    w.healAbsorb = c.healAbsorb
    return w
end

-- Daylight UI's own heal color, absorb color and over-absorb color, as its
-- Colors page sets them.
local function ufColor(key, fallback)
    local v = uf("colors." .. key)
    return isColor(v) and v or fallback
end

local function style(bar, c)
    local p = partsOf[bar]
    local want = wants(p, c)
    for _, key in ipairs(ORDER) do
        if want[key] then piece(p, key) end
    end
    local P, O = UF.PREDICTION, UF.OVERSHIELD
    local healAlpha, absorbAlpha = P.heals.alpha, P.absorbs.alpha
    if c.split then
        paint(p.mine, c.mine, healAlpha)
        paint(p.others, c.others, healAlpha)
    else
        paint(p.mine, ufColor("healColor", DEFAULTS[MINE]), healAlpha)
    end

    local file, tile = UF.ShieldTexture(uf("colors.absorbStyle"))
    local absorbColor, overColor, overFile, overTile = c.absorbColor, c.overColor, file, tile
    if c.absorb == "daylight" then
        absorbColor = ufColor("absorbColor", DEFAULTS[ABSORB_COLOR])
        overColor = uf("colors.overshieldPaint") == "custom" and ufColor("overshieldColor", absorbColor) or absorbColor
        local os = uf("colors.overshieldStyle")
        if type(os) == "string" and os ~= "shield" then overFile, overTile = UF.ShieldTexture(os) end
    end
    for _, key in ipairs({ "absorb", "rev", "start" }) do
        if want[key] then
            texture(p[key], file, tile)
            paint(p[key], absorbColor, absorbAlpha)
        end
    end
    if want.over then
        texture(p.over, overFile, overTile)
        paint(p.over, overColor, O.alpha)
        p.over.line:SetShown(c.absorb == "daylight")
    end
    for _, key in ipairs({ "revTwin", "startTwin" }) do
        if want[key] then
            texture(p[key], file, tile)
            paint(p[key], overColor, absorbAlpha)
        end
    end
    if want.healAbsorb then
        texture(p.healAbsorb, O.stripes, true)
        paint(p.healAbsorb, c.healAbsorbColor, O.alpha)
    end
    p.overColor = overColor
end

-- ---------------------------------------------------------------------
-- Amounts
-- ---------------------------------------------------------------------

-- The amounts a preview frame shows when its sample has none: Daylight UI's
-- focus sample (TestMode.lua), and half of it again for a heal absorb.
Pred.DEMO = { heals = 12, absorbs = 8, healAbsorbs = 6 }

local function num(v) return plain(v) and v or 0 end
local function amount(v)
    if type(v) == "nil" then return 0 end
    return v
end

-- The bar's calculator, made once, filled for the unit with the player as
-- the healer so the split works. nil when the client has none.
local function filled(bar, u)
    if type(CreateUnitHealPredictionCalculator) ~= "function" or type(UnitGetDetailedHealPrediction) ~= "function" then
        return nil
    end
    local calc = calcOf[bar]
    if not calc then
        calc = CreateUnitHealPredictionCalculator()
        if not calc then return nil end
        local E = Enum
        if E.UnitDamageAbsorbClampMode and calc.SetDamageAbsorbClampMode then
            calc:SetDamageAbsorbClampMode(E.UnitDamageAbsorbClampMode.MissingHealth)
        end
        if E.UnitIncomingHealClampMode and calc.SetIncomingHealClampMode then
            calc:SetIncomingHealClampMode(E.UnitIncomingHealClampMode.MissingHealth)
        end
        if E.UnitHealAbsorbClampMode and calc.SetHealAbsorbClampMode then
            calc:SetHealAbsorbClampMode(E.UnitHealAbsorbClampMode.CurrentHealth)
        end
        if E.UnitHealAbsorbMode and calc.SetHealAbsorbMode then
            calc:SetHealAbsorbMode(E.UnitHealAbsorbMode.ReducedByIncomingHeals)
        end
        calcOf[bar] = calc
    end
    -- Overheal runs past the health's end as Daylight UI's does; the clip
    -- stops it at the bar's end.
    local overflow = uf("colors.overheal") == false and 1 or UF.HEAL_OVERFLOW
    if overflowOf[calc] ~= overflow and calc.SetIncomingHealOverflowPercent then
        calc:SetIncomingHealOverflowPercent(overflow)
        overflowOf[calc] = overflow
    end
    UnitGetDetailedHealPrediction(u, "player", calc)
    return calc
end

local function put(s, max, v)
    if not s then return end
    s:SetMinMaxValues(0, max)
    s:SetValue(v)
    local w = wedgeOf[s]
    if w then
        w:SetMinMaxValues(0, 1)
        w:SetValue(v)
    end
end

-- A flag that may be secret shows a piece or hides it. No flag hides it.
local function gate(f, flag)
    if type(flag) == "nil" then f:SetAlpha(0) else f:SetAlphaFromBoolean(flag, 1, 0) end
end

-- The amounts now: a sample's plain numbers, or the calculator's for a real
-- unit. Returns max, mine, others, absorb, absorbAll, over, healAbsorb, or
-- nil when there is nothing to show.
local function amounts(bar, c)
    local frame = barFrame[bar]
    local s = sampleOf(frame)
    if s or framePreview[frame] then
        s = s or {}
        local h, a, ha = num(s.heals), num(s.absorbs), num(s.healAbsorbs)
        if framePreview[frame] and h == 0 and a == 0 then h, a, ha = Pred.DEMO.heals, Pred.DEMO.absorbs, Pred.DEMO.healAbsorbs end
        local health = plain(s.health) and s.health or 100
        local room = math.max(0, 100 - health - h)
        local mine, others = h, 0
        if c.split then mine, others = h / 2, h - h / 2 end
        return 100, mine, others, math.min(a, room), a, a > room, c.healAbsorb and math.min(ha, health) or 0
    end
    local u = unitOf(bar)
    if not u or not UnitExists(u) then return nil end
    local calc = filled(bar, u)
    local max = UnitHealthMax(u)
    if not calc then return max, amount(UnitGetIncomingHeals(u)), 0, amount(UnitGetTotalAbsorbs(u)),
        amount(UnitGetTotalAbsorbs(u)), nil, 0 end
    local total, mine, others = calc:GetIncomingHeals()
    if not c.split then mine, others = total, 0 end
    local absorb, over = calc:GetDamageAbsorbs()
    local healAbsorb = 0
    if c.healAbsorb then healAbsorb = calc:GetHealAbsorbs() end
    return max, amount(mine), amount(others), amount(absorb), amount(UnitGetTotalAbsorbs(u)), over, amount(healAbsorb)
end

-- Values into the shown pieces, and the over-shield flag into their gates.
local function update(bar)
    local c, p = wearing[bar], partsOf[bar]
    if not c then return end
    local max, mine, others, absorb, all, over, healAbsorb = amounts(bar, c)
    if max == nil then
        p.clip:Hide()
        return
    end
    p.clip:Show()
    local want = p.want
    for _, key in ipairs(ORDER) do
        local s = p[key]
        if s then
            s:SetShown(want[key] == true)
            local w = wedgeOf[s]
            if w then w:SetShown(want[key] == true and w.on == true) end
        end
    end
    put(p.mine, max, mine)
    if want.others then put(p.others, max, others) end
    if want.absorb then put(p.absorb, max, absorb) end
    if want.over then
        put(p.over, max, all)
        gate(p.over, over)
    end
    if want.rev then
        put(p.rev, max, all)
        put(p.revTwin, max, all)
        gate(p.revTwin, over)
    end
    if want.start then
        put(p.start, max, all)
        put(p.startTwin, max, all)
        gate(p.startTwin, over)
    end
    if want.healAbsorb then put(p.healAbsorb, max, healAbsorb) end
    if c.glow then gate(p.gate, over) end
end
Pred.Update = update

-- ---------------------------------------------------------------------
-- The glow
-- ---------------------------------------------------------------------

-- The chosen glow style round the strip while motion is on; with motion off,
-- the game's static overshield line in its place.
local function glowNow(bar)
    local c, p = wearing[bar], partsOf[bar]
    if not p then return end
    if not (c and c.glow) then
        API.GlowAround(p.strip, false)
        p.strip.line:Hide()
        p.gate:Hide()
        return
    end
    p.gate:Show()
    if API.MotionOn() then
        local k = p.overColor or DEFAULTS[OVER_COLOR]
        API.GlowAround(p.strip, true, { style = c.glow, r = k[1], g = k[2], b = k[3], inset = 0 })
        p.strip.line:Hide()
    else
        API.GlowAround(p.strip, false)
        p.strip.line:Show()
    end
end
Pred.Glow = glowNow

-- ---------------------------------------------------------------------
-- Wearing
-- ---------------------------------------------------------------------

local function wear(bar, c)
    if not partsOf[bar] then make(bar) end
    wearing[bar] = c
    style(bar, c)
    lay(bar, c)
    glowNow(bar)
    update(bar)
end

local function unwear(bar)
    if not wearing[bar] then return end
    wearing[bar] = nil
    local p = partsOf[bar]
    glowNow(bar)
    p.clip:Hide()
end

-- After a mapping, a unit change or a setting change: the bar's prediction now.
local function apply(bar)
    if not Pred.installed then return end
    local scope = barScope[bar]
    if not (scope and Pred.SCOPES[scope] and barPart[bar] == "health" and UNIT_KINDS[frameKind[barFrame[bar]]]) then
        return
    end
    local c = Pred.Resolve(scope)
    if c.worn then wear(bar, c) else unwear(bar) end
    file(bar, c.worn and unitOf(bar) or nil)
end
Pred.Apply = apply
Grad.OnBar(apply)

-- ---------------------------------------------------------------------
-- Overrides
-- ---------------------------------------------------------------------

local held = {}   -- "frame.setting" -> the Override handle, or false when refused
local wanted = {} -- reused each sync
local PREDICT = { "predictHeals", "predictAbsorbs" }

-- Holds Daylight UI's own prediction off on every frame page whose scope
-- wears a look, and lets go of the rest.
function Pred.SyncOverrides()
    for k in pairs(wanted) do wanted[k] = nil end
    if Pred.installed and API.IsModuleEnabled("UnitFrames") then
        for scope, keys in pairs(Pred.KEYS) do
            if Pred.Resolve(scope).worn then
                for _, key in ipairs(keys) do
                    for _, s in ipairs(PREDICT) do
                        local path = key .. "." .. s
                        if held[path] ~= nil or type(uf(path)) == "boolean" then wanted[path] = true end
                    end
                end
            end
        end
    end
    for path, h in pairs(held) do
        if not wanted[path] then
            held[path] = nil
            if h then API.Off(h) end
        end
    end
    for path in pairs(wanted) do
        if held[path] == nil then held[path] = me.Override("UnitFrames", path, false) or false end
    end
end

function Pred.Overriding() return next(held) ~= nil end

-- ---------------------------------------------------------------------
-- Hooks and events
-- ---------------------------------------------------------------------

-- Style.AngleFill: a health bar laid out again takes a new angled end.
local function afterAngle(bar)
    local c = wearing[bar]
    if c then lay(bar, c) end
end

-- { owner, name, fn }
Pred.HOOKS = {
    { "Style", "AngleFill", afterAngle },
}
local handles = {}

local function unhookAll()
    for i = #handles, 1, -1 do
        me.Unhook(handles[i])
        handles[i] = nil
    end
end

local function hookAll()
    for _, h in ipairs(Pred.HOOKS) do
        local handle = me.Hook(DaylightUI[h[1]], h[2], h[3])
        if not handle then
            unhookAll()
            return false, h[1] .. "." .. h[2]
        end
        handles[#handles + 1] = handle
    end
    return true
end

Pred.EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_HEAL_PREDICTION", "UNIT_ABSORB_AMOUNT_CHANGED",
    "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" }

-- Party and raid tiles read once per frame: a heal landing sends several
-- events at once, and 40 tiles get hundreds a second.
local due, armed = weak(), false
local function flush()
    armed = false
    for bar in pairs(due) do
        due[bar] = nil
        update(bar)
    end
end

local function soon(bar)
    if not GROUP_KINDS[frameKind[barFrame[bar]]] then return update(bar) end
    due[bar] = true
    if armed then return end
    armed = true
    C_Timer.After(0, flush)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, _, unit)
    local set = byUnit[unit]
    if not set then return end
    for bar in pairs(set) do
        if frameUnit[barFrame[bar]] == unit then soon(bar) end
    end
end)

local listening = false
local function listen(on)
    if on == listening then return end
    listening = on
    for _, e in ipairs(Pred.EVENTS) do
        if on then events:RegisterEvent(e) else events:UnregisterEvent(e) end
    end
end

local function anyWorn()
    for _, s in ipairs(Bars.SCOPES) do
        if Pred.SCOPES[s.key] and Pred.Resolve(s.key).worn then return true end
    end
    return false
end

-- The hook and events are on while some scope wears a look.
function Pred.Sync()
    if not Pred.installed then return end
    local any = anyWorn()
    if any and #handles == 0 then
        local ok, name = hookAll()
        if not ok then
            Pred.installed = false
            Pred.broken = { name }
            listen(false)
            Pred.SyncOverrides()
            DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": heal and absorb bars are off. Daylight UI refused a hook on "
                .. name .. ".")
            return
        end
    elseif not any and #handles > 0 then
        unhookAll()
    end
    listen(any)
    Pred.SyncOverrides()
end

function Pred.Hooked() return #handles > 0 end
function Pred.Listening() return listening end

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------

local KINDS = { "unit", "party", "raid", "partypet" }
local function only(scope) return Pred.SCOPES[scope] == true end

-- The rows read the settings live: Daylight UI redraws the page before
-- PinnoTweaks hears a change.
local function off() return not Pred.installed end
local function get(scope, key) return Bars.Get(scope, key) end
local function absorbOff(scope)
    local v = get(scope, ABSORB)
    return off() or v == nil or v == "daylight"
end

Bars.AddTweak({
    key = HEALS, card = "prediction", label = "Incoming heals", type = "dropdown", default = "daylight", kinds = KINDS, only = only,
    values = { daylight = "Daylight UI's", split = "Yours and others'" }, order = { "daylight", "split" },
    desc = "Yours and others' shows heals on the way as two bars, yours first. Any heal or absorb look here other than Daylight UI's draws this frame's heal and absorb bars itself, inside the health bar.",
    disabled = off,
})

Bars.AddTweak({
    key = MINE, card = "prediction", label = "Your heals", type = "color", default = DEFAULTS[MINE], kinds = KINDS, only = only,
    desc = "The color of your own heals on the way.",
    disabled = function(scope) return off() or get(scope, HEALS) ~= "split" end,
})

Bars.AddTweak({
    key = OTHERS, card = "prediction", label = "Others' heals", type = "color", default = DEFAULTS[OTHERS], kinds = KINDS, only = only,
    desc = "The color of other players' heals on the way.",
    disabled = function(scope) return off() or get(scope, HEALS) ~= "split" end,
})

Bars.AddTweak({
    key = ABSORB, card = "prediction", label = "Absorb style", type = "dropdown", default = "daylight", kinds = KINDS, only = only,
    values = { daylight = "Daylight UI's", normal = "Normal", reversed = "Reversed", start = "From start" },
    order = { "daylight", "normal", "reversed", "start" },
    desc = "Normal shows the shield after the heals. Reversed runs it back from the health's end over the health. From start runs the whole shield from the bar's start. Nothing draws outside the health bar.",
    disabled = off,
})

Bars.AddTweak({
    key = ABSORB_COLOR, card = "prediction", label = "Absorb color", type = "color", default = DEFAULTS[ABSORB_COLOR], kinds = KINDS,
    only = only, desc = "The shield's color.",
    disabled = absorbOff,
})

Bars.AddTweak({
    key = OVER_COLOR, card = "prediction", label = "Over-absorb color", type = "color", default = DEFAULTS[OVER_COLOR], kinds = KINDS,
    only = only, desc = "The shield's color while it is bigger than the health missing.",
    disabled = absorbOff,
})

Bars.AddTweak({
    key = HEAL_ABSORB, card = "prediction", label = "Heal absorbs", type = "toggle", default = false, kinds = KINDS, only = only,
    desc = "Shows effects that eat incoming healing as a striped bar back over the end of the health.",
    disabled = off,
})

Bars.AddTweak({
    key = HEAL_ABSORB_COLOR, card = "prediction", label = "Heal absorb color", type = "color", default = DEFAULTS[HEAL_ABSORB_COLOR],
    kinds = KINDS, only = only, desc = "The color of the heal absorb stripes.",
    disabled = function(scope) return off() or get(scope, HEAL_ABSORB) ~= true end,
})

Bars.AddTweak({
    key = GLOW, card = "prediction", label = "Absorb glow", type = "dropdown", default = "off", kinds = KINDS, only = only,
    values = glowValues, order = glowOrder,
    desc = "A glow at the bar's end while the shield is bigger than the health missing. With Daylight UI's motion off, the game's still overshield line shows instead.",
    disabled = off,
})

-- ---------------------------------------------------------------------
-- Changes and login
-- ---------------------------------------------------------------------

Grad.BeforeRepaint(function()
    forget()
    Pred.Sync()
end)

-- Motion on or off swaps the glow and the still line.
local function settingChanged(scope, path)
    if scope == "general" and path == "motion" then
        for bar in pairs(wearing) do glowNow(bar) end
    end
end

-- Checks every internal, then hooks in when a scope wears a look.
-- Gradients.lua maps the bars, so with it off this is off too. With the unit
-- frames off there are no bars, and the rows stay dimmed.
function Pred.Start()
    if Pred.installed or Pred.broken then return end
    if not API.IsModuleEnabled("UnitFrames") then return end
    local missing = Grad.installed and Pred.Missing() or { "Gradients.lua's frame map" }
    if #missing > 0 then
        Pred.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": heal and absorb bars are off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    Style, UF = DaylightUI.Style, ufTable()
    Pred.installed = true
    me.On("SettingChanged", settingChanged)
    Pred.Sync()
    if not Pred.installed then return end
    for bar in pairs(barScope) do apply(bar) end
end

me.On("Login", Pred.Start)
