--[[============================================================================
    AIMBOT  -  pulls your aim onto a target while you hold a key
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Hold the aim key. It picks the best target near your crosshair and turns
    your view smoothly onto them for as long as you hold it. Let go and you have
    your aim back immediately. It does not shoot - that is
    [`triggerbot.lua`](triggerbot.lua), and the two work well together.

    WHAT THIS FILE DOES NOT COVER
    The full script also has a *silent* mode, which leaves your camera alone and
    corrects only the shot itself, plus checks that skip targets deflecting with
    a katana or hiding behind a raised riot shield. Those are hooks into the
    weapon code rather than aim logic, and they are not in this file. This is
    the camera aimbot, complete and on its own.

===============================================================================
    PART ONE: PICKING A TARGET
===============================================================================

    Every frame, every candidate is scored and the lowest score wins. The score
    is CURSOR DISTANCE - how far the target is from your crosshair in pixels,
    not how far away they are in the world.

    That choice matters more than it sounds. Ranking by world distance means the
    aimbot grabs whoever is physically nearest to you, which is regularly
    someone off to your left that you are not looking at and did not want. What
    you actually want is "the thing I am most nearly already aiming at", and
    that is a screen-space question.

    Off-screen targets - only reachable at all with `IgnoreFOV` - are a special
    case. Their projected screen position is meaningless (see the arrow note in
    `esp/player-esp.lua`), so they cannot be scored the same way. They get a
    large fixed penalty plus their world distance, which sorts every one of them
    behind every on-screen target while still ordering them sensibly among
    themselves.

    THE FOV CIRCLE
    With `IgnoreFOV` off, a target must be within `FOVRadius` pixels of your
    crosshair to be eligible. This is the setting that decides how much the
    aimbot looks like aiming versus teleporting - a small circle only helps with
    aim you had already nearly made, while a huge one snaps across the screen.

    Turn on `ShowFOV` to draw the circle. Being able to see the region is worth
    it: most people set the radius far larger than they think.

    THE OTHER FILTERS
    Not you, not a teammate, not a corpse, not further than `MaxDistance`, and
    not spawn-shielded - shooting someone during their spawn invincibility does
    nothing, so locking onto them just wastes the moment. And if
    `RequireVisible` is on, the target must actually be in line of sight; the
    visibility test is the same multi-point raycast documented in
    `esp/player-esp.lua`.

    WHICH PART TO AIM AT
        "Head"     the head hitbox
        "Body"     the body hitbox
        "Closest"  whichever of the two is nearer your crosshair right now
        "Auto"     head if the head is visible, body otherwise

    "Auto" is the useful default. Aiming at a head that is behind a wall while
    the chest is in plain view is how you shoot a wall.

===============================================================================
    PART TWO: MOVING THE CAMERA  -  the part everyone gets wrong
===============================================================================

    The obvious way to point the camera somewhere is:

        camera.CFrame = CFrame.lookAt(camera.CFrame.Position, targetPosition)

    In RIVALS this does not work, and the way it fails is instructive. The game
    does not let the camera drift wherever it is put - it has its own camera
    controller holding your pitch and yaw as state, and every frame it rebuilds
    `camera.CFrame` from that state. Your write survives for a fraction of a
    frame and is then overwritten. What you get is a violent flicker and an aim
    that never actually moves.

    Worse, even if the write did stick visually, your SHOTS would not follow.
    The game asks its own controller which way you are facing, not the camera.

    So we do not write the camera. We write the controller's state:

        cameraController:SetRotation(Vector2.new(pitch, yaw))

    Now the game itself renders the turn, and everything downstream of the
    controller - including where your bullets go - follows, because from the
    game's point of view you genuinely turned.

    The general lesson: when a value is owned and rewritten every frame by
    something else, writing the value is pointless. Find the state it is
    computed from and write that instead.

    THE YAW WRAP - the bug that will bite you
    `Rotation` is a Vector2 of (pitch, yaw) in RADIANS, and the yaw is NOT
    normalised. Spin in circles and it keeps climbing: 7, 12, 40 radians. The
    target angle from `CFrame.lookAt(...):ToOrientation()`, meanwhile, always
    comes back between -pi and +pi.

    Subtract one from the other naively and you eventually ask the camera to
    turn six full rotations to reach something directly in front of you. So the
    yaw difference is wrapped to the nearest equivalent turn:

        delta = (target - current + pi) % (2*pi) - pi

    which always lands in -pi..+pi: the shortest way round. Pitch needs no such
    treatment, because you cannot look further up than straight up.

    THE SMOOTHING
        alpha = 1 - exp(-dt * (2 + AimSpeed * 0.58))
        rotation += delta * alpha

    This is exponential smoothing, and the `exp(-dt * k)` is what makes it
    correct rather than merely smooth. A naive `rotation += delta * 0.2` moves
    a fifth of the way *per frame*, so the aimbot is literally twice as fast on
    a 120 fps machine as on a 60 fps one. Framing it in terms of elapsed time
    means the aim takes the same wall-clock time to arrive on any hardware.

    The motion is fast at first and slows as it arrives, which is roughly how a
    person moves a mouse onto a target. It never quite reaches the target, only
    approaches it - which is fine, and arguably a feature.

    REQUIREMENTS
    Nothing executor-specific for the aiming. `Drawing` is only needed if you
    turn `ShowFOV` on, and the file disables that by itself if it is missing.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Hold this to aim. Any Enum.KeyCode, or a mouse button:
    --   Enum.UserInputType.MouseButton2 is right-click.
    AimKey = Enum.UserInputType.MouseButton2,

    -- Higher is faster and less human. See the header before raising it.
    -- Roughly: 10 = lazy, 35 = quick, 80 = obviously not a person.
    AimSpeed = 35,

    -- "Head", "Body", "Closest" or "Auto".
    AimPart = "Auto",

    -- Target must be within this many pixels of your crosshair.
    FOVRadius = 170,
    IgnoreFOV = false,
    ShowFOV = true,

    -- Target must be in line of sight.
    RequireVisible = true,

    -- Don't aim at teammates.
    TeamCheck = true,

    MaxDistance = 2000,

    FOVCircleColor = Color3.fromRGB(255, 255, 255),
    FOVCircleTransparency = 0.35,

    -- How long a visibility answer is trusted, in seconds.
    VisibilityCacheSeconds = 0.05,

    Notify = true,
}

-- Off-screen targets sort behind everything on screen. Any number larger than
-- the diagonal of any screen works; this one is not magic.
local OFFSCREEN_PENALTY = 100000

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Aimbot", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AimbotCleanup then
    pcall(env.__AimbotCleanup)
end

local Token = {}
env.__AimbotToken = Token

local HAS_DRAWING = type(Drawing) == "table" and type(Drawing.new) == "function"
if not HAS_DRAWING then
    CONFIG.ShowFOV = false
end

--=============================================================================
-- The game's camera controller
--=============================================================================
-- This is the object whose state we write instead of the camera. See header.

local CameraControllerCache = nil
local FighterControllerCache = nil

local function requireController(name)
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild(name)
    if not module then return nil end
    local ok, controller = pcall(require, module)
    return (ok and type(controller) == "table") and controller or nil
end

local function cameraController()
    if CameraControllerCache then return CameraControllerCache end
    CameraControllerCache = requireController("CameraController")
    return CameraControllerCache
end

local function fighterController()
    if FighterControllerCache then return FighterControllerCache end
    FighterControllerCache = requireController("FighterController")
    return FighterControllerCache
end

-- Spawn shield flag. Absent rather than false when not shielded.
local function isSpawnShielded(player)
    local controller = fighterController()
    if type(controller) ~= "table" or type(controller.GetFighter) ~= "function" then
        return false
    end
    local ok, fighter = pcall(controller.GetFighter, controller, player)
    if not ok or type(fighter) ~= "table" then return false end
    local entity = rawget(fighter, "Entity")
    local data = entity ~= nil and rawget(entity, "Data") or nil
    return data ~= nil and rawget(data, "IsInvincible") == true
end

--=============================================================================
-- Visibility
--=============================================================================
-- Same technique as esp/player-esp.lua: several points per part, any one
-- reachable counts as visible, cached briefly because raycasts are the
-- expensive part of all of this.

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

local VisibilityCache = setmetatable({}, { __mode = "k" })

local function samplePoints(part)
    local points = { part.Position }
    local cframe = part.CFrame
    local half = part.Size * 0.5
    local function add(x, y, z)
        points[#points + 1] = cframe:PointToWorldSpace(Vector3.new(x, y, z))
    end
    add(half.X * 0.9, 0, 0)
    add(-half.X * 0.9, 0, 0)
    add(0, half.Y * 0.9, 0)
    add(0, -half.Y * 0.9, 0)
    return points
end

local function isPartVisible(character, part, camera)
    if not part then return false end

    local cache = VisibilityCache[part]
    if cache and os.clock() < cache.expiresAt then
        return cache.value
    end

    local origin = camera.CFrame.Position
    RayParams.FilterDescendantsInstances = { LocalPlayer.Character, character }

    local visible = false
    for _, point in ipairs(samplePoints(part)) do
        local direction = point - origin
        if direction.Magnitude > 0 and Workspace:Raycast(origin, direction, RayParams) == nil then
            visible = true
            break
        end
    end

    VisibilityCache[part] = {
        value = visible,
        expiresAt = os.clock() + CONFIG.VisibilityCacheSeconds,
    }
    return visible
end

--=============================================================================
-- Choosing a target
--=============================================================================

local function headPart(character)
    return character:FindFirstChild("HitboxHead") or character:FindFirstChild("Head")
end

local function bodyPart(character)
    return character:FindFirstChild("HitboxBody")
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChildWhichIsA("BasePart")
end

-- Screen distance from the crosshair, and whether the point is on screen at
-- all. A negative Z means behind the camera, where X/Y are meaningless.
local function screenInfo(camera, worldPosition, cursor)
    local screen = camera:WorldToViewportPoint(worldPosition)
    if screen.Z <= 0 then
        return math.huge, false
    end
    return (Vector2.new(screen.X, screen.Y) - cursor).Magnitude, true
end

local function pickPart(character, camera, cursor)
    local head = headPart(character)
    local body = bodyPart(character)

    if CONFIG.AimPart == "Head" then return head or body end
    if CONFIG.AimPart == "Body" then return body or head end

    if CONFIG.AimPart == "Closest" then
        if not head then return body end
        if not body then return head end
        local headDistance = screenInfo(camera, head.Position, cursor)
        local bodyDistance = screenInfo(camera, body.Position, cursor)
        return headDistance <= bodyDistance and head or body
    end

    -- "Auto": head if you can actually see the head, otherwise body.
    if head and isPartVisible(character, head, camera) then
        return head
    end
    return body or head
end

local function isCandidate(player)
    if player == LocalPlayer then return false end
    if player.Parent ~= Players then return false end
    if CONFIG.TeamCheck and player.Team ~= nil and player.Team == LocalPlayer.Team then
        return false
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    if isSpawnShielded(player) then return false end
    return true
end

local function selectTarget(camera, cursor)
    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    local origin = localRoot and localRoot.Position or camera.CFrame.Position

    local best, bestScore = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isCandidate(player) then
            local character = player.Character
            local part = pickPart(character, camera, cursor)

            if part then
                local worldDistance = (part.Position - origin).Magnitude
                if worldDistance <= CONFIG.MaxDistance then
                    local screenDistance, onScreen = screenInfo(camera, part.Position, cursor)

                    local eligible = true
                    if not CONFIG.IgnoreFOV then
                        eligible = onScreen and screenDistance <= CONFIG.FOVRadius
                    end
                    if eligible and CONFIG.RequireVisible then
                        eligible = isPartVisible(character, part, camera)
                    end

                    if eligible then
                        -- Cursor-first. See header.
                        local score = onScreen and screenDistance
                            or (OFFSCREEN_PENALTY + worldDistance)
                        if score < bestScore then
                            best, bestScore = part, score
                        end
                    end
                end
            end
        end
    end

    return best
end

--=============================================================================
-- Applying the aim
--=============================================================================

local TWO_PI = math.pi * 2

local function aimAt(worldPosition, deltaTime)
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local controller = cameraController()
    if not controller or type(controller.SetRotation) ~= "function" then return end

    -- The controller's own pitch/yaw state, in radians.
    local rotation = rawget(controller, "Rotation")
    if typeof(rotation) ~= "Vector2" then return end

    -- Time-based smoothing, so the aim behaves identically at any frame rate.
    -- Clamped because a long frame (alt-tab, loading hitch) would otherwise
    -- snap the aim instantly.
    local dt = math.clamp(deltaTime or (1 / 60), 0, 0.1)
    local alpha = math.clamp(1 - math.exp(-dt * (2 + CONFIG.AimSpeed * 0.58)), 0, 1)

    local pitch, yaw = CFrame.lookAt(camera.CFrame.Position, worldPosition):ToOrientation()

    -- Pitch is bounded, so a plain difference is correct.
    local pitchNext = rotation.X + (pitch - rotation.X) * alpha

    -- Yaw accumulates past +/-pi, so take the shortest way round. See header -
    -- this is the single most common bug in code that does this.
    local yawDelta = (yaw - rotation.Y + math.pi) % TWO_PI - math.pi
    local yawNext = rotation.Y + yawDelta * alpha

    controller:SetRotation(Vector2.new(pitchNext, yawNext))
end

--=============================================================================
-- The FOV circle
--=============================================================================

local FovCircle = nil
if CONFIG.ShowFOV then
    local ok, circle = pcall(function()
        local drawing = Drawing.new("Circle")
        drawing.Thickness = 1
        drawing.NumSides = 64
        drawing.Filled = false
        drawing.Visible = false
        return drawing
    end)
    FovCircle = ok and circle or nil
    if not FovCircle then CONFIG.ShowFOV = false end
end

local function updateFovCircle(cursor)
    if not FovCircle then return end
    if not CONFIG.Enabled or not CONFIG.ShowFOV or CONFIG.IgnoreFOV then
        FovCircle.Visible = false
        return
    end
    FovCircle.Position = cursor
    FovCircle.Radius = CONFIG.FOVRadius
    FovCircle.Color = CONFIG.FOVCircleColor
    FovCircle.Transparency = CONFIG.FOVCircleTransparency
    FovCircle.Visible = true
end

--=============================================================================
-- The loop
--=============================================================================

local function isAimKeyHeld()
    local key = CONFIG.AimKey
    if typeof(key) == "EnumItem" and key.EnumType == Enum.UserInputType then
        return UserInputService:IsMouseButtonPressed(key)
    end
    return UserInputService:IsKeyDown(key)
end

local function step(deltaTime)
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local location = UserInputService:GetMouseLocation()
    local cursor = Vector2.new(location.X, location.Y)

    updateFovCircle(cursor)

    if not CONFIG.Enabled then return end
    if not isAimKeyHeld() then return end
    if UserInputService:GetFocusedTextBox() then return end

    local part = selectTarget(camera, cursor)
    if not part or not part.Parent then return end

    aimAt(part.Position, deltaTime)
end

local stepConn = RunService.RenderStepped:Connect(function(deltaTime)
    if env.__AimbotToken ~= Token then return end
    local ok, err = pcall(step, deltaTime)
    if not ok then
        warn("[Aimbot] " .. tostring(err))
    end
end)

-- The controllers are rebuilt on respawn.
local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__AimbotToken ~= Token then return end
    CameraControllerCache = nil
    FighterControllerCache = nil
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__AimbotCleanup = function()
    env.__AimbotToken = nil
    pcall(function() stepConn:Disconnect() end)
    pcall(function() characterConn:Disconnect() end)
    if FovCircle then
        pcall(function() FovCircle:Remove() end)
        FovCircle = nil
    end
    env.__AimbotCleanup = nil
end

notify("hold your aim key - speed " .. tostring(CONFIG.AimSpeed)
    .. ", FOV " .. (CONFIG.IgnoreFOV and "off" or tostring(CONFIG.FOVRadius)))
