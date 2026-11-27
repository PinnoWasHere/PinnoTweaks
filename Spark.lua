local addonName, ns = ...

-- The spark: a soft light on the moving end of a bar's fill, for each frame on
-- the Frames page. It takes a paler copy of the bar's own colors (Tint.lua) or
-- a picked color, and hides at full, at empty, and on a cast bar between casts.
--
-- Our crisp spark art lies across the fill's moving edge, its bright core on
-- the edge and its halo either side. It is anchored to that one edge only, so
-- no two moving edges can cross, and runs the edge's full length. It never
-- reads a size or position. It wears the bar's clipped ends and rectangle (not the fill's angled edge, which would
-- cut its outer half), and leans with an angled end.
--
-- A client curve on the unit's health or power percent gives its alpha, so a
-- secret value is never read. A swing bar (Swing.lua) has no unit and plain
-- values: a driver checks them while one wears the spark. A white ADD lift over it pales it, as the
-- ghost's does.
--
-- Hooks and events run only while a scope wears the spark. Every Daylight UI
-- internal used is checked at login; with one missing, nothing is installed.

local API = DaylightUI.API
local Bars, Grad, Tint = ns.Bars, ns.Gradients, ns.Tint
local me = API.For(addonName)

local Spark = { installed = false }
ns.Spark = Spark

local SPARK, MODE, COLOR = "spark", "sparkColorMode", "sparkColor"
Spark.SPARK, Spark.MODE, Spark.COLOR = SPARK, MODE, COLOR

-- Our own spark art (look.md "Spark art revised", owner-approved 2026-11-25).
Spark.ART = "Interface\\AddOns\\" .. addonName .. "\\Media\\spark-crisp.tga"
-- Its width across the edge, in UI units: fixed.
Spark.THICK = 12
-- The bar's rectangle as a mask, never drawn.
local WHITE = "Interface\\Buttons\\WHITE8x8" -- look-ok: a mask texture, never drawn
-- Over the fill and our layers on it: breakpoint 2, light 3, fill texture 4.
local SUB = 5
-- The curve's ramp at each end: shown from just above empty to just below full.
local EDGE = 0.001
local LIFT = Tint.LIFT

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- As Grad.INTERNALS. Tint.lua's are checked too (Spark.Missing).
local core = Grad.Core
Spark.INTERNALS = {
    { "Style", "GetFillMask", core("Style") },
    { "Style", "GetFillAngle", core("Style") },
    { "Style", "AngleFill", core("Style") },
}

function Spark.Missing()
    local out = Grad.MissingIn(Spark.INTERNALS)
    for _, name in ipairs(Tint.Missing()) do out[#out + 1] = name end
    return out
end

-- ---------------------------------------------------------------------
-- Settings, read once per change
-- ---------------------------------------------------------------------

local INK = API.Colors()
local COLOR_DEFAULT = { INK.TEXT[1], INK.TEXT[2], INK.TEXT[3] }

local looks = {}
local readFrom

local function forget()
    for k in pairs(looks) do looks[k] = nil end
    readFrom = nil
end

local function color(v)
    if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
        return v
    end
    return COLOR_DEFAULT
end

-- A scope's look. A profile switch replaces the settings table, which empties
-- the cache.
function Spark.Resolve(scope)
    local now = API.GetSetting(Bars.MODULE, "bars")
    if now ~= readFrom then
        forget()
        readFrom = now
    end
    local c = looks[scope]
    if not c then
        c = {
            on = Bars.Get(scope, SPARK) == true,
            custom = Bars.Get(scope, MODE) == "custom",
            color = color(Bars.Get(scope, COLOR)),
        }
        looks[scope] = c
    end
    return c
end

-- ---------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------

local Style -- Daylight UI's Style, set at login
local barScope, barFrame, barPart = Grad.barScope, Grad.barFrame, Grad.barPart
local frameUnit, framePreview, frameKind = Grad.frameUnit, Grad.framePreview, Grad.frameKind

local function weak() return setmetatable({}, { __mode = "k" }) end
local sparkOf = weak() -- bar -> the spark texture
local liftOf = weak()  -- bar -> the white lift over it
local wearing = weak() -- bar -> its resolved look while it wears a spark
Spark.sparkOf, Spark.liftOf = sparkOf, liftOf

function Spark.Wears(bar) return wearing[bar] ~= nil end

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

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- A real unit's bar, or nil for a sample frame or a frame with no unit now.
local function unitOf(bar)
    local frame = barFrame[bar]
    if framePreview[frame] then return nil end
    return frameUnit[frame] or nil
end

-- A sample bar's value and range, plain numbers only, else nil.
local function sample(bar)
    local v = bar:GetValue()
    local lo, hi = bar:GetMinMaxValues()
    if secret(v) or secret(lo) or secret(hi) then return nil end
    if type(v) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then return nil end
    return v, lo, hi
end

-- 0 at empty and at full, peak between, in straight lines.
local function edgeCurve(peak)
    if not (C_CurveUtil and C_CurveUtil.CreateCurve) then return nil end
    local c = C_CurveUtil.CreateCurve()
    if not c then return nil end
    if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Linear) end
    c:AddPoint(0, 0)
    c:AddPoint(EDGE, peak)
    c:AddPoint(1 - EDGE, peak)
    c:AddPoint(1, 0)
    return c
end
local sparkCurve, liftCurve -- made at login

-- Is the unit casting or channeling? Only whether an answer came is tested.
-- With no cast the client returns nothing, so each answer goes into a local.
local function casting(u)
    local cast = UnitCastingInfo(u)
    if type(cast) ~= "nil" then return true end
    local channel = UnitChannelInfo(u)
    return type(channel) ~= "nil"
end

-- ---------------------------------------------------------------------
-- The spark
-- ---------------------------------------------------------------------

local rectOf = weak() -- bar -> its rectangle as a mask, for the spark
Spark.rectOf = rectOf

local function make(bar)
    local s = bar:CreateTexture(nil, "ARTWORK", nil, SUB)
    local l = bar:CreateTexture(nil, "ARTWORK", nil, SUB + 1)
    for _, t in ipairs({ s, l }) do
        t:SetTexture(Spark.ART, "CLAMP", "CLAMP")
        t:SetBlendMode("ADD")
        t:Hide()
    end
    local m = bar:CreateMaskTexture()
    -- Clamped to black, so nothing shows past the bar.
    m:SetTexture(WHITE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(bar)
    sparkOf[bar], liftOf[bar], rectOf[bar] = s, l, m
end

-- The spark's masks: the bar's rectangle and the fill's other masks (the
-- bar's clipped ends), not the fill's angled edge. A texture takes three.
local want = {}
local function mask(bar, t)
    local fill, edge = bar:GetStatusBarTexture(), Style.GetFillMask(bar)
    for k in pairs(want) do want[k] = nil end
    want[rectOf[bar]] = true
    local n = 1
    for i = 1, fill:GetNumMaskTextures() do
        local m = fill:GetMaskTexture(i)
        if m and m ~= edge and not want[m] and n < 3 then
            want[m] = true
            n = n + 1
        end
    end
    for i = t:GetNumMaskTextures(), 1, -1 do
        local m = t:GetMaskTexture(i)
        if m and not want[m] then t:RemoveMaskTexture(m) elseif m then want[m] = false end
    end
    for m, add in pairs(want) do
        if add then t:AddMaskTexture(m) end
    end
end

-- Vertex indices: upper left 1, lower left 2, upper right 3, lower right 4.
local UPPER, LOWER = { 1, 3 }, { 2, 4 }

-- On an angled end the corners on its trailing side move back by the cut, so
-- the spark lies along the end.
local function lean(t, reverse, cut, under)
    local dx = (reverse and 1 or -1) * cut
    local moved, still = under and UPPER or LOWER, under and LOWER or UPPER
    for i = 1, 2 do
        t:SetVertexOffset(moved[i], dx, 0)
        t:SetVertexOffset(still[i], 0, 0)
    end
end

-- Lays the spark across the fill's moving edge, its core on the edge, from one
-- end of the edge to the other with no inset: right (left when reversed), or
-- top (bottom when reversed) on an upright bar. The art's whole length is used.
local function lay(bar)
    local fill = bar:GetStatusBarTexture()
    local upright = bar:GetOrientation() == "VERTICAL"
    local reverse = bar:GetReverseFill() == true
    for _, t in ipairs({ sparkOf[bar], liftOf[bar] }) do
        t:ClearAllPoints()
        if upright then
            local edge = reverse and "BOTTOM" or "TOP"
            t:SetPoint("LEFT", fill, edge .. "LEFT")
            t:SetPoint("RIGHT", fill, edge .. "RIGHT")
            t:SetHeight(Spark.THICK)
            -- The art's long side runs along the edge.
            t:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
            lean(t, reverse, 0, false)
        else
            local edge = reverse and "LEFT" or "RIGHT"
            t:SetPoint("TOP", fill, "TOP" .. edge)
            t:SetPoint("BOTTOM", fill, "BOTTOM" .. edge)
            t:SetWidth(Spark.THICK)
            t:SetTexCoord(0, 1, 0, 1)
            local _, cut, under = Style.GetFillAngle(bar)
            lean(t, reverse, cut or 0, under == true)
        end
        mask(bar, t)
    end
end
Spark.Lay = lay

-- The spark's alpha now, and its lift's (nil: no lift). A real unit's comes
-- from the curve (health or power) or whether it casts; a sample or a swing
-- bar compares its own plain value. nil: hidden.
local function alphas(bar, c)
    local u = unitOf(bar)
    local part = barPart[bar]
    local lifted = not c.custom
    if u and part == "bar" then
        if not casting(u) then return nil end
        return 1, lifted and LIFT or nil
    end
    if u then
        if not sparkCurve then return nil end
        if part == "power" then
            return UnitPowerPercent(u, nil, false, sparkCurve),
                lifted and UnitPowerPercent(u, nil, false, liftCurve) or nil
        end
        return UnitHealthPercent(u, true, sparkCurve), lifted and UnitHealthPercent(u, true, liftCurve) or nil
    end
    local v, lo, hi
    local f = barFrame[bar]
    if framePreview[f] or frameKind[f] == "swing" then v, lo, hi = sample(bar) end
    if not (v and v > lo and v < hi) then return nil end
    return 1, lifted and LIFT or nil
end

-- The spark now: its color (the picked one, or the bar's own at its moving
-- end) carries its alpha, and SetAlpha sets the same alpha after, so neither a
-- color nor an alpha written alone can show it at full. The lift keeps its
-- art's own white.
local function update(bar)
    local c, s, l = wearing[bar], sparkOf[bar], liftOf[bar]
    if not c then return end
    local a, la = alphas(bar, c)
    if a == nil then
        s:Hide()
        l:Hide()
        return
    end
    if c.custom then
        local k = c.color
        s:SetVertexColor(k[1], k[2], k[3], a)
    else
        Tint.Paint(bar, s, a, COLOR_DEFAULT, true)
    end
    s:SetAlpha(a)
    s:Show()
    if la ~= nil then
        l:SetAlpha(la)
        l:Show()
    else
        l:Hide()
    end
end
Spark.Update = update
Tint.OnChange(SPARK, update)

local function sparkOn(bar, c)
    if not sparkOf[bar] then make(bar) end
    wearing[bar] = c
    Tint.Follow(bar, SPARK)
    lay(bar)
    update(bar)
end

-- Swing bars move every frame and send no event, so a driver checks each worn
-- one's plain value and updates its spark only when it crosses empty or full.
local ticking = weak() -- swing bar -> whether its spark showed at the last check
Spark.ticking = ticking

local function between(bar)
    if not bar:IsVisible() then return false end
    local v, lo, hi = sample(bar)
    return v ~= nil and v > lo and v < hi
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function()
    for bar, was in pairs(ticking) do
        local now = between(bar)
        if now ~= was then
            ticking[bar] = now
            update(bar)
        end
    end
end)
Spark.driver = driver

local function tick(bar, on)
    if on then ticking[bar] = between(bar) else ticking[bar] = nil end
    driver:SetShown(next(ticking) ~= nil)
end

local function sparkOff(bar)
    if not wearing[bar] then return end
    wearing[bar] = nil
    Tint.Unfollow(bar, SPARK)
    sparkOf[bar]:Hide()
    liftOf[bar]:Hide()
end

-- After a mapping, a unit change or a setting change: the bar's spark now.
local function apply(bar)
    if not Spark.installed then return end
    local scope = barScope[bar]
    if not scope then return end
    local c = Spark.Resolve(scope)
    if c.on then sparkOn(bar, c) else sparkOff(bar) end
    file(bar, c.on and unitOf(bar) or nil)
    if frameKind[barFrame[bar]] == "swing" then tick(bar, c.on) end
end
Spark.Apply = apply
Grad.OnBar(apply)

-- ---------------------------------------------------------------------
-- Hooks and events
-- ---------------------------------------------------------------------

-- Style.AngleFill: a bar laid out again takes a new angled end.
local function afterAngle(bar)
    if wearing[bar] then lay(bar) end
end

-- { owner, name, fn }. The bar's colors come through Tint.lua's hooks.
Spark.HOOKS = {
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
    for _, h in ipairs(Spark.HOOKS) do
        local handle = me.Hook(DaylightUI[h[1]], h[2], h[3])
        if not handle then
            unhookAll()
            return false, h[1] .. "." .. h[2]
        end
        handles[#handles + 1] = handle
    end
    return true
end

-- Each event and the bar part it moves.
local PART_EVENTS = {
    health = { "UNIT_HEALTH", "UNIT_MAXHEALTH" },
    power = { "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER" },
    bar = { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
        "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_EMPOWER_START",
        "UNIT_SPELLCAST_EMPOWER_STOP" },
}
local PART_OF = {}
for part, list in pairs(PART_EVENTS) do
    for _, e in ipairs(list) do PART_OF[e] = part end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, unit)
    local set = byUnit[unit]
    if not set then return end
    local part = PART_OF[event]
    for bar in pairs(set) do
        if barPart[bar] == part and frameUnit[barFrame[bar]] == unit then update(bar) end
    end
end)

local registered = {}
local wantNow = {}

local function listen(parts)
    for k in pairs(wantNow) do wantNow[k] = nil end
    for part in pairs(parts) do
        local list = PART_EVENTS[part]
        if list then
            for _, e in ipairs(list) do wantNow[e] = true end
        end
    end
    for e in pairs(registered) do
        if not wantNow[e] then
            events:UnregisterEvent(e)
            registered[e] = nil
        end
    end
    for e in pairs(wantNow) do
        if not registered[e] then
            events:RegisterEvent(e)
            registered[e] = true
        end
    end
end

-- The bar parts a scope's spark reaches. Look reaches every part. Swing
-- bars have no events (the driver), so "swing" has none.
local CAST_SCOPES = { castbar = true, targetcast = true, focuscast = true, platecast = true }
local SWING_SCOPES = {}
for _, s in pairs(ns.SwingBars.SCOPE) do SWING_SCOPES[s] = true end
local POWER_SCOPES = {}
for _, p in pairs(Grad.POWER_SCOPE) do
    if p ~= "all" then POWER_SCOPES[p] = true end
end

local partsNow = {}
local function wornParts()
    for k in pairs(partsNow) do partsNow[k] = nil end
    for _, s in ipairs(Bars.SCOPES) do
        if Spark.Resolve(s.key).on then
            if s.key == "all" then
                partsNow.health, partsNow.power, partsNow.bar, partsNow.swing = true, true, true, true
            elseif SWING_SCOPES[s.key] then
                partsNow.swing = true
            elseif CAST_SCOPES[s.key] then
                partsNow.bar = true
            elseif POWER_SCOPES[s.key] then
                partsNow.power = true
            else
                partsNow.health = true
            end
        end
    end
    return partsNow
end

-- The hooks are on while some scope wears a spark; the events of the parts
-- the worn sparks reach.
function Spark.Sync()
    if not Spark.installed then return end
    local parts = wornParts()
    local any = next(parts) ~= nil
    local ok, name = Tint.Need(SPARK, any)
    if ok and any and #handles == 0 then ok, name = hookAll() end
    if not ok then
        Tint.Need(SPARK, false)
        Spark.installed = false
        Spark.broken = { name }
        listen({})
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": the spark is off. Daylight UI refused a hook on " .. name .. ".")
        return
    end
    if not any and #handles > 0 then unhookAll() end
    listen(parts)
end

function Spark.Hooked() return #handles > 0 end
function Spark.Listening() return next(registered) ~= nil or driver:IsShown() end

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------

local KINDS = { "unit", "party", "raid", "partypet", "nameplate", "castbar", "platecast", "swing" }

-- The rows read the settings live: Daylight UI redraws the page before
-- PinnoTweaks hears a change.
local function off() return not Spark.installed end
local function rowsOff(scope) return not Spark.installed or Bars.Get(scope, SPARK) ~= true end

Bars.AddTweak({
    key = SPARK, card = "spark", label = "Spark", type = "toggle", default = false, kinds = KINDS,
    desc = "A soft light rides the end of the fill. It hides when the bar is full or empty, and on a cast bar between casts. Daylight UI's Comet bar effect lights the same end, so the two add up.",
    disabled = off,
})

Bars.AddTweak({
    key = MODE, card = "spark", label = "Spark color", type = "dropdown", default = "bar", kinds = KINDS,
    values = { bar = "Bar color", custom = "Custom" }, order = { "bar", "custom" },
    desc = "Bar color is a paler copy of the bar's own color at the fill's end. Custom uses the color below.",
    disabled = rowsOff,
})

Bars.AddTweak({
    key = COLOR, card = "spark", label = "Custom spark color", type = "color", default = COLOR_DEFAULT, kinds = KINDS,
    desc = "The spark's color when Spark color is Custom.",
    disabled = function(scope) return rowsOff(scope) or Bars.Get(scope, MODE) ~= "custom" end,
})

-- ---------------------------------------------------------------------
-- Changes and login
-- ---------------------------------------------------------------------

Grad.BeforeRepaint(function()
    forget()
    Spark.Sync()
end)

-- Checks every internal, then hooks in when a scope wears the spark.
-- Gradients.lua maps the bars, so with it off this is off too.
function Spark.Start()
    if Spark.installed or Spark.broken then return end
    local missing = Grad.installed and Spark.Missing() or { "Gradients.lua's frame map" }
    if #missing == 0 and not Tint.installed then missing = { "Tint.lua" } end
    if #missing > 0 then
        Spark.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": the spark is off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    Style = DaylightUI.Style
    sparkCurve, liftCurve = edgeCurve(1), edgeCurve(LIFT)
    Spark.installed = true
    Spark.Sync()
    if not Spark.installed then return end
    for bar in pairs(barScope) do apply(bar) end

    -- Frames painted before login paint again, so a spark learns its bar's colors.
    for frame, scope in pairs(Grad.frameScope) do
        local p = Grad.powerScope[frame]
        if Spark.Resolve(scope).on or (p and Spark.Resolve(p).on) then Grad.Repaint(frame) end
    end
end

me.On("Login", Spark.Start)
