--[[============================================================================
    PLAYER ESP  -  see people through walls
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Draws an overlay on your screen for every other player: a box around them, a
    name, a health bar, their distance, a line showing which way they are
    facing, and arrows at the edge of the screen pointing at people you cannot
    currently see. Players in your line of sight are drawn in one colour and
    players behind cover in another.

    Everything here is READ-ONLY. It draws information your own client already
    has, and it sends nothing anywhere. That is worth understanding: your client
    is told where every player is because it needs that to render the game. ESP
    does not obtain information, it just stops hiding it from you.

===============================================================================
    WHY THE DRAWING LIBRARY
===============================================================================

    Everything is drawn with `Drawing.new`, an executor feature that paints
    directly onto the screen. The alternative is to build Roblox GUI objects -
    a Frame here, a TextLabel there.

    Drawing is the right choice for one reason: what you draw is not part of the
    game. A GUI object is an Instance. It lives in a container, something can
    iterate that container, and anything in the game can see how many children
    it has and what they are called. A `Drawing` exists only in the executor's
    renderer. There is nothing in the game's instance tree to find.

    The trade-off is that Drawing objects are not parented to anything, so
    nothing cleans them up for you. Forget to `:Remove()` one and it stays on
    screen until you close the game - including after you unload the script.
    This file is careful about that, and so should anything you build.

===============================================================================
    THE THING THAT MAKES OR BREAKS AN ESP: REUSE
===============================================================================

    This runs every single frame. The single biggest mistake in ESP code is
    creating and removing Drawing objects inside that loop. Sixty players' worth
    of objects created and destroyed sixty times a second will drop your frame
    rate through the floor on its own.

    So every player gets ONE set of drawings, created the first time we see
    them, kept in a table, and simply hidden (`Visible = false`) when not
    needed. Nothing is created in the render loop. Objects are only removed when
    a player actually leaves the game.

    Same principle for the box: the eight corner segments are created once and
    moved, never rebuilt.

===============================================================================
    HOW THE BOX IS SIZED
===============================================================================

    You want a 2D rectangle on screen that tightly contains a 3D character. The
    common approach is `model:GetBoundingBox()` and project that - but a
    character's bounding box includes hats, backpacks and whatever the current
    animation is throwing out to the side, so the box ends up loose and jumpy.

    Instead we take ONE part - the character's hitbox - work out its eight
    corners in world space, project each corner to the screen, and take the
    smallest and largest X and Y of the results:

        for each of the 8 corners:
            world = part.CFrame:PointToWorldSpace(corner)
            screen = camera:WorldToViewportPoint(world)
            if screen.Z > 0 then track min/max of screen.X and screen.Y

    `screen.Z > 0` means "in front of the camera". Points behind you project to
    nonsense coordinates, and a single bad point ruins the whole box, so they
    are skipped. If fewer than two corners survive there is nothing sensible to
    draw and we skip the player entirely.

    The corners are computed once per part size and cached, because the eight
    offsets never change while the part does not.

    THE CORNER STYLE
    The box is drawn as eight short segments at the four corners rather than
    four full sides. It obscures less of what you are looking at, and the corner
    length adapts to the box size so distant players get a small clean bracket
    instead of a solid blob.

    Every line is drawn twice: a thicker dark line underneath and the coloured
    line on top. That outline is what keeps the box readable against a bright
    wall or a white skybox. It is worth the second draw.

===============================================================================
    HOW "CAN I SEE THEM" IS DECIDED
===============================================================================

    Cast a ray from the camera to the target. If it hits anything on the way,
    they are behind cover:

        local result = Workspace:Raycast(camera.CFrame.Position, target - origin, params)
        visible = (result == nil)

    Your own character and the target's are excluded, or you would be blocked by
    yourself or by their own limbs.

    ONE RAY IS NOT ENOUGH. Aim at a player's chest while they stand behind a
    crate and the centre point is blocked even though their head and shoulder
    are in plain view. So we cast at several points spread across the hitbox -
    the centre, then points pushed out along each axis - and count them visible
    if ANY point is reachable. Heads get their own tighter spread, because a
    head is small and its corners land outside it.

    THIS IS THE MOST EXPENSIVE THING IN THE FILE. Raycasts are not free, and
    this is players x points x every frame. So results are cached for a short
    time, which is the honest trade-off you are making: how stale is a "visible"
    allowed to be?

    For an ESP, a couple of frames of staleness means a colour changes slightly
    late. Nobody dies from it. But note what the full script does elsewhere: its
    triggerbot deliberately keeps NO cached "visible" verdict at all, because
    there the stale value would fire a real shot into a wall. Cache lifetime is
    a decision per feature, not a global setting.

===============================================================================
    OFF-SCREEN ARROWS
===============================================================================

    When someone is outside your view, we draw an arrow at the edge of the
    screen pointing at them.

    Getting the direction right is fiddly. `WorldToViewportPoint` returns a
    position with a NEGATIVE Z for anything behind the camera, and the X/Y that
    come back with it are mirrored. So for those we flip the direction vector.
    Skip that and your arrows point exactly the wrong way whenever someone is
    behind you, which is precisely when you want them.

    The arrow itself is a filled triangle placed on a circle around the centre
    of the screen, rotated to face the target.

    REQUIREMENTS
    A working `Drawing` library. Almost every executor has one, but quality
    varies wildly - some do not support `Triangle` (arrows), some ignore
    `Transparency`. The file checks what it can and disables what is missing
    rather than erroring.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- What to draw
    Box = true,
    Names = true,
    HealthBar = true,
    HealthText = false,
    Distance = true,
    LookDirection = false,
    OffScreenArrows = true,
    Highlight = false,       -- solid fill through walls; uses a game instance

    -- Who to draw
    ShowTeammates = false,
    MaxDistance = 2000,      -- studs

    -- Colours
    VisibleColor = Color3.fromRGB(120, 255, 140),
    HiddenColor = Color3.fromRGB(255, 110, 110),
    TeammateColor = Color3.fromRGB(120, 190, 255),
    TextColor = Color3.fromRGB(255, 255, 255),
    OutlineColor = Color3.fromRGB(0, 0, 0),

    HighlightFillTransparency = 0.6,
    HighlightOutlineTransparency = 0,

    -- Text
    TextSize = 13,
    Font = 2,

    -- How long a visibility answer is trusted, in seconds. Higher = cheaper and
    -- staler. See the header before raising this.
    VisibilityCacheSeconds = 0.1,

    Notify = true,
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
            Title = "Player ESP", Text = text, Duration = 4,
        })
    end)
end

if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then
    notify("your executor has no Drawing library - cannot run")
    return
end

-- Some Drawing implementations are missing shapes. Find out now rather than
-- erroring sixty times a second later.
local HAS_TRIANGLE = pcall(function()
    local probe = Drawing.new("Triangle")
    probe:Remove()
end)
if not HAS_TRIANGLE and CONFIG.OffScreenArrows then
    CONFIG.OffScreenArrows = false
end

local env = (getgenv and getgenv()) or _G
if env.__PlayerEspCleanup then
    pcall(env.__PlayerEspCleanup)
end

local Token = {}
env.__PlayerEspToken = Token

--=============================================================================
-- Drawing helpers
--=============================================================================

local function newLine()
    local line = Drawing.new("Line")
    line.Visible = false
    line.Thickness = 1
    line.Transparency = 1
    return line
end

local function newText()
    local text = Drawing.new("Text")
    text.Visible = false
    text.Center = true
    text.Outline = true
    text.Size = CONFIG.TextSize
    text.Font = CONFIG.Font
    text.Color = CONFIG.TextColor
    return text
end

local function newSquare()
    local square = Drawing.new("Square")
    square.Visible = false
    square.Filled = true
    square.Thickness = 1
    square.Transparency = 1
    return square
end

local function remove(drawing)
    if drawing then
        pcall(function() drawing:Remove() end)
    end
end

--=============================================================================
-- Per-player drawing set
--=============================================================================
-- Created once per player, reused forever, removed only when they leave.
-- See "THE THING THAT MAKES OR BREAKS AN ESP" in the header.

local Entries = {}   -- [Player] = entry

local function createEntry()
    local entry = {
        corners = table.create(8),
        name = newText(),
        info = newText(),          -- distance and health text
        healthBack = newSquare(),
        healthFill = newSquare(),
        look = newLine(),
        lookOutline = newLine(),
        arrow = nil,
        highlight = nil,
    }

    -- Eight corner segments, each an outline line and a coloured line on top.
    for index = 1, 8 do
        entry.corners[index] = { outline = newLine(), color = newLine() }
    end

    if CONFIG.OffScreenArrows and HAS_TRIANGLE then
        entry.arrow = Drawing.new("Triangle")
        entry.arrow.Visible = false
        entry.arrow.Filled = true
        entry.arrow.Transparency = 1
    end

    return entry
end

local function hideEntry(entry)
    for _, segment in ipairs(entry.corners) do
        segment.outline.Visible = false
        segment.color.Visible = false
    end
    entry.name.Visible = false
    entry.info.Visible = false
    entry.healthBack.Visible = false
    entry.healthFill.Visible = false
    entry.look.Visible = false
    entry.lookOutline.Visible = false
    if entry.arrow then entry.arrow.Visible = false end
end

local function destroyEntry(entry)
    for _, segment in ipairs(entry.corners) do
        remove(segment.outline)
        remove(segment.color)
    end
    remove(entry.name)
    remove(entry.info)
    remove(entry.healthBack)
    remove(entry.healthFill)
    remove(entry.look)
    remove(entry.lookOutline)
    remove(entry.arrow)
    if entry.highlight then
        pcall(function() entry.highlight:Destroy() end)
    end
end

local function entryFor(player)
    local entry = Entries[player]
    if not entry then
        entry = createEntry()
        Entries[player] = entry
    end
    return entry
end

--=============================================================================
-- Character bits
--=============================================================================

-- RIVALS gives characters dedicated hitbox parts. Fall back to the standard
-- Roblox parts so this still does something sensible in another game.
local function hitboxBody(character)
    return character:FindFirstChild("HitboxBody")
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChildWhichIsA("BasePart")
end

local function hitboxHead(character)
    return character:FindFirstChild("HitboxHead")
        or character:FindFirstChild("Head")
end

--=============================================================================
-- Visibility
--=============================================================================

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude

-- The sample points on a part, in the part's own space, scaled to 90% so they
-- sit just inside the surface rather than exactly on it. A point exactly on a
-- surface can register as hitting the surface it belongs to.
local function samplePoints(part, isHead)
    local points = { part.Position }

    local cframe = part.CFrame
    local half = part.Size * 0.5
    local insetX, insetY, insetZ = half.X * 0.9, half.Y * 0.9, half.Z * 0.9

    local function add(x, y, z)
        points[#points + 1] = cframe:PointToWorldSpace(Vector3.new(x, y, z))
    end

    if isHead then
        -- A head is small; corner points would land outside it. Use a tighter
        -- spread biased toward the top, which is the part that peeks over
        -- cover in the first place.
        add(0, half.Y, 0)
        add(0, insetY * 0.82, insetZ * 0.45)
        add(0, insetY * 0.82, -insetZ * 0.45)
        add(insetX * 0.55, insetY * 0.78, 0)
        add(-insetX * 0.55, insetY * 0.78, 0)
        return points
    end

    add(insetX, 0, 0)
    add(-insetX, 0, 0)
    add(0, insetY, 0)
    add(0, -insetY, 0)
    add(0, 0, insetZ)
    add(0, 0, -insetZ)
    return points
end

-- Weak-keyed so a character leaving the game does not keep its cache alive.
local VisibilityCache = setmetatable({}, { __mode = "k" })

local function isVisible(character, camera)
    local cached = VisibilityCache[character]
    if cached and os.clock() < cached.expiresAt then
        return cached.value
    end

    local origin = camera.CFrame.Position
    RayParams.FilterDescendantsInstances = { LocalPlayer.Character, character }

    -- Head first: it is the part most likely to be showing over cover, so
    -- checking it first is usually the cheapest route to a "yes".
    local visible = false
    local head = hitboxHead(character)
    local body = hitboxBody(character)

    for _, candidate in ipairs({ { head, true }, { body, false } }) do
        local part, isHead = candidate[1], candidate[2]
        if part then
            for _, point in ipairs(samplePoints(part, isHead)) do
                local direction = point - origin
                if direction.Magnitude > 0
                    and Workspace:Raycast(origin, direction, RayParams) == nil then
                    visible = true
                    break
                end
            end
        end
        if visible then break end
    end

    VisibilityCache[character] = {
        value = visible,
        expiresAt = os.clock() + CONFIG.VisibilityCacheSeconds,
    }
    return visible
end

--=============================================================================
-- Screen bounds
--=============================================================================
-- The eight local corner offsets for a part size. Cached per part, because they
-- only change if the part is resized.

local CornerCache = setmetatable({}, { __mode = "k" })

local function localCorners(part)
    local cached = CornerCache[part]
    if cached and cached.size == part.Size then
        return cached.corners
    end

    local half = part.Size * 0.5
    local corners = table.create(8)
    local index = 0
    for xSign = -1, 1, 2 do
        for ySign = -1, 1, 2 do
            for zSign = -1, 1, 2 do
                index += 1
                corners[index] = Vector3.new(half.X * xSign, half.Y * ySign, half.Z * zSign)
            end
        end
    end

    CornerCache[part] = { size = part.Size, corners = corners }
    return corners
end

-- Returns minX, minY, maxX, maxY on screen, or nil if the part cannot sensibly
-- be drawn (mostly: it is behind you).
local function screenBounds(part, camera)
    local minX, minY, maxX, maxY
    local projected = 0

    for _, corner in ipairs(localCorners(part)) do
        local world = part.CFrame:PointToWorldSpace(corner)
        local screen = camera:WorldToViewportPoint(world)
        if screen.Z > 0 then   -- in front of the camera; see header
            projected += 1
            minX = minX and math.min(minX, screen.X) or screen.X
            maxX = maxX and math.max(maxX, screen.X) or screen.X
            minY = minY and math.min(minY, screen.Y) or screen.Y
            maxY = maxY and math.max(maxY, screen.Y) or screen.Y
        end
    end

    if projected < 2 or not minX then return nil end
    return minX, minY, maxX, maxY
end

--=============================================================================
-- Drawing one player
--=============================================================================

local function setSegment(segment, from, to, color, scale)
    segment.outline.From, segment.outline.To = from, to
    segment.outline.Color = CONFIG.OutlineColor
    segment.outline.Thickness = math.max(3 * scale, 2)
    segment.outline.Visible = true

    segment.color.From, segment.color.To = from, to
    segment.color.Color = color
    segment.color.Thickness = math.max(1 * scale, 1)
    segment.color.Visible = true
end

local function drawBox(entry, minX, minY, maxX, maxY, color, scale)
    local width = math.max(maxX - minX, 1)
    local height = math.max(maxY - minY, 1)

    -- Corner length adapts to the box, so far-away players get a small bracket
    -- rather than a solid block. Never longer than half a side, or the two
    -- corners of one edge would meet and it would just be a rectangle.
    local length = math.max(math.min(width, height) * 0.24, 5 * scale)
    length = math.min(length, width * 0.5, height * 0.5)

    local corners = entry.corners
    setSegment(corners[1], Vector2.new(minX, minY), Vector2.new(minX + length, minY), color, scale)
    setSegment(corners[2], Vector2.new(maxX - length, minY), Vector2.new(maxX, minY), color, scale)
    setSegment(corners[3], Vector2.new(minX, maxY), Vector2.new(minX + length, maxY), color, scale)
    setSegment(corners[4], Vector2.new(maxX - length, maxY), Vector2.new(maxX, maxY), color, scale)
    setSegment(corners[5], Vector2.new(minX, minY), Vector2.new(minX, minY + length), color, scale)
    setSegment(corners[6], Vector2.new(minX, maxY - length), Vector2.new(minX, maxY), color, scale)
    setSegment(corners[7], Vector2.new(maxX, minY), Vector2.new(maxX, minY + length), color, scale)
    setSegment(corners[8], Vector2.new(maxX, maxY - length), Vector2.new(maxX, maxY), color, scale)
end

local function drawHealthBar(entry, minX, minY, maxY, humanoid)
    local height = math.max(maxY - minY, 1)
    local fraction = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)

    -- Sits just to the left of the box, full height.
    local x = minX - 6
    entry.healthBack.Position = Vector2.new(x, minY)
    entry.healthBack.Size = Vector2.new(3, height)
    entry.healthBack.Color = CONFIG.OutlineColor
    entry.healthBack.Visible = true

    -- Grows from the bottom up, so a dying player's bar shrinks downward the
    -- way people expect.
    entry.healthFill.Position = Vector2.new(x + 1, minY + height * (1 - fraction))
    entry.healthFill.Size = Vector2.new(1, height * fraction)
    entry.healthFill.Color = Color3.fromRGB(
        math.floor(255 * (1 - fraction)),
        math.floor(255 * fraction),
        60
    )
    entry.healthFill.Visible = true
end

local function drawArrow(entry, camera, targetPosition, color, viewport)
    local screen = camera:WorldToViewportPoint(targetPosition)
    local centre = viewport * 0.5

    local direction = Vector2.new(screen.X, screen.Y) - centre
    -- Behind the camera, the returned X/Y are mirrored. See header.
    if screen.Z <= 0 then
        direction = -direction
    end
    if direction.Magnitude == 0 then
        entry.arrow.Visible = false
        return
    end
    direction = direction.Unit

    local radius = math.min(viewport.X, viewport.Y) * 0.32
    local tip = centre + direction * radius

    -- A vector at right angles to the direction gives us the two base corners.
    local side = Vector2.new(-direction.Y, direction.X)
    local size = 12

    entry.arrow.PointA = tip
    entry.arrow.PointB = tip - direction * size + side * (size * 0.5)
    entry.arrow.PointC = tip - direction * size - side * (size * 0.5)
    entry.arrow.Color = color
    entry.arrow.Visible = true
end

local function ensureHighlight(entry, character, color)
    if not entry.highlight or entry.highlight.Parent ~= character then
        if entry.highlight then
            pcall(function() entry.highlight:Destroy() end)
        end
        local highlight = Instance.new("Highlight")
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = character
        entry.highlight = highlight
    end
    entry.highlight.FillColor = color
    entry.highlight.OutlineColor = CONFIG.OutlineColor
    entry.highlight.FillTransparency = CONFIG.HighlightFillTransparency
    entry.highlight.OutlineTransparency = CONFIG.HighlightOutlineTransparency
    entry.highlight.Enabled = true
end

--=============================================================================
-- The frame
--=============================================================================

local function shouldDraw(player)
    if player == LocalPlayer then return false end
    if player.Parent ~= Players then return false end
    if not CONFIG.ShowTeammates and player.Team ~= nil and player.Team == LocalPlayer.Team then
        return false
    end
    return true
end

local function render()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local viewport = camera.ViewportSize
    -- Thicknesses and text scale with the window so the overlay looks the same
    -- at any resolution.
    local scale = math.clamp(viewport.Y / 1080, 0.75, 1.5)

    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")

    for player, entry in pairs(Entries) do
        local drawn = false

        if CONFIG.Enabled and shouldDraw(player) then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local body = character and hitboxBody(character)

            if humanoid and humanoid.Health > 0 and body then
                local distance = localRoot
                    and (body.Position - localRoot.Position).Magnitude
                    or (body.Position - camera.CFrame.Position).Magnitude

                if distance <= CONFIG.MaxDistance then
                    local visible = isVisible(character, camera)
                    local color
                    if player.Team ~= nil and player.Team == LocalPlayer.Team then
                        color = CONFIG.TeammateColor
                    else
                        color = visible and CONFIG.VisibleColor or CONFIG.HiddenColor
                    end

                    local minX, minY, maxX, maxY = screenBounds(body, camera)

                    if minX then
                        drawn = true

                        if CONFIG.Box then
                            drawBox(entry, minX, minY, maxX, maxY, color, scale)
                        end

                        if CONFIG.Names then
                            entry.name.Text = player.DisplayName
                            entry.name.Size = CONFIG.TextSize * scale
                            entry.name.Color = CONFIG.TextColor
                            entry.name.Position = Vector2.new((minX + maxX) * 0.5, minY - 16 * scale)
                            entry.name.Visible = true
                        end

                        -- Distance and health share one line under the box.
                        local parts = {}
                        if CONFIG.Distance then
                            parts[#parts + 1] = ("%dm"):format(math.floor(distance))
                        end
                        if CONFIG.HealthText then
                            parts[#parts + 1] = ("%d hp"):format(math.floor(humanoid.Health))
                        end
                        if #parts > 0 then
                            entry.info.Text = table.concat(parts, "  ")
                            entry.info.Size = CONFIG.TextSize * scale
                            entry.info.Color = CONFIG.TextColor
                            entry.info.Position = Vector2.new((minX + maxX) * 0.5, maxY + 2 * scale)
                            entry.info.Visible = true
                        end

                        if CONFIG.HealthBar then
                            drawHealthBar(entry, minX, minY, maxY, humanoid)
                        end

                        if CONFIG.LookDirection then
                            -- A short line from the player's feet in the
                            -- direction they are facing, projected to 2D.
                            local from = body.Position
                            local to = from + body.CFrame.LookVector * 6
                            local a = camera:WorldToViewportPoint(from)
                            local b = camera:WorldToViewportPoint(to)
                            if a.Z > 0 and b.Z > 0 then
                                local fromPoint = Vector2.new(a.X, a.Y)
                                local toPoint = Vector2.new(b.X, b.Y)
                                entry.lookOutline.From, entry.lookOutline.To = fromPoint, toPoint
                                entry.lookOutline.Color = CONFIG.OutlineColor
                                entry.lookOutline.Thickness = math.max(3 * scale, 2)
                                entry.lookOutline.Visible = true
                                entry.look.From, entry.look.To = fromPoint, toPoint
                                entry.look.Color = color
                                entry.look.Thickness = math.max(1 * scale, 1)
                                entry.look.Visible = true
                            end
                        end

                        if entry.arrow then entry.arrow.Visible = false end

                    elseif CONFIG.OffScreenArrows and entry.arrow then
                        -- Not on screen, so no box - but we can still point.
                        drawArrow(entry, camera, body.Position, color, viewport)
                        for _, segment in ipairs(entry.corners) do
                            segment.outline.Visible = false
                            segment.color.Visible = false
                        end
                        entry.name.Visible = false
                        entry.info.Visible = false
                        entry.healthBack.Visible = false
                        entry.healthFill.Visible = false
                        entry.look.Visible = false
                        entry.lookOutline.Visible = false
                        drawn = true
                    end

                    if CONFIG.Highlight and character then
                        ensureHighlight(entry, character, color)
                    elseif entry.highlight then
                        entry.highlight.Enabled = false
                    end
                end
            end
        end

        if not drawn then
            hideEntry(entry)
            if entry.highlight then
                entry.highlight.Enabled = false
            end
        end
    end
end

--=============================================================================
-- Wiring
--=============================================================================

for _, player in ipairs(Players:GetPlayers()) do
    if player ~= LocalPlayer then
        entryFor(player)
    end
end

local addedConn = Players.PlayerAdded:Connect(function(player)
    if env.__PlayerEspToken ~= Token then return end
    entryFor(player)
end)

local removingConn = Players.PlayerRemoving:Connect(function(player)
    local entry = Entries[player]
    if entry then
        destroyEntry(entry)
        Entries[player] = nil
    end
end)

local renderConn = RunService.RenderStepped:Connect(function()
    if env.__PlayerEspToken ~= Token then return end
    local ok, err = pcall(render)
    if not ok then
        warn("[Player ESP] " .. tostring(err))
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================
-- Drawing objects are not parented to anything, so nothing removes them for us.
-- Missing one leaves it burned onto the screen until the game is restarted.

env.__PlayerEspCleanup = function()
    env.__PlayerEspToken = nil
    pcall(function() renderConn:Disconnect() end)
    pcall(function() addedConn:Disconnect() end)
    pcall(function() removingConn:Disconnect() end)

    for player, entry in pairs(Entries) do
        destroyEntry(entry)
        Entries[player] = nil
    end

    env.__PlayerEspCleanup = nil
end

notify("active" .. (HAS_TRIANGLE and "" or " - no Triangle support, arrows disabled"))
