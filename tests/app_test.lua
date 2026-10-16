-- The app (softdamage.lua) against the scene mock: setup, dents from each source, repair, rebuild.
-- luajit tests/app_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local H = require('tests/scene_mock')({n = 20})
local orig = H.bodyMesh.vertices:clone()
local origDoor = H.doorMesh.vertices:clone()
H.load()
for _ = 1, 30 do H.frame() end
check(H.reads == 0 and H.state.cars[0] == nil, 'nothing read before the button')
H.buttons['Read this car'] = true H.frame() H.buttons['Read this car'] = nil
check(H.settle(), 'setup finishes')
local f = io.open((os.getenv('TMPDIR') or '/tmp') .. '/softdamage_trace.txt')
local traceText = f and f:read('*a') or ''
if f then f:close() end
check(traceText:find('app loaded', 1, true) and traceText:find('mesh 4/4: read', 1, true), 'trace written')
local body = H.state.cars[0]
check(body and body.state == 'ready', 'ready: ' .. tostring(body and body.state))
check(body.vertices == orig.n + 3 and #body.meshes == 2, 'both body meshes read: ' .. body.vertices)
check(body.skipped == 2, 'driver and needle skipped: ' .. tostring(body.skipped))
check(body.forward == 1 and body.left == 1, 'forward +z, left +x (from the wheels)')
-- the panel's vertices in body space: through its rotated node
local door
for _, m in ipairs(body.meshes) do if m.name == 'door' then door = m end end
local expect = H.doorLocal:transformPoint(vec3(0.1, 0, 0))
check(math.abs(door.px[2] - expect.x) < 1e-5 and math.abs(door.pz[2] - expect.z) < 1e-5, 'panel vertex in body space')
-- min/max of the body box
check(math.abs(body.min[3] - (-2.25)) < 1e-6 and math.abs(body.max[3] - 2.25) < 1e-6, 'bounds')

local function moved(buf, ref, filter)
  local n, maxd = 0, 0
  for i = 0, ref.n - 1 do
    local a, b = buf.raw[i].pos, ref.raw[i].pos
    local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    if d > 1e-9 then
      if filter and not filter(b) then return -1, 0 end
      n, maxd = n + 1, math.max(maxd, d)
    end
  end
  return n, maxd
end
local function press(label) H.buttons[label] = true H.frame() H.buttons[label] = nil H.settle() end

-- the car's own meshes changed (the 'direct' way) for the checks below; the 'copy' way after them
H.storage.method = 'direct'
-- a front dent: only vertices at the front move, and inward (-z)
H.storage.springs = 0
press('front')
local n, d = moved(H.bodyMesh.vertices, orig, function(p) return p.z > 2.2 - 0.6 end)
check(n > 0, 'front dent moves vertices: ' .. n)
check(n ~= -1, 'only at the front')
check(math.abs(d - H.storage.depth) < 0.02, ('as deep as asked: %.3f'):format(d))
local inward = true
for i = 0, orig.n - 1 do
  local a, b = H.bodyMesh.vertices.raw[i].pos, orig.raw[i].pos
  if math.abs(a.z - b.z) > 1e-9 and a.z > b.z then inward = false end
end
check(inward, 'pushed in (-z)')
-- normals bent beside the dent on the front face (a vertex on z = 2.2 off-centre)
local bent = false
for i = 0, orig.n - 1 do
  local nn, on = H.bodyMesh.vertices.raw[i].normal, orig.raw[i].normal
  if on.z > 0.99 and (math.abs(nn.x - on.x) > 1e-3 or math.abs(nn.y - on.y) > 1e-3) then bent = true end
end
check(bent, 'normals bent')
check(H.altered.body and H.altered.body >= 1, 'body mesh sent')

-- left: the +x side
press('Repair')
check(moved(H.bodyMesh.vertices, orig) == 0, 'repair: back exactly')
press('left')
n = moved(H.bodyMesh.vertices, orig, function(p) return p.x > 0.9 - 0.6 end)
check(n > 0, 'left dent on the +x side: ' .. n)

-- Ctrl + click
press('Repair')
local dents = body.dents
H.mouseRay = {pos = H.bodyWorld:transformPoint(vec3(0, 0.6, -6)), dir = H.bodyWorld:transformVector(vec3(0, 0, 1)), length = 50}
H.keys[0x11], H.keys[0x01] = true, true
H.frame()
H.keys[0x11], H.keys[0x01] = nil, nil
H.settle()
n = moved(H.bodyMesh.vertices, orig, function(p) return p.z < -2.2 + 0.6 end)
check(body.dents == dents + 1 and n > 0, 'Ctrl+click: a dent at the back: ' .. n)
-- a reset (AC's jump callback) repairs
H.jumps[0](0)
H.settle()
check(moved(H.bodyMesh.vertices, orig) == 0, 'reset repairs')

-- a crash: the car stopped from 15 m/s by something in front
H.storage.crashes = true
local fwd = H.bodyWorld:transformVector(vec3(0, 0, 1))
H.car.velocity:set(fwd * 15) H.frame()
H.car.collisionDepth = 0.1
H.car.velocity:set(fwd * 1) for _ = 1, 12 do H.frame() end
H.car.collisionDepth = 0
H.settle()
n = moved(H.bodyMesh.vertices, orig, function(p) return p.z > 2.2 - 1.2 end)
check(body.lastCrash and body.lastCrash > 13 and n > 0, 'crash: a dent at the front: ' .. n .. ' ' .. tostring(body.lastCrash))

-- the 'copy' way: the first dent makes a copy (same node, same material), hides the original, leaves its
-- vertices alone; the copy takes the dents
press('Repair')
H.storage.method = 'copy'
H.storage.crashes = false
local altered = H.altered.body or 0
press('front')
local copy = H.created[#H.created]
check(copy and copy.name == 'softdamage_body' and copy.parent == H.bodyMesh.parent and copy.material == 'body', 'copy made under the same node with the material')
check(H.state.cars[0] and true, 'still running')
check(H.bodyMesh.hidden and not copy.hidden, 'original hidden, copy shown')
check((H.altered.body or 0) == altered and moved(H.bodyMesh.vertices, orig) == 0, 'the original mesh untouched')
n = moved(copy.vertices, orig, function(p) return p.z > 2.2 - 0.6 end)
check(n > 0, 'the copy dented at the front: ' .. n)
press('back')
n = moved(copy.vertices, orig)
check(#H.created == 1 and n > 0, 'later dents go to the same copy')
press('Repair')
check(moved(copy.vertices, orig) == 0, 'repair: the copy back to the original shape')
-- unloading puts the originals back
H.release()
check(copy.disposed and not H.bodyMesh.hidden, 'unload: copy removed, original shown')
H.storage.method = 'direct'
-- tests A, B, C
H.buttons['A: track mesh'] = true H.frame() H.buttons['A: track mesh'] = nil
H.buttons['B: car mesh'] = true H.frame() H.buttons['B: car mesh'] = nil
H.buttons['C: car mesh copy'] = true H.frame() H.buttons['C: car mesh copy'] = nil
local testCopy = H.created[#H.created]
check(H.altered.road == 1 and H.altered.door and testCopy.name == 'softdamage_test' and H.doorMesh.hidden, 'tests A, B, C ran')
check(math.abs(testCopy.vertices.raw[0].pos.y - H.doorMesh.vertices.raw[0].pos.y - 0.05) < 1e-5, 'test C: the copy lifted 5 cm')
H.buttons['Undo C'] = true H.frame() H.buttons['Undo C'] = nil
check(testCopy.disposed and not H.doorMesh.hidden, 'undo C')
local doorAltered = H.altered.door
H.buttons['D: change a car mesh'] = true H.frame() H.buttons['D: change a car mesh'] = nil
check(H.altered.door == doorAltered + 1 and math.abs(H.doorMesh.vertices.raw[0].pos.y - origDoor.raw[0].pos.y - 0.05) < 1e-5, 'test D: lifted')
H.buttons['E: same, in a coroutine'] = true H.frame() H.buttons['E: same, in a coroutine'] = nil
check(H.altered.door == doorAltered + 2, 'test E: sent from a coroutine')
H.buttons['Undo D/E'] = true H.frame() H.buttons['Undo D/E'] = nil
check(moved(H.doorMesh.vertices, origDoor) == 0, 'undo D/E')

-- rebuild: reads the undamaged model again
H.buttons['Rebuild (re-read the car)'] = true H.frame() H.buttons['Rebuild (re-read the car)'] = nil
H.settle()
local body2 = H.state.cars[0]
check(body2 ~= body and body2.state == 'ready', 'rebuilt')
check(moved(H.bodyMesh.vertices, orig) == 0 and moved(H.doorMesh.vertices, origDoor) == 0, 'rebuild starts from the undamaged model')
local same = true
for _, m in ipairs(body2.meshes) do if m.name == 'body' then for i = 0, m.n - 1 do
  if math.abs(m.orig.raw[i].pos.z - orig.raw[i].pos.z) > 1e-9 then same = false end end end end
check(same, 'rebuild keeps the original vertices')
for _, l in ipairs(H.logs) do print(l) end
print(fails == 0 and 'app test passed' or ('app test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
