local _, ns = ...

-- PinnoTweaks' frame pages under its section in /dui (Bars.PAGES). Each page
-- has a tab per scope, with a card per feature that applies there
-- (Bars.CARDS). On a frame's tab each card starts with its "Same as defaults"
-- switch. Card labels name the frame, since Daylight UI's search heads a
-- result with page and card, not tab.

local Bars = ns.Bars

local SEP = " · "

-- Every tweak row on every page, in the order made.
Bars.rows = {}

-- Where each scope sits: { page, tab, tabIndex }.
Bars.TAB = {}

-- A group's place on its page: tab, then card (0 for Look's Reset card).
local rank = {}

local function byRank(a, b) return rank[a] < rank[b] end

local function addGroup(at, group, cardIndex)
    rank[group] = at.tabIndex * 100 + cardIndex
    local groups = at.page.groups
    groups[#groups + 1] = group
    table.sort(groups, byRank)
    return group
end

-- The card a tweak's row goes in on a scope's tab, made on first use.
local cardOf = {}
local function card(scope, key)
    cardOf[scope] = cardOf[scope] or {}
    local group = cardOf[scope][key]
    if group then return group end
    local at, c = Bars.TAB[scope], Bars.CARD[key]
    group = addGroup(at, { label = Bars.SCOPE[scope].label .. SEP .. c.label, tab = at.tab, items = {},
        barScope = scope, card = key }, c.index)
    if scope ~= "all" then
        group.items[1] = { type = "toggle", key = "bars." .. scope .. ".own." .. key, invert = true,
            label = "Same as defaults",
            desc = "On, this card uses the defaults page's values. Off, it keeps values of its own for this frame." }
    end
    cardOf[scope][key] = group
    return group
end

local reset = { type = "button", label = "Reset all PinnoTweaks", text = "Reset", confirm = true,
    desc = "Puts every PinnoTweaks setting on every frame back to its default, so your frames look as they do without PinnoTweaks.",
    disabled = function() return Bars.ResetMissing() ~= nil end,
    func = function() Bars.ResetAll() end }

for _, spec in ipairs(Bars.PAGES) do
    local page = { id = spec.id, label = spec.label, desc = spec.desc, groups = {}, preview = spec.preview }
    if spec.sample then
        local views = spec.sample
        page.sample = function(parent) return ns.BarsSample.New(views, parent) end
    end
    Bars.OPTION_PAGES[#Bars.OPTION_PAGES + 1] = page
    for i, tab in ipairs(spec.tabs) do
        local scope = tab[2]
        local at = { page = page, tab = tab[1], tabIndex = i }
        Bars.TAB[scope] = at
        if scope == "all" then addGroup(at, { label = "Reset", tab = at.tab, items = { reset } }, 0) end
    end
end
Bars.PAGE = Bars.OPTION_PAGES[1]

-- Every page id of ours, as Daylight UI's options window knows it.
Bars.PAGE_IDS = {}
for _, p in ipairs(Bars.OPTION_PAGES) do Bars.PAGE_IDS[Bars.MODULE .. "." .. p.id] = true end

-- The row fields a tweak passes on to its rows.
local PASS = { "type", "label", "desc", "values", "order", "min", "max", "step", "unit" }

-- True while a scope's bars can't be reached (its off(), Swing.lua's).
local function scopeOff(scope)
    local off = Bars.SCOPE[scope].off
    return off ~= nil and off() == true
end

-- One row per scope the tweak applies to, in its card on that scope's tab. A
-- card that is Same as defaults has its rows dimmed, and so is a row the tweak's
-- own disabled(scope) or its scope's off() says can't act.
function Bars.AddRows(def)
    local rule = def.disabled
    for _, s in ipairs(Bars.SCOPES) do
        if Bars.Applies(def, s.key) then
            local scope = s.key
            local row = { key = "bars." .. scope .. "." .. def.key, tweak = def.key, barScope = scope }
            for _, field in ipairs(PASS) do row[field] = def[field] end
            if def.valuesOf then row.values, row.order = def.valuesOf(scope) end
            if scope ~= "all" then
                local own = "bars." .. scope .. ".own." .. def.card
                row.disabled = function(get)
                    return get(own) ~= true or scopeOff(scope) or (rule ~= nil and rule(scope) == true)
                end
            elseif rule then
                row.disabled = function() return rule(scope) == true end
            end
            local items = card(scope, def.card).items
            items[#items + 1] = row
            Bars.rows[#Bars.rows + 1] = row
        end
    end
end

for _, def in ipairs(Bars.tweaks) do Bars.AddRows(def) end

-- The keys a click on a scope's part of the live preview jumps to: each
-- card's first row (its Same as defaults switch). They are on the scope's tab, so
-- Daylight UI opens that tab.
function Bars.JumpKeys(scope)
    local keys = {}
    local at = Bars.TAB[scope]
    if not at then return keys end
    for _, group in ipairs(at.page.groups) do
        if group.barScope == scope and group.items[1] and group.items[1].key then
            keys[#keys + 1] = group.items[1].key
        end
    end
    return keys
end
