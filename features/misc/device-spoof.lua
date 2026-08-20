--[[============================================================================
    DEVICE SPOOF  -  tell the server you are on a different device
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Your client tells the server what you are playing on - mouse and keyboard,
    touch, gamepad, or VR. This makes it report something else.

        Desktop -> MouseKeyboard
        Mobile  -> Touch
        Console -> Gamepad
        VR      -> VR

    What the server does with that is the game's business, not ours. Games
    commonly vary aim assist, control hints, or matchmaking by device. This file
    only changes what is reported; it makes no claim about what RIVALS does with
    it.

===============================================================================
    HOW IT WORKS
===============================================================================

    The report is sent by a function on the game's FighterController called
    `_ReplicateControls`. It reads one value:

        ControlsController.CurrentControls

    We could set `CurrentControls` on the controller directly, but that
    controller is shared - the whole game reads it, including the code that
    decides which on-screen prompts to show and how your input is interpreted.
    Change it there and you would genuinely start playing as if you were on a
    gamepad.

    So instead, exactly as `jump-power.lua` and
    `combat/no-spread-and-grenade-fuse.lua` do, we change what ONE function sees:

        find the upvalue of `_ReplicateControls` that IS the ControlsController
        replace it with a small proxy

    The proxy answers `CurrentControls` with the device you picked. Nothing else
    in the game is affected - your actual controls stay exactly as they are, and
    every other reader of the controller still gets the real object.

    Finding the upvalue is unusually easy here. We already have the real
    ControlsController, so we do not need to fingerprint anything - we just look
    for the upvalue that is equal to it.

===============================================================================
    PUSHING THE CHANGE
===============================================================================

    Swapping the upvalue does nothing until the game next replicates, which
    might not be for a while. So after installing (and again after removing) we
    call the game's own `_ReplicateControls` ourselves. It reads through our
    proxy and sends immediately.

    Calling the game's own function rather than firing a remote by hand means we
    do not have to know the remote, the argument order, or the encoding - and it
    keeps working if any of those change.

===============================================================================
    THE TWO :Kick() LINES
===============================================================================

    The proxy is deliberately narrow: it answers `CurrentControls` and nothing
    else. If the game asks it for any other field, or if the device you picked
    is not one of the four known values, it kicks you:

        LocalPlayer:Kick("Unexpected behavior (client misc 2)")   -- unknown field
        LocalPlayer:Kick("Unexpected behavior (client misc 1)")   -- unknown device

    Both come from the original Kicia implementation and are kept verbatim.
    The reasoning is that either case means the assumption behind the hook is
    wrong - the game changed - and a proxy that starts returning `nil` for
    fields the game expects would cause confusing, hard-to-attribute breakage
    somewhere else entirely. Leaving is treated as the safer failure.

    Neither is malicious and neither reports anything anywhere. If you would
    rather it failed quietly, delete the two `LocalPlayer:Kick(...)` lines below
    - returning `nil` and returning the real value respectively is a reasonable
    fallback. It is kept as-is here because this is a reconstruction, and
    quietly "improving" a guard changes behaviour in ways that are hard to
    notice later.

    REQUIREMENTS
    `debug.getupvalues`, `debug.getupvalue`, `debug.setupvalue`. You also have to
    be in a match - the controllers do not exist before that, so the file waits.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- One of: "Desktop", "Mobile", "Console", "VR"
    SpoofAs = "VR",

    RetryInterval = 1,
    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- The four devices the game knows about, and the value it replicates for each.
local CONTROLS_MAP = {
    Desktop = "MouseKeyboard",
    Mobile = "Touch",
    Console = "Gamepad",
    VR = "VR",
}

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Device Spoof", Text = text, Duration = 4,
        })
    end)
end

local missing = {}
for _, name in ipairs({ "getupvalues", "getupvalue", "setupvalue" }) do
    if type(debug[name]) ~= "function" then
        table.insert(missing, "debug." .. name)
    end
end
if #missing > 0 then
    notify("your executor is missing: " .. table.concat(missing, ", "))
    return
end

local env = (getgenv and getgenv()) or _G
if env.__DeviceSpoofCleanup then
    pcall(env.__DeviceSpoofCleanup)
end

local Token = {}
env.__DeviceSpoofToken = Token

--=============================================================================
-- Finding the pieces
--=============================================================================

local function requireController(name)
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild(name)
    if not module then return nil end
    local ok, controller = pcall(require, module)
    return (ok and type(controller) == "table") and controller or nil
end

-- `_ReplicateControls` lives on the class table behind the controller's
-- metatable, not on the controller instance itself.
local function resolveReplicateControls()
    local fighterController = requireController("FighterController")
    if type(fighterController) ~= "table" then return nil, nil end

    local metatable = getmetatable(fighterController)
    local classIndex = type(metatable) == "table" and rawget(metatable, "__index") or nil
    local fn = type(classIndex) == "table" and rawget(classIndex, "_ReplicateControls") or nil
    if type(fn) ~= "function" then return nil, fighterController end

    return fn, fighterController
end

-- Run the game's own replication so the change lands now, not eventually.
local function forceReplicate()
    local fn, fighterController = resolveReplicateControls()
    if fn and fighterController then
        pcall(fn, fighterController)
    end
end

--=============================================================================
-- The hook
--=============================================================================

local Hook = nil   -- { fn, index, original }

local function install()
    if Hook then return true end

    local controlsController = requireController("ControlsController")
    if type(controlsController) ~= "table" then return false end

    local replicateControls = resolveReplicateControls()
    if type(replicateControls) ~= "function" then return false end

    -- We hold the real controller, so we can find its upvalue by identity.
    local upvalueIndex = nil
    for index, value in pairs(debug.getupvalues(replicateControls)) do
        if value == controlsController then
            upvalueIndex = index
            break
        end
    end
    if upvalueIndex == nil then return false end

    local original = debug.getupvalue(replicateControls, upvalueIndex)

    debug.setupvalue(replicateControls, upvalueIndex, setmetatable({}, {
        __index = function(_, key)
            if key ~= "CurrentControls" then
                -- See "THE TWO :Kick() LINES" in the header. Delete the next
                -- line if you would rather this failed quietly.
                LocalPlayer:Kick("Unexpected behavior (client misc 2)")
                return nil
            end

            local value = CONTROLS_MAP[CONFIG.SpoofAs]
            if value == nil then
                -- See the header. Delete the next line to fail quietly - though
                -- then fix your CONFIG.SpoofAs, because it is not one of the
                -- four valid values.
                LocalPlayer:Kick("Unexpected behavior (client misc 1)")
            end
            return value
        end,
    }))

    Hook = { fn = replicateControls, index = upvalueIndex, original = original }
    return true
end

local function uninstall()
    if not Hook then return end
    local hook = Hook
    Hook = nil
    pcall(debug.setupvalue, hook.fn, hook.index, hook.original)
end

--=============================================================================
-- Keep it in the state CONFIG asks for
--=============================================================================

task.spawn(function()
    while env.__DeviceSpoofToken == Token do
        if CONFIG.Enabled and not Hook then
            local ok, installed = pcall(install)
            if ok and installed then
                forceReplicate()
                notify("reporting as " .. tostring(CONFIG.SpoofAs))
            end
        elseif not CONFIG.Enabled and Hook then
            uninstall()
            forceReplicate()
        end
        task.wait(CONFIG.RetryInterval)
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================
-- Restore the upvalue, then push the real device straight away so the server is
-- not left holding the spoofed value.

env.__DeviceSpoofCleanup = function()
    env.__DeviceSpoofToken = nil
    if Hook then
        uninstall()
        pcall(forceReplicate)
    end
    env.__DeviceSpoofCleanup = nil
end
