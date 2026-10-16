-- Model cars (everything scaled to the car), and wheels CSP puts in from an extension's model.
-- luajit tests/small_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local function moved(buf, ref)
  local n, most = 0, 0
  for i = 0, ref.n - 1 do
    local a, b = buf.raw[i].pos, ref.raw[i].pos
    local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    if d > 1e-9 then n, most = n + 1, math.max(most, d) end
  end
  return n, most
end
local function finite(buf)
  for i = 0, buf.n - 1 do
    local p, q = buf.raw[i].pos, buf.raw[i].normal
    for _, x in ipairs({p.x, p.y, p.z, q.x, q.y, q.z}) do if x ~= x or math.abs(x) > 1e4 then return false end end
  end
  return true
end

-- a model car: 0.53 m long, tyres 4 cm round (12% of the test car)
do
  local H = require('tests/scene_mock')({n = 20, size = 0.12})
  H.storage.atoms = os.getenv('ATOMS') or 'hull'
  local orig = H.bodyMesh.vertices:copy()
  H.load()
  H.settle()
  for _ = 1, 5 do H.frame() end
  H.settle()
  local body = H.state.cars[0]
  check(body and body.state == 'ready', 'a model car read: ' .. tostring(body and body.state))
  check(math.abs(body.scale - (4.4 * 0.12 + 0.1 * body.scale) / 4.5) < 0.01, ('its scale: %.3f'):format(body.scale))
  check(math.abs(body.wheels[1][6] - 0.33 * 0.12) < 1e-6, ('its tyres from AC, %.3f m round, not a default'):format(body.wheels[1][6]))
  check(body.atoms.count > 100 and body.atoms.count < 2000, 'a hull of the usual fineness for its size: ' .. body.atoms.count .. ' atoms')
  -- a test dent: as deep, for its size, as on a real car (no springs or crunch, as in the app test)
  H.storage.crunch, H.storage.springs = 0, 0
  H.buttons['front'] = true H.frame() H.buttons['front'] = nil H.settle()
  local n, most = moved(H.bodyMesh.vertices, orig)
  local asked = H.storage.depth * body.scale * H.storage.frontGive
  check(n > 0 and most > asked * 0.6 and most < asked * 1.1, ('a front dent %.4f m deep (asked %.4f)'):format(most, asked))
  -- a hard crash: a dent its size, nothing not finite
  H.buttons['Repair'] = true H.frame() H.buttons['Repair'] = nil H.settle()
  H.storage.crunch, H.storage.springs = 1, 2
  local fwd = H.bodyWorld:transformVector(vec3(0, 0, 1))
  local v = 0
  while v < 20 do v = v + 5 / 60 H.car.velocity:set(fwd * v) H.frame() end
  for _ = 1, 20 do H.frame() end
  H.car.velocity:set(fwd * 0.5)
  for _ = 1, 60 do H.frame() end
  H.settle()
  n, most = moved(H.bodyMesh.vertices, orig)
  check((body.crashes or 0) >= 1 and n > 0, 'a crash dents it: ' .. tostring(body.crashes))
  check(most < 0.53 * 0.6, ('no more than its size allows: %.3f m on a 0.53 m car'):format(most))
  check(finite(H.bodyMesh.vertices), 'every vertex finite')
  check(not body.error, 'no errors: ' .. tostring(body.error))
end

-- a wheel from an extension's model, under BODYTR, with its own name: a wheel, not bodywork; bent by a hard hit
-- beside it (a rigid tilt: it wobbles as it turns), straightened by a repair
do
  local H = require('tests/scene_mock')({n = 20, replacementWheel = true})
  H.storage.atoms = os.getenv('ATOMS') or 'hull'
  local origWheel = H.replWheel.vertices:copy()
  H.load()
  H.settle()
  for _ = 1, 5 do H.frame() end
  H.settle()
  local body = H.state.cars[0]
  local status
  for _, part in ipairs(body.parts) do if part.name == 'ext_wheel_fl_model' then status = part.status end end
  check(status and status:find('wheel 1', 1, true), 'the extension wheel is a wheel: ' .. tostring(status))
  local inBody = false
  for _, m in ipairs(body.meshes) do if m.name == 'ext_wheel_fl_model' then inBody = true end end
  check(not inBody, 'not bodywork')
  -- a light knock beside it: the wheel stays true
  H.storage.crunch = 0
  local W = H.bodyWorld
  H.state.dentWorld(body, W:transformPoint(vec3(0.9, 0.5, 1.4)), W:transformVector(vec3(-1, 0, 0)), 0.03, 0.3)
  H.settle()
  check(moved(H.replWheel.vertices, origWheel) == 0, 'a light knock: the wheel untouched')
  -- a hard hit beside it: tilted, rigidly (every distance in it kept)
  H.state.dentWorld(body, W:transformPoint(vec3(0.9, 0.5, 1.4)), W:transformVector(vec3(-1, 0, 0)), 0.4, 0.5)
  H.settle()
  local n = moved(H.replWheel.vertices, origWheel)
  local worst = 0
  local b, o = H.replWheel.vertices.raw, origWheel.raw
  for i = 0, origWheel.n - 1, 5 do for j = 1, origWheel.n - 1, 7 do
    local d1 = math.sqrt((b[i].pos.x - b[j].pos.x) ^ 2 + (b[i].pos.y - b[j].pos.y) ^ 2 + (b[i].pos.z - b[j].pos.z) ^ 2)
    local d0 = math.sqrt((o[i].pos.x - o[j].pos.x) ^ 2 + (o[i].pos.y - o[j].pos.y) ^ 2 + (o[i].pos.z - o[j].pos.z) ^ 2)
    worst = math.max(worst, math.abs(d1 - d0))
  end end
  check(n > 0 and (body.bentWheels or 0) > 0, 'a hard hit beside it bends it: ' .. n .. ' vertices')
  check(worst < 1e-5, ('bent, not crushed (distances kept to %.6f m)'):format(worst))
  H.buttons['Repair'] = true H.frame() H.buttons['Repair'] = nil H.settle()
  check(moved(H.replWheel.vertices, origWheel) == 0, 'a repair straightens it')
  check(not body.error, 'no errors: ' .. tostring(body.error))
end
print(fails == 0 and 'small test passed' or ('small test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
