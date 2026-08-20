--[[============================================================================
    FLICKBOT  -  snaps to a target, fires, and comes back
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Press the flick key. Your view travels onto the nearest target along a path
    that is generated to look like a human hand moved it, fires, and then stops.
    It does not track you onto anyone afterwards - one flick, one shot, then a
    cooldown.

    WHY IT EXISTS
    Read `aimbot.lua` first, and specifically the detectability section. A
    smoothed aimbot produces the same curve every single time: a clean
    exponential approach that decelerates perfectly onto the exact centre of a
    hitbox and never wobbles. That shape is the giveaway, not the speed.

    This file is the answer to that. Rather than a formula that produces the
    ideal path, it generates a path from a model of how a person actually moves
    a mouse - which is to say, badly, and differently every time.

===============================================================================
    THE MODEL
===============================================================================

    Human pointing has been studied for decades, and the findings are
    surprisingly specific. Five of them are implemented here.

    1. FITTS'S LAW  -  how long the movement takes
       People take longer to reach small or distant targets, and the
       relationship is logarithmic rather than linear:

           difficulty = log2(distance / targetWidth + 1)
           duration   = a + b * difficulty

       So a target twice as far away does not take twice as long. This is why a
       fixed "flick duration" looks wrong: real flicks across the screen and
       small adjustments nearby take noticeably different amounts of time, but
       not proportionally different.

    2. THE LOG-NORMAL VELOCITY PROFILE  -  how the movement is distributed
       Hand movement is not linear and it is not symmetric either. Speed rises
       quickly to a peak about a third of the way through, then trails off
       slowly. That shape is a log-normal distribution, so position along the
       path is its cumulative distribution function (CDF) and speed is its
       probability density (PDF).

       The alternative - moving at a constant rate, or easing symmetrically -
       produces motion that looks mechanical even when it is slow.

    3. SUBMOVEMENTS  -  the correction at the end
       People do not arrive in one motion. The main movement lands slightly
       short (usually) or slightly past (sometimes), and a smaller, faster
       corrective movement follows to close the gap. Occasionally a third,
       smaller still.

       Each correction here is its own log-normal profile with its own start
       time, layered on top of the primary. That layering is what produces the
       small settle at the end of the path rather than a clean stop.

       This one matters more than any of the others. An aim that arrives once,
       exactly, and stops dead is the single least human thing a cursor can do.

    4. TREMOR AND DRIFT  -  the noise floor
       A hand holding a mouse is never still. Two separate things are modelled:

       - Physiological tremor: a real 8-12 Hz oscillation everybody has. Here it
         is a sine wave at a random frequency in that band, with a random phase
         per axis. Its amplitude is divided down while the hand is moving fast,
         because tremor is most visible when you are barely moving.

       - Drift: modelled as an Ornstein-Uhlenbeck process, which is a random
         walk with a pull back toward zero:

             noise += -theta * noise * dt + sigma * sqrt(dt) * randomNormal()

         A plain random walk wanders off and never returns; the `-theta * noise`
         term keeps it hovering around the true path. That is what unsteadiness
         actually looks like, as opposed to white noise, which looks like a
         glitch.

    5. SIGNAL-DEPENDENT NOISE  -  faster means sloppier
       Motor noise scales with the size of the command sent to the muscle, so
       error is proportional to speed. Implemented as a term added to each
       sample proportional to the current velocity. It is why fast flicks are
       messier than slow ones - and why an aimbot that is equally precise at
       every speed does not read as human.

    THE PATH IS ALSO CURVED
    Straight lines are not natural either. The whole path is bent sideways by a
    bump function that peaks in the middle and is zero at both ends (so the
    start and end points stay exact). The amount of bend depends on the
    DIRECTION of the movement - horizontal flicks curve less than vertical ones,
    because of how a wrist and forearm actually rotate.

    THE SAMPLE TIMES ARE UNEVEN TOO
    Points along the path are not spaced evenly in time. The gaps are drawn from
    a gamma distribution with a mean of about 7.8 ms, which mimics the jitter of
    real mouse polling. Perfectly even spacing is itself a tell.

===============================================================================
    HOW THE PATH IS ACTUALLY FOLLOWED
===============================================================================

    The path is generated in 2D screen coordinates, because that is the space
    all the research above is in and the space a mouse moves in. Each point is
    then turned into a 3D direction with

        camera:ViewportPointToRay(x, y).Direction

    and the camera is pointed along those directions in turn, using
    `CameraController:SetRotation` - never `camera.CFrame`. If you have not read
    why, `aimbot.lua` explains it at length, along with the yaw-wrap bug.

    Each frame we advance through the baked path by elapsed time and interpolate
    between the two surrounding points, so the flick runs at the same speed
    regardless of frame rate.

    THE MOVING-TARGET CORRECTION
    The path was baked when the flick started. If the target moved since, it
    ends somewhere they no longer are. So the direction is nudged toward where
    the target is NOW, weighted by how far through the flick we are:

        corrected = direction + (currentTargetDirection - bakedEndDirection) * progress

    At the start the weight is zero, so the human-looking early motion is
    untouched. By the end the weight is one, so it lands on the target. The
    correction is invisible precisely because it is smallest when you would
    notice it.

===============================================================================
    THE STATE MACHINE
===============================================================================

        Idle      -> waiting for the key
        Flicking  -> following the path
        PostShot  -> arrived; waiting ShotDelay, then firing
        Cooldown  -> refusing to flick again until Cooldown elapses

    `ShotDelay` exists because firing on the exact frame you arrive is another
    impossible number. `Cooldown` exists because flicking continuously is just a
    worse-looking aimbot.

    REQUIREMENTS
    `VirtualInputManager` for the shot (only if `Shoot` is on) - executors
    normally have the elevated identity needed to construct one. Nothing else.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Press to flick. A key, or a mouse button via Enum.UserInputType.
    FlickKey = Enum.KeyCode.E,

    -- Fire when the flick arrives.
    Shoot = true,

    -- Milliseconds between arriving and firing. 0 is not humanly possible.
    ShotDelayMs = 40,

    -- Minimum milliseconds between flicks.
    CooldownMs = 250,

    -- Roughly how long the flick takes, in milliseconds. This is a baseline -
    -- Fitts's law scales it by how far and how difficult the flick is.
    FlickDurationMs = 110,

    -- How much the path bends sideways. 0 is a straight line, 50 is a big arc.
    Curvature = 12,

    -- Tremor and drift. 0 is a perfectly clean path, 100 is very messy.
    -- More human-looking AND less accurate. See the header.
    Humanness = 30,

    -- Target selection (same rules as aimbot.lua)
    FOVRadius = 170,
    RequireVisible = true,
    TeamCheck = true,
    MaxDistance = 2000,
    AimPart = "Auto",       -- "Head", "Body", "Closest", "Auto"

    Notify = true,
}

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
            Title = "Flickbot", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__FlickbotCleanup then
    pcall(env.__FlickbotCleanup)
end

local Token = {}
env.__FlickbotToken = Token

local VIM = nil
if CONFIG.Shoot then
    local ok, instance = pcall(Instance.new, "VirtualInputManager")
    VIM = ok and instance or nil
    if not VIM then
        CONFIG.Shoot = false
        notify("no VirtualInputManager - flicking without shooting")
    end
end

local Rng = Random.new()

--=============================================================================
-- The maths
--=============================================================================

-- A normally-distributed random number, via Box-Muller. `Random` only gives
-- uniform numbers, and everything above needs a bell curve.
local function normal(mean, deviation)
    local first = math.max(Rng:NextNumber(), 1e-15)
    local second = Rng:NextNumber()
    return mean + deviation * (math.sqrt(-2 * math.log(first)) * math.cos(2 * math.pi * second))
end

local function between(minimum, maximum)
    return minimum + Rng:NextNumber() * (maximum - minimum)
end

-- Gamma-distributed sample, Marsaglia-Tsang. Used for the gaps between sample
-- times: a gamma distribution is positive-only and skewed, which is the right
-- shape for "time until the next mouse report".
local function gamma(shape, scale)
    local factor = 1
    if shape < 1 then
        factor = Rng:NextNumber() ^ (1 / shape)
        shape = shape + 1
    end
    local adjusted = shape - (1 / 3)
    local root = math.sqrt(9 * adjusted)
    while true do
        local sample = normal(0, 1)
        local candidate = (1 + (sample / root)) ^ 3
        if candidate > 0 then
            local uniform = math.max(Rng:NextNumber(), 1e-15)
            if uniform < 1 - (0.0331 * sample ^ 4)
                or math.log(uniform) < (0.5 * sample * sample)
                    + adjusted * (1 - candidate + math.log(candidate)) then
                return adjusted * candidate * scale * factor
            end
        end
    end
end

-- Lua has no erf, so this is the standard Abramowitz & Stegun approximation.
-- Accurate to about 1e-7, which is far more than a mouse path needs.
local function erf(value)
    local sign = value < 0 and -1 or 1
    local magnitude = math.abs(value)
    local factor = 1 / (1 + 0.3275911 * magnitude)
    local polynomial = 0.254829592 * factor
        - 0.284496736 * factor ^ 2
        + 1.421413741 * factor ^ 3
        - 1.453152027 * factor ^ 4
        + 1.061405429 * factor ^ 5
    return sign * (1 - polynomial * math.exp(-magnitude * magnitude))
end

-- How far through a submovement we are at time t (0 to 1).
local function lognormalCdf(timeMs, startMs, mean, sigma)
    if timeMs <= startMs then return 0 end
    return 0.5 * (1 + erf((math.log(timeMs - startMs) - mean) / (sigma * math.sqrt(2))))
end

-- How fast that submovement is moving at time t. Used for the speed-dependent
-- noise and to damp tremor while moving.
local function lognormalPdf(timeMs, startMs, mean, sigma)
    if timeMs <= startMs then return 0 end
    local elapsed = timeMs - startMs
    local standardized = (math.log(elapsed) - mean) / sigma
    return math.exp(-0.5 * standardized * standardized)
        / (sigma * math.sqrt(2 * math.pi) * elapsed)
end

-- Zero at both ends, peaks around a third of the way through, normalised to a
-- maximum of 1. This is what shapes the sideways curve so the path bends in the
-- middle without moving where it starts or where it lands.
local function bump(value)
    if value <= 0 or value >= 1 then return 0 end
    return value * value * (1 - value) ^ 3 / 0.03456
end

--=============================================================================
-- The profile
--=============================================================================
-- Constants of the motion model. The four that come from CONFIG are marked;
-- the rest are fixed values taken from how the movement actually behaves.

local function profile()
    local durationMs = math.max(CONFIG.FlickDurationMs, 20)
    local humanness = math.clamp(CONFIG.Humanness, 0, 100) / 30

    return {
        -- Fitts's law: duration = a + b * difficulty
        FittsA = durationMs / 4,
        FittsB = durationMs / 4,
        TargetWidth = 80,           -- assumed target size in pixels

        PeakTimeRatio = 0.32,       -- speed peaks ~1/3 of the way through
        PrimarySigmaMin = 0.2,
        PrimarySigmaMax = 0.26,

        -- Most flicks land slightly short; a few overshoot.
        UndershootMin = 0.97,
        UndershootMax = 1.0,
        OvershootProbability = 0.08,
        OvershootMin = 1.01,
        OvershootMax = 1.04,

        SecondCorrectionProbability = 0,
        CorrectionSigmaMin = 0.1,
        CorrectionSigmaMax = 0.14,

        CurvatureScale = math.clamp(CONFIG.Curvature, 0, 50) / 1000,

        OuTheta = 3.5,              -- how hard drift is pulled back to centre
        OuSigma = 0.5 * humanness,
        TremorFrequencyMin = 8,     -- Hz; the real physiological band
        TremorFrequencyMax = 12,
        TremorAmplitudeMin = 0.05 * humanness,
        TremorAmplitudeMax = 0.18 * humanness,
        SignalDependentNoise = 0.02,

        SampleDeltaMean = 7.8,      -- ms between path samples, on average
        GammaShape = 3.5,
    }
end

--=============================================================================
-- Generating the path
--=============================================================================
-- Returns a list of { x, y, t } in screen coordinates and milliseconds.

local function generatePath(startX, startY, targetX, targetY)
    local p = profile()

    local deltaX, deltaY = targetX - startX, targetY - startY
    local distance = math.sqrt(deltaX * deltaX + deltaY * deltaY)
    if distance < 1 then return {} end

    local directionX, directionY = deltaX / distance, deltaY / distance
    local angle = math.atan2(deltaY, deltaX)

    -- 1. Fitts's law. `exp(normal(0, 0.08))` scatters the duration a little, so
    --    two identical flicks do not take identical time.
    local difficulty = math.log(distance / p.TargetWidth + 1) / math.log(2)
    local duration = math.max((p.FittsA + p.FittsB * difficulty) * math.exp(normal(0, 0.08)), 80)

    -- 2. The primary submovement: usually a little short, occasionally past.
    local factor
    if between(0, 1) < p.OvershootProbability then
        factor = between(p.OvershootMin, p.OvershootMax)
    else
        factor = between(p.UndershootMin, p.UndershootMax)
    end
    local primaryDistance = distance * factor
    local primarySigma = between(p.PrimarySigmaMin, p.PrimarySigmaMax)
    local peakRatio = between(p.PeakTimeRatio - 0.03, p.PeakTimeRatio + 0.03)
    -- The `+ sigma^2` shifts the log-normal so its PEAK lands where we want,
    -- rather than its median.
    local primaryMean = math.log(duration * peakRatio) + primarySigma * primarySigma

    -- 3. Corrections for whatever the primary movement left over.
    local corrections = {}
    local remaining = distance - primaryDistance
    if math.abs(remaining) > 0.5 then
        local sign = remaining > 0 and 1 or -1
        local correctionDistance = math.abs(remaining) * between(0.88, 1.02)
        local correctionSigma = between(p.CorrectionSigmaMin, p.CorrectionSigmaMax)
        local correctionPeak = between(0.12, 0.18)

        corrections[#corrections + 1] = {
            distance = correctionDistance,
            -- Starts partway through the primary, not after it - real
            -- corrections overlap the movement they are correcting.
            startMs = duration * between(0.55, 0.68),
            mean = math.log(duration * correctionPeak) + correctionSigma * correctionSigma,
            sigma = correctionSigma,
            directionX = directionX * sign,
            directionY = directionY * sign,
        }

        local secondRemaining = remaining - correctionDistance * sign
        if math.abs(secondRemaining) > 0.3
            and between(0, 1) < p.SecondCorrectionProbability then
            local secondSign = secondRemaining > 0 and 1 or -1
            local secondSigma = between(0.1, 0.16)
            local secondPeak = between(0.08, 0.12)
            corrections[#corrections + 1] = {
                distance = math.abs(secondRemaining) * between(0.85, 1.05),
                startMs = duration * between(0.78, 0.88),
                mean = math.log(duration * secondPeak) + secondSigma * secondSigma,
                sigma = secondSigma,
                directionX = directionX * secondSign,
                directionY = directionY * secondSign,
            }
        end
    end

    -- 4. Curvature, scaled by direction. Vertical flicks bow more than
    --    horizontal ones. Randomly signed, so the arc goes either way.
    local angleScale = 0.5 + 0.8 * math.abs(math.sin(angle)) - 0.15 * math.abs(math.cos(angle))
    local curvature = distance * p.CurvatureScale * angleScale * normal(0, 1)

    -- 5. Tremor: a real oscillation, random frequency in the human band, with
    --    an independent phase per axis so it is not a diagonal wobble.
    local tremorFrequency = between(p.TremorFrequencyMin, p.TremorFrequencyMax)
    local tremorAmplitude = between(p.TremorAmplitudeMin, p.TremorAmplitudeMax)
    local tremorPhaseX = between(0, 2 * math.pi)
    local tremorPhaseY = between(0, 2 * math.pi)

    -- Uneven sample times. Runs slightly past the end so the settle is included.
    local endTime = duration * 1.15
    local sampleTimes = {}
    local sampleTime = 0
    while sampleTime < endTime do
        sampleTime = sampleTime + math.clamp(gamma(p.GammaShape, p.SampleDeltaMean / p.GammaShape), 2, 25)
        if sampleTime <= endTime + 15 then
            sampleTimes[#sampleTimes + 1] = sampleTime
        end
    end

    local noiseX, noiseY = 0, 0
    local path = {}

    for index, timeMs in ipairs(sampleTimes) do
        local deltaMs = index > 1 and (timeMs - sampleTimes[index - 1]) or p.SampleDeltaMean
        local deltaSeconds = deltaMs / 1000

        local progress = lognormalCdf(timeMs, 0, primaryMean, primarySigma)

        -- Position along the primary movement, pushed sideways by the curve.
        -- (-directionY, directionX) is the direction at right angles to travel.
        local x = startX + directionX * primaryDistance * progress
            - directionY * curvature * bump(progress)
        local y = startY + directionY * primaryDistance * progress
            + directionX * curvature * bump(progress)

        -- Each correction layered on top, each on its own schedule.
        for _, correction in ipairs(corrections) do
            local correctionProgress = lognormalCdf(timeMs, correction.startMs, correction.mean, correction.sigma)
            x = x + correction.directionX * correction.distance * correctionProgress
            y = y + correction.directionY * correction.distance * correctionProgress
        end

        -- Current speed, summed over every active submovement.
        local velocity = primaryDistance * lognormalPdf(timeMs, 0, primaryMean, primarySigma)
        for _, correction in ipairs(corrections) do
            velocity = velocity + correction.distance
                * lognormalPdf(timeMs, correction.startMs, correction.mean, correction.sigma)
        end

        -- Drift: random walk with a pull back toward the path. See header.
        noiseX = noiseX + (-p.OuTheta * noiseX * deltaSeconds
            + p.OuSigma * math.sqrt(deltaSeconds) * normal(0, 1))
        noiseY = noiseY + (-p.OuTheta * noiseY * deltaSeconds
            + p.OuSigma * math.sqrt(deltaSeconds) * normal(0, 1))

        -- Tremor, damped while moving fast.
        local timeSeconds = timeMs / 1000
        local tremorScale = 1 / (1 + velocity * 0.3)
        local tremorX = math.sin(2 * math.pi * tremorFrequency * timeSeconds + tremorPhaseX)
        local tremorY = math.sin(2 * math.pi * tremorFrequency * timeSeconds + tremorPhaseY)

        path[#path + 1] = {
            x = x + noiseX + tremorAmplitude * tremorScale * tremorX
                + p.SignalDependentNoise * velocity * normal(0, 1),
            y = y + noiseY + tremorAmplitude * tremorScale * tremorY
                + p.SignalDependentNoise * velocity * normal(0, 1),
            t = timeMs,
        }
    end

    return path
end

--=============================================================================
-- Target selection  (same rules as aimbot.lua, in short form)
--=============================================================================

local CameraControllerCache, FighterControllerCache = nil, nil

local function requireController(name)
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild(name)
    if not module then return nil end
    local ok, controller = pcall(require, module)
    return (ok and type(controller) == "table") and controller or nil
end

local function cameraController()
    if not CameraControllerCache then
        CameraControllerCache = requireController("CameraController")
    end
    return CameraControllerCache
end

local function isSpawnShielded(player)
    if not FighterControllerCache then
        FighterControllerCache = requireController("FighterController")
    end
    local controller = FighterControllerCache
    if type(controller) ~= "table" or type(controller.GetFighter) ~= "function" then
        return false
    end
    local ok, fighter = pcall(controller.GetFighter, controller, player)
    if not ok or type(fighter) ~= "table" then return false end
    local entity = rawget(fighter, "Entity")
    local data = entity ~= nil and rawget(entity, "Data") or nil
    return data ~= nil and rawget(data, "IsInvincible") == true
end

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

local function isPartVisible(character, part, camera)
    if not part then return false end
    RayParams.FilterDescendantsInstances = { LocalPlayer.Character, character }
    local origin = camera.CFrame.Position
    local direction = part.Position - origin
    if direction.Magnitude <= 0 then return false end
    return Workspace:Raycast(origin, direction, RayParams) == nil
end

local function headPart(character)
    return character:FindFirstChild("HitboxHead") or character:FindFirstChild("Head")
end

local function bodyPart(character)
    return character:FindFirstChild("HitboxBody")
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChildWhichIsA("BasePart")
end

local function pickPart(character, camera)
    local head, body = headPart(character), bodyPart(character)
    if CONFIG.AimPart == "Head" then return head or body end
    if CONFIG.AimPart == "Body" then return body or head end
    if CONFIG.AimPart == "Auto" and head and isPartVisible(character, head, camera) then
        return head
    end
    return body or head
end

local function selectTarget(camera, cursor)
    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    local origin = localRoot and localRoot.Position or camera.CFrame.Position

    local best, bestScore = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Parent == Players then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local teammate = CONFIG.TeamCheck and player.Team ~= nil and player.Team == LocalPlayer.Team

            if humanoid and humanoid.Health > 0 and not teammate and not isSpawnShielded(player) then
                local part = pickPart(character, camera)
                if part and (part.Position - origin).Magnitude <= CONFIG.MaxDistance then
                    local screen = camera:WorldToViewportPoint(part.Position)
                    if screen.Z > 0 then
                        local screenDistance = (Vector2.new(screen.X, screen.Y) - cursor).Magnitude
                        if screenDistance <= CONFIG.FOVRadius
                            and (not CONFIG.RequireVisible or isPartVisible(character, part, camera))
                            and screenDistance < bestScore then
                            best, bestScore = part, screenDistance
                        end
                    end
                end
            end
        end
    end

    return best
end

--=============================================================================
-- The state machine
--=============================================================================

local State = {
    name = "Idle",
    path = nil,          -- list of { direction, t }
    index = 1,
    elapsedMs = 0,
    totalMs = 0,
    bakedEnd = Vector3.zAxis,
    part = nil,
    timer = 0,
    wasHeld = false,
}

local TWO_PI = math.pi * 2

local function toCooldown()
    State.name = "Cooldown"
    State.path = nil
    State.part = nil
    State.timer = math.clamp(CONFIG.CooldownMs, 0, 2000) / 1000
end

local function startFlick()
    local camera = Workspace.CurrentCamera
    if not camera then return false end

    local viewport = camera.ViewportSize
    local centre = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)

    local part = selectTarget(camera, centre)
    if not part then return false end

    local targetPoint = camera:WorldToViewportPoint(part.Position)
    if targetPoint.Z <= 0 then return false end

    -- Generated in 2D from the centre of the screen to the target.
    local generated = generatePath(centre.X, centre.Y, targetPoint.X, targetPoint.Y)
    if #generated < 2 then return false end

    -- Baked into 3D directions once, here, rather than every frame.
    local path = table.create(#generated)
    for index, point in ipairs(generated) do
        path[index] = {
            direction = camera:ViewportPointToRay(point.x, point.y).Direction,
            t = point.t,
        }
    end

    State.path = path
    State.index = 1
    State.elapsedMs = 0
    State.totalMs = path[#path].t
    State.bakedEnd = path[#path].direction
    State.part = part
    State.name = "Flicking"
    return true
end

-- Walk the baked path by elapsed time, interpolating between samples.
local function samplePath(deltaSeconds)
    local path = State.path
    State.elapsedMs = State.elapsedMs + deltaSeconds * 1000

    local index = State.index
    while index < #path and path[index + 1].t <= State.elapsedMs do
        index = index + 1
    end
    State.index = index

    local current = path[index]
    local following = path[index + 1]
    if not following then
        return path[#path].direction, true
    end

    local interval = following.t - current.t
    local alpha = interval > 0 and math.clamp((State.elapsedMs - current.t) / interval, 0, 1) or 1
    return current.direction:Lerp(following.direction, alpha), false
end

local function pointAlong(direction)
    local camera = Workspace.CurrentCamera
    local controller = cameraController()
    if not camera or not controller or type(controller.SetRotation) ~= "function" then
        return
    end

    -- Absolute, not smoothed: the path already contains all the motion. See
    -- aimbot.lua for why this is SetRotation and not camera.CFrame.
    local pitch, yaw = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + direction):ToOrientation()
    controller:SetRotation(Vector2.new(pitch, yaw))
end

local function shoot()
    if not CONFIG.Shoot or not VIM then return end
    local location = UserInputService:GetMouseLocation()
    pcall(function()
        VIM:SendMouseButtonEvent(location.X, location.Y, 0, true, game, 1)
    end)
    task.defer(function()
        pcall(function()
            VIM:SendMouseButtonEvent(location.X, location.Y, 0, false, game, 1)
        end)
    end)
end

local function isKeyHeld()
    local key = CONFIG.FlickKey
    if typeof(key) == "EnumItem" and key.EnumType == Enum.UserInputType then
        return UserInputService:IsMouseButtonPressed(key)
    end
    return UserInputService:IsKeyDown(key)
end

local function step(deltaTime)
    local delta = math.clamp(deltaTime or (1 / 60), 0, 0.1)

    if State.name == "Flicking" then
        local camera = Workspace.CurrentCamera
        local part = State.part
        if not part or not part.Parent or not camera or not State.path then
            toCooldown()
            return
        end

        local direction, finished = samplePath(delta)

        -- Moving-target correction, weighted by progress. See header.
        if State.totalMs > 0 then
            local offset = part.Position - camera.CFrame.Position
            if offset.Magnitude > 0.001 then
                local progress = math.clamp(State.elapsedMs / State.totalMs, 0, 1)
                local corrected = direction + (offset.Unit - State.bakedEnd) * progress
                if corrected.Magnitude > 0.001 then
                    direction = corrected.Unit
                end
            end
        end

        pointAlong(direction)

        if finished then
            if CONFIG.Shoot then
                State.name = "PostShot"
                State.timer = math.clamp(CONFIG.ShotDelayMs, 0, 250) / 1000
            else
                toCooldown()
            end
        end
        return
    end

    if State.name == "PostShot" then
        -- No camera writes here: the rotation we set last frame persists, so
        -- the view simply holds on target while the delay runs out.
        State.timer = State.timer - delta
        if State.timer <= 0 then
            shoot()
            toCooldown()
        end
        return
    end

    if State.name == "Cooldown" then
        State.timer = State.timer - delta
        if State.timer <= 0 then
            State.name = "Idle"
        end
        return
    end

    -- Idle: fire on the press, not while held, so holding the key does not
    -- produce a stream of flicks.
    local held = isKeyHeld()
    local pressed = held and not State.wasHeld
    State.wasHeld = held

    if CONFIG.Enabled and pressed and not UserInputService:GetFocusedTextBox() then
        if not startFlick() then
            toCooldown()
        end
    end
end

local stepConn = RunService.RenderStepped:Connect(function(deltaTime)
    if env.__FlickbotToken ~= Token then return end
    local ok, err = pcall(step, deltaTime)
    if not ok then
        warn("[Flickbot] " .. tostring(err))
        toCooldown()
    end
end)

local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__FlickbotToken ~= Token then return end
    CameraControllerCache = nil
    FighterControllerCache = nil
    toCooldown()
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__FlickbotCleanup = function()
    env.__FlickbotToken = nil
    pcall(function() stepConn:Disconnect() end)
    pcall(function() characterConn:Disconnect() end)
    State.path = nil
    State.part = nil
    env.__FlickbotCleanup = nil
end

notify(("ready - press %s to flick"):format(tostring(CONFIG.FlickKey)))
