local addonName, ns = ...

-- The cutaway ghost and the breakpoint color, for each frame on the Frames page.
--
-- Ghost: an unseen status bar of ours holds a bar's old value after a hit. A
-- texture on the bar, under its fill, follows that helper's fill, so the health
-- or power just lost shows past the fill's edge and then drains away. The
-- game's values pass straight into the helper; Lua never reads them.
--
-- Breakpoint: a texture over the fill in the picked color. A client curve on
-- the unit's health percent gives its alpha: the fill's opacity below the
-- threshold, 0 above it.
--
-- Layers on a bar: the ghost in BORDER (over the empty part, under the fill);
-- over the fill in ARTWORK, the breakpoint at 2, the light layer at 3
-- (Fills.lua), the fill texture at 4 (Gradients.lua, MOD over them all).
--
-- Events and hooks run only while a scope wears a look. Every Daylight UI
-- internal used is checked at login; with one missing, nothing is installed.

local API = DaylightUI.API
local Bars, Grad, Fills, Tint = ns.Bars, ns.Gradients, ns.Fills, ns.Tint
local me = API.For(addonName)

local Health = { installed = false }

-- The ghost lies under the fill; below this fill opacity it would show through, so it is off.
Health.GHOST_MIN_OPACITY = 0.75
ns.Health = Health

local GHOST, GHOST_COLOR, DRAIN, HOLD, FADE = "ghost", "ghostColor", "ghostDrain", "ghostHold", "ghostFade"
local GHOST_ALPHA_KEY, GHOST_MODE = "ghostOpacity", "ghostColorMode"
Health.GHOST_ALPHA, Health.GHOST_MODE = GHOST_ALPHA_KEY, GHOST_MODE
local LOW, LOW_AT, LOW_COLOR, SHADE, FRIENDLY = "breakpoint", "breakpointAt", "breakpointColor", "breakpointShade",
    "breakpointFriendly"
Health.GHOST, Health.GHOST_COLOR, Health.DRAIN, Health.HOLD, Health.FADE = GHOST, GHOST_COLOR, DRAIN, HOLD, FADE
Health.LOW, Health.LOW_AT, Health.LOW_COLOR, Health.SHADE, Health.FRIENDLY = LOW, LOW_AT, LOW_COLOR, SHADE, FRIENDLY

-- The ghost and breakpoint layers' texture (look.md, owner-approved additions).
local WHITE = "Interface\\Buttons\\WHITE8x8" -- look-ok: owner-approved ghost and breakpoint layers, docs/reference/look.md

-- How often the driver looks at holds, drains and demos, in seconds.
local STEP = 0.05
-- How long the ghost stays after a glide starts. The client eases with no
-- duration to read; the probe Dev.ProbeHelper measures it.
local GLIDE_SETTLE = 1
-- Preview demo: a hit every DEMO_EVERY seconds, of DEMO_HIT of the bar.
local DEMO_EVERY, DEMO_HIT = 2.5, 0.2
-- After a unit change, the helper tracks the value for this long and shows no
-- ghost, while Daylight UI's fill grows in (Arrive, Motion.SLOW).
local QUIET = API.Speed.SLOW
-- Ghost opacity 100% is this alpha, so the bar's empty part always shows.
local GHOST_MAX = 0.5
-- The white lift over a bar-colored ghost.
local LIFT = Tint.LIFT

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- As Grad.INTERNALS: { owner, name, table getter, module?, type? }.
local core = Grad.Core
Health.INTERNALS = {
    { "Style", "AngleFill", core("Style") },
    { "Style", "GetFillAngle", core("Style") },
    { "Style", "GetFillMask", core("Style") },
    { "Style", "FollowFill", core("Style") },
    { "Style", "SameMasks", core("Style") },
    { "Style", "Soften", core("Style") },
    { "Style", "Gradient", core("Style") },
    { "Gradients", "Orientation", core("Gradients") },
    { "Gradients", "Flat", core("Gradients") },
    { "Style", "NoteFill", core("Style") },
    { "Style", "NoteFillRGB", core("Style") },
    { "Style", "FillColors", core("Style") },
    { "Style", "SetBarGradient", core("Style") },
    { "Style", "FlatSweep", core("Style") },
    { "UF", "PaintHealth", Grad.ModNs("UnitFrames", "UF"), "UnitFrames" },
    { "UF", "DARK_FILL", Grad.ModNs("UnitFrames", "UF"), "UnitFrames", "table" },
}

function Health.Missing() return Grad.MissingIn(Health.INTERNALS) end

-- ---------------------------------------------------------------------
-- Settings, read once per change
-- ---------------------------------------------------------------------

local looks = {}  -- scope -> resolved look
local readFrom    -- the bars settings table the cache was read from
local curves = {} -- "threshold:opacity" -> client curve, or false

local function forget()
    for k in pairs(looks) do looks[k] = nil end
    readFrom = nil
end

local function rgb(t) return { t[1], t[2], t[3] } end
local INK = API.Colors()
-- Ghost opacity's default: 70%, where the owner first saw the bar through it.
local GHOST_ALPHA = 0.7
local GHOST_DEFAULT, LOW_DEFAULT = rgb(INK.TEXT), rgb(INK.BAD)

local function color(v, default)
    if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
        return v
    end
    return default
end

local function num(v, lo, hi, default)
    if type(v) ~= "number" then return default end
    return math.max(lo, math.min(hi, v))
end

local DRAINS = { glide = true, fade = true, both = true }

-- Power scopes have no breakpoint.
local POWER = {}
for _, p in pairs(Grad.POWER_SCOPE) do
    if p ~= "all" then POWER[p] = true end
end

-- A curve that gives op below the threshold t and 0 from it on, built as
-- Daylight UI's Health.FullCurve is. Shared by scopes with the same pair.
local function curveFor(t, op)
    local key = string.format("%.3f:%.3f", t, op)
    local c = curves[key]
    if c ~= nil then return c or nil end
    c = false
    if C_CurveUtil and C_CurveUtil.CreateCurve then
        c = C_CurveUtil.CreateCurve() or false
        if c then
            if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Linear) end
            c:AddPoint(0, op)
            c:AddPoint(t - 0.001, op)
            c:AddPoint(t, 0)
            if t < 1 then c:AddPoint(1, 0) end
        end
    end
    curves[key] = c
    return c or nil
end

-- A scope's look. A profile switch replaces the settings table, which empties
-- the cache.
function Health.Resolve(scope)
    local now = API.GetSetting(Bars.MODULE, "bars")
    if now ~= readFrom then
        forget()
        readFrom = now
    end
    local c = looks[scope]
    if not c then
        local drain = Bars.Get(scope, DRAIN)
        local shade = Bars.Get(scope, SHADE)
        c = {
            ghost = Bars.Get(scope, GHOST) == true,
            color = color(Bars.Get(scope, GHOST_COLOR), GHOST_DEFAULT),
            custom = Bars.Get(scope, GHOST_MODE) == "custom",
            alpha = 1,
            drain = DRAINS[drain] and drain or "glide",
            hold = num(Bars.Get(scope, HOLD), 0.1, 5, 0.8),
            fade = num(Bars.Get(scope, FADE), 0.05, 3, API.Speed.SLOW),
            low = not POWER[scope] and Bars.Get(scope, LOW) == true,
            at = num(Bars.Get(scope, LOW_AT), 0.01, 1, 0.35),
            lowColor = color(Bars.Get(scope, LOW_COLOR), LOW_DEFAULT),
            two = shade == "two",
            friendly = Bars.Get(scope, FRIENDLY) == true,
            opacity = 1,
        }
        if Fills.installed then c.opacity = Fills.Resolve(scope).opacity end
        c.alpha = num(Bars.Get(scope, GHOST_ALPHA_KEY), 0, 1, GHOST_ALPHA) * GHOST_MAX
        -- Under a well-faded fill the ghost would show through it, so it is off.
        c.ghostOn = c.ghost and c.opacity >= Health.GHOST_MIN_OPACITY
        if c.low then c.curve = curveFor(c.at, c.opacity) end
        looks[scope] = c
    end
    return c
end

-- ---------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------

local Style -- Daylight UI's Style, set at login
local barScope, barFrame, barPart = Grad.barScope, Grad.barFrame, Grad.barPart
local frameBars, frameUnit, framePreview = Grad.frameBars, Grad.frameUnit, Grad.framePreview

local function weak() return setmetatable({}, { __mode = "k" }) end
local helperOf = weak()  -- bar -> our unseen status bar, laid on it
local ghostOf = weak()   -- bar -> the ghost texture, on the bar under its fill
local liftOf = weak()    -- bar -> the white ADD lift over its ghost
local lowOf = weak()     -- bar -> the breakpoint texture, over its fill
local barOfHelper = weak() -- helper -> its bar
local wearing = weak()   -- bar -> its resolved look while it wears a ghost
local lowOn = weak()     -- bar -> its resolved look while it wears a breakpoint
local snapped = weak()   -- bar -> true once its helper has had a value
local holdUntil = weak() -- bar -> when its hold ends
local drainUntil = weak() -- bar -> when its drain ends
local fading = weak()    -- bar -> true once API.Fade has run on its ghost
local quietUntil = weak() -- bar -> when its arrive window ends
local demoAt = weak()    -- preview bar -> when its next demo hit is
Health.helperOf, Health.ghostOf, Health.lowOf, Health.liftOf = helperOf, ghostOf, lowOf, liftOf
Health.holdUntil, Health.drainUntil, Health.demoAt = holdUntil, drainUntil, demoAt

function Health.Wears(bar) return wearing[bar] ~= nil end

-- Real units' bars, filed by unit for the game events.
local byUnit = {}     -- unit -> { [bar] = true }
local filed = weak()  -- bar -> the unit it is filed under

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

local function isPreview(bar) return framePreview[barFrame[bar]] == true end

-- A sample bar's value and range, plain numbers only, else nil.
local function sample(bar)
    local v = bar:GetValue()
    local lo, hi = bar:GetMinMaxValues()
    if secret(v) or secret(lo) or secret(hi) then return nil end
    if type(v) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then return nil end
    return v, lo, hi
end

-- ---------------------------------------------------------------------
-- The driver: holds, drains and preview demos
-- ---------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:Hide()
Health.driver = driver

local function wake() driver:Show() end

-- ---------------------------------------------------------------------
-- The ghost
-- ---------------------------------------------------------------------

-- The bar's value and range into its helper. A real unit's pass straight from
-- the game; a sample's are its own plain numbers. A real frame with no unit
-- has none.
local function feedRange(bar, u)
    local h = helperOf[bar]
    if u then
        if barPart[bar] == "power" then h:SetMinMaxValues(0, UnitPowerMax(u)) else h:SetMinMaxValues(0, UnitHealthMax(u)) end
        return true
    end
    if not isPreview(bar) then return false end
    local _, lo, hi = sample(bar)
    if not lo then return false end
    h:SetMinMaxValues(lo, hi)
    return true
end

local EASE -- Enum.StatusBarInterpolation.ExponentialEaseOut, set at login

local function feedValue(bar, u, glide)
    local h = helperOf[bar]
    local how = glide and EASE or nil
    if u then
        if barPart[bar] == "power" then h:SetValue(UnitPower(u), how) else h:SetValue(UnitHealth(u), how) end
        return
    end
    if not isPreview(bar) then return end
    local v = sample(bar)
    if v then h:SetValue(v, how) end
end

-- The ghost's color: the picked one, or the bar's own (Tint.lua), lifted by
-- the white layer over it.
local function paintGhost(bar)
    local c, g = wearing[bar], ghostOf[bar]
    if not c then return end
    local a = c.alpha
    if c.custom then
        local k = c.color
        g:SetVertexColor(k[1], k[2], k[3], a)
        return
    end
    Tint.Paint(bar, g, a, GHOST_DEFAULT)
end
Health.PaintGhost = paintGhost

local function hideGhost(bar)
    ghostOf[bar]:Hide()
    liftOf[bar]:Hide()
end

-- The ghost and its lift at the scope's opacity. A picked color has no lift.
local function showGhost(bar)
    local c, g, l = wearing[bar], ghostOf[bar], liftOf[bar]
    local la = c.custom and 0 or c.alpha * LIFT
    paintGhost(bar)
    g:Show()
    l:SetShown(not c.custom)
    if fading[bar] then
        API.Fade(g, c.alpha, 0)
        API.Fade(l, la, 0)
        fading[bar] = nil
    else
        g:SetAlpha(c.alpha)
        l:SetAlpha(la)
    end
end

-- The helper takes the value now, and the ghost goes. arriving: a new unit,
-- whose fill Daylight UI grows in.
local function snap(bar, arriving)
    local u = unitOf(bar)
    holdUntil[bar], drainUntil[bar] = nil, nil
    hideGhost(bar)
    if feedRange(bar, u) then feedValue(bar, u, false) end
    snapped[bar] = true
    quietUntil[bar] = (arriving and u) and GetTime() + QUIET or nil
end
Health.Snap = snap

-- A change of value. restart (a hit) starts the hold again; otherwise a hold
-- already running carries on.
local function hit(bar, restart)
    local c = wearing[bar]
    if not c then return end
    local now = GetTime()
    local q = quietUntil[bar]
    if q then
        if now < q then
            feedValue(bar, unitOf(bar), false)
            return
        end
        quietUntil[bar] = nil
    end
    if holdUntil[bar] and not restart then return end
    holdUntil[bar] = now + c.hold
    drainUntil[bar] = nil
    showGhost(bar)
    wake()
end
Health.Hit = hit

-- The hold is over: the helper glides to the value, the ghost fades, or both.
local function drain(bar, now)
    holdUntil[bar] = nil
    local c = wearing[bar]
    if not c then return end
    local u = unitOf(bar)
    if not API.MotionOn() then
        feedValue(bar, u, false)
        hideGhost(bar)
        return
    end
    local glide, fade = c.drain ~= "fade", c.drain ~= "glide"
    if glide then feedValue(bar, u, true) end
    if fade then
        API.Fade(ghostOf[bar], 0, c.fade)
        API.Fade(liftOf[bar], 0, c.fade)
        fading[bar] = true
    end
    drainUntil[bar] = now + (fade and c.fade or GLIDE_SETTLE)
end

-- The drain is over: the helper holds the value and the ghost hides.
local function drained(bar)
    drainUntil[bar] = nil
    local c = wearing[bar]
    hideGhost(bar)
    if c and c.drain == "fade" then feedValue(bar, unitOf(bar), false) end
end

-- A preview's demo hit: the helper jumps a little past the sample's value and
-- drains back to it. Daylight UI's fill is never touched.
local function demoHit(bar)
    local v, lo, hi = sample(bar)
    if not v then return end
    local h = helperOf[bar]
    h:SetMinMaxValues(lo, hi)
    h:SetValue(math.min(hi, v + (hi - lo) * DEMO_HIT))
    hit(bar, true)
end

local waited = 0
driver:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + (elapsed or 0)
    if waited < STEP then return end
    waited = 0
    local now, busy = GetTime(), false
    for bar, t in pairs(holdUntil) do
        busy = true
        if now >= t then drain(bar, now) end
    end
    for bar, t in pairs(drainUntil) do
        busy = true
        if now >= t then drained(bar) end
    end
    if API.MotionOn() then
        for bar, t in pairs(demoAt) do
            if bar:IsVisible() then
                busy = true
                if now >= t then
                    demoAt[bar] = now + DEMO_EVERY
                    demoHit(bar)
                end
            end
        end
    end
    if not busy then self:Hide() end
end)

-- A shown preview starts its demo again.
local function helperShown(h)
    local bar = barOfHelper[h]
    if bar and demoAt[bar] then wake() end
end

local function makeHelper(bar)
    local h = CreateFrame("StatusBar", nil, bar)
    h:SetAllPoints(bar)
    h:SetAlpha(0)
    h:SetStatusBarTexture(WHITE)
    h:SetMinMaxValues(0, 1)
    h:SetValue(0)
    h:SetScript("OnShow", helperShown)
    local g = bar:CreateTexture(nil, "BORDER")
    g:SetTexture(WHITE)
    g:Hide()
    local l = bar:CreateTexture(nil, "BORDER", nil, 1)
    l:SetTexture(WHITE)
    l:SetBlendMode("ADD")
    l:Hide()
    helperOf[bar], ghostOf[bar], liftOf[bar], barOfHelper[h] = h, g, l, bar
    return h
end

-- The ghost's masks: the bar's own cuts (its clipped ends), not the fill's
-- angled edge, plus the helper's angled edge. A texture takes three at most.
local want = {}
local function maskGhost(bar, g)
    local h = helperOf[bar]
    local fill, hf = bar:GetStatusBarTexture(), h:GetStatusBarTexture()
    local edge = Style.GetFillMask(bar)
    for k in pairs(want) do want[k] = nil end
    local n = 0
    for i = 1, hf:GetNumMaskTextures() do
        local m = hf:GetMaskTexture(i)
        if m and n < 3 then want[m] = true; n = n + 1 end
    end
    for i = 1, fill:GetNumMaskTextures() do
        local m = fill:GetMaskTexture(i)
        if m and m ~= edge and not want[m] and n < 3 then want[m] = true; n = n + 1 end
    end
    for i = g:GetNumMaskTextures(), 1, -1 do
        local m = g:GetMaskTexture(i)
        if m and not want[m] then g:RemoveMaskTexture(m) elseif m then want[m] = false end
    end
    for m, add in pairs(want) do
        if add then g:AddMaskTexture(m) end
    end
end

-- The helper lies the bar's way, with the bar's angled end, and the ghost
-- spans its fill, under Daylight UI's fill. It is never anchored to the fill
-- itself: a rect whose ends cross draws whole in game (probe 5, 2026-11-25).
local function layGhost(bar)
    local h, g = helperOf[bar], ghostOf[bar]
    h:SetOrientation(bar:GetOrientation() == "VERTICAL" and "VERTICAL" or "HORIZONTAL")
    h:SetReverseFill(bar:GetReverseFill() == true)
    Style.AngleFill(h, Style.GetFillAngle(bar))
    local l = liftOf[bar]
    maskGhost(bar, g)
    maskGhost(bar, l)
    g:ClearAllPoints()
    g:SetAllPoints(h:GetStatusBarTexture())
    l:ClearAllPoints()
    l:SetAllPoints(h:GetStatusBarTexture())
end

local function ghostOn(bar, c)
    if not helperOf[bar] then makeHelper(bar) end
    wearing[bar] = c
    Tint.Follow(bar, GHOST)
    -- The opacity rides in the color too: a texture has one alpha, and a
    -- color set without one would put it back to 1.
    paintGhost(bar)
    layGhost(bar)
    if not snapped[bar] then snap(bar) end
    if isPreview(bar) then
        demoAt[bar] = demoAt[bar] or GetTime() + DEMO_EVERY
        wake()
    end
end

local function ghostOff(bar)
    if not wearing[bar] then return end
    wearing[bar], snapped[bar], demoAt[bar] = nil, nil, nil
    holdUntil[bar], drainUntil[bar], quietUntil[bar] = nil, nil, nil
    Tint.Unfollow(bar, GHOST)
    hideGhost(bar)
end

-- ---------------------------------------------------------------------
-- The breakpoint
-- ---------------------------------------------------------------------

local function lowTex(bar)
    local t = lowOf[bar]
    if not t then
        t = bar:CreateTexture(nil, "ARTWORK", nil, 2)
        t:SetTexture(WHITE)
        Style.FollowFill(bar, t)
        lowOf[bar] = t
    end
    return t
end

-- The picked color, flat, or two shades laid in the frame's gradient
-- direction: the softened shade where the fill starts, the picked one at its
-- moving end.
local function paintLow(bar, t, c)
    local r, g, b = c.lowColor[1], c.lowColor[2], c.lowColor[3]
    if not c.two then
        t:SetVertexColor(r, g, b)
        return
    end
    local sr, sg, sb = Style.Soften(r, g, b)
    local dir, flip = Grad.Resolve(barScope[bar])
    local o = dir or DaylightUI.Gradients.Orientation()
    local along = (bar:GetOrientation() == "VERTICAL") == (o == "VERTICAL")
    local swap = (along and bar:GetReverseFill() == true) ~= (flip == true)
    if swap then Style.Gradient(t, o, r, g, b, 1, sr, sg, sb, 1)
    else Style.Gradient(t, o, sr, sg, sb, 1, r, g, b, 1) end
end

-- The breakpoint's alpha now. A real unit's comes from the curve, so a secret
-- health is never read; a sample compares its own plain value.
local function lowAlpha(bar)
    local c, t = lowOn[bar], lowOf[bar]
    if not (c and t) then return end
    local u = unitOf(bar)
    if u then
        if c.friendly then
            local f = UnitIsFriend("player", u)
            if not secret(f) and f ~= true then
                t:Hide()
                return
            end
        end
        if not c.curve then
            t:Hide()
            return
        end
        t:SetAlpha(UnitHealthPercent(u, true, c.curve))
        t:Show()
        return
    end
    local v, lo, hi
    if isPreview(bar) then v, lo, hi = sample(bar) end
    if not v then
        t:Hide()
        return
    end
    t:SetAlpha((v - lo) / (hi - lo) < c.at and c.opacity or 0)
    t:Show()
end
Health.LowAlpha = lowAlpha

local function lowOnBar(bar, c)
    local t = lowTex(bar)
    lowOn[bar] = c
    Style.SameMasks(t, bar:GetStatusBarTexture())
    paintLow(bar, t, c)
    lowAlpha(bar)
end

local function lowOff(bar)
    lowOn[bar] = nil
    local t = lowOf[bar]
    if t then t:Hide() end
end

-- ---------------------------------------------------------------------
-- Applying a scope's look
-- ---------------------------------------------------------------------

-- After a mapping or a setting change: the bar's ghost and breakpoint now.
local function apply(bar)
    if not Health.installed then return end
    local scope = barScope[bar]
    if not scope then return end
    local c = Health.Resolve(scope)
    local part = barPart[bar]
    local ghost = c.ghostOn and (part == "health" or part == "power")
    local low = c.low and part == "health"
    if ghost then ghostOn(bar, c) else ghostOff(bar) end
    if low then lowOnBar(bar, c) else lowOff(bar) end
    file(bar, (ghost or low) and unitOf(bar) or nil)
end
Health.Apply = apply
Grad.OnBar(apply)

-- A frame shows another unit (a new target, a reused nameplate): its ghosts
-- snap to the new unit's values. Grad's map has run apply already.
local function unitChanged(_, frame)
    local bars = frameBars[frame]
    if not bars then return end
    for i = 1, #bars do
        local bar = bars[i]
        if wearing[bar] then snap(bar, true) end
        lowAlpha(bar)
    end
end

local function removed(_, frame)
    local bars = frameBars[frame]
    if not bars then return end
    for i = 1, #bars do
        local bar = bars[i]
        if wearing[bar] then
            holdUntil[bar], drainUntil[bar] = nil, nil
            hideGhost(bar)
        end
    end
end

-- ---------------------------------------------------------------------
-- Hooks and events
-- ---------------------------------------------------------------------

-- Style.AngleFill: a bar laid out again takes a new angled end, which its
-- ghost follows. Our own helper's calls pass through.
local function afterAngle(bar)
    local c = wearing[bar]
    if c then layGhost(bar) end
end

-- While a drain fades the ghost, a new color waits for the next hit, so the
-- fade isn't reset.
local function repaint(bar)
    if not fading[bar] then paintGhost(bar) end
end
Tint.OnChange(GHOST, repaint)

-- { owner, name, fn, module? }. Hooks of a module that is off are skipped.
-- The bar's colors come through Tint.lua's hooks.
local HOOKS = {
    { "Style", "AngleFill", afterAngle },
}
Health.HOOKS = HOOKS
local hookTables = {} -- owner name -> Daylight UI's table, set at login

local handles = {}

local function unhookAll()
    for i = #handles, 1, -1 do
        me.Unhook(handles[i])
        handles[i] = nil
    end
end

local function hookAll()
    for _, h in ipairs(HOOKS) do
        if not h[4] or API.IsModuleEnabled(h[4]) then
            local handle = me.Hook(hookTables[h[1]], h[2], h[3])
            if not handle then
                unhookAll()
                return false, h[1] .. "." .. h[2]
            end
            handles[#handles + 1] = handle
        end
    end
    return true
end

local GHOST_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_COMBAT", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER" }
local LOW_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_FACTION", "UNIT_FLAGS" }
local RANGE = { UNIT_MAXHEALTH = "health", UNIT_MAXPOWER = "power" }
local VALUE = { UNIT_HEALTH = "health", UNIT_POWER_UPDATE = "power" }
local LOW_ON = { UNIT_HEALTH = true, UNIT_MAXHEALTH = true, UNIT_FACTION = true, UNIT_FLAGS = true }

local function onBar(bar, event, unit, action)
    local part = barPart[bar]
    if wearing[bar] then
        if VALUE[event] == part then
            hit(bar, false)
        elseif RANGE[event] == part then
            feedRange(bar, unit)
        elseif event == "UNIT_COMBAT" then
            if part == "health" and not secret(action) and action == "WOUND" then hit(bar, true) end
        elseif event == "UNIT_DISPLAYPOWER" and part == "power" then
            snap(bar)
        end
    end
    if lowOn[bar] and LOW_ON[event] then lowAlpha(bar) end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, unit, action)
    local set = byUnit[unit]
    if not set then return end
    for bar in pairs(set) do
        if frameUnit[barFrame[bar]] == unit then onBar(bar, event, unit, action) end
    end
end)

local registered = {} -- event -> true while registered
local wantNow = {}    -- reused each sync

local function listen(ghost, low)
    for k in pairs(wantNow) do wantNow[k] = nil end
    if ghost then for _, e in ipairs(GHOST_EVENTS) do wantNow[e] = true end end
    if low then for _, e in ipairs(LOW_EVENTS) do wantNow[e] = true end end
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

-- Which looks any scope wears.
local function anyLook()
    local ghost, low = false, false
    for _, s in ipairs(Bars.SCOPES) do
        local c = Health.Resolve(s.key)
        if c.ghostOn then ghost = true end
        if c.low then low = true end
    end
    return ghost, low
end

-- The hooks are on while some scope wears a ghost; the events while some scope
-- wears either look.
function Health.Sync()
    if not Health.installed then return end
    local ghost, low = anyLook()
    local tinted, refused = Tint.Need(GHOST, ghost)
    if ghost and #handles == 0 then
        local ok, name = tinted, refused
        if ok then ok, name = hookAll() end
        if not ok then
            Tint.Need(GHOST, false)
            Health.installed = false
            Health.broken = { name }
            listen(false, false)
            DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": frame health effects are off. Daylight UI refused a hook on "
                .. name .. ".")
            return
        end
    elseif not ghost and #handles > 0 then
        unhookAll()
    end
    listen(ghost, low)
end

function Health.Hooked() return #handles > 0 end
function Health.Listening() return next(registered) ~= nil end

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------

-- Health and power bars: unit frames, nameplates.
local KINDS = { "unit", "party", "raid", "partypet", "nameplate" }

-- The rows read the settings live, never the cache: Daylight UI redraws the
-- page before PinnoTweaks hears a change, so a cached look is one click old.
local function off() return not Health.installed end
-- The ghost lies under the fill, so a faded fill dims every ghost row.
local function faded(scope)
    local o = Fills.installed and Bars.Get(scope, Fills.OPACITY)
    return type(o) == "number" and o < Health.GHOST_MIN_OPACITY
end
local function ghostRowsOff(scope)
    return not Health.installed or faded(scope) or Bars.Get(scope, GHOST) ~= true
end
local function noFade(scope)
    local d = Bars.Get(scope, DRAIN)
    return d ~= "fade" and d ~= "both"
end
local function lowRowsOff(scope) return not Health.installed or Bars.Get(scope, LOW) ~= true end
local function healthScope(scope) return not POWER[scope] end

Bars.AddTweak({
    key = GHOST, label = "Cutaway ghost", type = "toggle", default = false, kinds = KINDS,
    desc = "After a hit, the health or power just lost stays on the bar as a ghost for a moment, then drains away. A heal shows none. Off while this frame's Fill opacity is below 75%: the ghost lies under the fill.",
    disabled = function(scope) return off() or faded(scope) end,
})

Bars.AddTweak({
    key = GHOST_MODE, label = "Ghost color", type = "dropdown", default = "bar", kinds = KINDS,
    values = { bar = "Bar color", custom = "Custom" }, order = { "bar", "custom" },
    desc = "Bar color is a paler copy of the bar's own colors. Custom uses the color below.",
    disabled = ghostRowsOff,
})

Bars.AddTweak({
    key = GHOST_COLOR, label = "Custom ghost color", type = "color", default = GHOST_DEFAULT, kinds = KINDS,
    desc = "The ghost's color when Ghost color is Custom.",
    disabled = function(scope) return ghostRowsOff(scope) or Bars.Get(scope, GHOST_MODE) ~= "custom" end,
})

Bars.AddTweak({
    key = GHOST_ALPHA_KEY, label = "Ghost opacity", type = "slider", default = GHOST_ALPHA, kinds = KINDS,
    min = 0.05, max = 1, step = 0.05, unit = "%",
    desc = "How solid the ghost is. Even at 100% the bar's empty part shows through it.",
    disabled = ghostRowsOff,
})

Bars.AddTweak({
    key = DRAIN, label = "Ghost drain", type = "dropdown", default = "glide", kinds = KINDS,
    values = { glide = "Glide", fade = "Fade", both = "Glide and fade" }, order = { "glide", "fade", "both" },
    desc = "How the ghost goes: it glides down to the bar's value, fades out, or both. With Daylight UI's motion effects off it goes at once.",
    disabled = ghostRowsOff,
})

Bars.AddTweak({
    key = HOLD, label = "Ghost delay", type = "slider", default = 0.8, kinds = KINDS,
    min = 0.2, max = 3, step = 0.1, unit = "s",
    desc = "How long the ghost waits before it drains. Each new hit starts the wait again where the game reports hits.",
    disabled = ghostRowsOff,
})

Bars.AddTweak({
    key = FADE, label = "Ghost fade time", type = "slider", default = API.Speed.SLOW, kinds = KINDS,
    min = 0.1, max = 2, step = 0.05, unit = "s",
    desc = "How long Fade takes.",
    disabled = function(scope) return ghostRowsOff(scope) or noFade(scope) end,
})

Bars.AddTweak({
    key = LOW, label = "Low health color", type = "toggle", default = false, kinds = KINDS, only = healthScope,
    desc = "Below a health threshold the bar turns the color below, over every color mode, Dark included. Above it the bar's own colors return.",
    disabled = off,
})

Bars.AddTweak({
    key = LOW_AT, label = "Low health below", type = "slider", default = 0.35, kinds = KINDS, only = healthScope,
    min = 0.05, max = 0.95, step = 0.05, unit = "%",
    desc = "The health the color takes over below.",
    disabled = lowRowsOff,
})

Bars.AddTweak({
    key = LOW_COLOR, label = "Low health bar color", type = "color", default = LOW_DEFAULT, kinds = KINDS,
    only = healthScope,
    desc = "The color the bar turns.",
    disabled = lowRowsOff,
})

Bars.AddTweak({
    key = SHADE, label = "Low health shading", type = "dropdown", default = "flat", kinds = KINDS, only = healthScope,
    values = { flat = "Flat", two = "Two-shade" }, order = { "flat", "two" },
    desc = "Flat is one color. Two-shade runs from a softer shade of it to the color, the way the frame's gradient runs.",
    disabled = lowRowsOff,
})

Bars.AddTweak({
    key = FRIENDLY, label = "Friendly only", type = "toggle", default = false, kinds = KINDS, only = healthScope,
    desc = "Only friendly units' bars change color.",
    disabled = lowRowsOff,
})

-- ---------------------------------------------------------------------
-- Changes and login
-- ---------------------------------------------------------------------

Grad.BeforeRepaint(function()
    forget()
    Health.Sync()
end)

-- Checks every internal, then hooks in when a scope wears a look. Gradients.lua
-- maps the bars, so with it off this is off too.
function Health.Start()
    if Health.installed or Health.broken then return end
    local missing = Grad.installed and Health.Missing() or { "Gradients.lua's frame map" }
    if #missing == 0 and not Tint.installed then missing = Tint.Missing() end
    if #missing > 0 then
        Health.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": frame health effects are off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    Style = DaylightUI.Style
    for _, e in ipairs(Health.INTERNALS) do hookTables[e[1]] = e[3]() end
    EASE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
    Health.installed = true
    me.On("FrameUnitChanged", unitChanged)
    me.On("FrameRemoved", removed)
    Health.Sync()
    if not Health.installed then return end
    for bar in pairs(barScope) do apply(bar) end

    -- Frames painted before login paint again, so a ghost learns its bar's colors.
    for frame, scope in pairs(Grad.frameScope) do
        local p = Grad.powerScope[frame]
        if Health.Resolve(scope).ghostOn or (p and Health.Resolve(p).ghostOn) then Grad.Repaint(frame) end
    end
end

me.On("Login", Health.Start)
