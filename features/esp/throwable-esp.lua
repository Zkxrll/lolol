--[[============================================================================
    THROWABLE ESP  -  labels on live grenades, molotovs and tripmines
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Puts a floating label with a distance on every thrown item in the world -
    GRENADE, FLASH, MOLOTOV, SMOKE, SATCHEL, TRIPMINE, FLARE GUN - so you can
    see one land behind you.

    It is much smaller than [`player-esp.lua`](../esp/player-esp.lua), and worth
    reading first if that one looks like a lot. Same Drawing API, one label per
    object instead of a box, a name, a bar and an arrow.

===============================================================================
    FINDING THEM: ChildAdded, NOT DescendantAdded
===============================================================================

    Thrown items are parented straight into the workspace, so:

        Workspace.ChildAdded    ->  a new one exists
        Workspace.ChildRemoved  ->  it is gone

    The temptation is `DescendantAdded`, which catches everything anywhere. Do
    not use it here. `DescendantAdded` fires for every part of every character
    that spawns, every weapon that gets equipped, every particle emitter in
    every effect - hundreds of calls a second in a busy round, all of them
    running a name lookup that will miss. `ChildAdded` fires for the handful of
    things parented to the top level.

    Pick the narrowest signal that still sees what you need. It is free
    performance, and the difference is not small.

    Identification is by name against a table. Fragile - a renamed asset breaks
    it silently - but it is what the game offers, and the failure is a missing
    label rather than a crash.

===============================================================================
    THE DIRTY CHECK
===============================================================================

    Look at how each label is updated:

        if entry.lastLabelColor ~= info.Color then
            entry.lastLabelColor = info.Color
            entry.label.Color = info.Color
        end

    Every property is compared before it is written, and the last value is kept
    alongside the drawing. This looks like pointless bookkeeping - assigning a
    value that is already there should do nothing.

    It is not free. Drawing objects live outside Lua, on the executor's side, so
    every property write crosses that boundary and some executors do real work
    on each one regardless of whether the value changed. With a label per
    throwable at sixty frames a second, the writes you skip add up to more than
    the comparisons cost.

    The distance is rounded before comparison for the same reason - the raw
    distance changes every frame, the metre does not, and only the metre is
    displayed.

    This pattern is worth applying to anything that pushes values across a
    boundary each frame: compare, then write.

    ONE MORE SMALL THING
    Distance is compared squared:

        if worldDistanceSquared > maxDistSquared then ... end

    `math.sqrt` is only called for labels that survive the range check, because
    comparing distances does not need the actual distance - just the ordering,
    which squaring preserves.

    REQUIREMENTS
    `Drawing`. Any executor with a working Drawing API renders this.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    MaxDistance = 1000,   -- studs; further than this and the label hides
    TextSize = 12,
    Transparency = 1,     -- 1 = solid

    Notify = true,
}

-- Name in the workspace -> what to show. Add to this if you find something the
-- game spawns that is worth seeing.
local TRACKED = {
    ["Throwable - Grenade"]    = { Label = "GRENADE",  Color = Color3.fromRGB(255,  80,  80) },
    ["Throwable - Flashbang"]  = { Label = "FLASH",    Color = Color3.fromRGB(255, 255, 100) },
    ["Throwable - Molotov"]    = { Label = "MOLOTOV",  Color = Color3.fromRGB(255, 120,   0) },
    ["Throwable - Smoke"]      = { Label = "SMOKE",    Color = Color3.fromRGB(200, 200, 200) },
    ["Smoke Grenade"]          = { Label = "SMOKE",    Color = Color3.fromRGB(200, 200, 200) },
    ["Satchel"]                = { Label = "SATCHEL",  Color = Color3.fromRGB(255,  50,  50) },
    ["SubspaceTripmineHitbox"] = { Label = "TRIPMINE", Color = Color3.fromRGB(255,  50,  50) },
    ["Flare Gun"]              = { Label = "FLARE GUN", Color = Color3.fromRGB(255, 50,  50) },
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Throwable ESP", Text = text, Duration = 4,
        })
    end)
end

if type(Drawing) ~= "table" and type(Drawing) ~= "userdata" then
    notify("your executor has no Drawing API - cannot run")
    return
end

local env = (getgenv and getgenv()) or _G
if env.__ThrowableEspCleanup then
    pcall(env.__ThrowableEspCleanup)
end

local Token = {}
env.__ThrowableEspToken = Token

--=============================================================================
-- The label pool
--=============================================================================
-- One entry per tracked object. `last*` fields exist for the dirty check; see
-- header.

local Labels = {}

local function isTracked(instance)
    return instance ~= nil
        and (instance:IsA("BasePart") or instance:IsA("Model"))
        and TRACKED[instance.Name] ~= nil
end

local function createLabel(instance)
    if Labels[instance] then return end

    local label = Drawing.new("Text")
    label.Center = true
    label.Outline = true
    label.Font = 2
    label.Size = CONFIG.TextSize
    label.Transparency = CONFIG.Transparency
    label.Visible = false

    Labels[instance] = {
        label = label,
        visible = false,
        lastText = nil,
        lastSize = nil,
        lastColor = nil,
        lastX = nil,
        lastY = nil,
        lastDistance = nil,
    }
end

local function destroyLabel(instance)
    local entry = Labels[instance]
    if not entry then return end
    pcall(function() entry.label:Remove() end)
    Labels[instance] = nil
end

local function hide(entry)
    if entry.visible then
        entry.label.Visible = false
        entry.visible = false
    end
end

--=============================================================================
-- The frame
--=============================================================================

local function update()
    if not CONFIG.Enabled then
        for _, entry in pairs(Labels) do hide(entry) end
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local rootPosition = root and root.Position or nil

    local maxDistanceSquared = CONFIG.MaxDistance * CONFIG.MaxDistance

    -- Sweep first: things can leave the workspace without ChildRemoved reaching
    -- us (reparented, or removed while we were not listening).
    for instance in pairs(Labels) do
        if not instance.Parent or not instance:IsDescendantOf(Workspace) or not isTracked(instance) then
            destroyLabel(instance)
        end
    end

    for instance, entry in pairs(Labels) do
        local info = TRACKED[instance.Name]
        if not info then continue end

        local position = instance:IsA("BasePart") and instance.Position or instance:GetPivot().Position
        local screen, onScreen = camera:WorldToViewportPoint(position)

        -- Z <= 0 means behind the camera, where the projected X/Y are mirrored
        -- and meaningless. `onScreen` alone does not always catch it.
        if not onScreen or screen.Z <= 0 then
            hide(entry)
            continue
        end

        local distance = 0
        if rootPosition then
            local offset = position - rootPosition
            local distanceSquared = offset:Dot(offset)   -- no sqrt yet; see header
            if distanceSquared > maxDistanceSquared then
                hide(entry)
                continue
            end
            distance = math.sqrt(distanceSquared)
        end

        if not entry.visible then
            entry.label.Visible = true
            entry.visible = true
        end

        -- Everything below is compare-then-write. See header.
        if entry.lastSize ~= CONFIG.TextSize then
            entry.lastSize = CONFIG.TextSize
            entry.label.Size = CONFIG.TextSize
        end

        local metres = math.floor(distance)
        if entry.lastDistance ~= metres or entry.lastText ~= info.Label then
            entry.lastDistance = metres
            entry.lastText = info.Label
            entry.label.Text = string.format("%s | %dm", info.Label, metres)
        end

        local x, y = math.round(screen.X), math.round(screen.Y)
        if entry.lastX ~= x or entry.lastY ~= y then
            entry.lastX, entry.lastY = x, y
            entry.label.Position = Vector2.new(x, y)
        end

        if entry.lastColor ~= info.Color then
            entry.lastColor = info.Color
            entry.label.Color = info.Color
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================

for _, child in ipairs(Workspace:GetChildren()) do
    if isTracked(child) then createLabel(child) end
end

local addedConn = Workspace.ChildAdded:Connect(function(child)
    if env.__ThrowableEspToken ~= Token then return end
    if isTracked(child) then createLabel(child) end
end)

local removedConn = Workspace.ChildRemoved:Connect(function(child)
    if env.__ThrowableEspToken ~= Token then return end
    destroyLabel(child)
end)

local renderConn = RunService.RenderStepped:Connect(function()
    if env.__ThrowableEspToken ~= Token then return end
    local ok, err = pcall(update)
    if not ok then
        warn("[Throwable ESP] " .. tostring(err))
    end
end)

notify("active")

--=============================================================================
-- Cleanup
--=============================================================================

env.__ThrowableEspCleanup = function()
    env.__ThrowableEspToken = nil
    pcall(function() addedConn:Disconnect() end)
    pcall(function() removedConn:Disconnect() end)
    pcall(function() renderConn:Disconnect() end)
    for instance in pairs(Labels) do
        destroyLabel(instance)
    end
    table.clear(Labels)
    env.__ThrowableEspCleanup = nil
end
