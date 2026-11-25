local addonName, ns = ...

-- Bars settings, saved in Daylight UI's profiles under the PinnoTweaks module.
-- A scope is All frames or one bar. A bar follows All frames until its custom
-- switch is on.
--
--   bars.scope            the Bars page's "Settings for" pick
--   bars.all.<tweak>      the All frames value
--   bars.<scope>.custom   false: the bar follows All frames
--   bars.<scope>.<tweak>  the bar's own value
--
-- Rows write through their keys, so every change fires SettingChanged.
-- Bars.Changed(scope) follows each write to a scope's settings.

local API = DaylightUI.API

local Bars = { tweaks = {}, byKey = {} }
ns.Bars = Bars

Bars.MODULE = addonName

-- Menu order. kinds are the Paint kinds of a scope's frames.
Bars.SCOPES = {
    { key = "all", label = "All frames" },
    { key = "player", label = "Player", kinds = { "unit" } },
    { key = "target", label = "Target", kinds = { "unit" } },
    { key = "focus", label = "Focus", kinds = { "unit" } },
    { key = "pet", label = "Pet", kinds = { "unit", "partypet" } },
    { key = "party", label = "Party", kinds = { "party" } },
    { key = "raid", label = "Raid", kinds = { "raid" } },
    { key = "arena", label = "Arena", kinds = { "unit" } },
    { key = "castbar", label = "Your cast bar", kinds = { "castbar" } },
    { key = "targetcast", label = "Target cast bar", kinds = { "castbar" } },
    { key = "focuscast", label = "Focus cast bar", kinds = { "castbar" } },
    { key = "platecast", label = "Nameplate cast bars", kinds = { "platecast" } },
    { key = "nameplate", label = "Nameplates", kinds = { "nameplate" } },
}

Bars.SCOPE = {}
for _, s in ipairs(Bars.SCOPES) do Bars.SCOPE[s.key] = s end

Bars.DEFAULTS = { bars = { scope = "all", all = {} } }
for _, s in ipairs(Bars.SCOPES) do
    if s.key ~= "all" then Bars.DEFAULTS.bars[s.key] = { custom = false } end
end

-- BarsPage.lua fills the page's cards.
Bars.PAGE = { id = "bars", label = "Frames", groups = {} }

DaylightUI:RegisterModule(addonName, {
    plugin = addonName,
    label = addonName,
    defaults = Bars.DEFAULTS,
    options = { pages = { Bars.PAGE } },
    OnEnable = function() Bars.ready = true end,
})

-- ---------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------

local function setting(path) return API.GetSetting(Bars.MODULE, path) end

-- True while the scope keeps settings of its own.
function Bars.Custom(scope)
    return scope ~= "all" and Bars.SCOPE[scope] ~= nil and setting("bars." .. scope .. ".custom") == true
end

-- The value a scope uses: its own while custom, else All frames'.
function Bars.Get(scope, tweak)
    if Bars.Custom(scope) then return setting("bars." .. scope .. "." .. tweak) end
    return setting("bars.all." .. tweak)
end

-- Does a tweak apply to a scope? All frames takes every tweak.
function Bars.Applies(def, scope)
    local s = Bars.SCOPE[scope]
    if not s then return false end
    if not s.kinds then return true end
    for _, kind in ipairs(s.kinds) do
        for _, k in ipairs(def.kinds) do
            if k == kind then return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- The tweak registry
-- ---------------------------------------------------------------------

local ROW_TYPES = { toggle = true, dropdown = true, slider = true, color = true }

-- def: { key, label, desc?, type, default, kinds, values?, order?, min?, max?,
-- step?, unit? }. Registers before login only, while the defaults and the page
-- are still open. Returns true, or false and why.
function Bars.AddTweak(def)
    if Bars.ready then return false, "too late: register before login" end
    if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then return false, "no key" end
    if def.key == "custom" or Bars.byKey[def.key] then return false, "key taken: " .. def.key end
    if type(def.label) ~= "string" then return false, "no label" end
    if not ROW_TYPES[def.type] then return false, "unknown row type: " .. tostring(def.type) end
    if def.default == nil then return false, "no default" end
    if type(def.kinds) ~= "table" or #def.kinds == 0 then return false, "no kinds" end
    Bars.tweaks[#Bars.tweaks + 1] = def
    Bars.byKey[def.key] = def
    for _, s in ipairs(Bars.SCOPES) do
        if Bars.Applies(def, s.key) then Bars.DEFAULTS.bars[s.key][def.key] = def.default end
    end
    if Bars.AddRows then Bars.AddRows(def) end
    return true
end

-- ---------------------------------------------------------------------
-- Changes
-- ---------------------------------------------------------------------

local listeners = {}

-- fn(scope) runs after each write to a scope's settings.
function Bars.OnChanged(fn) listeners[#listeners + 1] = fn end

function Bars.Changed(scope)
    for _, fn in ipairs(listeners) do fn(scope) end
end

-- bars.scope is the page's pick and changes nothing on screen.
API.On("SettingChanged", function(scope, path)
    if scope ~= Bars.MODULE or type(path) ~= "string" then return end
    local s = path:match("^bars%.([^.]+)%.")
    if s and Bars.SCOPE[s] then Bars.Changed(s) end
end, addonName)
