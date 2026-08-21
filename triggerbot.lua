--[[============================================================================
    TRIGGERBOT  -  shoots for you when your crosshair is already on someone
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    It does not aim. You aim. It watches what is under your crosshair, and the
    moment that is an enemy who can actually be shot, it clicks for you.

    That distinction is the whole point. An aimbot moves your view onto people,
    which is unmistakable to anyone watching. A triggerbot only removes your
    reaction time, which looks like being fast.

===============================================================================
    HOW IT DECIDES THERE IS A TARGET
===============================================================================

    Once per frame, cast a ray from the camera through your cursor and see what
    it hits first:

        local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
        local result = Workspace:Raycast(ray.Origin, ray.Direction * range, params)

    If the first thing the ray hits belongs to an enemy, that is your target.

    Notice what this gives you for free: VISIBILITY. A ray stops at the first
    thing in its way, so if there is a wall between you and someone, the ray
    hits the wall and there is no target. You never need a separate "can I see
    them" check, and you can never fire into a wall because of a stale one. The
    full script goes out of its way to preserve this property - its visibility
    cache deliberately stores nothing for the triggerbot, so no cached "yes"
    from a moment ago can ever pull the trigger.

    Your own character is excluded from the ray, otherwise your own arms and gun
    would block every shot.

    From the hit part we walk up to the Model it belongs to
    (`FindFirstAncestorWhichIsA("Model")`), and ask whether a Player owns that
    model. Hitting someone's foot, head or backpack all resolve to the same
    person.

===============================================================================
    THE FOUR GATES
===============================================================================

    Having a target is not enough. Four things are checked before firing.

    1. TEAM AND LIFE
       Not you, not a teammate, not a corpse.

    2. SPAWN SHIELD
       Freshly spawned players are invincible for a moment, flagged by the game
       as `IsInvincible`. Shooting them does literally nothing, and the noise
       and muzzle flash are pure downside. Note that the target is still TRACKED
       while shielded and only the firing is blocked - so the instant the shield
       drops, the very next frame fires. Refusing to track them at all would
       cost you the reaction-time window every time.

    3. REACTION TIME
       If `ReactionTime` is above zero, a target has to have been under your
       crosshair for that long before the shot goes. The timer is keyed to WHO
       is under the crosshair, not to time in general - swing onto a new person
       and their timer starts fresh. Without that, sweeping your aim across a
       room would fire at whoever happened to be there when an unrelated timer
       expired.

       This is the single most important setting in the file. Zero means you
       fire on the exact frame anyone crosses your crosshair, which no human
       does, ever. A value between 0.05 and 0.15 is a fast human.

    4. THE WEAPON IS ACTUALLY READY
       Your gun has its own state, and clicking while it is busy does nothing
       but produce input the server can see:

           _reload_cooldown   still reloading
           _shoot_cooldown    still in the previous shot's cooldown
           _is_charging       a charge-up weapon is winding up

       On top of that we keep our own minimum interval, taken from the weapon's
       own cooldown numbers (`ShootCooldown`, `AttackCooldown`, and so on,
       whichever is largest) so we never click faster than the weapon can
       possibly fire.

===============================================================================
    HOW THE CLICK IS SENT
===============================================================================

        local vim = Instance.new("VirtualInputManager")
        vim:SendMouseButtonEvent(x, y, 0, true, game, 1)     -- press
        vim:SendMouseButtonEvent(x, y, 0, false, game, 1)    -- release

    `VirtualInputManager` is Roblox's own input-injection object. The click
    enters at the same place a real mouse click does, so the game's own code
    handles it exactly as if you had clicked - no remote firing, no reaching
    into the weapon, nothing to reimplement and nothing to get wrong when the
    game changes. `0` is the left button and `true`/`false` are press and
    release.

    The release is sent on `task.defer` - one frame later - because a press and
    release in the same frame can be collapsed and missed entirely.

    HOLD WEAPONS
    Some weapons are held rather than clicked; the Flamethrower is the one in
    RIVALS. For those we send the press and simply do not release it while the
    target stays valid, releasing only when it stops being valid. Sending
    repeated clicks to a hold weapon just stutters it.

    ONE MORE GATE, EASY TO MISS
    If you are holding the mouse button yourself, the triggerbot stands down
    entirely. Otherwise your real click and its synthetic click interleave and
    the weapon does something neither of you asked for.

    REQUIREMENTS
    Nothing executor-specific, but `VirtualInputManager` needs the elevated
    thread identity that executors normally run scripts with. If your executor
    cannot construct one, this file cannot work and will tell you so.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Seconds a target must be under your crosshair before firing.
    -- 0 = instant, which is not humanly possible. See header.
    ReactionTime = 0.08,

    -- Don't shoot teammates.
    TeamCheck = true,

    -- How far the ray reaches, in studs.
    MaxDistance = 2000,

    -- Weapons that are held down rather than clicked.
    HoldWeapons = { ["Flamethrower"] = true },

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
            Title = "Triggerbot", Text = text, Duration = 4,
        })
    end)
end

-- VirtualInputManager can only be constructed from an elevated thread. If this
-- fails there is no point continuing.
local ok, VIM = pcall(Instance.new, "VirtualInputManager")
if not ok or not VIM then
    notify("your executor cannot create a VirtualInputManager - cannot run")
    return
end

local env = (getgenv and getgenv()) or _G
if env.__TriggerbotCleanup then
    pcall(env.__TriggerbotCleanup)
end

local Token = {}
env.__TriggerbotToken = Token

--=============================================================================
-- Finding your weapon
--=============================================================================

local FighterControllerCache = nil

local function fighterController()
    if FighterControllerCache then return FighterControllerCache end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("FighterController")
    if not module then return nil end
    local success, controller = pcall(require, module)
    FighterControllerCache = (success and type(controller) == "table") and controller or nil
    return FighterControllerCache
end

local function fighterFor(subject)
    local controller = fighterController()
    if not controller then return nil end
    if subject == nil then
        return controller.LocalFighter
    end
    if type(controller.GetFighter) ~= "function" then return nil end
    local success, fighter = pcall(controller.GetFighter, controller, subject)
    return success and fighter or nil
end

local function equippedItem()
    local fighter = fighterFor(nil)
    if not fighter and type((fighterController() or {}).GetFighter) == "function" then
        fighter = fighterFor(LocalPlayer)
    end
    return type(fighter) == "table" and rawget(fighter, "EquippedItem") or nil
end

--=============================================================================
-- Weapon readiness
--=============================================================================

-- The slowest of the weapon's own cooldown numbers. We never click faster than
-- this, whatever the weapon's internal state says.
local COOLDOWN_FIELDS = {
    "ShootCooldown", "ShootBurstCooldown", "QuickShotCooldown",
    "ChargeReleaseCooldown", "AttackCooldown", "BladeCooldown",
}

local function shotInterval(item)
    local info = item and item.Info or nil
    local interval = 0.05
    for _, field in ipairs(COOLDOWN_FIELDS) do
        local value = info and info[field]
        if type(value) == "number" then
            interval = math.max(interval, value)
        end
    end
    return interval
end

-- These three fields are timestamps and flags the weapon keeps on itself. Read
-- with rawget so we never trip a metatable on the way past.
local function isWeaponBusy(item)
    if not item then return true end
    local now = tick()

    local reload = rawget(item, "_reload_cooldown")
    if type(reload) == "number" and reload - now > 0 then return true end

    local shoot = rawget(item, "_shoot_cooldown")
    if type(shoot) == "number" and shoot - now > 0 then return true end

    if rawget(item, "_is_charging") == true then return true end

    return false
end

--=============================================================================
-- Finding what is under the crosshair
--=============================================================================

-- Reused rather than rebuilt every frame - a RaycastParams is not free, and
-- this runs 60+ times a second.
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
local FilteredCharacter = nil

local function rayParams()
    local character = LocalPlayer.Character
    if character ~= FilteredCharacter then
        FilteredCharacter = character
        RayParams.FilterDescendantsInstances = { character }
    end
    return RayParams
end

local function cursorPosition()
    local location = UserInputService:GetMouseLocation()
    return location.X, location.Y
end

local function isAlive(player)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

-- The spawn shield flag, read from the target's fighter entity. Absent rather
-- than false when they are not shielded, so test for truthiness only.
local function isSpawnShielded(player)
    local fighter = fighterFor(player) or fighterFor(player.Character)
    local entity = type(fighter) == "table" and rawget(fighter, "Entity") or nil
    local data = entity ~= nil and rawget(entity, "Data") or nil
    return data ~= nil and rawget(data, "IsInvincible") == true
end

local function isEnemy(player)
    if player == LocalPlayer then return false end
    if player.Parent ~= Players then return false end
    if CONFIG.TeamCheck and player.Team ~= nil and player.Team == LocalPlayer.Team then
        return false
    end
    return isAlive(player)
end

-- Returns the player under the crosshair, or nil. Visibility is implied - see
-- the header.
local function targetUnderCrosshair()
    local camera = Workspace.CurrentCamera
    if not camera then return nil end

    local x, y = cursorPosition()
    local ray = camera:ViewportPointToRay(x, y)
    local result = Workspace:Raycast(ray.Origin, ray.Direction * CONFIG.MaxDistance, rayParams())

    local hit = result and result.Instance
    if not hit then return nil end

    local model = hit:FindFirstAncestorWhichIsA("Model")
    if not model then return nil end

    local player = Players:GetPlayerFromCharacter(model)
    if not player or not isEnemy(player) then return nil end

    return player
end

--=============================================================================
-- Firing
--=============================================================================

local Hold = { active = false, x = 0, y = 0 }
local LastShotAt = 0

local function releaseHold()
    if not Hold.active then return end
    Hold.active = false
    pcall(function()
        VIM:SendMouseButtonEvent(Hold.x, Hold.y, 0, false, game, 1)
    end)
end

local function fire(item)
    local now = tick()
    if now - LastShotAt < 0.05 then return false end

    local x, y = cursorPosition()

    pcall(function()
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
    end)

    if CONFIG.HoldWeapons[item and item.Name or ""] then
        -- Held down until the target stops being valid.
        Hold.active, Hold.x, Hold.y = true, x, y
    else
        -- Released one frame later; same-frame press+release can be swallowed.
        task.defer(function()
            pcall(function()
                VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
            end)
        end)
    end

    LastShotAt = now
    return true
end

--=============================================================================
-- The loop
--=============================================================================

-- Which target the reaction timer is counting for, and since when.
local ReactionTarget, ReactionSince = nil, 0

local function standDown()
    releaseHold()
    ReactionTarget, ReactionSince = nil, 0
end

local function step()
    if not CONFIG.Enabled then
        standDown()
        return
    end

    -- If you are shooting yourself, get out of the way entirely.
    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        standDown()
        return
    end

    local target = targetUnderCrosshair()
    if not target then
        standDown()
        return
    end

    -- Tracked while shielded, but not fired at. See header.
    if isSpawnShielded(target) then
        standDown()
        return
    end

    local item = equippedItem()
    if not item then
        standDown()
        return
    end

    -- Reaction time, keyed to who is under the crosshair.
    local now = tick()
    if ReactionTarget ~= target then
        ReactionTarget, ReactionSince = target, now
        if CONFIG.ReactionTime > 0 then
            releaseHold()
            return
        end
    elseif now - ReactionSince < CONFIG.ReactionTime then
        releaseHold()
        return
    end

    -- A hold weapon that is already held has nothing to do.
    if Hold.active and CONFIG.HoldWeapons[item.Name or ""] then
        return
    end

    if isWeaponBusy(item) then
        releaseHold()
        return
    end

    if now - LastShotAt < shotInterval(item) then
        return
    end

    fire(item)
end

local stepConn = RunService.RenderStepped:Connect(function()
    if env.__TriggerbotToken ~= Token then return end
    local success, err = pcall(step)
    if not success then
        warn("[Triggerbot] " .. tostring(err))
    end
end)

local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__TriggerbotToken ~= Token then return end
    FighterControllerCache = nil
    standDown()
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__TriggerbotCleanup = function()
    env.__TriggerbotToken = nil
    pcall(function() stepConn:Disconnect() end)
    pcall(function() characterConn:Disconnect() end)
    releaseHold()
    env.__TriggerbotCleanup = nil
end

notify(("active - %.0fms reaction time"):format(CONFIG.ReactionTime * 1000))
