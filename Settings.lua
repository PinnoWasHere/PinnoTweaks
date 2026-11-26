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

-- Menu order. kinds are the Paint kinds of a scope's frames ("swing" is
-- Swing.lua's own). A frame's scope (Player...) changes its health bar; its
-- power bar has a scope of its own. off(), when set, dims a scope's rows.
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
    { key = "swingmain", label = "Main hand swing", kinds = { "swing" } },
    { key = "swingoff", label = "Off hand swing", kinds = { "swing" } },
    { key = "swingranged", label = "Ranged swing", kinds = { "swing" } },
    { key = "playerpower", label = "Your power bar", kinds = { "unit" } },
    { key = "targetpower", label = "Target power bar", kinds = { "unit" } },
    { key = "focuspower", label = "Focus power bar", kinds = { "unit" } },
    { key = "petpower", label = "Pet power bar", kinds = { "unit", "partypet" } },
    { key = "partypower", label = "Party power bars", kinds = { "party" } },
    { key = "raidpower", label = "Raid power bars", kinds = { "raid" } },
    { key = "arenapower", label = "Arena power bars", kinds = { "unit" } },
    { key = "platepower", label = "Nameplate power bars", kinds = { "nameplate" } },
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

-- Does a tweak apply to a scope? All frames takes every tweak. A tweak's
-- only(scope) can leave a scope out.
function Bars.Applies(def, scope)
    local s = Bars.SCOPE[scope]
    if not s then return false end
    if def.only and not def.only(scope) then return false end
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
-- step?, unit?, disabled?, valuesOf?, only? }. disabled(scope) dims the scope's
-- row while true. valuesOf(scope) gives a dropdown's values and order per scope.
-- only(scope) false leaves the scope without the tweak.
-- Registers before login only, while the defaults and the page are still open.
-- Returns true, or false and why.
function Bars.AddTweak(def)
    if Bars.ready then return false, "too late: register before login" end
    if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then return false, "no key" end
    if def.key == "custom" or Bars.byKey[def.key] then return false, "key taken: " .. def.key end
    if type(def.label) ~= "string" then return false, "no label" end
    if not ROW_TYPES[def.type] then return false, "unknown row type: " .. tostring(def.type) end
    if def.default == nil then return false, "no default" end
    if type(def.kinds) ~= "table" or #def.kinds == 0 then return false, "no kinds" end
    if def.disabled ~= nil and type(def.disabled) ~= "function" then return false, "disabled is not a function" end
    if def.valuesOf ~= nil and type(def.valuesOf) ~= "function" then return false, "valuesOf is not a function" end
    if def.only ~= nil and type(def.only) ~= "function" then return false, "only is not a function" end
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

-- bars.scope is the page's pick and changes nothing on screen. During Reset
-- all, the writes wait for one change at the end.
API.On("SettingChanged", function(scope, path)
    if Bars.resetting or scope ~= Bars.MODULE or type(path) ~= "string" then return end
    local s = path:match("^bars%.([^.]+)%.")
    if s and Bars.SCOPE[s] then Bars.Changed(s) end
end, addonName)

-- ---------------------------------------------------------------------
-- Reset all
-- ---------------------------------------------------------------------

-- Daylight UI's own page reset, which puts every row of the Frames page (every
-- scope's) back to its default. Internals: docs/reference/daylight-internals.md.
Bars.INTERNALS = {
    { "Options", "GetPage", function() return DaylightUI.Options end },
    { "Options", "ResetPage", function() return DaylightUI.Options end },
}

-- The missing internal's name, or nil.
function Bars.ResetMissing()
    for _, e in ipairs(Bars.INTERNALS) do
        local t = e[3]()
        if type(t) ~= "table" or type(t[e[2]]) ~= "function" then return e[1] .. "." .. e[2] end
    end
    return nil
end

-- Every PinnoTweaks setting on every scope back to its default, then one
-- change for All frames: every frame repaints with Daylight UI's own look, and
-- each tweak lets go of its hooks, overrides and layers. Returns true when done.
function Bars.ResetAll()
    if Bars.ResetMissing() then return false end
    local Options = DaylightUI.Options
    local page = Options.GetPage(Bars.MODULE .. "." .. Bars.PAGE.id)
    if not page then return false end
    Bars.resetting = true
    Options.ResetPage(page)
    Bars.resetting = false
    Bars.Changed("all")
    return true
end
