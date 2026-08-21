--[[============================================================================
    AMBIENCE  -  a looping background sound over the map
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Plays a sound on loop, for you only - rain, wind, music, whatever you point
    it at. Completes the World set alongside `lighting.lua`, `weather.lua`,
    `lightning.lua` and `skybox.lua`.

    It is here for one specific idea.

===============================================================================
    IDEMPOTENT REFRESH
===============================================================================

    This runs on a loop, and every pass does the same thing: work out what the
    world should look like, compare it with what is there, and change only the
    difference.

        no sound wanted        -> destroy ours if we have one, stop
        sound wanted, none     -> create it
        wanted, different id   -> set the id and Play
        wanted, same id, quiet -> Play
        wanted, same id, going -> do nothing

    Written that way, running it once and running it fifty times produce exactly
    the same result. That is what "idempotent" means, and it is why the loop is
    allowed to be dumb - it never has to know what changed, or whether it has
    run before, or in what order things happened.

    The alternative shape - an `onEnabled` that creates and an `onDisabled` that
    destroys and an `onSoundChanged` that swaps - has to handle every transition
    between those states correctly, including the ones you did not think of
    (enabled twice, disabled before it ever started, id changed while stopped).
    That is where the bugs live, and it is more code.

    Look at the specific comparison that matters:

        if ActiveSource ~= source or sound.SoundId ~= source then
            sound.SoundId = source
            sound:Play()
        elseif not sound.IsPlaying then
            sound:Play()
        end

    Calling `Play()` on a sound that is already playing restarts it from the
    beginning. On a one-second loop that is a stutter every pass. So the id is
    only written when it actually differs, and `Play` is only called when
    something genuinely needs starting.

    Both checks are there for a reason: `ActiveSource` catches us changing it,
    and `sound.SoundId` catches anything else having changed it underneath us.
    They agree almost always, and when they do not, the sound is wrong and
    should be reset.

    Whenever you write a loop that keeps something in a desired state, write it
    as "compare and fix the difference", never as "apply the settings". The
    second one is what makes lights flicker and sounds stutter.

===============================================================================
    WHERE IT IS PARENTED
===============================================================================

    `SoundService`, not the workspace. A sound parented to a part is positional -
    it gets quieter as you walk away and pans as you turn. A sound parented to
    `SoundService` has no position, so it plays at the same volume everywhere,
    which is what ambience means.

    That is also why [`../visuals/sound-visualizer.lua`](../visuals/sound-visualizer.lua)
    can find every sound in the game by position: the ones that have a position
    are attached to a part, and this one deliberately is not.

    REQUIREMENTS
    None. Any Roblox asset id works; a URL or a local file needs an executor
    with `getcustomasset`, which the full script supports through its Custom
    Sounds feature.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- A Roblox asset id. Bare numbers are accepted too.
    SoundId = "rbxassetid://1837879082",

    Volume = 1,
    PlaybackSpeed = 1,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Ambience", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AmbienceCleanup then
    pcall(env.__AmbienceCleanup)
end

local Token = {}
env.__AmbienceToken = Token

local State = {
    Sound = nil,
    ActiveSource = nil,
}

--=============================================================================
-- Normalising the id
--=============================================================================
-- People type "1837879082", "rbxassetid://1837879082" and sometimes a whole
-- library URL. All three mean the same thing.

local function normaliseAssetId(value)
    if type(value) ~= "string" then return nil end

    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil end

    if trimmed:match("^rbxasset") then return trimmed end

    local digits = trimmed:match("(%d+)$")
    if digits then return "rbxassetid://" .. digits end

    return nil
end

--=============================================================================
-- One idempotent pass
--=============================================================================

local function destroySound()
    local sound = State.Sound
    State.Sound = nil
    State.ActiveSource = nil
    if sound then
        pcall(function() sound:Destroy() end)
    end
end

local function refresh()
    local source = CONFIG.Enabled and normaliseAssetId(CONFIG.SoundId) or nil

    if not source then
        destroySound()
        return
    end

    local sound = State.Sound
    if not sound or sound.Parent == nil then
        sound = Instance.new("Sound")
        sound.Looped = true
        -- SoundService, so it has no position. See header.
        sound.Parent = SoundService
        State.Sound = sound
    end

    -- Safe to write every pass; assigning the same number does nothing.
    sound.Volume = math.max(0, CONFIG.Volume)
    sound.PlaybackSpeed = math.max(0.01, CONFIG.PlaybackSpeed)

    -- Only touch the id and Play when something is genuinely wrong. See header
    -- - this is the whole point of the file.
    if State.ActiveSource ~= source or sound.SoundId ~= source then
        State.ActiveSource = source
        sound.SoundId = source
        sound:Play()
    elseif not sound.IsPlaying then
        sound:Play()
    end
end

--=============================================================================
-- The loop
--=============================================================================

task.spawn(function()
    while env.__AmbienceToken == Token do
        local ok, err = pcall(refresh)
        if not ok then
            warn("[Ambience] " .. tostring(err))
        end
        task.wait(1)
    end
end)

notify(CONFIG.Enabled and "active" or "disabled")

--=============================================================================
-- Cleanup
--=============================================================================

env.__AmbienceCleanup = function()
    env.__AmbienceToken = nil
    destroySound()
    env.__AmbienceCleanup = nil
end
