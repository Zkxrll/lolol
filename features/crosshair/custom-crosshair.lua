--[[============================================================================
    CUSTOM CROSSHAIR  -  draw your own crosshair over the game's
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Draws a crosshair at the centre of your screen with full control over its
    shape: four arms you can enable individually, a centre dot, length,
    thickness, gap, outline, per-arm colours, an optional spin, an optional
    colour cycle, a breathing gap, and text underneath it.

    It draws OVER the game's crosshair rather than replacing it. If you want
    only yours, turn the game's own crosshair off in its settings.

    WHAT IS NOT HERE
    The full script also supports using an image as the crosshair, and having
    the crosshair follow the nearest target around the screen. The image option
    depends on `Drawing.new("Image")`, which many executors either lack or
    implement differently, and follow-target needs the target selection from
    `combat/aimbot.lua`. Both are left out to keep this file dependency-free.

===============================================================================
    WHY THIS IS THE EASIEST FILE HERE
===============================================================================

    It reads nothing from the game. No modules, no hooks, no remotes, no
    upvalues, no raycasts. It draws shapes at the middle of your screen.

    That makes it a good place to start if you want to change something and see
    what happens. Every value in CONFIG maps to something you can see
    immediately, and there is nothing to break.

    It is also completely undetectable, for the same reason: nothing about it is
    observable from inside the game. It never touches the game's instance tree
    and it never sends anything.

===============================================================================
    HOW THE ARMS ARE BUILT
===============================================================================

    Each arm is a line from an inner point to an outer point:

        inner = centre + direction * gap
        outer = centre + direction * (gap + length)

    where `direction` is a unit vector: up, down, left or right. Building them
    from a direction vector rather than hard-coded coordinates means rotation
    comes for free - spin the direction vectors and the whole crosshair spins,
    with no special case anywhere.

    Every arm is drawn TWICE: a thicker dark line first, the coloured line on
    top. That is what keeps a white crosshair visible against a white wall.
    Drawing order matters here, and Drawing has no z-index you can rely on
    across executors, so the outline is simply created first.

    THE GAP AND "SPREAD"
    `Gap` is the empty space in the middle, which is what makes a crosshair
    usable rather than a plus sign covering what you are shooting at.

    The `SpreadPulse` option animates that gap between a minimum and a maximum
    on a cosine cycle. Note what it is NOT: it does not read your weapon's
    actual spread. It is a decorative breathing animation - the original names
    it "Spread", which is misleading, and this file keeps the behaviour but not
    the name.

        wave = 0.5 - 0.5 * cos(elapsed * speed)

    A raw cosine runs -1..1; that expression maps it to 0..1 so it can be used
    directly to blend between the minimum and maximum.

===============================================================================
    THE COLOUR CYCLE
===============================================================================

    With `ColorAnimation` on, the arms cycle through hues rather than sitting at
    a fixed colour. Each arm is given a different offset around the colour
    wheel, so the four arms are always four different colours rather than all
    flashing in unison:

        Color3.fromHSV((elapsed * speed + offset) % 1, saturation, value)

    HSV rather than RGB because "next hue" is one addition in HSV and an
    awkward piecewise mess in RGB. The `% 1` wraps the hue back round, so the
    cycle is seamless.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Which arms to draw.
    Top = true,
    Bottom = true,
    Left = true,
    Right = true,

    -- Shape, in pixels.
    Length = 12,
    Thickness = 2,
    Gap = 6,

    -- Centre dot.
    Dot = false,
    DotSize = 2,

    -- Dark border that keeps it visible on any background.
    Outline = true,
    OutlineThickness = 1,
    OutlineColor = Color3.fromRGB(0, 0, 0),

    -- Per-arm colours. Ignored while ColorAnimation is on.
    TopColor = Color3.fromRGB(255, 255, 255),
    BottomColor = Color3.fromRGB(255, 255, 255),
    LeftColor = Color3.fromRGB(255, 255, 255),
    RightColor = Color3.fromRGB(255, 255, 255),
    DotColor = Color3.fromRGB(255, 255, 255),

    -- Cycle the colours instead. See header.
    ColorAnimation = false,
    ColorSpeed = 0.35,
    ColorSaturation = 0.85,
    ColorValue = 1,

    -- Spin the whole crosshair, in degrees per second.
    Rotate = false,
    RotateSpeed = 90,

    -- Breathing gap. NOT your weapon's real spread - see header.
    SpreadPulse = false,
    SpreadMin = 4,
    SpreadMax = 16,
    SpreadSpeed = 3,

    -- Text under the crosshair. Leave empty for none.
    Text = "",
    TextSize = 14,
    TextOffset = 22,
    TextColor = Color3.fromRGB(255, 255, 255),
    TextFont = 2,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Custom Crosshair", Text = text, Duration = 4,
        })
    end)
end

if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then
    notify("your executor has no Drawing library - cannot run")
    return
end

local env = (getgenv and getgenv()) or _G
if env.__CrosshairCleanup then
    pcall(env.__CrosshairCleanup)
end

local Token = {}
env.__CrosshairToken = Token

--=============================================================================
-- The drawings
--=============================================================================
-- Created once. Nothing here is created or destroyed in the render loop - see
-- esp/player-esp.lua for why that matters.

local function newLine()
    local line = Drawing.new("Line")
    line.Visible = false
    line.Transparency = 1
    return line
end

-- The four arms, each with the direction it points in and its colour offset
-- around the wheel for the animated mode.
local Arms = {
    { key = "Top", direction = Vector2.new(0, -1), colorKey = "TopColor", hueOffset = 0 },
    { key = "Bottom", direction = Vector2.new(0, 1), colorKey = "BottomColor", hueOffset = 0.5 },
    { key = "Left", direction = Vector2.new(-1, 0), colorKey = "LeftColor", hueOffset = 0.75 },
    { key = "Right", direction = Vector2.new(1, 0), colorKey = "RightColor", hueOffset = 0.25 },
}

-- Outline created before the colour line so it renders underneath.
for _, arm in ipairs(Arms) do
    arm.outline = newLine()
    arm.line = newLine()
end

local Dot = Drawing.new("Square")
Dot.Filled = true
Dot.Thickness = 1
Dot.Transparency = 1
Dot.Visible = false

local DotOutline = Drawing.new("Square")
DotOutline.Filled = true
DotOutline.Thickness = 1
DotOutline.Transparency = 1
DotOutline.Visible = false

local Label = Drawing.new("Text")
Label.Center = true
Label.Outline = true
Label.Visible = false

--=============================================================================
-- Helpers
--=============================================================================

-- Rotate a 2D vector by an angle in radians. This is the whole of the spin
-- feature: rotate the direction vectors and everything follows.
local function rotate(vector, angle)
    local cosine, sine = math.cos(angle), math.sin(angle)
    return Vector2.new(
        vector.X * cosine - vector.Y * sine,
        vector.X * sine + vector.Y * cosine
    )
end

local function armColor(arm, elapsed)
    if not CONFIG.ColorAnimation then
        return CONFIG[arm.colorKey]
    end
    -- HSV so "next colour" is one addition. See header.
    local hue = (elapsed * CONFIG.ColorSpeed + arm.hueOffset) % 1
    return Color3.fromHSV(hue, CONFIG.ColorSaturation, CONFIG.ColorValue)
end

local function hideAll()
    for _, arm in ipairs(Arms) do
        arm.outline.Visible = false
        arm.line.Visible = false
    end
    Dot.Visible = false
    DotOutline.Visible = false
    Label.Visible = false
end

--=============================================================================
-- Drawing a frame
--=============================================================================

local Elapsed = 0

local function render(deltaTime)
    Elapsed = Elapsed + (deltaTime or 0)

    if not CONFIG.Enabled then
        hideAll()
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        hideAll()
        return
    end

    local viewport = camera.ViewportSize
    local centre = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)

    -- The breathing gap. See header for the 0.5 - 0.5*cos mapping.
    local gap = CONFIG.Gap
    if CONFIG.SpreadPulse then
        local wave = 0.5 - 0.5 * math.cos(Elapsed * CONFIG.SpreadSpeed)
        gap = gap + CONFIG.SpreadMin + (CONFIG.SpreadMax - CONFIG.SpreadMin) * wave
    end

    local angle = CONFIG.Rotate and math.rad(CONFIG.RotateSpeed * Elapsed) or 0

    for _, arm in ipairs(Arms) do
        if CONFIG[arm.key] then
            local direction = angle ~= 0 and rotate(arm.direction, angle) or arm.direction
            local inner = centre + direction * gap
            local outer = centre + direction * (gap + CONFIG.Length)
            local color = armColor(arm, Elapsed)

            if CONFIG.Outline then
                arm.outline.From = inner
                arm.outline.To = outer
                arm.outline.Color = CONFIG.OutlineColor
                arm.outline.Thickness = CONFIG.Thickness + CONFIG.OutlineThickness * 2
                arm.outline.Visible = true
            else
                arm.outline.Visible = false
            end

            arm.line.From = inner
            arm.line.To = outer
            arm.line.Color = color
            arm.line.Thickness = CONFIG.Thickness
            arm.line.Visible = true
        else
            arm.outline.Visible = false
            arm.line.Visible = false
        end
    end

    if CONFIG.Dot then
        local size = CONFIG.DotSize
        -- Position is the top-left corner of a Square, so offset by half the
        -- size to get the dot centred on the crosshair.
        if CONFIG.Outline then
            local outlineSize = size + CONFIG.OutlineThickness * 2
            DotOutline.Position = centre - Vector2.new(outlineSize, outlineSize) * 0.5
            DotOutline.Size = Vector2.new(outlineSize, outlineSize)
            DotOutline.Color = CONFIG.OutlineColor
            DotOutline.Visible = true
        else
            DotOutline.Visible = false
        end

        Dot.Position = centre - Vector2.new(size, size) * 0.5
        Dot.Size = Vector2.new(size, size)
        Dot.Color = CONFIG.ColorAnimation
            and Color3.fromHSV((Elapsed * CONFIG.ColorSpeed) % 1, CONFIG.ColorSaturation, CONFIG.ColorValue)
            or CONFIG.DotColor
        Dot.Visible = true
    else
        Dot.Visible = false
        DotOutline.Visible = false
    end

    if CONFIG.Text ~= "" then
        Label.Text = CONFIG.Text
        Label.Size = CONFIG.TextSize
        Label.Font = CONFIG.TextFont
        Label.Color = CONFIG.TextColor
        Label.Position = centre + Vector2.new(0, CONFIG.TextOffset)
        Label.Visible = true
    else
        Label.Visible = false
    end
end

local renderConn = RunService.RenderStepped:Connect(function(deltaTime)
    if env.__CrosshairToken ~= Token then return end
    local ok, err = pcall(render, deltaTime)
    if not ok then
        warn("[Custom Crosshair] " .. tostring(err))
    end
end)

--=============================================================================
-- Cleanup
--=============================================================================
-- Drawing objects belong to nothing, so nothing removes them for us. A missed
-- one stays burned onto the screen until the game restarts.

env.__CrosshairCleanup = function()
    env.__CrosshairToken = nil
    pcall(function() renderConn:Disconnect() end)

    for _, arm in ipairs(Arms) do
        pcall(function() arm.outline:Remove() end)
        pcall(function() arm.line:Remove() end)
    end
    pcall(function() Dot:Remove() end)
    pcall(function() DotOutline:Remove() end)
    pcall(function() Label:Remove() end)

    env.__CrosshairCleanup = nil
end

notify("drawn - edit the CONFIG table at the top to restyle it")
