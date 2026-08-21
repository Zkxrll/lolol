--[[============================================================================
    CLAIM ALL REWARDS  -  empty your daily, battle pass and capsule backlog
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Claims everything the game is currently holding for you, in one go:

        DAILY       the like / favourite / notifications rewards
        BATTLE PASS every unclaimed tier on every track up to your level
        CAPSULES    opens the whole unclaimed-rewards backlog, one at a time

    Every one of these is a button that exists in the game's own menus. This
    presses all of them, in order, without you having to click through three
    screens and ninety capsule animations.

===============================================================================
    THREE REWARD SYSTEMS, THREE DIFFERENT SHAPES
===============================================================================

    They look like one feature from the menu and they are nothing alike
    underneath.

    DAILY is a flat list with a boolean each:

        pdc:Get("ClaimedLikeReward")   -> true/false
        Remotes.Data.ClaimLikeReward:FireServer()

    BATTLE PASS is a two-dimensional grid - tiers down, tracks across (free and
    paid) - and the claimed state is a nested table keyed by STRINGS:

        rewardsClaimed[tostring(tier)][tostring(track)]

    Note the `tostring`. The data came back through a JSON-shaped path, and in
    JSON every object key is a string, so `[1]` and `["1"]` are different keys
    and only one of them exists. Getting this wrong gives you a claim loop that
    thinks nothing is claimed and re-fires everything, every time.

    CAPSULES are a QUEUE. There is no list of what to claim - there is a stack
    of unclaimed items, and you open the one on top repeatedly until there is
    nothing left.

===============================================================================
    "EMPTY" IS NOT "DONE"
===============================================================================

    The obvious capsule loop is: while the list is not empty, open the first
    thing. It leaves items behind, reliably, and looks like it worked.

    The reason is that opening a capsule can PRODUCE unclaimed rewards - a
    capsule containing a smaller capsule, an item that spawns a claim - and
    those arrive by replication a moment later. Read the list in that moment
    and it is empty. It is not empty because you finished; it is empty because
    the next batch has not landed yet.

        if list is empty then
            emptyStreak = emptyStreak + 1
            if emptyStreak >= 3 then break end     -- three in a row, spaced out
            task.wait(0.6)
        else
            emptyStreak = 0
            ...open one...
        end

    Three consecutive empty reads, 0.6 seconds apart, before believing it. Any
    single non-empty read resets the count to zero.

    THE GENERAL RULE: when a collection
    is filled asynchronously, emptiness is a statement about right now and not
    about the future. If you are waiting for something to finish, wait for it
    to STAY finished. This same shape - confirm N times before believing a
    negative - is worth reaching for whenever "done" and "not started yet" look
    identical from the outside.

===============================================================================
    TWO COUNTERS DOING OPPOSITE JOBS
===============================================================================

    Right next to `emptyStreak` is `failureStreak`, and they are mirror images.

        emptyStreak    counts up to decide when to STOP SUCCESSFULLY
        failureStreak  counts up to decide when to GIVE UP

    The server can refuse an open - rate limiting, a transient error, an item
    that is in a bad state. One refusal means nothing. Five in a row means it
    is not going to work and spinning here forever helps nobody.

    Both reset on the opposite outcome, so a single hiccup in the middle of a
    hundred capsules does not abort the run, and a single successful open in a
    stream of failures does not hide the fact that it is stuck.

    And wrapped around both, a hard cap:

        for _ = 1, 400 do

    Three layers of "this will terminate": the success condition, the failure
    condition, and a backstop above both in case a bug means neither triggers.
    Any loop whose length is decided by a remote server wants all three.

===============================================================================
    REMOTEEVENT VERSUS REMOTEFUNCTION
===============================================================================

    Worth pointing out because this file uses both, three lines apart.

        remote:FireServer(...)             -- RemoteEvent: send and move on
        remote:InvokeServer(...)           -- RemoteFunction: send and WAIT

    `FireServer` returns immediately and tells you nothing. You cannot know
    whether the daily reward was actually granted; you fire it and hope. That
    is why the daily section checks the flag BEFORE firing rather than
    verifying afterwards - checking first is the only check available.

    `InvokeServer` yields until the server answers, and here it answers with
    the string `"Success"`. That is why the capsule loop can count failures at
    all, and why it is the only one of the three that can be sure it worked.

    The trade is that `InvokeServer` blocks your thread until the server
    replies, or forever if it never does - which is why this whole thing runs
    inside `task.spawn` rather than on the frame loop.

===============================================================================
    THE SMALL DECENCIES
===============================================================================

    CHECK BEFORE FIRING. Every one of the three sections reads the already-
    claimed state first. Re-claiming something is at best wasted traffic, and
    at worst it burns your rate limit on requests that were always going to be
    rejected, so the ones that would have worked get refused too.

    DELAY BETWEEN CLAIMS. `task.wait(0.35)` after each. Firing ninety remotes
    in one frame is the single most reliable way to be rate-limited, and there
    is nothing to gain - you are already saving several minutes of clicking.

    NOT DURING A MATCH. Capsule opening is skipped while you are in a duel or
    the shooting range. It plays animations and takes seconds, and doing it
    mid-fight gets you killed. That is a gameplay reason rather than a code
    reason and it is still the right call.

    READ THE LIMIT FROM THE GAME. The maximum quantity per open comes from the
    game's own `CONSTANTS.MAX_BACKPACK_USE_QUANTITY`, with 99 only as a
    fallback. Hardcoding a limit somebody else owns means silently breaking
    the day they change it.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    -- Run as soon as this file executes. Set false and call
    -- getgenv().ClaimAllRewards() yourself instead.
    RunImmediately = true,

    ClaimDaily = true,
    ClaimBattlePass = true,
    OpenCapsules = true,

    Notify = true,
}

-- Pacing. See the header - these exist so the server does not start refusing.
local CLAIM_DELAY = 0.35
local SETTLE_DELAY = 0.6
local EMPTY_CONFIRMATIONS = 3
local MAX_FAILURE_STREAK = 5
local MAX_ITERATIONS = 400

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Claim All", Text = text, Duration = 6,
        })
    end)
end

local env = (getgenv and getgenv()) or _G

--=============================================================================
-- The game's own pieces
--=============================================================================

local PlayerDataControllerCache = nil

local function playerDataController()
    if PlayerDataControllerCache then return PlayerDataControllerCache end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("PlayerDataController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    PlayerDataControllerCache = (ok and type(controller) == "table") and controller or nil
    return PlayerDataControllerCache
end

-- CurrentData being present is the practical "your save has arrived" signal.
-- Claiming before it does asks the server for things you cannot see yet.
local function dataReady()
    local pdc = playerDataController()
    return pdc ~= nil and rawget(pdc, "CurrentData") ~= nil
end

local function dataRemote(name, expectedClass)
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local dataFolder = remotes and remotes:FindFirstChild("Data")
    local remote = dataFolder and dataFolder:FindFirstChild(name)
    -- Check the class. A RemoteEvent where you expected a RemoteFunction
    -- fails with a confusing error rather than a clear nil.
    if remote and remote:IsA(expectedClass or "RemoteEvent") then
        return remote
    end
    return nil
end

local function requireModule(name)
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local module = modules and modules:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    return (ok and type(result) == "table") and result or nil
end

local function inMatch()
    -- Best-effort: the fighter's own data says whether you are in a duel.
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("DuelController")
    if not module then return false end
    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return false end
    return rawget(controller, "CurrentObject") ~= nil
end

--=============================================================================
-- Daily rewards
--=============================================================================

local DAILY_REWARDS = {
    { remote = "ClaimLikeReward",          flag = "ClaimedLikeReward" },
    { remote = "ClaimFavoriteReward",      flag = "ClaimedFavoriteReward" },
    { remote = "ClaimNotificationsReward", flag = "ClaimedNotificationsReward" },
}

local function claimDaily(pdc)
    local claimed, skipped = 0, 0

    for _, info in ipairs(DAILY_REWARDS) do
        -- Check first. FireServer tells us nothing afterwards, so this is the
        -- only check there is. See the header.
        if pdc:Get(info.flag) then
            skipped = skipped + 1
        else
            local remote = dataRemote(info.remote, "RemoteEvent")
            if remote and pcall(remote.FireServer, remote) then
                claimed = claimed + 1
                task.wait(CLAIM_DELAY)
            end
        end
    end

    return claimed, skipped
end

--=============================================================================
-- Battle pass
--=============================================================================

local function claimBattlePass(pdc)
    local remote = dataRemote("ClaimBattlePassReward", "RemoteEvent")
    if not remote then return 0, "no remote" end

    local seasonLibrary = requireModule("SeasonLibrary")
    local currentSeason = seasonLibrary and seasonLibrary.CurrentSeason or nil
    if type(currentSeason) ~= "table" then return 0, "no season data" end
    if not currentSeason.BattlePassActive then return 0, "pass not active" end

    local seasons = pdc:Get("Seasons")
    local seasonData = type(seasons) == "table" and currentSeason.Name
        and seasons[currentSeason.Name] or nil
    local battlePass = type(seasonData) == "table" and seasonData.BattlePass or nil
    if type(battlePass) ~= "table" then return 0, "no progress this season" end

    local passLevel = tonumber(battlePass.PassLevel) or 0
    local maxTrack = tonumber(battlePass.MaxPassTrackNum) or 0
    local rewardsClaimed = type(battlePass.RewardsClaimed) == "table"
        and battlePass.RewardsClaimed or {}
    local catalog = type(currentSeason.BattlePassRewards) == "table"
        and currentSeason.BattlePassRewards or {}

    local claimed = 0

    -- Tiers down, tracks across. Only up to the level you have actually
    -- reached - asking for tiers above it is refused anyway.
    for tier = 1, passLevel do
        local tierCatalog = catalog[tier]
        if type(tierCatalog) == "table" then
            -- STRING keys. See the header; this is the detail that catches
            -- people, and it fails silently by re-claiming everything.
            local claimedTier = rewardsClaimed[tostring(tier)]
            for track = 1, maxTrack do
                -- A tier does not necessarily have a reward on every track.
                if tierCatalog[track] ~= nil then
                    local already = type(claimedTier) == "table" and claimedTier[tostring(track)]
                    if not already and pcall(remote.FireServer, remote, tier, track) then
                        claimed = claimed + 1
                        task.wait(CLAIM_DELAY)
                    end
                end
            end
        end
    end

    return claimed, nil
end

--=============================================================================
-- Capsules
--=============================================================================

local function openCapsules(pdc)
    if inMatch() then return 0, "skipped - in a match" end

    local remote = dataRemote("UseUnclaimedReward", "RemoteFunction")
    if not remote then return 0, "no remote" end

    -- The game owns this number, so read it rather than assuming it.
    local constants = requireModule("CONSTANTS")
    local maxQuantity = (constants and tonumber(constants.MAX_BACKPACK_USE_QUANTITY)) or 99

    local opened = 0
    local emptyStreak = 0
    local failureStreak = 0

    -- Backstop. Neither of the two conditions below should fail to trigger,
    -- and this is here for the day one of them does.
    for _ = 1, MAX_ITERATIONS do
        local rewards = pdc:Get("UnclaimedRewards")

        if type(rewards) ~= "table" or rewards[1] == nil then
            -- Empty right now is not the same as finished. See the header.
            emptyStreak = emptyStreak + 1
            if emptyStreak >= EMPTY_CONFIRMATIONS then break end
            task.wait(SETTLE_DELAY)
        else
            emptyStreak = 0

            local entry = rewards[1]
            local quantity = type(entry) == "table" and tonumber(entry.Quantity) or 1
            if not quantity or quantity < 1 then quantity = 1 end

            -- InvokeServer WAITS and answers. That answer is the only reason
            -- this loop can tell success from failure at all.
            local ok, result = pcall(remote.InvokeServer, remote, 1, math.min(quantity, maxQuantity))
            if ok and result == "Success" then
                opened = opened + 1
                failureStreak = 0
            else
                -- One refusal is noise. Five in a row is a wall.
                failureStreak = failureStreak + 1
                if failureStreak >= MAX_FAILURE_STREAK then break end
            end

            task.wait(CLAIM_DELAY)
        end
    end

    return opened, nil
end

--=============================================================================
-- Doing all three
--=============================================================================

local function claimAll()
    local pdc = playerDataController()
    if not pdc or not dataReady() then
        notify("Player data not ready yet, try again in a moment.")
        return
    end

    local parts = {}

    if CONFIG.ClaimDaily then
        local claimed, skipped = claimDaily(pdc)
        table.insert(parts, ("daily: %d claimed, %d already done"):format(claimed, skipped))
    end

    if CONFIG.ClaimBattlePass then
        local claimed, reason = claimBattlePass(pdc)
        table.insert(parts, reason and ("pass: " .. reason)
            or ("pass: %d claimed"):format(claimed))
    end

    if CONFIG.OpenCapsules then
        local opened, reason = openCapsules(pdc)
        table.insert(parts, reason and ("capsules: " .. reason)
            or ("capsules: %d opened"):format(opened))
    end

    notify(table.concat(parts, "\n"))
end

-- Exposed so it can be run again without re-executing the file. All three
-- sections yield, so this always runs on its own thread.
env.ClaimAllRewards = function()
    task.spawn(function()
        local ok, err = pcall(claimAll)
        if not ok then
            warn("[Claim All] " .. tostring(err))
            notify("failed: " .. tostring(err))
        end
    end)
end

if CONFIG.RunImmediately then
    env.ClaimAllRewards()
end

--=============================================================================
-- Cleanup
--=============================================================================
-- Nothing to clean up: this changes nothing, connects to nothing and leaves no
-- loop running. It sends some requests and stops.

env.__ClaimAllRewardsCleanup = function()
    env.ClaimAllRewards = nil
    env.__ClaimAllRewardsCleanup = nil
end