--[[============================================================================
    STRETCHED RESOLUTION  -  squash the view so targets look wider
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Squeezes the horizontal or vertical axis of your view. Squashing X makes
    everything on screen wider, including players, which is the look people go
    to stretched resolutions in other games for. It is done inside the camera
    rather than by changing your monitor.

===============================================================================
    IDEA 1: A CFrame IS A MATRIX, AND YOU CAN PUT ANYTHING IN IT
===============================================================================

    The whole effect is one multiply:

        camera.CFrame = base * CFrame.new(
            0, 0, 0,
            xRatio, 0, 0,
            0, yRatio, 0,
            0, 0, 1
        )

    That twelve-argument `CFrame.new` is the long form: three numbers of
    position, then the nine numbers of a 3x3 matrix, given as rows. Normally
    that matrix is a pure rotation and every one of its columns is length 1 -
    that is what makes it a rotation rather than a distortion.

    Here it is deliberately not. Putting `xRatio` where a 1 belongs scales the
    camera's right-axis, which scales the horizontal field of view, which
    stretches everything horizontally on screen. It is a malformed CFrame, and
    Roblox renders it perfectly happily.

    Worth knowing because CFrames are usually treated as opaque "position and
    rotation" objects. They are 3x4 matrices, they compose by multiplication,
    and if you are willing to write values a rotation would never contain you
    can shear, scale and mirror with the same one operation.

===============================================================================
    IDEA 2: WHEN YOU WRITE Camera.CFrame DECIDES WHETHER IT WORKS
===============================================================================

    Everywhere else in this project you will find the rule "never write
    `Camera.CFrame` in this game, it does nothing" - see
    [`../combat/aimbot.lua`](../combat/aimbot.lua), which has to go through the
    camera controller's `SetRotation` instead. This file writes `Camera.CFrame`
    directly and it works. Both are true, and the difference is timing:

        RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, fn)

    Roblox's render step runs callbacks in priority order, and the game's camera
    controller sits at `RenderPriority.Camera`. Write before that and your value
    is overwritten a moment later, every frame, which is why aiming this way
    fails. Bind at `Camera + 1` and you run immediately after it, so you are
    reading a camera the game has already finished with.

    That is why aiming and stretching need different approaches even though both
    "write the camera":

        aiming     -> tell the controller where to look, it decides the CFrame
        stretching -> let it decide, then post-process the result

    Anything you want applied on top of a system rather than instead of it wants
    to run after that system, and render priority is how you say so.

===============================================================================
    RESTORING IT
===============================================================================

    On cleanup, the last value written is compared against what is on the camera
    now:

        if camera.CFrame == lastResult then camera.CFrame = lastBase end

    Only if they still match is the un-stretched value put back. If the game has
    moved the camera since - because you died, respawned, or a cutscene took
    over - the stored base is stale, and forcing it would yank the camera to
    wherever it was pointing several seconds ago.

    Restoring state is not just "put the old value back". It is "put the old
    value back if the world still looks like the one I took it from". Check
    before you restore, every time.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- 1 is untouched. Lower X squashes horizontally, which makes everything
    -- look wider. 0.7-0.85 is the usual range; below 0.5 is unplayable.
    XRatio = 0.8,
    YRatio = 1,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local BIND_NAME = "StandaloneStretchedResolution"

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Stretched Resolution", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__StretchedResolutionCleanup then
    pcall(env.__StretchedResolutionCleanup)
end

local Token = {}
env.__StretchedResolutionToken = Token

-- What we last wrote, and what it was before we wrote it. See header.
local Last = {
    Camera = nil,
    Base = nil,
    Result = nil,
}

--=============================================================================
-- The stretch
--=============================================================================

local function apply()
    if env.__StretchedResolutionToken ~= Token then return end

    local camera = Workspace.CurrentCamera
    if not camera or not CONFIG.Enabled then return end

    local xRatio = math.clamp(CONFIG.XRatio, 0.01, 1)
    local yRatio = math.clamp(CONFIG.YRatio, 0.01, 1)

    -- Whatever the game's camera controller just decided.
    local base = camera.CFrame

    -- Position untouched; the 3x3 that follows is a scale, not a rotation.
    local result = base * CFrame.new(
        0, 0, 0,
        xRatio, 0, 0,
        0, yRatio, 0,
        0, 0, 1
    )

    Last.Camera = camera
    Last.Base = base
    Last.Result = result

    camera.CFrame = result
end

-- Camera + 1: immediately after the game's own camera step. See header.
RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, apply)

notify(string.format("active - %.2f x %.2f", CONFIG.XRatio, CONFIG.YRatio))

--=============================================================================
-- Cleanup
--=============================================================================

env.__StretchedResolutionCleanup = function()
    env.__StretchedResolutionToken = nil
    pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)

    -- Only undo it if nothing has moved the camera since. See header.
    local camera = Last.Camera
    if camera and camera.Parent and Last.Base and Last.Result
        and camera.CFrame == Last.Result then
        camera.CFrame = Last.Base
    end

    Last.Camera = nil
    Last.Base = nil
    Last.Result = nil
    env.__StretchedResolutionCleanup = nil
end
