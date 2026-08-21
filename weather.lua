--[[============================================================================
    WEATHER  -  snow, rain or a blizzard, locally
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Puts weather on the map for you and nobody else. Three presets, and sliders
    for how heavy it is, how fast it falls, how big the flakes are, how much it
    glows, how far it spreads, and which way the wind blows.

    Pairs with [`lightning.lua`](lightning.lua), which is what the menu version
    triggers during Rain and Blizzard.

===============================================================================
    ONE SMALL EMITTER THAT FOLLOWS YOU
===============================================================================

    The naive approach is to cover the map. A RIVALS map is hundreds of studs
    across, and filling it with snow at a density you would actually notice runs
    into millions of particles.

    Instead there is one 140x140 invisible part, parked above the camera,
    emitting downward, and moved to wherever the camera is every frame:

        part.Position = camera.CFrame.Position + Vector3.new(0, height, 0)

    You cannot see weather that is three hundred studs away anyway. A small
    volume that follows you looks exactly the same as a large one and costs a
    fraction of it.

    This generalises well beyond weather. Any ambient effect that is supposed to
    be "everywhere" only has to exist where the viewer is - fog, dust, embers,
    fireflies, falling leaves. Build a small one and move it.

===============================================================================
    WHY EACH PRESET IS SEVERAL EMITTERS
===============================================================================

        Snow      3 layers
        Rain      2 layers
        Blizzard  4 layers

    One emitter gives you flat, uniform, obviously-fake weather. The depth comes
    from layers that disagree with each other: a slow layer of small flakes, a
    fast layer of large ones, a dense layer of tiny specks. As you move, they
    slide past each other at different rates, and that parallax is what your eye
    reads as distance.

    Nothing about any single layer is impressive. The effect is entirely in the
    disagreement between them, which is worth remembering whenever something you
    have built looks flat.

===============================================================================
    SPECS AND MULTIPLIERS  -  the bit worth copying
===============================================================================

    Each emitter is stored alongside the numbers it was built from:

        { Emitter = emitter, Spec = spec }

    and every slider is a MULTIPLIER on the spec rather than a value written
    straight onto the emitter:

        emitter.Rate = spec.BaseRate * intensity * rate

    That is what lets one Intensity slider drive four emitters that must stay in
    proportion to each other. Snow's dense layer sits at rate 48 and its heavy
    layer at 12; multiply both and they stay four-to-one at every setting.

    Write the slider value straight onto the emitter instead and you destroy the
    base the moment you touch it - there is nothing left to scale from, and the
    layers all collapse to the same value.

    Keep the source numbers. Apply settings as transformations of them, not as
    replacements. This is the same reason `lighting.lua` snapshots each property
    before its first write.

    REBUILD vs RECONCILE
    Changing the preset rebuilds every emitter. Changing a slider only walks the
    existing ones and updates their numbers. That distinction matters: creating
    a ParticleEmitter starts it empty, so rebuilding on every slider tick would
    wipe every particle in flight and make the weather stutter each time you
    nudge anything.

    Ask whether a change can be applied to what exists before you throw it away
    and build it again.

===============================================================================
    TWO DETAILS
===============================================================================

    WIND IS AN ANGLE, NOT A VECTOR

        windX = sin(angle) * strength
        windZ = cos(angle) * strength
        emitter.Acceleration = Vector3.new(windX, spec.BaseAccelerationY, windZ)

    One direction dial and one strength slider is much easier to use than two
    numbers, and the vertical component is left alone at the spec's own value -
    wind should not change how fast things fall.

    RAIN FACES THE CAMERA, SNOW DOES NOT
    The rain layers set `ParticleOrientation.FacingCamera` so a streak always
    presents its length to you. Snow leaves the default, because a flake
    tumbling in three dimensions is the point of a flake. Same emitter, opposite
    setting, both correct.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    Preset = "Snow",     -- Snow | Rain | Blizzard

    -- All multipliers on the preset's own numbers. 1 = as designed.
    Intensity = 1,       -- how much of it there is
    Rate = 1,            -- multiplies intensity again; separate knob
    Speed = 1,
    Size = 1,
    Spread = 25,
    Glow = 0.6,          -- 0-1

    Color = Color3.new(1, 1, 1),

    WindStrength = 0,    -- studs/sec^2 sideways
    WindAngle = 0,       -- degrees

    Height = 45,         -- how far above you the emitter sits

    Notify = true,
}

--=============================================================================
-- The presets
--=============================================================================
-- Layers, in the order they are created. See header for why there are several.

local WEATHER_PRESETS = {
    Snow = {
        { Texture = "rbxassetid://119455261341623", BaseRate = 18, SpeedMin = 8,  SpeedMax = 12, SizeStart = 0.025, SizeEnd = 0.05, TransparencyMax = 0.4,  LifetimeMin = 4,   LifetimeMax = 6,   RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -25,  RotationSpeedMax = 25,  BaseSpread = 0.4,  BaseAccelerationY = -3 },
        { Texture = "rbxassetid://135953828575052", BaseRate = 12, SpeedMin = 12, SpeedMax = 18, SizeStart = 0.03,  SizeEnd = 0.08, TransparencyMax = 0.5,  LifetimeMin = 3,   LifetimeMax = 5,   RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -35,  RotationSpeedMax = 35,  BaseSpread = 0.45, BaseAccelerationY = -4 },
        { Texture = "rbxassetid://119888390708774", BaseRate = 48, SpeedMin = 10, SpeedMax = 16, SizeStart = 0.06,  SizeEnd = 0.13, TransparencyMax = 0.15, LifetimeMin = 4,   LifetimeMax = 6,   RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -90,  RotationSpeedMax = 90,  BaseSpread = 0.5,  BaseAccelerationY = -2 },
    },
    Rain = {
        { Texture = "rbxassetid://1822883048",      BaseRate = 180, SpeedMin = 80,  SpeedMax = 105, SizeStart = 0.18, SizeEnd = 0.35, TransparencyMax = 0.1,  LifetimeMin = 1.4, LifetimeMax = 1.8, RotationMin = -5, RotationMax = 5, RotationSpeedMin = 0, RotationSpeedMax = 0, BaseSpread = 0.4, BaseAccelerationY = -55, Orientation = Enum.ParticleOrientation.FacingCamera },
        { Texture = "rbxassetid://113640658844067", BaseRate = 75,  SpeedMin = 100, SpeedMax = 135, SizeStart = 0.22, SizeEnd = 0.42, TransparencyMax = 0.25, LifetimeMin = 1.1, LifetimeMax = 1.6, RotationMin = -4, RotationMax = 4, RotationSpeedMin = 0, RotationSpeedMax = 0, BaseSpread = 0.3, BaseAccelerationY = -70, Orientation = Enum.ParticleOrientation.FacingCamera },
    },
    Blizzard = {
        { Texture = "rbxassetid://119455261341623", BaseRate = 25, SpeedMin = 25, SpeedMax = 40, SizeStart = 0.025, SizeEnd = 0.06, TransparencyMax = 0.35, LifetimeMin = 2.5, LifetimeMax = 4,   RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -45,  RotationSpeedMax = 45,  BaseSpread = 0.55, BaseAccelerationY = -8 },
        { Texture = "rbxassetid://135953828575052", BaseRate = 20, SpeedMin = 28, SpeedMax = 45, SizeStart = 0.035, SizeEnd = 0.09, TransparencyMax = 0.45, LifetimeMin = 2.2, LifetimeMax = 3.8, RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -55,  RotationSpeedMax = 55,  BaseSpread = 0.6,  BaseAccelerationY = -10 },
        { Texture = "rbxassetid://119888390708774", BaseRate = 90, SpeedMin = 22, SpeedMax = 38, SizeStart = 0.07,  SizeEnd = 0.15, TransparencyMax = 0.1,  LifetimeMin = 2.8, LifetimeMax = 4.5, RotationMin = 0,   RotationMax = 360, RotationSpeedMin = -120, RotationSpeedMax = 120, BaseSpread = 0.7,  BaseAccelerationY = -7 },
        { Texture = "rbxassetid://1822883048",      BaseRate = 50, SpeedMin = 55, SpeedMax = 80, SizeStart = 0.14,  SizeEnd = 0.28, TransparencyMax = 0.2,  LifetimeMin = 1.8, LifetimeMax = 2.6, RotationMin = -12, RotationMax = 12,  RotationSpeedMin = 0,    RotationSpeedMax = 0,   BaseSpread = 0.5,  BaseAccelerationY = -35 },
    },
}

--=============================================================================
-- Setup
--=============================================================================

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Weather", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__WeatherCleanup then
    pcall(env.__WeatherCleanup)
end

local Token = {}
env.__WeatherToken = Token

local State = {
    Part = nil,
    Emitters = {},        -- { Emitter, Spec } - the Spec is the point; see header
    ActivePreset = nil,
}

--=============================================================================
-- Building
--=============================================================================

local function clearEmitters()
    for _, record in ipairs(State.Emitters) do
        if record.Emitter then
            pcall(function() record.Emitter:Destroy() end)
        end
    end
    table.clear(State.Emitters)
    State.ActivePreset = nil
end

local function ensurePart()
    local part = State.Part
    if part and part.Parent then return part end

    part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Transparency = 1
    part.Size = Vector3.new(140, 1, 140)   -- see header: small, and it follows you
    part.Parent = Workspace

    State.Part = part
    State.ActivePreset = nil    -- a new part has no emitters on it
    return part
end

local function rebuild(presetName)
    local specs = WEATHER_PRESETS[presetName]
    clearEmitters()

    local part = State.Part
    if not specs or not part then return end

    State.ActivePreset = presetName

    for _, spec in ipairs(specs) do
        local emitter = Instance.new("ParticleEmitter")
        emitter.Shape = Enum.ParticleEmitterShape.Box
        emitter.EmissionDirection = Enum.NormalId.Bottom
        emitter.Enabled = true
        emitter.Texture = spec.Texture

        -- Fades in and out at the ends of each particle's life, so nothing
        -- appears or vanishes abruptly in front of you.
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.15, spec.TransparencyMax),
            NumberSequenceKeypoint.new(0.85, spec.TransparencyMax),
            NumberSequenceKeypoint.new(1, 1),
        })

        emitter.Lifetime = NumberRange.new(spec.LifetimeMin, spec.LifetimeMax)
        emitter.Rotation = NumberRange.new(spec.RotationMin, spec.RotationMax)
        emitter.RotSpeed = NumberRange.new(spec.RotationSpeedMin, spec.RotationSpeedMax)
        emitter.LightInfluence = 0     -- weather should not be lit by the map

        -- Rain only. See header.
        if spec.Orientation then
            emitter.Orientation = spec.Orientation
        end

        emitter.Parent = part
        table.insert(State.Emitters, { Emitter = emitter, Spec = spec })
    end
end

--=============================================================================
-- Applying the sliders
--=============================================================================
-- Everything here multiplies the spec. Nothing replaces it. See header.

local function scaleSizeSequence(startValue, endValue, scale)
    return NumberSequence.new({
        NumberSequenceKeypoint.new(0, startValue * scale),
        NumberSequenceKeypoint.new(1, endValue * scale),
    })
end

local function reconcile()
    local intensity = math.max(0, CONFIG.Intensity)
    local rate = math.max(0, CONFIG.Rate)
    local speed = math.max(0, CONFIG.Speed)
    local size = math.max(0, CONFIG.Size)
    local spread = math.max(0, CONFIG.Spread)
    local glow = math.clamp(CONFIG.Glow, 0, 1)

    local color = typeof(CONFIG.Color) == "Color3" and CONFIG.Color or Color3.new(1, 1, 1)

    -- One dial and one strength, turned into a sideways acceleration.
    local angle = math.rad(CONFIG.WindAngle)
    local windX = math.sin(angle) * CONFIG.WindStrength
    local windZ = math.cos(angle) * CONFIG.WindStrength

    for _, record in ipairs(State.Emitters) do
        local emitter, spec = record.Emitter, record.Spec
        if emitter and emitter.Parent and spec then
            emitter.Rate = spec.BaseRate * intensity * rate
            emitter.Speed = NumberRange.new(spec.SpeedMin * speed, spec.SpeedMax * speed)
            emitter.Size = scaleSizeSequence(spec.SizeStart, spec.SizeEnd, size)
            emitter.LightEmission = glow

            local spreadAngle = spec.BaseSpread * spread
            emitter.SpreadAngle = Vector2.new(spreadAngle, spreadAngle)

            emitter.Color = ColorSequence.new(color)
            -- Wind sideways; the spec keeps control of how fast it falls.
            emitter.Acceleration = Vector3.new(windX, spec.BaseAccelerationY, windZ)
        end
    end
end

--=============================================================================
-- Refresh
--=============================================================================

local function destroyWeather()
    clearEmitters()
    local part = State.Part
    State.Part = nil
    if part then
        pcall(function() part:Destroy() end)
    end
end

local function refresh()
    if not CONFIG.Enabled then
        if State.Part then destroyWeather() end
        return
    end

    local preset = WEATHER_PRESETS[CONFIG.Preset] and CONFIG.Preset or "Snow"
    ensurePart()

    -- Rebuild only when the preset actually changed. See header.
    if State.ActivePreset ~= preset then
        rebuild(preset)
    end
    reconcile()
end

--=============================================================================
-- The loop
--=============================================================================

local followConn = RunService.Heartbeat:Connect(function()
    if env.__WeatherToken ~= Token then return end

    local part = State.Part
    local camera = Workspace.CurrentCamera
    if part and part.Parent and camera then
        part.Position = camera.CFrame.Position + Vector3.new(0, CONFIG.Height, 0)
    end
end)

-- Slow, because settings only change when you edit CONFIG. The per-frame work
-- above is one position write.
task.spawn(function()
    while env.__WeatherToken == Token do
        local ok, err = pcall(refresh)
        if not ok then
            warn("[Weather] " .. tostring(err))
        end
        task.wait(0.5)
    end
end)

notify("active - " .. tostring(CONFIG.Preset))

--=============================================================================
-- Cleanup
--=============================================================================

env.__WeatherCleanup = function()
    env.__WeatherToken = nil
    pcall(function() followConn:Disconnect() end)
    destroyWeather()
    env.__WeatherCleanup = nil
end
