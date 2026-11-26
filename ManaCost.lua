local addonName, ns = ...

-- Mana costs on Daylight UI's action buttons, on the Action bars page in
-- PinnoTweaks' section.
--
-- The text sits on each button's API.Attach holder in the Button font. Our
-- paint (me.Paint "actionbutton") fills it after each Daylight UI paint, and two
-- game events refresh it when spells or talents change. While the option is
-- off, no paint, event or cost lookup runs.
--
-- A secret cost goes to SetText whole and is never compared.

local API = DaylightUI.API
local me = API.For(addonName)

local Mana = { installed = false }
ns.ManaCost = Mana

Mana.MODULE = addonName .. "ActionBars"
Mana.PAGE_ID = "actionbars"

-- ---------------------------------------------------------------------
-- Daylight UI internals (docs/reference/daylight-internals.md)
-- ---------------------------------------------------------------------

-- Each is { owner, name, table getter, type? }. type is what the entry must be
-- ("function" unless given).
local function core(key) return function() return DaylightUI[key] end end
local function skin()
    local mod = DaylightUI:GetModule("ActionBars")
    return mod and type(mod.ns) == "table" and mod.ns.Skin or nil
end

Mana.INTERNALS = {
    { "ActionButtonLook", "Text", core("ActionButtonLook") },
    { "Skin", "NO_POWER_COLOR", skin, "table" },
}

-- Reset all's own, which dim only its row.
Mana.RESET_INTERNALS = {
    { "Options", "GetPage", core("Options") },
    { "Options", "ResetPage", core("Options") },
}

local function missingIn(list)
    local out = {}
    for _, e in ipairs(list) do
        local t = e[3]()
        if type(t) ~= "table" or type(t[e[2]]) ~= (e[4] or "function") then out[#out + 1] = e[1] .. "." .. e[2] end
    end
    return out
end

function Mana.ResetMissing() return missingIn(Mana.RESET_INTERNALS)[1] end

-- The missing internals' names, empty when all are there.
function Mana.Missing() return missingIn(Mana.INTERNALS) end

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------

-- Light blue: the action bars' own color for "short of power" (look.md,
-- owner-approved). The .toc's OptionalDeps loads the action bars first.
-- Without it, the text color, and mana costs stay off (Mana.Missing).
local function defaultColor()
    local s = skin()
    local c = s and s.NO_POWER_COLOR
    if type(c) == "table" then return { c[1], c[2], c[3] } end
    return API.Colors().TEXT
end

-- Where the text sits: point, x, y. The bottom ones move up over a macro name.
Mana.POS = {
    topleft = { "TOPLEFT", 3, -3 }, topright = { "TOPRIGHT", -2, -3 }, bottom = { "BOTTOM", 0, 3 },
    bottomleft = { "BOTTOMLEFT", 3, 3 }, bottomright = { "BOTTOMRIGHT", -2, 3 },
}
Mana.POS_ORDER = { "bottomleft", "bottomright", "bottom", "topleft", "topright" }
local JUSTIFY = { TOPLEFT = "LEFT", BOTTOMLEFT = "LEFT", TOPRIGHT = "RIGHT", BOTTOMRIGHT = "RIGHT", BOTTOM = "CENTER" }

-- Space between a macro name's top and the text above it, in px.
Mana.MACRO_GAP = 1

-- Size 10 is the look sheet's "tiny" (counts, badges, tags).
Mana.DEFAULTS = {
    manaCost = { on = false, size = 10, colorMode = "light", color = defaultColor(), pos = "bottomleft", x = 0, y = 0 },
}

local function setting(key) return API.GetSetting(Mana.MODULE, "manaCost." .. key) end

-- Cost color modes: Light blue, the player's accent (read each time), or the picker's.
Mana.COLOR_MODES = { light = "Light blue", accent = "Accent", custom = "Custom" }
Mana.COLOR_ORDER = { "light", "accent", "custom" }

function Mana.Color()
    local mode = setting("colorMode")
    if mode == "accent" then
        local r, g, b = API.Accent()
        return { r, g, b }
    end
    if mode == "custom" then
        local c = setting("color")
        if type(c) == "table" and type(c[1]) == "number" then return c end
    end
    return defaultColor()
end

-- Settings read once per change.
local look = {}
local function readLook()
    look.on = setting("on") == true
    look.size = tonumber(setting("size")) or Mana.DEFAULTS.manaCost.size
    look.color = Mana.Color()
    look.pos = Mana.POS[setting("pos")] and setting("pos") or Mana.DEFAULTS.manaCost.pos
    look.x, look.y = tonumber(setting("x")) or 0, tonumber(setting("y")) or 0
end

-- ---------------------------------------------------------------------
-- The cost
-- ---------------------------------------------------------------------

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- A spell's mana cost, or nil when it costs none. A secret cost comes back
-- whole, for the text only.
function Mana.Cost(spellID)
    if spellID == nil or not (secret(spellID) or type(spellID) == "number") then return nil end
    local costs = C_Spell.GetSpellPowerCost(spellID)
    if costs == nil or secret(costs) or type(costs) ~= "table" then return nil end
    local MANA = Enum.PowerType.Mana
    for _, c in ipairs(costs) do
        if type(c) == "table" and not secret(c) and not secret(c.type) and c.type == MANA then
            -- A cost tied to an aura the player lacks (another form or spec) doesn't apply.
            local aura, has = c.requiredAuraID, c.hasRequiredAura
            local needsAura = not secret(aura) and type(aura) == "number" and aura ~= 0
            if not (needsAura and not secret(has) and has ~= true) then
                local n = c.cost
                if secret(n) then return n end
                if type(n) == "number" and n > 0 then return n end
            end
        end
    end
    return nil
end

-- The spell a slot casts. A macro slot can name its spell itself (subtype
-- "spell") instead of its macro index.
function Mana.SpellOf(slot)
    if type(slot) ~= "number" then return nil end
    local kind, id, sub = GetActionInfo(slot)
    if kind == "spell" then return id end
    if kind == "macro" then
        if sub == "spell" then return id end
        return GetMacroSpell(id)
    end
    return nil
end

-- ---------------------------------------------------------------------
-- The text
-- ---------------------------------------------------------------------

local labels = setmetatable({}, { __mode = "k" })   -- button -> font string
local styled = setmetatable({}, { __mode = "k" })   -- font string -> look generation
local gen = 0

function Mana.Label(button) return labels[button] end

local function labelFor(button)
    local fs = labels[button]
    if fs then return fs end
    local holder = API.Attach(button)
    if not holder then return nil end
    fs = holder:CreateFontString(nil, "OVERLAY")
    labels[button] = fs
    return fs
end

-- The macro name's top above the button's bottom edge, or nil while none shows.
local function macroTop(button, parts)
    local m = parts and parts.macro
    if not (type(m) == "table" and m.GetText and m.IsShown) then return nil end
    if not m:IsShown() or m:GetAlpha() == 0 then return nil end
    -- A name of spaces shows nothing. A secret one counts as shown, never compared.
    local text = m:GetText()
    if text == nil then return nil end
    if not secret(text) and (type(text) ~= "string" or not text:find("%S")) then return nil end
    local _, height = m:GetFont()
    local p, rel, rp, _, y = m:GetPoint(1)
    local base = (p == "BOTTOM" and rel == button and rp == "BOTTOM" and type(y) == "number") and y or 0
    return base + (tonumber(height) or 0)
end

local function place(fs, button, parts)
    local at = Mana.POS[look.pos]
    local y = at[3]
    if at[1]:find("^BOTTOM") then
        local top = macroTop(button, parts)
        if top and top + Mana.MACRO_GAP > y then y = top + Mana.MACRO_GAP end
    end
    fs:ClearAllPoints()
    fs:SetPoint(at[1], button, at[1], at[2] + look.x, y + look.y)
end

local function paint(button, parts, info)
    local fs = labelFor(button)
    if not fs then return end
    if styled[fs] ~= gen then
        DaylightUI.ActionButtonLook.Text(fs, look.size)
        local c = look.color
        fs:SetTextColor(c[1], c[2], c[3])
        fs:SetJustifyH(JUSTIFY[Mana.POS[look.pos][1]])
        styled[fs] = gen
    end
    place(fs, button, parts)
    local cost = nil
    if info and not info.empty then cost = Mana.Cost(Mana.SpellOf(info.slot)) end
    fs:SetText(cost or "")
    fs:Show()
end
Mana.Paint = paint

-- Every button again, outside a Daylight UI paint (spells or settings changed).
function Mana.RefreshAll()
    if not Mana.installed then return end
    for button in API.Frames("actionbutton") do
        paint(button, API.Parts(button), API.ButtonInfo(button))
    end
end

-- ---------------------------------------------------------------------
-- On and off
-- ---------------------------------------------------------------------

-- Spells learned, ranks and talents change costs without a new action in a slot.
Mana.EVENTS = { "SPELLS_CHANGED", "PLAYER_TALENT_UPDATE" }

local events = CreateFrame("Frame")
local queued = false
events:SetScript("OnEvent", function()
    if queued then return end
    queued = true
    C_Timer.After(0, function()
        queued = false
        Mana.RefreshAll()
    end)
end)

local handle

local function install()
    if Mana.installed then return end
    Mana.installed = true
    for _, e in ipairs(Mana.EVENTS) do events:RegisterEvent(e) end
    handle = me.Paint("actionbutton", paint)
end

local function uninstall()
    if not Mana.installed then return end
    Mana.installed = false
    for _, e in ipairs(Mana.EVENTS) do events:UnregisterEvent(e) end
    if handle then API.Off(handle) end
    handle = nil
    for _, fs in pairs(labels) do
        fs:SetText("")
        fs:Hide()
    end
end

-- Follows the settings: the painter and events run only while the option is on.
function Mana.Sync()
    readLook()
    gen = gen + 1
    if not (look.on and Mana.ready and #Mana.Missing() == 0 and API.IsModuleEnabled("ActionBars")) then
        return uninstall()
    end
    if Mana.installed then return Mana.RefreshAll() end
    install()
end

API.On("SettingChanged", function(scope)
    if scope == Mana.MODULE and not Mana.resetting then Mana.Sync() end
end, addonName)

-- The Button font and the accent are Daylight UI's look.
API.On("StyleChanged", function() if Mana.installed then Mana.Sync() end end, addonName)

-- ---------------------------------------------------------------------
-- Reset all
-- ---------------------------------------------------------------------

-- Daylight UI's own page reset puts every row of the page back to its default.
function Mana.ResetAll()
    if Mana.ResetMissing() then return false end
    local Options = DaylightUI.Options
    local page = Options.GetPage(Mana.MODULE .. "." .. Mana.PAGE_ID)
    if not page then return false end
    Mana.resetting = true
    Options.ResetPage(page)
    Mana.resetting = false
    Mana.Sync()
    return true
end

-- ---------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------

local function off(get) return get("manaCost.on") ~= true end

local POS_WORDS = { bottomleft = "Bottom left", bottomright = "Bottom right", bottom = "Bottom",
    topleft = "Top left", topright = "Top right" }

local function nudge(key, label)
    return { type = "slider", key = "manaCost." .. key, label = label, min = -20, max = 20, step = 1, unit = "px",
        desc = "Nudges the mana cost away from its spot on the button, in pixels.", disabled = off }
end

Mana.PAGE = {
    id = Mana.PAGE_ID, label = "Action bars",
    desc = "Tweaks for Daylight UI's action buttons.",
    groups = { { label = "Mana costs", items = {
        { type = "button", label = "Reset all", text = "Reset", confirm = true,
          desc = "Puts every setting on this page back to its default.",
          disabled = function() return Mana.ResetMissing() ~= nil end,
          func = function() Mana.ResetAll() end },
        { type = "toggle", key = "manaCost.on", label = "Show mana costs",
          desc = "Shows how much mana a spell costs on its button, macros included. Spells with no mana cost show nothing." },
        { type = "slider", key = "manaCost.size", label = "Mana cost size", min = 6, max = 18, step = 1,
          desc = "Text size of the mana cost on buttons.", disabled = off },
        { type = "dropdown", key = "manaCost.colorMode", label = "Cost color",
          values = Mana.COLOR_MODES, order = Mana.COLOR_ORDER,
          desc = "Light blue like a button short of mana, your accent color, or a color you pick.", disabled = off },
        { type = "color", key = "manaCost.color", label = "Mana cost color",
          desc = "Color of the mana cost on buttons, with Cost color set to Custom.",
          disabled = function(get) return off(get) or get("manaCost.colorMode") ~= "custom" end },
        { type = "dropdown", key = "manaCost.pos", label = "Mana cost position", values = POS_WORDS, order = Mana.POS_ORDER,
          desc = "Where on the button its mana cost shows. At the bottom it sits above a macro's name.", disabled = off },
        nudge("x", "Mana cost X offset"),
        nudge("y", "Mana cost Y offset"),
    } } },
}

DaylightUI:RegisterModule(Mana.MODULE, {
    plugin = addonName,
    label = "Action bars",
    defaults = Mana.DEFAULTS,
    options = { pages = { Mana.PAGE } },
    OnEnable = function()
        Mana.ready = true
        Mana.Sync()
    end,
})
