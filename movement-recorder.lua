--[[============================================================================
    MOVEMENT RECORDER  -  record a route, then have the game walk it for you
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Press one key and it starts writing down everything you do - where you are
    looking, which way you are moving, when you jump, crouch, slide, swap
    weapon or fire. Press it again to stop. Press the other key and your
    character does the whole thing again by itself, at the same speed, from the
    same spot.

    The obvious use is a rush route off spawn: walk the fastest path to a
    strong position once, save it, and then take it perfectly every round
    without thinking about it.

    This is the biggest single feature in the project and easily the most
    interesting one to read, because almost none of it is about cheating. It is
    about recording a stream of events accurately and replaying it into a world
    that will not be in exactly the same state as when you recorded it.

===============================================================================
    IT IS NOT A VIDEO. IT IS AN INPUT LOG.
===============================================================================

    The naive design is to save your position and rotation every frame and then
    force the character back through those positions on playback. It is easy to
    write, and everything about it is bad: the file is enormous, the movement
    is a slideshow at any framerate but the one you recorded at, you clip
    through geometry because nothing is simulating physics any more, and the
    server sees a character teleporting in tiny steps.

    What this records instead is what you PRESSED:

        Move    the direction you were holding, whenever it changed
        Look    where the camera was pointing, whenever it moved
        Jump    Crouch    Slide
        Equip   which weapon slot you switched to
        ItemInput   fire down, fire up, aim down, reload, and so on

    Playback feeds those back into the game's own movement code. The game does
    the walking, the jumping, the collision, the animation, the acceleration
    curve - all of it - exactly as if a person were holding the keys. Everything
    comes out right for free, including the parts you never thought about.

    And it is small. A minute of running turns into a few hundred entries,
    because a Move is only written down when the direction CHANGES:

        if moveVector ~= active.LastMoveVector then
            active.LastMoveVector = moveVector
            recordAction({ kind = "Move", direction = moveVector })
        end

    Sixty frames of holding W is one entry, not sixty. Record transitions, not
    states - it is worth a lot more than the storage it saves, because a log of
    changes is something you can read and reason about and a log of states is
    not.

===============================================================================
    THE THING THAT MAKES RECORDINGS REUSABLE: MAP-RELATIVE COORDINATES
===============================================================================

    Nothing here is stored in world coordinates. Every position and every
    camera CFrame is stored relative to the map model's pivot:

        local anchorInverse = mapModel:GetPivot():Inverse()
        startCFrame = anchorInverse * rootPart.CFrame     -- saving
        worldPosition = mapAnchor * savedPosition          -- loading

    RIVALS builds each round's map fresh, and it does not land in the same
    place in the world every time. A recording saved in world coordinates works
    for exactly one round and is then quietly, confusingly wrong - your
    character sprints off toward a spot two hundred studs from anything.

    Multiplying by the inverse of the pivot converts world space into "space
    measured from the map's own origin", and multiplying by the pivot converts
    it back. Store it relative, restore it absolute.

    Use this any time you save a position that belongs to something that can
    move: a map, a vehicle, a moving platform, a rig. The question to ask is
    always "relative to what?", and the answer is almost never "the world".

===============================================================================
    REPLAY HAPPENS IN TWO PHASES
===============================================================================

    You cannot just start playing the log back, because you are not standing
    where you were when you recorded it. Two studs off and one jump lands you
    somewhere else entirely; ten degrees off and the whole route is rotated.

    PHASE ONE - ALIGNING. Walk to the recorded start position and turn the
    camera to the recorded start look. Note that it WALKS there, using the same
    `Humanoid:Move` everything else uses - it does not teleport, because a
    teleport is the one thing here the server would notice.

        local difference = targetPosition - rootPart.Position
        local planar = Vector3.new(difference.X, 0, difference.Z)
        humanoid:Move(planar.Unit, false)

    Y is dropped. You cannot walk upward, and including it makes the direction
    wrong whenever there is any height difference at all.

    PHASE TWO - PLAYING. Run the log.

    THE STUCK DETECTOR
    Aligning can fail. There may be a crate where you were standing, or another
    player, or the geometry may simply have changed. So it tracks the best
    distance it has ever achieved and gives up trying to improve on it:

        if distance < replay.BestDistance - 0.1 then
            replay.BestDistance = distance      -- still making progress
            replay.StuckTime = 0
        else
            replay.StuckTime = replay.StuckTime + deltaTime
        end

        local aligned = (snapped and lookIsAligned) or replay.StuckTime >= 1

    One second of not getting any closer and it starts anyway, slightly out of
    position, which is far better than standing against a wall forever. Any
    loop that waits for a physical condition needs one of these. The 0.1 stud
    margin is there so that jitter does not read as progress.

===============================================================================
    TWO STREAMS: WHAT YOU DID, AND WHERE IT PUT YOU
===============================================================================

    A recording holds two separate timelines.

        keypoints   the actions, written the moment they happen
        positions   where you actually were, sampled ten times a second

    Playback is driven entirely by `keypoints`. `positions` is never played
    back - it exists only to check the replay is going right.

    The inputs are the program; the positions are the assertions. If replaying the inputs puts you
    somewhere the positions say you should not be, something has gone wrong -
    somebody body-blocked you, a door was shut, you got shot - and continuing
    would just have your character sprint into a wall for another minute.

        if (expectedWorldPosition - rootPart.Position).Magnitude > 15 then
            stopReplay("Diverged")
        end

    `expected` is interpolated between the two position samples on either side
    of the current time, so the check is smooth rather than stepping ten times
    a second. Note how the samples are walked:

        while PositionIndex < #positions
            and positions[PositionIndex + 1].offset <= offset do
            PositionIndex = PositionIndex + 1
        end

    The index only ever moves forward, so this costs nothing per frame even
    with thousands of samples. Searching the whole list every frame would work
    and would be the thing you notice at the top of a profile later. Any time
    you walk a sorted timeline in order, keep the cursor.

===============================================================================
    TWO NUMERICAL DETAILS THAT ARE EASY TO GET WRONG
===============================================================================

    YAW WRAPPING. Camera yaw runs from -pi to +pi and jumps between them. Turn
    from +179 degrees to -179 and the naive difference is -358 degrees, so a
    two-degree turn becomes a full spin the wrong way. Every angle difference
    in this file goes through:

        local function wrapAngle(value)
            return (value + math.pi) % (2 * math.pi) - math.pi
        end

    which folds any difference back into -pi..+pi, i.e. into "the short way
    round". `../combat/aimbot.lua` hits the same problem and solves it the same
    way; it is the single most common bug in anything that turns a camera.

    FRAME-RATE INDEPENDENT SMOOTHING. The obvious way to ease toward a target
    is `current = current + (target - current) * 0.2`. That is wrong, and it is
    wrong in a way that only shows up on somebody else's machine: at 240 fps it
    runs four times as often as at 60, so the camera turns four times faster.

        local alpha = 1 - math.exp(-deltaTime / tau)

    This is the same easing expressed as a time constant. `tau` is roughly how
    long it takes to close most of the gap, in seconds, and the result is
    identical at any framerate. Use it any time you lerp toward something over
    time - it costs one `exp` and it is simply correct.

    While reading, notice `math.clamp(deltaTime, 0, 0.1)` in the update. Alt-tab
    for two seconds and the next frame's delta is two seconds; without the
    clamp the replay fires two seconds of keypoints in a single frame and
    launches your character across the map. Clamp every deltaTime you integrate.

===============================================================================
    GIVING THE CONTROLS BACK
===============================================================================

    Replay disables Roblox's default control module, or your WASD would fight
    the playback. Note what it remembers before doing so:

        local controlsWereEnabled = ...
        if controlsWereEnabled and controls.Enable then controls:Enable() end

    If something else had already disabled your controls - a cutscene, a menu,
    the game itself - then re-enabling them on the way out hands you movement
    at a moment the game had deliberately taken it away. Never restore a state
    you did not observe. It is the same snapshot rule as
    `../visuals/model-chams-and-highlight.lua`, applied to a setting rather
    than a property.

===============================================================================
    NOT IN THIS FILE
===============================================================================

    The full script also draws a floating marker in the world at the start of
    every saved route for the current map, so you can see where they begin and
    activate the nearest one by walking up to it. That is around 180 lines of
    BillboardGui plumbing that only makes sense once you have a library of
    routes and a menu to pick from, so it is left out here. Nothing else is
    missing - recording, saving, loading and replay are complete.

    REQUIREMENTS
    `writefile` / `readfile` / `isfile` to save recordings between sessions.
    Without them everything still works; recordings just live in memory and are
    gone when you leave.

============================================================================--]]

local CONFIG = {
    -- Tap to start recording; tap again to stop and save.
    RecordKey = Enum.KeyCode.LeftBracket,
    -- Tap to replay the recording named below; tap again to abort.
    ReplayKey = Enum.KeyCode.RightBracket,

    -- What a new recording is saved as. Change it before recording a second
    -- route, or the first one is overwritten. Recordings are stored per map.
    RecordingName = "route1",

    SavePath = "KiciaHook/RIVALS Movement Recordings.json",

    -- How close to the recorded start position counts as arrived, in studs.
    AlignTolerance = 0.2,
    -- Maximum camera turn rate while aligning, in degrees per second.
    TurnSpeed = 180,
    -- Camera smoothing, 0-100. Higher is smoother and slower to settle.
    CameraSmoothing = 35,
    -- Abort the replay if you end up this far from where the recording says
    -- you should be, in studs.
    DivergenceLimit = 15,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Movement Recorder", Text = text, Duration = 3,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__MovementRecorderCleanup then
    pcall(env.__MovementRecorderCleanup)
end

local Token = {}
env.__MovementRecorderToken = Token

local State = {
    Mode = "Idle",          -- Idle | Recording | Aligning | Playing
    Recording = nil,        -- live recording session
    Replay = nil,           -- live replay session
    Records = {},           -- mapName -> recordingName -> recording
    Loaded = false,

    InputConnections = {},

    -- Game modules, resolved once and cached.
    PlayerControls = nil,
    InputLibrary = nil,
    MechanicsController = nil,
    FighterController = nil,
}

--=============================================================================
-- Resolving the game's own modules
--=============================================================================
-- These are all already loaded by the game; `require` hands back the existing
-- copy rather than running them again.

local function requireChild(parent, name)
    local module = parent and parent:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    return (ok and type(result) == "table") and result or nil
end

local function controllers()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    return playerScripts and playerScripts:FindFirstChild("Controllers") or nil
end

local function resolveDependencies()
    if not State.PlayerControls then
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local playerModule = requireChild(playerScripts, "PlayerModule")
        if playerModule and type(playerModule.GetControls) == "function" then
            local ok, controls = pcall(playerModule.GetControls, playerModule)
            State.PlayerControls = ok and controls or nil
        end
    end
    if not State.InputLibrary then
        State.InputLibrary = requireChild(ReplicatedStorage:FindFirstChild("Modules"), "InputLibrary")
    end
    if not State.MechanicsController then
        State.MechanicsController = requireChild(controllers(), "MechanicsController")
    end
    if not State.FighterController then
        State.FighterController = requireChild(controllers(), "FighterController")
    end
    -- Controls and the input library are the two we genuinely cannot work
    -- without; the mechanics controller only costs us jump/crouch/slide.
    return State.PlayerControls ~= nil and State.InputLibrary ~= nil
end

local function localFighter()
    local controller = State.FighterController
    if not controller then return nil end
    local fighter = rawget(controller, "LocalFighter")
    if fighter == nil and type(controller.GetFighter) == "function" then
        local ok, result = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and result or nil
    end
    return type(fighter) == "table" and fighter or nil
end

local function equippedItem(fighter)
    return type(fighter) == "table" and rawget(fighter, "EquippedItem") or nil
end

-- Which loadout slot an item sits in. The item usually knows; if it does not,
-- find it by walking the fighter's own list.
local function itemIndex(item, fighter)
    local data = type(item) == "table" and rawget(item, "Data") or nil
    local index = type(data) == "table" and tonumber(rawget(data, "ItemIndex")) or nil
    if index then return index end
    for slot, candidate in ipairs(type(fighter) == "table" and rawget(fighter, "Items") or {}) do
        if candidate == item then return slot end
    end
    return nil
end

local function itemName(item)
    if type(item) ~= "table" then return nil end
    local name = rawget(item, "Name")
    if type(name) == "string" and name ~= "" then return name end
    local data = rawget(item, "Data")
    name = type(data) == "table" and rawget(data, "Name") or nil
    return (type(name) == "string" and name ~= "") and name or nil
end

--=============================================================================
-- Map context
--=============================================================================
-- Everything a recording needs to be meaningful: your character, the map model
-- it happened in, and that map's pivot to measure from.

local function resolveMapContext()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid") or nil
    local rootPart = character and character:FindFirstChild("HumanoidRootPart") or nil
    if not character or not humanoid or humanoid.Health <= 0 or not rootPart then
        return nil
    end

    -- Every round runs in an "environment"; the tag below is how the game
    -- itself finds the geometry belonging to yours.
    local environmentId = character:GetAttribute("EnvironmentID")
    if environmentId == nil then
        local fighter = localFighter()
        local data = type(fighter) == "table" and rawget(fighter, "Data") or nil
        environmentId = type(data) == "table" and rawget(data, "EnvironmentID") or nil
    end
    if environmentId == nil then return nil end

    local tagged = CollectionService:GetTagged("RaycastWhitelist" .. tostring(environmentId))
    local mapModel = tagged[1]
    -- The tag lands on some part inside the map; walk up to the model itself.
    while mapModel and mapModel ~= Workspace
        and not (mapModel:IsA("Model") or mapModel:GetAttribute("EnvironmentID") == environmentId) do
        mapModel = mapModel.Parent
    end
    if not mapModel or mapModel == Workspace or not mapModel:IsA("PVInstance") then
        return nil
    end

    -- The map's display name, so recordings can be filed under it. Three
    -- sources, in decreasing order of trustworthiness.
    local mapName
    local duelController = requireChild(controllers(), "DuelController")
    local duel = duelController and rawget(duelController, "CurrentObject") or nil
    if duel and type(duel.GetMapName) == "function" then
        local ok, value = pcall(duel.GetMapName, duel)
        mapName = (ok and type(value) == "string" and value ~= "") and value or nil
    end
    if not mapName then
        for _, attribute in ipairs({ "MapName", "MatchMap" }) do
            local value = Workspace:GetAttribute(attribute)
            if type(value) == "string" and value ~= "" then
                mapName = value
                break
            end
        end
    end
    mapName = mapName or mapModel.Name

    return {
        Character = character,
        Humanoid = humanoid,
        RootPart = rootPart,
        MapModel = mapModel,
        MapAnchor = mapModel:GetPivot(),   -- everything is measured from here
        MapName = mapName,
    }
end

local function isRoundActive()
    local fighter = localFighter()
    local data = type(fighter) == "table" and rawget(fighter, "Data") or nil
    if type(data) == "table" and rawget(data, "IsInShootingRange") == true then
        return true
    end
    return resolveMapContext() ~= nil
end

--=============================================================================
-- Encoding, so a recording can live in a JSON file
--=============================================================================
-- JSON has numbers, strings, booleans, arrays and objects. It does not have
-- Vector3 or CFrame, so those become arrays of numbers on the way out and are
-- rebuilt on the way in. Every decode is written to return nil rather than
-- error, because a file on disk can be anything at all.

local function encodeVector3(value)
    return { value.X, value.Y, value.Z }
end

local function decodeVector3(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
    if not x or not y or not z then return nil end
    return Vector3.new(x, y, z)
end

-- A CFrame is twelve numbers: three of position and a nine-number rotation
-- matrix. GetComponents hands them over in exactly the order CFrame.new wants
-- them back.
local function encodeCFrame(value)
    return { value:GetComponents() }
end

local function decodeCFrame(value)
    if type(value) ~= "table" or #value ~= 12 then return nil end
    local components = table.create(12)
    for index = 1, 12 do
        components[index] = tonumber(value[index])
        if components[index] == nil then return nil end
    end
    return CFrame.new(table.unpack(components))
end

local function encodeAction(action)
    local encoded = { kind = action.kind }
    if action.kind == "Move" then
        encoded.direction = encodeVector3(action.direction)
    elseif action.kind == "Look" then
        encoded.cframe = encodeCFrame(action.cframe)
    elseif action.kind == "Equip" then
        encoded.index = action.index
    elseif action.kind == "ItemInput" then
        encoded.inputType = action.inputType
    elseif action.kind == "QuickAttack" then
        encoded.attackType = action.attackType
    elseif action.kind == "Crouch" then
        encoded.crouching = action.crouching and true or false
    end
    return encoded
end

local function decodeAction(action)
    if type(action) ~= "table" or type(action.kind) ~= "string" then return nil end
    local decoded = { kind = action.kind }
    if action.kind == "Move" then
        decoded.direction = decodeVector3(action.direction)
        if not decoded.direction then return nil end
    elseif action.kind == "Look" then
        decoded.cframe = decodeCFrame(action.cframe)
        if not decoded.cframe then return nil end
    elseif action.kind == "Equip" then
        decoded.index = tonumber(action.index)
        if not decoded.index then return nil end
    elseif action.kind == "ItemInput" then
        if type(action.inputType) ~= "string" then return nil end
        decoded.inputType = action.inputType
    elseif action.kind == "QuickAttack" then
        if type(action.attackType) ~= "string" then return nil end
        decoded.attackType = action.attackType
    elseif action.kind == "Crouch" then
        decoded.crouching = action.crouching == true
    end
    return decoded
end

local function encodeRecording(recording)
    local encoded = {
        mapName = recording.mapName,
        startCFrame = encodeCFrame(recording.startCFrame),
        startEquippedIndex = recording.startEquippedIndex,
        loadoutRequirements = {},
        keypoints = {},
        positions = {},
    }
    for name in pairs(recording.loadoutRequirements or {}) do
        table.insert(encoded.loadoutRequirements, name)
    end
    for _, keypoint in ipairs(recording.keypoints) do
        table.insert(encoded.keypoints, {
            offset = keypoint.offset,
            action = encodeAction(keypoint.action),
        })
    end
    for _, sample in ipairs(recording.positions) do
        table.insert(encoded.positions, {
            offset = sample.offset,
            position = encodeVector3(sample.position),
        })
    end
    return encoded
end

local function decodeRecording(encoded)
    if type(encoded) ~= "table" then return nil end
    local startCFrame = decodeCFrame(encoded.startCFrame)
    if type(encoded.mapName) ~= "string" or not startCFrame then return nil end

    local recording = {
        mapName = encoded.mapName,
        startCFrame = startCFrame,
        startEquippedIndex = tonumber(encoded.startEquippedIndex),
        loadoutRequirements = {},
        keypoints = {},
        positions = {},
    }
    for _, name in ipairs(encoded.loadoutRequirements or {}) do
        if type(name) == "string" then
            recording.loadoutRequirements[name] = true
        end
    end
    for _, keypoint in ipairs(encoded.keypoints or {}) do
        local action = decodeAction(keypoint.action)
        local offset = tonumber(keypoint.offset)
        -- One unreadable entry is skipped rather than failing the whole file.
        if action and offset then
            table.insert(recording.keypoints, { offset = offset, action = action })
        end
    end
    for _, sample in ipairs(encoded.positions or {}) do
        local position = decodeVector3(sample.position)
        local offset = tonumber(sample.offset)
        if position and offset then
            table.insert(recording.positions, { offset = offset, position = position })
        end
    end
    if #recording.keypoints == 0 then return nil end
    return recording
end

--=============================================================================
-- Persistence
--=============================================================================

local function canWriteFiles()
    return type(writefile) == "function" and type(readfile) == "function"
        and type(isfile) == "function"
end

local function loadPersistence()
    if State.Loaded then return end
    State.Loaded = true
    if not canWriteFiles() or not isfile(CONFIG.SavePath) then return end

    local ok, raw = pcall(readfile, CONFIG.SavePath)
    if not ok then return end
    local decodedOk, payload = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decodedOk or type(payload) ~= "table" then return end

    for mapName, byName in pairs(payload) do
        if type(byName) == "table" then
            State.Records[mapName] = State.Records[mapName] or {}
            for name, encoded in pairs(byName) do
                local recording = decodeRecording(encoded)
                if recording then
                    State.Records[mapName][name] = recording
                end
            end
        end
    end
end

local function writePersistence()
    if not canWriteFiles() then return end
    local payload = {}
    for mapName, byName in pairs(State.Records) do
        payload[mapName] = {}
        for name, recording in pairs(byName) do
            payload[mapName][name] = encodeRecording(recording)
        end
    end
    local ok, raw = pcall(HttpService.JSONEncode, HttpService, payload)
    if not ok then return end
    -- The folder may not exist on a fresh executor install.
    if type(makefolder) == "function" then
        local folder = CONFIG.SavePath:match("^(.*)/[^/]*$")
        if folder then pcall(makefolder, folder) end
    end
    pcall(writefile, CONFIG.SavePath, raw)
end

--=============================================================================
-- Recording
--=============================================================================

local function recordingOffset()
    local active = State.Recording
    return active and math.max(0, os.clock() - active.StartTime) or 0
end

local function recordAction(action)
    local active = State.Recording
    if not active then return end
    table.insert(active.Data.keypoints, { offset = recordingOffset(), action = action })
end

-- If the recording never actually USED the weapon you happened to be holding
-- when you hit record, do not make the replay wait for it. Requirements should
-- be the minimum that makes the route work, or a perfectly good recording
-- refuses to run with a slightly different loadout.
local function discardUnusedStartItem()
    local active = State.Recording
    if not active or active.StartItemUsed or active.Data.startEquippedIndex == nil then
        return
    end
    active.Data.startEquippedIndex = nil
end

local function recordItemInput(inputType)
    local active = State.Recording
    if not active then return end

    local fighter = localFighter()
    local item = equippedItem(fighter)
    local name = itemName(item)
    if name then
        active.Data.loadoutRequirements[name] = true
    end
    if itemIndex(item, fighter) == active.StartItemIndex then
        active.StartItemUsed = true
    end
    recordAction({ kind = "ItemInput", inputType = inputType })
end

-- The game's input library knows which physical key currently means "Jump",
-- including rebinds and controller buttons. Asking it is the only way to get
-- this right for everybody.
local function inputMatches(input, inputName)
    local library = State.InputLibrary
    if not library or type(library.InputIs) ~= "function" then return false end
    local ok, matches = pcall(library.InputIs, library, input, inputName)
    return ok and matches == true
end

local function handleInput(input, gameProcessed, began)
    -- gameProcessed means the click went to a text box or a button. Recording
    -- it would replay a shot every time you typed in chat.
    if State.Mode ~= "Recording" or gameProcessed then return end

    if began and inputMatches(input, "Jump") then
        recordAction({ kind = "Jump" })
        return
    end
    if began and inputMatches(input, "QuickMelee") then
        recordAction({ kind = "QuickAttack", attackType = "Melee" })
        return
    end
    if began and inputMatches(input, "QuickUtility") then
        recordAction({ kind = "QuickAttack", attackType = "Utility" })
        return
    end

    -- Everything the equipped item responds to - fire, aim, reload - is
    -- enumerated by the library, with a name for the press and one for the
    -- release. We do not need to know what any of them are.
    local library = State.InputLibrary
    for _, inputName in ipairs(type(library) == "table" and library.ItemInputs or {}) do
        local definition = type(library.Inputs) == "table" and library.Inputs[inputName] or nil
        if definition and inputMatches(input, inputName) then
            local inputType = began and definition.StartName or definition.FinishName
            if type(inputType) == "string" then
                recordItemInput(inputType)
            end
            return
        end
    end
end

local function disconnectRecordingInputs()
    for _, connection in ipairs(State.InputConnections) do
        connection:Disconnect()
    end
    State.InputConnections = {}
end

local function connectRecordingInputs()
    disconnectRecordingInputs()
    State.InputConnections = {
        UserInputService.InputBegan:Connect(function(input, gameProcessed)
            handleInput(input, gameProcessed, true)
        end),
        UserInputService.InputEnded:Connect(function(input, gameProcessed)
            handleInput(input, gameProcessed, false)
        end),
    }
end

-- Called every frame while recording. Everything in here is a
-- compare-with-last-value: an entry is only written when something changed.
local function sampleRecording()
    local active = State.Recording
    if not active then return end

    -- Movement direction, straight from the control module. This is already
    -- camera-relative, which is why playback passes `true` to Humanoid:Move.
    local controls = State.PlayerControls
    local moveVector = Vector3.zero
    if controls and type(controls.GetMoveVector) == "function" then
        local ok, value = pcall(controls.GetMoveVector, controls)
        if ok and typeof(value) == "Vector3" then
            moveVector = value
        end
    end
    if moveVector ~= active.LastMoveVector then
        active.LastMoveVector = moveVector
        recordAction({ kind = "Move", direction = moveVector })
    end

    -- Camera. Stored map-relative, like everything else.
    local camera = Workspace.CurrentCamera
    if camera then
        local pitch, yaw = camera.CFrame:ToOrientation()
        local rotation = Vector2.new(pitch, yaw)
        -- A small threshold rather than an equality test: the camera drifts by
        -- fractions of a degree constantly, and without this every single
        -- frame produces a keypoint.
        if (rotation - active.LastCameraRotation).Magnitude > 0.0001 then
            active.LastCameraRotation = rotation
            recordAction({
                kind = "Look",
                cframe = active.AnchorInverse * CFrame.fromOrientation(pitch, yaw, 0),
            })
        end
    end

    local fighter = localFighter()
    local index = itemIndex(equippedItem(fighter), fighter)
    if index ~= active.LastEquippedIndex then
        active.LastEquippedIndex = index
        discardUnusedStartItem()
        if index ~= nil then
            recordAction({ kind = "Equip", index = index })
        end
    end

    -- Crouch and slide are states the mechanics controller exposes rather than
    -- inputs, so they are polled rather than caught from the keyboard.
    local mechanics = State.MechanicsController
    local crouching = mechanics and rawget(mechanics, "IsCrouching") == true or false
    if crouching ~= active.LastCrouching then
        active.LastCrouching = crouching
        recordAction({ kind = "Crouch", crouching = crouching })
    end
    local sliding = mechanics and rawget(mechanics, "IsSliding") == true or false
    if sliding ~= active.LastSliding then
        active.LastSliding = sliding
        -- Only the start is recorded; a slide ends itself.
        if sliding then
            recordAction({ kind = "Slide" })
        end
    end

    -- The second stream. Ten times a second is plenty to catch a replay
    -- wandering off, and it keeps the file small. See the header.
    local now = os.clock()
    if now - active.LastPositionSampleTime >= 0.1 then
        active.LastPositionSampleTime = now
        table.insert(active.Data.positions, {
            offset = recordingOffset(),
            position = active.AnchorInverse * active.RootPart.Position,
        })
    end
end

local function startRecording()
    local context = resolveMapContext()
    if not context or not resolveDependencies() then
        notify("You need to be alive and in a match")
        return false
    end
    if State.Mode ~= "Idle" then
        notify(State.Mode == "Recording" and "Already recording" or "Can't record while replaying")
        return false
    end

    local fighter = localFighter()
    local index = itemIndex(equippedItem(fighter), fighter)
    local camera = Workspace.CurrentCamera
    local pitch, yaw = 0, 0
    if camera then
        pitch, yaw = camera.CFrame:ToOrientation()
    end

    local anchorInverse = context.MapAnchor:Inverse()

    State.Recording = {
        Data = {
            mapName = context.MapName,
            startCFrame = anchorInverse * context.RootPart.CFrame,
            startEquippedIndex = index,
            -- The first keypoint is always a Look, so the replay knows which
            -- way to face before it starts.
            keypoints = {{
                offset = 0,
                action = {
                    kind = "Look",
                    cframe = anchorInverse * CFrame.fromOrientation(pitch, yaw, 0),
                },
            }},
            loadoutRequirements = {},
            positions = {},
        },
        AnchorInverse = anchorInverse,
        RootPart = context.RootPart,
        Character = context.Character,
        StartTime = os.clock(),
        StartItemIndex = index,
        StartItemUsed = false,
        LastMoveVector = Vector3.zero,
        LastCameraRotation = Vector2.new(pitch, yaw),
        LastEquippedIndex = index,
        LastCrouching = false,
        LastSliding = false,
        LastPositionSampleTime = 0,
    }

    State.Mode = "Recording"
    connectRecordingInputs()
    sampleRecording()
    notify("Now recording")
    return true
end

local function stopRecording(save)
    if State.Mode ~= "Recording" or not State.Recording then return end

    sampleRecording()          -- catch whatever changed since the last frame
    discardUnusedStartItem()

    local data = State.Recording.Data
    disconnectRecordingInputs()
    State.Recording = nil
    State.Mode = "Idle"

    if save then
        State.Records[data.mapName] = State.Records[data.mapName] or {}
        State.Records[data.mapName][CONFIG.RecordingName] = data
        writePersistence()
        notify(("Saved '%s' on %s (%d actions)"):format(
            CONFIG.RecordingName, data.mapName, #data.keypoints))
    else
        notify("Recording stopped")
    end
end

--=============================================================================
-- Replay
--=============================================================================

local function wrapAngle(value)
    return (value + math.pi) % (2 * math.pi) - math.pi
end

-- Frame-rate independent easing. See the header - this is not the same as a
-- fixed alpha and the difference is visible on any machine but yours.
local function smoothingAlpha(deltaTime)
    local tau = math.clamp(CONFIG.CameraSmoothing, 0, 100) / 100 * 0.3
    return tau <= 0 and 1 or 1 - math.exp(-deltaTime / tau)
end

local function readCameraRotation()
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local pitch, yaw = camera.CFrame:ToOrientation()
    return Vector2.new(pitch, yaw)
end

local function writeCameraRotation(rotation)
    local camera = Workspace.CurrentCamera
    if camera and rotation then
        -- Position is taken from the camera itself and only the rotation is
        -- replaced. Writing a whole CFrame here would fight the game's camera
        -- controller over where your head is.
        camera.CFrame = CFrame.new(camera.CFrame.Position)
            * CFrame.fromOrientation(rotation.X, rotation.Y, 0)
    end
end

local function resolveStartLook(mapAnchor, keypoints)
    for _, keypoint in ipairs(keypoints or {}) do
        if keypoint.action and keypoint.action.kind == "Look" then
            local pitch, yaw = (mapAnchor * keypoint.action.cframe):ToOrientation()
            return Vector2.new(pitch, yaw)
        end
    end
    return nil
end

local function loadoutFulfilled(recording)
    local owned = {}
    local fighter = localFighter()
    for _, item in ipairs(type(fighter) == "table" and rawget(fighter, "Items") or {}) do
        local name = itemName(item)
        if name then owned[name] = true end
    end
    for name in pairs(recording.loadoutRequirements or {}) do
        if not owned[name] then return false end
    end
    return true
end

local function stopReplay(reason)
    local replay = State.Replay
    if not replay then return end

    -- Stop walking before anything else, or the character keeps the last
    -- move vector and jogs away on its own.
    if replay.Humanoid and replay.Humanoid.Parent then
        pcall(replay.Humanoid.Move, replay.Humanoid, Vector3.zero, false)
    end
    -- Only give the controls back if we were the ones who took them. See the
    -- header.
    if replay.ControlsWereEnabled and replay.Controls
        and type(replay.Controls.Enable) == "function" then
        pcall(replay.Controls.Enable, replay.Controls)
    end
    local mechanics = State.MechanicsController
    if mechanics and type(mechanics.SetCrouching) == "function" then
        pcall(mechanics.SetCrouching, mechanics, false)
    end

    State.Replay = nil
    State.Mode = "Idle"

    if reason == "Diverged" then
        notify("Replay stopped (off course)")
    elseif reason == "Completed" then
        notify("Finished replaying")
    else
        notify("Stopped replaying")
    end
end

local function startReplay(recording)
    local context = resolveMapContext()
    if not context or not resolveDependencies() then
        notify("You need to be alive and in a match")
        return false
    end
    if State.Mode ~= "Idle" then
        notify(State.Mode == "Recording" and "Can't replay while recording" or "Already replaying")
        return false
    end
    if not recording then
        notify("No recording named '" .. tostring(CONFIG.RecordingName) .. "' for this map")
        return false
    end
    if recording.mapName ~= context.MapName then
        notify("That recording is for " .. tostring(recording.mapName))
        return false
    end
    if not loadoutFulfilled(recording) then
        notify("Your loadout does not meet this recording")
        return false
    end

    local fighter = localFighter()
    if recording.startEquippedIndex ~= nil and fighter and type(fighter.EquipItem) == "function" then
        task.spawn(function()
            pcall(fighter.EquipItem, fighter, recording.startEquippedIndex)
        end)
    end

    -- Take the controls, remembering whether they were ours to give back.
    local controls = State.PlayerControls
    local activeController = type(controls) == "table" and rawget(controls, "activeController") or nil
    local controlsWereEnabled = type(activeController) ~= "table"
        or rawget(activeController, "enabled") ~= false
    if controls and type(controls.Disable) == "function" then
        pcall(controls.Disable, controls)
    end

    State.Replay = {
        Data = recording,
        Character = context.Character,
        Humanoid = context.Humanoid,
        RootPart = context.RootPart,
        Fighter = fighter,
        MapAnchor = context.MapAnchor,
        State = "Aligning",
        AlignElapsed = 0,
        StuckTime = 0,
        BestDistance = math.huge,
        LookAligned = false,
        StartLook = resolveStartLook(context.MapAnchor, recording.keypoints),
        TargetLook = nil,
        MoveVector = Vector3.zero,
        Offset = 0,
        KeypointIndex = 1,
        PositionIndex = 1,
        Controls = controls,
        ControlsWereEnabled = controlsWereEnabled,
    }
    State.Mode = "Aligning"
    notify("Now replaying")
    return true
end

-- The weapon we start with may still be mid-swap. Waiting for it means the
-- first shot of the route actually fires.
local function isStartItemReady()
    local replay = State.Replay
    if not replay or replay.Data.startEquippedIndex == nil then return true end

    local item = equippedItem(replay.Fighter)
    if itemIndex(item, replay.Fighter) ~= replay.Data.startEquippedIndex then
        return false
    end
    local cooldown = type(item) == "table" and rawget(item, "_equip_cooldown") or nil
    return type(cooldown) ~= "number" or cooldown <= tick()
end

local function stepAlign(deltaTime)
    local replay = State.Replay
    if not replay then return end
    if not isRoundActive() then
        replay.Humanoid:Move(Vector3.zero, false)
        return
    end

    replay.AlignElapsed = replay.AlignElapsed + deltaTime

    local targetPosition = (replay.MapAnchor * replay.Data.startCFrame).Position
    local difference = targetPosition - replay.RootPart.Position
    -- Drop Y: you cannot walk upward, and leaving it in skews the direction on
    -- any slope. See the header.
    local planar = Vector3.new(difference.X, 0, difference.Z)
    local distance = planar.Magnitude

    local snapped = distance <= CONFIG.AlignTolerance
    if snapped then
        replay.Humanoid:Move(Vector3.zero, false)
    else
        -- `false` = the direction is in world space, not camera space.
        replay.Humanoid:Move(planar.Unit, false)
    end

    -- Stuck detector. See the header.
    if distance < replay.BestDistance - 0.1 then
        replay.BestDistance = distance
        replay.StuckTime = 0
    else
        replay.StuckTime = replay.StuckTime + deltaTime
    end

    local aligned = (snapped and (replay.StartLook == nil or replay.LookAligned))
        or replay.StuckTime >= 1
    if not aligned then return end

    replay.Humanoid:Move(Vector3.zero, false)
    -- Give the weapon up to three seconds, then start regardless.
    if not isStartItemReady() and replay.AlignElapsed < 3 then return end

    replay.State = "Playing"
    State.Mode = "Playing"
end

local function hasDiverged(offset)
    local replay = State.Replay
    local positions = replay and replay.Data.positions or nil
    if not positions or #positions == 0 then return false end

    -- Forward-only cursor. See the header.
    while replay.PositionIndex < #positions
        and positions[replay.PositionIndex + 1].offset <= offset do
        replay.PositionIndex = replay.PositionIndex + 1
    end

    local first = positions[replay.PositionIndex]
    local second = positions[replay.PositionIndex + 1]
    local expected = first.position
    if second then
        local span = second.offset - first.offset
        local alpha = span > 0 and math.clamp((offset - first.offset) / span, 0, 1) or 0
        expected = first.position:Lerp(second.position, alpha)
    end

    local expectedWorld = replay.MapAnchor:PointToWorldSpace(expected)
    return (expectedWorld - replay.RootPart.Position).Magnitude > CONFIG.DivergenceLimit
end

local function applyReplayAction(action)
    local replay = State.Replay
    if not replay then return end
    local fighter = replay.Fighter
    local mechanics = State.MechanicsController

    if action.kind == "Move" then
        -- Stored, not applied: Humanoid:Move has to be called every frame or
        -- the character stops, so the vector is held and reissued below.
        replay.MoveVector = action.direction

    elseif action.kind == "Look" then
        local pitch, yaw = (replay.MapAnchor * action.cframe):ToOrientation()
        replay.TargetLook = Vector2.new(pitch, yaw)

    elseif action.kind == "Equip" and fighter and type(fighter.EquipItem) == "function" then
        -- task.spawn because these can yield, and this loop must not.
        task.spawn(function() pcall(fighter.EquipItem, fighter, action.index) end)

    elseif action.kind == "ItemInput" and fighter and type(fighter.Input) == "function" then
        task.spawn(function() pcall(fighter.Input, fighter, action.inputType) end)

    elseif action.kind == "QuickAttack" and fighter
        and type(fighter.QuickAttackDown) == "function" then
        -- Press and release. The game wants both; 50ms is a human-length tap.
        task.spawn(function()
            pcall(fighter.QuickAttackDown, fighter, action.attackType)
            task.wait(0.05)
            if fighter and type(fighter.QuickAttackUp) == "function" then
                pcall(fighter.QuickAttackUp, fighter, action.attackType)
            end
        end)

    elseif action.kind == "Jump" then
        if mechanics then
            -- Jumping out of a slide is a different move with different
            -- height, so it has to be dispatched differently to come out the
            -- same on replay.
            if rawget(mechanics, "IsSliding") == true and type(mechanics.HighJump) == "function" then
                pcall(mechanics.HighJump, mechanics)
            else
                -- Both are offered; the controller works out which applies.
                if type(mechanics.DoubleJumpRequest) == "function" then
                    pcall(mechanics.DoubleJumpRequest, mechanics)
                end
                if type(mechanics.JumpRequest) == "function" then
                    pcall(mechanics.JumpRequest, mechanics)
                end
            end
        end

    elseif action.kind == "Crouch" then
        if mechanics and type(mechanics.SetCrouching) == "function" then
            pcall(mechanics.SetCrouching, mechanics, action.crouching)
        end

    elseif action.kind == "Slide" then
        if mechanics and type(mechanics.Slide) == "function" then
            task.spawn(function() pcall(mechanics.Slide, mechanics) end)
        end
    end
end

local function stepPlaying(deltaTime)
    local replay = State.Replay
    if not replay then return end

    replay.Offset = replay.Offset + deltaTime

    if hasDiverged(replay.Offset) then
        stopReplay("Diverged")
        return
    end

    -- Fire every keypoint whose time has arrived. A `while`, not an `if`:
    -- several actions can share a moment, and a slow frame can pass several.
    local keypoints = replay.Data.keypoints
    while replay.KeypointIndex <= #keypoints do
        local keypoint = keypoints[replay.KeypointIndex]
        if replay.Offset < keypoint.offset then break end
        applyReplayAction(keypoint.action)
        replay.KeypointIndex = replay.KeypointIndex + 1
    end

    -- `true` = camera-relative, because that is how GetMoveVector gave it to
    -- us when recording. Getting this argument wrong sends the whole route
    -- sideways, and it is the sort of mistake that looks like bad physics.
    replay.Humanoid:Move(replay.MoveVector, true)

    if replay.KeypointIndex > #keypoints then
        stopReplay("Completed")
    end
end

local function updateReplayCamera(deltaTime)
    local replay = State.Replay
    local current = replay and readCameraRotation() or nil
    if not replay or not current then return end

    if replay.State == "Aligning" and replay.StartLook then
        local difference = Vector2.new(
            replay.StartLook.X - current.X,
            wrapAngle(replay.StartLook.Y - current.Y)   -- yaw, the short way
        )
        local magnitude = difference.Magnitude
        if magnitude <= math.rad(0.1) then
            current = replay.StartLook
            replay.LookAligned = true
        else
            -- Two limits at once: ease toward the target, but never faster
            -- than TurnSpeed. The ease alone snaps instantly on a big turn;
            -- the cap alone arrives at full speed and stops dead.
            local step = math.min(
                magnitude * smoothingAlpha(deltaTime),
                math.rad(CONFIG.TurnSpeed) * deltaTime
            )
            current = current + difference.Unit * step
            replay.LookAligned = false
        end
        writeCameraRotation(current)

    elseif replay.State == "Playing" and replay.TargetLook then
        local alpha = smoothingAlpha(deltaTime)
        writeCameraRotation(Vector2.new(
            current.X + (replay.TargetLook.X - current.X) * alpha,
            current.Y + wrapAngle(replay.TargetLook.Y - current.Y) * alpha
        ))
    end
end

--=============================================================================
-- Keys
--=============================================================================

local function selectedRecording()
    local context = resolveMapContext()
    if not context then return nil end
    local byName = State.Records[context.MapName]
    return byName and byName[CONFIG.RecordingName] or nil
end

local keyConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or env.__MovementRecorderToken ~= Token then return end

    if input.KeyCode == CONFIG.RecordKey then
        loadPersistence()
        if State.Mode == "Recording" then
            stopRecording(true)
        elseif State.Mode == "Idle" then
            resolveDependencies()
            startRecording()
        end

    elseif input.KeyCode == CONFIG.ReplayKey then
        loadPersistence()
        if State.Mode == "Aligning" or State.Mode == "Playing" then
            stopReplay("Stopped")
        elseif State.Mode == "Idle" then
            resolveDependencies()
            startReplay(selectedRecording())
        end
    end
end)

--=============================================================================
-- The loops
--=============================================================================
-- Two of them. Movement runs on Heartbeat (after physics, which is where you
-- want to be when issuing a move for the next step) and the camera runs on
-- RenderStepped, because a camera written outside the render step is a frame
-- stale and visibly juddery.

local function update(deltaTime)
    loadPersistence()

    -- Died, or the round ended. Everything referencing the old character is
    -- now meaningless.
    local context = resolveMapContext()
    local activeCharacter = State.Recording and State.Recording.Character
        or State.Replay and State.Replay.Character or nil
    if activeCharacter and (not context or context.Character ~= activeCharacter) then
        stopRecording(false)
        stopReplay("Stopped")
        return
    end

    if State.Mode == "Recording" then
        sampleRecording()
    elseif State.Mode == "Aligning" then
        stepAlign(deltaTime)
    elseif State.Mode == "Playing" then
        stepPlaying(deltaTime)
    end
end

local heartbeat
heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    if env.__MovementRecorderToken ~= Token then
        heartbeat:Disconnect()
        return
    end
    -- Clamped, always. See the header.
    local ok, err = pcall(update, math.clamp(deltaTime, 0, 0.1))
    if not ok then
        warn("[Movement Recorder] " .. tostring(err))
    end
end)

local render
render = RunService.RenderStepped:Connect(function(deltaTime)
    if env.__MovementRecorderToken ~= Token then
        render:Disconnect()
        return
    end
    pcall(updateReplayCamera, math.clamp(deltaTime, 0, 0.1))
end)

loadPersistence()
notify(("ready - %s to record, %s to replay"):format(
    CONFIG.RecordKey.Name, CONFIG.ReplayKey.Name))

--=============================================================================
-- Cleanup
--=============================================================================

env.__MovementRecorderCleanup = function()
    env.__MovementRecorderToken = nil

    stopRecording(false)
    stopReplay("Stopped")
    disconnectRecordingInputs()

    if keyConnection then keyConnection:Disconnect() end
    if heartbeat then heartbeat:Disconnect() end
    if render then render:Disconnect() end

    env.__MovementRecorderCleanup = nil
end