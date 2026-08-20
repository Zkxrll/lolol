--[[============================================================================
    UNLOCK ALL COSMETICS  -  own every skin, wrap, charm, finisher and emote
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Makes the game's cosmetics menu show everything as owned, and lets you
    actually equip any of it on any weapon. Skins, wraps, charms, finishers and
    emotes.

    LOCAL ONLY, AND THIS MATTERS
    Nobody else sees any of it. Your own screen shows the skin; every other
    player sees whatever you really own. Cosmetic ownership lives on the
    server, and there is nothing a client can send that changes that - this is
    a dress-up mirror, not a shop exploit. If a script tells you otherwise it
    is either lying or it is about a game with a much worse server.

    It is the largest feature in the project and this file is the CORE of it.
    See "what the full version adds" at the bottom - the shipped version is
    around 5,000 lines, and almost all of that is presets, a live 3D previewer,
    favourites, per-weapon selection and the menu wiring. The unlock itself is
    the two techniques below.

===============================================================================
    TECHNIQUE ONE: A PROXY OVER THE SAVE DATA
===============================================================================

    Your inventory arrives from the server and is parked in a table:

        PlayerDataController.CurrentData.Data.CosmeticInventory

    The obvious move is to overwrite that field with a table saying you own
    everything. It works for about a second, because the game re-reads and
    re-writes its own save data constantly, and your value gets replaced by the
    next update from the server.

    So instead of changing the value, this changes what READING it does.
    `.Data` is replaced with a proxy table that owns nothing and stores
    nothing:

        local proxy = setmetatable({}, {
            __index = function(_, field)
                return resolveField(field, rawget(inner, field))
            end,
            __newindex = function(_, field, value)
                rawset(inner, field, value)     -- writes go straight through
            end,
        })
        rawset(currentData, "Data", proxy)

    Every read is now a function call. `resolveField` intercepts exactly two
    field names and hands back everything else untouched:

        CosmeticInventory  -> a fabricated "you own everything" table
        FavoritedCosmetics -> our own favourites
        anything else      -> the real value, unmodified

    And `__newindex` writes through to the real table, so when the game saves
    or updates its data, it lands on the genuine article. The real data is
    never modified, never overwritten, and never diverges - it is simply seen
    through a lens.

    THE EMPTY TABLE IS LOAD-BEARING. `__index` and `__newindex` only fire for
    keys the table does NOT already have. A proxy that cached anything would
    stop calling its own metamethod for that key and silently go stale. It
    stays empty forever on purpose.

    This is the most complete version of the idea that runs through this whole
    project - `../movement/walkspeed-and-slide.lua`, `../misc/device-spoof.lua`
    and `../visuals/overlay-removals.lua` are all smaller instances of it.
    Modify the view, not the thing.

===============================================================================
    TECHNIQUE TWO: CHANGING WHICH FUNCTION SOMEONE ELSE CALLS
===============================================================================

    The proxy handles what the MENU shows. It does not handle what you actually
    have equipped, because that comes from a different path:

        PlayerDataController:GetWeaponData(playerData, weaponName)

    which internally calls `PlayerDataUtility:GetWeaponData(...)`. We want our
    own function to run there - but we cannot just replace
    `PlayerDataUtility.GetWeaponData`, because plenty of other game code calls
    that same method legitimately and would get our version too.

    So instead of changing the function, we change WHICH NAME the caller looks
    up. When Luau compiles `utility:GetWeaponData(...)`, the string
    `"GetWeaponData"` is stored as a constant inside the compiled function.
    Constants can be rewritten:

        for index, value in pairs(debug.getconstants(getWeaponData)) do
            if value == "GetWeaponData" then constantIndex = index break end
        end
        debug.setconstant(getWeaponData, constantIndex, SENTINEL)
        rawset(playerDataUtility, SENTINEL, function(_, playerData, name) ... end)

    That one function now calls `utility:<SENTINEL>(...)` instead. We define
    that name on the utility table, and our code runs - for that call site and
    that call site only. The original `GetWeaponData` is completely untouched
    and everyone else who calls it gets the real one.

    This is surgical in a way that hooking is not. Hooking a function affects
    every caller; rewriting a constant affects exactly the one function whose
    bytecode you edited. When you want to intercept one specific call rather
    than one specific function, this is the tool.

    (`../visuals/overlay-removals.lua` introduces the same trick more gently,
    on the gun tracer path. Read that first if this is new.)

    THE SENTINEL should be a name nothing else could ever use - hence the
    control character in it. If the game happened to have a real method by
    that name, you would be hijacking it by accident.

    RESTORING IT is symmetric and must not be skipped: put the original string
    back with another `setconstant`, and remove the sentinel key. Leaving a
    rewritten constant behind means the game keeps calling a method that no
    longer exists the moment your script unloads.

===============================================================================
    THE INVENTORY SHAPE IS ASYMMETRIC, AND IT IS NOT A BUG
===============================================================================

    Building the "you own everything" table looks odd until you know why:

        Skin, Emote            ->  inventory[name] = true
        Wrap, Charm, Finisher  ->  inventory[name] = { [everyItemName] = true }

    A skin belongs to one specific weapon, so owning it is a yes or no. A wrap
    or a charm can go on ANY weapon, and the game tracks which weapons you own
    it for - so the value is a set of item names rather than a boolean.

    Two different shapes in one table, because they answer two different
    questions. Copy the shape the game uses; do not tidy it into something
    consistent, because the code reading it is expecting the inconsistency.

    Note also that the same `allItemNames` table is shared by reference across
    every universal cosmetic rather than copied per entry. Nothing writes to
    it, so one table is correct and cheaper - but if anything ever did write to
    it, every cosmetic would change at once. Shared immutable data is fine;
    just be sure it stays immutable.

===============================================================================
    TELLING THE MENU TO LOOK AGAIN
===============================================================================

    Installing all of the above while the cosmetics menu is already open
    changes nothing on screen, because the menu built its list from the old
    values and has no reason to rebuild.

    The game's own data object carries change signals, so we fire them:

        local events = rawget(currentData, "_value_changed_events")
        events["CosmeticInventory"]:Fire()

    Firing the game's own "this changed" signal is nearly always better than
    trying to rebuild its UI yourself. The game knows how to refresh its menu;
    it just needs to be told there is a reason to.

    REQUIREMENTS
    `debug.getconstants` and `debug.setconstant` for the equipped-item half.
    Without them the menu still shows everything as owned (the proxy needs
    nothing special) but equipping does not stick.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- What to put on which weapon. Weapon names and cosmetic names are the
    -- game's own; open the cosmetics menu with this running and every name is
    -- visible there.
    --
    -- Any field can be omitted to leave that slot alone.
    Loadout = {
        -- ["AK-47"] = { Skin = "Cyberpunk", Wrap = "Carbon", Charm = "Duck" },
        -- ["Deagle"] = { Skin = "Gold", Finisher = "Shatter" },
    },

    Notify = true,
}

-- A name nothing in the game could plausibly define. The \0 is what makes
-- that guarantee - it cannot be typed in source. See the header.
local SENTINEL = "GetWeaponData\0Unlocked"

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Unlock Cosmetics", Text = text, Duration = 5,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__UnlockCosmeticsCleanup then
    pcall(env.__UnlockCosmeticsCleanup)
end

local Token = {}
env.__UnlockCosmeticsToken = Token

local State = {
    Controller = nil,
    DataRestore = nil,          -- { Current, Inner } so the proxy can be undone
    UnlockedInventory = nil,    -- built once, cached
    Utility = nil,
    PreviousSentinel = nil,
    HookedFunction = nil,
    ConstantIndex = nil,
    OriginalConstant = nil,
    DataAddedConnection = nil,
}

--=============================================================================
-- The game's own pieces
--=============================================================================

local function requireModule(name)
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local module = modules and modules:FindFirstChild(name)
    if not module then return nil end
    local ok, result = pcall(require, module)
    return (ok and type(result) == "table") and result or nil
end

local function playerDataController()
    if State.Controller then return State.Controller end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("PlayerDataController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    State.Controller = (ok and type(controller) == "table") and controller or nil
    return State.Controller
end

--=============================================================================
-- The fabricated inventory
--=============================================================================

local function buildUnlockedInventory()
    if type(State.UnlockedInventory) == "table" then
        return State.UnlockedInventory
    end

    local cosmeticLibrary = requireModule("CosmeticLibrary")
    local itemLibrary = requireModule("ItemLibrary")
    local cosmetics = cosmeticLibrary and cosmeticLibrary.Cosmetics or nil
    local items = itemLibrary and itemLibrary.Items or nil
    if type(cosmetics) ~= "table" or type(items) ~= "table" then
        return nil
    end

    -- Built once and shared by reference across every universal cosmetic
    -- below. Nothing writes to it. See the header.
    local allItemNames = {}
    for itemName in pairs(items) do
        if type(itemName) == "string" and itemName ~= "" then
            allItemNames[itemName] = true
        end
    end

    local inventory = {}
    for cosmeticName, cosmeticData in pairs(cosmetics) do
        local cosmeticType = type(cosmeticData) == "table" and cosmeticData.Type or nil
        if type(cosmeticName) == "string" then
            -- Two different shapes, on purpose. See the header.
            if cosmeticType == "Skin" or cosmeticType == "Emote" then
                inventory[cosmeticName] = true
            elseif cosmeticType == "Wrap" or cosmeticType == "Charm"
                or cosmeticType == "Finisher" then
                inventory[cosmeticName] = allItemNames
            end
        end
    end

    State.UnlockedInventory = inventory
    return inventory
end

--=============================================================================
-- Technique one: the proxy
--=============================================================================

-- Called for every field read through the proxy. Two fields are answered
-- differently; everything else passes straight through untouched.
local function resolveField(fieldName, originalValue)
    if not CONFIG.Enabled then return originalValue end
    if fieldName == "CosmeticInventory" then
        return buildUnlockedInventory() or originalValue
    end
    return originalValue
end

local function restoreProxy()
    local restore = State.DataRestore
    if type(restore) ~= "table" then return end
    State.DataRestore = nil
    if type(restore.Current) == "table" then
        rawset(restore.Current, "Data", restore.Inner)
    end
end

local function installProxy(currentData)
    if type(currentData) ~= "table" then return false end

    local restore = State.DataRestore
    if type(restore) == "table" then
        -- Already installed on this exact object; nothing to do.
        if restore.Current == currentData then return true end
        -- A new data object means the old proxy belongs to something dead.
        restoreProxy()
    end

    local inner = rawget(currentData, "Data")
    if type(inner) ~= "table" then return false end

    -- Deliberately empty and it must stay that way - a key stored here would
    -- stop __index firing for it. See the header.
    local proxy = setmetatable({}, {
        __index = function(_, fieldName)
            return resolveField(fieldName, rawget(inner, fieldName))
        end,
        __newindex = function(_, fieldName, value)
            -- Writes go to the real table, so the game's own saves are real.
            rawset(inner, fieldName, value)
        end,
    })

    rawset(currentData, "Data", proxy)
    State.DataRestore = { Current = currentData, Inner = inner }
    return true
end

--=============================================================================
-- Technique two: the constant rewrite
--=============================================================================

local function resolveGetWeaponData()
    local controller = playerDataController()
    local metatable = type(controller) == "table" and getmetatable(controller) or nil
    local index = type(metatable) == "table" and rawget(metatable, "__index") or nil
    return type(index) == "table" and rawget(index, "GetWeaponData") or nil
end

-- The real inventory, read past our own proxy, so this never reads back the
-- fabricated one and confuses itself.
local function originalField(fieldName)
    local restore = State.DataRestore
    local inner = type(restore) == "table" and restore.Inner or nil
    return type(inner) == "table" and rawget(inner, fieldName) or nil
end

local function findOriginalWeaponData(weaponName)
    local inventory = originalField("WeaponInventory")
    if type(inventory) ~= "table" then return nil end
    for _, weaponData in pairs(inventory) do
        if type(weaponData) == "table" and rawget(weaponData, "Name") == weaponName then
            return weaponData
        end
    end
    return nil
end

local function overrideWeaponData(weaponName, weaponData)
    if type(weaponData) ~= "table" then return weaponData end

    local wanted = CONFIG.Loadout[weaponName]
    if type(wanted) ~= "table" then return weaponData end

    -- Clone rather than edit. The table we were handed is the game's own
    -- inventory entry, and writing to it would make the change permanent for
    -- this session even after we unload.
    local overridden = table.clone(weaponData)
    if wanted.Skin then overridden.Skin = { Name = wanted.Skin } end
    if wanted.Wrap then
        overridden.Wrap = { Name = wanted.Wrap, Inverted = wanted.WrapInverted == true }
    end
    if wanted.Charm then overridden.Charm = { Name = wanted.Charm } end
    if wanted.Finisher then overridden.Finisher = { Name = wanted.Finisher } end
    return overridden
end

local function installItemHook()
    if State.ConstantIndex ~= nil then return true end

    local getWeaponData = resolveGetWeaponData()
    local utility = requireModule("PlayerDataUtility")
    if type(getWeaponData) ~= "function" or type(utility) ~= "table"
        or type(debug.getconstants) ~= "function" or type(debug.setconstant) ~= "function" then
        return false
    end

    -- Find the string constant the call site uses to name the method.
    local constantIndex = nil
    for index, value in pairs(debug.getconstants(getWeaponData)) do
        if value == "GetWeaponData" then
            constantIndex = index
            break
        end
    end
    if constantIndex == nil then return false end

    -- Repoint that one call site at a name only we define. See the header.
    local previousSentinel = rawget(utility, SENTINEL)
    debug.setconstant(getWeaponData, constantIndex, SENTINEL)

    rawset(utility, SENTINEL, function(_, playerData, weaponName)
        local original = findOriginalWeaponData(weaponName)
        if original == nil then return nil end

        -- This path runs for OTHER players' weapon data too. Overriding
        -- theirs would put your skins on their guns on your screen, which is
        -- not what anybody wants.
        local player = type(playerData) == "table"
            and (rawget(playerData, "Player") or rawget(playerData, "_player_object")) or nil
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
            player = LocalPlayer
        end
        if player ~= LocalPlayer or not CONFIG.Enabled then
            return original
        end

        return overrideWeaponData(weaponName, original)
    end)

    State.Utility = utility
    State.PreviousSentinel = previousSentinel
    State.HookedFunction = getWeaponData
    State.ConstantIndex = constantIndex
    State.OriginalConstant = "GetWeaponData"
    return true
end

local function restoreItemHook()
    -- Symmetric, and not optional. A rewritten constant left behind means the
    -- game calls a method that stops existing the moment we unload.
    if type(State.HookedFunction) == "function" and type(State.ConstantIndex) == "number"
        and type(debug.setconstant) == "function" then
        pcall(debug.setconstant, State.HookedFunction, State.ConstantIndex, State.OriginalConstant)
    end
    if type(State.Utility) == "table" then
        rawset(State.Utility, SENTINEL, State.PreviousSentinel)
    end
    State.HookedFunction = nil
    State.ConstantIndex = nil
    State.Utility = nil
    State.PreviousSentinel = nil
end

--=============================================================================
-- Telling the menu to look again
--=============================================================================

local function refreshMenu()
    local controller = playerDataController()
    local currentData = controller and rawget(controller, "CurrentData") or nil
    if type(currentData) ~= "table" then return end

    -- Fire the game's own change signal rather than rebuilding its UI. See
    -- the header.
    local events = rawget(currentData, "_value_changed_events")
    local signal = type(events) == "table" and events["CosmeticInventory"] or nil
    if type(signal) == "table" and type(signal.Fire) == "function" then
        pcall(signal.Fire, signal)
    end
end

--=============================================================================
-- Install
--=============================================================================

local function install()
    local controller = playerDataController()
    local currentData = type(controller) == "table" and rawget(controller, "CurrentData") or nil
    if type(controller) ~= "table" or type(currentData) ~= "table" then
        return false
    end

    local proxyOk = installProxy(currentData)
    local hookOk = installItemHook()

    -- The server can replace CurrentData wholesale - on a save reload, or
    -- between rounds. When it does, our proxy is attached to an object nobody
    -- reads any more, so reinstall on the new one.
    if State.DataAddedConnection == nil then
        local signal = rawget(controller, "PlayerDataAdded")
        if type(signal) == "table" and type(signal.Connect) == "function" then
            State.DataAddedConnection = signal:Connect(function()
                -- Deferred: the controller is mid-update when this fires and
                -- CurrentData may not be swapped in yet.
                task.defer(function()
                    if env.__UnlockCosmeticsToken ~= Token then return end
                    installProxy(rawget(controller, "CurrentData"))
                    refreshMenu()
                end)
            end)
        end
    end

    refreshMenu()

    if proxyOk and not hookOk then
        notify("menu unlocked, but equipping needs debug.setconstant")
    elseif proxyOk then
        notify("unlocked")
    end
    return proxyOk
end

if CONFIG.Enabled then
    task.spawn(function()
        -- Your save has to arrive before there is anything to proxy.
        for _ = 1, 100 do
            if env.__UnlockCosmeticsToken ~= Token then return end
            if install() then return end
            task.wait(0.5)
        end
        notify("player data never arrived")
    end)
end

--=============================================================================
-- Cleanup
--=============================================================================

env.__UnlockCosmeticsCleanup = function()
    env.__UnlockCosmeticsToken = nil
    if State.DataAddedConnection then
        State.DataAddedConnection:Disconnect()
        State.DataAddedConnection = nil
    end
    restoreItemHook()
    restoreProxy()
    refreshMenu()          -- so the menu drops back to what you really own
    State.UnlockedInventory = nil
    env.__UnlockCosmeticsCleanup = nil
end

--[[============================================================================
    WHAT THE FULL VERSION ADDS
===============================================================================

    This file is the unlock. The shipped `RivalsCosmetics` namespace is around
    5,000 lines, and the rest of it is:

    * A PER-WEAPON SELECTION UI with dropdowns for skin, wrap, charm, finisher
      and wrap inversion, populated from the cosmetic library and filtered per
      weapon, plus favourites and an "only use favourites" mode that constrains
      the game's own random-cosmetic picker.
    * PRESETS - named sets of selections, saved to a file, with auto-load.
    * A LIVE 3D PREVIEWER: a ViewportFrame that builds the selected weapon with
      the selected cosmetics applied, so you can see it before committing.
    * VIEWMODEL INJECTION. The proxy covers menus and inventory; making the gun
      in your hands actually look different means hooking `ClientItem.new` to
      patch the view model data as it is constructed, plus a matching path for
      other players' items and for world objects like placed tripmines.
    * FINISHERS AND EMOTES, which live on different controllers again and are
      hooked separately (`ClientEntity.PlayFinisher`, the emote controller's
      equip and use-by-name).
    * RANK CHARMS, which encode a season and have to be patched into the charm
      payload rather than named directly.
    * NATIVE MENU BINDING so the game's own cosmetics screen drives all of the
      above, instead of a separate menu.

    All of it sits on the two techniques at the top of this file. If you
    understand the proxy and the constant rewrite, you can read the rest.

============================================================================--]]
