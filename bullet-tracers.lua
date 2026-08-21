--[[============================================================================
    BULLET TRACERS  -  draw a beam along every shot fired in the match
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Every bullet - yours and everyone else's - leaves a beam from the muzzle to
    wherever it landed. Nine textures to pick from, a colour, a glow, and an
    optional spring so the beam shoots outward rather than appearing whole.

    It reads the game's network traffic without touching anything.

===============================================================================
    LISTENING IN ON A REMOTE
===============================================================================

    Shots arrive at your client as a message on an ordinary RemoteEvent:

        ReplicatedStorage.Remotes.Replication.Fighter.Replicate
        ReplicatedStorage.Remotes.Replication.Fighter.ReplicateUnreliable

    And here is the part people do not realise:

        remote.OnClientEvent:Connect(handler)

    That does NOT replace the game's handler. `OnClientEvent` is a signal, and
    signals can have any number of listeners - the game's handler still runs,
    exactly as before, and yours runs too, with the same arguments.

    So there is no hooking here at all. No metatable, no upvalue, no function
    replacement, nothing to detect and nothing to put back. You just asked to be
    told about messages that were already being sent to you.

    Whenever you want to *observe* rather than *change*, look for a signal to
    connect to before you reach for anything cleverer. It is the cheapest and
    safest thing in the toolbox, and it is easy to forget it exists.

    (Two remotes because Roblox splits reliable and unreliable replication. The
    unreliable one is for high-frequency, drop-tolerant traffic. Shots can come
    down either, so both are watched.)

===============================================================================
    THE PACKET DOES NOT SAY "ShootEffect"
===============================================================================

    The message is a list of values, and one of them names the effect. But it
    does not name it in English - the game runs its enum names through an
    obfuscator, so what actually arrives is a scrambled string that changes
    between builds.

    Do not go hunting for that string. The game ships the translator:

        EnumLibrary:ToEnum("ShootEffect")   -->  the same scrambled token

    Ask the game to encode the name you want and compare against the result. It
    is correct on every build, including ones that do not exist yet, and it is
    two lines instead of a reverse-engineering session.

    General principle: when a game obfuscates something it also has to
    de-obfuscate it, and that code is on your machine too.

    FINDING IT IN THE LIST
    The token is not at a fixed position, so the packet is scanned from index 3
    and the shooter's id is derived from wherever it turned up:

        objectId = (index == 4) and packet[2] or packet[index - 1]

    That looks arbitrary and it is - it is the shape the game's own packets have.
    This is what reverse-engineered code looks like when it is honest.

    THE HIT POSITIONS
    After the token comes a list of raycast results, and each one stores its
    position under a key that is a single zero byte:

        finish = encodedResult[utf8.char(0)]

    A zero-byte key is unreachable from ordinary code and invisible in most
    printouts - it is the same trick this project uses in
    [`overlay-removals.lua`](overlay-removals.lua) to plant a field nothing else
    can collide with, here being used by the game against you. Lua strings hold
    any bytes; use that, and expect others to.

===============================================================================
    TWO SMALL THINGS WORTH STEALING
===============================================================================

    THE GLOW CURVE
        beam.Brightness = 10000 ^ ((glow - 1) / 24)

    `Glow` is a 1-25 slider, and brightness is meaningful across four orders of
    magnitude. Mapping the slider linearly would waste almost all of it - every
    visible difference would be crammed into the first notch. This raises 10000
    to a fraction, so each step multiplies rather than adds, and every notch
    changes the look by about the same amount.

    Any time a slider drives something whose useful range spans orders of
    magnitude - brightness, volume, zoom, time - map it exponentially.

    THE SPRING
    The game already has a spring implementation at `Modules.Spring`, so the
    expanding beam just uses it: the far end's position tracks a spring easing
    from 0 to 1 while the near end stays at the muzzle.

    Reusing the game's own module is better than writing your own spring - it is
    less code, it matches how everything else in the game moves, and it is one
    less thing to get wrong.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    Color = Color3.fromRGB(120, 220, 255),
    -- Plain, Beam, Lightning, Trail, Zigzag, Heartrate, Chain, Glitch, Swirl
    Style = "Beam",

    Width = 0.06,
    Glow = 1,           -- 1-25, exponential; see header
    LightEmission = 1,

    TextureLength = 4,
    TextureSpeed = 1,

    Lifetime = 0.6,     -- seconds at full opacity
    FadeTime = 0.35,    -- seconds fading out after that

    -- Spring the beam outward from the muzzle instead of drawing it whole.
    Expand = false,
    SpringSpeed = 18,
    SpringDamper = 0.7,

    MaxTracers = 128,

    Notify = true,
}

local TRACER_STYLES = {
    Plain     = "",
    Beam      = "rbxassetid://12781852245",
    Lightning = "rbxassetid://446111271",
    Trail     = "rbxassetid://6419989824",
    Zigzag    = "rbxassetid://1274380363",
    Heartrate = "rbxassetid://5830549480",
    Chain     = "rbxassetid://9632168658",
    Glitch    = "rbxassetid://8089467613",
    Swirl     = "rbxassetid://5638168605",
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Bullet Tracers", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__BulletTracersCleanup then
    pcall(env.__BulletTracersCleanup)
end

local Token = {}
env.__BulletTracersToken = Token

local Tracers = {}
local Connections = {}
local ShootToken = nil
local SpringClass = nil

--=============================================================================
-- Asking the game to encode the name for us
--=============================================================================

local function resolveShootToken()
    if ShootToken then return ShootToken end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local enumModule = modules and modules:FindFirstChild("EnumLibrary")
    if not enumModule then return nil end

    local ok, library = pcall(require, enumModule)
    if not ok or type(library) ~= "table" then return nil end
    -- The library builds itself asynchronously; before it is finished the
    -- tokens it hands out are wrong.
    if library._enum_builder_complete ~= true or type(library.ToEnum) ~= "function" then
        return nil
    end

    local tokenOk, token = pcall(library.ToEnum, library, "ShootEffect")
    if not tokenOk or type(token) ~= "string" then return nil end

    ShootToken = token
    return token
end

local function resolveSpringClass()
    if SpringClass ~= nil then return SpringClass or nil end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local springModule = modules and modules:FindFirstChild("Spring")
    if not springModule then
        SpringClass = false
        return nil
    end

    local ok, class = pcall(require, springModule)
    SpringClass = (ok and type(class) == "table") and class or false
    return SpringClass or nil
end

--=============================================================================
-- Whose gun fired
--=============================================================================
-- The packet names the item that fired by id, not the player, so both the local
-- fighter and every other fighter are searched for an item with that id.

local function requireController(name)
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild(name)
    if not module then return nil end
    local ok, controller = pcall(require, module)
    return (ok and type(controller) == "table") and controller or nil
end

local function findItem(fighter, objectId)
    if type(fighter) ~= "table" then return nil end
    for _, item in pairs(rawget(fighter, "Items") or {}) do
        local data = type(item) == "table" and rawget(item, "Data") or nil
        local itemObjectId = type(data) == "table" and rawget(data, "ObjectID") or nil
        if itemObjectId == objectId then return item end
    end
    return nil
end

local function resolveItem(objectId)
    local controller = requireController("FighterController")
    if not controller then return nil end

    local localFighter = rawget(controller, "LocalFighter")
    local item = findItem(localFighter, objectId)
    if item then return item end

    for _, fighter in pairs(rawget(controller, "Objects") or {}) do
        item = findItem(fighter, objectId)
        if item then return item end
    end
    return nil
end

--=============================================================================
-- Drawing one tracer
--=============================================================================

local function createTracer(startPosition, finishPosition)
    local springClass = resolveSpringClass()
    if not springClass or type(springClass.new) ~= "function" then return end

    -- At the ceiling, the oldest goes. A screen full of stale beams is worse
    -- than losing the ones you have already seen.
    while #Tracers >= CONFIG.MaxTracers do
        local oldest = table.remove(Tracers, 1)
        if oldest then
            pcall(function()
                oldest.Beam:Destroy()
                oldest.Near:Destroy()
                oldest.Far:Destroy()
            end)
        end
    end

    local near = Instance.new("Attachment")
    near.Position = startPosition
    near.Parent = Workspace.Terrain

    -- Starts at the muzzle even when not expanding; the far end is moved to the
    -- hit position below, or animated there by the spring.
    local far = Instance.new("Attachment")
    far.Position = startPosition
    far.Parent = Workspace.Terrain

    local beam = Instance.new("Beam")
    beam.Attachment0 = near
    beam.Attachment1 = far
    beam.Color = ColorSequence.new(CONFIG.Color)
    beam.Width0 = CONFIG.Width
    beam.Width1 = CONFIG.Width
    beam.FaceCamera = true
    beam.LightEmission = CONFIG.LightEmission
    beam.LightInfluence = 0
    beam.Brightness = 10000 ^ ((math.clamp(CONFIG.Glow, 1, 25) - 1) / 24)   -- see header
    beam.Transparency = NumberSequence.new(0)

    local texture = TRACER_STYLES[CONFIG.Style] or ""
    if texture ~= "" then
        beam.Texture = texture
        beam.TextureLength = CONFIG.TextureLength
        beam.TextureSpeed = CONFIG.TextureSpeed
    end
    beam.Parent = Workspace.Terrain

    local spring = springClass.new(0)
    spring.Speed = CONFIG.SpringSpeed
    spring.Damper = CONFIG.SpringDamper
    spring.Target = 1

    if not CONFIG.Expand then
        -- Jump the spring to the end so the per-frame code below needs no
        -- special case for the non-expanding style.
        spring.Position = 1
        far.Position = finishPosition
    end

    table.insert(Tracers, {
        Beam = beam,
        Near = near,
        Far = far,
        Spring = spring,
        Start = startPosition,
        Finish = finishPosition,
        CreatedAt = tick(),
        Lifetime = math.max(0.1, CONFIG.Lifetime),
        FadeTime = math.max(0, CONFIG.FadeTime),
        Expand = CONFIG.Expand,
    })
end

--=============================================================================
-- Handling a shot packet
--=============================================================================

local function handleShoot(objectId, raycastResults)
    if type(raycastResults) ~= "table" then return end

    local item = resolveItem(objectId)
    local viewModel = type(item) == "table" and rawget(item, "ViewModel") or nil
    if type(viewModel) ~= "table" or type(viewModel.GetMuzzlePosition) ~= "function" then
        return
    end

    local ok, muzzlePosition = pcall(viewModel.GetMuzzlePosition, viewModel)
    local camera = Workspace.CurrentCamera
    if not ok or typeof(muzzlePosition) ~= "Vector3" or not camera then return end

    -- Nudged one stud forward so the beam does not start inside your own
    -- viewmodel, where it would be a bright smear across the screen.
    local startPosition = muzzlePosition + camera.CFrame.LookVector

    for _, encodedResult in pairs(raycastResults) do
        -- The zero-byte key. See header.
        local finishPosition = type(encodedResult) == "table" and encodedResult[utf8.char(0)] or nil
        if typeof(finishPosition) == "Vector3" then
            createTracer(startPosition, finishPosition)
        end
    end
end

local function handleReplicate(...)
    if not CONFIG.Enabled then return end

    local token = resolveShootToken()
    if not token then return end

    local packet = table.pack(...)
    for index = 3, packet.n do
        if packet[index] == token then
            -- Where the id sits depends on where the token turned up.
            local objectId = (index == 4) and packet[2] or packet[index - 1]
            if type(objectId) == "string" then
                handleShoot(objectId, packet[index + 1])
            end
            return
        end
    end
end

--=============================================================================
-- The frame
--=============================================================================

local function update()
    local now = tick()

    for index = #Tracers, 1, -1 do
        local tracer = Tracers[index]
        local age = now - tracer.CreatedAt
        local expired = age >= tracer.Lifetime + tracer.FadeTime
            or not tracer.Beam or tracer.Beam.Parent == nil

        if expired then
            pcall(function()
                tracer.Beam:Destroy()
                tracer.Near:Destroy()
                tracer.Far:Destroy()
            end)
            table.remove(Tracers, index)
        else
            tracer.Beam.Color = ColorSequence.new(CONFIG.Color)

            if tracer.Expand then
                tracer.Far.Position = tracer.Start:Lerp(
                    tracer.Finish,
                    math.clamp(tracer.Spring.Position, 0, 1)
                )
            end

            -- Fully opaque until Lifetime is up, then fades across FadeTime.
            local alpha = tracer.FadeTime > 0
                and math.clamp((age - tracer.Lifetime) / tracer.FadeTime, 0, 1)
                or 0
            tracer.Beam.Transparency = NumberSequence.new(alpha)
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

    -- Both, because shots can come down either. See header.
    for _, name in ipairs({ "Replicate", "ReplicateUnreliable" }) do
        local remote = fighter:FindFirstChild(name)
        if remote and remote:IsA("RemoteEvent") and not Connections[name] then
            Connections[name] = remote.OnClientEvent:Connect(function(...)
                if env.__BulletTracersToken ~= Token then return end
                pcall(handleReplicate, ...)
            end)
        end
    end

    return Connections.Replicate ~= nil or Connections.ReplicateUnreliable ~= nil
end

task.spawn(function()
    while env.__BulletTracersToken == Token do
        if bind() and resolveShootToken() then
            notify("active")
            return
        end
        task.wait(1)
    end
end)

Connections.Render = RunService.RenderStepped:Connect(function()
    if env.__BulletTracersToken ~= Token then return end
    local ok, err = pcall(update)
    if not ok then
        warn("[Bullet Tracers] " .. tostring(err))
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__BulletTracersCleanup = function()
    env.__BulletTracersToken = nil
    for _, connection in pairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)

    for _, tracer in ipairs(Tracers) do
        pcall(function()
            tracer.Beam:Destroy()
            tracer.Near:Destroy()
            tracer.Far:Destroy()
        end)
    end
    table.clear(Tracers)

    env.__BulletTracersCleanup = nil
end
