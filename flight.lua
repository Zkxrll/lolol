--[[============================================================================
    FLIGHT  -  fly with WASD
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Hold or toggle a key and your character flies. WASD moves you relative to
    where the camera is looking, Space goes up, Shift/Ctrl goes down.

    HOW IT WORKS
    There are two ways to move a character in Roblox, and picking the wrong one
    is why most flight scripts get you kicked:

      BAD:  set HumanoidRootPart.CFrame every frame (teleporting)
      GOOD: attach a LinearVelocity and let the physics engine move you

    We do the second one. A LinearVelocity is a real Roblox physics constraint -
    the engine moves you with it, the movement is smooth, and it replicates the
    way ordinary movement does, because as far as the physics engine is
    concerned it *is* ordinary movement. Setting CFrame directly makes you jump
    between positions with nothing in between, which is trivially detectable.

    The constraint needs an Attachment to pull against, so we create both, parent
    them to the root part, and then just rewrite `VectorVelocity` each frame as
    your input changes. We do NOT tear down and rebuild the constraint every
    frame - creating instances every frame is slow and makes the movement stutter.

    BUILD ORDER MATTERS. Velocity is assigned BEFORE Attachment0 and Parent are
    set. If you parent the constraint while its velocity is still zero, you get a
    one-frame dead stop that reads as a stutter at the start of every flight.
    (This ordering is from the original Kicia implementation, annotated at
    [103530] in KiciaHook_Deobfuscated.lua.)

    THE INPUT MATH
    W and S ride a *flattened* look vector - the camera's forward direction with
    its Y component removed and re-normalised. That means looking down at the
    floor and pressing W moves you forward horizontally instead of driving you
    into the ground, which is what you actually want when flying.

    A and D use the camera's RAW RightVector, not a flattened one. That is
    deliberate and it is not a bug: strafing while the camera is rolled should
    follow the camera. Only forward/back gets flattened.

    Space and Shift/Ctrl add and subtract straight world-up.

    The pieces are summed WITHOUT normalising as they go, then normalised once at
    the end. Normalising early would make diagonal movement slower than straight
    movement.

    ON TOUCH DEVICES (no keyboard) we read the move vector out of Roblox's own
    PlayerModule instead, so the on-screen thumbstick drives flight. That path
    uses the UNflattened look vector - pushing the stick forward while looking
    down flies you downward, which is the natural expectation on a thumbstick.

    STOPPING CLEANLY
    On release we destroy the constraint AND zero the root part's
    AssemblyLinearVelocity. Without that second step you keep coasting at flight
    speed after letting go, and slam into whatever is in front of you.

    REQUIREMENTS
    None. No executor-specific functions.

============================================================================--]]

local CONFIG = {
    -- Key that activates flight.
    Key = Enum.KeyCode.F,

    -- "Hold" or "Toggle"
    Mode = "Toggle",

    -- Studs per second. 16 is normal walking speed; 100 is fast.
    Speed = 100,

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
if env.__FlightCleanup then
    pcall(env.__FlightCleanup)
end

local Token = {}
env.__FlightToken = Token

local State = {
    Active = false,
    Flight = nil,        -- { RootPart, Attachment, Velocity }
    PlayerModule = nil,  -- cached, for touch input
}

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Flight", Text = text, Duration = 2,
        })
    end)
end

--=============================================================================
-- Input direction
--=============================================================================

-- Roblox's own control module, so the touch thumbstick works. Cached because
-- require() on every frame is wasteful.
local function resolveMoveVector()
    if State.PlayerModule == nil then
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local moduleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if moduleScript then
            local ok, playerModule = pcall(require, moduleScript)
            if ok and type(playerModule) == "table" and type(playerModule.GetControls) == "function" then
                State.PlayerModule = playerModule
            end
        end
    end

    local playerModule = State.PlayerModule
    if playerModule then
        local ok, moveVector = pcall(function()
            return playerModule:GetControls():GetMoveVector()
        end)
        if ok and typeof(moveVector) == "Vector3" then
            return moveVector
        end
    end
    return Vector3.zero
end

local function moveDirection()
    -- Never fly because someone typed "wasd" in chat.
    if UserInputService:GetFocusedTextBox() then
        return Vector3.zero
    end

    local direction = Vector3.zero
    local cframe = Workspace.CurrentCamera.CFrame

    if UserInputService.KeyboardEnabled then
        -- Forward/back flattened, so looking down doesn't fly you into the floor.
        local look = cframe.LookVector
        local flatLook = Vector3.new(look.X, 0, look.Z)
        if flatLook.Magnitude > 0 then
            flatLook = flatLook.Unit
        end

        if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + flatLook end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - flatLook end
        -- Strafe uses the RAW right vector on purpose - see header.
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + cframe.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - cframe.RightVector end

        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            direction = direction + Vector3.new(0, 1, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
            or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
            direction = direction - Vector3.new(0, 1, 0)
        end
    else
        -- Touch: unflattened, so the thumbstick flies where you're looking.
        local moveVector = resolveMoveVector()
        if moveVector.Magnitude > 0 then
            direction = direction + cframe.LookVector * -moveVector.Z
            direction = direction + cframe.RightVector * moveVector.X
        end
    end

    return direction   -- deliberately NOT normalised yet
end

--=============================================================================
-- The physics constraint
--=============================================================================

local function destroyFlight()
    local flight = State.Flight
    State.Flight = nil
    if flight then
        pcall(function() flight.Velocity:Destroy() end)
        pcall(function() flight.Attachment:Destroy() end)
    end
end

-- Kills leftover momentum so you don't coast after releasing the key.
local function blankVelocity(rootPart)
    if rootPart and rootPart.Parent then
        pcall(function() rootPart.AssemblyLinearVelocity = Vector3.zero end)
    end
end

local function step()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")

    local canFly = State.Active
        and rootPart ~= nil and rootPart.Parent ~= nil
        and humanoid ~= nil and humanoid.Health > 0

    if not canFly then
        destroyFlight()
        return
    end

    local direction = moveDirection()
    if direction.Magnitude > 0 then
        direction = direction.Unit    -- normalise ONCE, at the end
    end
    local velocityVector = direction * CONFIG.Speed

    local flight = State.Flight

    -- Respawning gives you a brand new root part; the old constraint is attached
    -- to a corpse and has to be rebuilt.
    if flight and flight.RootPart ~= rootPart then
        destroyFlight()
        flight = nil
    end

    if flight then
        -- Reuse the existing constraint - just retarget it.
        flight.Velocity.VectorVelocity = velocityVector
        return
    end

    local attachment = Instance.new("Attachment")
    attachment.Parent = rootPart

    local velocity = Instance.new("LinearVelocity")
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.MaxForce = math.huge
    velocity.VectorVelocity = velocityVector   -- BEFORE Attachment0/Parent, see header
    velocity.Attachment0 = attachment
    velocity.Parent = rootPart

    State.Flight = { RootPart = rootPart, Attachment = attachment, Velocity = velocity }
end

local function setActive(active)
    if State.Active == active then return end
    State.Active = active

    if not active then
        local character = LocalPlayer.Character
        destroyFlight()
        blankVelocity(character and character:FindFirstChild("HumanoidRootPart"))
    end

    notify(active and "on" or "off")
end

--=============================================================================
-- Input and lifecycle
--=============================================================================

local heartbeat = RunService.Heartbeat:Connect(function()
    if env.__FlightToken ~= Token then return end
    step()
end)

local inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode ~= CONFIG.Key then return end

    if CONFIG.Mode == "Toggle" then
        setActive(not State.Active)
    else
        setActive(true)
    end
end)

local inputEnded = UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.Key then return end
    -- Not gated on `processed`: a swallowed release would strand you flying.
    if CONFIG.Mode == "Hold" then
        setActive(false)
    end
end)

env.__FlightCleanup = function()
    setActive(false)
    pcall(function() heartbeat:Disconnect() end)
    pcall(function() inputBegan:Disconnect() end)
    pcall(function() inputEnded:Disconnect() end)
    env.__FlightCleanup = nil
    env.__FlightToken = nil
end

notify(("loaded - press %s to %s"):format(
    CONFIG.Key.Name,
    CONFIG.Mode == "Toggle" and "toggle" or "hold"
))
