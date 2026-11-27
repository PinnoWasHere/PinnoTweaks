local _, ns = ...

-- The live preview over each frame page (BarsPage.lua). It shows Daylight
-- UI's own sample of that page's frame, the one its own frame pages show, so
-- our tweaks paint it as they paint any preview. Our Parts() point each bar
-- at its tab's cards, so a click jumps there. A page with more than one frame
-- gets a chip per frame (sample.Views), one always picked.
-- Internals: docs/reference/daylight-internals.md.

local Bars = ns.Bars

local Sample = {}
ns.BarsSample = Sample

local function moduleNs(name)
    local mod = DaylightUI:GetModule(name)
    return mod and mod.enabled and type(mod.ns) == "table" and mod.ns or nil
end

local function pageSample() local m = moduleNs("UnitFrames"); return m and m.PageSample end
local function plateSample() local m = moduleNs("Nameplates"); return m and m.Sample end

-- The sample builders we call: { table name, function, its table }.
Sample.INTERNALS = {
    { "PageSample", "New", pageSample },
    { "PageSample", "NewCasts", pageSample },
    { "Sample", "New", plateSample },
}

-- True while a builder is there (its module on).
local function has(e)
    local t = e[3]()
    return type(t) == "table" and type(t[e[2]]) == "function"
end

-- The missing builders' names (Nameplates' Sample.New as "Sample.New").
function Sample.Missing()
    local out = {}
    for _, e in ipairs(Sample.INTERNALS) do
        if not has(e) then out[#out + 1] = e[1] .. "." .. e[2] end
    end
    return out
end

local NEW, CASTS, PLATE = Sample.INTERNALS[1], Sample.INTERNALS[2], Sample.INTERNALS[3]

local function fields(t, ...)
    for i = 1, select("#", ...) do
        if type(t) ~= "table" then return nil end
        t = t[select(i, ...)]
    end
    return t
end

-- A unit frame sample's health and power bars, each with its scope.
local function frameBars(health, power)
    return function(s)
        local f = s.f or (s.members and s.members[1])
        return { { fields(f, "health"), health, "Health bar" }, { fields(f, "power"), power, "Power bar" } }
    end
end

local function unitView(id, health, power)
    return { make = function(parent) return pageSample().New(id, parent) end, parts = frameBars(health, power),
             needs = NEW }
end

-- A cast bar of Daylight UI's Cast Bars page sample, held on one kind.
local function castView(kind, scope)
    return { make = function(parent)
                 local s = pageSample().NewCasts(parent)
                 s.view = kind
                 return s
             end,
             parts = function(s) return { { fields(s, "bars", kind, "bar"), scope, "Cast bar" } } end,
             needs = CASTS }
end

local function plateView(parts)
    return { make = function(parent) return plateSample().New("plates", parent) end, parts = parts, needs = PLATE }
end

-- Each view by the scope it shows.
Sample.VIEWS = {
    player = unitView("player", "player", "playerpower"),
    target = unitView("target", "target", "targetpower"),
    focus = unitView("focus", "focus", "focuspower"),
    pet = unitView("pet", "pet", "petpower"),
    arena = unitView("arena", "arena", "arenapower"),
    party = unitView("party", "party", "partypower"),
    raid = unitView("raid", "raid", "raidpower"),
    castbar = castView("player", "castbar"),
    targetcast = castView("target", "targetcast"),
    focuscast = castView("focus", "focuscast"),
    platecast = plateView(function(s) return { { fields(s, "p", "cast"), "platecast", "Cast bar" } } end),
    nameplate = plateView(function(s)
        return { { fields(s, "p", "hp"), "nameplate", "Health bar" }, { fields(s, "p", "power"), "platepower", "Power bar" } }
    end),
}

-- The sample for a page: scopes lists its views in chip order. A view whose
-- builder is missing (its module off) is left out. With none left, a sample of
-- nothing: the strip hides at height 0.
function Sample.New(scopes, parent)
    local s = { frame = CreateFrame("Frame", nil, parent), viewsExclusive = true, inner = {} }
    local list = {}
    for _, scope in ipairs(scopes) do
        local v = Sample.VIEWS[scope]
        if v and has(v.needs) then list[#list + 1] = scope end
    end
    s.view = list[1]

    local function current()
        local scope = s.view
        if not scope then return nil end
        s.inner[scope] = s.inner[scope] or Sample.VIEWS[scope].make(s.frame)
        return s.inner[scope]
    end

    function s.Views()
        local out = {}
        if #list < 2 then return out end
        for _, scope in ipairs(list) do
            out[#out + 1] = { key = scope, label = Bars.SCOPE[scope].label, on = s.view == scope }
        end
        return out
    end

    function s.SetView(key)
        for _, scope in ipairs(list) do
            if scope == key then s.view = key end
        end
    end

    function s.Refresh(width, maxH)
        for scope, inner in pairs(s.inner) do
            if scope ~= s.view then inner.frame:Hide() end
        end
        local inner = current()
        if not inner then return 0 end
        inner.frame:Show()
        inner.frame:ClearAllPoints()
        inner.frame:SetPoint("TOPLEFT", s.frame, "TOPLEFT", 0, 0)
        local h = inner.Refresh(width, maxH)
        if type(h) ~= "number" or h <= 0 then return 0 end
        s.frame:SetSize(width, h)
        return h
    end

    -- Each shown bar, jumping to its tab.
    function s.Parts()
        local out = {}
        local inner = s.view and s.inner[s.view]
        if not inner then return out end
        for _, part in ipairs(Sample.VIEWS[s.view].parts(inner)) do
            local region, scope, label = part[1], part[2], part[3]
            if region and region.IsVisible and region:IsVisible() then
                out[#out + 1] = { region = region, label = label, keys = Bars.JumpKeys(scope), scale = 1 }
            end
        end
        return out
    end

    return s
end
