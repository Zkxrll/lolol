--[[============================================================================
    AUTO RESPAWN  -  come back the moment the game lets you
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    When you die, it asks the server to respawn you immediately instead of
    waiting for you to click anything.

    WHERE IT WORKS
    The remote it uses lives at

        ReplicatedStorage.Remotes.Duels.RespawnNow

    Note the `Duels` in that path. This is the game's own instant-respawn
    request, and it only exists - and is only honoured - in the modes that offer
    instant respawning, which is duels and practice rather than a ranked match.
    In a mode with a real respawn timer, the server will simply ignore it. The
    file does not pretend otherwise: if the remote is not there, it says so and
    stops.

===============================================================================
    THE BURST, AND WHY IT IS NOT SPAM
===============================================================================

    One request is not reliable. The server only accepts a respawn while you are
    in the state where respawning is allowed, and the exact frame that begins is
    not something the client can know - your death is processed on the server,
    and your client finds out afterwards. Fire a moment early and the request is
    dropped, silently, and you stay dead until you notice and click.

    So instead of trying to guess the frame, we fire a short burst:

        5 requests, 0.1 seconds apart

    which covers about half a second of uncertainty. The server takes the first
    one that lands in the valid window and ignores the rest, because the
    request is idempotent: "respawn me" when you are already alive is a no-op.

    Then a hard floor of ONE SECOND between bursts. This is the part that
    matters, and it is the difference between a burst and spam:

      * without it, every frame you spend dead sends another five requests
      * a client sending a remote sixty times a second is a pattern the server
        can see even if it ignores every one of them

    The general shape - a short burst to cover a timing window you cannot
    observe, plus a hard rate limit so the burst cannot repeat - is worth
    keeping. It is how you make an unreliable request reliable without making
    yourself loud.

    IF IT SEEMS TO DO NOTHING
    A handful of executors have a quirk where `FireServer` silently does nothing
    when called from a spawned thread rather than the top-level script thread.
    If the burst appears to fire and never arrives, that is the first thing to
    test - move the call out of the `task.spawn` and see if it starts working.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Requests per burst, and the gap between them, in seconds.
    BurstCount = 5,
    BurstDelay = 0.1,

    -- Minimum seconds between bursts. Do not set this to 0 - see header.
    RequestInterval = 1,

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
            Title = "Auto Respawn", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AutoRespawnCleanup then
    pcall(env.__AutoRespawnCleanup)
end

local Token = {}
env.__AutoRespawnToken = Token

--=============================================================================
-- The remote
--=============================================================================

local function respawnRemote()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local duels = remotes and remotes:FindFirstChild("Duels")
    local remote = duels and duels:FindFirstChild("RespawnNow")
    if remote and remote:IsA("RemoteEvent") then
        return remote
    end
    return nil
end

--=============================================================================
-- Requesting
--=============================================================================

local LastRequestAt = 0
local Bursting = false

local function requestRespawn()
    if not CONFIG.Enabled then return false end

    local now = tick()
    if now - LastRequestAt < CONFIG.RequestInterval then return false end

    local remote = respawnRemote()
    if not remote then return false end

    -- Stamped before the burst runs, not after, so a burst still in progress
    -- cannot have a second one started alongside it.
    LastRequestAt = now
    if Bursting then return false end
    Bursting = true

    task.spawn(function()
        for index = 1, CONFIG.BurstCount do
            if env.__AutoRespawnToken ~= Token then break end
            pcall(function() remote:FireServer() end)
            if index < CONFIG.BurstCount then
                task.wait(CONFIG.BurstDelay)
            end
        end
        Bursting = false
    end)

    return true
end

--=============================================================================
-- Noticing that you died
--=============================================================================
-- Two triggers, because neither alone is reliable. `Died` fires the instant the
-- humanoid's health reaches zero, which is the fast path. But if the character
-- is removed outright, or the script starts while you are already dead, no
-- event ever fires - so a slow poll backs it up.

local connections = {}

local function bindCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then return end

    table.insert(connections, humanoid.Died:Connect(function()
        if env.__AutoRespawnToken ~= Token then return end
        requestRespawn()
    end))
end

if LocalPlayer.Character then
    bindCharacter(LocalPlayer.Character)
end

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function(character)
    if env.__AutoRespawnToken ~= Token then return end
    bindCharacter(character)
end))

task.spawn(function()
    while env.__AutoRespawnToken == Token do
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        -- No character at all, or a dead one: both mean "ask".
        if not character or (humanoid and humanoid.Health <= 0) then
            requestRespawn()
        end
        task.wait(0.5)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__AutoRespawnCleanup = function()
    env.__AutoRespawnToken = nil
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
    env.__AutoRespawnCleanup = nil
end

if respawnRemote() then
    notify("active")
else
    -- Not an error: it just means this mode has no instant respawn.
    notify("no RespawnNow remote in this mode - will keep checking")
end
