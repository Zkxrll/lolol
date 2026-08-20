--[[============================================================================
    RAGEBOT  -  stop aiming, and put yourself on top of them instead
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    READ THIS FIRST
    This is the most detectable thing in the entire project, by an enormous
    margin, and it is not close. Every other feature here either changes only
    your screen or sends traffic that looks like a person playing. This one
    tells the server you are standing at coordinates roughly a hundred thousand
    studs outside the map, anchors other players' hitboxes, and fires the combat
    remote directly with a hand-built payload containing a ray a billion studs
    long.

    Any server-side check worth the name catches it. A position sanity check
    catches it. A rate-of-fire check catches it. A "why is this player's
    replicated position not inside any map" check catches it in one line. It is
    included because this is a faithful reconstruction and this is what the
    original does - not because it is subtle. It is not subtle.

===============================================================================
    WHAT A RAGEBOT IS
===============================================================================

    An aimbot moves your camera onto a target and lets the game do the rest,
    and it is trying to look like a person with good aim. See
    `aimbot.lua` and `flickbot.lua` for the versions that care about that.

    A ragebot does not aim at all. It stops pretending. Instead it moves YOU -
    or more precisely, moves what the server believes about where you are -
    until you are inside the target, and then fires the combat remote directly.
    There is no crosshair involved and no shot to line up. If the server thinks
    you are point-blank on someone, the shot hits.

    Everything below is in service of one sentence: *make the server believe you
    are somewhere you are not, without your own screen changing*.

===============================================================================
    TRICK ONE: ROOT VIRTUALIZATION
===============================================================================

    It is about thirty lines.

    Your character's position reaches the server because Roblox samples your
    HumanoidRootPart and replicates it. Your character appears on YOUR screen
    because the renderer draws it where the root is. Both read the same
    property - but they do not read it at the same moment in the frame.

    Roblox's frame runs roughly:

        RenderStepped  (RenderPriority.First is the earliest slot here)
        ...camera, rendering...
        physics step   <- position sampled and replicated from here
        Heartbeat      (the last thing in the frame)

    So if you write a fake CFrame at Heartbeat, and write the real one back at
    RenderStep First, the fake value exists only in the gap between the end of
    one frame and the start of the next - which is exactly the window
    replication reads, and is entirely outside the window rendering reads.

        function RootDesync:HeartbeatUpdate()      -- end of frame
            self._oldCFrame = self._rootPart.CFrame  -- remember the truth
            self._rootPart.CFrame = self._cframe     -- lie
        end

        function RootDesync:_RenderStepUpdate()    -- start of next frame
            self._rootPart.CFrame = self._oldCFrame  -- tell the truth again
        end

    The server sees the lie. Your screen never does. Your character does not
    even flicker, because no frame is ever drawn while the lie is in place.

    THE GENERAL IDEA, which is worth far more than this feature: two systems
    reading the same value at different points in a frame can be shown
    different values, and you do not need to hook either of them. You just need
    to know the order things happen in. `../visuals/stretched-resolution.lua`
    uses the same reasoning from the other direction - it binds AFTER the
    camera controller specifically so its write is the one that survives.

===============================================================================
    TRICK TWO: PART GLUE, OR "WHOSE PHYSICS ARE THESE?"
===============================================================================

    Root virtualization moves you. It is not quite enough on its own, because
    you now have to work out where the target will be and put yourself there,
    every frame, against a moving player and a laggy connection.

    So the shipped version does something better. Instead of chasing them, it
    brings both of you to a fixed point:

        1. take the target's HitboxHead, break its weld and anchor it, so
           moving it does not drag their whole body around
        2. teleport that hitbox to a fixed, arbitrary, far-away CFrame
        3. point your own hidden `PhysicsRepRootPart` property at that hitbox

    `PhysicsRepRootPart` is the part Roblox replicates your physics FROM. It is
    normally your HumanoidRootPart and it is not scriptable, which is why this
    needs `sethiddenproperty`. Repoint it and the server stops asking where
    your root is and starts asking where that hitbox is - and the hitbox is at
    the void CFrame, so as far as the server is concerned, so are you.

    Both of you are now at the same point in empty space, from the server's
    perspective, regardless of what either of you is doing in the actual match.
    Every shot is point-blank because there is no distance left to be wrong
    about.

    THE VOID CFRAME is generated once, at random, a hundred thousand studs out:

        local VOID_CFRAME = CFrame.new(
            math.random(-100000, -10000), 100000, math.random(-100000, 10000))

    Far away so nothing is there to collide with or be seen by; random so two
    people running this in the same server do not end up in the same cubic
    metre and start shooting each other by accident.

    NOTE THE `refCount` IN `PartGlue`. Several things can want the same hitbox
    glued at once, and whoever finishes first must not un-anchor it while the
    others are still using it. Counting how many holders there are, and only
    restoring on the last release, is the standard fix - and this file needs it
    more than most, because a hitbox left anchored with its weld broken stays
    broken for the person it belongs to.

===============================================================================
    TRICK THREE: FIRING THE REMOTE YOURSELF
===============================================================================

    With the positions sorted out, the shot is sent by hand rather than by
    pressing the mouse button:

        local inner = { ["\0"] = aim1, ["\1"] = aim2, ["\2"] = hitboxHead,
                        ["\3"] = extra }
        remote:FireServer(objectId, token, { ["\1"] = inner }, nil)

    Two things there are worth stopping on.

    THE KEYS ARE CONTROL CHARACTERS. `"\0"` is a one-character string whose
    character is byte zero. The game's own network format uses these as field
    names because they are one byte instead of eight and nobody types them by
    accident. They are not magic, they are just short names. Slot `"\2"` being
    the hitbox Instance is the important one - that is the game asking "what
    did you hit", and we are answering directly.

    THE TOKEN IS NOT HARDCODED. `enc("StartShooting")` runs the game's own
    `EnumLibrary:ToEnum`, which returns whatever scrambled string this build
    uses for that packet type. It changes between updates; asking the game
    means this keeps working when it does. `../visuals/bullet-tracers.lua`
    reads the same channel from the other side using the same call - worth
    reading, because it is a much gentler introduction to this packet format.

    THE AIM VECTORS ARE DELIBERATELY ABSURD:

        AIM_ABOVE_ORIGIN = { ["\0"] = -math.huge, ["\1"] = 0, ["\2"] = 0 }
        AIM_ABOVE_END    = { ["\0"] = 0, ["\1"] = -90000000, ["\2"] = 0 }

    The server validates a RAY, not a point - it wants a start and an end and
    checks whether the thing you claim to have hit is somewhere along it. So
    you hand it a ray that starts at negative infinity and ends ninety million
    studs away in the other direction. Any point in the universe is on that
    line, including the hitbox you named. The check passes because the check
    was answering a different question than it looked like it was answering.

    That is the whole shape of most server-side validation failures. It is not
    that the check is missing; it is that the check verifies something adjacent
    to the thing you actually wanted verified.

===============================================================================
    ABOVE OR BELOW
===============================================================================

    The Riot Shield blocks damage from the direction its holder is facing. So
    the file picks a side - it approaches from above by default, and from below
    when the target is holding a shield and looking upward:

        OFFSET_ABOVE = Vector3.new(0, -0.7, 0.05)
        OFFSET_BELOW = Vector3.new(0, -3.85, 0.05)

    with the fake aim pitch flipped to match. Shield-less targets, which is
    almost everyone, fold to Above.

===============================================================================
    THREAD IDENTITY
===============================================================================

        local prev = getthreadidentity()
        setthreadidentity(8)
        sethiddenproperty(ourPart, "PhysicsRepRootPart", hitboxPart)
        setthreadidentity(prev)

    Hidden-property writes need elevated permissions. Executors give your
    script thread a high identity to begin with, but calling into the game's
    own functions can leave your thread with a reduced one, and the write then
    fails silently rather than erroring. Setting identity 8 immediately before
    the write, and putting it back straight after, is the reliable pattern.
    Raise it for the one call that needs it, never for the whole script.

===============================================================================
    WHAT THE FULL SCRIPT ADDS ON TOP OF THIS FILE
===============================================================================

    The shipped ragebot is about 1,600 lines. This file is the mechanism -
    root virtualization, part glue, target selection and firing - and it works.
    On top of it, `KiciaHook_Source_Runnable.lua` adds:

    * VIEW-ANGLE DESYNC. Hooks the character joint update and the camera
      replication loop to send a plausible fake camera rotation, so other
      players do not see you standing there staring at a point outside the
      universe.
    * EVASION MODES. Off / Random / ProjectileBreaker / Translocate - what to
      do with your replicated position when there is nothing to shoot. The
      interesting one is ProjectileBreaker, which parks the server-side you
      inside a wall so incoming projectiles collide with geometry first.
    * A MELEE STRATEGY with a real backstab window and cooldown, since melee
      swings are validated differently to bullets.
    * A SPATIAL LIMIT GATE, because the game does have a bounds check and going
      too far outside it gets you removed rather than being useful.
    * FFLAG CHANGES around the physics stepping while it is active.
    * AUTO RESPAWN and OOB BAIT MODE. Bait mode is a
      separate mechanism entirely: it detects other people teleport-hacking by
      watching for impossible position deltas, and parks you where their next
      teleport is predicted to land.

    None of that changes the core, and all of it is readable in the full
    source under the "Kicia Ragebot" heading.

    REQUIREMENTS
    `sethiddenproperty` and `setthreadidentity` are mandatory - without them
    the part glue silently does nothing and you fire from wherever you actually
    are. Most mainstream executors have both. The file checks and refuses to
    start rather than half-working.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Hold this to run. Set to nil to have it run constantly, which is very
    -- much not recommended.
    Key = Enum.KeyCode.LeftAlt,

    -- Seconds between shots. 0 fires every frame, which is the "rage" part.
    FireInterval = 0,

    -- Approach from below instead of above when the target has a shield.
    RespectShields = true,

    Notify = true,
}

--=============================================================================
-- Capability gate
--=============================================================================
-- Both of these are mandatory. Half of this feature working is worse than none
-- of it: you end up firing the combat remote from your real position, which
-- misses and is just as visible.

-- Read through the normal global lookup, not `rawget`. Several executors put
-- their functions behind a metatable on the global table, and a rawget misses
-- those entirely - so the check reports "unsupported" on an executor that
-- supports it perfectly well.
local function capability(name)
    local ok, fn = pcall(function() return (getgenv and getgenv() or _G)[name] end)
    if ok and type(fn) == "function" then return fn end
    ok, fn = pcall(function() return _G[name] end)
    return (ok and type(fn) == "function") and fn or nil
end

local setHidden = capability("sethiddenproperty")
local setIdentity = capability("setthreadidentity")
local getIdentity = capability("getthreadidentity")

if not setHidden or not setIdentity or not getIdentity then
    warn("[Ragebot] Your executor is missing sethiddenproperty or "
        .. "setthreadidentity. This feature cannot work without them and has "
        .. "not been started.")
    return
end

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Ragebot", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__RagebotCleanup then
    pcall(env.__RagebotCleanup)
end

local Token = {}
env.__RagebotToken = Token

--=============================================================================
-- Resolving the game's own pieces
--=============================================================================

local function findChild(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        if not node then return nil end
        node = node:FindFirstChild(name)
    end
    return node
end

local Cache = {}

local function enumLibrary()
    if Cache.EnumLibrary then return Cache.EnumLibrary end
    local module = findChild(ReplicatedStorage, "Modules", "EnumLibrary")
    if not module then return nil end
    local ok, library = pcall(require, module)
    if not ok or type(library) ~= "table" then return nil end
    -- The enum table is built asynchronously. Using it early gives you a nil
    -- token and a packet the server drops without comment.
    if rawget(library, "_enum_builder_complete") ~= true then return nil end
    Cache.EnumLibrary = library
    return library
end

-- The obfuscated token for a packet name. Never hardcode the result of this;
-- it changes with the game build.
local function enc(name)
    local library = enumLibrary()
    if not library or type(library.ToEnum) ~= "function" then return nil end
    local ok, token = pcall(library.ToEnum, library, name)
    return ok and token or nil
end

local function useItemRemote()
    if Cache.UseItem then return Cache.UseItem end
    local remote = findChild(ReplicatedStorage, "Remotes", "Fighter", "UseItem")
        or findChild(ReplicatedStorage, "Remotes", "Replication", "Fighter", "UseItem")
    Cache.UseItem = remote
    return remote
end

local function fighterController()
    if Cache.FighterController then return Cache.FighterController end
    local module = findChild(LocalPlayer, "PlayerScripts", "Controllers", "FighterController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    Cache.FighterController = (ok and type(controller) == "table") and controller or nil
    return Cache.FighterController
end

local function localFighter()
    local controller = fighterController()
    if not controller then return nil end
    local fighter = rawget(controller, "LocalFighter")
    if fighter == nil and type(controller.GetFighter) == "function" then
        local ok, result = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and result or nil
    end
    return type(fighter) == "table" and fighter or nil
end

--=============================================================================
-- The firing payload
--=============================================================================
-- See the header. The keys are single control characters because that is the
-- game's own wire format, and the aim vectors are absurd on purpose.

local AIM_ABOVE_ORIGIN = { ["\0"] = -math.huge, ["\1"] = 0, ["\2"] = 0 }
local AIM_ABOVE_END    = { ["\0"] = 0, ["\1"] = -90000000, ["\2"] = 0 }
local AIM_BELOW_ORIGIN = { ["\0"] = -math.huge, ["\1"] = 0, ["\2"] = 0 }
local AIM_BELOW_END    = { ["\0"] = 0, ["\1"] = 90000000, ["\2"] = 0 }
local AIM_EXTRA        = { ["\0"] = 0, ["\1"] = 1, ["\2"] = 0, ["\3"] = 0,
                           ["\4"] = 0, ["\5"] = 0 }

local OFFSET_ABOVE = Vector3.new(0, -0.7, 0.05)
local OFFSET_BELOW = Vector3.new(0, -3.85, 0.05)
local PITCH_ABOVE = -math.pi / 2
local PITCH_BELOW = math.pi / 2

local function buildAim(base, pitch, oy, oz)
    return {
        ["\0"] = base["\0"], ["\1"] = base["\1"], ["\2"] = base["\2"],
        ["\3"] = pitch, ["\4"] = oy, ["\5"] = oz,
    }
end

local function itemObjectId(item)
    local data = type(item) == "table" and rawget(item, "Data") or nil
    return type(data) == "table" and rawget(data, "ObjectID") or nil
end

local function itemIsRaycast(item)
    local info = type(item) == "table" and rawget(item, "Info") or nil
    if type(info) ~= "table" then return true end
    return rawget(info, "IsRaycast") ~= false
end

local function fireGun(objectId, isRaycast, aim1, aim2, hitboxHead)
    local remote = useItemRemote()
    local token = enc("StartShooting")
    if not remote or not token or not objectId then return end

    -- Slot "\2" is the hitbox we claim to have hit. That is the whole shot.
    local inner = { ["\0"] = aim1, ["\1"] = aim2, ["\2"] = hitboxHead, ["\3"] = AIM_EXTRA }
    local payload = isRaycast and { ["\1"] = inner, ["\2"] = true } or { ["\1"] = inner }
    pcall(function()
        remote:FireServer(objectId, token, payload, nil)
    end)
end

--=============================================================================
-- Root virtualization
--=============================================================================
-- The whole trick, in thirty lines. See the header - the ordering of these two
-- callbacks within a frame is the entire mechanism.

local RootDesync = {}
RootDesync.__index = RootDesync

function RootDesync.new(rootPart)
    local self = setmetatable({
        _rootPart = rootPart,
        _boundId = HttpService:GenerateGUID(false),
        _oldCFrame = rootPart.CFrame,
        _cframe = nil,
    }, RootDesync)

    -- RenderPriority.First is the earliest slot in the frame - before the
    -- camera, before anything draws.
    RunService:BindToRenderStep(self._boundId, Enum.RenderPriority.First.Value, function()
        self:_RenderStepUpdate()
    end)
    return self
end

-- Start of frame: put the truth back before anything can render it.
function RootDesync:_RenderStepUpdate()
    local old = self._oldCFrame
    if old ~= nil then
        self._rootPart.CFrame = old
        self._oldCFrame = nil
    end
end

function RootDesync:SetServerCFrame(cf)
    self._cframe = cf
end

-- End of frame: stash the truth, write the lie, and let replication read it.
function RootDesync:HeartbeatUpdate()
    local cf = self._cframe
    if cf ~= nil then
        self._oldCFrame = self._rootPart.CFrame
        self._rootPart.CFrame = cf
    end
end

function RootDesync:Destroy()
    pcall(function() RunService:UnbindFromRenderStep(self._boundId) end)
    -- If a lie is currently in place, undo it. Skipping this leaves your
    -- character at the void CFrame on your own screen.
    if self._oldCFrame ~= nil and self._rootPart.Parent then
        pcall(function() self._rootPart.CFrame = self._oldCFrame end)
        self._oldCFrame = nil
    end
end

--=============================================================================
-- Part glue
--=============================================================================
-- Generated once, per session, at random. See the header for why both of those
-- matter.

local VOID_CFRAME = CFrame.new(
    math.random(-100000, -10000),
    100000,
    math.random(-100000, 10000)
)

local PartGlue = {}
PartGlue.__index = PartGlue

function PartGlue.new()
    return setmetatable({ _gluedParts = {}, _bindings = {} }, PartGlue)
end

function PartGlue:_SetupGlue(part)
    local entry = self._gluedParts[part]
    if entry ~= nil then
        -- Already held by someone else. Count it and leave the part alone.
        entry.refCount = entry.refCount + 1
        return
    end

    -- Breaking the weld is what stops moving the hitbox from dragging the
    -- target's entire character across the map with it.
    local weld = part:FindFirstChildOfClass("WeldConstraint")
    local originalPart1 = nil
    if weld ~= nil then
        originalPart1 = weld.Part1
        if originalPart1 ~= nil then
            weld.Part1 = nil
        end
        part.Anchored = true
    end

    self._gluedParts[part] = { refCount = 1, weld = weld, originalPart1 = originalPart1 }
end

function PartGlue:_ReleaseGlue(part)
    local entry = self._gluedParts[part]
    if entry == nil then return end

    entry.refCount = entry.refCount - 1
    if entry.refCount > 0 then return end   -- somebody else still needs it

    local weld = entry.weld
    if weld ~= nil and entry.originalPart1 ~= nil then
        weld.Part1 = entry.originalPart1
        entry.originalPart1.Anchored = false
    end
    self._gluedParts[part] = nil
end

function PartGlue:Acquire(ourPart, hitboxPart)
    -- Raise identity for exactly one call. See the header.
    local prev = getIdentity()
    setIdentity(8)
    pcall(setHidden, ourPart, "PhysicsRepRootPart", hitboxPart)
    setIdentity(prev)

    local bound = self._bindings[ourPart]
    if bound ~= hitboxPart then
        if bound ~= nil then
            self:_ReleaseGlue(bound)
        end
        self:_SetupGlue(hitboxPart)
        self._bindings[ourPart] = hitboxPart
    end

    hitboxPart.CFrame = CFrame.new(VOID_CFRAME.Position)
    return VOID_CFRAME
end

function PartGlue:Free(ourPart)
    local bound = self._bindings[ourPart]
    if bound == nil then return end

    self._bindings[ourPart] = nil
    self:_ReleaseGlue(bound)

    local prev = getIdentity()
    setIdentity(8)
    pcall(setHidden, ourPart, "PhysicsRepRootPart", nil)
    setIdentity(prev)
end

-- Unconditional restore. If this does not run, somebody else's hitbox stays
-- anchored with a broken weld and their character stops working properly -
-- so this is called from cleanup, from a lost target, and from an error.
function PartGlue:Destroy()
    for _, entry in pairs(self._gluedParts) do
        local weld = entry.weld
        if weld ~= nil and entry.originalPart1 ~= nil then
            pcall(function()
                weld.Part1 = entry.originalPart1
                entry.originalPart1.Anchored = false
            end)
        end
    end
    table.clear(self._gluedParts)
    table.clear(self._bindings)
end

--=============================================================================
-- Targets
--=============================================================================

local function isEnemyPlayer(player)
    if player == nil or player == LocalPlayer then return false end
    local ourTeam = LocalPlayer.Team
    return ourTeam == nil or player.Team ~= ourTeam
end

local function collectEnemies()
    local out = {}
    local controller = fighterController()
    local objects = controller and rawget(controller, "Objects") or nil
    if type(objects) ~= "table" then return out end

    for _, fighter in ipairs(objects) do
        local ok, entry = pcall(function()
            local player = rawget(fighter, "Player")
            local entity = rawget(fighter, "Entity")
            local model = entity and rawget(entity, "Model") or nil
            if not model then return nil end
            if player ~= nil and not isEnemyPlayer(player) then return nil end

            -- HitboxHead is the part the server checks shots against. Note we
            -- want the HITBOX, not the visible head - they are different parts
            -- and only one of them counts.
            local hitboxHead = model:FindFirstChild("HitboxHead")
            local hitboxBody = model:FindFirstChild("HitboxBody")
            local rootPart = model:FindFirstChild("HumanoidRootPart") or hitboxBody
            if not (hitboxHead and rootPart) then return nil end

            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local data = entity and rawget(entity, "Data") or nil

            return {
                player = player,
                model = model,
                hitboxHead = hitboxHead,
                rootPart = rootPart,
                itemObserver = rawget(fighter, "itemObserver") or rawget(fighter, "ItemObserver"),
                alive = humanoid == nil or humanoid.Health > 0,
                -- Spawn protection. Firing at an invincible target just
                -- announces you for nothing.
                invincible = type(data) == "table" and rawget(data, "IsInvincible") == true,
            }
        end)
        if ok and entry then
            out[#out + 1] = entry
        end
    end
    return out
end

local function selectTarget()
    for _, entry in ipairs(collectEnemies()) do
        if entry.alive and not entry.invincible then
            return entry
        end
    end
    return nil
end

-- Riot Shields block from the front, so approach from whichever side they are
-- not looking. Shield-less targets - almost everyone - fold to Above.
local function isAbove(target)
    if not CONFIG.RespectShields then return true end
    local observer = target and target.itemObserver
    if not observer then return true end

    local ok, result = pcall(function()
        local equipped = observer:GetEquippedItem()
        if equipped ~= nil and equipped.name == "Riot Shield" then
            local pitch = math.deg(target:GetCameraRotation().X)
            if pitch > 22 and pitch < 91 then return "Below" end
            return "Above"
        end
        return "None"
    end)
    return not (ok and result == "Below")
end

--=============================================================================
-- The loop
--=============================================================================

local State = {
    Desync = nil,
    Glue = PartGlue.new(),
    RootPart = nil,
    LastFireAt = 0,
    GluedOurPart = nil,
}

local function releaseGlue()
    if State.GluedOurPart then
        State.Glue:Free(State.GluedOurPart)
        State.GluedOurPart = nil
    end
end

local function teardownDesync()
    if State.Desync then
        State.Desync:Destroy()
        State.Desync = nil
    end
    State.RootPart = nil
end

local function isHeld()
    if CONFIG.Key == nil then return true end
    return UserInputService:IsKeyDown(CONFIG.Key)
end

local function step(deltaTime)
    if not CONFIG.Enabled or not isHeld() then
        releaseGlue()
        teardownDesync()
        return
    end

    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart") or nil
    local humanoid = character and character:FindFirstChildOfClass("Humanoid") or nil
    if not rootPart or not humanoid or humanoid.Health <= 0 then
        releaseGlue()
        teardownDesync()
        return
    end

    -- Respawned: the old desync is bound to a part that no longer exists.
    if State.RootPart ~= rootPart then
        teardownDesync()
        State.RootPart = rootPart
        State.Desync = RootDesync.new(rootPart)
    end

    local target = selectTarget()
    if not target then
        releaseGlue()
        State.Desync:SetServerCFrame(nil)
        return
    end

    -- Glue their hitbox to the void and repoint our physics at it.
    local void = State.Glue:Acquire(rootPart, target.hitboxHead)
    State.GluedOurPart = rootPart

    local above = isAbove(target)
    local offset = above and OFFSET_ABOVE or OFFSET_BELOW
    local serverCFrame
    if above then
        serverCFrame = void + offset
    else
        serverCFrame = CFrame.new(void.Position + offset, target.hitboxHead.Position)
    end
    State.Desync:SetServerCFrame(serverCFrame)

    -- Fire.
    local now = os.clock()
    if now - State.LastFireAt < CONFIG.FireInterval then return end
    State.LastFireAt = now

    local fighter = localFighter()
    local item = type(fighter) == "table" and rawget(fighter, "EquippedItem") or nil
    local objectId = itemObjectId(item)
    if not objectId then return end

    -- The target's own yaw/roll go into the fake aim so the numbers at least
    -- describe a rotation that could exist.
    local _, oy, oz = target.rootPart.CFrame:ToOrientation()
    local pitch = above and PITCH_ABOVE or PITCH_BELOW
    local aim1 = buildAim(above and AIM_ABOVE_ORIGIN or AIM_BELOW_ORIGIN, pitch, oy, oz)
    local aim2 = buildAim(above and AIM_ABOVE_END or AIM_BELOW_END, pitch, oy, oz)

    fireGun(objectId, itemIsRaycast(item), aim1, aim2, target.hitboxHead)
end

local heartbeat
heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    if env.__RagebotToken ~= Token then
        heartbeat:Disconnect()
        return
    end

    local ok, err = pcall(step, deltaTime)
    if not ok then
        warn("[Ragebot] " .. tostring(err))
        -- An error mid-glue would otherwise leave somebody's hitbox anchored.
        pcall(releaseGlue)
    end

    -- Always last in the frame, and always after step() has decided what the
    -- server CFrame should be. This is the write the server reads.
    if State.Desync then
        pcall(function() State.Desync:HeartbeatUpdate() end)
    end
end)

notify(CONFIG.Key and ("hold " .. CONFIG.Key.Name) or "active")

--=============================================================================
-- Cleanup
--=============================================================================

env.__RagebotCleanup = function()
    env.__RagebotToken = nil
    if heartbeat then heartbeat:Disconnect() end
    releaseGlue()
    State.Glue:Destroy()      -- unconditional; see PartGlue:Destroy
    teardownDesync()
    env.__RagebotCleanup = nil
end