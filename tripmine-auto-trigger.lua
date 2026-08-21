--[[============================================================================
    TRIPMINE AUTO TRIGGER  -  set off Subspace tripmines from anywhere
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Subspace tripmines are placed on the map and go off when someone walks into
    them. This sets them off without you being anywhere near, so an enemy mine
    is spent harmlessly before you ever reach it.

    `TeamTrigger` extends it to your own and your allies' mines, which is
    normally not what you want - it wastes your team's mines - so it is off by
    default.

    It uses the same fake-touch technique as `auto-pickup.lua`; read that first
    if `firetouchinterest` is new to you. What is interesting here is not the
    touch, it is everything that has to be true before the touch is worth
    sending.

===============================================================================
    FINDING THE MINES  -  let the game keep the list
===============================================================================

    The obvious approach is to scan the workspace for things that look like
    tripmines. Don't. The game already tags them:

        CollectionService:GetTagged("SubspaceTripmine")
        CollectionService:GetInstanceAddedSignal("SubspaceTripmine")
        CollectionService:GetInstanceRemovedSignal("SubspaceTripmine")

    `CollectionService` is Roblox's tagging system, and games use it to keep
    track of their own objects. When a game tags things you care about, you get
    a maintained list and two events for free - no scanning, no polling, no
    guessing from names, and no cost when nothing is happening.

    Always check for tags before writing a scanner. It is the single biggest
    shortcut available when a game is organised enough to use them.

    Each mine's details come from its attributes, which the game sets itself:

        EnvironmentID     which arena instance it belongs to
        PlacedByUserID    who placed it
        TeamID            whose team it belongs to

===============================================================================
    THE THREE CHECKS BEFORE FIRING
===============================================================================

    1. SAME ENVIRONMENT
       RIVALS runs multiple arenas in one server, and your client can see mines
       from arenas you are not in. Triggering one of those does nothing useful
       and is a touch event the server has no reason to see from you. The
       mine's `EnvironmentID` must match yours.

    2. WHOSE MINE IT IS
       Friendly if you placed it, or if its `TeamID` matches yours. Friendly
       mines are skipped unless `TeamTrigger` is on.

    3. IS IT ACTUALLY ARMED  -  the clever one
       This is the check worth understanding. A mine that is still deploying,
       already spent, or otherwise not live will not respond to a touch, and
       firing at it just produces pointless events.

       There is no "armed" attribute to read. But there is a rendering
       side-effect that gives the same answer for free: the game renders a mine
       differently depending on whose it is and what state it is in, and the
       result is visible on the hitbox as `LocalTransparencyModifier`:

           friendly mine, live  ->  0.5
           enemy mine, live     ->  1

       So the expected value is derived from whose mine it is, and if the actual
       value does not match, the mine is not in the state where a touch does
       anything, and it is skipped.

       `LocalTransparencyModifier` is a purely client-side rendering property.
       Reading it costs nothing and tells you something the game never exposed
       as data. This is a good general technique: when there is no state flag to
       read, look for something the game's own rendering had to compute from
       that state.

    ONE PER PASS
    Once a mine is triggered the function returns immediately rather than
    continuing down the list. Same reason as `auto-pickup.lua` - firing several
    touches inside one frame can have the later ones swallowed while the game is
    still processing the first.

    REQUIREMENTS
    `firetouchinterest`. Solara and Xeno both ship one that exists, passes a
    type check, and never registers a touch - this file detects both by name and
    refuses to run rather than pretending to work.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Also trigger your own and your team's mines. Usually a bad idea.
    TeamTrigger = false,

    -- Seconds between passes.
    Interval = 0.25,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local TAG = "SubspaceTripmine"

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Tripmine Auto Trigger", Text = text, Duration = 4,
        })
    end)
end

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
if env.__TripmineTriggerCleanup then
    pcall(env.__TripmineTriggerCleanup)
end

local Token = {}
env.__TripmineTriggerToken = Token

--=============================================================================
-- Tracking the mines
--=============================================================================
-- Keyed by both the mine and its hitbox, so either one can find the entry.

local Entries = {}
local Destroying = {}

local function untrack(tripmine)
    local entry = Entries[tripmine]
    if entry and entry.Hitbox then
        Entries[entry.Hitbox] = nil
    end
    Entries[tripmine] = nil

    local connection = Destroying[tripmine]
    if connection then
        pcall(function() connection:Disconnect() end)
    end
    Destroying[tripmine] = nil
end

local function track(tripmine)
    if not tripmine or Entries[tripmine] then return end

    -- Spawned because the hitbox may not exist yet when the tag arrives, and
    -- waiting for it must not block the signal handler.
    task.spawn(function()
        local hitbox = tripmine:WaitForChild("Hitbox", 3)
        if not hitbox or not hitbox:IsA("BasePart") or not tripmine.Parent then
            return
        end
        if env.__TripmineTriggerToken ~= Token then return end

        local entry = {
            Tripmine = tripmine,
            Hitbox = hitbox,
            EnvironmentId = tripmine:GetAttribute("EnvironmentID"),
            PlacedBy = tripmine:GetAttribute("PlacedByUserID"),
            TeamId = tripmine:GetAttribute("TeamID"),
        }
        Entries[tripmine] = entry
        Entries[hitbox] = entry

        Destroying[tripmine] = hitbox.Destroying:Connect(function()
            untrack(tripmine)
        end)
    end)
end

--=============================================================================
-- Your side of it
--=============================================================================

local FighterControllerCache = nil

local function localFighter()
    if not FighterControllerCache then
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
        local module = controllers and controllers:FindFirstChild("FighterController")
        if module then
            local ok, controller = pcall(require, module)
            FighterControllerCache = (ok and type(controller) == "table") and controller or nil
        end
    end
    local controller = FighterControllerCache
    if type(controller) ~= "table" then return nil end

    local fighter = controller.LocalFighter
    if not fighter and type(controller.GetFighter) == "function" then
        local ok, value = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and value or nil
    end
    return type(fighter) == "table" and fighter or nil
end

-- Fighter first, character/player attributes as the fallback - the fighter is
-- authoritative but does not exist between rounds.
local function localIds()
    local character = LocalPlayer.Character
    local fighter = localFighter()

    local environmentId = fighter and rawget(fighter, "EnvironmentID") or nil
    if environmentId == nil and character then
        environmentId = character:GetAttribute("EnvironmentID")
    end

    local teamId = fighter and rawget(fighter, "TeamID") or nil
    if teamId == nil then
        teamId = LocalPlayer:GetAttribute("TeamID")
    end

    return environmentId, teamId
end

local function touchPart()
    local character = LocalPlayer.Character
    if not character then return nil end
    local part = character:FindFirstChild("HitboxBody")
        or character:FindFirstChild("HumanoidRootPart")
    return (part and part:IsA("BasePart")) and part or nil
end

--=============================================================================
-- One pass
--=============================================================================

local function pass()
    if not CONFIG.Enabled then return end

    local part = touchPart()
    if not part then return end

    local localEnvironmentId, localTeamId = localIds()

    for tripmine, entry in pairs(Entries) do
        -- Entries are stored twice; only walk the mine-keyed half.
        if tripmine == entry.Tripmine then
            local hitbox = entry.Hitbox
            if not hitbox or not hitbox.Parent or not tripmine.Parent then
                untrack(tripmine)
            else
                local friendly = entry.PlacedBy == LocalPlayer.UserId
                if not friendly and localTeamId ~= nil and entry.TeamId ~= nil then
                    friendly = localTeamId == entry.TeamId
                end

                -- The armed check. See header.
                local expectedTransparency = friendly and 0.5 or 1

                if localEnvironmentId == entry.EnvironmentId
                    and (not friendly or CONFIG.TeamTrigger)
                    and hitbox.LocalTransparencyModifier == expectedTransparency then
                    firetouchinterest(hitbox, part, 0)   -- begin
                    firetouchinterest(hitbox, part, 1)   -- end
                    return   -- one per pass; see header
                end
            end
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================

local addedConn = CollectionService:GetInstanceAddedSignal(TAG):Connect(function(tripmine)
    if env.__TripmineTriggerToken ~= Token then return end
    track(tripmine)
end)

local removedConn = CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

for _, tripmine in ipairs(CollectionService:GetTagged(TAG)) do
    track(tripmine)
end

local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__TripmineTriggerToken ~= Token then return end
    FighterControllerCache = nil
end)

task.spawn(function()
    while env.__TripmineTriggerToken == Token do
        local ok, err = pcall(pass)
        if not ok then
            warn("[Tripmine Auto Trigger] " .. tostring(err))
        end
        task.wait(CONFIG.Interval)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__TripmineTriggerCleanup = function()
    env.__TripmineTriggerToken = nil
    pcall(function() addedConn:Disconnect() end)
    pcall(function() removedConn:Disconnect() end)
    pcall(function() characterConn:Disconnect() end)

    for tripmine, entry in pairs(Entries) do
        if tripmine == entry.Tripmine then
            untrack(tripmine)
        end
    end
    table.clear(Entries)
    table.clear(Destroying)

    env.__TripmineTriggerCleanup = nil
end

notify("active" .. (CONFIG.TeamTrigger and " - including friendly mines" or ""))
