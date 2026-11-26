local addonName, ns = ...

-- Daylight UI's swing timer bars (main hand, off hand, ranged) on the Frames
-- page. They send no frame events and have no Paint kind, so each bar is
-- mapped at login from the swing timer's own rows, as a frame of kind "swing"
-- with one bar. Their colors already pass through the painters Gradients.lua,
-- Fills.lua and Tint.lua hook. A change repaints them through the swing
-- timer's own layout. Every Daylight UI internal used is checked at login;
-- with one missing, nothing is mapped and the swing scopes' rows stay dimmed.

local API = DaylightUI.API
local Bars, Grad = ns.Bars, ns.Gradients
local me = API.For(addonName)

local Swing = { installed = false }
ns.SwingBars = Swing

-- A swing row's hand (Daylight UI's def.key) -> its scope.
Swing.SCOPE = { main = "swingmain", off = "swingoff", ranged = "swingranged" }

-- One effect setting animates every swing bar.
Swing.FX = { "UnitFrames", "swing.barFx.style" }

-- ---------------------------------------------------------------------
-- Daylight UI internals
-- ---------------------------------------------------------------------

local function ufNs()
    local mod = DaylightUI:GetModule("UnitFrames")
    return mod and type(mod.ns) == "table" and mod.ns or nil
end

local function holder()
    local n = ufNs()
    return n and n.swing
end

local function firstRow()
    local h = holder()
    return h and type(h.rows) == "table" and h.rows[1] or nil
end

local function firstDef()
    local row = firstRow()
    return row and row.def
end

-- As Grad.INTERNALS: { owner, name, table getter, module?, type? }.
Swing.INTERNALS = {
    { "Swing", "Layout", Grad.ModNs("UnitFrames", "Swing"), "UnitFrames" },
    { "swing", "rows", holder, "UnitFrames", "table" },
    { "swing", "cfg", holder, "UnitFrames", "table" },
    { "swing", "castbar", holder, "UnitFrames", "table" },
    { "swing row", "bar", firstRow, "UnitFrames", "table" },
    { "swing row", "holder", firstRow, "UnitFrames", "table" },
    { "swing row", "def", firstRow, "UnitFrames", "table" },
    { "swing row def", "key", firstDef, "UnitFrames", "string" },
}

-- The missing internals, as names. Each row's hand must be one we know.
function Swing.Missing()
    local out = Grad.MissingIn(Swing.INTERNALS)
    if #out > 0 then return out end
    for _, row in ipairs(holder().rows) do
        local key = type(row.def) == "table" and row.def.key
        local bar = row.bar
        if not Swing.SCOPE[key] or type(bar) ~= "table" or not bar.GetStatusBarTexture then
            out[#out + 1] = "swing row def.key " .. tostring(key)
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Rows and repaint
-- ---------------------------------------------------------------------

local function uf(path) return API.GetSetting("UnitFrames", path) end

-- The swing scopes' rows dim while their bars can't be reached or the swing
-- timer is off on Daylight UI's page.
local function off() return not Swing.installed or uf("swing.enabled") ~= true end
Swing.Off = off

-- The direction rows act on a two-color or custom gradient fill.
local function gradient()
    if off() then return false end
    local fill = uf("swing.fill")
    return fill == "pair" or fill == "customGradient"
end

for _, scope in pairs(Swing.SCOPE) do
    Bars.SCOPE[scope].off = off
    Grad.HAS_GRADIENT[scope] = gradient
end

-- Daylight UI lays the swing timer out again from its own settings, which
-- paints each bar.
Grad.REPAINT.swing = function(row)
    local h = row.holder
    if Swing.installed and h and type(h.cfg) == "table" then
        ufNs().Swing.Layout(h, h.cfg, h.castbar)
    end
end

-- ---------------------------------------------------------------------
-- Login
-- ---------------------------------------------------------------------

-- Checks every internal, then maps each swing bar to its scope, turns its
-- bar effect off while a scope wears a fill look (Gradients.lua's override),
-- and repaints the bars a saved look reaches.
function Swing.Start()
    if Swing.installed or Swing.broken then return end
    if not Grad.installed or not API.IsModuleEnabled("UnitFrames") then return end
    if holder() == nil and type(ufNs().Swing) == "table" then return end -- a client with no swing timer
    local missing = Swing.Missing()
    if #missing > 0 then
        Swing.broken = missing
        DEFAULT_CHAT_FRAME:AddMessage(addonName .. ": swing timer tweaks are off. Daylight UI no longer has "
            .. table.concat(missing, ", ") .. ".")
        return
    end
    Swing.installed = true
    for _, row in ipairs(holder().rows) do
        local scope = Swing.SCOPE[row.def.key]
        Grad.FX[scope] = { Swing.FX }
        Grad.MapBar(row, "swing", scope, row.bar)
        local dir, flip, file = Grad.Resolve(scope)
        if dir or flip or file then Grad.Repaint(row) end
    end
    Grad.SyncFx()
end

me.On("Login", Swing.Start)
