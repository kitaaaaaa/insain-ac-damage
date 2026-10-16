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
for _, b in pairs(cars) do check(not b.error, 'no errors: ' .. tostring(b.error)) end
print(fails == 0 and 'cars test passed' or ('cars test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
