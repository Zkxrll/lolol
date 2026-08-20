--[[============================================================================
    AUTO QUEUE  -  requeue the instant a match ends
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Rejoins the queue for a mode of your choice as soon as the last match is
    over - including pressing the cutscene's Skip button so the match-end window
    closes sooner.

===============================================================================
    THE HARD PART IS NOT SENDING THE REQUEST
===============================================================================

    Queueing is one call:

        MatchmakingController:QueueInto(queueKey)

    Everything else in this file exists because of one thing: the server refuses
    the call for a few seconds after a match ends, while the match is "wrapping
    up". So the question is not how to queue, it is exactly when you are allowed
    to, and the answer arrives in stages.

    Four separate things tell you a match has ended, and they do not arrive
    together:

        1. the duel object reports you left it       <- earliest
        2. workspace attribute MatchmadeGameOver     <- a moment later
        3. the Play Again button becomes visible     <- later still
        4. the queue status event says idle/expired

    This listens to the earliest ones and treats a rejection as normal rather
    than as an error: a refused call schedules a retry every 0.1s. Then whichever
    signal arrives first wins, and the rest find the work already done.

    That is the shape worth taking away. When you cannot know when something
    becomes possible, don't hunt for the one true signal - listen to all of
    them, make the action idempotent, and let the first one through do the job.

===============================================================================
    BELIEVED STATE, AND WHY IT IS A GUESS
===============================================================================

        State.Believed  ->  "idle" | "queued" | "matched"

    Called `Believed` deliberately. It is not the server's opinion, it is ours,
    updated when we send something and corrected when a status event disagrees.
    Every trigger sets it back to `idle` before firing, because arriving at a
    trigger means whatever we believed before is stale.

    It exists to stop us queueing when we already are, but it is defence in
    depth, not the real gate - the real gate is that the server accepts or
    rejects. Treating your own optimistic state as authoritative is how these
    scripts get stuck: something desyncs once, and the feature believes it is
    queued forever. Keep the belief, but make sure something external can always
    correct it.

    On top of that, `LastFireAt` blocks two requests inside 1.5s no matter which
    trigger fired them.

===============================================================================
    PRESSING THE SKIP BUTTON  -  the one place a real click is needed
===============================================================================

    The end-of-match cutscene has a Skip button. Skipping it shortens the window
    where the server refuses to queue, so it is pressed automatically. The button
    is found by looking for a `GuiButton` inside `MainFrame.DuelInterfaces` whose
    `Title` reads "Skip".

    Unlike the loadout picker, there is no module field to write here, so this
    one really does click, with `VirtualInputManager`. That brings a coordinate
    trap worth knowing:

        cy = pos.Y + GuiService:GetGuiInset().Y + size.Y * 0.5

    `AbsolutePosition` is measured from below Roblox's 36-pixel top bar, but
    `SendMouseButtonEvent` wants true screen coordinates including it. Miss the
    inset and every click lands 36 pixels high - which usually still hits a big
    button and silently misses a small one, so it is a bug that looks like
    flakiness rather than an error.

    Being visible is also checked properly - not just `button.Visible`, but every
    ancestor up to the PlayerGui, because a visible button inside a hidden frame
    is not on screen and clicking where it would be hits whatever is.

===============================================================================
    WHAT IS LEFT OUT
===============================================================================

    The menu version also handles arcade modes, which live in separate places and
    need a teleport rather than a queue, and it registers a handler on the Play
    Again button as a fourth trigger. Neither is here: the teleport belongs to a
    different feature, and the three triggers above already cover everything Play
    Again would catch, just earlier. Set `ModeName` to a normal queue.

    REQUIREMENTS
    `VirtualInputManager` for the Skip press. Everything else works without it;
    if it is missing you just watch the cutscene.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Mode to queue into. Leave nil to use whatever the first available queue
    -- is. Accepts the game's internal queue name or its display name; run with
    -- `ListModes` on once to see what this server offers.
    ModeName = nil,

    -- Prints the available modes to the console on startup.
    ListModes = true,

    -- Press the cutscene Skip button.
    SkipCutscene = true,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local FIRE_DEBOUNCE = 1.5    -- seconds between queue attempts, any trigger
local RETRY_DELAY = 0.1      -- between rejected attempts
local RETRY_LIMIT = 150      -- ~15 seconds of trying
local SKIP_RETRY_DELAY = 0.25
local SKIP_GIVE_UP = 30

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Auto Queue", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AutoQueueCleanup then
    pcall(env.__AutoQueueCleanup)
end

local Token = {}
env.__AutoQueueToken = Token

local State = {
    Believed = "idle",
    LastFireAt = 0,
    MatchEndedConfirmed = false,
    RetryToken = 0,
    RetryAttempts = 0,
    SkipToken = 0,
    Modes = nil,          -- display name -> queue key
    Matchmaking = nil,
}

local Connections = {}

--=============================================================================
-- What modes exist on this server
--=============================================================================
-- Two sources, because neither is complete. The pads standing in the lobby
-- carry a `QueueName` attribute each, and the rotating-queue library knows the
-- ones that are only available right now.

local function resolveModes()
    if State.Modes then return State.Modes end

    local keys, seen = {}, {}
    local function add(key)
        if type(key) == "string" and key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(keys, key)
        end
    end

    local ok, pads = pcall(function() return CollectionService:GetTagged("QueuePad") end)
    if ok and type(pads) == "table" then
        for _, pad in ipairs(pads) do
            add(pad:GetAttribute("QueueName"))
        end
    end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local rotating = modules and modules:FindFirstChild("RotatingQueueLibrary")
    if rotating then
        local okRequire, library = pcall(require, rotating)
        if okRequire and type(library) == "table" and type(library.GetCurrent) == "function" then
            local okCurrent, current = pcall(function() return library:GetCurrent() end)
            if okCurrent and type(current) == "table" and type(current.QueueNames) == "table" then
                for _, name in ipairs(current.QueueNames) do add(name) end
            end
        end
    end

    if #keys == 0 then return nil end

    -- Both the internal key and the pretty name map to the same key, so the
    -- config accepts either.
    local queueInfo = modules and modules:FindFirstChild("QueueInfo")
    local info = nil
    if queueInfo then
        local okInfo, value = pcall(require, queueInfo)
        info = (okInfo and type(value) == "table") and value or nil
    end

    local modes = {}
    for _, key in ipairs(keys) do
        modes[key] = key
        local entry = info and info[key]
        if type(entry) == "table" and type(entry.DisplayName) == "string" and entry.DisplayName ~= "" then
            modes[entry.DisplayName] = key
        end
    end

    State.Modes = modes
    return modes
end

local function chosenQueueKey()
    local modes = resolveModes()
    if not modes then return nil end
    if CONFIG.ModeName then return modes[CONFIG.ModeName] end

    -- No preference: take one, deterministically, so repeated runs agree.
    local names = {}
    for name, key in pairs(modes) do
        if name == key then table.insert(names, key) end
    end
    table.sort(names)
    return names[1]
end

--=============================================================================
-- Are we allowed to queue right now
--=============================================================================

local function canFireQueue()
    -- Not in a running match at all.
    if Workspace:GetAttribute("MatchmadeStatus") ~= "Started" then return true end
    -- In one, but it is over.
    if Workspace:GetAttribute("MatchmadeGameOver") == true then return true end
    -- Or the duel told us first. See header.
    return State.MatchEndedConfirmed == true
end

local function matchmakingController()
    if State.Matchmaking then return State.Matchmaking end

    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("MatchmakingController")
    if not module then return nil end

    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return nil end

    State.Matchmaking = controller
    return controller
end

--=============================================================================
-- Queueing
--=============================================================================

local stopRetry, scheduleRetry, fireJoin

function stopRetry()
    State.RetryAttempts = 0
    State.RetryToken = State.RetryToken + 1
end

function scheduleRetry()
    if not CONFIG.Enabled or not canFireQueue() then return end
    if State.Believed ~= "idle" then return end
    if State.RetryAttempts >= RETRY_LIMIT then
        stopRetry()
        return
    end

    State.RetryAttempts = State.RetryAttempts + 1
    State.RetryToken = State.RetryToken + 1
    local token = State.RetryToken

    task.delay(RETRY_DELAY, function()
        if env.__AutoQueueToken ~= Token then return end
        if token ~= State.RetryToken then return end   -- superseded
        fireJoin()
    end)
end

function fireJoin()
    if not CONFIG.Enabled then return false, "disabled" end
    if not canFireQueue() then return false, "match_running" end
    if State.Believed ~= "idle" then return false, "already_" .. State.Believed end

    local queueKey = chosenQueueKey()
    if not queueKey then return false, "no_mode" end

    local now = tick()
    if now - State.LastFireAt < FIRE_DEBOUNCE then return false, "debounced" end
    State.LastFireAt = now

    local controller = matchmakingController()
    if controller and type(controller.QueueInto) == "function" then
        local ok, result = pcall(function() return controller:QueueInto(queueKey) end)
        if ok then
            -- A returned string is the server's refusal reason, not a success
            -- value. Empty/nil means it took.
            if type(result) == "string" and #result > 0 then
                State.Believed = "idle"
                scheduleRetry()
                return false, result
            end
            State.Believed = "queued"
            stopRetry()
            notify("queued for " .. queueKey)
            return true
        end
    end

    -- Older builds route through a RemoteFunction instead of the controller.
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local matchmaking = remotes and remotes:FindFirstChild("Matchmaking")
    local joinQueue = matchmaking and matchmaking:FindFirstChild("JoinQueue")
    if joinQueue and joinQueue:IsA("RemoteFunction") then
        local ok, result = pcall(function() return joinQueue:InvokeServer(queueKey) end)
        if ok and not (type(result) == "string" and #result > 0) then
            State.Believed = "queued"
            stopRetry()
            notify("queued for " .. queueKey)
            return true
        end
        scheduleRetry()
        return false, "rejected"
    end

    return false, "no_remote"
end

--=============================================================================
-- The Skip button
--=============================================================================

-- Visible means visible all the way up, not just on itself. See header.
local function isVisibleInTree(guiObject)
    if not guiObject or not guiObject:IsA("GuiObject") then return false end
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local current = guiObject
    while current and current ~= playerGui do
        if current:IsA("GuiObject") and current.Visible ~= true then return false end
        current = current.Parent
    end
    return current == playerGui
end

local function skipButton()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local mainGui = playerGui and playerGui:FindFirstChild("MainGui")
    local mainFrame = mainGui and mainGui:FindFirstChild("MainFrame")
    local duelInterfaces = mainFrame and mainFrame:FindFirstChild("DuelInterfaces")
    if not duelInterfaces then return nil end

    for _, descendant in ipairs(duelInterfaces:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            local title = descendant:FindFirstChild("Title")
            if title and title:IsA("TextLabel") and title.Text == "Skip" then
                return descendant
            end
            if descendant:IsA("TextButton") and descendant.Text == "Skip" then
                return descendant
            end
        end
    end
    return nil
end

local function pressSkip()
    local button = skipButton()
    if not button or not isVisibleInTree(button) then return false end

    local position, size = button.AbsolutePosition, button.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return false end

    local x = position.X + size.X * 0.5
    -- The inset. See header - this is the line people get wrong.
    local y = position.Y + GuiService:GetGuiInset().Y + size.Y * 0.5

    return (pcall(function()
        local vim = Instance.new("VirtualInputManager")
        vim:SendMouseButtonEvent(x, y, 0, true, button, 1)
        vim:SendMouseButtonEvent(x, y, 0, false, button, 1)
    end))
end

-- The button appears some time after the match ends, so this keeps looking
-- rather than checking once.
local function pressSkipWithRetry()
    if not CONFIG.SkipCutscene then return end

    State.SkipToken = State.SkipToken + 1
    local token = State.SkipToken
    local startedAt = tick()

    local function attempt()
        if env.__AutoQueueToken ~= Token then return end
        if token ~= State.SkipToken then return end
        if pressSkip() then return end
        if tick() - startedAt >= SKIP_GIVE_UP then return end
        task.delay(SKIP_RETRY_DELAY, attempt)
    end
    attempt()
end

--=============================================================================
-- Triggers
--=============================================================================

local function onMatchEnded()
    State.MatchEndedConfirmed = true
    if not CONFIG.Enabled then return end
    pressSkipWithRetry()
    State.Believed = "idle"
    fireJoin()
end

local function bindDuelController()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("DuelController")
    if not module then return false end

    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return false end

    -- Leaving the duel is the earliest "it's over" there is. See header.
    if controller.LocalPlayerLeftDuel and type(controller.LocalPlayerLeftDuel.Connect) == "function" then
        Connections.LeftDuel = controller.LocalPlayerLeftDuel:Connect(function()
            if env.__AutoQueueToken ~= Token then return end
            onMatchEnded()
        end)
    end

    -- And joining one means the previous end is old news.
    if controller.LocalPlayerJoinedDuel and type(controller.LocalPlayerJoinedDuel.Connect) == "function" then
        Connections.JoinedDuel = controller.LocalPlayerJoinedDuel:Connect(function()
            if env.__AutoQueueToken ~= Token then return end
            State.MatchEndedConfirmed = false
            State.Believed = "matched"
            stopRetry()
            State.SkipToken = State.SkipToken + 1   -- cancel any pending skip
        end)
    end

    return Connections.LeftDuel ~= nil or Connections.JoinedDuel ~= nil
end

Connections.GameOver = Workspace:GetAttributeChangedSignal("MatchmadeGameOver"):Connect(function()
    if env.__AutoQueueToken ~= Token then return end
    if Workspace:GetAttribute("MatchmadeGameOver") ~= true then return end
    State.Believed = "idle"
    fireJoin()
end)

Connections.Status = Workspace:GetAttributeChangedSignal("MatchmadeStatus"):Connect(function()
    if env.__AutoQueueToken ~= Token then return end
    -- Back out of "Started" means we are in the lobby again, whatever else
    -- happened, so anything we believed is stale.
    if Workspace:GetAttribute("MatchmadeStatus") == "Started" then return end
    State.Believed = "idle"
    State.MatchEndedConfirmed = false
    fireJoin()
end)

task.spawn(function()
    while env.__AutoQueueToken == Token do
        if bindDuelController() then break end
        task.wait(1)
    end

    if env.__AutoQueueToken ~= Token then return end

    if CONFIG.ListModes then
        local modes = resolveModes()
        if modes then
            local names = {}
            for name in pairs(modes) do table.insert(names, name) end
            table.sort(names)
            print("[Auto Queue] modes on this server: " .. table.concat(names, ", "))
        else
            print("[Auto Queue] no queues found - are you in the lobby?")
        end
    end

    notify("active")
    fireJoin()   -- if we are already sitting in the lobby, go now
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__AutoQueueCleanup = function()
    env.__AutoQueueToken = nil
    for _, connection in pairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    State.Modes = nil
    State.Matchmaking = nil
    env.__AutoQueueCleanup = nil
end
