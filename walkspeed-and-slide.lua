--[[============================================================================
    WALKSPEED + SLIDING SPEED
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Multiplies how fast you run, and separately how fast you slide.

    WHY BOTH ARE IN ONE FILE
    They are not two features. They are two answers from the same hook, and you
    physically cannot install one without the other. Read on.

===============================================================================
    HOW IT WORKS
===============================================================================

    The obvious way to move faster is `Humanoid.WalkSpeed = 32`. That does not
    work here. RIVALS computes your speed itself every frame in its own
    MechanicsController and writes the result over whatever you set. You would be
    fighting the game 60 times a second and losing.

    So instead of fighting the output, we change the input.

    Inside the game's code there is a function `_GetWalkSpeed()`. It reads your
    base speed out of a constants table that looks roughly like:

        { BASE_WALKSPEED = 16, ... }

    That table is an UPVALUE of `_GetWalkSpeed` - a local variable captured from
    the enclosing scope when the function was created. Executors can read and
    replace upvalues with `debug.getupvalues` and `debug.setupvalue`.

    So we find that table, and swap it for a fake one:

        setmetatable({}, { __index = function(_, key) ... end })

    The fake table is EMPTY. Every read falls through to `__index`, which is our
    function. Now every time the game asks "what is the base walk speed?", we
    answer - and we can answer with `16 * yourMultiplier` instead of `16`.

    The game then does all of its own math on our number. Acceleration, friction,
    slide curves, everything downstream still works exactly as designed, because
    from the game's point of view nothing is wrong - the base speed constant just
    happens to be a bigger number today.

    ONE HOOK, TWO FEATURES
    Here is why walk and slide share a file. Sliding uses the SAME function. The
    game's slide routine calls `_GetWalkSpeed()` too. So when our `__index` runs,
    we have to work out who is asking:

        debug.info(3, 'n') == 'Slide'

    `debug.info` walks up the call stack. Level 3 is the function that called the
    function that called us, and `'n'` asks for its name. If that name is
    `Slide`, the game is mid-slide and we return the sliding multiplier.
    Otherwise we return the walking multiplier.

    One injection point. Two behaviours. You cannot install half of it, which is
    why splitting these into two files would be a lie about how the code works.

===============================================================================
    ABOUT THE :Kick() IN THIS FILE  -  please read before you panic
===============================================================================

    Our fake table kicks you out of the game if anything reads a key other than
    BASE_WALKSPEED.

    That looks alarming in a script you downloaded from the internet, so: this is
    not ours, and it is not malicious. It is reproduced from the original Kicia
    implementation (annotated at [111866] in the reference source), and it is a
    SELF-PROTECTION measure, not an attack on you.

    The reasoning behind it: our fake table only knows how to answer
    BASE_WALKSPEED. If a future game update makes `_GetWalkSpeed` read some other
    constant from that table, our fake returns nil, and nil flows into the game's
    physics math. That produces obviously broken movement - which is exactly the
    kind of thing that gets you flagged. Leaving the match immediately is safer
    than skating around at a nonsense speed in front of everyone.

    It is kept because this project is a faithful reconstruction, and quietly
    "improving" a guard changes behaviour in ways that are hard to see. If you
    would rather it did not, delete the two lines marked SELF-PROTECTION below and
    return the real base speed instead. Then know that a game update can leave you
    moving strangely rather than disconnected.

===============================================================================

    REQUIREMENTS
    `debug.getupvalues` and `debug.setupvalue`. Many executors have these; some
    do not. The script checks and tells you rather than half-working.

============================================================================--]]

local CONFIG = {
    -- Walking speed multiplier. 1 = normal, 2 = double.
    WalkMultiplier = 2,
    WalkEnabled = true,

    -- Sliding speed multiplier. The original ships a much larger default here
    -- because slides are short and the game's own slide friction eats most of it.
    SlideMultiplier = 10,
    SlideEnabled = true,

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Speed", Text = text, Duration = 4,
        })
    end)
end

-- Feature-detect honestly. A stub that exists but does nothing is worse than a
-- missing function, because it fails silently.
if type(debug) ~= "table"
    or type(debug.getupvalues) ~= "function"
    or type(debug.setupvalue) ~= "function"
    or type(debug.info) ~= "function" then
    notify("your executor lacks debug.getupvalues/setupvalue - cannot run")
    return
end

local env = (getgenv and getgenv()) or _G

-- The hook cannot be uninstalled cleanly once the upvalue is swapped, so we
-- install it at most once and let re-runs just retune the multipliers.
local Shared = env.__SpeedHookState
if Shared then
    Shared.WalkMultiplier = CONFIG.WalkMultiplier
    Shared.WalkEnabled = CONFIG.WalkEnabled
    Shared.SlideMultiplier = CONFIG.SlideMultiplier
    Shared.SlideEnabled = CONFIG.SlideEnabled
    notify("multipliers updated")
    return
end

Shared = {
    WalkMultiplier = CONFIG.WalkMultiplier,
    WalkEnabled = CONFIG.WalkEnabled,
    SlideMultiplier = CONFIG.SlideMultiplier,
    SlideEnabled = CONFIG.SlideEnabled,
}
env.__SpeedHookState = Shared

--=============================================================================
-- Find the game's speed function
--=============================================================================

local function resolveMechanicsController()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local mechanicsModule = controllers and controllers:FindFirstChild("MechanicsController")
    if not mechanicsModule then
        return nil
    end
    local ok, controller = pcall(require, mechanicsModule)
    return (ok and type(controller) == "table") and controller or nil
end

local mechanics = resolveMechanicsController()
if type(mechanics) ~= "table" then
    notify("MechanicsController not found - are you in a match yet?")
    return
end

-- `_GetWalkSpeed` lives on the class, not the instance, so we go through the
-- metatable's __index. rawget avoids running any __index of its own on the way.
local metatable = getmetatable(mechanics)
local classIndex = type(metatable) == "table" and rawget(metatable, "__index") or nil
local getWalkSpeed = type(classIndex) == "table" and rawget(classIndex, "_GetWalkSpeed") or nil

if type(getWalkSpeed) ~= "function" then
    notify("_GetWalkSpeed not found - the game has probably been updated")
    return
end

--=============================================================================
-- Find the constants upvalue
--=============================================================================
-- We do not hard-code an upvalue index. Index numbers shift whenever the game's
-- code is recompiled, so we identify the table by its CONTENT instead: the one
-- upvalue that is a table containing a BASE_WALKSPEED key. That survives updates
-- that a fixed index would not.

local upvalueIndex, realConstants
for index, value in pairs(debug.getupvalues(getWalkSpeed)) do
    if type(value) == "table" and rawget(value, "BASE_WALKSPEED") ~= nil then
        upvalueIndex = index
        realConstants = value
        break
    end
end

if upvalueIndex == nil then
    notify("speed constants not found - the game has probably been updated")
    return
end

--=============================================================================
-- Install the proxy
--=============================================================================

debug.setupvalue(getWalkSpeed, upvalueIndex, setmetatable({}, {
    __index = function(_, key)
        if key ~= "BASE_WALKSPEED" then
            -- SELF-PROTECTION (see the long note in the header). Delete these
            -- two lines and `return rawget(realConstants, key)` instead if you
            -- would rather stay in the match.
            LocalPlayer:Kick("Unexpected behavior (client physics 1)")
            return nil
        end

        local baseWalkSpeed = rawget(realConstants, "BASE_WALKSPEED")

        -- Who is asking? Level 3 of the call stack is the game routine that
        -- triggered this read.
        if Shared.SlideEnabled and debug.info(3, "n") == "Slide" then
            return baseWalkSpeed * Shared.SlideMultiplier
        end

        if Shared.WalkEnabled then
            return baseWalkSpeed * Shared.WalkMultiplier
        end

        return baseWalkSpeed
    end,
}))

notify(("installed - walk x%s, slide x%s"):format(
    tostring(CONFIG.WalkMultiplier),
    tostring(CONFIG.SlideMultiplier)
))
