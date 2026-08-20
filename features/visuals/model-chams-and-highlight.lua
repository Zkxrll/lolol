--[[============================================================================
    MODEL CHAMS AND VIEWMODEL HIGHLIGHT  -  recolour your own character, arms
    and weapon, and outline the ones in front of you
    Standalone. Run this file on its own; it needs nothing else.
===============================================================================

    WHAT IT DOES
    Five menu sections in one file, because they are one mechanism:

        Character Chams  recolours your whole body
        Arms Chams       recolours the first-person arms
        Item Chams       recolours the gun in your hands
        Arms Highlight   an outline + fill over the arms
        Item Highlight   an outline + fill over the gun

    All of it is local and all of it is cosmetic - it changes how *your* screen
    looks. Nobody else sees any of it. This is the "make my gun neon pink"
    feature, and it is genuinely the safest thing in the entire project.

===============================================================================
    TWO WAYS TO RECOLOUR A MODEL, AND WHY BOTH ARE HERE
===============================================================================

    CHAMS write on the parts themselves. Walk every `BasePart` in the model and
    set `Material`, `Color` and `Transparency`. You get every material Roblox
    has - ForceField for that classic ghost look, Neon for flat colour, Glass,
    Foil - and it is exact, because you are setting the real properties on the
    real parts.

    The price is that you are now holding somebody else's object in a changed
    state, and you have to be able to put it back. Most of this file is that
    problem, not the recolouring.

    HIGHLIGHTS are an engine feature. One `Highlight` instance parented to a
    model draws a fill and an outline over the whole thing, and with
    `DepthMode = AlwaysOnTop` it draws through walls. Nothing about the model is
    modified, so cleanup is `:Destroy()` and you are done.

    The price is that it does exactly one effect. Fill colour, fill
    transparency, outline colour, outline transparency - that is the whole API.
    No materials, no per-part control. Roblox also only renders a limited number
    of Highlights at once, so it is fine for the two things in front of your
    face and a bad idea for forty players.

    The rule that falls out of that: use `Highlight` when the built-in effect is
    what you wanted, and write on parts when it is not. Reaching for the manual
    version first is a very common way to give yourself a restore problem you
    did not need to have.

===============================================================================
    THE HARD PART: PUTTING IT BACK
===============================================================================

    Your arms and your gun are destroyed and rebuilt constantly - every weapon
    swap, every respawn, every time you pick something up. So this cannot be
    "apply on enable, undo on disable". By the time you disable it, half the
    parts you changed no longer exist and the other half are new ones you never
    touched.

    The shape that survives that is a RECONCILE PASS. Every tick:

        1. work out which models should be affected right now
        2. apply the settings, and mark every part you touched as "active"
        3. walk everything you have EVER touched; anything not marked active
           this pass gets restored and forgotten

    Step 3 is the whole trick. It handles every case with no special code:
    toggle turned off, colour changed, weapon swapped, character died, part
    deleted, script disabled. They all look identical from inside the loop -
    something that was active is no longer active, so it gets restored.

    You will see the same `active` set pattern twice here (parts and textures)
    and a third time in `ReconcileHighlights`. It is worth learning as a shape.
    `../world/ambience.lua` is the one-object version of the same idea, and
    much easier to read first.

===============================================================================
    WEAK TABLES, AND THE LEAK YOU GET WITHOUT THEM
===============================================================================

        AppearanceSnapshots = setmetatable({}, { __mode = "k" })

    That `__mode = "k"` marks the table's KEYS as weak. Normally, putting an
    object in a table keeps it alive - the garbage collector will not free
    anything a table still refers to. With weak keys, the table's reference does
    not count: once nothing else refers to that part, the collector takes it and
    the entry vanishes from this table on its own.

    Here is why that matters. Every weapon swap destroys a set of parts and
    makes new ones. This table snapshots each part it touches. Without weak
    keys, an hour of play leaves thousands of entries pointing at parts that
    were destroyed long ago - and every one of those entries is still walked,
    every single pass, forever. That is a memory leak *and* a slow leak of frame
    time, and it is completely invisible until someone plays for two hours and
    wonders why it got choppy.

    Any time you keep a table keyed by game objects that you did not create and
    do not control the lifetime of, use weak keys. It costs one line.

    (`TextureSnapshots` is deliberately a normal strong table - see below.)

===============================================================================
    THE INVISIBLE PART RULE
===============================================================================

    Look at this line, it is the least obvious one in the file:

        descendant.Transparency = snapshot.Transparency < 1
            and transparency or snapshot.Transparency

    Read it as: "if this part was visible, apply my transparency; if it was
    completely invisible, leave it completely invisible."

    Models are full of parts you are not supposed to see - hitboxes, collision
    proxies, attachment anchors, the invisible root part every rig has. The game
    hides them by setting `Transparency = 1`. If you blanket-write your
    transparency onto every part, all of those light up, and your character
    turns into a mess of floating boxes with a giant block where the HumanoidRootPart
    is. It is instantly recognisable as the mark of someone's first cham script.

    One comparison fixes it, and the same idea applies whenever you are styling
    something you did not build: a value the author deliberately set to an
    extreme is usually load-bearing. Check for it before you overwrite it.

===============================================================================
    STRIPPING TEXTURES, AND THE PROPERTY THAT DOES NOT EXIST
===============================================================================

    A clean cham usually means removing the model's textures too, otherwise the
    weapon's camo pattern sits on top of your colour and muddies it.

    Four of the five texture types have an off switch:

        MeshPart        TextureID    -> ""
        SpecialMesh     TextureId    -> ""
        Decal / Texture Transparency -> 1

    `SurfaceAppearance`, `Clothing` and `ShirtGraphic` have nothing like that.
    A SurfaceAppearance IS the texture; there is no "disabled" property on it.

    So for those we take the object out of the tree entirely:

        snapshot.Value = instance.Parent   -- remember where it lived
        instance.Parent = nil              -- and lift it out

    Setting `Parent = nil` does not destroy an instance. It stays in memory,
    fully intact, just not part of the world any more - and putting it back is
    one assignment. It is the general answer for "this thing has no off switch":
    unparent it, keep the reference, restore it later.

    This is also exactly why `TextureSnapshots` is NOT a weak table. Our
    reference is the only one keeping those unparented objects alive. Make it
    weak and the collector eats the very thing you promised to give back.

    THE BUG THAT CAUSES, AND THE FIX
    The reconcile pass builds its active set from `root:GetDescendants()`. An
    instance we unparented is no longer a descendant of anything, so it will
    never appear in that list, so it gets treated as inactive and restored
    immediately - one pass later it is back, and it flickers forever.

    That is what the first loop in `stripTextures` is for. Before scanning, it
    re-marks anything we previously unparented from this same root as still
    active. Small, and completely mysterious until you know it was written to
    answer a specific bug.

===============================================================================
    FINDING THE THINGS TO COLOUR
===============================================================================

    Your character is easy: `LocalPlayer.Character`.

    The first-person arms and weapon are looked for in two places, and both are
    checked every pass:

        the fighter's ClientViewModel table -> ItemModel, _left_arm, _right_arm
        Workspace.ViewModels.FirstPerson    -> ItemVisual, LeftArm, RightArm

    They usually agree. They disagree for a frame or two around a weapon swap,
    because the game builds the new viewmodel object before it parents the new
    models into the workspace, and destroys the old models before it drops the
    old object. Checking both means the colour never blinks off mid-swap.

    When two sources describe the same thing and neither is reliably ahead,
    read both and de-duplicate. That is what `appendUniqueRoot` and the `seen`
    tables are doing - three lines to make the whole problem go away.

    REQUIREMENTS
    None. This is the only visual feature in the project that needs no executor
    functions at all - it is ordinary Roblox instance work.

============================================================================--]]

local CONFIG = {
    -- Chams. Material is one of: Original, Ghost, Flat, Foil, Custom, Reflective
    -- (Ghost is the classic see-through look; Flat is solid colour.)
    Character = {
        Enabled       = false,
        Material      = "Ghost",
        Color         = Color3.fromRGB(255, 255, 255),
        Transparency  = 0,
        StripTextures = false,
    },
    Arms = {
        Enabled       = true,
        Material      = "Ghost",
        Color         = Color3.fromRGB(120, 170, 255),
        Transparency  = 0,
        StripTextures = true,   -- arms default to stripped; skin textures muddy the colour
    },
    Item = {
        Enabled       = true,
        Material      = "Flat",
        Color         = Color3.fromRGB(255, 90, 200),
        Transparency  = 0,
        StripTextures = false,
    },

    -- Highlights. Separate from chams and stackable with them.
    ArmsHighlight = {
        Enabled              = false,
        FillColor            = Color3.fromRGB(255, 255, 255),
        FillTransparency     = 0.5,
        OutlineColor         = Color3.fromRGB(255, 255, 255),
        OutlineTransparency  = 0,
    },
    ItemHighlight = {
        Enabled              = true,
        FillColor            = Color3.fromRGB(0, 0, 0),
        FillTransparency     = 1,     -- 1 = no fill, outline only
        OutlineColor         = Color3.fromRGB(255, 90, 200),
        OutlineTransparency  = 0,
    },

    -- How often the reconcile pass runs. Ten times a second is plenty; the
    -- work is proportional to how many parts your gun has.
    Interval = 0.1,

    Notify = true,
}

-- "Original" is absent on purpose: a nil material means "leave the part's own
-- material alone and only change its colour".
local MATERIALS = {
    Ghost      = Enum.Material.ForceField,
    Flat       = Enum.Material.Neon,
    Foil       = Enum.Material.Foil,
    Custom     = Enum.Material.SmoothPlastic,
    Reflective = Enum.Material.Glass,
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
            Title = "Model Chams", Text = text, Duration = 4,
        })
    end)
end

local env = (getgenv and getgenv()) or _G
if env.__ModelChamsCleanup then
    pcall(env.__ModelChamsCleanup)
end

local Token = {}
env.__ModelChamsToken = Token

local State = {
    -- part -> { Material, Color, Transparency, Reflectance }
    -- Weak keys: destroyed parts drop out on their own. See the header.
    AppearanceSnapshots = setmetatable({}, { __mode = "k" }),

    -- instance -> { Property, Value, Root }
    -- Deliberately STRONG. We may be the only thing keeping an unparented
    -- SurfaceAppearance alive, and we owe it a home. See the header.
    TextureSnapshots = {},

    -- scope name -> (model -> Highlight)
    Highlights = { Arms = {}, Item = {} },

    FighterController = nil,
}

--=============================================================================
-- Finding the local fighter
--=============================================================================
-- The game keeps its own object for you, separate from your Roblox Player. It
-- holds the equipped item, which holds the viewmodel. The controller module is
-- already loaded by the game, so `require` here just hands back the existing
-- copy rather than running it again.

local function fighterController()
    if State.FighterController then return State.FighterController end
    local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("FighterController")
    if not module then return nil end
    local success, controller = pcall(require, module)
    State.FighterController = (success and type(controller) == "table") and controller or nil
    return State.FighterController
end

local function localFighter()
    local controller = fighterController()
    if not controller then return nil end
    local fighter = rawget(controller, "LocalFighter")
    if fighter == nil and type(controller.GetFighter) == "function" then
        local success, result = pcall(controller.GetFighter, controller, LocalPlayer)
        fighter = success and result or nil
    end
    return type(fighter) == "table" and fighter or nil
end

--=============================================================================
-- Working out what to colour
--=============================================================================

local function appendUniqueRoot(roots, seen, root)
    -- typeof, not type: `type` says "userdata" for every Roblox object.
    if typeof(root) ~= "Instance" or root.Parent == nil or seen[root] then
        return
    end
    seen[root] = true
    roots[#roots + 1] = root
end

local function resolveScopes()
    local scopes = { Character = {}, Arms = {}, Item = {} }
    local seen = { Character = {}, Arms = {}, Item = {} }

    appendUniqueRoot(scopes.Character, seen.Character, LocalPlayer.Character)

    -- Source one: the fighter's own viewmodel table.
    local fighter = localFighter()
    local equipped = fighter and rawget(fighter, "EquippedItem") or nil
    local viewModel = type(equipped) == "table"
        and (rawget(equipped, "_ViewModel") or rawget(equipped, "ViewModel")) or nil
    if type(viewModel) == "table" then
        appendUniqueRoot(scopes.Item, seen.Item, rawget(viewModel, "ItemModel"))
        appendUniqueRoot(scopes.Arms, seen.Arms, rawget(viewModel, "_left_arm"))
        appendUniqueRoot(scopes.Arms, seen.Arms, rawget(viewModel, "_right_arm"))
    end

    -- Source two: the models actually sitting in the workspace. See the header
    -- for why both are read.
    local viewModels = Workspace:FindFirstChild("ViewModels")
    local firstPerson = viewModels and viewModels:FindFirstChild("FirstPerson") or nil
    for _, model in ipairs(firstPerson and firstPerson:GetChildren() or {}) do
        if model:IsA("Model") then
            appendUniqueRoot(scopes.Item, seen.Item, model:FindFirstChild("ItemVisual"))
            appendUniqueRoot(scopes.Arms, seen.Arms, model:FindFirstChild("LeftArm"))
            appendUniqueRoot(scopes.Arms, seen.Arms, model:FindFirstChild("RightArm"))
        end
    end

    return scopes
end

-- A model's parts are its descendants, but a scope root can itself be a single
-- part rather than a Model, so it has to be included by hand.
local function partsUnder(root)
    local descendants = root:GetDescendants()
    if root:IsA("BasePart") then
        table.insert(descendants, root)
    end
    return descendants
end

--=============================================================================
-- Snapshot and restore
--=============================================================================
-- Both of these take the snapshot on the FIRST write only. Snapshotting again
-- later would capture the value we ourselves wrote, and the original would be
-- gone for good.

local function captureAppearance(part)
    local snapshot = State.AppearanceSnapshots[part]
    if snapshot then return snapshot end

    snapshot = {
        Material     = part.Material,
        Color        = part.Color,
        Transparency = part.Transparency,
        Reflectance  = part.Reflectance,
    }
    State.AppearanceSnapshots[part] = snapshot
    return snapshot
end

local function restoreAppearance(part, snapshot)
    -- A weak table can hand back an entry for a part that has since been
    -- removed from the world but not yet collected.
    if not part or part.Parent == nil or type(snapshot) ~= "table" then
        return
    end
    pcall(function()
        part.Material     = snapshot.Material
        part.Color        = snapshot.Color
        part.Transparency = snapshot.Transparency
        part.Reflectance  = snapshot.Reflectance
    end)
end

local function captureTexture(instance, property, root)
    local snapshot = State.TextureSnapshots[instance]
    if snapshot then return snapshot end

    snapshot = { Property = property, Root = root }
    if property == "Parent" then
        snapshot.Value = instance.Parent
    else
        snapshot.Value = instance[property]
    end
    State.TextureSnapshots[instance] = snapshot
    return snapshot
end

local function restoreTexture(instance, snapshot)
    if not instance or type(snapshot) ~= "table" then return end
    -- For an unparented instance this assignment is what puts it back in the
    -- world, which is the entire reason the reference was kept.
    pcall(function()
        instance[snapshot.Property] = snapshot.Value
    end)
end

--=============================================================================
-- Textures
--=============================================================================

local function stripTextures(root, activeTextures)
    -- Anything we already lifted out of this root cannot show up in
    -- GetDescendants, so mark it active here or it flickers back in. See the
    -- header - this loop exists to answer one specific bug.
    for instance, snapshot in pairs(State.TextureSnapshots) do
        if snapshot.Root == root and snapshot.Property == "Parent" and instance.Parent == nil then
            activeTextures[instance] = true
        end
    end

    for _, descendant in ipairs(partsUnder(root)) do
        local property, replacement = nil, nil

        if descendant:IsA("MeshPart") then
            property, replacement = "TextureID", ""
        elseif descendant:IsA("SpecialMesh") then
            property, replacement = "TextureId", ""
        elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
            property, replacement = "Transparency", 1
        elseif descendant:IsA("SurfaceAppearance")
            or descendant:IsA("Clothing") or descendant:IsA("ShirtGraphic") then
            -- No off switch on these three; they get unparented instead.
            property = "Parent"
        end

        if property then
            captureTexture(descendant, property, root)
            activeTextures[descendant] = true
            pcall(function()
                if property == "Parent" then
                    descendant.Parent = nil
                else
                    descendant[property] = replacement
                end
            end)
        end
    end
end

--=============================================================================
-- Chams
--=============================================================================

local function applyChamScope(roots, settings, activeParts, activeTextures)
    if not settings.Enabled then
        -- Nothing is marked active, so the sweep at the end of the pass
        -- restores this scope on its own. There is no "turn off" code.
        return
    end

    local material = MATERIALS[settings.Material]   -- nil for "Original"
    local color = settings.Color
    local transparency = math.clamp(settings.Transparency or 0, 0, 1)

    for _, root in ipairs(roots) do
        for _, descendant in ipairs(partsUnder(root)) do
            if descendant:IsA("BasePart") then
                local snapshot = captureAppearance(descendant)
                activeParts[descendant] = true
                pcall(function()
                    descendant.Material = material or snapshot.Material
                    descendant.Color = color
                    -- Parts the game hid stay hidden. See the header.
                    descendant.Transparency = snapshot.Transparency < 1
                        and transparency or snapshot.Transparency
                end)
            end
        end

        if settings.StripTextures then
            stripTextures(root, activeTextures)
        end
    end
end

--=============================================================================
-- Highlights
--=============================================================================

local function reconcileHighlights(scopeName, roots, settings)
    local entries = State.Highlights[scopeName]
    local active = {}

    if settings.Enabled then
        for _, root in ipairs(roots) do
            active[root] = true

            local highlight = entries[root]
            if not highlight or highlight.Parent == nil then
                highlight = Instance.new("Highlight")
                highlight.Name = "KiciaHookViewmodelHighlight_" .. scopeName
                -- AlwaysOnTop is what makes it draw through geometry. The
                -- default (Occluded) hides it behind whatever is in front.
                highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                highlight.Adornee = root
                highlight.Parent = root
                entries[root] = highlight
            end

            -- Cheap to write every pass; no reuse bug to worry about because
            -- the instance is ours and nothing else touches it.
            highlight.FillColor = settings.FillColor
            highlight.FillTransparency = math.clamp(settings.FillTransparency or 0.5, 0, 1)
            highlight.OutlineColor = settings.OutlineColor
            highlight.OutlineTransparency = math.clamp(settings.OutlineTransparency or 0, 0, 1)
        end
    end

    -- Same sweep as the chams, and it covers the same set of cases: toggled
    -- off, weapon swapped, model destroyed.
    for root, highlight in pairs(entries) do
        if not active[root] then
            pcall(function() highlight:Destroy() end)
            entries[root] = nil
        end
    end
end

--=============================================================================
-- One reconcile pass
--=============================================================================

local function reconcile()
    local scopes = resolveScopes()
    local activeParts = {}
    local activeTextures = {}

    applyChamScope(scopes.Character, CONFIG.Character, activeParts, activeTextures)
    applyChamScope(scopes.Arms, CONFIG.Arms, activeParts, activeTextures)
    applyChamScope(scopes.Item, CONFIG.Item, activeParts, activeTextures)

    -- The sweep. Everything we have ever changed and did not just re-apply
    -- goes back to how we found it, and we forget about it.
    for part, snapshot in pairs(State.AppearanceSnapshots) do
        if not activeParts[part] then
            restoreAppearance(part, snapshot)
            State.AppearanceSnapshots[part] = nil
        end
    end
    for instance, snapshot in pairs(State.TextureSnapshots) do
        if not activeTextures[instance] then
            restoreTexture(instance, snapshot)
            State.TextureSnapshots[instance] = nil
        end
    end

    reconcileHighlights("Arms", scopes.Arms, CONFIG.ArmsHighlight)
    reconcileHighlights("Item", scopes.Item, CONFIG.ItemHighlight)
end

--=============================================================================
-- The loop
--=============================================================================

task.spawn(function()
    while env.__ModelChamsToken == Token do
        local ok, err = pcall(reconcile)
        if not ok then
            warn("[Model Chams] " .. tostring(err))
        end
        task.wait(CONFIG.Interval)
    end
end)

notify("active")

--=============================================================================
-- Cleanup
--=============================================================================
-- Note how little there is here. The reconcile pass already knows how to
-- restore anything that stops being active, so switching off is just "make
-- nothing active, run one more pass". That is the payoff for writing it as a
-- reconcile in the first place.

env.__ModelChamsCleanup = function()
    env.__ModelChamsToken = nil

    CONFIG.Character.Enabled = false
    CONFIG.Arms.Enabled = false
    CONFIG.Item.Enabled = false
    CONFIG.ArmsHighlight.Enabled = false
    CONFIG.ItemHighlight.Enabled = false

    pcall(reconcile)

    -- Belt and braces: RunService gives the engine a moment to settle, and any
    -- root that vanished between passes is handled directly.
    RunService.Heartbeat:Wait()
    for part, snapshot in pairs(State.AppearanceSnapshots) do
        restoreAppearance(part, snapshot)
    end
    for instance, snapshot in pairs(State.TextureSnapshots) do
        restoreTexture(instance, snapshot)
    end
    State.AppearanceSnapshots = setmetatable({}, { __mode = "k" })
    State.TextureSnapshots = {}

    for _, entries in pairs(State.Highlights) do
        for root, highlight in pairs(entries) do
            pcall(function() highlight:Destroy() end)
            entries[root] = nil
        end
    end

    env.__ModelChamsCleanup = nil
end
