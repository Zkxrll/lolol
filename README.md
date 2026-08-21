# Standalone features

Each file here is **one feature, runnable on its own**. No menu, no library, no
other files. Download one, run it, and that feature works.

Every file follows the same shape:

```lua
--[[ long comment: what it does, how it works, what it needs ]]

local CONFIG = { ... }   -- edit these; everything tunable is at the top

... implementation, commented ...

env.__FeatureCleanup = function() ... end   -- how to turn it off
```

Running a file twice is safe — each one stores a token globally, and the older
copy retires itself when it sees the token change.

The comments are written for someone who does **not** already read Lua. If a
technique is non-obvious, the file explains why it is done that way and what
happens if you do it the obvious way instead.

---

## Available now

| File | Feature | Needs |
|---|---|---|
| [`movement/noclip.lua`](movement/noclip.lua) | Walk through walls | — |
| [`movement/flight.lua`](movement/flight.lua) | Fly with WASD | — |
| [`movement/walkspeed-and-slide.lua`](movement/walkspeed-and-slide.lua) | Faster running and sliding | `debug.getupvalues`, `debug.setupvalue` |
| [`movement/jump-power.lua`](movement/jump-power.lua) | Jump higher | `debug.getupvalues`, `debug.setupvalue`, `debug.getconstants`, `debug.getprotos`, `debug.getproto` |
| [`movement/auto-strafe.lua`](movement/auto-strafe.lua) | Gain air speed while holding jump | — |
| [`movement/long-jump.lua`](movement/long-jump.lua) | Launch yourself across the map | — |
| [`movement/movement-recorder.lua`](movement/movement-recorder.lua) | Record a route once, then have the game walk it for you | `writefile`/`readfile` (only to save between sessions) |
| [`movement/animation-player.lua`](movement/animation-player.lua) | Loop any Roblox animation on your character | — |
| [`automation/auto-pickup.lua`](automation/auto-pickup.lua) | Grab health when hurt, ammo when empty | `firetouchinterest` |
| [`automation/auto-respawn.lua`](automation/auto-respawn.lua) | Respawn the moment the game allows it | — |
| [`automation/tripmine-auto-trigger.lua`](automation/tripmine-auto-trigger.lua) | Set off Subspace tripmines from across the map | `firetouchinterest` |
| [`automation/auto-ban-and-map-vote.lua`](automation/auto-ban-and-map-vote.lua) | Ban weapons and vote for maps from a list you write once | — |
| [`automation/auto-loadout.lua`](automation/auto-loadout.lua) | Fill in and confirm the weapon picker for you, per map | — |
| [`automation/auto-queue.lua`](automation/auto-queue.lua) | Requeue the instant a match ends, skipping the cutscene | `VirtualInputManager` (only for Skip) |
| [`combat/weapon-mods.lua`](combat/weapon-mods.lua) | Twelve weapon and camera modifiers: attack speed, reload, recoil, dash cooldown, ADS, equip, automatic fire, infinite double jumps, camera shake, third person, FOV, viewmodel offset | — |
| [`combat/no-spread-and-grenade-fuse.lua`](combat/no-spread-and-grenade-fuse.lua) | Bullets with no scatter; choose when throwables detonate | `setrawmetatable`, `clonefunction`, `debug.getupvalues`, `debug.setupvalue` |
| [`combat/aimbot.lua`](combat/aimbot.lua) | Pulls your aim onto a target while you hold a key | `Drawing` (only for the FOV circle) |
| [`combat/flickbot.lua`](combat/flickbot.lua) | Snaps to a target along a human-shaped path, fires, and stops | `VirtualInputManager` (only to shoot) |
| [`combat/triggerbot.lua`](combat/triggerbot.lua) | Fires for you when your crosshair is already on someone | — |
| [`combat/ragebot.lua`](combat/ragebot.lua) | Stops aiming entirely — moves what the server believes about you onto the target and fires directly. **By far the most detectable thing here.** | `sethiddenproperty`, `setthreadidentity` |
| [`crosshair/custom-crosshair.lua`](crosshair/custom-crosshair.lua) | Your own crosshair: shape, colours, spin, breathing gap, text | `Drawing` |
| [`esp/player-esp.lua`](esp/player-esp.lua) | Boxes, names, health, distance, look lines and off-screen arrows through walls | `Drawing` |
| [`esp/throwable-esp.lua`](esp/throwable-esp.lua) | Labels on live grenades, molotovs, satchels and tripmines | `Drawing` |
| [`visuals/bullet-tracers.lua`](visuals/bullet-tracers.lua) | A beam along every shot fired in the match, yours and theirs | — |
| [`visuals/hit-and-kill-feedback.lua`](visuals/hit-and-kill-feedback.lua) | A sound and a body flash when you hit or kill someone | — |
| [`visuals/model-chams-and-highlight.lua`](visuals/model-chams-and-highlight.lua) | Recolour your character, arms and gun; outline the arms and gun | — |
| [`visuals/sound-visualizer.lua`](visuals/sound-visualizer.lua) | A ring in the world wherever a sound plays — ESP with no Drawing API | — |
| [`visuals/overlay-removals.lua`](visuals/overlay-removals.lua) | Delete the vignette, tracers, muzzle flash and scope overlays | `debug.setconstant`, `debug.setupvalue` (partial without) |
| [`visuals/stretched-resolution.lua`](visuals/stretched-resolution.lua) | Squash the view so targets look wider | — |
| [`visuals/viewmodel-animations.lua`](visuals/viewmodel-animations.lua) | Strip the first-person sway, shoot, sprint, equip and reload animations | — |
| [`world/lighting.lua`](world/lighting.lua) | Rewrite the map's lighting, fog, shadows and post-processing, locally | — |
| [`world/lightning.lua`](world/lightning.lua) | Procedural lightning strikes with branches, sparks and delayed thunder | — |
| [`world/weather.lua`](world/weather.lua) | Snow, rain or a blizzard that follows you around the map | — |
| [`world/skybox.lua`](world/skybox.lua) | Replace the map's sky with a preset or your own six faces | — |
| [`world/ambience.lua`](world/ambience.lua) | A looping background sound over the map | — |
| [`misc/device-spoof.lua`](misc/device-spoof.lua) | Report a different input device to the server | `debug.getupvalues`, `debug.getupvalue`, `debug.setupvalue` |
| [`misc/staff-detector.lua`](misc/staff-detector.lua) | Warn when a RIVALS moderator — or a friend of one — is in the server | `game:HttpGet` (only for the friends half) |
| [`misc/claim-all-rewards.lua`](misc/claim-all-rewards.lua) | Claim every daily, battle pass and capsule reward in one go | — |
| [`misc/unlock-cosmetics.lua`](misc/unlock-cosmetics.lua) | Every skin, wrap, charm, finisher and emote shown as owned and equippable — **on your screen only** | `debug.getconstants`, `debug.setconstant` (menu half works without) |
| [`debug/silent-debug.lua`](debug/silent-debug.lua) | A live panel naming whichever of eleven signals is currently stopping a shot | — |

## Coverage

Every feature in the menu has a standalone file here.

Two of them are deliberately partial, and each says so in its own header rather
than quietly leaving something out:

- [`visuals/overlay-removals.lua`](visuals/overlay-removals.lua) covers six of
  the eight removals. The other two (Flashbang and Burn) work by refusing a
  replicated packet rather than by removing a visual, and Hitmarker rides the
  crosshair wrapper.
- [`misc/unlock-cosmetics.lua`](misc/unlock-cosmetics.lua) is the unlock itself
  — the two techniques the whole thing rests on. The shipped version is around
  5,000 lines, and the file ends with a list of exactly what the rest of it
  does: presets, the 3D previewer, viewmodel injection, finishers and emotes,
  rank charms, and the native menu binding.

The complete script in
[`KiciaHook_Source_Runnable.lua`](../KiciaHook_Source_Runnable.lua) has all of it, unabridged.

---

## Reading order, if you're here to learn

Start with **[`crosshair/custom-crosshair.lua`](crosshair/custom-crosshair.lua)**
if you have never touched any of this. It reads nothing from the game and hooks
nothing — it draws shapes on your screen — so every value you change does
something you can see straight away and there is nothing to break. Then:

1. **[`movement/noclip.lua`](movement/noclip.lua)** — the simplest complete
   example. Shows the shape: per-frame loop, a registry that lets you undo
   cleanly, and handling the character dying underneath you.
2. **[`movement/flight.lua`](movement/flight.lua)** — physics constraints instead
   of position writes, and why that distinction matters.
3. **[`movement/auto-strafe.lua`](movement/auto-strafe.lua)** — the opposite
   trade-off: position writes, why they were chosen here anyway, and the
   velocity-zeroing trick that makes it work at all.
4. **[`movement/walkspeed-and-slide.lua`](movement/walkspeed-and-slide.lua)** —
   the most interesting technique in the set. Instead of fighting the game's
   output, it replaces a constant the game reads, using upvalue injection.
5. **[`movement/long-jump.lua`](movement/long-jump.lua)** — the lesson the other
   four build up to: don't reimplement a mechanic, find the function the game
   already uses for it and call that. Simpler, smoother, and far less visible.
6. **[`combat/weapon-mods.lua`](combat/weapon-mods.lua)** — the two techniques
   almost everything else is built from: editing the game's own stat tables, and
   wrapping the game's own functions so your code runs around them. Also the
   clearest example of why the menu's grouping is not the code's grouping.
7. **[`combat/no-spread-and-grenade-fuse.lua`](combat/no-spread-and-grenade-fuse.lua)**
   — the most technically interesting file here, and the one to read last.
   Instead of hooking the network call everyone hooks, it swaps a single
   variable inside a single function so the game hands its own messages to us on
   the way out. Read the walkspeed file first; this is the same idea, much
   further developed.

Others worth reading on their own, in any order:

- **[`combat/triggerbot.lua`](combat/triggerbot.lua)** — the smallest complete
  "does something in a fight" feature, and a good illustration of how much of
  this work is gates rather than cleverness.
- **[`esp/throwable-esp.lua`](esp/throwable-esp.lua)** — the small version of
  the one below, and the better place to start: one label per object, plus two
  habits worth keeping — pick the narrowest event signal that still works, and
  compare a value before writing it across a boundary.
- **[`esp/player-esp.lua`](esp/player-esp.lua)** — the only drawing-heavy file
  here. Object reuse, projecting 3D to 2D, and why a visibility answer is
  allowed to be slightly stale for an overlay but never for a trigger.
- **[`combat/aimbot.lua`](combat/aimbot.lua)** — target scoring in screen space
  rather than world space, why writing `camera.CFrame` does nothing in this
  game, and the yaw-wrap bug that anyone writing this from scratch hits.
- **[`visuals/viewmodel-animations.lua`](visuals/viewmodel-animations.lua)** —
  read straight after the removals file. It contains the single nicest trick in
  the project: swap the animation *track* for a do-nothing stub, let the game's
  own function run start to finish, then put the track back inside the same
  call. Nothing flickers and nothing gets confused, because the game did all its
  own bookkeeping. It also shows the `pcall` + restore + re-raise shape that any
  wrapper changing state around a call needs.
- **[`visuals/bullet-tracers.lua`](visuals/bullet-tracers.lua)** — the quietest
  file here, and the one to read before you assume every feature needs a hook.
  It reads the game's network traffic by asking politely: `OnClientEvent` takes
  as many listeners as you like, and the game's own enum library will encode the
  packet name you are looking for.
- **[`visuals/overlay-removals.lua`](visuals/overlay-removals.lua)** — six
  removals done five different ways, arranged from blunt to surgical: replace a
  method, replace what it sees, wrap it and undo it, change a number inside its
  compiled body, and change which function it calls. If you read one file to
  understand what can be done to code you did not write, read this one.
- **[`visuals/sound-visualizer.lua`](visuals/sound-visualizer.lua)** — the
  cleverest idea in the project relative to how little code it is. The game has
  to know where every sound comes from in order to play it, so it will tell you
  where everyone is if you ask it in the right place.
- **[`combat/ragebot.lua`](combat/ragebot.lua)** — read it for the first
  technique, which is the best thing in the project: your character's position
  is written at the end of one frame and un-written at the start of the next,
  so replication sees one value and the renderer never does. No hooks, no
  patching — just knowing what order things happen in. The file also has the
  bluntest honesty section here, because it needs one.
- **[`debug/silent-debug.lua`](debug/silent-debug.lua)** — the shortest useful
  lesson here, and the one most worth applying to your own code. When a
  decision has eleven inputs, have it return the NAMES of the ones that fired
  instead of a yes or no, and give each input its own switch. "It doesn't
  shoot" becomes "it's `burst_count`" and you are done in a minute instead of
  an afternoon.
- **[`misc/unlock-cosmetics.lua`](misc/unlock-cosmetics.lua)** — the last word
  on the idea half this project is built from. Instead of changing a value the
  game reads, it replaces the table that value lives in with one that has no
  contents at all, so every read becomes a function call it can answer however
  it likes. Then, for the one call it could not reach that way, it edits a
  string inside compiled bytecode so that a single call site looks up a
  different method name. Read it after the walkspeed and overlay-removals
  files; it is where both of those end up.
- **[`misc/staff-detector.lua`](misc/staff-detector.lua)** — nothing clever
  happens in it, and that is the point. It is the file about handling a
  question whose answer might be "I don't know": three-valued returns instead
  of booleans, caching how *complete* an answer was alongside the answer, and
  the generation counters that stop a slow reply landing after the world has
  moved on. If you write anything that waits on a network, read this one.
- **[`movement/movement-recorder.lua`](movement/movement-recorder.lua)** — the
  longest file here and the one with the least to do with cheating. Recording a
  stream of events so it can be replayed faithfully into a world that has since
  moved is a real engineering problem, and this is a complete worked answer:
  record changes rather than states, store coordinates relative to something
  that can move, replay in two phases with a stuck-detector, and keep a second
  stream of "where that should have put me" so you can tell when it has gone
  wrong. It also contains the two numerical bugs everyone writes at least once
  — angle wrapping, and framerate-dependent smoothing.
- **[`visuals/model-chams-and-highlight.lua`](visuals/model-chams-and-highlight.lua)**
  — the file to read if you want to write anything that changes objects you did
  not create. It is one long answer to "how do I put it back", and the answer —
  a reconcile pass with an active set — is the same shape you will end up using
  for half the features you ever write. Also contains the two details that give
  a first cham script away: the invisible-part rule, and weak tables.
- **[`world/lightning.lua`](world/lightning.lua)** — nothing to do with cheating
  at all, and the most enjoyable file to change numbers in. How to draw a
  lightning bolt from a straight line and a sine curve, why thunder has to
  arrive late, and a one-shot sound trick worth stealing.
- **[`automation/tripmine-auto-trigger.lua`](automation/tripmine-auto-trigger.lua)**
  — short, and it contains two ideas worth stealing: letting the game's own
  `CollectionService` tags keep your list of objects for you, and reading state
  the game never exposed as data by looking at what its renderer had to work out
  from that state.
- **[`combat/flickbot.lua`](combat/flickbot.lua)** — read after the aimbot. It
  is the answer to the aimbot's biggest problem, and it contains the most
  interesting maths in the project: an actual model of how a human hand moves a
  mouse, built from Fitts's law, log-normal velocity profiles, corrective
  submovements, tremor and drift.

## Why one file sometimes holds several menu options

The menu is arranged for whoever is playing; the code is arranged around
mechanisms. Those are not the same shape, so a file here covers whatever shares
a mechanism, and says so at the top.

`weapon-mods.lua` is the extreme case: twelve menu options spread across three
different tabs, all of them branches inside the same three pieces of machinery.
`walkspeed-and-slide.lua` and `auto-pickup.lua` are milder versions of it. If
you are looking for a specific menu option, the table at the top of this file
points at the file it actually lives in.

## A note on `:Kick()`

`walkspeed-and-slide.lua` and `jump-power.lua` each contain a line that kicks you
from the game. They are **not** malicious and they are not ours — they are
reproduced from the original Kicia implementation as self-protection measures
against a half-installed physics hook, and each file explains at length what its
line does, why it is there, and how to remove it if you'd rather.

We kept it because this is a reconstruction, and silently "improving" a guard
changes behaviour in ways that are hard to notice. Anywhere else you find
something surprising in these files, it is documented in the same way.
