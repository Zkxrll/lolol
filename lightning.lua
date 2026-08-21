--[[============================================================================
    LIGHTNING  -  procedural lightning strikes around you
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Throws a lightning bolt down near you every few seconds: a forked bolt with
    branches, a flash of light, sparks where it lands, a ring of arcs across the
    ground, and a thunder clap that arrives late in proportion to how far away
    it struck.

    Purely local. Nobody else sees any of it. It is decoration, and it is the
    most fun file here to change numbers in.

    One difference from the menu version: there, lightning is part of the
    weather system and only strikes while the weather preset is Rain or
    Blizzard. Here it stands alone and strikes whenever it is on.

===============================================================================
    HOW A BOLT IS DRAWN
===============================================================================

    Straight line from cloud to ground, chopped into pieces, each piece shoved
    sideways at random. That is all a lightning bolt is.

        for index = 0, segments do
            local alpha = index / segments
            local point = start:Lerp(finish, alpha)
            ... jitter it ...
        end

    The one line that matters is the taper:

        local taper = math.sin(alpha * math.pi)

    `sin` is zero at both ends and one in the middle, so points near the cloud
    and near the ground barely move while the middle wanders. Without it the
    bolt detaches from the sky and misses the ground - it looks like a scribble
    instead of a strike. Any time you want to randomise the middle of something
    while pinning its ends, this is the shape.

    Piece count comes from length, `distance / 12`, clamped to 8-28. A short
    bolt with 28 segments is noise; a long one with 8 is a zigzag.

    Each piece is a `Beam` between two `Attachment`s, and all of them are
    parented to `Workspace.Terrain`. Terrain is a convenient host - it always
    exists, it is never destroyed between rounds, and nothing else in the game
    looks at its children.

    Three properties do the glow:

        beam.FaceCamera = true      a flat beam always turned toward you
        beam.LightEmission = 1      draw it bright, not lit
        beam.LightInfluence = 0     ignore world lighting entirely

    Without `FaceCamera` a beam is a flat ribbon and vanishes edge-on. Without
    the other two, a bolt at night is a grey stripe.

===============================================================================
    THUNDER ARRIVES LATE
===============================================================================

        delay = distance / 1225

    Sound travels about 1225 studs per second, so a strike 300 studs away is
    heard a quarter-second after it is seen. That single division is most of
    what makes the effect feel real - the flash and the bang arriving together
    is the giveaway that something is fake.

    Volume falls off with distance, and playback speed is randomised 0.75-1.0 so
    no two claps are identical.

    THE FIRE-AND-FORGET SOUND
    Look at how the clap is played:

        sound.PlayOnRemove = true
        sound.Parent = SoundService
        sound:Destroy()

    `PlayOnRemove` means "play when you are removed", so destroying it plays it.
    The sound instance is gone immediately, plays to the end anyway, and cleans
    itself up. No connection, no timer, no leak. It is the standard trick for a
    one-shot sound and worth remembering.

    THE GENERATION COUNTER
    Thunder is scheduled into the future, so a clap can be pending when you turn
    the feature off. Every strike stamps the current generation, and the delayed
    play checks it still matches:

        if generation ~= State.Generation then return end

    Same idea as the nonce in `auto-loadout.lua`. Anything you schedule for
    later needs a way to find out it is no longer wanted.

===============================================================================
    CLEANING UP
===============================================================================

    A strike makes 30-90 instances. All of them go into one list and the whole
    list is destroyed 0.24 seconds later - the flash is over long before you
    could count them.

    Collecting into a list as you build, then destroying the list, is much safer
    than trying to find your own instances afterwards by name. You never miss
    one, and you never destroy something that was not yours.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Timing and placement
    Interval = 2,        -- seconds between strikes
    MaxDistance = 80,    -- how far from you a strike can land, in studs
    Height = 220,        -- how high the bolt starts

    -- The bolt
    Color = Color3.fromRGB(214, 230, 255),
    Thickness = 4,
    Jaggedness = 7,      -- sideways wander. 0 is a straight line
    Branches = 12,       -- forks off the main bolt (0-24)
    Flash = 8,           -- brightness of the light at the impact. 0 = no light

    -- Sparks at the impact
    Sparks = true,
    SparkColor = Color3.fromRGB(238, 246, 255),
    SparkCount = 18,
    SparkThickness = 2.2,
    SparkDistance = 22,
    SparkSpeed = 22,

    -- The ring of arcs across the ground
    GroundArcs = true,
    GroundArcColor = Color3.fromRGB(238, 200, 255),
    GroundArcSize = 0.45,
    GroundArcCount = 14,

    -- Thunder
    Thunder = true,
    ThunderDelay = true,      -- off = instant clap, which sounds wrong on purpose
    ThunderVolume = 1,
    ThunderSoundId = "rbxassetid://79197041664081",
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local SPEED_OF_SOUND = 1225   -- studs per second
local STRIKE_LIFETIME = 0.24  -- seconds before everything is destroyed

local function notify(text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Lightning", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__LightningCleanup then
    pcall(env.__LightningCleanup)
end

local Token = {}
env.__LightningToken = Token

local State = {
    NextStrikeAt = 0,
    Generation = 0,   -- bumped on cleanup; see header
}

--=============================================================================
-- One segment of bolt
--=============================================================================

local function addSegment(instances, startPosition, endPosition, color, thickness, brightness)
    local near = Instance.new("Attachment")
    near.Position = startPosition
    near.Parent = Workspace.Terrain

    local far = Instance.new("Attachment")
    far.Position = endPosition
    far.Parent = Workspace.Terrain

    local beam = Instance.new("Beam")
    beam.Attachment0 = near
    beam.Attachment1 = far
    beam.Color = ColorSequence.new(color)
    beam.Width0 = thickness
    beam.Width1 = math.max(0.05, thickness * 0.72)   -- tapers along its length
    beam.FaceCamera = true       -- see header
    beam.LightEmission = 1
    beam.LightInfluence = 0
    beam.Brightness = math.max(1, brightness)
    -- Fades out toward the far end, so branches dissolve rather than stop.
    beam.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.02),
        NumberSequenceKeypoint.new(0.8, 0.12),
        NumberSequenceKeypoint.new(1, 1),
    })
    beam.Parent = Workspace.Terrain

    table.insert(instances, beam)
    table.insert(instances, near)
    table.insert(instances, far)
end

--=============================================================================
-- The path of the bolt
--=============================================================================

local function buildPoints(startPosition, endPosition, jaggedness)
    local distance = (endPosition - startPosition).Magnitude
    local segments = math.clamp(math.floor(distance / 12), 8, 28)

    local points = table.create(segments + 1)
    for index = 0, segments do
        local alpha = index / segments
        local point = startPosition:Lerp(endPosition, alpha)

        -- Ends stay put, middle wanders. See header - this is the whole trick.
        if index > 0 and index < segments then
            local taper = math.sin(alpha * math.pi)
            point = point + Vector3.new(
                (math.random() - 0.5) * jaggedness * 2 * taper,
                (math.random() - 0.5) * jaggedness * taper,       -- less vertical wander
                (math.random() - 0.5) * jaggedness * 2 * taper
            )
        end
        points[index + 1] = point
    end
    return points
end

--=============================================================================
-- Thunder
--=============================================================================

local function playThunder(distance)
    if not CONFIG.Thunder then return end

    local generation = State.Generation
    local delayTime = CONFIG.ThunderDelay and (distance / SPEED_OF_SOUND) or 0
    local volume = CONFIG.ThunderVolume * math.max(0.3, 1 - distance / 320)
    local playbackSpeed = 0.75 + math.random() * 0.25

    task.delay(delayTime, function()
        if env.__LightningToken ~= Token then return end
        if generation ~= State.Generation then return end   -- see header

        local sound = Instance.new("Sound")
        sound.SoundId = CONFIG.ThunderSoundId
        sound.Volume = math.max(0, volume)
        sound.PlaybackSpeed = playbackSpeed
        sound.PlayOnRemove = true      -- fire and forget; see header
        sound.Parent = SoundService
        sound:Destroy()
    end)
end

--=============================================================================
-- One strike
--=============================================================================

local function render(startPosition, endPosition)
    local instances = {}

    local points = buildPoints(startPosition, endPosition, math.max(0, CONFIG.Jaggedness))
    for index = 1, #points - 1 do
        addSegment(instances, points[index], points[index + 1],
            CONFIG.Color, math.max(0.05, CONFIG.Thickness), math.max(0, CONFIG.Flash))
    end

    -- Branches: pick a point on the bolt, fork downward and outward from it.
    -- Never the first or last point, so a branch cannot sprout from the cloud
    -- or from the ground.
    for _ = 1, math.clamp(math.floor(CONFIG.Branches), 0, 24) do
        local source = points[math.random(2, math.max(2, #points - 2))]
        local length = math.max(4, CONFIG.Jaggedness * (1.5 + math.random()))
        local branchEnd = source + Vector3.new(
            (math.random() - 0.5) * length * 2,
            -math.random() * length,          -- always downward
            (math.random() - 0.5) * length * 2
        )
        addSegment(instances, source, branchEnd, CONFIG.Color,
            CONFIG.Thickness * 0.45, CONFIG.Flash * 0.7)
    end

    local impact = Instance.new("Attachment")
    impact.Position = endPosition
    impact.Parent = Workspace.Terrain
    table.insert(instances, impact)

    if CONFIG.Flash > 0 then
        local light = Instance.new("PointLight")
        light.Color = CONFIG.Color
        light.Brightness = CONFIG.Flash
        light.Range = math.max(18, CONFIG.Flash * 5)
        light.Shadows = true
        light.Parent = impact
        table.insert(instances, light)
    end

    if CONFIG.Sparks then
        local sparkSpeed = math.max(2, CONFIG.SparkSpeed)
        local sparkDistance = math.max(2, CONFIG.SparkDistance)
        local sparkThickness = math.max(0.2, CONFIG.SparkThickness)

        local sparks = Instance.new("ParticleEmitter")
        sparks.Texture = "rbxassetid://119455261341623"
        sparks.Rate = 0                    -- nothing continuous; we Emit once
        sparks.Color = ColorSequence.new(CONFIG.SparkColor)
        sparks.LightEmission = 1
        sparks.Speed = NumberRange.new(sparkSpeed * 0.65, sparkSpeed)
        -- Lifetime derived from how far they should travel, so distance and
        -- speed stay independent of each other.
        sparks.Lifetime = NumberRange.new(
            math.max(0.10, sparkDistance / sparkSpeed * 0.65),
            math.max(0.15, sparkDistance / sparkSpeed)
        )
        sparks.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, sparkThickness * 0.035),
            NumberSequenceKeypoint.new(1, 0),
        })
        sparks.SpreadAngle = Vector2.new(180, 180)   -- every direction
        sparks.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.2, 0)
        sparks.Parent = impact
        sparks:Emit(math.clamp(math.floor(CONFIG.SparkCount), 0, 40))
        table.insert(instances, sparks)
    end

    -- Arcs crawling outward across the ground from the impact.
    if CONFIG.GroundArcs then
        local size = math.max(0, CONFIG.GroundArcSize)
        for _ = 1, math.clamp(math.floor(CONFIG.GroundArcCount), 0, 30) do
            local angle = math.random() * math.pi * 2
            local length = (4 + math.random() * 12) * size
            local arcEnd = endPosition + Vector3.new(
                math.cos(angle) * length,
                math.random() * length * 0.35,   -- barely leaves the floor
                math.sin(angle) * length
            )
            addSegment(instances, endPosition, arcEnd, CONFIG.GroundArcColor,
                CONFIG.Thickness * 0.22, CONFIG.Flash * 0.5)
        end
    end

    -- One list, one timer. See header.
    task.delay(STRIKE_LIFETIME, function()
        for _, instance in ipairs(instances) do
            if instance and instance.Parent then
                pcall(function() instance:Destroy() end)
            end
        end
    end)
end

--=============================================================================
-- Where to strike
--=============================================================================

local function strike()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local limit = math.max(10, CONFIG.MaxDistance)
    -- Biased outward: a minimum radius so bolts do not land on your face, then
    -- the rest of the range spread evenly.
    local minimum = math.min(18, limit)
    local radius = minimum + math.random() * math.max(0, limit - minimum)

    local angle = math.random() * math.pi * 2
    local origin = camera.CFrame.Position
    local x = origin.X + math.cos(angle) * radius
    local z = origin.Z + math.sin(angle) * radius

    local height = math.max(50, CONFIG.Height)

    -- Find the floor under the chosen spot. Your own character is excluded, or
    -- a bolt overhead would stop on your head.
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    if LocalPlayer.Character then
        params.FilterDescendantsInstances = { LocalPlayer.Character }
    end

    local result = Workspace:Raycast(
        Vector3.new(x, origin.Y + height, z),
        Vector3.new(0, -2000, 0),
        params
    )
    -- No floor found (over a void) - put it somewhere plausible anyway.
    local groundY = result and result.Position.Y or (origin.Y - 40)

    local finish = Vector3.new(x, groundY, z)
    local start = Vector3.new(
        x + (math.random() - 0.5) * 30,   -- the cloud end is offset, so bolts lean
        groundY + height,
        z + (math.random() - 0.5) * 30
    )

    render(start, finish)
    playThunder(radius)
end

--=============================================================================
-- The loop
--=============================================================================

local renderConn = RunService.Heartbeat:Connect(function()
    if env.__LightningToken ~= Token then return end
    if not CONFIG.Enabled then return end

    local now = tick()
    if now < State.NextStrikeAt then return end
    State.NextStrikeAt = now + math.max(0.2, CONFIG.Interval)

    local ok, err = pcall(strike)
    if not ok then
        warn("[Lightning] " .. tostring(err))
    end
end)

notify("active")

--=============================================================================
-- Cleanup
--=============================================================================

env.__LightningCleanup = function()
    env.__LightningToken = nil
    State.Generation = State.Generation + 1   -- cancels pending thunder
    pcall(function() renderConn:Disconnect() end)
    env.__LightningCleanup = nil
end
