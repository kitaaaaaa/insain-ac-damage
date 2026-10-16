# Soft Body Damage for Assetto Corsa

Assetto Corsa barely shows crash damage. Hit a wall at 100 km/h and the car comes away looking much the same
(at most, some cars swap in a pre-made "damaged" bumper). This app makes cars **dent and crumple where they
were hit**: a nose crushed by a wall, a rear corner caved in where another car hit it, the metal more crumpled
the harder the hit.

It works on **any car**, including mods, with no setup per car. It works out each car's shape by itself the
first time it sees it.

It's **visual only**. It doesn't change how the car drives, its physics, or what it collides with. The bent
metal is there to look at, nothing more.

> **Status: prototype.** It works and has been tested on a handful of cars, but expect rough edges: on some
> cars a few parts won't dent, and on busy grids it costs some performance (see [Performance](#performance)).

## What you need

- **Assetto Corsa** (the original, 2014).
- **Custom Shaders Patch (CSP)**, which most people install through Content Manager. This app is a CSP
  "Lua app": CSP is what lets it reach into the car models. Use a recent version.

## Installing

1. Download this repository: on GitHub, **Code**, then **Download ZIP**, and unzip it.
2. Rename the unzipped folder (`insain-ac-damage-main`) to `softdamage`.
3. Move it into your Assetto Corsa folder, under `apps\lua\`. You should end up with
   `assettocorsa\apps\lua\softdamage\manifest.ini`.
4. Start a session (practice is easiest). In the app bar on the right side of the screen, find
   **Soft Body Damage** and click it to open its window.

The app starts when you first open its window, and keeps working (window open or closed) until you quit AC.

## Using it

Just drive. Once the window has been opened, the app reads the car you're watching, then the other cars near
you. The top line of its window shows how far it's got. From then on:

- **Crash**, and the car dents where it was hit, in the direction it was pushed. A tap leaves a shallow,
  smooth dent; a big hit leaves a deep, crumpled one. Dents add up: hit the same corner twice and it gets worse.
- **Other cars** dent in their crashes too, AI or other players online.
- **Go back to the pits** (or reset the car) and it's repaired.
- **Repair slowly**, as in Carmageddon: hold the **Repair slowly** button and the damage goes back a bit at a
  time, dents easing out and bent wheels straightening; let go and it stops where it got to. Bind it to a key
  or a controller button in the app's window (next to "Repair slowly (hold):"). It works on the car you're
  watching. With the **Carmapeds** app running, repairs cost credits (see below).

To see how it looks without crashing:

- The **front / back / left / right / roof** buttons in the window dent the car there. The **Dent depth**,
  **Dent radius** and **Crunch** sliders below them set how big.
- **Ctrl + left click** on the car dents it where you click.
- **Repair** undoes it all.

## How it works

You don't need any of this to use the app, but it helps when tuning the settings.

### The car's shape: a hull of "atoms"

The idea comes from **1nsane** (Invictus, 2000), an off-road racing game whose damage still looks good. In
1nsane, every car had a rough outline made of points called **atoms**, joined into triangles: a very
low-detail copy of the car's body. The real, detailed model is pinned to that outline: each point of the model
(each **vertex**) belongs to a triangle of atoms, at a set place on it and a set height above it. Push some atoms
in and their triangles bend, and every vertex pinned to them follows, so the whole detailed body bends.

1nsane's artists made each car's outline by hand. This app builds it by itself, from the car's own model:

1. It reads the car's body (the meshes of its 3D model) once.
2. It wraps a **hull** of atoms around it: rings of atoms around the car every 30 cm along its length, 20 atoms
   per ring, each just outside the bodywork, and smaller rings at the front and the back that follow the shape
   of the nose and the tail.
3. It **pins** every vertex of the body to the nearest triangle of the hull. A detailed car has a hundred
   thousand vertices or more, so this takes a second or two, done a little each frame in the background.

### A dent

When a car is hit, the atoms near the hit are pushed in, in the direction of the push: most at the middle,
fading out around it. Then:

- **Springs** join neighbouring atoms (along the edges of the hull's triangles). After a dent they pull the
  atoms around it in a little, so the dent spreads into the panel instead of leaving a sharp crater.
- **Spring limits** (also from 1nsane): sheet metal hardly stretches, so when a dent would stretch the metal
  between two atoms too far, it drags the next atom in with it. Deep hits make wide dents, not spikes. And
  where metal is squashed together, it **folds**.
- **One direction**: everything a hit moves, it moves the way the car was hit. The metal around a dent is
  dragged along with it, not sideways towards it, and a harder hit goes deeper rather than wider. So a hard
  hit on a corner crushes that corner in, instead of looking as if the corner was hit from every side.
- **Crunch**: dented metal isn't smooth, it crumples. The app adds creases to dented areas (with Perlin noise,
  a kind of natural-looking randomness), more the harder the hit and where the metal folded. The creases push
  the metal further in or less far, along the way it was hit, and bend the shading, so they catch the light.
- **Parts standing off the body**, like a bull bar's tubes, keep their size as they're bent: each point stays
  as far off its triangle of atoms as it was. (1nsane scaled that distance with the triangle's size, so tubes
  swelled where the hull stretched.)

Then every vertex pinned to a moved triangle is given its new place, and **bends** there: rather than
jumping, the metal eases in over about a third of a second, fast at first and settling, so you see it give way.
A second hit while it's still moving carries on from wherever it's got to.

### Not every part dents the same

- **The front and the rear give most**, like the crumple zones of a real car. **The doors give least**: there
  are beams in them. So a sideways hit at a front or rear corner dents much more than one at the doors.
- **The roof** gives a little less than the ends.
- **The interior** (the cockpit) bends with the body, half as much. **The driver, the steering wheel** and the
  gauge **needles** never move.
- **How far**: the body goes in as far as it's pushed: there's no limit (there's a setting for one). The
  interior moves at most about 7.5 cm, and the body never goes through it: before it would, the metal crumples
  against it instead.
- **The wheel wells stay clear of the wheels**: the app knows where each wheel is and how big its tyre is, and
  keeps the bodywork out of the space each wheel needs (with room for the suspension to move, and at the
  front, for the steering). A crushed wing folds around the wheel instead of into it.
- **Wheels** aren't bodywork: they're found by their names (wheels, rims, tyres) and also by their shape (a part
  centred on a wheel's hub and about the size of its tyre), so wheels a CSP extension puts in, whatever they're
  called, count as wheels too. A hard hit beside a wheel **bends** it: its parts tilt a few degrees about the
  hub, so it wobbles as it turns, like a bent rim or axle. A repair straightens it.
- **Other moving parts** (brakes, suspension, wipers) are left alone.
- **Any size of car**: the hull's spacing, the size of dents, the crunch and the wheel spaces are all scaled to
  the car, so a model car half a metre long dents like a full-size one, not as if hit by something its own
  size.

### Repairs and other apps (Carmapeds)

While it repairs slowly, the app tells other Lua apps how much it put right, each frame, as a CSP shared event,
`softdamage.repair`: `{car = index, repaired = per cent, damage = per cent left}`, in per cents of a wrecked
car. An app can stop it for a car with `softdamage.repairBlocked`: `{car = index, blocked = true}` (and let
it go on with `blocked = false`). Carmapeds uses these to charge credits for repairs, at C1's repair cost (30
credits a per cent of damage, from C1's GENERAL.TXT), and, with its "repairs need credits" setting, to stop
them when the money runs out.

### Finding crashes

AC doesn't tell apps where a car was hit, so the app works it out from how the car moves. A hit square on the
nose just slows the car; a hit at a rear corner also spins it. From how much the car's speed and spin change in
an instant, the app works out where the push came from and how hard it was. A push straight along the car doesn't
say how far along it landed, and in a hard hit the car pitches, which would make the contact look high up, so
for level hits the app looks for the car's outside from the push's side, at bumper height, on its hull: a hard
head-on hit dents the front, not the windscreen. Braking and cornering change the
speed far more gently than a crash does, so they don't count. Landing a jump is mostly the suspension's job, so
it dents little.

## The window

At the top, the window shows what the app is up to:

- **Cars read** (and how many are dented), and which car it's reading now.
- **App: … ms a frame**: how much time the app takes each frame. A millisecond or two is normal, more while a
  car is being read or a dent is being made.
- **Lua memory** and **Vertices read**: how much of its memory budget it's using (see Performance).
- For the car you're watching: its parts, its hull, and how long reading it and the last dent took.
- **Show the parts**: every part of the car's model and what the app made of it: body, interior, left still
  (and why), on a moving part, too far from the car. If some part of a car doesn't dent, this says why.

The **A** to **E** test buttons check what works on a given PC and AC setup; you can ignore them.

## Settings

Open them with the gear icon on the app's window; **Reset all settings to their defaults** is at the top. The
useful ones:

**How much damage**

| Setting | What it does |
|---|---|
| Crash dent scale | How deep crash dents are: lower for subtler damage, higher for more. |
| Front / Rear / Doors / Quarters / Roof give | How easily each part of the car dents, compared with the others. |
| Body moves at most, Interior moves at most | The deepest a dent can go: no limit for the body to begin with (the slider at its top), 7.5 cm for the interior. |
| The body crumples against the interior, not through it | On: the body stops at the cockpit and crumples there. |
| Crunch (in the main window), Crunch: biggest creases, Crunch: at most | How crumpled dented metal looks, how big the creases are, and how deep they can go. At 0% crunch, dents are smooth. |
| Crunch style | **Creases** (sharp folds, like crumpled sheet metal) or **Hammered** (round bumps). |
| Metal bends in over … s | How long a dent takes to bend in. 0: at once. |
| Repairing slowly: …% of a wreck a second | How fast the Repair slowly button puts the car right. |
| Spring passes | How far a dent spreads into the panel around it. |
| Spring limits; Metal stretches, Squashes, Folds | How much the metal between atoms may stretch or squash, and when it folds. |

**Which cars**

| Setting | What it does |
|---|---|
| Read cars without the button | Off: nothing is read until you press **Read this car**. |
| Every car in the session | Off: only the car you're watching gets damaged. |
| Read cars within … m of the camera | Cars this near are read ahead of time. A car that crashes further away is read then, and dented a moment later. |
| Vertices read at most | The memory budget (see Performance). |
| Damaged cars keep their detailed model; up to … m; the nearest … | See [Far away cars](#far-away-cars). |

**The hull**

| Setting | What it does |
|---|---|
| Atoms | **Car-shaped hull** (the normal way) or **Box lattice** (an older, simpler way: a 3D grid of atoms over the car's box). |
| Hull rings every … m, Hull atoms around | How fine the hull is. Finer gives smaller, more precise dents, and costs more time and memory. |

Settings marked **(rebuild)** apply to cars read after the change; **Rebuild** reads the car you're watching
again.

## Performance

Denting a detailed car means moving tens of thousands of points. How the work is spread:

- When a car is hit, the app works out where every point of the dent ends up, the middle of the dent first,
  with up to 12 ms of work on the frame it happens (setting: **Work on a new dent, its first frame**) and up to
  4 ms on each frame after (**Work per frame after that**).
- Then the metal **bends** in over about 0.3 s (**Metal bends in over**): each frame, every point that's still
  moving goes a step further. That part is light: a blend per moving point.
- Everything a dent needs is prepared when the car is read (a copy of its model, the crumple pattern), so
  nothing has to be fetched at the moment of a crash.

Set **Metal bends in over** to 0 for dents that appear in one go instead.

Reading cars is the slow part, and it happens ahead of time, in the background:

- **Reading** a car takes a second or two of background work (up to 2 ms a frame), longer for very detailed
  cars. That's why the app reads nearby cars before they crash. A car that crashes before it's been read is read
  then, and dented as soon as that's done.
- **Memory**: each car read takes very roughly 15–30 MB. The app stops reading more cars at 1 million vertices
  in all (a setting), nearest cars first; the car you're watching is always read. When memory runs short, it
  lets go of far away cars that aren't damaged.
- On a big grid with many damaged cars, if it's too heavy for your PC, turn **Every car in the session** off.

### Far away cars

AC draws far away cars with simpler models (**LODs**) to save time. The dents are made on each car's main
model, so from far away a dented car shows its simpler, undamaged model. To hide that, the app keeps the 3
nearest damaged cars within 60 m on their main models (settings), which costs some drawing time.

## Limits

- **Visual only**: the physics, handling and collisions are AC's own, unchanged.
- **Only on your screen**: the dents are made by the app on your PC. Online, other players see them only if they
  run the app too, and then their app makes its own.
- **Some parts may not dent** on some cars, depending on how the car's model was built. **Show the parts** says
  why.
- **Two cars of the same model**: it's not known yet whether denting one shows on the other.
- Crashes are worked out from motion, so an unusual hit can land a little off from where it really happened.

## If something goes wrong

The app writes every step it takes to `softdamage_trace.txt`, in its folder (`apps\lua\softdamage\`), a line at
a time. If AC crashes or something looks wrong, the last lines of that file show what the app was doing; send
the file along with a bug report.

## For developers

The code: `softdamage.lua` (the app: reading cars, crashes, dents, the window), `src/hull.lua` (the hull: its
atoms, triangles, springs and pinning), `src/lattice.lua` (the box lattice), `src/noise.lua` (the Perlin noise
for the crunch), `src/arrays.lua` (compact arrays).

The tests run outside the game with LuaJIT, against a mock of the CSP functions the app uses
(`tests/scene_mock.lua`). From the app's folder:

```
luajit tests/hull_test.lua
luajit tests/lattice_test.lua
luajit tests/noise_test.lua
luajit tests/app_test.lua
ATOMS=box luajit tests/app_test.lua
luajit tests/cars_test.lua
luajit tests/small_test.lua
luajit tests/repair_test.lua
luajit tests/crash_test.lua 3
```

## Credits

The atom hull and its spring limits follow how 1nsane (Invictus Games, 2000) did its damage, as worked out from
its game files. No files from 1nsane are included here.
