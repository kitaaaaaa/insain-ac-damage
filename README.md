# Soft Body Damage for Assetto Corsa (prototype)

A Custom Shaders Patch Lua app that dents cars visually, on any car, with no per-car setup. The way 1nsane did
it: a hull of "atoms" wraps the car's body, dents push atoms in, springs between them spread a dent, and every
vertex of the body is pinned to the hull's triangles and follows them. 1nsane's cars came with their hulls made
by hand; here the hull is built from the car's own meshes. Visual only: AC's physics and collisions don't
change.

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
  the front 150% (a crumple zone), the rear 120%, the roof 80%, the sides 60% (door beams). Sliders.
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

- The meshes under the car's `BODYTR` node (the car's body, not its wheels and suspension) are read once
  (`getVertices`). Each vertex is put in the body's own coordinates through its node's transform.
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
```

`tests/scene_mock.lua` mocks the CSP calls the app makes, with a fake car (a turned, moved box body and a panel
under a rotated node).
