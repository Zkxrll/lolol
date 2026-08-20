--[[============================================================================
    SKYBOX  -  replace the sky, locally
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Swaps the map's sky for one of the presets below, or for six texture ids of
    your own. Local only - everyone else sees the map's real sky.

===============================================================================
    THE PART PEOPLE GET WRONG
===============================================================================

    A sky in Roblox is a `Sky` instance parented to `Lighting`, and the obvious
    move is to create one with your textures and parent it there.

    That works only if the map does not already have one. If it does, you now
    have two `Sky` objects in Lighting, and Roblox renders one of them - not
    reliably the same one, not necessarily yours, and it can change when
    anything else touches Lighting. The usual symptom is a skybox that works in
    one map and silently does nothing in another, which sends people hunting for
    bugs in the wrong place entirely.

    So this checks first:

        does Lighting already contain a Sky that is not ours?
            yes -> write our textures onto THAT one, remembering its originals
            no  -> create our own and parent it

    Two different code paths that look identical from outside, chosen by what is
    already there. Adopting the existing object is always the better branch when
    there can only be one of something - you inherit whatever else the map set
    on it, and there is nothing to conflict with.

    THE GENERAL RULE
    Before creating an instance in a shared container, ask whether the thing you
    want is a singleton. `Sky`, `Atmosphere`, `Clouds`, most post-processing
    effects, `Terrain` - for all of these the engine picks one and ignores the
    rest. Adopt, don't add. `lighting.lua` in this folder does the same thing
    with post-processing effects for the same reason.

===============================================================================
    RESTORING SOMETHING YOU DID NOT MAKE
===============================================================================

    When we made the Sky, cleanup is easy: destroy it, and the map's own sky (if
    any) takes over again.

    When we adopted the map's Sky, cleanup has to put every property back the
    way it was - so each one is snapshotted immediately before its first write:

        if Original[property] == nil then
            Original[property] = sky[property]
        end
        sky[property] = value

    Note the `== nil` guard. The snapshot happens once, on the first write only.
    Without it, a second pass would snapshot the value we ourselves wrote and
    the original would be lost forever - and re-applying is normal here, because
    a map can reset its own sky at any point.

    Snapshot before the first write, never after. It is the same rule as in
    `lighting.lua`, and it is the single easiest thing to get wrong when writing
    to something you did not create.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Any key from PRESETS below, or "Custom" to use CustomFaces.
    Preset = "Night",

    -- Only used when Preset is "Custom". Six faces; all six are needed.
    CustomFaces = {
        SkyboxFt = "rbxassetid://0",
        SkyboxBk = "rbxassetid://0",
        SkyboxLf = "rbxassetid://0",
        SkyboxRt = "rbxassetid://0",
        SkyboxUp = "rbxassetid://0",
        SkyboxDn = "rbxassetid://0",
    },

    -- Applied on top of whichever preset is chosen. nil leaves it alone.
    StarCount = nil,              -- e.g. 3000
    SunAngularSize = nil,         -- degrees; 0 hides the sun
    MoonAngularSize = nil,
    CelestialBodiesShown = nil,   -- false hides sun and moon entirely

    Notify = true,
}

local PRESETS = {
    Night = {
        SkyboxFt = "rbxassetid://12064107295", SkyboxBk = "rbxassetid://12064107295",
        SkyboxLf = "rbxassetid://12064107295", SkyboxRt = "rbxassetid://12064107295",
        SkyboxUp = "rbxassetid://12064107295", SkyboxDn = "rbxassetid://12064107295",
        StarCount = 5000,
    },
    Space = {
        SkyboxFt = "rbxassetid://159454299", SkyboxBk = "rbxassetid://159454296",
        SkyboxLf = "rbxassetid://159454293", SkyboxRt = "rbxassetid://159454300",
        SkyboxUp = "rbxassetid://159454301", SkyboxDn = "rbxassetid://159454288",
        StarCount = 0,
    },
    Sunset = {
        SkyboxFt = "rbxassetid://271042516", SkyboxBk = "rbxassetid://271042516",
        SkyboxLf = "rbxassetid://271042516", SkyboxRt = "rbxassetid://271042516",
        SkyboxUp = "rbxassetid://271042516", SkyboxDn = "rbxassetid://271042516",
    },
}

-- Every property this file is allowed to touch. Restricting it to a list is
-- what makes the restore complete - anything not named here is never written,
-- so it never needs putting back.
local SKY_PROPERTIES = {
    "SkyboxFt", "SkyboxBk", "SkyboxLf", "SkyboxRt", "SkyboxUp", "SkyboxDn",
    "StarCount", "SunAngularSize", "MoonAngularSize", "CelestialBodiesShown",
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
            Title = "Skybox", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__SkyboxCleanup then
    pcall(env.__SkyboxCleanup)
end

local Token = {}
env.__SkyboxToken = Token

local State = {
    OwnedSky = nil,        -- the Sky we created, if we created one
    AdoptedSky = nil,      -- the map's Sky, if we are writing to that instead
    Original = {},         -- adopted sky only: property -> value before we touched it
}

--=============================================================================
-- Building the property set
--=============================================================================

local function resolveValues()
    local preset = (CONFIG.Preset == "Custom") and CONFIG.CustomFaces or PRESETS[CONFIG.Preset]
    if type(preset) ~= "table" then return nil end

    local values = {}
    for key, value in pairs(preset) do
        values[key] = value
    end

    -- CONFIG overrides sit on top of the preset. nil means "leave it".
    if CONFIG.StarCount ~= nil then values.StarCount = CONFIG.StarCount end
    if CONFIG.SunAngularSize ~= nil then values.SunAngularSize = CONFIG.SunAngularSize end
    if CONFIG.MoonAngularSize ~= nil then values.MoonAngularSize = CONFIG.MoonAngularSize end
    if CONFIG.CelestialBodiesShown ~= nil then values.CelestialBodiesShown = CONFIG.CelestialBodiesShown end

    return values
end

--=============================================================================
-- Finding the map's own sky
--=============================================================================

local function findNativeSky()
    for _, child in ipairs(Lighting:GetChildren()) do
        if child:IsA("Sky") and child ~= State.OwnedSky then
            return child
        end
    end
    return nil
end

--=============================================================================
-- Applying
--=============================================================================

-- Snapshot before the FIRST write only. See header - the `== nil` is the whole
-- point of this function.
local function setGuarded(sky, property, value)
    if State.Original[property] == nil then
        local ok, current = pcall(function() return sky[property] end)
        if ok then State.Original[property] = current end
    end
    pcall(function() sky[property] = value end)
end

local function apply()
    if not CONFIG.Enabled then return end

    local values = resolveValues()
    if not values then
        notify("unknown preset: " .. tostring(CONFIG.Preset))
        return
    end

    local native = findNativeSky()

    if native then
        -- The map has one. Adopt it rather than adding a second. See header.
        if State.OwnedSky then
            pcall(function() State.OwnedSky:Destroy() end)
            State.OwnedSky = nil
        end
        -- A different Sky than last time means our snapshot belongs to an
        -- object that no longer exists.
        if State.AdoptedSky ~= native then
            State.AdoptedSky = native
            table.clear(State.Original)
        end

        for _, property in ipairs(SKY_PROPERTIES) do
            if values[property] ~= nil then
                setGuarded(native, property, values[property])
            end
        end
        return
    end

    -- No native sky: make one.
    if State.OwnedSky and State.OwnedSky.Parent then
        for _, property in ipairs(SKY_PROPERTIES) do
            if values[property] ~= nil then
                pcall(function() State.OwnedSky[property] = values[property] end)
            end
        end
        return
    end

    local sky = Instance.new("Sky")
    for _, property in ipairs(SKY_PROPERTIES) do
        if values[property] ~= nil then
            pcall(function() sky[property] = values[property] end)
        end
    end
    sky.Parent = Lighting

    State.OwnedSky = sky
    State.AdoptedSky = nil
    table.clear(State.Original)
end

--=============================================================================
-- The loop
--=============================================================================
-- Re-applied slowly, because a map can swap its own sky between rounds and
-- because CONFIG can be edited while this is running. Once a second is far more
-- often than either happens.

task.spawn(function()
    while env.__SkyboxToken == Token do
        local ok, err = pcall(apply)
        if not ok then
            warn("[Skybox] " .. tostring(err))
        end
        task.wait(1)
    end
end)

notify("active - " .. tostring(CONFIG.Preset))

--=============================================================================
-- Cleanup
--=============================================================================

env.__SkyboxCleanup = function()
    env.__SkyboxToken = nil

    -- Ours: just remove it, and the map's sky reappears.
    if State.OwnedSky then
        pcall(function() State.OwnedSky:Destroy() end)
        State.OwnedSky = nil
    end

    -- Theirs: put every property we wrote back exactly as we found it.
    local adopted = State.AdoptedSky
    if adopted and adopted.Parent then
        for property, value in pairs(State.Original) do
            pcall(function() adopted[property] = value end)
        end
    end
    State.AdoptedSky = nil
    table.clear(State.Original)

    env.__SkyboxCleanup = nil
end
