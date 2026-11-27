local addonName, ns = ...

-- Bars settings, saved in Daylight UI's profiles under the PinnoTweaks module.
-- A scope is Look (every frame's values) or one bar. Each feature card of a
-- bar follows Look until its "Same as defaults" switch is off.
--
--   bars.all.<tweak>         the Look value
--   bars.<scope>.own.<card>  true: the bar's card uses its own values
--   bars.<scope>.<tweak>     the bar's own value
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
    { key = "all", label = "Frame defaults" },
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

-- A tweak's card on each tab, in card order.
Bars.CARDS = {
    { key = "gradient", label = "Gradient" },
    { key = "fill", label = "Fill" },
    { key = "background", label = "Background" },
    { key = "ghost", label = "Ghost" },
    { key = "low", label = "Low health" },
    { key = "spark", label = "Spark" },
    { key = "prediction", label = "Heals & absorbs" },
}
Bars.CARD = {}
for i, c in ipairs(Bars.CARDS) do
    c.index = i
    Bars.CARD[c.key] = c
end

-- The options pages in order, each with a tab per scope: { tab name, scope }.
-- preview lists Daylight UI's test parts for the page's "Test frame" switch.
-- sample lists the live preview's views by scope (BarsSample.lua).
Bars.PAGES = {
    { id = "bars", label = "Frame defaults", tabs = { { "Defaults", "all" } },
      desc = "What every frame wears. A frame's card follows this page until you turn its Same as defaults off." },
    { id = "player", label = "Player", tabs = { { "Health", "player" }, { "Power", "playerpower" } },
      desc = "Your own frame's health and power bars.", sample = { "player" } },
    { id = "targetfocus", label = "Target & Focus",
      tabs = { { "Target", "target" }, { "Focus", "focus" }, { "Target power", "targetpower" }, { "Focus power", "focuspower" } },
      desc = "Your target's and focus's health and power bars.", preview = { "target", "focus" },
      sample = { "target", "focus" } },
    { id = "pet", label = "Pet", tabs = { { "Pet", "pet" }, { "Pet power", "petpower" } },
      desc = "Your pet's frame and your party's pets.", preview = { "pet" }, sample = { "pet" } },
    { id = "group", label = "Party & Raid",
      tabs = { { "Party", "party" }, { "Raid", "raid" }, { "Party power", "partypower" }, { "Raid power", "raidpower" } },
      desc = "Party and raid frames.", preview = { "party", "raid" }, sample = { "party", "raid" } },
    { id = "arena", label = "Arena", tabs = { { "Arena", "arena" }, { "Arena power", "arenapower" } },
      desc = "Arena enemy frames.", preview = { "arena" }, sample = { "arena" } },
    { id = "casts", label = "Cast bars",
      tabs = { { "Yours", "castbar" }, { "Target", "targetcast" }, { "Focus", "focuscast" }, { "Nameplates", "platecast" } },
      desc = "Your cast bar, your target's and focus's, and the nameplates' cast bars.",
      preview = { "castbars", "target", "focus" }, sample = { "castbar", "targetcast", "focuscast", "platecast" } },
    { id = "swing", label = "Swing",
      tabs = { { "Main hand", "swingmain" }, { "Off hand", "swingoff" }, { "Ranged", "swingranged" } },
      desc = "Daylight UI's swing timer bars.", preview = { "swing" } },
    { id = "nameplates", label = "Nameplates", tabs = { { "Health", "nameplate" }, { "Power", "platepower" } },
      desc = "Nameplate health and power bars.", sample = { "nameplate" } },
}

Bars.DEFAULTS = { bars = { all = {} } }
for _, s in ipairs(Bars.SCOPES) do
    if s.key ~= "all" then
        local own = {}
        for _, c in ipairs(Bars.CARDS) do own[c.key] = false end
        Bars.DEFAULTS.bars[s.key] = { own = own }
    end
end

-- One switch per frame (bars.<scope>.custom) became one per card. A frame
-- that kept its own settings keeps them on every card. Runs on every saved
-- profile at load, and on a profile copied from an older one.
function Bars.Migrate(profile)
    local mod = type(profile) == "table" and type(profile.modules) == "table" and profile.modules[addonName]
    local bars = type(mod) == "table" and mod.bars
    if type(bars) ~= "table" then return end
    for _, sc in ipairs(Bars.SCOPES) do
        local t = bars[sc.key]
        if sc.key ~= "all" and type(t) == "table" and t.custom ~= nil then
            if t.custom == true then
                if type(t.own) ~= "table" then t.own = {} end
                for _, c in ipairs(Bars.CARDS) do t.own[c.key] = true end
            end
            t.custom = nil
        end
    end
end

do
    local DB = DaylightUI.DB
    local root = DB.Root()
    for _, profile in pairs(type(root.profileData) == "table" and root.profileData or {}) do Bars.Migrate(profile) end
    DB.RegisterUpgrade(Bars.Migrate)
end

-- BarsPage.lua fills the pages.
Bars.OPTION_PAGES = {}

DaylightUI:RegisterModule(addonName, {
    plugin = addonName,
    label = addonName,
    defaults = Bars.DEFAULTS,
    options = { pages = Bars.OPTION_PAGES },
    OnEnable = function() Bars.ready = true end,
})

-- ---------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------

local function setting(path) return API.GetSetting(Bars.MODULE, path) end

-- True while a scope's card uses its own values. With no card: true while
-- every card the scope has does, so Look reaches none of it.
function Bars.Custom(scope, card)
    if scope == "all" or Bars.SCOPE[scope] == nil then return false end
    if card then return setting("bars." .. scope .. ".own." .. card) == true end
    local any = false
    for _, def in ipairs(Bars.tweaks) do
        if Bars.Applies(def, scope) then
            if setting("bars." .. scope .. ".own." .. def.card) ~= true then return false end
            any = true
        end
    end
    return any
end

-- The value a scope uses: its own while the tweak's card is, else Look's.
function Bars.Get(scope, tweak)
    local def = Bars.byKey[tweak]
    if def and Bars.Custom(scope, def.card) then return setting("bars." .. scope .. "." .. tweak) end
    return setting("bars.all." .. tweak)
end

-- Does a tweak apply to a scope? Look takes every tweak. A tweak's
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

-- def: { key, label, desc?, type, default, kinds, card, values?, order?, min?,
-- max?, step?, unit?, disabled?, valuesOf?, only? }. card is a Bars.CARDS key. disabled(scope) dims the scope's
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
    if not Bars.CARD[def.card] then return false, "unknown card: " .. tostring(def.card) end
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

-- During Reset all, the writes wait for one change at the end.
API.On("SettingChanged", function(scope, path)
    if Bars.resetting or scope ~= Bars.MODULE or type(path) ~= "string" then return end
    local s = path:match("^bars%.([^.]+)%.")
    if s and Bars.SCOPE[s] then Bars.Changed(s) end
end, addonName)

-- ---------------------------------------------------------------------
-- Reset all
-- ---------------------------------------------------------------------

-- Daylight UI's own page reset, which puts every row of a page back to its
-- default. Reset all runs it on each of our pages. Internals: docs/reference/daylight-internals.md.
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
-- change for Look: every frame repaints with Daylight UI's own look, and
-- each tweak lets go of its hooks, overrides and layers. Returns true when done.
function Bars.ResetAll()
    if Bars.ResetMissing() then return false end
    local Options = DaylightUI.Options
    local pages = {}
    for i, p in ipairs(Bars.OPTION_PAGES) do
        pages[i] = Options.GetPage(Bars.MODULE .. "." .. p.id)
        if not pages[i] then return false end
    end
    Bars.resetting = true
    for _, page in ipairs(pages) do Options.ResetPage(page) end
    Bars.resetting = false
    Bars.Changed("all")
    return true
end
