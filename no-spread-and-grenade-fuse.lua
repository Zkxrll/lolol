--[[============================================================================
    NO SPREAD  +  GRENADE FUSE  -  editing your inputs on the way to the server
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES

        NoSpread     your bullets go exactly where you aim, with no random
                     scatter, on any gun
        GrenadeFuse  decide when a cookable throwable detonates: the moment it
                     leaves your hand, or the moment it lands
        RemoveFuse   a cooked throwable never detonates in your hand

    WHY THESE TWO SHARE A FILE
    They are the only two features in the script that work by editing the
    arguments of an input on its way to the server, and they share the whole
    machinery that makes that possible. Both reserve a slot on one shared hook.
    Building that hook twice would mean two copies of it fighting over the same
    upvalue.

    This is the most technically interesting file in the folder. If you read
    only one to learn something, read this one - but read
    `movement/walkspeed-and-slide.lua` first, because it introduces upvalues
    with a much smaller example.

===============================================================================
    THE PROBLEM
===============================================================================

    When you shoot, your client tells the server about it:

        ReplicatedStorage.Remotes.Replication.Fighter.UseItem:FireServer(
            objectId,      -- which weapon
            encodedType,   -- what you did: StartShooting, FinishAiming, ...
            args           -- the details
        )

    We want to change what is in `args` before it leaves. The obvious way is to
    hook `FireServer` - either the method on that one remote, or the game's
    `__namecall` metamethod globally.

    Both are bad ideas. The `__namecall` hook is the single most-checked thing
    an anti-cheat looks for, and it puts your code in the path of EVERY remote
    call the entire game makes - thousands per minute, all of which you then
    have to filter and none of which you wanted. Hooking the one remote's
    `FireServer` is quieter but still leaves a modified function on an object
    anything in the game can look at.

===============================================================================
    THE TRICK  -  don't hook the remote, hook the map to it
===============================================================================

    The game finds that remote by walking a path from a variable:

        ReplicatedStorage . Remotes . Replication . Fighter . UseItem

    So we leave the remote completely alone, and instead change what
    `ReplicatedStorage` means - but only inside the one function that sends
    weapon inputs, and nowhere else in the game.

    That function is `Input`, on the game's `ClientItem` class. Like every Lua
    function it carries its own captured variables, called UPVALUES - the
    outside values it closed over when it was created. One of them is
    ReplicatedStorage. We find that upvalue and replace it with a decoy:

        decoy . anything . anything . anything . anything  ->  our function

    Then the game's own unmodified code walks its usual path, arrives at
    something it believes is the UseItem remote, and calls `FireServer` on it.
    That call lands in our function. We read the arguments, change what we want,
    and pass them on.

    What this buys us:
      * The real remote object is untouched. Compare it, hash it, iterate it -
        it is exactly as the game built it.
      * `FireServer` is untouched, globally and on that remote.
      * Only `ClientItem.Input` is affected. Every other script in the game
        still gets the real ReplicatedStorage from its own upvalue.
      * We only ever see weapon inputs. No filtering, no overhead on anything.

    HOW THE DECOY IS BUILT
    We need an object where reading ANY field returns our fake remote tree,
    because we do not want to care what the game names each step of the path.

        local decoy = Color3.new()
        setrawmetatable(decoy, { __index = function() return remoteTree end })

    A Color3 has no fields of its own, so `__index` fires for absolutely every
    read - `decoy.Remotes`, `decoy.Anything`, all of it returns `remoteTree`.
    A plain table would work for missing keys too, but a Color3 makes it
    impossible to accidentally hit a real key. `setrawmetatable` rather than
    `setmetatable` because Roblox datatypes already have a locked metatable that
    the normal function refuses to replace.

    From there `remoteTree` is just a plain nested table ending in our function.

    HOW WE FORWARD THE REAL CALL
    Once we are done editing, the input still has to reach the server. We do NOT
    call `realRemote:FireServer(...)`, because if anything else has hooked
    FireServer we would run through their hook too:

        local scratch = Instance.new("RemoteEvent")             -- never parented
        local fireServerNative = clonefunction(scratch.FireServer)
        ...
        fireServerNative(realRemote, objectId, encodedType, args, nil)

    A brand new RemoteEvent gives us a clean reference to `FireServer` before
    anyone could have touched this specific one, `clonefunction` gives us a copy
    that is not identity-equal to the original (so we are not holding a
    recognisable reference to it), and calling it with the real remote as the
    first argument is exactly what `remote:FireServer(...)` means anyway.

===============================================================================
    THE SHARED DISPATCH
===============================================================================

    Two features need this hook, and one day a third might. So the hook does not
    know about either of them. It builds a packet:

        { block = false, objectId = ..., type = "StartShooting", args = {...} }

    and offers it to each registered handler in turn. A handler edits `args`,
    and may set `block = true` to swallow the input entirely (neither feature
    here does, but the machinery supports it). Whatever survives gets sent.

    `type` is decoded first. The game sends the input type as a compact code
    rather than a string, so we look it up in the game's own EnumLibrary
    `_from_enum` table to get back "StartShooting" and friends.

===============================================================================
    NO SPREAD
===============================================================================

    On a `StartShooting` input, look up which weapon it was, and if that weapon
    is a gun, set one argument:

        packet.args["\2"] = true

    `"\2"` is a string one character long, holding the byte 2. The game names
    the fields of this packet with single bytes instead of words to keep the
    message small. This particular field is the one the shot handler reads to
    decide whether to apply spread; setting it makes the shot land dead centre.

    We do not compute anything, aim anything, or move anything - we set one flag
    on a message the game was already sending.

===============================================================================
    GRENADE FUSE
===============================================================================

    Cookable throwables send a fuse time when you release them - argument
    `"\3"`. Whatever number we put there is when it goes off.

        ExplodeOn = "Throw"    ->  0, detonates as it leaves your hand
        ExplodeOn = "Impact"   ->  the exact time it will reach where it lands

    Working out that impact time is the interesting half. While you hold a
    throwable the game draws the arc preview in front of you, and that preview
    is a real object with real data on it: a list of segment parts along the
    arc, and a sphere sitting at the predicted landing point. The segments are
    spaced a fixed time apart. So:

        find the segment whose position matches the impact sphere
        its index tells you how many time-steps along the arc that is

    which gives `(index - 2) * step`, capped by the game's own maximum. The
    step and the cap are read from the preview's `_last_args`, defaulting to
    0.05 seconds and no cap. Nothing is estimated - this is the game's own
    prediction, read back out of its own preview.

    (The `- 2` is an index offset in the game's segment list, and the segment
    list is walked with `next()` because it is a plain array of parts, not a
    callable iterator. Both were confirmed against the live game.)

    REMOVE FUSE, AND WHY IT NEEDS A SECOND HOOK
    Remove Fuse clears the item's `_cook_detonate_delay`, which is the timer
    that blows the grenade up in your hand if you cook it too long.

    Clearing it from the input handler is one throw too late. The arming happens
    in `Throwable._StartThrow`, which does its `task.delay(_cook_detonate_delay,
    ...)` and only afterwards replicates - and replication is where our hook
    sits. By the time we see the input, the timer for this throw is already
    running.

    So Remove Fuse installs a small second hook, on `Throwable._StartThrow`
    itself, which clears the field one call earlier - before the delay is read.
    It is installed when Remove Fuse is turned on and removed when it is turned
    off.

    This is worth remembering in general: intercepting at the network layer
    means you are downstream of everything the client already did locally. If a
    local effect has already happened by the time the packet exists, the network
    layer is the wrong place to stop it.

    REQUIREMENTS
    `setrawmetatable`, `clonefunction`, `debug.getupvalues`, `debug.setupvalue`.
    `compareinstances` and `cloneref` are used if present. This is the most
    demanding file in the folder; plenty of executors cannot run it.

============================================================================--]]

local CONFIG = {
    NoSpread = true,

    GrenadeFuse = false,
    -- "Impact" detonates where the arc preview says it will land.
    -- "Throw"  detonates the instant it leaves your hand.
    ExplodeOn = "Impact",

    -- Stop a cooked throwable detonating in your hand.
    RemoveFuse = false,

    -- How often to retry installing while the game is still loading.
    RetryInterval = 1,

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
            Title = "No Spread / Grenade Fuse", Text = text, Duration = 5,
        })
    end)
end

-- Capability check. All four are required; there is no partial mode.
local missing = {}
if type(setrawmetatable) ~= "function" then table.insert(missing, "setrawmetatable") end
if type(clonefunction) ~= "function" then table.insert(missing, "clonefunction") end
if type(debug.getupvalues) ~= "function" then table.insert(missing, "debug.getupvalues") end
if type(debug.setupvalue) ~= "function" then table.insert(missing, "debug.setupvalue") end

if #missing > 0 then
    notify("your executor is missing: " .. table.concat(missing, ", "))
    return
end

local env = (getgenv and getgenv()) or _G
if env.__InputHookCleanup then
    pcall(env.__InputHookCleanup)
end

local Token = {}
env.__InputHookToken = Token

local function report(where, err)
    warn(("[Input Hook] %s: %s"):format(where, tostring(err)))
end

--=============================================================================
-- Finding the game's pieces
--=============================================================================

local function requireChild(parent, name)
    local module = parent and parent:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    return ok and result or nil
end

local function playerModules()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    return playerScripts and playerScripts:FindFirstChild("Modules"),
        playerScripts and playerScripts:FindFirstChild("Controllers")
end

-- The class whose `Input` function holds the ReplicatedStorage upvalue we swap.
local function resolveClientItem()
    local modules = playerModules()
    local replicated = modules and modules:FindFirstChild("ClientReplicatedClasses")
    local fighter = replicated and replicated:FindFirstChild("ClientFighter")
    local clientItem = requireChild(fighter, "ClientItem")
    return type(clientItem) == "table" and clientItem or nil
end

-- The real remote. We never modify it; we only need it to forward calls.
local function resolveUseItemRemote()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local replication = remotes and remotes:FindFirstChild("Replication")
    local fighter = replication and replication:FindFirstChild("Fighter")
    local remote = fighter and fighter:FindFirstChild("UseItem")
    if not remote or not remote:IsA("RemoteEvent") then return nil end
    -- cloneref hands back a proxy that behaves like the instance but is not
    -- traceable back to us through the usual reference checks.
    return (type(cloneref) == "function" and cloneref(remote)) or remote
end

-- Turns the compact input code the game sends back into "StartShooting" etc.
local function resolveInputDecoder()
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local library = requireChild(modules, "EnumLibrary")
    local fromEnum = type(library) == "table" and rawget(library, "_from_enum") or nil
    if type(fromEnum) ~= "table" then return nil end
    return function(encoded) return rawget(fromEnum, encoded) end
end

local function resolveThrowable()
    local modules = playerModules()
    local throwable = requireChild(modules and modules:FindFirstChild("ItemTypes"), "Throwable")
    return type(throwable) == "table" and throwable or nil
end

-- Your weapons, looked up by the ObjectID the input packet refers to.
local FighterControllerCache = nil

local function localItems()
    if not FighterControllerCache then
        local _, controllers = playerModules()
        FighterControllerCache = requireChild(controllers, "FighterController")
    end
    local controller = FighterControllerCache
    if type(controller) ~= "table" then return {} end

    local fighter = controller.LocalFighter
    if not fighter and type(controller.GetFighter) == "function" then
        local ok, value = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and value or nil
    end

    local items = type(fighter) == "table" and rawget(fighter, "Items") or nil
    return type(items) == "table" and items or {}
end

local function itemById(objectId)
    for _, item in next, localItems() do
        local data = rawget(item, "Data")
        if data ~= nil and objectId == rawget(data, "ObjectID") then
            return item
        end
    end
    return nil
end

--=============================================================================
-- The hook itself
--=============================================================================

local Hook = {
    handlers = {},   -- ordered list of functions taking (packet)
    restore = nil,   -- how to undo the upvalue swap
    installed = false,
}

-- Comparing instances is not as simple as `==` here: if anything in the chain
-- handed us a cloneref proxy, a proxy and its original are NOT equal to each
-- other. `compareinstances` is the executor function that answers the question
-- honestly. We try it first and fall back to `==`.
local function isReplicatedStorage(value)
    if typeof(value) ~= "Instance" then return false end
    if type(compareinstances) == "function" and compareinstances(value, ReplicatedStorage) then
        return true
    end
    return value == ReplicatedStorage
end

function Hook.install(clientItem, useItemRemote, decodeInput)
    if Hook.installed then return true end

    local inputMethod = rawget(clientItem, "Input")
    if type(inputMethod) ~= "function" then
        return false, "could not find ClientItem.Input"
    end

    -- A clean, un-hooked FireServer to forward through. See header.
    local scratchRemote = Instance.new("RemoteEvent")
    local fireServerNative = clonefunction(scratchRemote.FireServer)

    local function fireServer(_, objectId, encodedType, args)
        local packet = {
            block = false,
            objectId = objectId,
            type = decodeInput(encodedType),
            args = args,
        }

        for _, handler in ipairs(Hook.handlers) do
            local ok, err = pcall(handler, packet)
            if not ok then report("handler", err) end
            if packet.block then break end
        end

        if packet.block then return end
        return fireServerNative(useItemRemote, objectId, encodedType, args, nil)
    end

    -- The fake path the game will walk. The decoy absorbs the first step
    -- (whatever it is called), and everything after it is this plain table.
    local remoteTree = {
        Replication = { Fighter = { UseItem = { FireServer = fireServer } } },
    }

    local decoy = Color3.new()
    setrawmetatable(decoy, {
        __index = function() return remoteTree end,
    })

    -- Find the ReplicatedStorage upvalue and swap it for the decoy.
    for index, value in pairs(debug.getupvalues(inputMethod)) do
        if isReplicatedStorage(value) then
            debug.setupvalue(inputMethod, index, decoy)
            Hook.restore = { method = inputMethod, index = index, original = value }
        end
    end

    -- Newer builds of the game keep that dependency one level deeper - inside a
    -- table that is itself the upvalue - so if the direct scan found nothing,
    -- look inside every table upvalue for the same thing.
    if Hook.restore == nil then
        for _, bundle in pairs(debug.getupvalues(inputMethod)) do
            if type(bundle) == "table" then
                for key, value in pairs(bundle) do
                    if isReplicatedStorage(value) then
                        Hook.restore = { bundle = bundle, key = key, original = value }
                        bundle[key] = decoy
                        break
                    end
                end
                if Hook.restore ~= nil then break end
            end
        end
    end

    if Hook.restore == nil then
        return false, "could not find the ReplicatedStorage upvalue"
    end

    Hook.installed = true
    return true
end

function Hook.uninstall()
    local restore = Hook.restore
    Hook.restore = nil
    Hook.installed = false
    if restore == nil then return end

    if restore.bundle ~= nil then
        restore.bundle[restore.key] = restore.original
    else
        debug.setupvalue(restore.method, restore.index, restore.original)
    end
end

--=============================================================================
-- Handler: No Spread
--=============================================================================

table.insert(Hook.handlers, function(packet)
    if not CONFIG.NoSpread then return end
    if packet.type ~= "StartShooting" then return end

    local item = itemById(packet.objectId)
    if item == nil then return end

    local info = rawget(item, "Info")
    if info == nil or rawget(info, "Type") ~= "Gun" then return end

    packet.args["\2"] = true   -- the "no spread on this shot" field
end)

--=============================================================================
-- Handler: Grenade Fuse
--=============================================================================

local Fuse = {
    trajectoryVisual = nil,      -- remembered between the start and finish input
    throwablePrototype = nil,    -- for the Remove Fuse second hook
    originalStartThrow = nil,
}

-- Read the impact time straight out of the game's own arc preview. See header.
local function computeImpactTime(trajectoryVisual)
    local lastArgs = rawget(trajectoryVisual, "_last_args")
    if type(lastArgs) ~= "table" then return nil end

    local step = lastArgs[4] or 0.05
    local cap = lastArgs[6] or math.huge

    local impactSphere = rawget(trajectoryVisual, "_impact_sphere")
    local segments = rawget(trajectoryVisual, "_segments")
    if impactSphere == nil or type(segments) ~= "table" then return nil end

    local impactCFrame = impactSphere.CFrame

    -- Walked with next() because _segments is a plain array of parts.
    local key
    while true do
        local segment
        key, segment = next(segments, key)
        if key == nil then break end
        if segment.CFrame == impactCFrame then
            return math.min(cap, (key - 2) * step)
        end
    end
    return nil
end

-- Remove Fuse's second hook, on Throwable._StartThrow. See header for why the
-- input handler alone is one throw too late.
local function ensureStartThrowHook()
    if Fuse.throwablePrototype then return end

    local throwable = resolveThrowable()
    if not throwable then return end

    local original = rawget(throwable, "_StartThrow")
    if type(original) ~= "function" then return end

    Fuse.throwablePrototype = throwable
    Fuse.originalStartThrow = original

    rawset(throwable, "_StartThrow", function(item, ...)
        if CONFIG.RemoveFuse then
            rawset(item, "_cook_detonate_delay", nil)
        end
        return original(item, ...)
    end)
end

local function restoreStartThrowHook()
    if not Fuse.throwablePrototype then return end
    rawset(Fuse.throwablePrototype, "_StartThrow", Fuse.originalStartThrow)
    Fuse.throwablePrototype = nil
    Fuse.originalStartThrow = nil
end

table.insert(Hook.handlers, function(packet)
    if not CONFIG.GrenadeFuse then return end

    local kind = packet.type
    local isStart = kind == "StartShooting" or kind == "StartAiming"
    local isFinish = kind == "FinishShooting" or kind == "FinishAiming"
    if not (isStart or isFinish) then return end

    local item = itemById(packet.objectId)
    if item == nil then return end

    -- Only throwables you can cook have a fuse to change.
    local info = rawget(item, "Info")
    if info == nil or not rawget(info, "CanCook") then return end

    if isStart then
        -- Remember the arc preview now; by the time you release, it is gone.
        Fuse.trajectoryVisual = rawget(item, "_trajectory_visual")
        if CONFIG.RemoveFuse then
            rawset(item, "_cook_detonate_delay", nil)
        end
        return
    end

    if CONFIG.ExplodeOn == "Throw" then
        packet.args["\3"] = 0
    else
        local fuseTime = nil
        if Fuse.trajectoryVisual then
            local ok, value = pcall(computeImpactTime, Fuse.trajectoryVisual)
            fuseTime = ok and value or nil
        end
        -- nil is a legitimate value here: it means "use the game's own default".
        packet.args["\3"] = fuseTime
    end

    Fuse.trajectoryVisual = nil
end)

--=============================================================================
-- Install, and keep the Remove Fuse hook in sync
--=============================================================================

local function tryInstall()
    local clientItem = resolveClientItem()
    local remote = resolveUseItemRemote()
    local decode = resolveInputDecoder()
    if not clientItem or not remote or not decode then
        return false
    end

    local ok, result, err = pcall(Hook.install, clientItem, remote, decode)
    if not ok then
        report("install", result)
        return false
    end
    if not result then
        report("install", err)
        return false
    end
    return true
end

task.spawn(function()
    -- The modules do not exist until you are actually in a match, so retry.
    while env.__InputHookToken == Token and not Hook.installed do
        if tryInstall() then
            notify("hooked - No Spread " .. (CONFIG.NoSpread and "on" or "off")
                .. ", Grenade Fuse " .. (CONFIG.GrenadeFuse and "on" or "off"))
            break
        end
        task.wait(CONFIG.RetryInterval)
    end

    -- Remove Fuse needs its extra hook present only while it is on.
    while env.__InputHookToken == Token do
        if CONFIG.GrenadeFuse and CONFIG.RemoveFuse then
            pcall(ensureStartThrowHook)
        elseif Fuse.throwablePrototype then
            pcall(restoreStartThrowHook)
        end
        task.wait(CONFIG.RetryInterval)
    end
end)

-- The fighter object is replaced on respawn; the modules are not.
local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__InputHookToken ~= Token then return end
    FighterControllerCache = nil
    Fuse.trajectoryVisual = nil
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__InputHookCleanup = function()
    env.__InputHookToken = nil
    pcall(function() characterConn:Disconnect() end)
    table.clear(Hook.handlers)
    pcall(restoreStartThrowHook)
    pcall(Hook.uninstall)
    env.__InputHookCleanup = nil
end
