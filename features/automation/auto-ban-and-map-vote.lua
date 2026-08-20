--[[============================================================================
    AUTO BAN + AUTO MAP VOTE  -  pick for you in the pre-match vote
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Duels open with a voting phase. Depending on the mode you either ban weapons
    you don't want to face, or vote for a map. This watches that phase and
    submits your choices from a list you write once, so you never have to click
    through it.

    Two independent halves, both configurable below:

        BanWeapons   ban from your list when the window is a weapon-ban window
        VoteMaps     pick from your list when the window is a map window

===============================================================================
    NOTHING IS POLLED
===============================================================================

    A vote window opens, lasts a few seconds, and closes. The lazy way to catch
    it is to check every frame forever. This does not: the duel object hands out
    change signals, so the whole feature sits idle until the game itself says
    something changed.

        duel:GetDataChangedSignal("VoteOptionsType")     ban round vs map round
        duel:GetDataChangedSignal("VoteOptions")         what is on offer
        duel:GetDataChangedSignal("VoteBansRemaining")   how many bans are left
        duel:GetDataChangedSignal("MaxWeaponBansPerTeam")
        duel:GetDataChangedSignal("MaxMapBansPerTeam")

    All five run the same handler, which works out from scratch whether there is
    anything to do. That is the pattern worth copying: rather than write five
    handlers that each know what changed, write one that re-reads the world and
    decides. It cannot get out of step with itself, and adding a sixth trigger
    later costs one line.

    Which duel to watch comes from the controller's own events:

        DuelController.LocalPlayerJoinedDuel  ->  rebind to the new duel
        DuelController.LocalPlayerLeftDuel    ->  unbind

===============================================================================
    THE TRAP: DON'T DEDUPLICATE WITH THE SERVER'S VALUE
===============================================================================

    The handler runs many times per window, so it has to know whether it has
    already voted. There is an obvious way to check - the duel replicates your
    last vote, so read that and skip if it is set.

    That is wrong, and it fails in a way you will not notice for a while: the
    server's copy of your last vote persists ACROSS windows. Once you have voted
    for a map in one round, that value is still sitting there in the next round,
    so the check says "already voted" forever and the feature quietly stops
    working after the first duel of the session.

    So the memory is local instead - `LastSubmitted`, wiped whenever
    `VoteOptionsType` changes, which is exactly when a new window opens. There
    is one deliberate exception, and it is doing real work:

        already voted, AND our pick is now banned  ->  vote again

    In a two-round ban phase the type does not change between rounds; what
    changes is that our first pick got banned out from under us. Treating "my
    submission is banned" as "the window moved on" is how round two gets
    handled without needing an event for it.

    General shape: when you need to know "have I already acted", prefer a fact
    you own over a fact the server owns. Server state was written for the
    server's purposes and its lifetime is not yours to assume.

===============================================================================
    TWO MORE THINGS THAT ARE NOT OBVIOUS
===============================================================================

    WHICH BAN LIST, ROUND ONE OR ROUND TWO
    Nothing announces the round number. But bans-remaining counts down, so it is
    the round number in disguise: 2 left means round one, 1 left means round
    two. That is why there are two lists below and why the second is only ever
    used when one ban remains.

    RANKED BANS vs CASUAL PICKS
    Both arrive as map windows and look identical from here. The difference is
    that a ranked ban window replicates `MaxMapBansPerTeam` and a casual pick
    window does not carry it at all. So the bans-remaining gate is only applied
    when that field exists - apply it unconditionally and every casual map vote
    is blocked, because bans-remaining computes to zero for a phase that has no
    bans in it.

    An absent field is information. It is worth checking whether something is
    missing before deciding a rule applies to it.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- === Weapon bans ==========================================================
    BanWeapons = true,

    -- Round one: banned when two bans remain. Round two: when one remains.
    -- First name that is on offer and not already banned wins, so order them
    -- most-hated first. Names are matched loosely (case and spacing ignored).
    FirstBans  = { "Shotgun", "Sniper" },
    SecondBans = { "Rocket Launcher", "Minigun" },

    -- === Map vote =============================================================
    VoteMaps = true,

    MapPicks = { "Skyline", "Sandstorm" },

    Notify = true,
}

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
            Title = "Auto Vote", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AutoVoteCleanup then
    pcall(env.__AutoVoteCleanup)
end

local Token = {}
env.__AutoVoteToken = Token

--=============================================================================
-- State
--=============================================================================

local State = {
    Controller = nil,
    BoundDuel = nil,
    LastVoteType = nil,     -- which window we are in
    LastSubmitted = nil,    -- what we sent this window. See header.
}

-- Named so a rebind can drop just the per-duel ones.
local Connections = {}

local function disconnect(names)
    for _, name in ipairs(names) do
        local connection = Connections[name]
        if connection then
            pcall(function() connection:Disconnect() end)
            Connections[name] = nil
        end
    end
end

local DUEL_KEYS = {
    "VoteOptionsType", "VoteOptions", "VoteBansRemaining",
    "MaxWeaponBansPerTeam", "MaxMapBansPerTeam",
}

--=============================================================================
-- Reading the duel
--=============================================================================
-- The duel is a replicated object, and depending on the game's build a field is
-- reached either through a `Get` method or as a plain key. Try the method, fall
-- back to the index - costs nothing and survives both shapes.

local function read(object, key)
    if not object then return nil end
    if type(object.Get) == "function" then
        local ok, value = pcall(object.Get, object, key)
        if ok then return value end
    end
    return object[key]
end

local function resolveController()
    if State.Controller then return State.Controller end

    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("DuelController")
    if not module then return nil end

    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return nil end

    State.Controller = controller
    return controller
end

-- Only duelers may vote; the game's own slots render disabled for anyone else.
-- Checking it also keeps us quiet during the lobby pods' ambient votes.
local function localDueler(duel)
    if type(duel.GetDueler) ~= "function" then return nil end
    local ok, dueler = pcall(duel.GetDueler, duel, LocalPlayer)
    if ok and dueler then return dueler end
    ok, dueler = pcall(duel.GetDueler, duel, LocalPlayer.UserId)
    return ok and dueler or nil
end

local function bansRemaining(duel, voteType)
    local teamId = read(localDueler(duel), "TeamID")
    if teamId == nil then return 0 end

    local maxKey = (voteType == "Weapons") and "MaxWeaponBansPerTeam" or "MaxMapBansPerTeam"
    local maxBans = tonumber(read(duel, maxKey)) or 0
    local byTeam = read(duel, "VoteBansRemaining")
    local used = (type(byTeam) == "table") and tonumber(byTeam[teamId]) or 0
    return maxBans - used
end

local function isOptionBanned(voteOptions, optionName)
    if type(voteOptions) ~= "table" or optionName == nil then return false end
    for _, option in pairs(voteOptions) do
        if read(option, "Name") == optionName then
            -- Not a boolean: the field holds who banned it, so "set" is the
            -- test, not "true".
            return read(option, "IsBanned") ~= nil
        end
    end
    return false
end

--=============================================================================
-- Matching your list against what is on offer
--=============================================================================
-- Loose on purpose. The menu version picks from dropdowns so the names are
-- always exact; here you type them, so case and spacing are ignored.

local function normalise(name)
    return (tostring(name):lower():gsub("%s+", ""))
end

local function isSelected(list, name)
    if type(list) ~= "table" or name == nil then return false end
    local wanted = normalise(name)
    for _, entry in ipairs(list) do
        if normalise(entry) == wanted then return true end
    end
    return false
end

--=============================================================================
-- The handler - re-reads everything and decides
--=============================================================================

local function tryVote()
    if not CONFIG.Enabled then return false, "disabled" end
    if not CONFIG.BanWeapons and not CONFIG.VoteMaps then return false, "disabled" end

    local controller = resolveController()
    local duel = State.BoundDuel or (controller and controller.CurrentObject)
    if not duel then
        State.LastVoteType = nil
        State.LastSubmitted = nil
        return false, "no_duel"
    end

    -- New window: forget what we sent in the last one.
    local voteType = read(duel, "VoteOptionsType")
    if voteType ~= State.LastVoteType then
        State.LastVoteType = voteType
        State.LastSubmitted = nil
    end
    if voteType == nil then return false, "no_vote" end

    local voteOptions = read(duel, "VoteOptions")
    if type(voteOptions) ~= "table" or next(voteOptions) == nil then
        return false, "no_vote"
    end

    -- Already voted, and our pick still stands -> nothing to do. If it has been
    -- banned since, fall through and vote again. See header.
    if State.LastSubmitted ~= nil and not isOptionBanned(voteOptions, State.LastSubmitted) then
        return false, "already_voted"
    end

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local duels = remotes and remotes:FindFirstChild("Duels")
    local voteRemote = duels and duels:FindFirstChild("Vote")
    if not voteRemote or not voteRemote:IsA("RemoteEvent") then
        return false, "no_vote_remote"
    end

    -- Shared by both halves: first option that is on offer, not already banned,
    -- and on the given list.
    local function submitFirstMatch(list)
        for _, option in pairs(voteOptions) do
            local name = read(option, "Name")
            if name and read(option, "IsBanned") == nil and isSelected(list, name) then
                State.LastSubmitted = name
                local ok, err = pcall(voteRemote.FireServer, voteRemote, name)
                if not ok then
                    State.LastSubmitted = nil   -- it never left; don't remember it
                    return false, tostring(err)
                end
                notify("submitted " .. name)
                return true
            end
        end
        return false, "no_match"
    end

    if voteType == "Maps" then
        if not CONFIG.VoteMaps then return false, "map_vote_disabled" end
        if not localDueler(duel) then return false, "not_dueler" end

        -- Ranked ban window: gated. Casual pick window: no such field, no gate.
        -- See header - applying this unconditionally breaks casual entirely.
        if read(duel, "MaxMapBansPerTeam") ~= nil and bansRemaining(duel, "Maps") <= 0 then
            return false, "bans_complete"
        end

        return submitFirstMatch(CONFIG.MapPicks)
    end

    if voteType ~= "Weapons" or not CONFIG.BanWeapons then
        return false, "no_weapon_vote"
    end

    local remaining = bansRemaining(duel, "Weapons")
    if remaining <= 0 then return false, "bans_complete" end

    -- Bans remaining IS the round number. 2 left -> first list, 1 left ->
    -- second. See header.
    local lists = { CONFIG.FirstBans, CONFIG.SecondBans }
    local list = lists[#lists - remaining + 1]
    if not list then return false, "no_ban_list" end

    return submitFirstMatch(list)
end

--=============================================================================
-- Binding
--=============================================================================

local function bindDuel(duel)
    local perDuel = {}
    for _, key in ipairs(DUEL_KEYS) do
        table.insert(perDuel, "Duel_" .. key)
    end
    disconnect(perDuel)

    State.BoundDuel = duel
    State.LastVoteType = nil
    State.LastSubmitted = nil

    if not duel or type(duel.GetDataChangedSignal) ~= "function" then return end

    for _, key in ipairs(DUEL_KEYS) do
        local ok, signal = pcall(duel.GetDataChangedSignal, duel, key)
        if ok and signal and type(signal.Connect) == "function" then
            Connections["Duel_" .. key] = signal:Connect(function()
                if env.__AutoVoteToken ~= Token then return end
                pcall(tryVote)
            end)
        end
    end

    -- The window may already be open by the time we bound to it.
    pcall(tryVote)
end

local function registerSignals()
    local controller = resolveController()
    if not controller then return false end

    if controller.LocalPlayerJoinedDuel and type(controller.LocalPlayerJoinedDuel.Connect) == "function" then
        Connections.JoinedDuel = controller.LocalPlayerJoinedDuel:Connect(function(duel)
            if env.__AutoVoteToken ~= Token then return end
            bindDuel(duel or controller.CurrentObject)
        end)
    end

    if controller.LocalPlayerLeftDuel and type(controller.LocalPlayerLeftDuel.Connect) == "function" then
        Connections.LeftDuel = controller.LocalPlayerLeftDuel:Connect(function()
            if env.__AutoVoteToken ~= Token then return end
            bindDuel(nil)
        end)
    end

    bindDuel(controller.CurrentObject)
    return true
end

-- Retries only until the controller exists, then stops entirely. Running this
-- file during the loading screen is normal; polling forever afterwards is not.
task.spawn(function()
    while env.__AutoVoteToken == Token do
        local ok, done = pcall(registerSignals)
        if ok and done then
            notify("active")
            return
        end
        task.wait(1)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__AutoVoteCleanup = function()
    env.__AutoVoteToken = nil
    for name in pairs(Connections) do
        disconnect({ name })
    end
    table.clear(Connections)
    State.Controller = nil
    State.BoundDuel = nil
    State.LastVoteType = nil
    State.LastSubmitted = nil
    env.__AutoVoteCleanup = nil
end
