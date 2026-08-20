--[[============================================================================
    HIT + KILL FEEDBACK  -  a sound and a flash when you land a shot
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Plays a sound when you hit someone - a different one for a headshot - and
    briefly paints their whole body a colour so you can see exactly who you hit
    in a crowd. Same again, with its own sound and colour, when you get a kill.

    Read [`bullet-tracers.lua`](bullet-tracers.lua) first. This listens to the
    same remote the same way; what differs is what it does with what it hears.

===============================================================================
    ONE LISTENER, THREE EFFECTS
===============================================================================

    The game announces things by putting an obfuscated token in a replicated
    packet, and the enum library will encode any name you ask for:

        ShootEffect         someone fired          -> bullet-tracers.lua
        DamageNumberEffect  someone took damage    -> this file
        EliminationEffect   someone died           -> this file

    So the same listener serves all of them, and adding a fourth would be one
    more name in the list. That is the shape of a well-built observer: one place
    that reads packets, a table of what you care about, and separate handlers.

    THE GATE THAT MAKES IT USEFUL
    Damage packets are broadcast for everyone's hits, not just yours. Without
    this line you would hear a hitmarker every time anybody in the server hit
    anybody:

        if localObjectId ~= packetObjectId then return end

    The packet names the fighter who dealt the damage, and that is compared
    against your own fighter's id. It is one comparison, and it is the whole
    difference between a hit sound and a constant din.

    Whenever you start reading broadcast traffic, the first question is which of
    it is about you. Usually there is an id in the packet that answers it.

===============================================================================
    THE CHAMS: A DISPOSABLE COPY, NOT AN EDIT
===============================================================================

    The obvious way to flash someone red is to set their parts' colour and set
    it back. Don't. You would be writing to instances the game owns and
    animates, you would fight its own colour updates, and if anything went wrong
    mid-flash you would leave a player permanently red.

    Instead a throwaway copy is built:

        ghost = part:Clone()
        for _, descendant in ipairs(ghost:GetDescendants()) do
            if not descendant:IsA("DataModelMesh") then
                descendant:Destroy()
            end
        end

    Cloning gets the exact size, shape and mesh for free - matching a character's
    geometry by hand is hopeless. Then everything inside the clone is destroyed
    except `DataModelMesh` objects, which is the class covering SpecialMesh and
    friends. That one filter strips scripts, decals, textures, particle
    emitters, welds, sounds and attachments in a line, and keeps precisely the
    thing that makes the shape correct.

    Knowing the right base class to filter on turns a long list of "destroy
    this, destroy that" into one condition. `DataModelMesh` is the useful one
    here; the habit of looking for it generalises.

    The ghosts are `Anchored` and their CFrame is copied from the real part each
    frame, rather than welded to it. Chasing rather than attaching means the
    ghost can be destroyed at any moment, in any state, and the real character
    cannot possibly be disturbed - no welds to clean up, nothing to leave
    behind. When you attach something temporary to something you do not own,
    prefer chasing.

    They are also `CanCollide`, `CanQuery` and `CanTouch` false, so they are
    invisible to physics and to raycasts - including the game's own, and your
    aimbot's.

===============================================================================
    TWO WAYS TO PLAY A SOUND, AND WHEN TO USE WHICH
===============================================================================

    This file does:

        sound.Parent = SoundService
        Debris:AddItem(sound, 20)
        sound:Play()

    while [`../world/lightning.lua`](../world/lightning.lua) does:

        sound.PlayOnRemove = true
        sound.Parent = SoundService
        sound:Destroy()

    Both are fire-and-forget with no cleanup to write. The difference is that
    `PlayOnRemove` is gone the instant you make it, so nothing can ever stop it,
    while the Debris version leaves a real instance around for its lifetime that
    you could still stop, retune, or check on.

    Thunder can never need cancelling. A hit sound might - you may want to cut
    it when the feature is turned off mid-fight. Pick by whether you might ever
    want to change your mind.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- === On a hit ============================================================
    HitSound = true,
    HeadSoundId = "rbxassetid://83717596220569",   -- headshot
    BodySoundId = "rbxassetid://83717596220569",
    HeadVolume = 1, HeadPitch = 1.2,
    BodyVolume = 1, BodyPitch = 1,

    HitChams = true,
    HitColor = Color3.fromRGB(255, 60, 60),
    HitTransparency = 0.35,
    HitDuration = 0.8,

    -- === On a kill ===========================================================
    KillSound = true,
    KillSoundId = "rbxassetid://139452805868562",
    KillVolume = 1, KillPitch = 1,

    KillChams = true,
    KillColor = Color3.fromRGB(255, 220, 60),
    KillTransparency = 0.25,
    KillDuration = 0.8,

    -- Ghost, Flat, Foil, Custom, Reflective
    Material = "Ghost",

    Notify = true,
}

local MATERIALS = {
    Ghost      = Enum.Material.ForceField,
    Flat       = Enum.Material.Neon,
    Foil       = Enum.Material.Foil,
    Custom     = Enum.Material.SmoothPlastic,
    Reflective = Enum.Material.Glass,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Hit Feedback", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__HitFeedbackCleanup then
    pcall(env.__HitFeedbackCleanup)
end

local Token = {}
env.__HitFeedbackToken = Token

local Chams = {}
local Connections = {}
local Tokens = nil    -- enum name -> obfuscated token

--=============================================================================
-- Tokens and identity
--=============================================================================

local function resolveTokens()
    if Tokens then return Tokens end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local enumModule = modules and modules:FindFirstChild("EnumLibrary")
    if not enumModule then return nil end

    local ok, library = pcall(require, enumModule)
    if not ok or type(library) ~= "table" then return nil end
    if library._enum_builder_complete ~= true or type(library.ToEnum) ~= "function" then
        return nil
    end

    local resolved = {}
    for _, name in ipairs({ "DamageNumberEffect", "EliminationEffect" }) do
        local tokenOk, token = pcall(library.ToEnum, library, name)
        if not tokenOk or type(token) ~= "string" then return nil end
        resolved[name] = token
    end

    Tokens = resolved
    return resolved
end

local function localFighter()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("FighterController")
    if not module then return nil end

    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return nil end
    return rawget(controller, "LocalFighter")
end

-- The id the packets use to say who did something.
local function localObjectId()
    local fighter = localFighter()
    if type(fighter) ~= "table" then return nil end
    local data = rawget(fighter, "Data")
    return type(data) == "table" and rawget(data, "ObjectID") or nil
end

--=============================================================================
-- Sound
--=============================================================================

local function playSound(soundId, volume, pitch)
    if type(soundId) ~= "string" or soundId == "" then return end

    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = math.max(0, volume or 1)
    sound.PlaybackSpeed = math.max(0.01, pitch or 1)
    sound.Parent = SoundService
    Debris:AddItem(sound, 20)   -- see header for why not PlayOnRemove
    sound:Play()
end

--=============================================================================
-- Chams
--=============================================================================

local function createChams(character, color, transparency, duration)
    if typeof(character) ~= "Instance" or not character:IsA("Model") then return end

    local model = Instance.new("Model")
    local parts = {}
    local material = MATERIALS[CONFIG.Material] or Enum.Material.ForceField
    local baseTransparency = math.clamp(transparency or 0, 0, 1)

    for _, part in ipairs(character:GetDescendants()) do
        -- The root part is an invisible collision box; already-invisible parts
        -- are not part of the silhouette either.
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
            local ok, ghost = pcall(function() return part:Clone() end)

            -- A clone can fail on a part with something odd inside it. A plain
            -- box of the right size is a worse ghost than a real one, but it is
            -- much better than a hole in the silhouette.
            if not ok or not ghost or not ghost:IsA("BasePart") then
                ghost = Instance.new("Part")
                ghost.Size = part.Size
                ghost.Shape = part:IsA("Part") and part.Shape or Enum.PartType.Block
            end

            -- Keep the geometry, throw away everything else. See header.
            for _, descendant in ipairs(ghost:GetDescendants()) do
                if not descendant:IsA("DataModelMesh") then
                    descendant:Destroy()
                end
            end

            ghost.Anchored = true       -- chased, not welded; see header
            ghost.CanCollide = false
            ghost.CanQuery = false      -- invisible to raycasts, ours included
            ghost.CanTouch = false
            ghost.CastShadow = false
            ghost.Color = color or Color3.fromRGB(255, 0, 0)
            ghost.Material = material
            ghost.Transparency = baseTransparency
            ghost.CFrame = part.CFrame
            -- A material variant on the original would override our material.
            pcall(function() ghost.MaterialVariant = "" end)
            ghost.Parent = model

            table.insert(parts, { Source = part, Ghost = ghost })
        end
    end

    if #parts == 0 then
        model:Destroy()
        return
    end

    model.Parent = Workspace
    table.insert(Chams, {
        Model = model,
        Parts = parts,
        StartedAt = tick(),
        Duration = math.max(0.05, duration or 0.8),
        Transparency = baseTransparency,
    })
end

--=============================================================================
-- Handlers
--=============================================================================

local function handleHit(isHead, character)
    if CONFIG.HitSound then
        if isHead then
            playSound(CONFIG.HeadSoundId, CONFIG.HeadVolume, CONFIG.HeadPitch)
        else
            playSound(CONFIG.BodySoundId, CONFIG.BodyVolume, CONFIG.BodyPitch)
        end
    end
    if CONFIG.HitChams then
        createChams(character, CONFIG.HitColor, CONFIG.HitTransparency, CONFIG.HitDuration)
    end
end

local function handleKill(character)
    if CONFIG.KillSound then
        playSound(CONFIG.KillSoundId, CONFIG.KillVolume, CONFIG.KillPitch)
    end
    if CONFIG.KillChams then
        createChams(character, CONFIG.KillColor, CONFIG.KillTransparency, CONFIG.KillDuration)
    end
end

local function handleReplicate(...)
    if not CONFIG.Enabled then return end

    local tokens = resolveTokens()
    if not tokens then return end

    local packet = table.pack(...)
    for index = 3, packet.n do
        local value = packet[index]
        if type(value) == "string" then
            local matched = nil
            for name, token in pairs(tokens) do
                if value == token then
                    matched = name
                    break
                end
            end

            if matched then
                local objectId = (index == 4) and packet[2] or packet[index - 1]
                if type(objectId) ~= "string" then return end

                -- Only our own hits. See header - this is the important line.
                if localObjectId() ~= objectId then return end

                local hitPart = packet[index + 1]
                if typeof(hitPart) ~= "Instance" then return end
                local character = hitPart.Parent
                if typeof(character) ~= "Instance" or not character:IsA("Model") then return end

                if matched == "DamageNumberEffect" then
                    handleHit(packet[index + 3] == true, character)
                else
                    handleKill(character)
                end
                return
            end
        end
    end
end

--=============================================================================
-- The frame
--=============================================================================

local function update()
    local now = tick()

    for index = #Chams, 1, -1 do
        local cham = Chams[index]
        local progress = math.clamp((now - cham.StartedAt) / cham.Duration, 0, 1)

        if progress >= 1 or not cham.Model or cham.Model.Parent == nil then
            if cham.Model then
                pcall(function() cham.Model:Destroy() end)
            end
            table.remove(Chams, index)
        else
            for partIndex = #cham.Parts, 1, -1 do
                local pair = cham.Parts[partIndex]
                if pair.Source and pair.Source.Parent and pair.Ghost and pair.Ghost.Parent then
                    pair.Ghost.CFrame = pair.Source.CFrame   -- chase it
                    -- Fade from its starting transparency out to fully clear.
                    pair.Ghost.Transparency = cham.Transparency
                        + (1 - cham.Transparency) * progress
                else
                    -- The real part is gone (they despawned mid-flash), so this
                    -- ghost has nothing left to follow.
                    if pair.Ghost then
                        pcall(function() pair.Ghost:Destroy() end)
                    end
                    table.remove(cham.Parts, partIndex)
                end
            end
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================

local function bind()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local replication = remotes and remotes:FindFirstChild("Replication")
    local fighter = replication and replication:FindFirstChild("Fighter")
    if not fighter then return false end

    for _, name in ipairs({ "Replicate", "ReplicateUnreliable" }) do
        local remote = fighter:FindFirstChild(name)
        if remote and remote:IsA("RemoteEvent") and not Connections[name] then
            Connections[name] = remote.OnClientEvent:Connect(function(...)
                if env.__HitFeedbackToken ~= Token then return end
                pcall(handleReplicate, ...)
            end)
        end
    end

    return Connections.Replicate ~= nil or Connections.ReplicateUnreliable ~= nil
end

task.spawn(function()
    while env.__HitFeedbackToken == Token do
        if bind() and resolveTokens() then
            notify("active")
            return
        end
        task.wait(1)
    end
end)

Connections.Render = RunService.RenderStepped:Connect(function()
    if env.__HitFeedbackToken ~= Token then return end
    local ok, err = pcall(update)
    if not ok then
        warn("[Hit Feedback] " .. tostring(err))
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__HitFeedbackCleanup = function()
    env.__HitFeedbackToken = nil
    for _, connection in pairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)

    for _, cham in ipairs(Chams) do
        if cham.Model then
            pcall(function() cham.Model:Destroy() end)
        end
    end
    table.clear(Chams)

    env.__HitFeedbackCleanup = nil
end
