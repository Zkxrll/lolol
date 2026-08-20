--[[============================================================================
    AUTO LOADOUT  -  pick your weapons the moment the picker opens
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    When the weapon-select screen appears, this fills in your four slots and
    confirms, so the screen is gone before you have read it. You can give a
    different loadout per map, and a fallback order per slot for when your first
    choice is locked or banned.

===============================================================================
    IT DOES NOT CLICK ANYTHING
===============================================================================

    The obvious way to automate a menu is to find the buttons and click them.
    Don't, if you can avoid it. Clicking means knowing where things are on
    screen, waiting for animations, coping with scrolling, and redoing all of it
    when the layout changes.

    The screen is driven by a module the game requires - `Modules.Pages.
    PickWeapons` - and that module keeps its state in plain fields:

        pageController._is_open              is the screen up
        pageController._current_slot         which slot you are browsing
        pageController._chosen_weapon_slots  the slots this screen is asking for
        pageController._chosen_weapons       what has been chosen so far
        pageController:Finish()              confirm and submit

    So the whole feature is: write `_chosen_weapons`, call `Finish`. The game
    submits it exactly as if you had clicked, because as far as it knows, you
    did - this is its own confirm path, with its own validation, running on its
    own data.

    Reaching into a module's underscore-prefixed fields is reaching into
    somebody's private state, and it will break when the game updates. That is
    the trade: far less code, far less fragile to the things that change often
    (layout, art, animation), and completely at the mercy of the things that
    change rarely (field names).

===============================================================================
    KNOWING WHEN THE SCREEN OPENED
===============================================================================

    Two page names exist, `PickWeapons` and `PickWeaponsList`, depending on
    build. Both are watched. The trigger is the frame's `Visible` property, plus
    a `ChildAdded` on the Pages folder for the case where the frame does not
    exist yet when this file runs.

    "Visible" alone is not enough to act on, though:

        pageFrame.Visible == true
        pageFrame.AbsoluteSize.X > 0 and AbsoluteSize.Y > 0

    A frame that is visible but has zero size is mid-open - the layout has not
    resolved yet, and writing to the controller now gets overwritten by its own
    setup. The size check is what turns "the property changed" into "the screen
    is actually up". Any time you react to a GUI becoming visible, check that it
    has a size too.

    And because even that can be a frame early, a submit that does not take is
    retried five times, 0.05s apart, then given up on.

    THE NONCE
    Every open gets a number. Retries carry the number they started with and do
    nothing if it no longer matches:

        if openNonce ~= State.OpenNonce then return end

    Without it, closing and reopening the screen quickly leaves the old open's
    retries still running against the new one. This is worth remembering in
    general: any time you schedule work into the future for a thing that can be
    replaced, stamp it, and check the stamp when it lands.

===============================================================================
    FALLBACKS, AND WHY THEY ONLY HALF-WORK
===============================================================================

    Each slot takes a list, and the first entry that is actually available wins.
    "Available" is read off the screen itself - a weapon counts if its button is
    in the list and neither its `Locked` nor its `Banned` badge is showing.

    The catch: the list on screen only ever holds the slot you are currently
    browsing. So availability is learned one slot at a time, as you browse, and
    cached. For a slot nothing is known about yet, the first entry in your list
    is used and the game rejects it if it is wrong.

    This is exactly what the menu version does, and it is worth being honest
    about rather than papering over: put your most reliable pick first, and the
    fallbacks will start mattering after you have opened those slots once.

    REQUIREMENTS
    None.

============================================================================--]]

local CONFIG = {
    Enabled = true,

    -- Per slot, in order of preference. First one available is taken.
    -- `Default` is used for every map. Add a map name as another key to
    -- override it there; the name must match the game's map name.
    Loadouts = {
        Default = {
            Primary   = { "AK-47", "M4A1" },
            Secondary = { "Deagle", "Glock" },
            Melee     = { "Katana" },
            Utility   = { "Frag Grenade", "Flashbang" },
        },

        -- ["Skyline"] = {
        --     Primary   = { "Sniper" },
        --     Secondary = { "Deagle" },
        --     Melee     = { "Katana" },
        --     Utility   = { "Smoke" },
        -- },
    },

    Notify = true,
}

--=============================================================================
-- Setup
--=============================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- Order matters: index 1 is the Primary slot, and the game asks for its slots
-- in the same order.
local SLOTS = { "Primary", "Secondary", "Melee", "Utility" }
local PAGE_NAMES = { "PickWeapons", "PickWeaponsList" }

local RETRY_DELAY = 0.05
local RETRY_LIMIT = 5

local function notify(text)
    if not CONFIG.Notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Auto Loadout", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__AutoLoadoutCleanup then
    pcall(env.__AutoLoadoutCleanup)
end

local Token = {}
env.__AutoLoadoutToken = Token

--=============================================================================
-- State
--=============================================================================

local State = {
    OpenNonce = 0,
    HasRunThisOpen = false,
    PageControllers = {},   -- pageName -> required module
    BoundFrames = {},       -- pageName -> true
    -- What each slot's list showed the last time we saw it. See header.
    AvailableBySlot = {},
}

local Connections = {}

--=============================================================================
-- Finding the screen
--=============================================================================

local function pagesFrame()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local mainGui = playerGui and playerGui:FindFirstChild("MainGui")
    local mainFrame = mainGui and mainGui:FindFirstChild("MainFrame")
    return mainFrame and mainFrame:FindFirstChild("Pages") or nil
end

local function pageFrameFor(pageName)
    local pages = pagesFrame()
    local frame = pages and pages:FindFirstChild(pageName)
    return (frame and frame:IsA("GuiObject")) and frame or nil
end

-- Visible AND laid out. See header.
local function isPageUp(frame)
    return frame ~= nil
        and frame.Visible == true
        and frame.AbsoluteSize.X > 0
        and frame.AbsoluteSize.Y > 0
end

local function pageControllerFor(pageName)
    if State.PageControllers[pageName] then
        return State.PageControllers[pageName]
    end

    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local modules = playerScripts and playerScripts:FindFirstChild("Modules")
    local pages = modules and modules:FindFirstChild("Pages")
    local module = pages and pages:FindFirstChild(pageName)
    if not module then return nil end

    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return nil end

    State.PageControllers[pageName] = controller
    return controller
end

--=============================================================================
-- Which map are we on
--=============================================================================
-- Four sources, cheapest last. The duel object knows, but only once the match
-- exists; the workspace attributes are the fallback for everything else.

local function currentMapName()
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("DuelController")

    if module then
        local ok, controller = pcall(require, module)
        local duel = (ok and type(controller) == "table") and controller.CurrentObject or nil
        if duel then
            if type(duel.GetMapName) == "function" then
                local mapOk, name = pcall(duel.GetMapName, duel)
                if mapOk and type(name) == "string" and name ~= "" then return name end
            end
            if type(duel.Get) == "function" then
                for _, key in ipairs({ "MapName", "Map" }) do
                    local mapOk, name = pcall(duel.Get, duel, key)
                    if mapOk and type(name) == "string" and name ~= "" then return name end
                end
            end
            local name = duel.MapName or duel.Map
            if type(name) == "string" and name ~= "" then return name end
        end
    end

    for _, attribute in ipairs({ "MapName", "MatchMap" }) do
        local name = Workspace:GetAttribute(attribute)
        if type(name) == "string" and name ~= "" then return name end
    end
    return nil
end

local function loadoutForCurrentMap()
    local mapName = currentMapName()
    local perMap = mapName and CONFIG.Loadouts[mapName] or nil
    return perMap or CONFIG.Loadouts.Default
end

--=============================================================================
-- What the screen is currently offering
--=============================================================================
-- Only the slot being browsed is on screen, so this learns one slot at a time
-- and remembers. See header.

local function captureVisibleValues(pageController)
    local slotName = SLOTS[pageController._current_slot]
    if not slotName then return end

    local list = pageController.List
    local container = list and list:FindFirstChild("Container")
    if not container then return end

    local entries = {}
    for _, child in ipairs(container:GetChildren()) do
        if child.Name == "WeaponSlot" and child.Visible ~= false then
            local button = child:FindFirstChild("Button")
            local title = button and button:FindFirstChild("Title")
            local locked = button and button:FindFirstChild("Locked")
            local banned = button and button:FindFirstChild("Banned")

            local name = title and title.Text or nil
            if type(name) == "string" then
                name = name:match("^%s*(.-)%s*$")   -- the label carries padding
            end

            -- The badges exist whether or not they apply, so the test is
            -- whether they are showing, not whether they are there.
            if type(name) == "string" and name ~= ""
                and (not locked or locked.Visible ~= true)
                and (not banned or banned.Visible ~= true) then
                table.insert(entries, { Name = name, Order = child.LayoutOrder })
            end
        end
    end

    if #entries == 0 then return end

    table.sort(entries, function(left, right)
        if left.Order == right.Order then return left.Name < right.Name end
        return left.Order < right.Order
    end)

    local values, seen = {}, {}
    for _, entry in ipairs(entries) do
        if not seen[entry.Name] then
            seen[entry.Name] = true
            table.insert(values, entry.Name)
        end
    end
    State.AvailableBySlot[slotName] = values
end

-- Unknown slot -> assume available. That is the honest answer: we have not
-- looked, not that it is missing.
local function isAvailable(slotName, weaponName)
    local values = State.AvailableBySlot[slotName]
    if type(values) ~= "table" or #values == 0 then return true end
    return table.find(values, weaponName) ~= nil
end

--=============================================================================
-- Building the answer
--=============================================================================

local function buildChosenWeapons(maxSlots)
    local loadout = loadoutForCurrentMap()
    if type(loadout) ~= "table" then return nil end

    local chosen = {}
    for slotIndex = 1, maxSlots do
        local slotName = SLOTS[slotIndex]
        local preferences = slotName and loadout[slotName]
        if type(preferences) == "string" then
            preferences = { preferences }   -- a bare name is a list of one
        end
        if type(preferences) ~= "table" then return nil end

        for _, weaponName in ipairs(preferences) do
            if isAvailable(slotName, weaponName) then
                chosen[slotIndex] = weaponName
                break
            end
        end

        -- All-or-nothing: a partial loadout submitted to the game is worse than
        -- letting you pick the rest yourself.
        if not chosen[slotIndex] then return nil end
    end
    return chosen
end

--=============================================================================
-- Submitting
--=============================================================================

local function applyPage(pageController)
    if not pageController or pageController._is_open ~= true then return nil end

    local frame = pageController.PageFrame
    if not isPageUp(frame) then return nil end

    local slots = pageController._chosen_weapon_slots
    if type(slots) ~= "table" then return nil end

    local maxSlots = math.min(#slots, #SLOTS)
    if maxSlots <= 0 then return nil end

    captureVisibleValues(pageController)

    local chosen = buildChosenWeapons(maxSlots)
    if not chosen then
        return false   -- ready, but we have nothing valid to send: don't retry forever
    end

    pageController._chosen_weapons = chosen
    local ok = pcall(pageController.Finish, pageController)
    if ok then
        notify("submitted " .. table.concat(chosen, ", "))
    end
    return ok
end

local function scheduleSubmit(pageController, openNonce, attempt)
    if not pageController then return end
    if openNonce ~= State.OpenNonce then return end     -- a newer open replaced us
    if not CONFIG.Enabled or State.HasRunThisOpen then return end

    if applyPage(pageController) == true then
        State.HasRunThisOpen = true
        return
    end

    if attempt >= RETRY_LIMIT then return end

    task.delay(RETRY_DELAY, function()
        if env.__AutoLoadoutToken ~= Token then return end
        scheduleSubmit(pageController, openNonce, attempt + 1)
    end)
end

local function queueSubmit(pageController)
    if not pageController or not CONFIG.Enabled then return end

    State.OpenNonce = State.OpenNonce + 1
    State.HasRunThisOpen = false

    local openNonce = State.OpenNonce
    -- Deferred so the game's own open handler finishes first.
    task.defer(function()
        if env.__AutoLoadoutToken ~= Token then return end
        scheduleSubmit(pageController, openNonce, 1)
    end)
end

--=============================================================================
-- Wiring
--=============================================================================

local function handleVisibility(pageName)
    local frame = pageFrameFor(pageName)
    if not isPageUp(frame) then
        -- Closed: invalidate anything still scheduled.
        State.OpenNonce = State.OpenNonce + 1
        State.HasRunThisOpen = false
        return
    end

    local pageController = pageControllerFor(pageName)
    if not pageController then return end

    captureVisibleValues(pageController)
    queueSubmit(pageController)
end

local function bindPageFrame(pageName, frame)
    if State.BoundFrames[pageName] then return end

    frame = frame or pageFrameFor(pageName)
    if not frame then return end

    State.BoundFrames[pageName] = true
    Connections[pageName] = frame:GetPropertyChangedSignal("Visible"):Connect(function()
        if env.__AutoLoadoutToken ~= Token then return end
        handleVisibility(pageName)
    end)

    -- It may already be open.
    if isPageUp(frame) then
        handleVisibility(pageName)
    end
end

task.spawn(function()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 60)
    local mainGui = playerGui and playerGui:WaitForChild("MainGui", 60)
    local mainFrame = mainGui and mainGui:WaitForChild("MainFrame", 60)
    local pages = mainFrame and mainFrame:WaitForChild("Pages", 60)
    if not pages or env.__AutoLoadoutToken ~= Token then return end

    -- The frames may be built after we get here.
    Connections.PagesChildAdded = pages.ChildAdded:Connect(function(child)
        if env.__AutoLoadoutToken ~= Token then return end
        if not child or not child:IsA("GuiObject") then return end
        for _, pageName in ipairs(PAGE_NAMES) do
            if pageName == child.Name then
                bindPageFrame(pageName, child)
                break
            end
        end
    end)

    for _, pageName in ipairs(PAGE_NAMES) do
        bindPageFrame(pageName)
    end

    notify("active")
end)

--=============================================================================
-- Cleanup
--=============================================================================

env.__AutoLoadoutCleanup = function()
    env.__AutoLoadoutToken = nil
    for _, connection in pairs(Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Connections)
    table.clear(State.PageControllers)
    table.clear(State.BoundFrames)
    table.clear(State.AvailableBySlot)
    env.__AutoLoadoutCleanup = nil
end
