--[[============================================================================
    SOUND VISUALIZER  -  see every sound as a ring in the world
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Every time a sound plays anywhere in the map, an expanding ring appears at
    the exact spot it came from - through walls, colour-coded, footsteps in one
    colour and everything else in another.

    Play with it for thirty seconds and it stops being a toy. Someone reloading
    two rooms away lights up. A player sprinting behind you draws a trail of
    rings. It is an ESP that needs no player list, no bounding boxes and no
    visibility checks, because the game is already telling you where everyone is
    - out loud.

===============================================================================
    WHY THIS WORKS AT ALL
===============================================================================

    Roblox 3D sound is not mixed on a server somewhere. To make a gunshot come
    from your left, the client needs a `Sound` object parented to a part at that
    position, in your own workspace, right now. So the position of every sound
    you can hear is sitting in the instance tree, exactly, as a number.

    That is the whole feature:

        sound.Played  ->  find the part it is parented to  ->  draw a ring there

    Worth internalising as a general habit: anything a game renders or plays for
    you has to exist on your machine before you perceive it. If a game can make
    you hear it, your client knows where it is - and audio is usually the least
    guarded of those channels, because nobody thinks of sound as information.

===============================================================================
    NO DRAWING API HERE
===============================================================================

    Unlike the ESP files, this uses no executor drawing at all:

        an invisible anchored Part          the position
        a SphereHandleAdornment on it       the ring
        AlwaysOnTop = true                  drawn through walls

    Adornments are ordinary Roblox instances that render in 3D and can be told
    to ignore depth. That makes them a real alternative to `Drawing` for
    anything that lives in the world rather than on the screen - and they work
    on executors with no Drawing API at all.

    The trade-off is that they exist in the instance tree, where a game could in
    principle notice them. Drawing objects cannot be seen by the game at all.
    For a purely local visual on a game that does not scan for foreign
    instances, the adornment is easier and looks better; if you are worried
    about scanning, use Drawing.

===============================================================================
    THE POOL, AND WHY IT IS CAPPED
===============================================================================

    A busy round produces a lot of sounds. Creating and destroying a part per
    sound would be constant churn, so effects are recycled:

        ActiveEffects   in flight right now
        PooledEffects   finished, waiting to be reused
        MaxEffects      hard ceiling; oldest is retired early to make room

    The ceiling matters as much as the pool. Without it, a grenade going off in
    a crowd spawns a hundred rings at once, and the frame it happens on is the
    frame you needed. A visual that degrades when things get busy is worse than
    one that has a limit and keeps its limit.

    THE EASE
        easedAlpha = 1 - (1 - alpha)^2

    The ring expands quickly then slows down, rather than growing at a constant
    rate. Sound does not behave like that physically, but it reads as an impact
    rather than an inflating balloon, and the fast part is at the start where
    you actually need to notice it.

===============================================================================
    TELLING A FOOTSTEP FROM A GUNSHOT
===============================================================================

    There is no field for it, so it is guesswork, and the guess is deliberately
    cheap: mash the sound's name, its part's name and its parent's name into one
    lowercase string and look for "foot", "step", "running" or "landing".

    Plus one heuristic for the sounds that are named nothing useful:

        parented to HumanoidRootPart, not looped, shorter than a second

    which is what a footstep looks like when its name will not say so. It gets
    some wrong. It is a colour choice, not a decision anything depends on, so
    wrong costs nothing - which is exactly when a cheap heuristic is the right
    tool. Do not reach for one where being wrong matters.

    TWO GATES WORTH KEEPING
    A sound below `MinVolume` is ignored, and so is one further away than its
    own `RollOffMaxDistance` - which is the distance past which the game itself
    would not have played it for you. Drawing a ring for a sound you could not
    have heard is inventing information rather than surfacing it, and it fills
    the screen with noise from the other side of the map.

    REQUIREMENTS
    None. This is the ESP for people whose executor has no Drawing API.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- "All" | "Enemies" | "Team" | "Self"
    Source = "Enemies",

    Footsteps = true,
    OtherSounds = true,

    FootstepColor = Color3.fromRGB(255, 210, 80),
    OtherColor = Color3.fromRGB(255, 90, 90),

    MinVolume = 0.05,    -- quieter than this is ignored
    MaxEffects = 32,     -- rings on screen at once; see header

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- How long a ring lives and how big it gets, by kind.
local FOOTSTEP_DURATION, OTHER_DURATION = 0.65, 0.9
local FOOTSTEP_START_RADIUS, OTHER_START_RADIUS = 0.45, 0.8
local FOOTSTEP_END_RADIUS, OTHER_END_RADIUS = 5, 9
local BASE_TRANSPARENCY = 0.28
local REPLAY_DEBOUNCE = 0.03

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Sound Visualizer", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__SoundVisualizerCleanup then
    pcall(env.__SoundVisualizerCleanup)
end

local Token = {}
env.__SoundVisualizerToken = Token

local Tracked = {}          -- sound -> { LastPlayedAt, Connections }
local ActiveEffects = {}
local PooledEffects = {}

--=============================================================================
-- Who made the sound
--=============================================================================

-- The Sound may hang off the part, off an Attachment on the part, or deeper.
local function emitterPart(sound)
    local parent = sound and sound.Parent
    if not parent then return nil end
    if parent:IsA("BasePart") then return parent end
    if parent:IsA("Attachment") and parent.Parent and parent.Parent:IsA("BasePart") then
        return parent.Parent
    end
    return parent:FindFirstAncestorWhichIsA("BasePart")
end

-- Walk up through Models, not just to the first one - a character's parts can
-- sit inside accessory or weapon models, and only the outer one is the
-- character Roblox knows about.
local function sourcePlayer(part)
    local model = part and part:FindFirstAncestorOfClass("Model") or nil
    while model do
        local player = Players:GetPlayerFromCharacter(model)
        if player then return player end
        model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model") or nil
    end
    return nil
end

-- Teams first, TeamID attribute as the fallback - which is what the game
-- actually replicates in a duel.
local function isEnemy(player)
    if not player or player == LocalPlayer then return false end
    if player.Team ~= nil and LocalPlayer.Team ~= nil then
        return player.Team ~= LocalPlayer.Team
    end
    local theirs = player:GetAttribute("TeamID")
    local ours = LocalPlayer:GetAttribute("TeamID")
    if theirs ~= nil and ours ~= nil then return theirs ~= ours end
    return true   -- unknown: treat as an enemy rather than hide it
end

local function isAllowed(player)
    local mode = CONFIG.Source
    if mode == "All" then return true end
    if mode == "Self" then return player == LocalPlayer end
    if mode == "Team" then return player ~= nil and player ~= LocalPlayer and not isEnemy(player) end
    return player ~= nil and isEnemy(player)   -- "Enemies"
end

-- Cheap and sometimes wrong, on purpose. See header.
local function isFootstep(sound, part)
    local descriptor = string.lower(table.concat({
        tostring(sound and sound.Name or ""),
        tostring(part and part.Name or ""),
        tostring(sound and sound.Parent and sound.Parent.Name or ""),
    }, " "))

    return descriptor:find("foot", 1, true) ~= nil
        or descriptor:find("step", 1, true) ~= nil
        or descriptor:find("running", 1, true) ~= nil
        or descriptor:find("landing", 1, true) ~= nil
        or (part and part.Name == "HumanoidRootPart"
            and sound.Looped == false
            and sound.TimeLength > 0
            and sound.TimeLength <= 1)
end

--=============================================================================
-- The rings
--=============================================================================

local function createEffect()
    local anchor = Instance.new("Part")
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false     -- invisible to raycasts, including the game's
    anchor.CanTouch = false
    anchor.CastShadow = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.05, 0.05, 0.05)
    anchor.Parent = Workspace

    local pulse = Instance.new("SphereHandleAdornment")
    pulse.Adornee = anchor
    pulse.AlwaysOnTop = true    -- through walls; see header
    pulse.ZIndex = 9
    pulse.Visible = false
    pulse.Parent = anchor

    return {
        Anchor = anchor,
        Pulse = pulse,
        StartedAt = 0,
        Duration = 0,
        StartRadius = 0,
        EndRadius = 0,
    }
end

local function deactivate(index, destroy)
    local effect = table.remove(ActiveEffects, index)
    if not effect then return end
    effect.Pulse.Visible = false
    if destroy then
        effect.Anchor:Destroy()
    else
        PooledEffects[#PooledEffects + 1] = effect
    end
end

local function spawnEffect(sound)
    if not CONFIG.Enabled or not sound or not sound.Parent then return end
    if sound.Volume < CONFIG.MinVolume then return end

    local part = emitterPart(sound)
    if not part or not isAllowed(sourcePlayer(part)) then return end

    -- Past the sound's own falloff you would not have heard it. See header.
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and sound.RollOffMaxDistance > 0
        and (part.Position - root.Position).Magnitude > sound.RollOffMaxDistance then
        return
    end

    local footstep = isFootstep(sound, part)
    if footstep and not CONFIG.Footsteps then return end
    if not footstep and not CONFIG.OtherSounds then return end

    -- At the ceiling, the oldest ring goes early rather than the new one being
    -- dropped: the newest sound is the one you need to see.
    if #ActiveEffects >= CONFIG.MaxEffects then
        deactivate(1, false)
    end

    local effect = table.remove(PooledEffects) or createEffect()
    local loudness = math.clamp(sound.Volume, 0.25, 2)

    effect.Anchor.CFrame = CFrame.new(part.Position)
    effect.StartedAt = tick()
    effect.Duration = footstep and FOOTSTEP_DURATION or OTHER_DURATION
    effect.StartRadius = footstep and FOOTSTEP_START_RADIUS or OTHER_START_RADIUS
    effect.EndRadius = (footstep and FOOTSTEP_END_RADIUS or OTHER_END_RADIUS) * loudness
    effect.Pulse.Color3 = footstep and CONFIG.FootstepColor or CONFIG.OtherColor
    effect.Pulse.Radius = effect.StartRadius
    effect.Pulse.Transparency = BASE_TRANSPARENCY
    effect.Pulse.Visible = true

    ActiveEffects[#ActiveEffects + 1] = effect
end

--=============================================================================
-- Watching every sound in the world
--=============================================================================

local function disconnectSound(sound)
    local tracked = Tracked[sound]
    if not tracked then return end
    for _, connection in pairs(tracked.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    Tracked[sound] = nil
end

local function registerSound(instance)
    if not instance or not instance:IsA("Sound") or Tracked[instance] then return end

    local tracked = { LastPlayedAt = 0, Connections = {} }
    Tracked[instance] = tracked

    tracked.Connections.Played = instance.Played:Connect(function()
        if env.__SoundVisualizerToken ~= Token then return end
        -- A sound restarted rapidly fires Played each time; one ring is enough.
        local now = tick()
        if now - tracked.LastPlayedAt < REPLAY_DEBOUNCE then return end
        tracked.LastPlayedAt = now
        spawnEffect(instance)
    end)

    tracked.Connections.Destroying = instance.Destroying:Connect(function()
        disconnectSound(instance)
    end)
end

--=============================================================================
-- The frame
--=============================================================================

local function update()
    local now = tick()
    -- Backwards, because deactivate() removes from the list we are walking.
    for index = #ActiveEffects, 1, -1 do
        local effect = ActiveEffects[index]
        local alpha = math.clamp((now - effect.StartedAt) / effect.Duration, 0, 1)
        if alpha >= 1 then
            deactivate(index, false)
        else
            local eased = 1 - ((1 - alpha) * (1 - alpha))    -- see header
            effect.Pulse.Radius = effect.StartRadius + (effect.EndRadius - effect.StartRadius) * eased
            effect.Pulse.Transparency = BASE_TRANSPARENCY + alpha * (1 - BASE_TRANSPARENCY)
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================
-- DescendantAdded, not ChildAdded: sounds live deep inside characters and
-- weapons. This is the opposite call from `throwable-esp.lua`, for the opposite
-- reason - here the thing we want really is buried.

local addedConn = Workspace.DescendantAdded:Connect(function(descendant)
    if env.__SoundVisualizerToken ~= Token then return end
    registerSound(descendant)
end)

local removingConn = Workspace.DescendantRemoving:Connect(function(descendant)
    if env.__SoundVisualizerToken ~= Token then return end
    if descendant:IsA("Sound") then disconnectSound(descendant) end
end)

for _, descendant in ipairs(Workspace:GetDescendants()) do
    registerSound(descendant)
end

local renderConn = RunService.RenderStepped:Connect(function()
    if env.__SoundVisualizerToken ~= Token then return end
    local ok, err = pcall(update)
    if not ok then
        warn("[Sound Visualizer] " .. tostring(err))
    end
end)

notify("active - " .. CONFIG.Source)

--=============================================================================
-- Cleanup
--=============================================================================

env.__SoundVisualizerCleanup = function()
    env.__SoundVisualizerToken = nil
    pcall(function() addedConn:Disconnect() end)
    pcall(function() removingConn:Disconnect() end)
    pcall(function() renderConn:Disconnect() end)

    for sound in pairs(Tracked) do
        disconnectSound(sound)
    end
    table.clear(Tracked)

    for index = #ActiveEffects, 1, -1 do
        deactivate(index, true)
    end
    for _, effect in ipairs(PooledEffects) do
        pcall(function() effect.Anchor:Destroy() end)
    end
    table.clear(PooledEffects)

    env.__SoundVisualizerCleanup = nil
end
