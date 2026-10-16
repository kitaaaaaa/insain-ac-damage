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
-- repaired (to the pits) and far: let go
H.jumps[1](1)
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
for _, b in pairs(cars) do check(not b.error, 'no errors: ' .. tostring(b.error)) end
print(fails == 0 and 'cars test passed' or ('cars test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
