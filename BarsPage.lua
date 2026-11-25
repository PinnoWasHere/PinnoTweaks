local _, ns = ...

-- The Bars page under PinnoTweaks' section in /dui. "Settings for" picks a
-- scope. Every scope's rows sit on the page with their own keys and stay
-- hidden until their scope is picked, as Daylight UI's picker cards do. The
-- pick is a saved setting, so picking redraws the page.

local Bars = ns.Bars

local PICK = "bars.scope"

local function notShown(scope)
    return function(get) return get(PICK) ~= scope end
end

local values, order = {}, {}
for _, s in ipairs(Bars.SCOPES) do
    values[s.key] = s.label
    order[#order + 1] = s.key
end

local items = {
    { type = "dropdown", key = PICK, label = "Settings for", values = values, order = order,
      desc = "Which frames the rows below change. A frame follows All frames until you give it settings of its own." },
}

for _, s in ipairs(Bars.SCOPES) do
    if s.key ~= "all" then
        items[#items + 1] = { type = "toggle", key = "bars." .. s.key .. ".custom", invert = true,
            label = "Use All frames settings",
            desc = "On, this frame looks like All frames. Off, it keeps settings of its own.",
            hidden = notShown(s.key) }
    end
end

items[#items + 1] = { type = "text", label = "No frame tweaks yet. They arrive with later updates.",
    hidden = function() return #Bars.tweaks > 0 end }

-- The row fields a tweak passes on to its rows.
local PASS = { "type", "label", "desc", "values", "order", "min", "max", "step", "unit" }

-- One row per scope the tweak applies to. A following bar's rows are dimmed.
function Bars.AddRows(def)
    for _, s in ipairs(Bars.SCOPES) do
        if Bars.Applies(def, s.key) then
            local row = { key = "bars." .. s.key .. "." .. def.key, hidden = notShown(s.key), tweak = def.key, barScope = s.key }
            for _, field in ipairs(PASS) do row[field] = def[field] end
            if s.key ~= "all" then
                local custom = "bars." .. s.key .. ".custom"
                row.disabled = function(get) return get(custom) ~= true end
            end
            items[#items + 1] = row
        end
    end
end

for _, def in ipairs(Bars.tweaks) do Bars.AddRows(def) end

Bars.PAGE.desc = "Tweaks for the health, power and cast bars on unit frames and nameplates."
Bars.PAGE.groups[1] = { label = "Frames", items = items }
