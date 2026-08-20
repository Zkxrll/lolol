--[[============================================================================
    WEAPON MODS  -  twelve weapon and camera modifiers in one file
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    This one file gives you all of the following at once. Turn the ones you want
    on in the CONFIG table below.

        WeaponAttackSpeed    shoot and swing faster
        FasterReload         shorter reloads
        NoRecoil             reduce or remove recoil kick
        ScytheDashCooldown   shorten the Scythe's dash cooldown
        FasterADS            aim down sights quicker
        FasterEquip          swap weapons quicker
        AutomaticWeapon      semi-auto guns fire while you hold the trigger
        InfiniteDoubleJumps  the double-jump limit stops mattering
        NoCameraShake        removes camera shake
        ThirdPerson          puts the camera behind you
        CustomFOV            set your own field of view
        ViewmodelOffset      move your arms and gun on screen

===============================================================================
    WHY TWELVE FEATURES ARE IN ONE FILE
===============================================================================

    Because they are not twelve features. They are three mechanisms, and every
    one of these twelve is a branch inside one of them.

    In the menu these live under three DIFFERENT tabs - Combat, Client Effects
    and Movement - which makes them look unrelated. They are not. "Infinite
    Double Jumps" looks like a movement feature and sits in the movement tab,
    but it is literally one line inside the weapon code:

        info.MaxDoubleJumps = 676767

    Splitting these into twelve files would mean twelve copies of the same
    module-resolution, hooking and restore code, each one fighting the other
    eleven over the same tables. Where they share a mechanism, they share a file.

    The two features from this menu section that are NOT here - No Spread and
    Grenade Fuse - genuinely are a different mechanism (they rewrite upvalues
    inside the game's input handler rather than touching weapon stats), so they
    get their own file.

===============================================================================
    MECHANISM 1  -  editing the weapon's stat table
===============================================================================

    Every weapon in RIVALS carries an `Info` table: a plain Lua table of numbers
    and flags describing that weapon. Cooldowns, dash timings, jump limits, and
    so on. The game reads those numbers when it needs them.

    We are the client, so that table is ours to write to. Change the number, and
    the game behaves as though the weapon was always built that way.

    Two kinds of edit happen here, and the difference matters:

    PERSISTENT edits are written once and left in place - `MaxDoubleJumps`,
    `DashCooldown`, `InputSpammingEnabled`. We save the original value first, in
    a table keyed by the item, so cleanup can put it back exactly.

    SCOPED edits are written, the game's own function is called, and the value
    is put back immediately - `ShootCooldown`, `AttackCooldown`, `BladeCooldown`.
    The number is only modified for the microsecond the game spends reading it.

    Scoped is better wherever it is possible. If the script is unloaded, or
    errors, or you alt-F4 mid-shot, the weapon's numbers are already back to
    normal - there is no window in which a snapshot of the table would look
    edited. That is why the shooting mods are scoped and the persistent list is
    as short as it is.

    Note we write persistent edits with `rawset` rather than `info.X = v`. Item
    info tables can have a metatable, and a metatable can carry a `__newindex`
    function that sees every write. `rawset` writes the raw table slot and never
    calls it. (The scoped edits use plain writes because they are reproduced
    exactly as the original implementation had them.)

    ABOUT 676767
    That is the double-jump limit we write, and it is not a meaningful number -
    it is a joke value from the original Kicia implementation, kept as-is
    because this is a reconstruction. Any number bigger than the count of jumps
    you could physically do in one life works identically.

===============================================================================
    MECHANISM 2  -  wrapping the weapon's functions
===============================================================================

    Some things aren't a number in a table, they're behaviour in a function. For
    those, we replace the function with our own, and our version calls the
    original in the middle.

        local original = module.StartShooting
        module.StartShooting = function(self, ...)
            -- our code before
            local results = table.pack(pcall(original, self, ...))
            -- our code after
            return table.unpack(results, 2, results.n)
        end

    This is the standard shape and it is worth understanding.

    We hook the MODULE, not your weapon. RIVALS builds every gun from a shared
    `Gun` module - one table that all guns use as their behaviour. Hooking that
    one table covers every gun you will ever hold, including ones that do not
    exist yet, without touching individual weapons at all.

    Three modules are hooked, because RIVALS has three weapon families:
        PlayerScripts/Modules/ItemTypes/Gun       - guns
        PlayerScripts/Modules/ItemTypes/Melee     - melee
        PlayerScripts/Modules/Items/Gunblade      - the gunblade, which is both

    `pcall` around the original is deliberate. If the game's own function throws
    while our modified numbers are in place, an unprotected error would unwind
    past our restore code and leave the weapon permanently edited. With `pcall`
    the error is caught, we restore, and only then report it.

===============================================================================
    MECHANISM 3  -  the camera controller
===============================================================================

    The camera features write to the game's own CameraController object:
    `_shake_enabled` off for no shake, `SetThirdPersonOverride(true)` for third
    person, `SetExternalFOVOffset` for FOV, `ViewModelOffsetCFrame` for arms.

    FOV is set as an OFFSET rather than a value on purpose. The game constantly
    changes your FOV itself - sprinting, aiming, ability effects. If we assigned
    a fixed number every frame we would be in a fight with the game and all of
    those effects would break. `SetExternalFOVOffset` is the game's own
    supported way to add to whatever FOV it currently wants, so zoom still works
    on top of your setting. The offset we register is (yourFOV - baseFOV).

    Viewmodel offset MULTIPLIES the original CFrame rather than replacing it, so
    your offset is applied relative to wherever the game is holding the gun,
    which keeps working as the game moves it around.

    REQUIREMENTS
    Nothing exotic - no executor-specific functions at all. If your executor can
    `require` a module, it can run this.

============================================================================--]]

local CONFIG = {
    ---------------------------------------------------------------------------
    -- Weapon stats
    ---------------------------------------------------------------------------

    -- Shoot and swing faster. The boost is a percentage: 85 means cooldowns
    -- become 1/1.85 of normal. Original menu max is 85.
    WeaponAttackSpeed = true,
    WeaponSpeedBoost = 85,

    -- Shorter reloads, as a percentage cut from every reload timing.
    -- Original menu max is 20 - reloads are animation-driven and cutting more
    -- than that desynchronises the animation from the ammo count.
    FasterReload = true,
    ReloadSpeedBoost = 20,

    -- Recoil reduction, as a percentage. 100 = no recoil at all.
    NoRecoil = false,
    RecoilReduction = 100,

    -- Scythe dash cooldown reduction, as a percentage.
    ScytheDashCooldown = false,
    DashCooldownReduction = 75,

    -- Aim-down-sights speed boost, as a percentage. Original menu max is 85.
    FasterADS = true,
    ADSSpeedBoost = 85,

    -- Weapon swap speed boost, as a percentage. Original menu max is 80.
    FasterEquip = true,
    EquipSpeedBoost = 80,

    -- Semi-auto weapons keep firing while the trigger is held.
    AutomaticWeapon = false,

    -- Remove the double jump limit.
    InfiniteDoubleJumps = false,

    ---------------------------------------------------------------------------
    -- Camera
    ---------------------------------------------------------------------------

    NoCameraShake = false,
    ThirdPerson = false,

    CustomFOV = false,
    FOV = 80,               -- menu range is 50 to 130

    ViewmodelOffset = false,
    ViewmodelX = 0,         -- menu range is -3 to 3 on each axis
    ViewmodelY = 0,
    ViewmodelZ = 0,

    ---------------------------------------------------------------------------

    -- How often to re-check for new weapons, respawns and a rebuilt camera.
    RefreshInterval = 0.5,

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
            Title = "Weapon Mods", Text = text, Duration = 4,
        })
    end)
end

local function report(where, err)
    warn(("[Weapon Mods] %s failed: %s"):format(where, tostring(err)))
end

local env = (getgenv and getgenv()) or _G
if env.__WeaponModsCleanup then
    pcall(env.__WeaponModsCleanup)
end

local Token = {}
env.__WeaponModsToken = Token

--=============================================================================
-- Finding the game's modules
--=============================================================================
-- Each of these is cached after the first success. They are all `require`d
-- module scripts sitting in your own PlayerScripts, which is client-side and
-- readable by anything running on your machine.

local Cache = {}

local function requireChild(parent, name)
    local module = parent and parent:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    return ok and result or nil
end

local function playerModules()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    return playerScripts and playerScripts:FindFirstChild("Modules"),
        playerScripts and playerScripts:FindFirstChild("Controllers")
end

local function gunModule()
    if Cache.Gun then return Cache.Gun end
    local modules = playerModules()
    Cache.Gun = requireChild(modules and modules:FindFirstChild("ItemTypes"), "Gun")
    return Cache.Gun
end

local function meleeModule()
    if Cache.Melee then return Cache.Melee end
    local modules = playerModules()
    Cache.Melee = requireChild(modules and modules:FindFirstChild("ItemTypes"), "Melee")
    return Cache.Melee
end

local function gunbladeModule()
    if Cache.Gunblade then return Cache.Gunblade end
    local modules = playerModules()
    Cache.Gunblade = requireChild(modules and modules:FindFirstChild("Items"), "Gunblade")
    return Cache.Gunblade
end

local function cameraController()
    if Cache.Camera then return Cache.Camera end
    local _, controllers = playerModules()
    local controller = requireChild(controllers, "CameraController")
    if type(controller) ~= "table" then return nil end
    Cache.Camera = controller
    return controller
end

-- Your fighter: the object holding your weapons. `Items` is the table of every
-- weapon you are carrying; `EquippedItem` is the one in your hands.
local function localFighter()
    if not Cache.FighterController then
        local _, controllers = playerModules()
        Cache.FighterController = requireChild(controllers, "FighterController")
    end
    local controller = Cache.FighterController
    if type(controller) ~= "table" then return nil end

    local fighter = controller.LocalFighter
    if not fighter and type(controller.GetFighter) == "function" then
        local ok, value = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = ok and value or nil
    end
    return type(fighter) == "table" and fighter or nil
end

--=============================================================================
-- MECHANISM 1  -  persistent stat edits
--=============================================================================
-- Applied to every weapon you carry and re-applied whenever you pick one up.
-- Originals are saved per item so cleanup restores exactly what was there,
-- including "there was no such field at all", which is not the same as zero.

local OriginalInfo = {}

local function storeOriginal(item)
    if type(item) ~= "table" or OriginalInfo[item] ~= nil then return end

    local info = item.Info
    if type(info) ~= "table" then return end

    local inputSpamming = rawget(info, "InputSpammingEnabled")
    OriginalInfo[item] = {
        Info = info,
        HasDashCooldown = rawget(info, "DashCooldown") ~= nil,
        DashCooldown = rawget(info, "DashCooldown"),
        HasMaxDoubleJumps = rawget(info, "MaxDoubleJumps") ~= nil,
        MaxDoubleJumps = rawget(info, "MaxDoubleJumps"),
        HasInputSpamming = inputSpamming ~= nil,
        -- Cloned, because this one is a table. Keeping the reference would mean
        -- our own edits below quietly corrupt the "original" we are holding.
        InputSpamming = type(inputSpamming) == "table" and table.clone(inputSpamming) or inputSpamming,
    }
end

local function restoreInputSpamming(info, original)
    if original.HasInputSpamming then
        rawset(info, "InputSpammingEnabled", type(original.InputSpamming) == "table"
            and table.clone(original.InputSpamming)
            or original.InputSpamming)
    else
        rawset(info, "InputSpammingEnabled", nil)
    end
end

local function applyPersistent(item)
    storeOriginal(item)

    local original = OriginalInfo[item]
    local info = original and original.Info or nil
    if type(info) ~= "table" then return end

    -- Automatic Weapon.
    -- `InputSpammingEnabled` is the game's own table of "how long before this
    -- input can repeat". Setting the shoot and reload entries to 0 means
    -- holding the button re-triggers with no delay, which turns a semi-auto
    -- into a full-auto without touching the firing code at all.
    if CONFIG.AutomaticWeapon then
        local inputSpamming = original.InputSpamming
        if type(inputSpamming) == "table" then
            local automatic = table.clone(inputSpamming)
            automatic.StartShooting = 0
            automatic.StartReloading = 0
            rawset(info, "InputSpammingEnabled", automatic)
        end
    else
        restoreInputSpamming(info, original)
    end

    -- Infinite Double Jumps. See the header for 676767.
    if CONFIG.InfiniteDoubleJumps then
        rawset(info, "MaxDoubleJumps", 676767)
    elseif original.HasMaxDoubleJumps then
        rawset(info, "MaxDoubleJumps", original.MaxDoubleJumps)
    else
        rawset(info, "MaxDoubleJumps", nil)
    end

    -- Scythe dash cooldown.
    if CONFIG.ScytheDashCooldown and type(original.DashCooldown) == "number" then
        local reduction = math.clamp(CONFIG.DashCooldownReduction, 0, 100) / 100
        rawset(info, "DashCooldown", original.DashCooldown * (1 - reduction))
    elseif original.HasDashCooldown then
        rawset(info, "DashCooldown", original.DashCooldown)
    else
        rawset(info, "DashCooldown", nil)
    end
end

local function restorePersistent(item)
    local original = OriginalInfo[item]
    local info = original and original.Info or nil
    if type(info) == "table" then
        restoreInputSpamming(info, original)

        if original.HasMaxDoubleJumps then
            rawset(info, "MaxDoubleJumps", original.MaxDoubleJumps)
        else
            rawset(info, "MaxDoubleJumps", nil)
        end

        if original.HasDashCooldown then
            rawset(info, "DashCooldown", original.DashCooldown)
        else
            rawset(info, "DashCooldown", nil)
        end
    end
    OriginalInfo[item] = nil
end

-- Watch the fighter for weapons appearing and disappearing. Re-hooked whenever
-- the fighter object itself is replaced, which happens on respawn.
local TrackedFighter, ItemAddedConn, ItemRemovedConn = nil, nil, nil

local function refreshPersistent()
    local fighter = localFighter()

    if fighter ~= TrackedFighter then
        if ItemAddedConn then ItemAddedConn:Disconnect() end
        if ItemRemovedConn then ItemRemovedConn:Disconnect() end
        ItemAddedConn, ItemRemovedConn = nil, nil
        TrackedFighter = fighter

        if fighter then
            if fighter.ItemAdded and type(fighter.ItemAdded.Connect) == "function" then
                ItemAddedConn = fighter.ItemAdded:Connect(function(item)
                    if env.__WeaponModsToken ~= Token then return end
                    local ok, err = pcall(applyPersistent, item)
                    if not ok then report("ItemAdded", err) end
                end)
            end
            if fighter.ItemRemoved and type(fighter.ItemRemoved.Connect) == "function" then
                ItemRemovedConn = fighter.ItemRemoved:Connect(function(item)
                    if env.__WeaponModsToken ~= Token then return end
                    pcall(restorePersistent, item)
                end)
            end
        end
    end

    if not fighter or type(fighter.Items) ~= "table" then return end
    for _, item in pairs(fighter.Items) do
        applyPersistent(item)
    end
end

--=============================================================================
-- MECHANISM 2  -  function hooks
--=============================================================================

local Hooks = {}   -- [module] = { [functionName] = originalFunction }

local function isHooked(module, name)
    return Hooks[module] ~= nil and Hooks[module][name] ~= nil
end

local function rememberHook(module, name, original)
    Hooks[module] = Hooks[module] or {}
    Hooks[module][name] = original
end

-- Cooldown scale. 85% boost -> 1/1.85 -> cooldowns are ~54% of normal.
local function weaponSpeedScale()
    if not CONFIG.WeaponAttackSpeed then return 1 end
    local boost = math.clamp(CONFIG.WeaponSpeedBoost, 0, 85)
    return 1 / (1 + (boost / 100))
end

-- The game sometimes calls StartShooting with the item as `self` and sometimes
-- with something else; if what we got does not look like a weapon, fall back to
-- whatever is currently equipped.
local function resolveItem(maybeItem)
    if type(maybeItem) == "table" and type(maybeItem.Name) == "string" and maybeItem.Name ~= "" then
        return maybeItem
    end
    local fighter = localFighter()
    local equipped = fighter and fighter.EquippedItem or nil
    if type(equipped) == "table" and type(equipped.Name) == "string" and equipped.Name ~= "" then
        return equipped
    end
    return nil
end

-- Shared shape for the three StartShooting hooks: scale some cooldown fields on
-- the item's Info, run the game's function, put the fields back. `fields` is a
-- list of Info field names to scale; `shouldScale` is an extra per-family test.
local function hookStartShooting(module, label, fields, shouldScale)
    if type(module.StartShooting) ~= "function" or isHooked(module, "StartShooting") then
        return
    end

    local original = module.StartShooting
    rememberHook(module, "StartShooting", original)

    module.StartShooting = function(self, ...)
        local item = resolveItem(self)
        if not item then return nil end

        local info = item.Info
        local saved = nil

        if CONFIG.WeaponAttackSpeed and info and (not shouldScale or shouldScale(item)) then
            local scale = weaponSpeedScale()
            for _, field in ipairs(fields) do
                if type(info[field]) == "number" then
                    saved = saved or {}
                    saved[field] = info[field]
                    -- Floored at 0.001 - a cooldown of exactly 0 makes some of
                    -- the game's own timing maths divide by zero.
                    info[field] = math.max(0.001, saved[field] * scale)
                end
            end
        end

        -- Note we pass `item`, not `self`. resolveItem may have substituted the
        -- equipped weapon for a `self` that was not one, and the original
        -- expects the weapon.
        local results = table.pack(pcall(original, item, ...))

        if saved then
            for field, value in pairs(saved) do
                info[field] = value
            end
        end

        if not results[1] then
            report(label, results[2])
            return nil
        end
        return table.unpack(results, 2, results.n)
    end
end

--- Reload -------------------------------------------------------------------
-- Reloads are not one number. Depending on the weapon there are two timings
-- (Regular) or six (Segmented, i.e. shotguns loading shell by shell), and the
-- field names are built from a key that changes depending on whether you are
-- reloading from empty. So we work out the key, scale every timing field that
-- belongs to it, run the reload, and put them all back.

local function resolveReloadKey(item, reloadEnum)
    local info = item and item.Info or nil
    if not info then return nil end

    if reloadEnum ~= nil and type(item.FromEnum) == "function" then
        local ok, key = pcall(function() return item:FromEnum(reloadEnum) end)
        if ok and type(key) == "string" then return key end
    end

    local ok, ammo = pcall(function() return item.Ammo end)
    if ok and type(ammo) == "number" and ammo <= 0 and info.HasEmptyReload then
        return "EmptyReload"
    end
    return "Reload"
end

local function withScaledReloadTimings(info, reloadKey, scale, callback)
    if not info or type(reloadKey) ~= "string" or scale >= 0.999 then
        return callback()
    end

    local fields
    if info.ReloadType == "Regular" then
        fields = { reloadKey .. "Length", reloadKey .. "ActionTimestamp" }
    elseif info.ReloadType == "Segmented" then
        fields = {
            reloadKey .. "StartLength",   reloadKey .. "StartActionTimestamp",
            reloadKey .. "SegmentLength", reloadKey .. "SegmentActionTimestamp",
            reloadKey .. "FinishLength",  reloadKey .. "FinishActionTimestamp",
        }
    else
        return callback()   -- unknown reload style; leave it alone
    end

    local saved = {}
    for _, field in ipairs(fields) do
        if type(info[field]) == "number" then
            saved[field] = info[field]
            info[field] = math.max(0.05, saved[field] * scale)
        end
    end

    local results = table.pack(pcall(callback))

    for field, value in pairs(saved) do
        info[field] = value
    end

    if not results[1] then
        report("reload timings", results[2])
        return nil
    end
    return table.unpack(results, 2, results.n)
end

--- Equip --------------------------------------------------------------------
-- Faster equip does not speed the animation up, it shortens the cooldown that
-- blocks you from shooting, then stops the equip animation once that shortened
-- time has passed so the visuals don't lag behind.

local function stopEquipAnimations(item)
    local viewModel = item and item.ViewModel
    if not viewModel then return end

    local target = viewModel
    if type(viewModel.StopAnimation) ~= "function" then
        target = viewModel.Animator
    end
    if not target or type(target.StopAnimation) ~= "function" then return end

    pcall(function() target:StopAnimation("Equip") end)
    pcall(function() target:StopAnimation("EquipEmpty") end)
end

--- Install all the function hooks -------------------------------------------

local function ensureGunHooks()
    local module = gunModule()
    if not module then return end

    hookStartShooting(module, "gun shooting", {
        "ShootCooldown", "ShootBurstCooldown", "QuickShotCooldown",
    })

    if type(module.StartReloading) == "function" and not isHooked(module, "StartReloading") then
        local original = module.StartReloading
        rememberHook(module, "StartReloading", original)
        module.StartReloading = function(self, forceReload, reloadEnum, animationEnum, segmentedCount)
            if not CONFIG.FasterReload then
                return original(self, forceReload, reloadEnum, animationEnum, segmentedCount)
            end

            local boost = math.clamp(CONFIG.ReloadSpeedBoost, 0, 20)
            if boost <= 0 then
                return original(self, forceReload, reloadEnum, animationEnum, segmentedCount)
            end

            local key = resolveReloadKey(self, reloadEnum)
            return withScaledReloadTimings(self and self.Info or nil, key, 1 - (boost / 100), function()
                return original(self, forceReload, reloadEnum, animationEnum, segmentedCount)
            end)
        end
    end

    -- Recoil. `_Recoil` is called with a strength multiplier; we shrink it.
    -- At 100% reduction we return without calling the original at all, rather
    -- than passing it a zero it may not be written to handle.
    if type(module._Recoil) == "function" and not isHooked(module, "_Recoil") then
        local original = module._Recoil
        rememberHook(module, "_Recoil", original)
        module._Recoil = function(self, multiplier)
            if CONFIG.NoRecoil and type(multiplier) == "number" then
                local reduction = math.clamp(CONFIG.RecoilReduction, 0, 100)
                local reduced = multiplier * (1 - (reduction / 100))
                if reduced <= 0.001 then return end
                return original(self, reduced)
            end
            return original(self, multiplier)
        end
    end

    -- ADS speed. This one returns a value rather than doing something, so the
    -- hook just multiplies the answer on the way out.
    if type(module.GetAimSpeed) == "function" and not isHooked(module, "GetAimSpeed") then
        local original = module.GetAimSpeed
        rememberHook(module, "GetAimSpeed", original)
        module.GetAimSpeed = function(self)
            local speed = original(self)
            if CONFIG.FasterADS and type(speed) == "number" then
                local boost = math.clamp(CONFIG.ADSSpeedBoost, 0, 85)
                return math.max(1, speed * (1 + (boost / 100)))
            end
            return speed
        end
    end

    if type(module.Equip) == "function" and not isHooked(module, "Equip") then
        local original = module.Equip
        rememberHook(module, "Equip", original)
        module.Equip = function(self, ...)
            local results = table.pack(original(self, ...))

            if CONFIG.FasterEquip then
                local boost = math.clamp(CONFIG.EquipSpeedBoost, 0, 80)
                local scale = 1 / (1 + (boost / 100))
                local now = tick()
                local remaining = type(self._equip_cooldown) == "number"
                    and math.max(self._equip_cooldown - now, 0) or 0

                self._equip_cooldown = now + (remaining * scale)

                -- `_equip_hash` changes every time you equip something. Storing
                -- it and comparing later means that if you swap again before
                -- this timer fires, we do NOT stop the animation of the weapon
                -- you are now holding.
                local hash = self._equip_hash
                task.delay(remaining * scale, function()
                    if self and self._equip_hash == hash then
                        stopEquipAnimations(self)
                    end
                end)
            end

            return table.unpack(results, 1, results.n)
        end
    end
end

local function ensureMeleeHooks()
    local module = meleeModule()
    if not module then return end
    hookStartShooting(module, "melee swinging", { "AttackCooldown" })
end

local function ensureGunbladeHooks()
    local module = gunbladeModule()
    if not module then return end
    -- The gunblade has a gun mode and a blade mode; only the blade half has a
    -- BladeCooldown worth scaling, and only while it is actually in blade mode.
    hookStartShooting(module, "gunblade swinging", { "BladeCooldown" }, function(item)
        return type(item.Get) == "function" and item:Get("Mode") == "Blade"
    end)
end

--=============================================================================
-- MECHANISM 3  -  camera
--=============================================================================
-- Each of these saves the original the first time it changes something, and
-- puts it back the moment its CONFIG entry is off. That means toggling a value
-- in CONFIG and re-running the file behaves correctly.

local CameraSaved = {}

local function updateCamera()
    local controller = cameraController()
    if not controller then return end

    -- Camera shake.
    if CONFIG.NoCameraShake then
        if CameraSaved.ShakeEnabled == nil then
            CameraSaved.ShakeEnabled = controller._shake_enabled
        end
        controller._shake_enabled = false
    elseif CameraSaved.ShakeEnabled ~= nil then
        controller._shake_enabled = CameraSaved.ShakeEnabled
        CameraSaved.ShakeEnabled = nil
    end

    -- Third person.
    if CONFIG.ThirdPerson then
        if not CameraSaved.ThirdPersonCaptured then
            CameraSaved.ThirdPersonCaptured = true
            CameraSaved.ThirdPersonOriginal = controller._third_person_override
        end
        if controller._third_person_override ~= true
            and type(controller.SetThirdPersonOverride) == "function" then
            controller:SetThirdPersonOverride(true)
        end
    elseif CameraSaved.ThirdPersonCaptured then
        if type(controller.SetThirdPersonOverride) == "function" then
            controller:SetThirdPersonOverride(CameraSaved.ThirdPersonOriginal)
        end
        CameraSaved.ThirdPersonCaptured = false
        CameraSaved.ThirdPersonOriginal = nil
    end

    -- FOV, as an offset from whatever the game currently wants. See header.
    if type(controller.SetExternalFOVOffset) == "function" then
        local baseFov = type(controller._base_fov) == "number" and controller._base_fov or 80
        local offset = CONFIG.CustomFOV and (CONFIG.FOV - baseFov) or 0
        controller:SetExternalFOVOffset("WeaponMods", offset)
    end

    -- Viewmodel offset, applied relative to the game's own placement.
    if CONFIG.ViewmodelOffset then
        if CameraSaved.ViewModelOriginal == nil then
            CameraSaved.ViewModelOriginal = controller.ViewModelOffsetCFrame
        end
        local offset = CFrame.new(CONFIG.ViewmodelX, CONFIG.ViewmodelY, CONFIG.ViewmodelZ)
        controller.ViewModelOffsetCFrame = (CameraSaved.ViewModelOriginal or CFrame.identity) * offset
    elseif CameraSaved.ViewModelOriginal ~= nil then
        controller.ViewModelOffsetCFrame = CameraSaved.ViewModelOriginal
        CameraSaved.ViewModelOriginal = nil
    end
end

--=============================================================================
-- Keep everything applied
--=============================================================================
-- Hooks only need installing once, but modules may not exist yet when the file
-- runs, weapons get picked up mid-match, and the camera controller is rebuilt
-- on respawn. So we just re-run the whole thing on a slow loop. Everything in
-- here is written to be safe to call repeatedly.

local function ensureAll()
    local ok, err = pcall(function()
        refreshPersistent()
        updateCamera()
        ensureGunHooks()
        ensureMeleeHooks()
        ensureGunbladeHooks()
    end)
    if not ok then report("refresh", err) end
end

ensureAll()

task.spawn(function()
    while env.__WeaponModsToken == Token do
        ensureAll()
        task.wait(CONFIG.RefreshInterval)
    end
end)

-- On respawn the fighter, camera controller and weapons are all new objects.
-- The module tables are NOT - those live for the whole session, so the function
-- hooks survive and must not be reinstalled.
local characterConn = LocalPlayer.CharacterAdded:Connect(function()
    if env.__WeaponModsToken ~= Token then return end
    Cache.Camera = nil
    Cache.FighterController = nil
    table.clear(CameraSaved)
    ensureAll()
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__WeaponModsCleanup = function()
    env.__WeaponModsToken = nil

    pcall(function() characterConn:Disconnect() end)
    if ItemAddedConn then pcall(function() ItemAddedConn:Disconnect() end) end
    if ItemRemovedConn then pcall(function() ItemRemovedConn:Disconnect() end) end
    ItemAddedConn, ItemRemovedConn, TrackedFighter = nil, nil, nil

    -- Put every weapon's stats back.
    for item in pairs(OriginalInfo) do
        pcall(restorePersistent, item)
    end
    table.clear(OriginalInfo)

    -- Put the camera back. Easiest way is to turn every camera feature off and
    -- run the update once - each branch restores its own saved value.
    CONFIG.NoCameraShake = false
    CONFIG.ThirdPerson = false
    CONFIG.CustomFOV = false
    CONFIG.ViewmodelOffset = false
    pcall(updateCamera)

    -- Unhook: restore every function we replaced.
    for module, functions in pairs(Hooks) do
        for name, original in pairs(functions) do
            pcall(function() module[name] = original end)
        end
    end
    table.clear(Hooks)

    env.__WeaponModsCleanup = nil
end

notify("loaded - edit the CONFIG table at the top to pick features")
