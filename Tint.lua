local addonName, ns = ...

-- A bar's own colors, as Daylight UI last painted them, for our looks that
-- wear a paler copy of them (the cutaway ghost, the spark). Each color may be
-- secret: it passes straight back into our textures' setters and is never read.
--
-- Dark's near-black gives way to the unit's own color (unit-frame health), and
-- the Daylight sweep to its middle color. The hooks run only while some look
-- follows a bar's colors.

local API = DaylightUI.API
local Grad = ns.Gradients
local me = API.For(addonName)

local Tint = { installed = false }
ns.Tint = Tint

-- The white lift over a bar-colored look: Daylight UI's own lighten amount
-- (Colors.lua :332, Style.Lighten(..., 0.3)).
Tint.LIFT = 0.3

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

-- As Grad.INTERNALS: { owner, name, table getter, module?, type? }.
local core = Grad.Core
Tint.INTERNALS = {
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

function Tint.Missing() return Grad.MissingIn(Tint.INTERNALS) end

-- ---------------------------------------------------------------------
-- Followed bars
-- ---------------------------------------------------------------------

local function weak() return setmetatable({}, { __mode = "k" }) end
local tintOf = weak()    -- bar -> its fill's last colors, passed through untouched
local unitTint = weak()  -- bar -> the unit's own color from UF.PaintHealth
local darkOf = weak()    -- bar -> true while its fill is Dark's near-black
local sweepOf = weak()   -- bar -> true while it shows the Daylight sweep
local fillToBar = weak() -- fill texture -> its bar, while a look follows it
local users = weak()     -- bar -> { [look key] = true }
local onChange = {}      -- look key -> fn(bar), run when the bar's colors change

local Style, UF -- Daylight UI's tables, set at login
local barScope, barPart, frameBars = Grad.barScope, Grad.barPart, Grad.frameBars

-- key's fn(bar) runs whenever a bar the look follows takes new colors.
function Tint.OnChange(key, fn) onChange[key] = fn end

function Tint.Follow(bar, key)
    local u = users[bar]
    if not u then
        u = {}
        users[bar] = u
    end
    u[key] = true
    fillToBar[bar:GetStatusBarTexture()] = bar
end

function Tint.Unfollow(bar, key)
    local u = users[bar]
    if not u then return end
    u[key] = nil
    if next(u) == nil then
        users[bar] = nil
        fillToBar[bar:GetStatusBarTexture()] = nil
    end
end

local function changed(bar)
    local u = users[bar]
    if not u then return end
    for key in pairs(u) do
        local fn = onChange[key]
        if fn then fn(bar) end
    end
end

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- ---------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------

-- The way the fill's pair runs: the scope's own direction, else the
-- Gradients page's.
local function orientationOf(bar)
    local dir = Grad.Resolve(barScope[bar])
    return dir or DaylightUI.Gradients.Orientation()
end

-- Does a pair laid in o run along the way the bar fills?
local function along(bar, o) return (bar:GetOrientation() == "VERTICAL") == (o == "VERTICAL") end

-- A pair into tex at alpha a. edge: tex is a thin light on the fill's moving
-- end and takes one color, never a gradient, so its alpha stays its own: the
-- end's color for a pair along the bar (the second, or the first on a reversed
-- bar), the second for a pair across it.
local function pair(bar, tex, edge, a, r1, g1, b1, r2, g2, b2)
    local o = orientationOf(bar)
    if edge then
        if along(bar, o) and bar:GetReverseFill() == true then tex:SetVertexColor(r1, g1, b1, a)
        else tex:SetVertexColor(r2, g2, b2, a) end
        return
    end
    Style.Gradient(tex, o, r1, g1, b1, a, r2, g2, b2, a)
end

-- Paints tex in the bar's own colors at alpha a, the fallback { r, g, b }
-- before any paint is heard. The bar's colors pass straight from Daylight UI's
-- paint into tex's setters, so a secret color is never read.
function Tint.Paint(bar, tex, a, fallback, edge)
    local t = tintOf[bar]
    if darkOf[bar] and unitTint[bar] then t = unitTint[bar] end
    if sweepOf[bar] then
        local r, g, b = Style.FlatSweep()
        tex:SetVertexColor(r, g, b, a)
    elseif t and t.two then
        pair(bar, tex, edge, a, t[1], t[2], t[3], t[4], t[5], t[6])
    elseif t and t.set then
        tex:SetVertexColor(t[1], t[2], t[3], a)
    else
        local lo, hi = Style.FillColors(bar:GetStatusBarTexture())
        if lo then
            pair(bar, tex, edge, a, lo[1], lo[2], lo[3], hi[1], hi[2], hi[3])
        else
            tex:SetVertexColor(fallback[1], fallback[2], fallback[3], a)
        end
    end
end

-- ---------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------

local function keep(bar)
    local t = tintOf[bar]
    if not t then
        t = {}
        tintOf[bar] = t
    end
    return t
end

local function unpackColor(c)
    if type(c) ~= "table" then return nil end
    if c.r ~= nil then return c.r, c.g, c.b end
    return c[1], c[2], c[3]
end

-- Style.NoteFill: a pair, or one color, in painting order.
local function afterNote(tex, lo, hi)
    local bar = fillToBar[tex]
    if not bar then return end
    local t = keep(bar)
    t[1], t[2], t[3] = unpackColor(lo)
    t.two, t.set = hi ~= nil, true
    if t.two then t[4], t[5], t[6] = unpackColor(hi) end
    darkOf[bar] = nil
    changed(bar)
end

-- Style.NoteFillRGB: one color. Dark's near-black (plain) keeps the color
-- the look had, or takes the unit's own (UF.PaintHealth).
local function afterNoteRGB(tex, r, g, b)
    local bar = fillToBar[tex]
    if not bar then return end
    local d = UF and UF.DARK_FILL
    if d and not (secret(r) or secret(g) or secret(b)) and r == d[1] and g == d[2] and b == d[3] then
        darkOf[bar] = true
    else
        local t = keep(bar)
        t[1], t[2], t[3], t.two, t.set = r, g, b, false, true
        darkOf[bar] = nil
    end
    changed(bar)
end

-- Style.SetBarGradient: the Daylight sweep on or off.
local function afterSweep(bar, on)
    if not users[bar] then return end
    sweepOf[bar] = (on and not DaylightUI.Gradients.Flat()) or nil
    changed(bar)
end

-- UF.PaintHealth: r, g, b is the unit's own color, which Dark's look takes.
local function afterHealth(f, r, g, b)
    local bars = frameBars[f]
    if not bars then return end
    for i = 1, #bars do
        local bar = bars[i]
        if users[bar] and barPart[bar] == "health" then
            local t = unitTint[bar]
            if not t then
                t = {}
                unitTint[bar] = t
            end
            t[1], t[2], t[3], t.set = r, g, b, true
            changed(bar)
        end
    end
end

-- { owner, name, fn, module? }. Hooks of a module that is off are skipped.
Tint.HOOKS = {
    { "Style", "NoteFill", afterNote },
    { "Style", "NoteFillRGB", afterNoteRGB },
    { "Style", "SetBarGradient", afterSweep },
    { "UF", "PaintHealth", afterHealth, "UnitFrames" },
}
local hookTables = {} -- owner name -> Daylight UI's table, set at login
local handles = {}
local needs = {}      -- look key -> true while it follows some bar

local function unhookAll()
    for i = #handles, 1, -1 do
        me.Unhook(handles[i])
        handles[i] = nil
    end
end

local function hookAll()
    for _, h in ipairs(Tint.HOOKS) do
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

-- A look says whether it follows any bar now. The hooks are on while some
-- look does. Returns false and the refused hook's name when Daylight UI
-- refuses one; nothing is hooked then.
function Tint.Need(key, on)
    if not Tint.installed then return false, "Tint" end
    needs[key] = on or nil
    if next(needs) and #handles == 0 then
        local ok, name = hookAll()
        if not ok then
            needs[key] = nil
            return false, name
        end
    elseif not next(needs) and #handles > 0 then
        unhookAll()
    end
    return true
end

function Tint.Hooked() return #handles > 0 end

-- Checks every internal. Gradients.lua maps the bars, so with it off this is
-- off too. The looks that use Tint check its internals themselves.
function Tint.Start()
    if Tint.installed then return end
    if not Grad.installed or #Tint.Missing() > 0 then return end
    Style = DaylightUI.Style
    for _, e in ipairs(Tint.INTERNALS) do hookTables[e[1]] = e[3]() end
    UF = hookTables.UF
    Tint.installed = true
end

me.On("Login", Tint.Start)
