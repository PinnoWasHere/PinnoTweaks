local addonName, ns = ...

-- PinnoTweaks' section under /dui's Plugins, with Daylight UI's own Frames icon.

DaylightUI:RegisterPlugin(addonName, {
    needs = { 1, 15 },
    icon = DaylightUI.API.Media("ui-section-frames.png"), -- look-ok: Daylight UI's Frames section icon, by API.Media
    short = "PinnoTweaks",
    blurb = "More ways to style your frames, bars and panels.",
})

PinnoTweaks = ns
