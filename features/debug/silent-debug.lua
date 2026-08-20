--[[============================================================================
    SILENT AIM DEBUG  -  why didn't it take the shot?
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Draws a live panel showing everything the shoot-readiness check is looking
    at, and which of those things is currently stopping a shot. It changes
    nothing about the game - it only tells you what the game's state is.

    Run it, hold your fire key, and watch the list. Whatever is on it is what
    is in your way.

===============================================================================
    WHY THIS EXISTS, WHICH IS THE POINT OF THE FILE
===============================================================================

    "The aimbot isn't shooting" is a useless bug report, including to yourself.
    There are eleven separate conditions that can independently stop a shot,
    they are all invisible, and most of them are true for a fraction of a
    second at a time. Guessing which one it is means changing something,
    playing a round, and guessing again.

    So instead of guessing, the readiness check was written to explain itself.
    Every condition has a NAME, every condition that fires is added to a list,
    and the list is what comes back:

        reasons = { "shoot_cooldown", "burst_count" }

    Not `false`. `false` tells you it did not fire and nothing else. A list of
    names tells you exactly which gate to go and look at.

    And every one of those gates can be turned off individually, so you can
    bisect: disable them one at a time until the shot goes through, and the one
    you just disabled is the one that was wrong. Eleven checks, four rounds of
    bisection, done - versus an afternoon of guessing.

    THE GENERAL LESSON, and it applies to anything with more than about three
    conditions: make the decision produce a reason, not a boolean, and give
    each input its own switch. It costs you a table and an if per condition,
    and it turns "it doesn't work" into "it is this line".

===============================================================================
    A HARD BLOCK IS NOT THE SAME AS A REASON TO WAIT
===============================================================================

    Look at the difference between how `reload_cooldown` is treated and how
    everything else is.

    `reload_cooldown` sets `blockedReason` and returns IMMEDIATELY with
    `shouldAim = false`. It is a hard no - you are reloading, there is no shot
    to take, and none of the other conditions matter.

    Everything else adds to `reasons` and keeps going. Those are notes about
    why we are waiting, and the check collects all of them rather than stopping
    at the first, because when you are debugging you want the whole picture and
    not just the first thing that happened to be checked.

    Two categories, deliberately handled differently: conditions that END the
    decision, and conditions that DESCRIBE it. Collapsing them into one list
    loses the distinction; collapsing them into one boolean loses everything.

    Note also that when nothing at all fired, the list does not stay empty:

        if #reasons == 0 then
            reasons[1] = shootInputHeld and "held_input" or "keybind"
        end

    A shot that WAS allowed still says why. An empty list would be ambiguous
    between "allowed" and "the diagnostic is broken", and those look identical
    on screen at exactly the moment you cannot afford them to.

===============================================================================
    THE THREE KINDS OF SIGNAL
===============================================================================

    They read differently and it is worth knowing which is which.

    COUNTDOWNS are stored as an absolute deadline, not a remaining time:

        remaining = math.max(item._shoot_cooldown - tick(), 0)

    One number written once when the shot happens, rather than a value that has
    to be decremented every frame. Every cooldown in every game should be
    stored this way - a deadline is correct whether or not anything ran while
    it was counting down.

    FLAGS are just booleans on the item: `_is_charging`, `_is_using`,
    `_is_throwing`, `_is_input_queueing`. Read and report.

    RECENCY signals are the awkward ones - "did a shot happen in the last
    `holdWindow` seconds". There is no value to poll for that, so a timestamp
    has to be recorded at the moment it happens and compared later:

        if lastShot > state.LastShot then state.LastShotChangedAt = tick() end
        ...
        recent = (now - state.LastShotChangedAt) <= holdWindow

    Note what that first line is doing: `_last_shot` is a counter, and the
    thing being detected is that it CHANGED. Watching a value for change and
    stamping the time is how you turn "a thing happened" into something you can
    ask about later, when the only evidence is that a number is now different.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Every signal the readiness check consults. Set one to false to take it
    -- out of the decision - that is the bisection tool. See the header.
    Signals = {
        ReloadCooldown  = true,   -- hard block
        ShootCooldown   = true,
        LastShot        = true,
        BurstCount      = true,
        QueuePending    = true,
        InputSpamming   = true,   -- cancels QueuePending when set
        ShootBurstInfo  = true,
        ShotSignal      = true,
        ProjectileShot  = true,
        IsUsing         = true,
        IsThrowing      = true,
        IsCharging      = true,
    },

    -- How long a "this happened recently" signal stays true, in seconds.
    HoldWindow = 0.15,

    Position = UDim2.new(0, 12, 0, 120),
    TextSize = 14,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.__SilentDebugCleanup then
    pcall(env.__SilentDebugCleanup)
end

local Token = {}
env.__SilentDebugToken = Token

local State = {
    LastShot = nil,
    LastShotChangedAt = 0,
    ShotSignalAt = 0,
    ProjectileShotAt = 0,
    FighterController = nil,
}

--=============================================================================
-- Reading the equipped item
--=============================================================================

local function fighterController()
    if State.FighterController then return State.FighterController end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("FighterController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    State.FighterController = (ok and type(controller) == "table") and controller or nil
    return State.FighterController
end

local function equippedItem()
    local controller = fighterController()
    if not controller then return nil end
    local fighter = rawget(controller, "LocalFighter")
    if fighter == nil and type(controller.GetFighter) == "function" then
        local ok, result = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and result or nil
    end
    return type(fighter) == "table" and rawget(fighter, "EquippedItem") or nil
end

-- Cooldowns are stored as a deadline, so "remaining" is a subtraction. See
-- the header - this is the right way round.
local function remainingOn(item, field)
    local deadline = item and rawget(item, field)
    if type(deadline) == "number" then
        return math.max(deadline - tick(), 0)
    end
    return 0
end

--=============================================================================
-- The readiness check
--=============================================================================

local function evaluate(item, shootInputHeld)
    if not item then
        return { shouldAim = false, blockedReason = "no_item", reasons = {} }
    end

    -- Recency: watch the counter for a change and stamp when it moved. See
    -- the header.
    local lastShot = rawget(item, "_last_shot")
    if type(lastShot) == "number" and type(State.LastShot) == "number"
        and lastShot > State.LastShot then
        State.LastShotChangedAt = tick()
    end
    State.LastShot = lastShot

    local signals = CONFIG.Signals
    local info = rawget(item, "Info")
    local shootRemaining = remainingOn(item, "_shoot_cooldown")
    local reloadRemaining = remainingOn(item, "_reload_cooldown")
    local burstCount = type(rawget(item, "_burst_count")) == "number"
        and rawget(item, "_burst_count") or 0
    local queuePending = rawget(item, "_is_input_queueing") == true
    local isCharging = rawget(item, "_is_charging") == true
    local inputSpammingFlag = type(info) == "table" and info.InputSpammingEnabled
        and info.InputSpammingEnabled.StartShooting or nil
    local holdWindow = CONFIG.HoldWindow
    local now = tick()

    local reasons = {}

    -- HARD BLOCK. Returns immediately; nothing else is worth evaluating while
    -- you are mid-reload. See the header for why this one is different.
    if signals.ReloadCooldown and shootInputHeld and reloadRemaining > 0 and not isCharging then
        return {
            shouldAim = false,
            blockedReason = "reload_cooldown",
            reasons = reasons,
            shootRemaining = shootRemaining,
            reloadRemaining = reloadRemaining,
            burstCount = burstCount,
            queuePending = queuePending,
            isCharging = isCharging,
            holdWindow = holdWindow,
        }
    end

    -- Everything below DESCRIBES rather than decides, so all of them are
    -- collected rather than stopping at the first.
    if signals.IsCharging and isCharging then
        reasons[#reasons + 1] = "is_charging"
    end
    if signals.ShootCooldown and shootRemaining > 0 then
        reasons[#reasons + 1] = "shoot_cooldown"
    end
    if signals.LastShot and holdWindow > 0 and State.LastShotChangedAt > 0
        and (now - State.LastShotChangedAt) <= holdWindow then
        reasons[#reasons + 1] = "last_shot"
    end
    if signals.BurstCount and burstCount > 0 then
        reasons[#reasons + 1] = "burst_count"
    end
    -- Note the second half: a weapon that allows input spamming is expected to
    -- have a queued input, so that stops being a reason to wait.
    if signals.QueuePending and queuePending
        and not (signals.InputSpamming and inputSpammingFlag) then
        reasons[#reasons + 1] = "queue_pending"
    end
    if signals.ShootBurstInfo and type(info) == "table"
        and type(info.ShootBurst) == "number" and info.ShootBurst > 1 and burstCount > 0 then
        reasons[#reasons + 1] = "shoot_burst_info"
    end
    if signals.ShotSignal and holdWindow > 0 and State.ShotSignalAt > 0
        and (now - State.ShotSignalAt) <= holdWindow then
        reasons[#reasons + 1] = "shot_signal"
    end
    if signals.ProjectileShot and holdWindow > 0 and State.ProjectileShotAt > 0
        and (now - State.ProjectileShotAt) <= holdWindow then
        reasons[#reasons + 1] = "projectile_signal"
    end
    if signals.IsUsing and rawget(item, "_is_using") then
        reasons[#reasons + 1] = "is_using"
    end
    if signals.IsThrowing and rawget(item, "_is_throwing") then
        reasons[#reasons + 1] = "is_throwing"
    end

    -- An allowed shot still says why. See the header - an empty list would be
    -- ambiguous with a broken diagnostic.
    if #reasons == 0 then
        reasons[1] = shootInputHeld and "held_input" or "keybind"
    end

    return {
        shouldAim = true,
        blockedReason = nil,
        reasons = reasons,
        shootRemaining = shootRemaining,
        reloadRemaining = reloadRemaining,
        burstCount = burstCount,
        queuePending = queuePending,
        isCharging = isCharging,
        holdWindow = holdWindow,
        aimScopePercent = type(info) == "table" and info.AimScopePercent or nil,
    }
end

--=============================================================================
-- The panel
--=============================================================================
-- Deliberately a ScreenGui rather than the Drawing API: this is a developer
-- tool, it wants to be readable and selectable rather than invisible to
-- screenshots, and it should work on executors with no Drawing support at all.

local gui = Instance.new("ScreenGui")
gui.Name = "KiciaHookSilentDebug"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if gui.Parent == nil then
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local label = Instance.new("TextLabel")
label.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
label.BackgroundTransparency = 0.25
label.BorderSizePixel = 0
label.Position = CONFIG.Position
label.Size = UDim2.new(0, 300, 0, 200)
label.AutomaticSize = Enum.AutomaticSize.XY
label.Font = Enum.Font.Code
label.TextSize = CONFIG.TextSize
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.TextColor3 = Color3.fromRGB(220, 220, 225)
label.Text = ""
label.Parent = gui

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 8)
padding.PaddingBottom = UDim.new(0, 8)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.Parent = label

local function format(result, item)
    if not item then
        return "SILENT DEBUG\n\nno item equipped"
    end

    local lines = { "SILENT DEBUG" }
    lines[#lines + 1] = ""

    if result.blockedReason then
        lines[#lines + 1] = "BLOCKED: " .. result.blockedReason
    else
        lines[#lines + 1] = "would shoot: " .. tostring(result.shouldAim)
    end
    lines[#lines + 1] = "reasons: " .. (#result.reasons > 0
        and table.concat(result.reasons, ", ") or "(none)")
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("shoot cooldown   %.3f"):format(result.shootRemaining or 0)
    lines[#lines + 1] = ("reload cooldown  %.3f"):format(result.reloadRemaining or 0)
    lines[#lines + 1] = ("burst count      %d"):format(result.burstCount or 0)
    lines[#lines + 1] = "queue pending    " .. tostring(result.queuePending)
    lines[#lines + 1] = "is charging      " .. tostring(result.isCharging)
    if result.aimScopePercent then
        lines[#lines + 1] = ("aim scope %%      %.2f"):format(result.aimScopePercent)
    end

    return table.concat(lines, "\n")
end

--=============================================================================
-- The loop
--=============================================================================

local connection
connection = RunService.RenderStepped:Connect(function()
    if env.__SilentDebugToken ~= Token then
        connection:Disconnect()
        return
    end

    label.Visible = CONFIG.Enabled
    if not CONFIG.Enabled then return end

    local ok, err = pcall(function()
        local item = equippedItem()
        local held = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        local result = evaluate(item, held)
        label.Text = format(result, item)
        -- Red while something is stopping the shot, green while it is not.
        label.TextColor3 = result.blockedReason and Color3.fromRGB(255, 120, 120)
            or (result.shouldAim and Color3.fromRGB(150, 235, 160)
                or Color3.fromRGB(220, 220, 225))
    end)
    if not ok then
        label.Text = "SILENT DEBUG\n\nerror: " .. tostring(err)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__SilentDebugCleanup = function()
    env.__SilentDebugToken = nil
    if connection then connection:Disconnect() end
    pcall(function() gui:Destroy() end)
    env.__SilentDebugCleanup = nil
end