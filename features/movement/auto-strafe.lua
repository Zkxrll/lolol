--[[============================================================================
    AUTO STRAFE  -  hold jump to keep gaining air speed
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    While you are holding Space, your character keeps accelerating in whatever
    direction you are steering with WASD. It is the automated version of the
    air-strafing technique from Quake and Counter-Strike: turn while airborne and
    you gain speed instead of losing it.

    HOW IT WORKS
    Three things happen every frame while Space is held, and all three matter:

    1. WORK OUT THE STEER DIRECTION
       Both the camera's look and right vectors are FLATTENED (Y removed, then
       re-normalised), and WASD is summed against those. Strafing is a horizontal
       technique, so looking up or down must not tilt the push - unlike flight,
       where forward/back is flattened but strafe is not.

    2. NUDGE THE POSITION
       We add a small offset to the root part's CFrame:

           rootPart.CFrame = rootPart.CFrame + direction * (speed / 100) * dt * 60

       Note it is `+ direction`, adding to the existing CFrame - not assigning a
       new absolute position. Each frame moves you a few hundredths of a stud.
       The `dt * 60` makes it framerate-independent: without it you would strafe
       twice as fast on a 120fps machine as on a 60fps one.

    3. KILL THE HORIZONTAL VELOCITY
           rootPart.AssemblyLinearVelocity *= Vector3.new(0, 1, 0)

       Multiplying by (0,1,0) zeroes X and Z and keeps Y. This wipes the game's
       own horizontal momentum every frame while preserving your fall/jump speed.

       This is the step people leave out, and it is the one that makes it work.
       Without it, the game's air friction is constantly dragging your real
       velocity back toward zero while our nudge pushes it forward, and the two
       fight - you get jitter instead of speed. By zeroing horizontal velocity we
       take the game out of the argument entirely: our nudge becomes the only
       thing moving you sideways, while gravity still owns the vertical.

    WHY IT NEEDS SPACE HELD
    That is the whole activation condition - there is no separate keybind. Air
    strafing only makes sense while airborne, and holding jump is already what
    you do. It means the feature costs you nothing when you are walking around.

    REQUIREMENTS
    None. No executor-specific functions.

============================================================================--]]

local CONFIG = {
    -- Strafe strength. The original's default is 50. Above ~100 the movement
    -- stops looking like momentum and starts looking like teleporting.
    Speed = 50,

    -- Key that must be held. Space by default, matching the jump button.
    HoldKey = Enum.KeyCode.Space,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.__AutoStrafeCleanup then
    pcall(env.__AutoStrafeCleanup)
end

local Token = {}
env.__AutoStrafeToken = Token

local PlayerModule = nil   -- cached, for touch input

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Auto Strafe", Text = text, Duration = 3,
        })
    end)
end

--=============================================================================
-- Steer direction
--=============================================================================

local function flatten(vector)
    local flat = Vector3.new(vector.X, 0, vector.Z)
    return flat.Magnitude > 0 and flat.Unit or Vector3.zero
end

local function resolveMoveVector()
    if PlayerModule == nil then
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local moduleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if moduleScript then
            local ok, playerModule = pcall(require, moduleScript)
            if ok and type(playerModule) == "table" and type(playerModule.GetControls) == "function" then
                PlayerModule = playerModule
            end
        end
    end
    if PlayerModule then
        local ok, moveVector = pcall(function()
            return PlayerModule:GetControls():GetMoveVector()
        end)
        if ok and typeof(moveVector) == "Vector3" then
            return moveVector
        end
    end
    return Vector3.zero
end

local function strafeDirection()
    if UserInputService:GetFocusedTextBox() then
        return Vector3.zero
    end

    local direction = Vector3.zero
    local cframe = Workspace.CurrentCamera.CFrame

    -- BOTH flattened here, unlike flight.lua. See note 1 in the header.
    local look = flatten(cframe.LookVector)
    local right = flatten(cframe.RightVector)

    if UserInputService.KeyboardEnabled then
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + look end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - look end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + right end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - right end
    else
        local moveVector = resolveMoveVector()
        if moveVector.Magnitude > 0 then
            direction = direction + look * -moveVector.Z
            direction = direction + right * moveVector.X
        end
    end

    if direction.Magnitude > 0 then
        direction = direction.Unit
    end
    return direction
end

--=============================================================================
-- Per-frame driver
--=============================================================================

local function step(deltaTime)
    if not UserInputService:IsKeyDown(CONFIG.HoldKey) then
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")

    if not rootPart or not humanoid or humanoid.Health <= 0 then
        return
    end

    local direction = strafeDirection()
    if direction.Magnitude == 0 then
        return
    end

    -- Add to the current CFrame; dt*60 normalises to a 60fps baseline.
    rootPart.CFrame = rootPart.CFrame + direction * (CONFIG.Speed / 100) * deltaTime * 60

    -- Zero X and Z, keep Y. This is the step that makes it work - see note 3.
    rootPart.AssemblyLinearVelocity = rootPart.AssemblyLinearVelocity * Vector3.new(0, 1, 0)
end

--=============================================================================
-- Lifecycle
--=============================================================================

local heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    if env.__AutoStrafeToken ~= Token then return end
    step(deltaTime)
end)

env.__AutoStrafeCleanup = function()
    pcall(function() heartbeat:Disconnect() end)
    env.__AutoStrafeCleanup = nil
    env.__AutoStrafeToken = nil
end

notify(("loaded - hold %s while airborne"):format(CONFIG.HoldKey.Name))
