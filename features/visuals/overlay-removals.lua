--[[============================================================================
    OVERLAY REMOVALS  -  delete the effects the game draws over your screen
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Six things the game paints on top of your view, removed:

        AdsVignette      the dark edges when you aim down sights
        GunTracers       the streaks your own bullets leave
        MuzzleFlash      the flash at the end of your gun
        ScopeOverlay     the black circle and blur when scoped
        ScopeReticle     the crosshair drawn inside the scope
        GameHitsound     the game's own hitmarker sound

===============================================================================
    SIX REMOVALS, FIVE DIFFERENT TECHNIQUES
===============================================================================

    Every one of these deletes a visual effect, and no two do it the same way.
    Read them in this order - it is a tour of everything you can do to a
    function you did not write, from the blunt to the surgical.

    1. REPLACE THE METHOD          (GameHitsound)

        rawset(viewModel, "PlayHitmarkerSound", function() end)

       The simplest thing that works. Find the method, put an empty function
       where it was, keep the original so you can put it back. Use this when the
       whole method does only the thing you want gone.

    2. REPLACE WHAT IT SEES        (MuzzleFlash)

        debug.setupvalue(muzzleFlash, 2, { PlayParticles = function() end })

       `MuzzleFlash` does more than one thing, so blanking it breaks the rest.
       Instead the particle library it reaches for is swapped for a stub with
       the same shape. The function runs completely and normally; the one call
       we care about goes nowhere.

       This is the pattern that runs through the whole project - see
       [`../movement/walkspeed-and-slide.lua`](../movement/walkspeed-and-slide.lua)
       and [`../misc/device-spoof.lua`](../misc/device-spoof.lua). Change what
       one function sees rather than changing the thing itself, and nothing else
       in the game notices.

    3. WRAP IT AND UNDO IT         (ScopeOverlay, ScopeReticle)

        local original = Scope.SetActive
        rawset(Scope, "SetActive", function(self, active)
            original(self, active)
            self.CircleFrame.Visible = false
        end)

       Sometimes the effect is built by code you cannot usefully interfere with.
       So let it run, then immediately hide what it made. It costs a frame of
       work you throw away, but the game's own code stays in charge of building
       the thing, which means it never gets confused about what state it is in.

       Note the wrapper calls the original through `coroutine.wrap`. That is
       from the original implementation and it is deliberate: `SetActive` can
       yield, and running it in its own coroutine means our re-hide happens
       immediately rather than waiting on it.

    4. CHANGE A NUMBER INSIDE IT   (AdsVignette)

       The vignette is drawn like this, inside the game's own update function:

            AimingVignette.ImageTransparency = 1 - CurrentAimValue

       There is no method to blank and no upvalue to swap - the effect is one
       arithmetic expression. But that `1` is a constant in the compiled
       function, and constants can be edited:

            debug.setconstant(update, 2, 999)

       Now the game computes `999 - CurrentAimValue`, which is way past fully
       transparent for every possible aim value, so the vignette never appears.
       The function is untouched, nothing is wrapped, and the effect is gone
       because its own maths now produces nothing.

       This is `debug.setconstant`, and it is the most surgical tool in the box.
       You are editing a literal inside compiled bytecode. Save the original
       value; there is no other way back.

    5. CHANGE WHICH FUNCTION IT CALLS   (GunTracers)

       The best one. Tracers are drawn by a line inside `_LocalTracers` that
       amounts to `self:_Tracers(...)`. That method name is a *string* constant,
       so:

            rawset(gun, "_Tracers\0NoGunTracers", function() end)
            debug.setconstant(localTracers, index, "_Tracers\0NoGunTracers")

       A no-op is planted under a nonsense name, and the string constant is
       repointed at it. The game still looks up a method, still finds one, still
       calls it, still gets a clean return - it is just a different method now.

       Why the `\0`? Lua strings can hold any byte, including a zero. A name
       with a NUL in it can never collide with a real field, and cannot be typed
       by anything else. It is a way of saying "this key is mine" that is
       impossible to get wrong.

       Compare this with 1: blanking `_Tracers` itself would break tracers for
       every gun in the game including other people's. This changes what one
       function does, and nothing else.

===============================================================================
    NOT IN THIS FILE
===============================================================================

    The full script has two more removals - No Flashbang and No Burn - that work
    a different way again: they intercept the replicated packet that tells your
    client to play the effect, and refuse it, so the effect is never created at
    all. That needs the shared replication hook (the same machinery as
    [`../combat/no-spread-and-grenade-fuse.lua`](../combat/no-spread-and-grenade-fuse.lua))
    rather than anything local, so it does not fit a standalone. The hitmarker
    removal is likewise part of the native crosshair wrapper.

    REQUIREMENTS
    `debug.setconstant` and `debug.getconstants` (for the vignette and tracers),
    `debug.setupvalue` and `debug.getupvalue` (for the muzzle flash). The other
    three need nothing. Each removal is checked separately, so on a limited
    executor the ones that can work still do.

============================================================================--]]

local CONFIG = {
    AdsVignette = true,
    GunTracers = true,
    MuzzleFlash = true,
    ScopeOverlay = true,
    ScopeReticle = true,
    GameHitsound = false,   -- only useful if you have your own hit sound

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- A NUL in the name makes collision impossible. See header.
local TRACER_SENTINEL = "_Tracers\0NoGunTracers"

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Overlay Removals", Text = text, Duration = 5,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__OverlayRemovalsCleanup then
    pcall(env.__OverlayRemovalsCleanup)
end

local Token = {}
env.__OverlayRemovalsToken = Token

-- Everything needed to put each removal back, exactly.
local Restore = {}
local applied = {}

--=============================================================================
-- Finding the game's modules
--=============================================================================

local MODULE_PATHS = {
    Other = { "Modules", "ClientReplicatedClasses", "ClientFighter", "ClientItem", "ItemInterface", "Other" },
    Scope = { "Modules", "ClientReplicatedClasses", "ClientFighter", "ClientItem", "ItemInterface", "Mouse", "Scope" },
    Gun = { "Modules", "ItemTypes", "Gun" },
    ClientViewModel = { "Modules", "ClientReplicatedClasses", "ClientFighter", "ClientItem", "ClientViewModel" },
}

local ModuleCache = {}

local function requireModule(key)
    if ModuleCache[key] then return ModuleCache[key] end

    local cursor = LocalPlayer:FindFirstChild("PlayerScripts")
    for _, segment in ipairs(MODULE_PATHS[key] or {}) do
        cursor = cursor and cursor:FindFirstChild(segment)
    end
    if not cursor then return nil end

    local ok, value = pcall(require, cursor)
    if not ok or type(value) ~= "table" then return nil end

    ModuleCache[key] = value
    return value
end

local function has(...)
    for _, name in ipairs({ ... }) do
        if type(name) == "string" then
            local fn = debug and rawget(debug, name)
            if type(fn) ~= "function" then return false end
        end
    end
    return true
end

--=============================================================================
-- 1. Replace the method
--=============================================================================

local function removeGameHitsound()
    local viewModel = requireModule("ClientViewModel")
    local method = viewModel and rawget(viewModel, "PlayHitmarkerSound") or nil
    if type(method) ~= "function" then return false end

    rawset(viewModel, "PlayHitmarkerSound", function() end)
    Restore.Hitsound = function()
        rawset(viewModel, "PlayHitmarkerSound", method)
    end
    return true
end

--=============================================================================
-- 2. Replace what it sees
--=============================================================================

local function removeMuzzleFlash()
    if not has("getupvalue", "setupvalue") then return false end

    local viewModel = requireModule("ClientViewModel")
    local muzzleFlash = viewModel and rawget(viewModel, "MuzzleFlash") or nil
    if type(muzzleFlash) ~= "function" then return false end

    -- Upvalue 2 is the particle library the function calls PlayParticles on.
    local original = debug.getupvalue(muzzleFlash, 2)
    if type(original) ~= "table" then return false end

    -- Same shape, does nothing. The function itself runs start to finish.
    debug.setupvalue(muzzleFlash, 2, { PlayParticles = function() end })
    Restore.Muzzle = function()
        debug.setupvalue(muzzleFlash, 2, original)
    end
    return true
end

--=============================================================================
-- 3. Wrap it and undo it
--=============================================================================
-- One hook serves both scope removals, because both are frames created by the
-- same call. Which of them get hidden is decided each time it runs, so
-- toggling one at runtime needs no rehooking.

local function ensureScopeHook()
    if Restore.Scope then return true end
    if not CONFIG.ScopeOverlay and not CONFIG.ScopeReticle then return false end

    local scopeClass = requireModule("Scope")
    local setActive = scopeClass and rawget(scopeClass, "SetActive") or nil
    if type(setActive) ~= "function" then return false end

    rawset(scopeClass, "SetActive", function(scopeObject, active)
        -- In its own coroutine: SetActive can yield, and we want to re-hide
        -- immediately rather than after it finishes. See header.
        coroutine.wrap(setActive)(scopeObject, active)

        if not rawget(scopeObject, "_is_scope_active") then return end

        if CONFIG.ScopeOverlay then
            local circle = rawget(scopeObject, "CircleFrame")
            local blur = rawget(scopeObject, "BlurFrame")
            if circle then circle.Visible = false end
            if blur then blur.Visible = false end
        end

        if CONFIG.ScopeReticle then
            local reticle = rawget(scopeObject, "ReticleContainer")
            if reticle then reticle.Visible = false end
        end
    end)

    Restore.Scope = function()
        rawset(scopeClass, "SetActive", setActive)
    end
    return true
end

--=============================================================================
-- 4. Change a number inside it
--=============================================================================

local function removeAdsVignette()
    if not has("getconstants", "setconstant") then return false end

    local other = requireModule("Other")
    local update = other and rawget(other, "Update") or nil
    if type(update) ~= "function" then return false end

    -- Constant 2 is the literal `1` in `1 - CurrentAimValue`. See header.
    local original = nil
    for index, value in debug.getconstants(update) do
        if index == 2 then
            original = value
            break
        end
    end
    if type(original) ~= "number" then return false end

    debug.setconstant(update, 2, 999)
    Restore.Vignette = function()
        debug.setconstant(update, 2, original)
    end
    return true
end

--=============================================================================
-- 5. Change which function it calls
--=============================================================================

local function removeGunTracers()
    if not has("getconstants", "setconstant") then return false end

    local gun = requireModule("Gun")
    local localTracers = gun and rawget(gun, "_LocalTracers") or nil
    if type(localTracers) ~= "function" then return false end

    -- Find the method name it calls, then point that name somewhere harmless.
    for index, value in debug.getconstants(localTracers) do
        if value == "_Tracers" then
            rawset(gun, TRACER_SENTINEL, function() end)
            debug.setconstant(localTracers, index, TRACER_SENTINEL)

            Restore.Tracers = function()
                debug.setconstant(localTracers, index, value)
                rawset(gun, TRACER_SENTINEL, nil)
            end
            return true
        end
    end
    return false
end

--=============================================================================
-- Apply
--=============================================================================

local function apply(name, enabled, fn)
    if not enabled then return end
    local ok, result = pcall(fn)
    if ok and result then
        table.insert(applied, name)
    end
end

apply("AdsVignette", CONFIG.AdsVignette, removeAdsVignette)
apply("GunTracers", CONFIG.GunTracers, removeGunTracers)
apply("MuzzleFlash", CONFIG.MuzzleFlash, removeMuzzleFlash)
apply("GameHitsound", CONFIG.GameHitsound, removeGameHitsound)

if CONFIG.ScopeOverlay or CONFIG.ScopeReticle then
    local ok, result = pcall(ensureScopeHook)
    if ok and result then
        if CONFIG.ScopeOverlay then table.insert(applied, "ScopeOverlay") end
        if CONFIG.ScopeReticle then table.insert(applied, "ScopeReticle") end
    end
end

if #applied > 0 then
    notify("removed: " .. table.concat(applied, ", "))
else
    notify("nothing could be removed - your executor may lack debug.setconstant")
end

--=============================================================================
-- Cleanup
--=============================================================================
-- Every removal above stored exactly what it needs to reverse itself. Nothing
-- here has to know how any of them worked.

env.__OverlayRemovalsCleanup = function()
    env.__OverlayRemovalsToken = nil
    for _, restore in pairs(Restore) do
        pcall(restore)
    end
    table.clear(Restore)
    table.clear(applied)
    env.__OverlayRemovalsCleanup = nil
end
