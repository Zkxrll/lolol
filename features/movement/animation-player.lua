--[[============================================================================
    ANIMATION PLAYER  -  play any Roblox animation on your character
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Loads an animation by asset id and loops it on your character, at a speed
    you choose, optionally looping only a slice of it. Type in an id, and you
    are breakdancing in the middle of a gunfight.

    THIS ONE IS DIFFERENT - READ THIS.

    Almost every other visual feature in this project is local: it changes your
    screen and nobody else can see it. This one is not. Animations you play on
    your own character REPLICATE - the server passes them to everyone in the
    server, and they all watch you do it.

    That is the entire point of the feature, and it also means it is the most
    visible thing here. It is not "detectable" in the sense of an anticheat
    catching a memory write, because you are using the animation system exactly
    as it was designed. It is detectable in the sense that a human being can see
    you doing a T-pose while sprinting and report you. Treat those as different
    risks, because they are.

===============================================================================
    ANIMATOR, NOT HUMANOID
===============================================================================

    The old way was `humanoid:LoadAnimation(animation)`. It is deprecated, and
    on modern Roblox it either warns or does not work at all. Animations now go
    through an `Animator` object, which lives inside the Humanoid:

        local animator = humanoid:FindFirstChildOfClass("Animator")
        local track = animator:LoadAnimation(animation)

    The catch is that the Animator is created by the engine a moment AFTER the
    character spawns, so a script that runs on spawn and looks for it will very
    often find nothing. The tempting fix is `WaitForChild`, which blocks; the
    fix used here does not block:

        humanoid.ChildAdded:Connect(function(child)
            if child:IsA("Animator") and Player.Humanoid == humanoid then
                apply(true)
            end
        end)

    Note the second half of that condition. By the time the Animator appears you
    may already have died and respawned, in which case this connection belongs
    to a character that no longer matters and must not touch the new one.
    Connections outlive the thing they were made for; check that the world still
    looks the way it did when you connected.

===============================================================================
    THE ONE THAT CATCHES EVERYONE: NETWORK OWNERSHIP
===============================================================================

    When your character spawns, the SERVER owns it for a short window - a few
    hundred milliseconds, variable, longer on a bad connection. Ownership then
    transfers to you, and from that moment your client is the authority on where
    your character is and what it is doing.

    An animation started before that handover plays perfectly on your screen and
    is never seen by anyone else. It looks like it worked. It did not.

    That is what the `awaitOwnership` flag is for. When we start an animation
    early we remember that we did, and the update loop watches for the handover:

        if AwaitingOwnership and humanoid and humanoid.RootPart then
            AwaitingOwnership = false
            apply(false)          -- start it again, properly this time
        end

    `humanoid.RootPart` being non-nil is the practical signal that the character
    is fully assembled and yours. There is no event for "you now own this", so
    you watch for the thing that becomes true at the same moment.

    The general lesson: when something works on
    your screen but nobody else sees it, suspect a replication window, not your
    code. Start it, and then start it again once the world has settled.

===============================================================================
    THE OTHER TWO DETAILS
===============================================================================

    PRIORITY. `track.Priority = Enum.AnimationPriority.Action4` is the highest
    band Roblox has. Your character is already playing idle, walk, and whatever
    the weapon is doing; a track at a lower priority just loses to them and you
    see nothing. If your animation "does not play", priority is the first thing
    to check.

    RESTART ON STOP. The game stops tracks for its own reasons - state changes,
    getting hit, equipping something. So the loop notices a track that stopped
    and starts a fresh one rather than trying to resume the dead one:

        if not track.IsPlaying then
            track:Destroy()
            apply(false)
        end

    A stopped AnimationTrack is not reusable in any way you want to rely on.
    Throw it away and load again; it is cheap.

===============================================================================
    THE LOOP WINDOW
===============================================================================

    `LoopStartPercent` and `LoopEndPercent` cut the animation down to a slice -
    useful when only one second of a ten-second emote is the part you wanted.

    It is enforced by checking the playhead every frame rather than by
    arithmetic on the track length:

        if track.TimePosition >= windowEnd or track.TimePosition < windowStart then
            track.TimePosition = windowStart
        end

    Both halves of that comparison are needed. The `>=` catches the normal case
    of running off the end. The `<` catches the playhead being *before* the
    window, which happens when the track loops back to zero on its own, and also
    when speed is negative and it is running backwards. Checking the position
    you actually have beats predicting where it should be.

    REQUIREMENTS
    None. Ordinary Roblox animation API.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Any Roblox animation asset id. A full URL works too - only the digits
    -- are read out of it.
    AnimationId = "507771019",

    -- 1 is normal. 2 is double speed. Negative runs it backwards.
    Speed = 1,

    -- Loop only part of the animation. 0 and 100 mean the whole thing.
    LoopStartPercent = 0,
    LoopEndPercent = 100,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Animation Player", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AnimationPlayerCleanup then
    pcall(env.__AnimationPlayerCleanup)
end

local Token = {}
env.__AnimationPlayerToken = Token

local State = {
    Character = nil,
    Humanoid = nil,
    Track = nil,
    AnimatorWait = nil,       -- the ChildAdded connection, when we are waiting
    AwaitingOwnership = false,
    LastLoadFailure = nil,    -- so a bad id warns once, not every frame
}

--=============================================================================
-- Reading the id
--=============================================================================
-- People paste "507771019", "rbxassetid://507771019" and whole catalogue URLs.
-- Pulling the digits out handles all three.

local function resolveAnimationId()
    local value = CONFIG.AnimationId
    if type(value) ~= "string" then
        value = tostring(value)
    end
    return value:match("%d+")
end

--=============================================================================
-- Stopping
--=============================================================================

local function stop()
    if State.AnimatorWait then
        State.AnimatorWait:Disconnect()
        State.AnimatorWait = nil
    end

    local track = State.Track
    State.Track = nil
    if track then
        pcall(track.Stop, track)
        pcall(track.Destroy, track)
    end
end

--=============================================================================
-- Starting
--=============================================================================

local function apply(awaitOwnership)
    stop()
    State.AwaitingOwnership = false

    if not CONFIG.Enabled then return end

    local humanoid = State.Humanoid
    if not humanoid or humanoid.Parent == nil then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        -- Not there yet. Wait for it without blocking, and check on arrival
        -- that this is still the character we care about. See the header.
        State.AnimatorWait = humanoid.ChildAdded:Connect(function(child)
            if child:IsA("Animator") and State.Humanoid == humanoid then
                apply(true)
            end
        end)
        return
    end

    local animationId = resolveAnimationId()
    if not animationId then return end

    -- The Animation instance is only a carrier for the id. Once the track is
    -- loaded it has what it needs, so this can go straight away.
    local animation = Instance.new("Animation")
    animation.AnimationId = "rbxassetid://" .. animationId
    local ok, track = pcall(animator.LoadAnimation, animator, animation)
    animation:Destroy()

    if not ok or not track then
        -- Warn once per bad id. Without this check, a typo produces a
        -- notification every time the loop runs, forever.
        if State.LastLoadFailure ~= animationId then
            State.LastLoadFailure = animationId
            notify("Animation " .. animationId .. " could not be loaded.")
        end
        return
    end
    State.LastLoadFailure = nil

    -- Action4 is the top priority band; anything lower loses to the game's own
    -- idle and walk tracks. See the header.
    track.Priority = Enum.AnimationPriority.Action4
    track.Looped = true

    State.Track = track
    track:Play()
    track:AdjustSpeed(CONFIG.Speed)

    State.AwaitingOwnership = awaitOwnership == true
end

--=============================================================================
-- The loop window
--=============================================================================

local function enforceWindow(track)
    local length = track.Length
    -- Length is 0 until the asset finishes downloading. Nothing to clamp yet.
    if type(length) ~= "number" or length <= 0 then return end

    local windowStart = math.clamp(CONFIG.LoopStartPercent or 0, 0, 100) / 100 * length
    local windowEnd = math.clamp(CONFIG.LoopEndPercent or 100, 0, 100) / 100 * length
    if windowEnd <= windowStart then return end

    -- Both comparisons matter. See the header.
    if track.TimePosition >= windowEnd or track.TimePosition < windowStart then
        track.TimePosition = windowStart
    end
end

--=============================================================================
-- Per-frame update
--=============================================================================

local function update()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid") or nil

    -- New character (respawn) - throw everything away and start over. Note
    -- this also catches the humanoid being replaced under an unchanged
    -- character model, which does happen.
    if character ~= State.Character or humanoid ~= State.Humanoid then
        stop()
        State.Character = character
        State.Humanoid = humanoid
        apply(true)
        return
    end

    local track = State.Track
    if not track then return end

    -- The game stopped our track. Load a fresh one; a stopped track is not
    -- worth resuming.
    if not track.IsPlaying then
        State.Track = nil
        pcall(track.Destroy, track)
        apply(false)
        return
    end

    -- The ownership handover finally happened. Restart so it replicates. See
    -- the header - this is the important line in the file.
    if State.AwaitingOwnership and humanoid and humanoid.RootPart then
        State.AwaitingOwnership = false
        apply(false)
        return
    end

    enforceWindow(track)

    -- Cheap enough to reassert every frame, and it means editing CONFIG.Speed
    -- while this is running takes effect immediately.
    pcall(track.AdjustSpeed, track, CONFIG.Speed)
end

local connection
connection = RunService.Heartbeat:Connect(function()
    if env.__AnimationPlayerToken ~= Token then
        connection:Disconnect()
        return
    end
    local ok, err = pcall(update)
    if not ok then
        warn("[Animation Player] " .. tostring(err))
    end
end)

notify(CONFIG.Enabled and "active" or "loaded, disabled")

--=============================================================================
-- Cleanup
--=============================================================================

env.__AnimationPlayerCleanup = function()
    env.__AnimationPlayerToken = nil
    if connection then
        connection:Disconnect()
        connection = nil
    end
    stop()
    State.Character = nil
    State.Humanoid = nil
    State.AwaitingOwnership = false
    State.LastLoadFailure = nil
    env.__AnimationPlayerCleanup = nil
end