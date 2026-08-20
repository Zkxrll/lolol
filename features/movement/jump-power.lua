--[[============================================================================
    JUMP POWER  -  jump higher
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Multiplies how high you jump. 2 is double height. The multiplier applies to
    normal jumps and double jumps alike, because both read the same number.

===============================================================================
    THE IDEA
===============================================================================

    Somewhere in the game there is a constant called `BASE_JUMPPOWER`, living in
    a table of movement constants. Several of the game's functions hold that
    table and read the number out of it when you jump.

    The obvious move is to find that table and write a bigger number into it.
    Don't. That table is shared - anything in the game that holds a reference to
    it now sees your edited value, permanently, and the edit sits there for
    anything to find.

    Instead we do the same thing this script does in three other places: leave
    the real table completely alone, and change what the functions that read it
    are looking at.

        real table:  { BASE_JUMPPOWER = 50, GRAVITY = ..., ... }   <- untouched

        what the     empty table with __index:
        game sees      "BASE_JUMPPOWER" -> 50 * yourMultiplier
                       anything else    -> straight from the real table

    The proxy is an EMPTY table, which matters: `__index` only runs for keys a
    table does not have, so an empty one means every single read goes through
    our function. Reads we do not care about are passed through with `rawget` on
    the original, so nothing else changes and nothing else is copied.

    Compare this to `walkspeed-and-slide.lua`, which replaces a constant the
    same way, and `combat/no-spread-and-grenade-fuse.lua`, which replaces a
    service reference the same way. It is the same idea three times: modifying
    the *view* rather than the *thing*.

===============================================================================
    FINDING THE FUNCTIONS THAT READ IT
===============================================================================

    A proxy only helps for functions we actually swap it into, so we need to
    find every function that reads BASE_JUMPPOWER. There are three, and each one
    is found a different way.

    1. `MechanicsController._HookFighter`
       Straightforward. Get the controller, look at its class table, take the
       function by name.

    2. The `EntityAdded` handler that sets up gravity
       This one is not stored anywhere we can name - it is an anonymous function
       somebody connected to a signal. So we walk the signal's list of
       connections (`_handlerListHead`, then `_next`, then `_next`...) and ask
       each connected function what literal values it contains:

           for _, constant in pairs(debug.getconstants(fn)) do
               if constant == "CustomGravity" then ... end
           end

       Every compiled Lua function carries the literals it uses - the numbers
       and strings written into its source. `debug.getconstants` reads that
       list. The gravity handler is the one that mentions "CustomGravity", so
       that string is a fingerprint that identifies it without a name.

       This is the general technique for finding an anonymous function: don't
       look for what it is called, look for something only it contains.

    3. The closures created inside that handler
       Functions defined inside a function are called protos. `debug.getprotos`
       lists them; `debug.getproto(fn, index, true)` returns the live closures
       that have actually been created from one. Those closures captured their
       own reference to the constants table when they were made, so they need
       the proxy too. This is why the file bothers with all three - miss one and
       jump power works for normal jumps but not double jumps, or the other way
       round.

===============================================================================
    RUNNING IT TWICE
===============================================================================

    If you run this file again, the scan looks at the function's upvalues and
    finds... a table. Our proxy, from last time. Wrapping a proxy in a proxy
    would multiply your jump power by the multiplier twice, and again on the
    third run.

    So the proxy answers one secret key with the original table it wraps:

        proxy["meow\0d67"]  ->  the real constants table

    The scan asks every candidate table that question first. If it answers, it
    is one of ours, and we wrap the original it hands back instead of wrapping
    the proxy. Chains never form no matter how many times you run this.

    The key contains `\0`, a null byte, which no normal code would ever use as
    a field name - so there is no chance of a real table answering by accident.
    ("meow" is the original author's; it is kept as-is because this is a
    reconstruction, not a rewrite.)

===============================================================================
    TURNING IT OFF WITHOUT A LIST
===============================================================================

    Cleanup here does not walk back through everything it patched. It just sets
    a flag, and every proxy checks that flag on its next read:

        if destroyed then
            put the original upvalue back
            return the real value
        end

    The first time the game reads the constant after you unload, the hook
    removes itself. This is a nice pattern when you have patched things you did
    not keep a list of: teardown happens on the game's schedule, from inside the
    thing being torn down, and it cannot leave a proxy stranded because a proxy
    that is never read again never mattered.

===============================================================================
    THE :Kick() LINE
===============================================================================

    Like `walkspeed-and-slide.lua`, this file contains a line that kicks you
    from the game:

        LocalPlayer:Kick("JumpPower error: ent")

    It fires in exactly one case: the gravity handler was not found. That means
    the game updated and the fingerprint no longer matches, so the hook would be
    half-installed - patched into one place and not the others. The original
    implementation treats a half-installed physics hook as unsafe and leaves
    rather than run in that state.

    It is not malicious, it is not a punishment, and it does not report you
    anywhere. If you would rather it just gave up quietly, delete the
    `LocalPlayer:Kick(...)` line marked below - the `return false` under it
    already handles the failure correctly on its own.

    It is kept because this is a reconstruction. Silently "improving" a guard
    changes behaviour in ways that are hard to notice later.

    REQUIREMENTS
    `debug.getupvalues`, `debug.setupvalue`, `debug.getconstants`,
    `debug.getprotos`, `debug.getproto`. Also needs you to be in a match with a
    character - the hook cannot be built before the game has a fighter, so it
    waits.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- How much higher you jump. 1 is normal, 2 is double.
    Multiplier = 2,

    -- How often to retry installing while you are still loading in.
    RetryInterval = 1,

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
            Title = "Jump Power", Text = text, Duration = 4,
        })
    end)
end

local missing = {}
for _, name in ipairs({ "getupvalues", "setupvalue", "getconstants", "getprotos", "getproto" }) do
    if type(debug[name]) ~= "function" then
        table.insert(missing, "debug." .. name)
    end
end
if #missing > 0 then
    notify("your executor is missing: " .. table.concat(missing, ", "))
    return
end

local env = (getgenv and getgenv()) or _G
if env.__JumpPowerCleanup then
    pcall(env.__JumpPowerCleanup)
end

local Token = {}
env.__JumpPowerToken = Token

-- Shared state the proxies read on every access. Kept in one table so that a
-- proxy installed minutes ago still sees current values.
local State = {
    destroyed = false,
    loaded = false,
}

-- The secret key a proxy answers with the table it wraps. See header.
local PROXY_MARKER = "meow\0d67"

--=============================================================================
-- Installing a proxy on one function
--=============================================================================
-- Scans the function's upvalues for the constants table and swaps in a proxy.
-- Handles the "already proxied by a previous run" case by unwrapping.

local function replaceConstants(target)
    for index, value in pairs(debug.getupvalues(target)) do
        if type(value) == "table" then
            local metatable = getmetatable(value)
            local metaIndex = type(metatable) == "table" and rawget(metatable, "__index") or nil

            local original = nil
            if type(metaIndex) == "function" then
                -- Has an __index function, so it might be one of our proxies.
                -- Ask it. pcall because an unrelated __index could error on an
                -- unexpected key.
                local ok, wrapped = pcall(function()
                    return value[PROXY_MARKER]
                end)
                original = ok and wrapped or nil
            elseif rawget(value, "BASE_JUMPPOWER") ~= nil then
                -- A plain table holding the constant. This is the real thing.
                original = value
            end

            if original ~= nil then
                local upvalueIndex = index
                debug.setupvalue(target, upvalueIndex, setmetatable({}, {
                    __index = function(_, key)
                        -- "Are you one of ours?" - see header.
                        if key == PROXY_MARKER then
                            return original
                        end

                        -- Lazy self-removal on unload.
                        if State.destroyed then
                            debug.setupvalue(target, upvalueIndex, original)
                            return rawget(original, key)
                        end

                        -- Everything except the jump constant passes straight
                        -- through, unmodified.
                        if key ~= "BASE_JUMPPOWER" then
                            return rawget(original, key)
                        end

                        return rawget(original, "BASE_JUMPPOWER")
                            * (CONFIG.Enabled and CONFIG.Multiplier or 1)
                    end,
                }))
                break   -- one constants table per function; done here
            end
        end
    end
end

--=============================================================================
-- Finding every function that reads the constant
--=============================================================================

local MechanicsCache = nil

local function mechanicsController()
    if MechanicsCache then return MechanicsCache end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("MechanicsController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    MechanicsCache = (ok and type(controller) == "table") and controller or nil
    return MechanicsCache
end

-- Walk a signal's connection list looking for the handler that mentions
-- "CustomGravity" among its literals. See header for why this works.
local function findGravityHandler(localFighter)
    local entityAdded = rawget(localFighter, "EntityAdded")
    local handler = type(entityAdded) == "table" and rawget(entityAdded, "_handlerListHead") or nil

    while type(handler) == "table" do
        local fn = rawget(handler, "_fn")
        if type(fn) == "function" then
            for _, constant in pairs(debug.getconstants(fn)) do
                if constant == "CustomGravity" then
                    return fn
                end
            end
        end
        handler = rawget(handler, "_next")
    end
    return nil
end

local function attemptLoad()
    if State.loaded then return true end

    local mechanics = mechanicsController()
    if type(mechanics) ~= "table" then return false end

    -- `_HookFighter` lives on the class table behind the controller's
    -- metatable, not on the controller itself.
    local metatable = getmetatable(mechanics)
    local classIndex = type(metatable) == "table" and rawget(metatable, "__index") or nil
    local hookFighter = type(classIndex) == "table" and rawget(classIndex, "_HookFighter") or nil
    if type(hookFighter) ~= "function" then return false end

    -- The hook cannot be built before you have a fighter. Wait rather than
    -- install a broken half of it.
    local localFighter = rawget(mechanics, "LocalFighter")
    if localFighter == nil then return false end

    -- 1. the controller method
    replaceConstants(hookFighter)

    -- 2. the connected gravity handler
    local entityCallback = findGravityHandler(localFighter)
    if entityCallback == nil then
        -- See "THE :Kick() LINE" in the header. Delete the next line if you
        -- would rather this failed quietly.
        LocalPlayer:Kick("JumpPower error: ent")
        return false
    end
    replaceConstants(entityCallback)

    -- 3. every live closure created inside that handler
    for protoIndex in pairs(debug.getprotos(entityCallback)) do
        local activated = debug.getproto(entityCallback, protoIndex, true)
        local instance = type(activated) == "table" and activated[1] or nil
        if instance ~= nil then
            replaceConstants(instance)
        end
    end

    State.destroyed = false
    State.loaded = true
    return true
end

--=============================================================================
-- Install
--=============================================================================

task.spawn(function()
    while env.__JumpPowerToken == Token and not State.loaded do
        local ok, result = pcall(attemptLoad)
        if not ok then
            warn("[Jump Power] install failed: " .. tostring(result))
        elseif result then
            notify(("active - jumping %sx higher"):format(CONFIG.Multiplier))
            break
        end
        task.wait(CONFIG.RetryInterval)
    end
end)

-- The controller and the fighter are rebuilt on respawn, so the hook has to be
-- reinstalled onto the new ones.
local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__JumpPowerToken ~= Token then return end
    MechanicsCache = nil
    State.loaded = false
    task.spawn(function()
        while env.__JumpPowerToken == Token and not State.loaded do
            local ok = pcall(attemptLoad)
            if ok and State.loaded then break end
            task.wait(CONFIG.RetryInterval)
        end
    end)
end)

--=============================================================================
-- Cleanup
--=============================================================================
-- Just raise the flag. Every proxy restores its own upvalue the next time the
-- game reads through it. See header.

env.__JumpPowerCleanup = function()
    env.__JumpPowerToken = nil
    State.destroyed = true
    State.loaded = false
    pcall(function() characterConn:Disconnect() end)
    env.__JumpPowerCleanup = nil
end
