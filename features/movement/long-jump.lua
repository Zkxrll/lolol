--[[============================================================================
    LONG JUMP  -  launch yourself across the map
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Press a key and you get launched in the direction you are looking, fast and
    far. Two modes: a normal forward launch, and an "Under Feet" mode that fires
    you steeply upward instead.

    HOW IT WORKS  -  and why this one is different
    Every other movement feature in this folder fights the game in some way:
    noclip overwrites a property every frame, flight bolts on a physics
    constraint, auto-strafe rewrites your position and wipes the game's velocity.

    This one does none of that. It just *asks the game to launch you*.

    RIVALS already has a launch mechanic. Being knocked back, boosted, blown up
    by a grenade - all of that goes through one function on your fighter entity:

        entity:AirborneTrigger(velocity, 4)

    That is the game's own code, doing the game's own thing. We hand it a
    velocity vector we picked and it launches us exactly as if a game mechanic
    had. The physics are the game's physics, the animation is the game's
    animation, and the replication is the game's replication - because it *is*
    the game's, all the way down.

    This is the best kind of exploit to write, and worth internalising if you are
    here to learn: before you reach for a physics hack, look for the function the
    game already uses to do the thing you want. Calling it with your own
    arguments is simpler, smoother, and far less visible than reimplementing it.

    WHY IT CALLS AirborneCancel FIRST
        pcall(entity.AirborneCancel, entity)
        pcall(entity.AirborneTrigger, entity, velocity, 4)

    If you are already airborne from a previous launch, triggering a new one on
    top of it gives you a weak, half-applied jump - the old airborne state is
    still running and the two interfere. Cancelling first clears that state so
    the new launch lands at full strength. Spam the key without the cancel and
    you get progressively weaker jumps.

    The `4` is the airborne type/state the game tags the launch with. It comes
    from the original implementation; it is passed through unchanged.

    THE DIRECTION MATH
    Forward is the camera's look vector with Y stripped, so aiming at the sky
    doesn't change where you go - only how you look while going there. Vertical
    lift is added separately and is fully under your control.

    If you are looking straight down (or straight up), the flattened vector has
    almost no length and normalising it would produce garbage, so there is a
    fallback to your character's own facing direction.

    In "Under Feet" mode the flat direction is scaled by BehindOffset and then a
    fixed +4 studs of up is mixed in before normalising, which tips the launch
    into a steep arc. Bigger BehindOffset = shallower; smaller = closer to
    straight up.

    REQUIREMENTS
    None. No executor-specific functions. You do need to be alive and in a match,
    since the fighter entity does not exist in the lobby.

============================================================================--]]

local CONFIG = {
    Key = Enum.KeyCode.G,

    -- "Forward"    - launch where you are looking, flattened
    -- "Under Feet" - steep upward launch
    Mode = "Forward",

    -- Horizontal launch strength.
    Force = 60,

    -- Straight-up velocity added on top. Raise for more hang time.
    UpwardVelocity = 20,

    -- "Under Feet" mode only: how far forward the steep launch leans.
    -- Larger = flatter arc, smaller = closer to straight up.
    BehindOffset = 8,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.__LongJumpCleanup then
    pcall(env.__LongJumpCleanup)
end

local Token = {}
env.__LongJumpToken = Token

local FighterController = nil   -- cached

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Long Jump", Text = text, Duration = 3,
        })
    end)
end

--=============================================================================
-- Finding your fighter entity
--=============================================================================
-- RIVALS keeps its gameplay logic in ModuleScripts under
-- PlayerScripts/Controllers. Requiring one gives you the live controller the
-- game itself is using - not a copy - so anything you call on it affects the
-- real game state. This same path is how most features here reach the game.

local function resolveFighterController()
    if FighterController then
        return FighterController
    end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("FighterController")
    if not module then
        return nil
    end
    local ok, controller = pcall(require, module)
    if not ok then
        return nil
    end
    FighterController = controller
    return FighterController
end

-- Your "fighter" is the game's object for your in-match character. There are
-- several ways to get at it depending on how far the match has loaded, so try
-- each in turn rather than assuming one works.
local function resolveLocalFighter()
    local controller = resolveFighterController()
    if not controller then
        return nil
    end

    if controller.LocalFighter then
        return controller.LocalFighter
    end

    if type(controller.GetFighter) ~= "function" then
        return nil
    end

    local fighter = controller:GetFighter(LocalPlayer)
    if fighter then
        return fighter
    end

    if LocalPlayer.Character then
        fighter = controller:GetFighter(LocalPlayer.Character)
        if fighter then
            return fighter
        end
    end

    return nil
end

-- The entity hangs off the fighter, either as a plain field or behind a getter.
-- rawget skips any __index metamethod on the way, which keeps the read quiet.
local function resolveEntity()
    local fighter = resolveLocalFighter()
    if type(fighter) ~= "table" then
        return nil
    end

    local entity = rawget(fighter, "Entity")
    if entity then
        return entity
    end

    if type(fighter.GetEntity) == "function" then
        local ok, value = pcall(fighter.GetEntity, fighter)
        if ok then
            return value
        end
    end

    return nil
end

--=============================================================================
-- The launch
--=============================================================================

local function launch()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local camera = Workspace.CurrentCamera
    local entity = resolveEntity()

    if type(entity) ~= "table" or not rootPart or not camera
        or not humanoid or humanoid.Health <= 0 then
        notify("not ready - are you alive and in a match?")
        return false
    end

    -- Flatten the camera direction so looking up/down doesn't change where you go.
    local lookVector = camera.CFrame.LookVector
    local direction = Vector3.new(lookVector.X, 0, lookVector.Z)

    -- Looking near-straight up or down leaves almost nothing to normalise.
    if direction.Magnitude < 0.001 then
        local rootLook = rootPart.CFrame.LookVector
        direction = Vector3.new(rootLook.X, 0, rootLook.Z)
    end
    direction = direction.Unit

    if CONFIG.Mode == "Under Feet" then
        -- Mix in a fixed +4 up BEFORE normalising to tip the launch steep.
        direction = (direction * CONFIG.BehindOffset + Vector3.new(0, 4, 0)).Unit
    end

    local velocity = direction * CONFIG.Force
        + Vector3.new(0, CONFIG.UpwardVelocity, 0)

    if type(entity.AirborneCancel) ~= "function"
        or type(entity.AirborneTrigger) ~= "function" then
        notify("launch functions missing - the game has probably been updated")
        return false
    end

    -- Cancel any launch already in flight, or this one comes out weak.
    pcall(entity.AirborneCancel, entity)
    local ok = pcall(entity.AirborneTrigger, entity, velocity, 4)
    return ok
end

--=============================================================================
-- Input and lifecycle
--=============================================================================

-- Fires once per press. Without this guard, holding the key would re-launch
-- every frame and you would hover instead of jumping.
local pressed = false

local inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
    if env.__LongJumpToken ~= Token then return end
    if processed then return end
    if input.KeyCode ~= CONFIG.Key then return end
    if pressed then return end
    pressed = true
    launch()
end)

local inputEnded = UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.Key then return end
    pressed = false
end)

-- A respawn invalidates the cached controller.
local charAdded = LocalPlayer.CharacterAdded:Connect(function()
    FighterController = nil
end)

env.__LongJumpCleanup = function()
    pcall(function() inputBegan:Disconnect() end)
    pcall(function() inputEnded:Disconnect() end)
    pcall(function() charAdded:Disconnect() end)
    env.__LongJumpCleanup = nil
    env.__LongJumpToken = nil
end

notify(("loaded - press %s (%s mode)"):format(CONFIG.Key.Name, CONFIG.Mode))
