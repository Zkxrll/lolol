--[[============================================================================
    VIEWMODEL ANIMATIONS  -  strip the first-person weapon animations
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Five things your gun does on screen, removable one at a time:

        NoMotion     the sway, bob, tilt and recoil kick as you move
        NoShoot      the firing animation
        NoSprint     the lowered-gun sprint animation
        NoEquip      the draw animation when you swap weapons
        NoReload     the reload animation

    None of it changes what the gun does - your shots, spread, reload time and
    hitboxes are all unaffected. It changes what you look at while it happens,
    which is mostly about not having your view thrown around.

    Two different mechanisms in here, and the animation one is the interesting
    part of this whole file.

===============================================================================
    STOP IT BEFORE IT STARTS, NOT AFTER
===============================================================================

    The obvious way to remove an animation is to notice it playing and stop it:

        animator.AnimationPlayed:Connect(function(track)
            if isReload(track) then track:Stop() end
        end)

    That works, badly. The animation plays for a frame or two before you catch
    it, so you get a flicker rather than nothing. And you have stopped a track
    the game believes is running, so its own bookkeeping is now wrong - it may
    refuse to start the next one, or wait forever for a finish that will not
    come.

    What this does instead: replace `ViewModelAnimator.PlayAnimation`, and when
    an animation you want gone is requested, swap the track itself for a stub
    while the game's own function runs.

        local existing = tracks[animationKey]
        tracks[animationKey] = { Play = function() end, Stop = function() end }
        pcall(original, animator, animationKey, ...)
        tracks[animationKey] = existing

    Read that again, because it is a lovely little trick. The game's real
    `PlayAnimation` runs, completely and normally. Every counter it increments,
    every flag it sets, every follow-up it schedules - all of it happens exactly
    as it would have. The only difference is that when it finally reaches for
    the track and calls `Play` on it, the thing it is holding does nothing.

    Nothing flickers, because nothing ever started. Nothing is confused,
    because the game's own state was updated by the game's own code. And the
    swap is undone inside the same call, so no other code can ever observe it.

    This is the most general form of "modify the view, not the thing", which
    runs through the whole project - see
    [`../movement/walkspeed-and-slide.lua`](../movement/walkspeed-and-slide.lua)
    and [`overlay-removals.lua`](overlay-removals.lua). Here the swapped view is
    not a constant or an upvalue, it is one entry in a table, for the duration of
    one call.

    THE pcall THAT IS NOT ABOUT SAFETY
        local ok, err = pcall(original, animator, animationKey, ...)
        tracks[animationKey] = existing
        if not ok then error(err, 0) end

    The `pcall` here is not swallowing errors - it re-raises them. It is there
    so that the restore line runs *even if the original throws*. Without it, one
    error inside the game's function leaves a stub permanently in its track
    table, and that animation is dead for the rest of the session.

    `error(err, 0)` re-raises with level 0, so the message is not re-prefixed
    with this file's position and still points at where it actually happened.

    Any wrapper that changes state around a call needs this shape. If the thing
    in the middle can throw, and yours is the only code that can put the state
    back, then it must be `pcall` + restore + re-raise.

===============================================================================
    ONLY YOUR OWN GUN
===============================================================================

    `PlayAnimation` is replaced on the class, which means it is called for every
    player's animator, not just yours. Stripping everyone's animations would
    look bizarre, be far more noticeable, and gain nothing.

    So each call checks whose animator it is by walking up the ownership chain:

        animator.ClientViewModel.ClientItem.ClientFighter.IsLocalPlayer

    Any time you replace something on a class rather than on an instance,
    assume you are now in the path of every user of that class and find the
    "is this mine" test before you write anything else.

===============================================================================
    NO MOTION IS A DIFFERENT THING ENTIRELY
===============================================================================

    Sway and bob are not animations. They are springs - numbers the viewmodel
    integrates every frame to make the gun lag behind your movement. There is no
    track to suppress, so `NoMotion` simply writes zero into each spring:

        _sliding_spring, _sprinting_spring, _bobbing_speed_spring,
        _bobbing_value_spring, _landing_spring, _jump_spring, _tilt_spring,
        _impulse_position_spring, _recoil_spring, _unrecoil_spring

    They have to be re-zeroed on a loop, because the game keeps writing them -
    this is fighting the game's output rather than changing its input, which is
    the weaker of the two approaches and is used here only because there is
    nothing better to reach for. Compare with the animation half above, which
    never has to fight anything.

    Note `_recoil_spring` is in that list: this removes the visual recoil kick.
    It does not remove recoil - where your bullets go is decided elsewhere and
    is not affected.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    NoMotion = true,    -- sway, bob, tilt, visual recoil
    NoShoot = false,
    NoSprint = true,
    NoEquip = false,
    NoReload = false,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- Every spring the viewmodel uses to lag behind you, and the value that means
-- "no movement". Vector types matter - writing 0 into a Vector2 spring errors.
local MOTION_SPRINGS = {
    _sliding_spring = 0,
    _sprinting_spring = 0,
    _bobbing_speed_spring = 0,
    _bobbing_value_spring = Vector2.zero,
    _landing_spring = 0,
    _jump_spring = 0,
    _tilt_spring = Vector2.zero,
    _impulse_position_spring = Vector3.zero,
    _recoil_spring = Vector3.zero,
    _unrecoil_spring = Vector3.zero,
}

-- Does nothing, answers everything PlayAnimation will ask of a track.
local ANIMATION_STUB = {
    Play = function() end,
    Stop = function() end,
}

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Viewmodel", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__ViewmodelAnimationsCleanup then
    pcall(env.__ViewmodelAnimationsCleanup)
end

local Token = {}
env.__ViewmodelAnimationsToken = Token

local Restore = nil
local motionConn = nil

--=============================================================================
-- Finding things
--=============================================================================

local function requireByPath(...)
    local cursor = LocalPlayer:FindFirstChild("PlayerScripts")
    for _, segment in ipairs({ ... }) do
        cursor = cursor and cursor:FindFirstChild(segment)
    end
    if not cursor then return nil end
    local ok, value = pcall(require, cursor)
    return (ok and type(value) == "table") and value or nil
end

local function localFighter()
    local controller = requireByPath("Controllers", "FighterController")
    if not controller then return nil end
    return rawget(controller, "LocalFighter")
end

-- Whose animator is this? See header.
local function isLocalAnimator(animator)
    local viewModel = type(animator) == "table" and rawget(animator, "ClientViewModel") or nil
    local item = type(viewModel) == "table" and rawget(viewModel, "ClientItem") or nil
    local fighter = type(item) == "table" and rawget(item, "ClientFighter") or nil
    return type(fighter) == "table" and rawget(fighter, "IsLocalPlayer") == true
end

--=============================================================================
-- Which animations to suppress
--=============================================================================
-- Shoot and Reload are matched on the key's text because there are many of
-- them per weapon. Sprint and Equip are single named animations, and the
-- animator itself holds the key it uses - so it is read from there rather than
-- guessed, and stays right when a weapon names them differently.

local function shouldSuppress(animator, animationKey)
    if type(animationKey) ~= "string" then return false end

    if CONFIG.NoShoot
        and (string.find(animationKey, "Shoot", 1, true) ~= nil or animationKey == "QuickShot") then
        return true
    end
    if CONFIG.NoSprint and animationKey == rawget(animator, "_sprint_animation") then
        return true
    end
    if CONFIG.NoEquip and animationKey == rawget(animator, "_equip_animation") then
        return true
    end
    if CONFIG.NoReload and string.find(animationKey, "Reload", 1, true) ~= nil then
        return true
    end
    return false
end

--=============================================================================
-- The animation hook
--=============================================================================

local function installAnimationHook()
    if Restore then return true end
    if not (CONFIG.NoShoot or CONFIG.NoSprint or CONFIG.NoEquip or CONFIG.NoReload) then
        return false
    end

    local class = requireByPath(
        "Modules", "ClientReplicatedClasses", "ClientFighter", "ClientItem",
        "ClientViewModel", "ViewModelAnimator"
    )
    local original = class and rawget(class, "PlayAnimation") or nil
    if type(original) ~= "function" then return false end

    rawset(class, "PlayAnimation", function(animator, animationKey, ...)
        -- Not ours, or not one we want gone: hand it straight through.
        if not isLocalAnimator(animator) or not shouldSuppress(animator, animationKey) then
            return original(animator, animationKey, ...)
        end

        local tracks = rawget(animator, "_animation_tracks")
        local existing = type(tracks) == "table" and tracks[animationKey] or nil
        -- No track to swap means nothing would have played anyway.
        if existing == nil then return end

        tracks[animationKey] = ANIMATION_STUB
        local ok, err = pcall(original, animator, animationKey, ...)
        tracks[animationKey] = existing         -- must run even on error
        if not ok then
            error(err, 0)                       -- see header
        end
    end)

    Restore = { class = class, original = original }
    return true
end

--=============================================================================
-- The motion springs
--=============================================================================

local function applyMotionSuppression()
    if not CONFIG.NoMotion then return end

    local fighter = localFighter()
    local items = (type(fighter) == "table" and type(rawget(fighter, "Items")) == "table")
        and rawget(fighter, "Items") or nil
    if not items then return end

    for _, item in pairs(items) do
        local viewModel = type(item) == "table" and rawget(item, "ViewModel") or nil
        if type(viewModel) == "table" then
            for springName, value in pairs(MOTION_SPRINGS) do
                local spring = rawget(viewModel, springName)
                if type(spring) == "table" then
                    -- pcall because a spring's Value may be typed, and a build
                    -- that changes one from Vector2 to Vector3 would throw here
                    -- rather than anywhere useful.
                    pcall(function() spring.Value = value end)
                end
            end
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================

local applied = {}

task.spawn(function()
    while env.__ViewmodelAnimationsToken == Token do
        if installAnimationHook() then break end
        -- Nothing to install (all animation options off) also breaks out.
        if not (CONFIG.NoShoot or CONFIG.NoSprint or CONFIG.NoEquip or CONFIG.NoReload) then
            break
        end
        task.wait(1)
    end
end)

if CONFIG.NoMotion then
    -- Heartbeat, not RenderStepped: the springs are read during rendering, so
    -- zeroing them just after the physics step means the value is already there
    -- when the frame is drawn.
    motionConn = RunService.Heartbeat:Connect(function()
        if env.__ViewmodelAnimationsToken ~= Token then return end
        pcall(applyMotionSuppression)
    end)
    table.insert(applied, "NoMotion")
end

for name, enabled in pairs({
    NoShoot = CONFIG.NoShoot, NoSprint = CONFIG.NoSprint,
    NoEquip = CONFIG.NoEquip, NoReload = CONFIG.NoReload,
}) do
    if enabled then table.insert(applied, name) end
end
table.sort(applied)

notify(#applied > 0 and ("active: " .. table.concat(applied, ", ")) or "nothing enabled")

--=============================================================================
-- Cleanup
--=============================================================================
-- The springs are not restored: the game writes them every frame anyway, so
-- they heal themselves the moment we stop zeroing them.

env.__ViewmodelAnimationsCleanup = function()
    env.__ViewmodelAnimationsToken = nil

    if motionConn then
        pcall(function() motionConn:Disconnect() end)
        motionConn = nil
    end

    if Restore then
        rawset(Restore.class, "PlayAnimation", Restore.original)
        Restore = nil
    end

    env.__ViewmodelAnimationsCleanup = nil
end
