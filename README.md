# Soft Body Damage for Assetto Corsa (prototype)

A Custom Shaders Patch Lua app that dents cars visually, on any car, with no per-car setup. In the spirit of
the "atoms" of 1nsane and Live for Speed's visual damage: a lattice of atoms covers the car's body, dents push
atoms in, springs between them spread a dent, and every vertex of the body follows the atoms around it.
Visual only: AC's physics and collisions don't change.

This first version is for finding out what works in the game, so it has test dents and shows timings.

## Install

Copy the `softdamage` folder to `assettocorsa\apps\lua\`, or drag the .zip file over Content Manager. In a
session, open "Soft Body Damage" from the app bar: it reads the body of the car you're watching, a mesh per
frame (a setting turns that off, for a **Read this car** button instead).

Each step that calls into CSP is written to `softdamage_trace.txt` in the app's folder, a line at a time, so
if AC crashes, the file's last line shows where.

## Trying it

- **Crashes** dent every car that's been read, where it was hit and the way it was pushed, deeper and
  crunchier the harder the hit. An impact is a jump in the car's velocity over 3 g in a frame (braking and
  cornering stay under about 2 g), or AC reporting a contact; the hit is the biggest change of velocity over
  the next 150 ms, and it dents from 2.5 m/s. A teleport (over 5 m in a frame) isn't one. Each crash is in the
  trace file with its speed and depth.
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
- A lattice of atoms covers the body's box, one about every 0.35 m. A dent pushes the atoms near it along the
  hit, by up to the depth asked with a smooth falloff; spring passes spread that dent to the atoms around it.
  An atom keeps its offset (the metal stays bent), up to a limit.
- Each vertex moves by the atoms' offset where it sits (trilinear interpolation, a free-form deformation), and
  its normal turns with the lattice's local stretch, so dents catch the light. Only the vertices near atoms
  that moved are redone, a few milliseconds of work per frame, and only changed meshes are sent back
  (`alterVertices`).

## What to look for (not known yet)

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
luajit tests/lattice_test.lua
luajit tests/noise_test.lua
luajit tests/app_test.lua
```

`tests/scene_mock.lua` mocks the CSP calls the app makes, with a fake car (a turned, moved box body and a panel
under a rotated node).
