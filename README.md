# Soft Body Damage for Assetto Corsa (prototype)

A Custom Shaders Patch Lua app that dents cars visually, on any car, with no per-car setup. The way 1nsane did
it: a hull of "atoms" wraps the car's body, dents push atoms in, springs between them spread a dent, and every
vertex of the body is pinned to the hull's triangles and follows them. 1nsane's cars came with their hulls made
by hand; here the hull is built from the car's own meshes. Visual only: AC's physics and collisions don't
change.

## New in 0.7.2: the real cause of the slowdown (from your trace)

The trace showed it: on some cars a mesh sits far from the body (hundreds of metres; the crash lines put hits
"314 m from the middle"), so the box the hull was built over was hundreds of metres long, and those cars got
hulls of 45,000-75,000 atoms instead of about 600. Every dent on them went over all of those atoms and some
200,000 springs, ten times; and the same lever arm made tiny bumps look like hard hits (600 crash dents in two
minutes). And 12 cars came to 2.8 million vertices.

- **The car's box comes from AC** (its bounding box for the car). A mesh whose middle is more than 1 m outside
  it is left alone (the parts list says so, with how far out it is), and the hull's box goes no more than 0.6 m
  past AC's. Without a box from AC, it's around the middle of the car's meshes. And a safety net: at most 61
  rings along any hull.
- **A vertex budget**: 1 million vertices read in all (about 250 MB with AC's copies; a setting), the nearest cars
  first. The watched car is always read. The window shows how much is used.
- **One crash dent a frame** (the others wait their turn, 32 at most), **150,000 vertices sent to AC a frame**
  at most (the rest the next frame), and **3 crashes kept** at most for a car not read yet (the hardest).

Checked offline: with a mesh 300 m out, 0.7.1 made a 303 m box and a 20,342-atom hull (the test fails on it);
0.7.2 leaves that mesh alone and builds a 4.5 m box. The budget stops the second car being read; two cars
crashing in the same frame get their dents one frame apart.

## New in 0.7.1: performance with many damaged cars

0.7.0 got slower with each damaged car. What grew with them:

- **The detailed model**: every damaged car within 100 m was kept on its main model (with the dents), each
  drawn in full detail. Now only the 3 nearest, within 60 m (settings: how many, how far, or off).
- **Garbage collection**: each damaged car kept big Lua tables (which vertices had moved, which vertices sit
  on which hull triangle), and every garbage collection walked all of them, so each car made every collection
  slower. They're compact FFI arrays now, which the collector doesn't walk: a full collection with two heavily
  dented 137,000-vertex cars went from 1.4 ms to 0.4 ms (offline). And watching for crashes on every car no
  longer makes garbage every frame.
- **The window shows what the app costs**: its milliseconds a frame (crash watching and background work apart),
  Lua memory, and how many cars are kept detailed. If AC slows down while these stay small, the cost is in the
  drawing (the detailed models: turn that off to see), not the app's work.

## New in 0.7.0: every car in the session

- **Which cars**: the one you're watching, and every other car within 100 m of the camera (a setting), read
  one at a time, the nearest first, in the background. The window shows how many are read and dented.
- **Crashes on every car**, read or not: a car hit before it's read is read straight away and then dented
  where it was hit (the hit is kept in the car's own axes till then).
- **Memory**: the per-vertex data is in compact arrays now (about 150 bytes a vertex, from about 430), so a
  detailed car takes some 15-20 MB, not 50. An undamaged car that goes further than 150 m from the camera is let
  go (read again if it comes back); a damaged one is kept.
- **Far away**: AC shows simpler models of far cars (LODs), and those don't have the dents: the dents are on the
  car's main model. So a damaged car keeps its main model near the camera (0.7.1: the 3 nearest within 60 m; it
  costs drawing time). Past that it shows AC's simpler model, without its dents.
- Settings: **Every car in the session** (off: just the watched one, as before), how far to read, and the
  detailed-model distance.

Checked offline (two cars: tests/cars_test.lua): both read, a crash dents the car that crashed and not the
other, a dented car keeps its main model near and not far, an undamaged far car is let go, and a crash on a car
not read yet reads it and dents its front. Not tested in AC yet: how a full grid feels (setup runs one car at a
time in the background), and AI and online cars (a car AC reports as not connected is skipped).

## New in 0.6.0: spring limits (1nsane's)

1nsane's physics files give every spring between atoms its length at rest and how far it may squash and
stretch (half to one and a half times). Here every edge of the hull is such a spring (hull only; the box lattice
is as it was):

- **Stretch** (default 1.05x at most): sheet metal hardly stretches, so a deep dent drags the metal around it in
  rather than poking a spike. The middle of the dent keeps its depth (it's held where the hit put it); the
  atoms around it give.
- **Squash** (0.5x at most): pushed harder than that, an edge shoves the next atom along.
- **Folds**: squashed past 0.9x, the metal folds: its atoms get crunch from the squeeze (1 m of crunch per metre
  squashed past that, times the Crunch setting, up to the crunch's limit). It's "at least this much", so the
  same squeeze doesn't pile up dent after dent.
- Settings: **Spring limits** on or off, and the four values. The spring passes (spreading each dent) are as
  before; the limits come after them.

Checked offline: a narrow 30 cm push that stretched edges to 1.4x without them keeps every edge within 0.5 to
1.05x, the middle as deep, and moves over twice as many atoms; a nose pushed straight back squashes no further
than 0.5x and folds. Modest dents look much as in 0.5.1 (the spring passes spread them already); deep crash
dents are where it shows. Not tested in AC yet.

## New in 0.5.1

- **More of the car dents**: meshes outside BODYTR are read too (see How it works), so lights and glass some
  cars keep there dent with the body. A setting turns it off.
- **Show the parts** (a box in the window): every mesh of the car and what became of it: body, interior (and
  how much it moves), left still (and why), outside BODYTR, on a moving part, no vertices, and how many of its
  vertices are moved now. If a part doesn't dent, this says why (the trace file has it too).
- **The quarters give more sideways**: a tail swinging into a wall crumples the rear corner (see Which way,
  how far).

## New in 0.5.0: the car-shaped hull

Until 0.4.0 the atoms were a box lattice over the car (atoms in the air around it and inside it). Now they're a
hull on the body's outside, shaped like the car, as in 1nsane (from reverse-engineering its files: each vertex
sits at `a + u(b - a) + v(c - a) + h (b - a) x (c - a)` for a triangle of atoms a, b, c; the game stored u, v, h
per vertex, this app works them out when it reads the car).

- **The hull**: rings of atoms around the car every 0.3 m along its length, 20 around each, each as far out as
  the body goes in its direction, pushed out until the hull goes around every vertex. At each end, smaller
  rings down to a middle atom, each as far forward (back) as the body goes at its spot, so the hull follows the
  nose and the tail.
- **Pinning**: each vertex goes to the hull triangle over it (and a second one beside it, at a seam, blended),
  with its place on the triangle and its height off it. A dent moves atoms; the triangles move, bend and
  stretch, and the vertices with them. Normals turn with their triangles.
- **Why**: atoms are on the metal, so a hit pushes the side that was hit and only that (a box lattice's atoms
  also sit inside the car and on the far side of a narrow part), and dents spread along the body's surface
  (springs follow the hull's edges) rather than through the air.
- The box lattice is still there (settings: **Atoms**, then **Rebuild**) to compare.
- The window shows the hull's atoms and triangles.

Checked offline (the tests, and on the body of a car model from 1nsane): moving the whole hull moves every
vertex exactly with it, dents stay on the side hit, nothing on the dented side goes out more than 2 mm, and no
vertex moves more than the dent. Pinning a 120,000-vertex body is about half a second of work, spread over
frames while the car is read. Not tested in AC yet.

This first version is for finding out what works in the game, so it has test dents and shows timings.

## Install

Copy the `softdamage` folder to `assettocorsa\apps\lua\`, or drag the .zip file over Content Manager. In a
session, open "Soft Body Damage" from the app bar: it reads the body of the car you're watching, a mesh per
frame (a setting turns that off, for a **Read this car** button instead).

Each step that calls into CSP is written to `softdamage_trace.txt` in the app's folder, a line at a time, so
if AC crashes, the file's last line shows where.

## Trying it

- **Crashes** dent every car that's been read, where it was hit and the way it was pushed, deeper and
  crunchier the harder the hit. Where: an impulse J at r from the car's middle changes its velocity by J/m and
  its spin by I^-1 (r x J), so from the two changes the hit is found, r = k^2 (dv x dw) / |dv|^2 (k from the
  body's size; the spin from how the car's axes turn between frames). So a tail swinging into a wall dents the
  tail, a quarter panel the quarter, the middle of the side the doors. How hard: the change at the contact
  point, dv + dw x r (a tail strike mostly spins the car: the middle barely changes). An impact starts with a
  jump over 3 g (braking and cornering stay under about 2 g) at the middle or, through the spin, at the ends,
  or AC reporting a contact; the biggest change over the next 150 ms is the hit, and it dents from 2.5 m/s at
  the contact. A push from below (a landing) counts 15%: the suspension takes it. A teleport (over 5 m in a
  frame) isn't a crash. Each crash is in the trace file: its speed, where, and the depth.
- **Buttons** dent the front, back, left, right or roof; **Repair** undoes it all. Depth, radius and crunch
  are sliders.
- **Ctrl + left click** on the car dents it there, along the view.
- Going back to the pits, or being reset, repairs the car.

## Which way, how far

- **Each way gives differently**: a dent's depth is scaled by the way the car was pushed, in its own frame:
  the front 150% (a crumple zone), the rear 120%, the roof 80%, and pushed sideways, the doors 60% (beams in
  them) rising to 130% at the front and rear quarters (crumple zones: a tail into a wall bends the corner).
  Sliders.
- **The interior** (the cockpit: AC's `COCKPIT_HR` / `COCKPIT_LR` nodes) moves with the body, half as much.
  The driver, the steering wheel and gauge needles don't move at all.
- **Limits**: a spot of the body moves at most half a foot (0.15 m), a spot of the interior a quarter foot
  (0.076 m). And the body doesn't go through the interior: at setup, each body vertex finds its clearance (the
  nearest interior vertex), and it moves only as far as closes that gap, counting the interior there moving
  with it. What a hit asks beyond a limit goes to the crunch, so the metal crumples against the interior
  instead. Sliders for all three.

## Crunch

Dented metal is crumpled with 3D Perlin noise: each dented vertex moves in and out along its surface's normal
by the noise times the crunch there, and its normal tilts with the noise's slope, so the creases catch the
light. The crunch is a second value on each atom, added by each dent with the same falloff and springs, and it
grows faster than the dent with how hard the hit was (a test dent: its depth; a crash: its speed), so a tap
leaves a smooth dent and a big hit crumples the metal. **Creases** (ridged noise: sharp folds) is the default
style, **Hammered** (bumps) the other; the biggest creases are about 0.25 m, with finer ones on top, and the
crunch moves the metal at most 6 cm (settings). Each car gets its own noise, so no two crumple alike.

The window shows the meshes and vertices read, the lattice, and how long setup and each re-skin took.

## Tests in the window

Dents change the car's own meshes (`alterVertices`). The calls go out from the app's normal update, not from
inside the background work, and the driver, steering wheel, cockpit and gauge needles are left alone (by AC's
node names, and "needle" in a mesh's name). A setting makes dents go to copies of the meshes instead, but
test C crashed AC (at the `clone()` before `createMesh`, it turned out).

The window has tests for finding out what works. Run them one per AC launch, since a crash ends AC
(`softdamage_trace.txt` then shows the step):

- **A**: sends a small track mesh back unchanged.
- **B**: sends the car's smallest body mesh back unchanged.
- **C**: makes a copy of that mesh, hides the original, lifts the copy 5 cm. **Undo C** puts it back.
- **D**: lifts that mesh 5 cm (changed vertices) and sends it.
- **E**: the same as D, sent from inside a coroutine. **Undo D/E** puts it back.

So far (a 1971 Dodge): A and B pass; C and D crashed AC, and the dents did too (fixed in 0.1.4). What they had in common was
CSP's `VertexBuffer:clone()` (the traces stop right before it), so the app doesn't use it: a fresh copy of a
mesh's vertices comes from `getVertices()` again.

## How it works

- The meshes under the car's `BODYTR` node are read once (`getVertices`), and the car's other meshes too
  (lights, glass, trim some cars keep outside BODYTR), except those on moving parts (by their names: wheels,
  tyres, rims, hubs, discs, calipers, suspension, steering, wipers, the driver, shadows, blur). If one of those
  others moves on the body after all (its node moves), it's put back and not dented again (the trace says so). Each vertex is put in the body's own coordinates through its node's transform.
- The hull is built around them and each vertex pinned to it (see above); or, with the box lattice, atoms
  every 0.35 m over the body's box.
- A dent pushes the atoms near it (at least the nearest) along the hit, by up to the depth asked with a smooth
  falloff; spring passes spread that dent to the atoms around it (along the hull's edges). An atom keeps its
  offset (the metal stays bent), up to a limit.
- Each vertex moves with its triangles (the hull) or by the atoms' offset where it sits (the lattice: trilinear
  interpolation, a free-form deformation), and its normal turns with them, so dents catch the light. Only the
  vertices on triangles (in cells) next to atoms that moved are redone, and only changed meshes are sent back
  (`alterVertices`).

## What to look for (not known yet)

- 0.5.0: do dents look better or worse than 0.4.0's (Atoms: Box lattice, then Rebuild, to compare)? Setup time
  on a detailed car (shown in the window). Anything poking out or swinging oddly when a dent is near a concave
  spot (where the bonnet meets the windscreen, around the wheel arches): those vertices sit under the hull, not
  on it.
- Does the car dent at all? (Is `alterVertices` allowed on car meshes from an app?)
- Do dents land where they should, the right way (front button: the front pushed in)?
- Setup and re-skin times on a detailed car, and any stutter.
- Shading around dents, and transparent parts (glass, lights).
- Two cars of the same model: does denting one dent the other? (Shared meshes.)
- Lower-detail models (LODs) at a distance: do they show the dents?
- The cockpit view: does the interior bend too?
- Online: other players' cars.

## Tests

From this folder, with LuaJIT:

```
luajit tests/hull_test.lua
luajit tests/lattice_test.lua
luajit tests/noise_test.lua
luajit tests/app_test.lua
ATOMS=box luajit tests/app_test.lua
luajit tests/cars_test.lua
```

`tests/scene_mock.lua` mocks the CSP calls the app makes, with a fake car (a turned, moved box body and a panel
under a rotated node).
