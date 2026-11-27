local addonName, ns = ...

-- Mana costs on Daylight UI's action buttons, on the Action bars page in
-- PinnoTweaks' section.
--
-- The text sits on each button's API.Attach holder. Our paint (me.Paint
-- "actionbutton") fills it after each Daylight UI paint, and two game events
-- refresh it when spells or talents change. While the option is off, no paint,
-- event or cost lookup runs.
--
-- A secret cost goes to the client whole (SetText, AbbreviateNumbers). It is
-- never compared or tested.

local API = DaylightUI.API
local me = API.For(addonName)

local Mana = { installed = false }
ns.ManaCost = Mana

Mana.MODULE = addonName .. "ActionBars"
Mana.PAGE_ID = "actionbars"
Mana.LOOK_PAGE_ID = "look"

-- ---------------------------------------------------------------------
-- Daylight UI internals (docs/reference/daylight-internals.md)
-- ---------------------------------------------------------------------

-- Each is { owner, name, table getter, type? }. type is what the entry must be
-- ("function" unless given).
local function core(key) return function() return DaylightUI[key] end end
local function bars()
    local mod = DaylightUI:GetModule("ActionBars")
    return mod and type(mod.ns) == "table" and mod.ns or nil
end
local function skin() local n = bars(); return n and n.Skin end
local function barsMedia() local n = bars(); return n and n.MEDIA end

-- Without these, mana costs stay off.
Mana.INTERNALS = {
    { "Style", "DressText", core("Style") },
    { "Media", "RegisterSlot", core("Media") },
    { "ActionBars ns.MEDIA", "font", barsMedia, "string" },
    { "Skin", "NO_POWER_COLOR", skin, "table" },
}

-- The page's rows. Missing, the font row is API.FontRow's and the spots keep
-- their own words.
Mana.OPTION_INTERNALS = {
    { "Options", "MediaPick", core("Options") },
    { "Spots", "ORDER", core("Spots"), "table" },
    { "Spots", "LABELS", core("Spots"), "table" },
}

-- The position grid's. Missing, the position menu stands alone.
Mana.GRID_INTERNALS = {
    { "Widgets", "Round", core("Widgets") },
    { "Widgets", "TintDaylight", core("Widgets") },
    { "Widgets", "ROW_HEIGHT", core("Widgets"), "number" },
    { "SampleStrip", "DOT", core("SampleStrip"), "number" },
    { "SampleStrip", "DOT_NEAR", core("SampleStrip"), "number" },
    { "SampleStrip", "DOT_ALPHA", core("SampleStrip"), "number" },
    { "SampleStrip", "DOT_NEAR_ALPHA", core("SampleStrip"), "number" },
    { "Options", "Set", core("Options") },
    { "Sound", "Play", core("Sound") },
}

-- Reset's own, which dim only its row.
Mana.RESET_INTERNALS = {
    { "Options", "GetPage", core("Options") },
    { "Options", "ResetPage", core("Options") },
    { "Options", "Set", core("Options") },
}

local function missingIn(list)
    local out = {}
    for _, e in ipairs(list) do
        local t = e[3]()
        if type(t) ~= "table" or type(t[e[2]]) ~= (e[4] or "function") then out[#out + 1] = e[1] .. "." .. e[2] end
    end
    return out
end

-- The missing internals' names, empty when all are there.
function Mana.Missing() return missingIn(Mana.INTERNALS) end
function Mana.OptionsMissing() return missingIn(Mana.OPTION_INTERNALS) end
function Mana.GridMissing() return missingIn(Mana.GRID_INTERNALS)[1] end
function Mana.ResetMissing() return missingIn(Mana.RESET_INTERNALS)[1] end

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------

-- Light blue: the action bars' own color for "short of power" (look.md,
-- owner-approved). The .toc's OptionalDeps loads the action bars first.
local function defaultColor()
    local s = skin()
    local c = s and s.NO_POWER_COLOR
    if type(c) == "table" then return { c[1], c[2], c[3] } end
    return API.Colors().TEXT
end
Mana.DefaultColor = defaultColor

-- Font slots. The Look page's follows the Button font while set to "general",
-- then General's; the mana cost's own follows the Look page's.
Mana.LOOK_SLOT = addonName .. ".actionbarsLook"
Mana.FONT_SLOT = addonName .. ".manaCost"
do
    local Media, m = DaylightUI.Media, barsMedia()
    if Media and type(Media.RegisterSlot) == "function" then
        Media.RegisterSlot(Mana.LOOK_SLOT, Mana.MODULE, "look.font", "font", m and m.font or nil)
        Media.RegisterSlot(Mana.FONT_SLOT, Mana.MODULE, "manaCost.font", "font", Mana.LOOK_SLOT)
    end
end

-- The nine spots on a button: point, x, y. The bottom ones move up over a macro name.
Mana.POS = {
    topleft = { "TOPLEFT", 3, -3 }, top = { "TOP", 0, -3 }, topright = { "TOPRIGHT", -2, -3 },
    left = { "LEFT", 3, 0 }, center = { "CENTER", 0, 0 }, right = { "RIGHT", -2, 0 },
    bottomleft = { "BOTTOMLEFT", 3, 3 }, bottom = { "BOTTOM", 0, 3 }, bottomright = { "BOTTOMRIGHT", -2, 3 },
}
local function justify(point)
    if point:find("LEFT$") then return "LEFT" end
    if point:find("RIGHT$") then return "RIGHT" end
    return "CENTER"
end

-- Space between a macro name's top and the text above it, in px.
Mana.MACRO_GAP = 1

-- Text outline: Daylight UI's General setting, or one of its three looks
-- (General > Appearance > Text outline's flags).
Mana.OUTLINE_FLAGS = { none = "", thin = "OUTLINE", thick = "THICKOUTLINE" }
Mana.OUTLINE_WORDS = { general = "Same as General", none = "None", thin = "Thin", thick = "Thick" }
Mana.OUTLINE_ORDER = { "general", "none", "thin", "thick" }

-- Size 10 is the look sheet's "tiny" (counts, badges, tags).
-- The Look page's text values are every action-bar text feature's while its
-- "same as defaults" switch is on.
Mana.DEFAULTS = {
    look = { font = "general", size = 10, outline = "general" },
    manaCost = {
        on = false, short = false, red = false, hideMacro = false, sameLook = true,
        font = "general", size = 10, outline = "general", colorMode = "light", color = defaultColor(),
        pos = "bottomleft", x = 0, y = 0,
    },
}

local function setting(key) return API.GetSetting(Mana.MODULE, "manaCost." .. key) end

-- A text value (size, outline): the Look page's while "same as defaults" is on.
local function textSetting(key)
    if setting("sameLook") ~= false then return API.GetSetting(Mana.MODULE, "look." .. key) end
    return setting(key)
end
function Mana.TextSlot() return setting("sameLook") ~= false and Mana.LOOK_SLOT or Mana.FONT_SLOT end

-- Cost color modes: Light blue, the player's accent (read each time), or the picker's.
Mana.COLOR_MODES = { light = "Light blue", accent = "Accent", custom = "Custom" }
Mana.COLOR_ORDER = { "light", "accent", "custom" }

-- { r, g, b, a }. Only the picker has an alpha.
function Mana.Color()
    local mode = setting("colorMode")
    if mode == "accent" then
        local r, g, b = API.Accent()
        return { r, g, b, 1 }
    end
    if mode == "custom" then
        local c = setting("color")
        if type(c) == "table" and type(c[1]) == "number" then
            return { c[1], c[2], c[3], type(c[4]) == "number" and c[4] or 1 }
        end
    end
    local c = defaultColor()
    return { c[1], c[2], c[3], 1 }
end

-- Settings read once per change.
local look = {}
local function readLook()
    local d = Mana.DEFAULTS.manaCost
    look.on = setting("on") == true
    look.short = setting("short") == true
    look.red = setting("red") == true
    look.hideMacro = setting("hideMacro") == true
    look.size = tonumber(textSetting("size")) or d.size
    look.outline = Mana.OUTLINE_FLAGS[textSetting("outline")]
    look.slot = Mana.TextSlot()
    look.color = Mana.Color()
    look.bad = API.Colors().BAD
    look.pos = Mana.POS[setting("pos")] and setting("pos") or d.pos
    look.x, look.y = tonumber(setting("x")) or 0, tonumber(setting("y")) or 0
end

-- ---------------------------------------------------------------------
-- The cost
-- ---------------------------------------------------------------------

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- A spell's mana cost and true, or nil and false when it costs none. A secret
-- cost comes back whole, for the text only.
function Mana.Cost(spellID)
    if not secret(spellID) and type(spellID) ~= "number" then return nil, false end
    local costs = C_Spell.GetSpellPowerCost(spellID)
    if secret(costs) or type(costs) ~= "table" then return nil, false end
    local MANA = Enum.PowerType.Mana
    for _, c in ipairs(costs) do
        if not secret(c) and type(c) == "table" and not secret(c.type) and c.type == MANA then
            -- A cost tied to an aura the player lacks (another form or spec) doesn't apply.
            local aura, has = c.requiredAuraID, c.hasRequiredAura
            local needsAura = not secret(aura) and type(aura) == "number" and aura ~= 0
            if not (needsAura and not secret(has) and has ~= true) then
                local n = c.cost
                if secret(n) then return n, true end
                if type(n) == "number" and n > 0 then return n, true end
            end
        end
    end
    return nil, false
end

-- The spell a slot casts. A macro slot can name its spell itself (subtype
-- "spell") instead of its macro index.
function Mana.SpellOf(slot)
    if type(slot) ~= "number" then return nil end
    local kind, id, sub = GetActionInfo(slot)
    if secret(kind) or secret(sub) then return nil end
    if kind == "spell" then return id end
    if kind == "macro" then
        if sub == "spell" then return id end
        if secret(id) then return nil end
        return GetMacroSpell(id)
    end
    return nil
end

-- The cost as written: the game's own shortener takes a secret and gives back a
-- secret string, so nothing here reads the number.
function Mana.Text(cost)
    if look.short and type(AbbreviateNumbers) == "function" then return AbbreviateNumbers(cost) end
    return cost
end

-- ---------------------------------------------------------------------
-- The text
-- ---------------------------------------------------------------------

local labels = setmetatable({}, { __mode = "k" })   -- button -> font string
local styled = setmetatable({}, { __mode = "k" })   -- font string -> look generation
local hidNames = setmetatable({}, { __mode = "k" }) -- macro names we hid
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

-- Hides a button's macro name while its cost shows, and shows again only the
-- names we hid. Daylight UI's own "Show macro names" works through alpha, so
-- the two never undo each other.
local function hideName(m, hide)
    if type(m) ~= "table" or type(m.Hide) ~= "function" then return end
    if hide then
        local shown = m:IsShown()
        if not secret(shown) and shown then
            m:Hide()
            hidNames[m] = true
        end
    elseif hidNames[m] then
        hidNames[m] = nil
        m:Show()
    end
end

local function showNames()
    for m in pairs(hidNames) do
        hidNames[m] = nil
        m:Show()
    end
end

-- The macro name's top above the button's bottom edge, or nil while none shows.
local function macroTop(button, parts)
    local m = parts and parts.macro
    if not (type(m) == "table" and m.GetText and m.IsShown) then return nil end
    local shown, alpha = m:IsShown(), m:GetAlpha()
    if secret(shown) or secret(alpha) or not shown or alpha == 0 then return nil end
    -- A name of spaces shows nothing. A secret one counts as shown, never compared.
    local text = m:GetText()
    if not secret(text) and (type(text) ~= "string" or not text:find("%S")) then return nil end
    local _, height = m:GetFont()
    if secret(height) or type(height) ~= "number" then height = 0 end
    local p, rel, rp, _, y = m:GetPoint(1)
    local base = 0
    if not (secret(p) or secret(rel) or secret(rp) or secret(y))
        and p == "BOTTOM" and rel == button and rp == "BOTTOM" and type(y) == "number" then
        base = y
    end
    return base + height
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
    local cost, has = nil, false
    if info and not info.empty then cost, has = Mana.Cost(Mana.SpellOf(info.slot)) end
    hideName(parts and parts.macro, look.hideMacro and has)
    if styled[fs] ~= gen then
        DaylightUI.Style.DressText(fs, look.size, { slot = look.slot, outline = look.outline })
        fs:SetJustifyH(justify(Mana.POS[look.pos][1]))
        styled[fs] = gen
    end
    -- Short of mana is the game's plain flag (IsUsableAction, through ButtonInfo).
    local noPower = info and info.noPower
    local short = look.red and has and not secret(noPower) and noPower == true
    local c = short and look.bad or look.color
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    place(fs, button, parts)
    if has then fs:SetText(Mana.Text(cost)) else fs:SetText("") end
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
    showNames()
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

-- The fonts, the outline, the accent and BAD are Daylight UI's look.
API.On("StyleChanged", function() if Mana.installed then Mana.Sync() end end, addonName)

-- ---------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------

Mana.ROWS = {}

-- Daylight UI's own page reset puts every row of the page back to its default.
function Mana.ResetAll()
    if Mana.ResetMissing() then return false end
    local Options = DaylightUI.Options
    local page = Options.GetPage(Mana.MODULE .. "." .. Mana.PAGE_ID)
    if not page then return false end
    Mana.resetting = true
    Options.ResetPage(page)
    -- The page reset compares and copies a color's r, g, b only, so an
    -- opacity-only change would stay (core-prs.md).
    Options.Set(page, Mana.ROWS.color, defaultColor())
    Mana.resetting = false
    Mana.Sync()
    return true
end

-- ---------------------------------------------------------------------
-- The position grid
-- ---------------------------------------------------------------------

-- Nine of Daylight UI's spot dots (Design mode's) in a 3 x 3 grid beside the
-- position menu. A click picks that spot; the picked one shows large and bright.
Mana.GRID = {
    { "topleft", "top", "topright" },
    { "left", "center", "right" },
    { "bottomleft", "bottom", "bottomright" },
}
Mana.CELL = 9

function Mana.Grid(row)
    local f = CreateFrame("Frame", nil, row)
    f.cells = {}
    if Mana.GridMissing() then
        f:SetSize(1, 1)
        function f.Refresh() end
        return f
    end
    local W, Strip = DaylightUI.Widgets, DaylightUI.SampleStrip
    local cell = Mana.CELL
    f:SetSize(3 * cell, W.ROW_HEIGHT)
    local top = math.floor((W.ROW_HEIGHT - 3 * cell) / 2)

    function f.Refresh()
        local at = setting("pos")
        for _, b in ipairs(f.cells) do
            local size = (b.spot == at or b.hover) and Strip.DOT_NEAR or Strip.DOT
            b.dot:SetSize(size, size)
            W.TintDaylight(b.dot, b.spot == at and Strip.DOT_NEAR_ALPHA or Strip.DOT_ALPHA)
        end
    end

    for r, line in ipairs(Mana.GRID) do
        for c, spot in ipairs(line) do
            local b = CreateFrame("Button", nil, f)
            b:SetSize(cell, cell)
            b:SetPoint("TOPLEFT", f, "TOPLEFT", (c - 1) * cell, -(top + (r - 1) * cell))
            b.spot = spot
            b.dot = W.Round(b, "OVERLAY", 7)
            b.dot:SetPoint("CENTER", b, "CENTER", 0, 0)
            b:SetScript("OnClick", function()
                if row.disabled then return end
                DaylightUI.Options.Set(row.page, row.item, spot)
                DaylightUI.Sound.Play("click")
                if row.Refresh then row.Refresh() end
            end)
            b:SetScript("OnEnter", function()
                b.hover = true
                f.Refresh()
                if row.Enter then row.Enter() end
            end)
            b:SetScript("OnLeave", function()
                b.hover = nil
                f.Refresh()
                if row.Leave then row.Leave() end
            end)
            f.cells[#f.cells + 1] = b
        end
    end
    f.Refresh()
    return f
end

-- ---------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------

local function off(get) return get("manaCost.on") ~= true end

-- The spots in Daylight UI's order and words.
local SPOT_WORDS, SPOT_ORDER = {}, {}
do
    local Spots = DaylightUI.Spots
    local order = Spots and type(Spots.ORDER) == "table" and Spots.ORDER
    local words = Spots and type(Spots.LABELS) == "table" and Spots.LABELS or {}
    for _, line in ipairs(order and { order } or Mana.GRID) do
        for _, s in ipairs(line) do
            if Mana.POS[s] then
                SPOT_ORDER[#SPOT_ORDER + 1] = s
                SPOT_WORDS[s] = words[s] or s
            end
        end
    end
end
Mana.SPOT_WORDS, Mana.SPOT_ORDER = SPOT_WORDS, SPOT_ORDER

-- Daylight UI's own font picker. "General" follows the parent slot, as
-- Daylight UI's sub-fonts follow their area's.
local function fontRow(key, label, desc, parent, parentLabel, disabled)
    local Options = DaylightUI.Options
    local item
    if type(Options) == "table" and type(Options.MediaPick) == "function" and type(parent) == "string" then
        item = Options.MediaPick("font", key, label, desc, { follows = { slot = parent, label = parentLabel } })
    else
        item = API.FontRow(key, label, desc)
    end
    item.disabled = disabled
    return item
end

-- The mana cost's own text rows dim while "same as defaults" is on.
local function ownText(get) return off(get) or get("manaCost.sameLook") ~= false end

local function nudge(key, label, desc)
    return { type = "slider", key = "manaCost." .. key, label = label, min = -20, max = 20, step = 1, unit = "px",
        desc = desc, disabled = off }
end

Mana.ROWS.reset = { type = "button", label = "Reset mana costs", text = "Reset", confirm = true,
    desc = "Puts every mana cost setting, on all three tabs, back to its default. Button defaults keeps its own.",
    disabled = function() return Mana.ResetMissing() ~= nil end,
    func = function() Mana.ResetAll() end }
Mana.ROWS.on = { type = "toggle", key = "manaCost.on", label = "Show mana costs",
    desc = "Shows how much mana a spell costs on its button, macros included. Spells with no mana cost show nothing." }
Mana.ROWS.short = { type = "toggle", key = "manaCost.short", label = "Short numbers (1.2K)",
    desc = "Writes a cost of a thousand or more short, 1,200 as 1.2K, with the game's own shortener, so it works in a fight too.",
    disabled = off }
Mana.ROWS.red = { type = "toggle", key = "manaCost.red", label = "Red when not enough mana",
    desc = "The cost turns red while you don't have the mana to cast the spell.", disabled = off }
Mana.ROWS.hideMacro = { type = "toggle", key = "manaCost.hideMacro", label = "Hide macro names on buttons",
    desc = "Hides a macro's name on a button that shows a mana cost, so the cost sits on the bottom edge. "
        .. "Daylight UI's own Show macro names hides them on every button.",
    disabled = off }
Mana.ROWS.sameLook = { type = "toggle", key = "manaCost.sameLook", label = "Mana cost text same as defaults",
    desc = "Uses the font, size and outline on Action bars > Look. Off, the three rows below set the mana cost's own.",
    disabled = off }
Mana.ROWS.font = fontRow("manaCost.font", "Mana cost font",
    "The font of the mana cost on buttons. General uses the font on Action bars > Look.",
    Mana.LOOK_SLOT, "Default font", ownText)
Mana.ROWS.size = { type = "slider", key = "manaCost.size", label = "Mana cost size", min = 6, max = 20, step = 1,
    desc = "Text size of the mana cost on buttons.", disabled = ownText }
Mana.ROWS.outline = { type = "dropdown", key = "manaCost.outline", label = "Mana cost outline",
    values = Mana.OUTLINE_WORDS, order = Mana.OUTLINE_ORDER,
    desc = "A dark edge around the numbers, so they stay readable over any icon. Same as General follows General > Appearance.",
    disabled = ownText }
Mana.ROWS.colorMode = { type = "dropdown", key = "manaCost.colorMode", label = "Cost color",
    values = Mana.COLOR_MODES, order = Mana.COLOR_ORDER,
    desc = "Light blue like a button short of mana, your accent color, or a color you pick.", disabled = off }
Mana.ROWS.color = { type = "color", key = "manaCost.color", label = "Mana cost color", alpha = true,
    desc = "Color and opacity of the mana cost on buttons, with Cost color set to Custom.",
    disabled = function(get) return off(get) or get("manaCost.colorMode") ~= "custom" end }
Mana.ROWS.pos = { type = "dropdown", key = "manaCost.pos", label = "Mana cost position",
    values = SPOT_WORDS, order = SPOT_ORDER, beside = Mana.Grid,
    desc = "Where on the button its mana cost shows; a dot in the grid picks that spot. At the bottom it sits above a macro's name.",
    disabled = off }
Mana.ROWS.x = nudge("x", "Mana cost nudge left/right", "Moves the mana cost left (below 0) or right (above 0) of its spot, in pixels.")
Mana.ROWS.y = nudge("y", "Mana cost nudge down/up", "Moves the mana cost down (below 0) or up (above 0) from its spot, in pixels.")

-- The Look page: text values every action-bar text feature can share.
Mana.LOOK_ROWS = {
    font = fontRow("look.font", "Action bar text font",
        "The font of PinnoTweaks' text on action buttons, like mana costs. General uses the action bars' Button font.",
        (barsMedia() or {}).font, "Button font"),
    size = { type = "slider", key = "look.size", label = "Action bar text size", min = 6, max = 20, step = 1,
        desc = "Text size of PinnoTweaks' text on action buttons, like mana costs." },
    outline = { type = "dropdown", key = "look.outline", label = "Action bar text outline",
        values = Mana.OUTLINE_WORDS, order = Mana.OUTLINE_ORDER,
        desc = "A dark edge around PinnoTweaks' text on action buttons. Same as General follows General > Appearance." },
}
local LR = Mana.LOOK_ROWS
Mana.LOOK_PAGE = {
    id = Mana.LOOK_PAGE_ID, label = "Button defaults",
    desc = "The look PinnoTweaks' action button tweaks share. Each tweak can keep its own instead.",
    groups = { { label = "Text", items = { LR.font, LR.size, LR.outline } } },
}

local R = Mana.ROWS
Mana.PAGE = {
    id = Mana.PAGE_ID, label = "Action bars",
    desc = "Tweaks for Daylight UI's action buttons.",
    groups = {
        { label = "Mana costs", tab = "Mana costs", items = { R.reset, R.on, R.short, R.red, R.hideMacro } },
        { label = "Mana cost text", tab = "Text", items = { R.sameLook, R.font, R.size, R.outline, R.colorMode, R.color } },
        { label = "Mana cost position", tab = "Position", items = { R.pos, R.x, R.y } },
    },
}

DaylightUI:RegisterModule(Mana.MODULE, {
    plugin = addonName,
    label = "Action bars",
    defaults = Mana.DEFAULTS,
    options = { pages = { Mana.LOOK_PAGE, Mana.PAGE } },
    OnEnable = function()
        Mana.ready = true
        Mana.Sync()
    end,
})
