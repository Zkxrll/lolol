--[[============================================================================
    WORLD LIGHTING  -  change how the map looks, for you only
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Rewrites the lighting of the map on your machine: time of day, brightness,
    ambient colour, fog, shadows, bloom, colour correction, sun rays and
    atmosphere. Turn a dark map bright so people cannot hide in corners, kill
    the fog so you can see across the whole map, or just make it look nicer.

    THIS IS LOCAL ONLY, AND THAT IS NOT A DISCLAIMER
    `Lighting` is a client-side service. The server does not send you a picture
    of the map - it sends you the objects, and your machine renders them. The
    lighting settings are part of that rendering, they live on your machine, and
    nothing here is reported anywhere. Other players see the map exactly as they
    always did.

    Which also means: this is undetectable, and it is one of the biggest
    practical advantages in the folder for the least risk. Turning night into
    day is a real competitive edge that costs you nothing.

===============================================================================
    THE ONE THING TO GET RIGHT: CLEANING UP
===============================================================================

    There are two kinds of thing here, and treating them the same is the mistake
    to avoid.

    PROPERTIES that already exist on `Lighting` - Brightness, ClockTime, FogEnd
    and so on. We do not create these; we change them. So we snapshot the
    original value BEFORE the first write and restore it on unload.

    EFFECTS that may or may not exist - Bloom, ColorCorrection, SunRays,
    Atmosphere. Some games ship their own; some do not. So:

        the game had one    -> snapshot its properties, modify it, restore later
        the game had none   -> create one, and DESTROY it on unload

    Getting this backwards is how you end up deleting a game's own bloom and
    leaving the map permanently wrong until the player rejoins. The rule is the
    same one `movement/noclip.lua` uses for collision and `combat/weapon-mods.lua`
    uses for weapon stats: record exactly what was there, put exactly that back,
    and remember that "there was nothing here" is itself a state worth
    recording.

===============================================================================
    NOTES ON INDIVIDUAL SETTINGS
===============================================================================

    ClockTime          0-24. 14 is bright midday, 0 is midnight. This is the
                       single most useful setting in the file.
    Brightness         how strong the sun is. Raising it alone tends to blow
                       out the highlights; raise Ambient too.
    Ambient /          light that reaches surfaces facing away from the sun.
    OutdoorAmbient     This is what actually removes black shadows - not
                       Brightness. Push both toward white to flatten the map.
    FogEnd             set it very high to remove fog entirely. Many maps use
                       fog specifically to limit sightlines.
    GlobalShadows      off makes everything evenly lit and slightly faster.
    ExposureCompensation  a whole-image exposure shift. Small values.

    ColorCorrection saturation of -1 gives you a black-and-white map, which
    sounds like a gimmick and is genuinely useful: coloured player highlights
    stand out against a grey world far more than against a colourful one.

    A NOTE ON PRESETS
    The full script ships whole-map lighting themes in a dropdown. That dropdown
    is deliberately an ACTION - picking one applies it there and then, and it is
    excluded from saved configs, so loading a config never silently replays a
    preset over settings you tuned yourself. If you build presets on top of this
    file, keep that distinction: applying a preset is an event, not a setting.

    REQUIREMENTS
    None. Everything here is standard Roblox API that any executor can reach.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    ---------------------------------------------------------------------------
    -- Core lighting. Set any of these to nil to leave the game's value alone.
    ---------------------------------------------------------------------------
    ClockTime = 14,
    Brightness = 3,
    Ambient = Color3.fromRGB(140, 140, 140),
    OutdoorAmbient = Color3.fromRGB(140, 140, 140),
    ColorShiftTop = nil,
    ColorShiftBottom = nil,
    ExposureCompensation = 0,
    EnvironmentDiffuseScale = nil,
    EnvironmentSpecularScale = nil,
    GeographicLatitude = nil,

    -- Fog. FogEnd very high effectively removes it.
    FogColor = nil,
    FogStart = 0,
    FogEnd = 100000,

    -- Shadows
    GlobalShadows = false,
    ShadowSoftness = nil,

    ---------------------------------------------------------------------------
    -- Post-processing. Set a whole block to nil to leave that effect alone.
    ---------------------------------------------------------------------------
    Bloom = {
        Intensity = 0.4,
        Size = 24,
        Threshold = 1.2,
    },

    ColorCorrection = {
        Brightness = 0,
        Contrast = 0.1,
        Saturation = 0,      -- -1 is fully greyscale; see header
        TintColor = Color3.fromRGB(255, 255, 255),
    },

    SunRays = nil,           -- { Intensity = 0.1, Spread = 0.5 }

    Atmosphere = nil,        -- { Density = 0.3, Offset = 0.25, Glare = 0,
                             --   Haze = 0, Color = ..., Decay = ... }

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "World Lighting", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__WorldLightingCleanup then
    pcall(env.__WorldLightingCleanup)
end

local Token = {}
env.__WorldLightingToken = Token

--=============================================================================
-- Remembering what was there
--=============================================================================

-- Original values of properties we changed, so they can go back exactly.
local SavedProperties = {}   -- [instance] = { [property] = originalValue }

-- Effects WE created, which must be destroyed rather than restored.
local CreatedEffects = {}

local function setProperty(instance, property, value)
    if value == nil then return end

    local saved = SavedProperties[instance]
    if not saved then
        saved = {}
        SavedProperties[instance] = saved
    end

    -- Snapshot before the first write only. Writing twice must not overwrite
    -- the original with our own earlier value.
    if saved[property] == nil then
        local ok, original = pcall(function() return instance[property] end)
        if not ok then return end
        saved[property] = original
    end

    pcall(function() instance[property] = value end)
end

-- Find the game's own effect of this class, or make one and remember that we
-- did. See "THE ONE THING TO GET RIGHT" in the header.
local function ensureEffect(className)
    local existing = Lighting:FindFirstChildWhichIsA(className)
    if existing then
        return existing
    end

    local ok, created = pcall(Instance.new, className)
    if not ok or not created then return nil end

    created.Name = "Custom" .. className
    created.Parent = Lighting
    CreatedEffects[#CreatedEffects + 1] = created
    return created
end

--=============================================================================
-- Applying
--=============================================================================

local function applyBlock(instance, block)
    if not instance or type(block) ~= "table" then return end
    for property, value in pairs(block) do
        setProperty(instance, property, value)
    end
end

local function apply()
    if not CONFIG.Enabled then return end

    setProperty(Lighting, "ClockTime", CONFIG.ClockTime)
    setProperty(Lighting, "Brightness", CONFIG.Brightness)
    setProperty(Lighting, "Ambient", CONFIG.Ambient)
    setProperty(Lighting, "OutdoorAmbient", CONFIG.OutdoorAmbient)
    setProperty(Lighting, "ColorShift_Top", CONFIG.ColorShiftTop)
    setProperty(Lighting, "ColorShift_Bottom", CONFIG.ColorShiftBottom)
    setProperty(Lighting, "ExposureCompensation", CONFIG.ExposureCompensation)
    setProperty(Lighting, "EnvironmentDiffuseScale", CONFIG.EnvironmentDiffuseScale)
    setProperty(Lighting, "EnvironmentSpecularScale", CONFIG.EnvironmentSpecularScale)
    setProperty(Lighting, "GeographicLatitude", CONFIG.GeographicLatitude)

    setProperty(Lighting, "FogColor", CONFIG.FogColor)
    setProperty(Lighting, "FogStart", CONFIG.FogStart)
    setProperty(Lighting, "FogEnd", CONFIG.FogEnd)

    setProperty(Lighting, "GlobalShadows", CONFIG.GlobalShadows)
    setProperty(Lighting, "ShadowSoftness", CONFIG.ShadowSoftness)

    if CONFIG.Bloom then
        applyBlock(ensureEffect("BloomEffect"), CONFIG.Bloom)
    end
    if CONFIG.ColorCorrection then
        applyBlock(ensureEffect("ColorCorrectionEffect"), CONFIG.ColorCorrection)
    end
    if CONFIG.SunRays then
        applyBlock(ensureEffect("SunRaysEffect"), CONFIG.SunRays)
    end
    if CONFIG.Atmosphere then
        applyBlock(ensureEffect("Atmosphere"), CONFIG.Atmosphere)
    end
end

local ok, err = pcall(apply)
if not ok then
    warn("[World Lighting] " .. tostring(err))
end

--=============================================================================
-- Holding it
--=============================================================================
-- Games commonly rewrite Lighting themselves - a day/night cycle, a round
-- transition, an ability effect. So re-apply periodically rather than once.
-- This is cheap: it is a handful of property writes, not a render loop.

task.spawn(function()
    while env.__WorldLightingToken == Token do
        task.wait(1)
        if env.__WorldLightingToken ~= Token then break end
        pcall(apply)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================
-- Destroy what we made; restore what we borrowed. Restore AFTER destroying, so
-- we are not writing properties onto instances that are about to go away.

env.__WorldLightingCleanup = function()
    env.__WorldLightingToken = nil

    for _, effect in ipairs(CreatedEffects) do
        pcall(function() effect:Destroy() end)
    end
    table.clear(CreatedEffects)

    for instance, saved in pairs(SavedProperties) do
        for property, value in pairs(saved) do
            pcall(function() instance[property] = value end)
        end
    end
    table.clear(SavedProperties)

    env.__WorldLightingCleanup = nil
end

notify("applied - run the cleanup function to put the map back")
