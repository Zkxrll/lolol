--[[============================================================================
    NOCLIP  -  walk through walls
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Turns off collision on every part of your character, so you fall through the
    floor and walk through walls. Hold (or toggle) the key below to activate.

    HOW IT WORKS
    A Roblox character is a bunch of parts, and each one has a `CanCollide`
    property. Set them all to false and nothing stops you any more.

    Two things make that harder than it sounds, and both are why this file is
    longer than three lines:

    1. YOU HAVE TO KEEP DOING IT.
       The game re-enables collision on parts constantly - respawns, animations,
       equipping a weapon. So we don't set it once, we set it every single frame
       while noclip is on. That is what the Heartbeat loop at the bottom does.

    2. YOU HAVE TO PUT IT BACK CORRECTLY.
       When you turn noclip off, you have to re-enable collision - but only on
       the parts that were collidable to begin with. Plenty of parts on a
       character are *supposed* to be non-collidable (accessory handles, weapon
       models, hitbox helpers). If you naively set every part to CanCollide=true
       on release, you break the character: you snag on your own hat.

       So we keep a registry. When noclip binds to a character we record which
       parts were collidable at that moment, and we keep that registry current as
       parts are added and removed. On release we restore exactly those parts and
       nothing else.

       This registry approach is lifted from the original Kicia implementation
       (annotated at offset [139965] in KiciaHook_Deobfuscated.lua).

    3. DEATH IS A SPECIAL CASE.
       If you die while noclipping, we throw the registry away *without*
       restoring anything. The character is being destroyed - there is nothing to
       put back, and touching parts on a corpse mid-teardown throws errors.

    REQUIREMENTS
    None. This uses no executor-specific functions at all.

============================================================================--]]

local CONFIG = {
    -- The key that activates noclip.
    -- Full list of names: https://create.roblox.com/docs/reference/engine/enums/KeyCode
    Key = Enum.KeyCode.N,

    -- "Hold"   - noclip is on only while the key is held down
    -- "Toggle" - press once to turn on, press again to turn off
    Mode = "Toggle",

    -- Show a message when it turns on and off.
    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- Running this file twice would leave the first copy's loop running forever,
-- fighting the second one. So each run stores a token globally and the previous
-- run's loop sees the token change and retires itself.
local env = (getgenv and getgenv()) or _G
if env.__NoclipCleanup then
    pcall(env.__NoclipCleanup)
end

local Token = {}
env.__NoclipToken = Token

--=============================================================================
-- State
--=============================================================================

local State = {
    Active = false,          -- is noclip currently on
    BoundCharacter = nil,    -- the character our registry belongs to
    Connections = {},        -- DescendantAdded / DescendantRemoving handlers
    CollidableParts = {},    -- [BasePart] = true, the restore registry
}

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Noclip",
            Text = text,
            Duration = 2,
        })
    end)
end

--=============================================================================
-- The registry
--=============================================================================

-- Forget the current character entirely, WITHOUT restoring collision. Used when
-- the character is dying or being swapped out - there is nothing to restore to.
local function clearCharacter()
    for _, connection in ipairs(State.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(State.Connections)
    table.clear(State.CollidableParts)
    State.BoundCharacter = nil
end

-- Start tracking a character: record every part that is collidable RIGHT NOW,
-- then keep that record current as the character gains and loses parts.
local function bindCharacter(character)
    clearCharacter()
    State.BoundCharacter = character

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.CanCollide then
            State.CollidableParts[descendant] = true
        end
    end

    -- A part added while noclip is ON arrives with CanCollide=true and gets
    -- recorded, so it is correctly restored on release even though it never
    -- existed in the collidable state we originally captured.
    table.insert(State.Connections, character.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") and descendant.CanCollide then
            State.CollidableParts[descendant] = true
        end
    end))

    table.insert(State.Connections, character.DescendantRemoving:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            State.CollidableParts[descendant] = nil
        end
    end))
end

-- Put collision back on exactly the parts we recorded.
local function restoreCollision()
    for part in pairs(State.CollidableParts) do
        -- pcall because a part can be destroyed between the registry write and
        -- here (you died, or swapped weapons, on this very frame).
        pcall(function() part.CanCollide = true end)
    end
end

--=============================================================================
-- Per-frame driver
--=============================================================================

local function step()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local alive = character ~= nil and humanoid ~= nil and humanoid.Health > 0

    if not alive then
        -- Dying clears without restoring - see note 3 in the header.
        clearCharacter()
        return
    end

    if State.BoundCharacter ~= character then
        bindCharacter(character)
    end

    if not State.Active then
        return
    end

    -- Every frame, because the game keeps turning collision back on.
    for part in pairs(State.CollidableParts) do
        pcall(function() part.CanCollide = false end)
    end
end

local function setActive(active)
    if State.Active == active then return end

    if State.Active and not active then
        restoreCollision()
    end

    State.Active = active
    notify(active and "on" or "off")
end

--=============================================================================
-- Input and lifecycle
--=============================================================================

local heartbeat = RunService.Heartbeat:Connect(function()
    -- Retire if a newer run of this file has taken over.
    if env.__NoclipToken ~= Token then
        return
    end
    step()
end)

local inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end                 -- ignore keys typed into chat
    if input.KeyCode ~= CONFIG.Key then return end

    if CONFIG.Mode == "Toggle" then
        setActive(not State.Active)
    else
        setActive(true)
    end
end)

local inputEnded = UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= CONFIG.Key then return end
    -- Deliberately not gated on `processed`: a release that gets swallowed would
    -- leave noclip stuck on forever.
    if CONFIG.Mode == "Hold" then
        setActive(false)
    end
end)

-- Call this to shut the script down cleanly. Also called automatically if you
-- run this file again.
env.__NoclipCleanup = function()
    setActive(false)
    clearCharacter()
    pcall(function() heartbeat:Disconnect() end)
    pcall(function() inputBegan:Disconnect() end)
    pcall(function() inputEnded:Disconnect() end)
    env.__NoclipCleanup = nil
    env.__NoclipToken = nil
end

notify(("loaded - press %s to %s"):format(
    CONFIG.Key.Name,
    CONFIG.Mode == "Toggle" and "toggle" or "hold"
))
