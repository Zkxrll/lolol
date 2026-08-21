--[[============================================================================
    STAFF DETECTOR  -  tell me if a RIVALS moderator just joined
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Watches everyone in the server and warns you about two kinds of person:

        MODERATOR    they hold rank 100+ in the RIVALS Roblox group
        MOD FRIEND   their Roblox friends list contains somebody who does

    Optionally it can also get you out - leave the server, or teleport back to
    the lobby - before they get a chance to watch you.

===============================================================================
    THIS FILE MAKES A NETWORK REQUEST. HERE IS EXACTLY WHAT IT IS.
===============================================================================

    This is one of only two features in the entire project that talks to
    anything outside the game, and the project is careful about saying so.

    It calls `groups.roblox.com`, which is Roblox's own public group API, and
    it reads two things:

        /v1/groups/3461453/roles                     the group's rank list
        /v1/groups/3461453/roles/{id}/users          who holds each rank

    Both are public - anyone can open them in a browser right now. Nothing is
    sent anywhere; nothing about you is included in the request; the only
    thing that leaves your machine is a request for a public members list. It
    talks to Roblox and nobody else, and there is no server of ours involved
    anywhere.

    (The other one is Custom Sounds, which downloads a URL that you typed in
    yourself.)

===============================================================================
    TWO QUESTIONS, TWO COMPLETELY DIFFERENT COSTS
===============================================================================

    "IS THIS PLAYER A MODERATOR?" is cheap and needs no network call at all,
    because Roblox already answers it:

        player:GetRankInGroup(3461453) >= 100

    That is built into the engine, it is already cached client-side, and it
    works on anyone in the server.

    "IS THIS PLAYER FRIENDS WITH A MODERATOR?" cannot be asked that way. You
    can get somebody's friends list (`Players:GetFriendsAsync`), but then you
    would have to ask `GetRankInGroup` about every one of their friends, and
    people have hundreds. That is hundreds of calls per player, per join.

    So it is turned inside out. Download the group's ENTIRE staff roster once -
    every user id at rank 100 or above - keep it in a set, and then checking a
    friends list is a table lookup per friend instead of a request per friend:

        if StaffUserIds[friendUserId] then ...

    One expensive thing done once, instead of a cheap thing done a thousand
    times. When a check is too slow, the fix is usually to invert which side
    you enumerate rather than to make the check faster.

===============================================================================
    PAGINATION, AND KNOWING WHEN YOU DID NOT GET ALL OF IT
===============================================================================

    The members endpoint returns 100 at a time with a cursor for the next page:

        repeat
            local page = fetchJson(url .. (cursor and "&cursor=" .. cursor or ""))
            ...
            cursor = page.nextPageCursor
        until not cursor or cursor == "" or pageCount >= MAX_PAGES

    Standard enough. The part worth copying is the `complete` flag next to it.

    A page can fail. A role can have more members than the page cap allows. In
    either case you now hold a PARTIAL roster - and a partial roster is
    dangerous in a way a missing one is not, because absence from it looks
    exactly like "this person is not staff". You would confidently tell the
    user they are safe on the strength of a request that timed out.

    So the code tracks whether it got everything, and treats the two cases
    completely differently:

        complete     -> replace the set, cache it for 15 minutes
        incomplete   -> MERGE into the set, keep it, retry in 15 seconds

    Merging rather than replacing is deliberate: everyone it did find is still
    genuinely staff, so that information is worth keeping. It is only the
    absence that is unreliable.

    Any time you cache the result of something that can partly fail, store
    whether it was complete alongside it. A cache that cannot tell you how much
    it knows is worse than no cache.

===============================================================================
    THREE-VALUED LOGIC, WHICH IS THE POINT OF THE WHOLE FILE
===============================================================================

    `isStaff(player)` returns one of THREE things:

        true    they are staff
        false   they are not staff
        nil     we could not find out

    Not two. This is the single most important detail here, and collapsing it
    to a boolean is how this feature would quietly fail at the exact moment it
    mattered - a moderator joins, the request times out, `nil` is treated as
    "not staff", and you are told the server is clean.

    Watch how `nil` is handled downstream. It does not produce a detection, and
    it does not produce an all-clear either. It produces a RETRY:

        if detection then
            runActions(detection)
        elseif unavailable then
            queueClassification(player, FAILURE_RETRY_DELAY)   -- ask again
        end

    Note `unavailable`, not `not detection`. A confirmed "no" is an answer and
    is never asked again until the cache expires. Only "I don't know" is
    retried. Getting that condition wrong gives you either a feature that never
    settles, or one that lies.

    Any function that answers a question by asking something that can fail
    should return three values, not two. It is one extra branch at each call
    site and it removes an entire class of silent wrongness.

===============================================================================
    THREE ASYNC PROBLEMS AND THEIR FIXES
===============================================================================

    Classification happens in the background, and there are twenty players, and
    the user can toggle the feature off halfway through. Three guards handle it.

    IN-FLIGHT DEDUPLICATION. Twenty people joining at once must not start
    twenty identical roster downloads. The first sets `StaffSetLoading`; the
    rest see it and wait for the result instead of duplicating the work:

        if StaffSetLoading then
            repeat task.wait(0.05) until not StaffSetLoading or timedOut
            return StaffSetReady
        end

    Note the timeout in that wait. A flag-based wait with no escape is a hang
    the first time the thread setting the flag dies.

    GENERATION COUNTERS, twice over. `Generation` is bumped whenever the
    feature is turned off and on; `RetryGeneration[userId]` is bumped whenever
    a particular player is re-queued. Both are captured before the async work
    and compared after it:

        if detectorGeneration ~= Generation
            or retryGeneration ~= RetryGeneration[userId] then return end

    Without the first, turning the feature off and on again mid-request lets a
    result from the previous session land in the new one. Without the second, a
    slow first attempt can overwrite the answer from a faster retry. They are
    separate counters because they answer separate questions - "is this whole
    feature still the same instance" and "is this the answer I am still waiting
    for" - and one counter cannot do both.

    RE-CHECKING AFTER THE AWAIT. Every guard is evaluated twice: once before
    starting the slow work and once after it finishes. Anything can have
    changed while you were waiting, including the player leaving. The rule for
    async code is that a condition you checked before a yield has not been
    checked; it has been checked *at some point in the past*.

===============================================================================
    THE ACTIONS
===============================================================================

    Kick, To Lobby, or just tell me. `Kick` wins when both are selected -
    leaving entirely is strictly safer than teleporting to another place in the
    same game, so if you asked for both you meant the safer one.

    Both are deduplicated through `ActionCache`, keyed by kind and user id, so
    a moderator who keeps getting re-detected does not trigger a teleport
    every single pass. To Lobby also has a five-second cooldown on top, because
    a teleport takes time to actually happen and the loop keeps running while
    it does.

    REQUIREMENTS
    An executor with `game:HttpGet` for the friends-of-staff half. The plain
    "is this player a moderator" half needs nothing at all and works without
    it - the file degrades to that automatically.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- What to do when actual RIVALS staff are found.
    -- Any of: "Notify", "Kick", "To Lobby". Kick wins over To Lobby.
    ModeratorActions = { "Notify" },

    -- What to do about players whose friends list contains staff.
    ModFriendActions = { "Notify" },

    -- The RIVALS group, and the rank at which someone counts as staff.
    GroupId = 3461453,
    MinimumRank = 100,
    LobbyPlaceId = 17625359962,

    Notify = true,
}

-- Cache lifetimes, in seconds. Success is cached for a long time because
-- these facts change slowly; failure is retried quickly because a failure is
-- not an answer. See the header.
local ROLE_CACHE_LIFETIME   = 300
local FRIEND_CACHE_LIFETIME = 300
local STAFF_SET_LIFETIME    = 900
local FAILURE_RETRY_DELAY   = 15

-- Caps, so a pathological group cannot make this run forever.
local MAX_STAFF_ROLES          = 32
local MAX_GROUP_PAGES_PER_ROLE = 10
local MAX_FRIEND_PAGES         = 5

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Staff Detector", Text = text, Duration = 8,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__StaffDetectorCleanup then
    pcall(env.__StaffDetectorCleanup)
end

local Token = {}
env.__StaffDetectorToken = Token

local State = {
    Connections = {},
    RoleCache = {},              -- userId -> { Value, ExpiresAt }
    FriendCache = {},            -- userId -> { Value, StaffFriendName, ExpiresAt }
    Detections = {},             -- userId -> detection or nil
    ActionCache = {},            -- "Kind:userId:Action" -> true
    ClassificationInFlight = {},
    RetryGeneration = {},        -- userId -> counter
    StaffUserIds = {},

    StaffSetExpiresAt = 0,
    StaffSetReady = false,
    StaffSetLoading = false,

    EscapeCooldownUntil = 0,
    Generation = 0,
    Unloaded = false,
}

local function isRunning()
    return env.__StaffDetectorToken == Token and CONFIG.Enabled and not State.Unloaded
end

local function isActionSelected(kind, action)
    local list = (kind == "Moderator") and CONFIG.ModeratorActions or CONFIG.ModFriendActions
    for _, entry in ipairs(list or {}) do
        if entry == action then return true end
    end
    return false
end

--=============================================================================
-- Is this player staff?
--=============================================================================
-- Returns true, false, or NIL. See the header - the third one is the point.

local function isStaff(player)
    if not player or player == LocalPlayer then return false end

    local cached = State.RoleCache[player.UserId]
    if cached and cached.ExpiresAt > os.clock() then
        return cached.Value
    end

    -- Free and built in. No network request for this half.
    local ok, rank = pcall(function()
        return player:GetRankInGroup(CONFIG.GroupId)
    end)
    if not ok or type(rank) ~= "number" then
        return nil     -- "could not find out", NOT "no"
    end

    local result = rank >= CONFIG.MinimumRank
    State.RoleCache[player.UserId] = {
        Value = result,
        ExpiresAt = os.clock() + ROLE_CACHE_LIFETIME,
    }
    if result then
        State.StaffUserIds[player.UserId] = true
    end
    return result
end

--=============================================================================
-- Downloading the staff roster
--=============================================================================

local function fetchJson(url)
    if type(game.HttpGet) ~= "function" then return nil end
    local requestOk, response = pcall(game.HttpGet, game, url)
    if not requestOk or type(response) ~= "string" then return nil end

    local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, response)
    return (decodeOk and type(decoded) == "table") and decoded or nil
end

local function ensureStaffUserIds()
    local now = os.clock()
    if State.StaffSetReady and State.StaffSetExpiresAt > now then
        return true
    end

    -- Somebody else is already fetching. Wait for them rather than starting a
    -- second identical download - but never wait forever. See the header.
    if State.StaffSetLoading then
        local waitUntil = now + 5
        repeat
            task.wait(0.05)
        until not State.StaffSetLoading or os.clock() >= waitUntil or State.Unloaded
        return State.StaffSetReady
    end

    State.StaffSetLoading = true

    local roles = fetchJson(("https://groups.roblox.com/v1/groups/%d/roles")
        :format(CONFIG.GroupId))

    local nextStaffUserIds = {}
    local complete = roles ~= nil and type(roles.roles) == "table"
    local staffRoleCount = 0

    if complete then
        for _, role in ipairs(roles.roles) do
            if type(role) == "table" and type(role.rank) == "number"
                and role.rank >= CONFIG.MinimumRank and tonumber(role.id) then

                staffRoleCount = staffRoleCount + 1
                if staffRoleCount > MAX_STAFF_ROLES then
                    complete = false
                    break
                end

                local cursor = nil
                local pageCount = 0
                repeat
                    pageCount = pageCount + 1
                    local url = ("https://groups.roblox.com/v1/groups/%d/roles/%d/users?limit=100&sortOrder=Asc")
                        :format(CONFIG.GroupId, tonumber(role.id))
                    if cursor and cursor ~= "" then
                        -- A cursor is an opaque string and can contain
                        -- characters that are not URL-safe.
                        url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
                    end

                    local page = fetchJson(url)
                    if not page or type(page.data) ~= "table" then
                        complete = false
                        break
                    end

                    for _, member in ipairs(page.data) do
                        local userId = type(member) == "table"
                            and tonumber(member.userId or member.id) or nil
                        if userId then
                            nextStaffUserIds[userId] = true
                        end
                    end

                    cursor = page.nextPageCursor
                until not cursor or cursor == "" or pageCount >= MAX_GROUP_PAGES_PER_ROLE

                -- Ran out of pages before running out of members.
                if cursor and cursor ~= "" then
                    complete = false
                end
            end
        end
    end

    if complete then
        -- Got everything: this set is now authoritative, so absence from it
        -- means something.
        State.StaffUserIds = nextStaffUserIds
        State.StaffSetReady = true
    else
        -- Partial. Everyone found IS staff, so keep them - but absence proves
        -- nothing, so merge rather than replace and come back soon. See header.
        for userId in pairs(nextStaffUserIds) do
            State.StaffUserIds[userId] = true
        end
        State.StaffSetReady = State.StaffSetReady or next(State.StaffUserIds) ~= nil
    end

    State.StaffSetExpiresAt = os.clock()
        + (complete and STAFF_SET_LIFETIME or FAILURE_RETRY_DELAY)
    State.StaffSetLoading = false
    return State.StaffSetReady
end

--=============================================================================
-- Is this player friends with staff?
--=============================================================================
-- Also three-valued.

local function isModFriend(player)
    if not player or player == LocalPlayer then return false end

    local cached = State.FriendCache[player.UserId]
    if cached and cached.ExpiresAt > os.clock() then
        return cached.Value, cached.StaffFriendName
    end

    if not ensureStaffUserIds() then
        return nil
    end

    local friendsOk, friendPages = pcall(Players.GetFriendsAsync, Players, player.UserId)
    if not friendsOk or not friendPages then
        return nil
    end

    local matchedName = nil
    local pageCount = 0
    local complete = true

    repeat
        pageCount = pageCount + 1
        local pageOk, friends = pcall(friendPages.GetCurrentPage, friendPages)
        if not pageOk or type(friends) ~= "table" then
            complete = false
            break
        end

        for _, friend in ipairs(friends) do
            local friendUserId = type(friend) == "table"
                and tonumber(friend.Id or friend.UserId or friend.id) or nil
            -- The whole reason the roster was downloaded: one table lookup
            -- instead of one request.
            if friendUserId and State.StaffUserIds[friendUserId] then
                matchedName = friend.Username or friend.DisplayName or tostring(friendUserId)
                break
            end
        end

        if matchedName or friendPages.IsFinished then break end
        if pageCount >= MAX_FRIEND_PAGES then
            complete = false
            break
        end
        if not pcall(friendPages.AdvanceToNextPageAsync, friendPages) then
            complete = false
            break
        end
    until false

    -- A match is a match even from a partial read. A non-match from a partial
    -- read is not an answer, so it is not cached and not returned as `false`.
    if matchedName then
        State.FriendCache[player.UserId] = {
            Value = true,
            StaffFriendName = matchedName,
            ExpiresAt = os.clock() + FRIEND_CACHE_LIFETIME,
        }
        return true, matchedName
    end
    if not complete then
        return nil
    end

    State.FriendCache[player.UserId] = {
        Value = false,
        ExpiresAt = os.clock() + FRIEND_CACHE_LIFETIME,
    }
    return false
end

--=============================================================================
-- Acting on a detection
--=============================================================================

local function runActions(detection)
    if not isRunning() or not detection or not detection.Player then return end

    local kind = detection.Kind
    local prefix = ("%s:%d:"):format(kind, detection.Player.UserId)
    local label = (kind == "Moderator") and "moderator" or "moderator friend"

    if isActionSelected(kind, "Notify") then
        local key = prefix .. "Notify"
        if not State.ActionCache[key] then
            State.ActionCache[key] = true
            notify(("%s is a %s%s"):format(
                detection.Player.Name, label,
                detection.StaffFriendName
                    and (" (friend: " .. detection.StaffFriendName .. ")") or ""))
        end
    end

    -- Kick wins: leaving is strictly safer than moving somewhere else in the
    -- same game, so if both were asked for, the safer one was meant.
    if isActionSelected(kind, "Kick") then
        local key = prefix .. "Kick"
        if not State.ActionCache[key] then
            State.ActionCache[key] = true
            pcall(LocalPlayer.Kick, LocalPlayer,
                ("Staff Detector: %s detected (%s)."):format(detection.Player.Name, label))
        end
        return
    end

    if isActionSelected(kind, "To Lobby") and game.PlaceId ~= CONFIG.LobbyPlaceId then
        local key = prefix .. "To Lobby"
        -- Two guards: once per player, and a cooldown, because a teleport
        -- takes real time to happen and this loop keeps running meanwhile.
        if not State.ActionCache[key] and os.clock() >= State.EscapeCooldownUntil then
            State.EscapeCooldownUntil = os.clock() + 5
            local ok = pcall(TeleportService.Teleport, TeleportService,
                CONFIG.LobbyPlaceId, LocalPlayer)
            if ok then
                State.ActionCache[key] = true
            end
        end
    end
end

--=============================================================================
-- Classification
--=============================================================================

local queueClassification

function queueClassification(player, delaySeconds)
    if not isRunning() or not player or player == LocalPlayer then return end

    local userId = player.UserId
    -- Two independent counters. See the header for why one cannot do both.
    local retryGeneration = (State.RetryGeneration[userId] or 0) + 1
    State.RetryGeneration[userId] = retryGeneration
    local detectorGeneration = State.Generation

    task.delay(delaySeconds or 0, function()
        if not isRunning()
            or detectorGeneration ~= State.Generation
            or retryGeneration ~= State.RetryGeneration[userId]
            or player.Parent ~= Players
            or State.ClassificationInFlight[userId] then
            return
        end

        State.ClassificationInFlight[userId] = true

        local staff = isStaff(player)
        local detection = nil
        local unavailable = staff == nil

        if staff == true then
            detection = { Player = player, Kind = "Moderator" }
        elseif staff == false then
            -- Only worth asking the expensive question once the cheap one has
            -- come back with a definite no.
            local modFriend, staffFriendName = isModFriend(player)
            unavailable = modFriend == nil
            if modFriend == true then
                detection = {
                    Player = player,
                    Kind = "ModFriend",
                    StaffFriendName = staffFriendName,
                }
            end
        end

        State.ClassificationInFlight[userId] = nil

        -- Every guard again. The work above yielded, so none of what we
        -- checked before it is known to still be true. See the header.
        if not isRunning()
            or detectorGeneration ~= State.Generation
            or retryGeneration ~= State.RetryGeneration[userId]
            or player.Parent ~= Players then
            return
        end

        State.Detections[userId] = detection

        if detection then
            runActions(detection)
        elseif unavailable then
            -- `unavailable`, not `not detection`. A confirmed "no" is an
            -- answer; only "I don't know" is worth asking again.
            queueClassification(player, FAILURE_RETRY_DELAY)
        end
    end)
end

--=============================================================================
-- Wiring
--=============================================================================

local function disconnectAll()
    for _, connection in ipairs(State.Connections) do
        connection:Disconnect()
    end
    State.Connections = {}
end

local function start()
    disconnectAll()
    State.Generation = State.Generation + 1

    table.insert(State.Connections, Players.PlayerAdded:Connect(function(player)
        queueClassification(player, 0)
    end))
    table.insert(State.Connections, Players.PlayerRemoving:Connect(function(player)
        -- Drop everything keyed by this player, or the tables grow forever in
        -- a server that churns.
        local userId = player.UserId
        State.Detections[userId] = nil
        State.RetryGeneration[userId] = nil
        State.ClassificationInFlight[userId] = nil
    end))

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            queueClassification(player, 0)
        end
    end
end

if CONFIG.Enabled then
    start()
    notify("watching " .. (#Players:GetPlayers() - 1) .. " players")
end

--=============================================================================
-- Cleanup
--=============================================================================

env.__StaffDetectorCleanup = function()
    env.__StaffDetectorToken = nil
    State.Unloaded = true
    -- Bumping the generation is what makes any classification still in flight
    -- discard its result instead of acting on it after we are gone.
    State.Generation = State.Generation + 1
    disconnectAll()
    env.__StaffDetectorCleanup = nil
end