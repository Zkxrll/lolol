--[[============================================================================
    AUTO PICKUP  -  grab health when hurt, ammo when empty
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Watches your health and your magazine. When you drop below full health it
    grabs the nearest health pack; when your gun runs dry it grabs the nearest
    ammo pack. You never walk over to either one.

    WHY BOTH ARE IN ONE FILE
    Same reason as walkspeed-and-slide: they are the same machinery. Both find a
    `_drop` part, both use the same body part to touch it with, and both fire the
    same touch. Splitting them would duplicate everything and share nothing.

===============================================================================
    HOW IT WORKS  -  faking a touch
===============================================================================

    Pickups in RIVALS are collected by walking into them. A part touches a part,
    the game's Touched event fires, you get the item. So we don't need to move
    anywhere - we just need the game to believe a touch happened.

        firetouchinterest(yourPart, theDrop, 0)   -- touch BEGAN
        firetouchinterest(yourPart, theDrop, 1)   -- touch ENDED

    `firetouchinterest` is an executor function that fires Roblox's internal
    touch machinery directly. The third argument is the phase: 0 for begin, 1 for
    end. The game's own Touched handler runs exactly as if you had walked in.

    YOU MUST SEND BOTH. A begin without an end leaves the game believing you are
    permanently standing inside that drop. Depending on the handler, that either
    breaks the next pickup or leaves the touch registered forever. The end is
    sent on `task.defer` - one frame later, after the game has processed the
    begin - and re-checks that both parts still exist, because a pickup usually
    destroys the drop the instant it is collected.

    WHICH PART TOUCHES
    We prefer `HitboxBody` if the character has one, falling back to
    HumanoidRootPart. HitboxBody is the part the game already uses for collision
    against pickups, so a touch from it is the most faithful to the real thing.

    IDENTIFYING DROPS
    A pickup is a BasePart literally named `_drop`. What kind it is comes from
    its children:

        has a child called "Health"                    -> health pack
        has a child called "AmmoBalanced" or "Ammo"     -> ammo pack

    Anything else named `_drop` is ignored.

    THE TRIGGER CONDITIONS
      Health: fires when you are missing 25 or more HP. Not "below full" -
              chasing a 3 HP scratch across the map would be obvious and would
              waste a pack you might need later.
      Ammo:   fires when your equipped weapon's Ammo reads 0 or less. Empty, not
              low - grabbing ammo at half a magazine wastes the pack.

    ONLY ONE PER PASS. If a health drop was touched this pass, ammo is skipped
    until the next one. Firing two touches in the same frame can have the second
    swallowed while the game is still processing the first.

    THE RETRY LOOP
    When a condition is true but no drop was found, we retry every 0.05s instead
    of giving up. A pack may be about to spawn, or one may be about to come into
    range. When no condition is true the loop stops entirely, so an idle script
    costs nothing.

    REQUIREMENTS
    `firetouchinterest`. NOTE: Solara and Xeno both ship a `firetouchinterest`
    that exists and silently does nothing - it will pass a `type()` check and
    then never register a touch. This file detects both by name and refuses to
    run rather than pretending to work.

============================================================================--]]

local CONFIG = {
    AutoHeal = true,
    AutoAmmo = true,

    -- Grab health once you are missing at least this much HP.
    MissingHealthThreshold = 25,

    -- How far away a drop can be and still be grabbed, in studs.
    -- math.huge = anywhere on the map. Lower it to stay less obvious.
    MaxDistance = math.huge,

    -- Seconds between retries while a condition is unmet.
    RetryDelay = 0.05,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Auto Pickup", Text = text, Duration = 4,
        })
    end)
end

-- Honest capability check. A function existing is not the same as it working.
if type(firetouchinterest) ~= "function" then
    notify("your executor lacks firetouchinterest - cannot run")
    return
end

local executorName = ""
pcall(function()
    if type(identifyexecutor) == "function" then
        executorName = string.lower(tostring(identifyexecutor()))
    end
end)
if executorName:find("solara") or executorName:find("xeno") then
    notify("this executor's firetouchinterest is fake - cannot run")
    return
end

local env = (getgenv and getgenv()) or _G
if env.__AutoPickupCleanup then
    pcall(env.__AutoPickupCleanup)
end

local Token = {}
env.__AutoPickupToken = Token

local FighterController = nil

--=============================================================================
-- Finding things
--=============================================================================

-- The part we touch drops with. HitboxBody is what the game itself collides
-- against, so prefer it.
local function touchPart()
    local character = LocalPlayer.Character
    if not character then return nil end
    return character:FindFirstChild("HitboxBody")
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChildWhichIsA("BasePart")
end

local function dropKind(drop)
    if not drop or not drop:IsA("BasePart") or drop.Name ~= "_drop" then
        return nil
    end
    if drop:FindFirstChild("Health") then
        return "Health"
    end
    if drop:FindFirstChild("AmmoBalanced") or drop:FindFirstChild("Ammo") then
        return "Ammo"
    end
    return nil
end

local function findNearestDrop(kind, from)
    local best, bestDistance = nil, CONFIG.MaxDistance
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if dropKind(descendant) == kind then
            local distance = (descendant.Position - from.Position).Magnitude
            if distance < bestDistance then
                best, bestDistance = descendant, distance
            end
        end
    end
    return best
end

-- Your equipped weapon, for reading its ammo count. Same PlayerScripts
-- controller path the other features use.
local function equippedItem()
    if not FighterController then
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
        local module = controllers and controllers:FindFirstChild("FighterController")
        if not module then return nil end
        local ok, controller = pcall(require, module)
        if not ok then return nil end
        FighterController = controller
    end

    local fighter = FighterController.LocalFighter
    if not fighter and type(FighterController.GetFighter) == "function" then
        local ok, value = pcall(FighterController.GetFighter, FighterController, LocalPlayer)
        fighter = ok and value or nil
    end

    return type(fighter) == "table" and rawget(fighter, "EquippedItem") or nil
end

local function readAmmo()
    local item = equippedItem()
    if type(item) ~= "table" then return nil end
    local ok, value = pcall(function() return item.Ammo end)
    return (ok and type(value) == "number") and value or nil
end

--=============================================================================
-- The touch
--=============================================================================

local function touchDrop(drop, part)
    if not drop or not drop.Parent or not part or not part.Parent then
        return false
    end

    firetouchinterest(part, drop, 0)   -- begin

    -- End one frame later, and only if both parts survived - collecting a drop
    -- usually destroys it immediately.
    task.defer(function()
        if drop.Parent and part.Parent then
            firetouchinterest(part, drop, 1)   -- end
        end
    end)

    return true
end

--=============================================================================
-- One pass. Returns true if a condition is still unmet and we should retry.
--=============================================================================

local function pass()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return false
    end

    local part = touchPart()
    if not part then
        return false
    end

    local touchedSomething = false
    local shouldRetry = false

    local missingHealth = math.max(humanoid.MaxHealth - humanoid.Health, 0)
    if CONFIG.AutoHeal and missingHealth >= CONFIG.MissingHealthThreshold then
        shouldRetry = true   -- still hurt, keep looking even if nothing is nearby
        local drop = findNearestDrop("Health", part)
        if drop then
            touchedSomething = touchDrop(drop, part)
        end
    end

    -- Only one touch per pass - see header.
    if not touchedSomething and CONFIG.AutoAmmo then
        local ammo = readAmmo()
        if type(ammo) == "number" and ammo <= 0 then
            shouldRetry = true
            local drop = findNearestDrop("Ammo", part)
            if drop then
                touchDrop(drop, part)
            end
        end
    end

    return shouldRetry
end

--=============================================================================
-- Retry loop
--=============================================================================
-- Only runs while there is something to do. A healthy player with a full
-- magazine costs nothing.

local retryActive = false

local function startRetryLoop()
    if retryActive then return end
    retryActive = true

    task.spawn(function()
        while env.__AutoPickupToken == Token do
            local keepGoing = pass()
            if not keepGoing then
                break
            end
            task.wait(CONFIG.RetryDelay)
        end
        retryActive = false
    end)
end

-- Waking up is event-driven: losing health, or firing your last round.
local connections = {}

local function bindCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then return end

    table.insert(connections, humanoid.HealthChanged:Connect(function()
        if env.__AutoPickupToken ~= Token then return end
        startRetryLoop()
    end))
end

if LocalPlayer.Character then
    bindCharacter(LocalPlayer.Character)
end

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function(character)
    FighterController = nil   -- stale after a respawn
    bindCharacter(character)
end))

-- Health events cover healing, but not shooting yourself dry, so poll slowly for
-- the ammo condition. Cheap: it stops as soon as the retry loop takes over.
task.spawn(function()
    while env.__AutoPickupToken == Token do
        if CONFIG.AutoAmmo and not retryActive then
            local ammo = readAmmo()
            if type(ammo) == "number" and ammo <= 0 then
                startRetryLoop()
            end
        end
        task.wait(0.25)
    end
end)

env.__AutoPickupCleanup = function()
    env.__AutoPickupToken = nil
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
    env.__AutoPickupCleanup = nil
end

notify(("loaded - heal %s, ammo %s"):format(
    CONFIG.AutoHeal and "on" or "off",
    CONFIG.AutoAmmo and "on" or "off"
))
