-- Every car in the session: two cars, the watched one (0) and another (1) 30 m from the camera.
-- luajit tests/cars_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local H = require('tests/scene_mock')({n = 12, cars = 2})
H.storage.atoms = os.getenv('ATOMS') or 'hull'
local orig2 = H.body2Mesh.vertices:copy()
local function moved(buf, ref)
  local n = 0
  for i = 0, ref.n - 1 do
    local a, b = buf.raw[i].pos, ref.raw[i].pos
    if math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) > 1e-9 then n = n + 1 end
  end
  return n
end
H.load()
H.settle()
for _ = 1, 10 do H.frame() end
H.settle()
local cars = H.state.cars
check(cars[0] and cars[0].state == 'ready', 'the watched car read')
check(cars[1] and cars[1].state == 'ready', 'the other car (30 m away) read too')
check(cars[1] and cars[1].vertices == orig2.n, 'its own body: ' .. tostring(cars[1] and cars[1].vertices))

-- a crash on the other car: 12 m/s into a wall, head on
local fwd2 = H.body2World:transformVector(vec3(0, 0, 1))
local function drive(car, look, speed, frames) for _ = 1, frames do car.velocity:set(look * speed) H.frame() end end
local v = 0
while v < 12 do v = v + 5 / 60 H.car2.velocity:set(fwd2 * v) H.frame() end
drive(H.car2, fwd2, 12, 30)
drive(H.car2, fwd2, 0.5, 30)
H.settle()
check((cars[1].crashes or 0) == 1 and moved(H.body2Mesh.vertices, orig2) > 0, 'the other car dents in a crash: ' .. tostring(cars[1].crashes))
check((cars[0].crashes or 0) == 0 and (cars[0].dents or 0) == 0, 'the watched car untouched')
-- dented and near: kept on its detailed model
local before = H.detailed[1] or 0
H.frame()
check((H.detailed[1] or 0) > before, 'a dented car keeps its detailed model')
check(not H.detailed[0], 'an undamaged one is left to AC')
-- far away, but dented: kept
H.car2.distanceToCamera = 400
for _ = 1, 5 do H.frame() end
check(cars[1] and cars[1].state == 'ready', 'a dented car far away stays read')
check((H.detailed[1] or 0) == before + 1, 'and past the distance, left to AC: ' .. tostring(H.detailed[1]))
-- repaired (to the pits) and far, and memory getting full: let go (not otherwise: reading it again costs more)
H.jumps[1](1)
H.settle()
for _ = 1, 5 do H.frame() end
check(cars[1] ~= nil, 'an undamaged far car is kept while there is room')
H.storage.maxVertices = math.floor((cars[0].vertices + cars[1].vertices) * 1.05)
H.settle()
for _ = 1, 5 do H.frame() end
check(cars[1] == nil, 'an undamaged car far away is let go')
-- a crash while it isn't read: kept, the car read first, then dented
drive(H.car2, fwd2, 0.5, 10)
local v2 = 0.5
while v2 < 15 do v2 = v2 + 5 / 60 H.car2.velocity:set(fwd2 * v2) H.frame() end
drive(H.car2, fwd2, 15, 20)
check(cars[1] == nil, '(still not read before the crash)')
H.body2Mesh.vertices = orig2:copy()
drive(H.car2, fwd2, 0.5, 30)
check(cars[1] ~= nil, 'a crash reads the car')
H.settle()
H.frame()
check(cars[1] and (cars[1].crashes or 0) == 1 and moved(H.body2Mesh.vertices, orig2) > 0, 'and dents it once read: ' .. tostring(cars[1] and cars[1].crashes))
-- at the front (+z in its body)
local front = 0
for i = 0, orig2.n - 1 do
  local a, b = H.body2Mesh.vertices.raw[i].pos, orig2.raw[i].pos
  if math.abs(a.z - b.z) > 1e-6 and b.z > 1.0 then front = front + 1 end
end
check(front > 0, 'the kept crash dents the front: ' .. front)
-- just the watched car (all cars off)
local H2 = require('tests/scene_mock')({n = 8, cars = 2})
H2.storage.allCars = false
H2.load()
H2.settle()
for _ = 1, 10 do H2.frame() end
H2.settle()
check(H2.state.cars[0] and not H2.state.cars[1], 'all cars off: only the watched one read')
-- a mesh 300 m from the body (seen on real cars): left alone; the hull and the crash lever arm stay car-sized
local H3 = require('tests/scene_mock')({n = 10, farMesh = true})
H3.load()
H3.settle()
for _ = 1, 5 do H3.frame() end
H3.settle()
local b3 = H3.state.cars[0]
check(b3 and b3.state == 'ready', 'read with a far mesh')
local farStatus
for _, part in ipairs(b3.parts) do if part.name == 'far_away_plane' then farStatus = part.status end end
check(farStatus and farStatus:find('outside the car', 1, true), 'the far mesh left alone: ' .. tostring(farStatus))
check(b3.max[3] - b3.min[3] < 5 and b3.atoms.count < 1500, ('the box and hull car-sized: %.1f m long, %d atoms'):format(b3.max[3] - b3.min[3], b3.atoms.count))
-- a vertex budget: with room for one car only, the other isn't read (the watched one always is)
local H4 = require('tests/scene_mock')({n = 10, cars = 2})
H4.storage.maxVertices = 700
H4.load()
H4.settle()
for _ = 1, 10 do H4.frame() end
H4.settle()
check(H4.state.cars[0] and not H4.state.cars[1], ('budget full: the other car not read (%d vertices)'):format(H4.state.cars[0] and H4.state.cars[0].vertices or -1))
-- a crash dent at most a frame
local H5 = require('tests/scene_mock')({n = 10, cars = 2})
H5.load()
H5.settle()
for _ = 1, 10 do H5.frame() end
H5.settle()
local c5 = H5.state.cars
local function hitBoth()
  local f1, f2 = H5.bodyWorld:transformVector(vec3(0, 0, 1)), H5.body2World:transformVector(vec3(0, 0, 1))
  local v = 0
  while v < 12 do v = v + 5 / 60 H5.car.velocity:set(f1 * v) H5.car2.velocity:set(f2 * v) H5.frame() end
  for _ = 1, 20 do H5.frame() end
  H5.car.velocity:set(f1 * 0.5) H5.car2.velocity:set(f2 * 0.5)
end
hitBoth()
local maxInFrame = 0
for _ = 1, 30 do
  local before = (c5[0].crashes or 0) + (c5[1].crashes or 0)
  H5.frame()
  maxInFrame = math.max(maxInFrame, (c5[0].crashes or 0) + (c5[1].crashes or 0) - before)
end
check((c5[0].crashes or 0) == 1 and (c5[1].crashes or 0) == 1, ('both cars dented: %s, %s'):format(tostring(c5[0].crashes), tostring(c5[1].crashes)))
check(maxInFrame == 1, 'one crash dent a frame at most: ' .. maxInFrame)
-- dents go first: the watched car's dent shows while another car is still being read
local H6 = require('tests/scene_mock')({n = 40, cars = 2})
H6.car2.distanceToCamera = 400  -- (not read yet)
H6.load()
H6.settle()
for _ = 1, 5 do H6.frame() end
H6.settle()
local c6 = H6.state.cars
check(c6[0] and c6[0].state == 'ready' and not c6[1], '(the other car not read yet)')
H6.car2.distanceToCamera = 30
H6.frame()  -- starts reading the other car
local W6 = c6[0].node:getWorldTransformationRaw()
local sent0 = H6.altered.body or 0
H6.state.dentWorld(c6[0], W6:transformPoint(vec3(0, 0.6, 2.2)), W6:transformVector(vec3(0, 0, -1)), 0.15, 0.6)
local frames = 0
while (H6.altered.body or 0) == sent0 and frames < 200 do H6.frame() frames = frames + 1 end
check(c6[1] and c6[1].state == 'reading meshes', 'the other car still being read: ' .. tostring(c6[1] and c6[1].state))
check(frames < 30, ('the dent showed after %d frames, before the reading finished'):format(frames))
-- car to car: the watched car rear-ends the other (AC's contact says car 1): the other's rear dents about as much
-- as the watched car's front, and once (its own reading of the hit is dropped)
local H7 = require('tests/scene_mock')({n = 12, cars = 2, ahead = true, brakeLight = true,
  lights = {LIGHT_0 = {NAME = {'headlight_glass'}}, BRAKE_0 = {NAME = {'brake_light_l'}}}})
H7.storage.atoms = os.getenv('ATOMS') or 'hull'
H7.load()
H7.settle()
for _ = 1, 10 do H7.frame() end
H7.settle()
local c7 = H7.state.cars
check(c7[0] and c7[0].state == 'ready' and c7[1] and c7[1].state == 'ready', '(both cars read)')
local o0, o1 = H7.bodyMesh.vertices:copy(), H7.body2Mesh.vertices:copy()
local fwd7 = H7.bodyWorld:transformVector(vec3(0, 0, 1))
local v7 = 0
while v7 < 12 do v7 = v7 + 5 / 60 H7.car.velocity:set(fwd7 * v7) H7.frame() end
for _ = 1, 30 do H7.frame() end
-- the hit: the watched car from 12 to 5 m/s, the other pushed from 0 to 7 (it reports no contact: a remote car)
H7.car.collidedWith = 2
for k = 1, 3 do
  H7.car.collisionDepth = 0.05
  H7.car.velocity:set(fwd7 * (12 - 7 * k / 3))
  H7.car2.velocity:set(fwd7 * (7 * k / 3))
  H7.frame()
end
H7.car.collisionDepth, H7.car.collidedWith = 0, -1
for _ = 1, 30 do H7.frame() end
H7.settle()
for _ = 1, 40 do H7.frame() end
H7.settle()
local function deepest(buf, ref, front)
  local d, n = 0, 0
  for i = 0, ref.n - 1 do
    local a, b = buf.raw[i].pos, ref.raw[i].pos
    local m = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    if m > 1e-6 then
      d = math.max(d, m)
      if (front and b.z > 1.0) or (not front and b.z < -1.0) then n = n + 1 end
    end
  end
  return d, n
end
local d0, n0 = deepest(H7.bodyMesh.vertices, o0, true)
local d1, n1 = deepest(H7.body2Mesh.vertices, o1, false)
print(('rear-end: watched car front %.3f m (%d at the front), other car %.3f m (%d at the rear), crashes %s and %s'):format(
  d0, n0, d1, n1, tostring(c7[0].crashes), tostring(c7[1].crashes)))
check(d0 > 0.02 and n0 > 0, 'the watched car\'s front dents')
check(d1 > 0.02 and n1 > 0, 'the other car\'s rear dents')
check(d1 > d0 * 0.6 and d1 < d0 / 0.6, 'about as much')
check((c7[0].crashes or 0) == 1 and (c7[1].crashes or 0) == 1, 'once each')
local function glow(m) local e = m.emissive return e and (e.x + e.y + e.z) or 15 end
check(glow(H7.lensMesh) == 0, 'the headlight (in lights.ini) in the dented front: off')
local bl
for _, m in ipairs(c7[0].meshes) do if m.name == 'brake_light_l' then bl = m end end
check(bl and bl.light == 'BRAKE_0', 'a brake light under a BRAKE_ node, in lights.ini: read, a light')
H7.jumps[0](0)
H7.settle()
for _ = 1, 5 do H7.frame() end
check(glow(H7.lensMesh) == 15, 'repaired: back on')
-- the same hit, but its first frame pointing the wrong way (the car still speeding up: +0.8 m/s with the contact),
-- then the hard part: the watched car's front and the other's rear still, not the other ends
local function ends(buf, ref)
  local f, r = 0, 0
  for k = 0, ref.n - 1 do
    local a, b = buf.raw[k].pos, ref.raw[k].pos
    local m = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    if b.z > 1 then f = math.max(f, m) elseif b.z < -1 then r = math.max(r, m) end
  end
  return f, r
end
local function rearEnd(partner)
  H7.jumps[0](0) H7.jumps[1](1)
  H7.car.velocity:set(fwd7 * 12) H7.car2.velocity:set(vec3())
  for _ = 1, 60 do H7.frame() end
  H7.settle()
  for _ = 1, 30 do H7.frame() end
  local a0, a1 = H7.bodyMesh.vertices:copy(), H7.body2Mesh.vertices:copy()
  H7.car.collidedWith = partner and 2 or 0
  H7.car.collisionDepth = 0.05
  H7.car.velocity:set(fwd7 * 12.8) H7.frame()
  for k = 1, 3 do
    H7.car.collisionDepth = 0.05
    H7.car.velocity:set(fwd7 * (12.8 - 8 * k / 3))
    if partner then H7.car2.velocity:set(fwd7 * (6 * k / 3)) end
    H7.frame()
  end
  H7.car.collisionDepth, H7.car.collidedWith = 0, -1
  for _ = 1, 30 do H7.frame() end
  H7.settle() for _ = 1, 40 do H7.frame() end H7.settle()
  local f0, r0 = ends(H7.bodyMesh.vertices, a0)
  local f1, r1 = ends(H7.body2Mesh.vertices, a1)
  return f0, r0, f1, r1
end
local f0, r0, f1, r1 = rearEnd(true)
print(('rear-end, first frame the wrong way: watched front %.3f rear %.3f, other front %.3f rear %.3f'):format(f0, r0, f1, r1))
check(f0 > 0.02 and r0 < 0.002, 'into a car, its first frame the wrong way: the watched car\'s front dents, not its rear')
check(r1 > 0.02 and f1 < 0.002, 'and the other car\'s rear, not its front')
f0, r0 = rearEnd(false)
print(('into a wall, first frame the wrong way: front %.3f rear %.3f'):format(f0, r0))
check(f0 > 0.02 and r0 < 0.01, 'into a wall, its first frame the wrong way: the hard part at the front (the rear at most lightly)')
for _, b in pairs(c7) do check(not b.error, 'no errors: ' .. tostring(b.error)) end
for _, b in pairs(cars) do check(not b.error, 'no errors: ' .. tostring(b.error)) end
print(fails == 0 and 'cars test passed' or ('cars test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
