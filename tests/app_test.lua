-- The app (softdamage.lua) against the scene mock: setup, dents from each source, repair, rebuild.
-- luajit tests/app_test.lua   (from the app folder; ATOMS=box for the box lattice, the hull by default)
package.path = './?.lua;' .. package.path
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local H = require('tests/scene_mock')({n = 20})
H.storage.readWatched = false  -- (on by default; this test presses the button)
H.storage.atoms = os.getenv('ATOMS') or 'hull'
print('atoms: ' .. H.storage.atoms)
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
check(traceText:find('app loaded', 1, true) and traceText:find('mesh %d+/%d+: read'), 'trace written')
local body = H.state.cars[0]
check(body and body.state == 'ready', 'ready: ' .. tostring(body and body.state))
check(body.vertices == orig.n + 3 + H.cardMesh.vertices.n + H.lensMesh.vertices.n and #body.meshes == 4, 'body, panel, interior and the lens outside BODYTR read: ' .. body.vertices)
local partStatus = {}
for _, part in ipairs(body.parts) do partStatus[part.name] = part.status end
check(partStatus.headlight_glass and partStatus.headlight_glass:find('outside BODYTR, body', 1, true), 'the lens: ' .. tostring(partStatus.headlight_glass))
check(partStatus.tyre_lf and partStatus.tyre_lf:find('on a moving part', 1, true), 'the wheel left alone: ' .. tostring(partStatus.tyre_lf))
check(partStatus['DRIVER:suit'] and partStatus['DRIVER:suit']:find('left still', 1, true), 'the driver listed: ' .. tostring(partStatus['DRIVER:suit']))
check(body.skipped == 3, 'driver, needle and steering wheel left still: ' .. tostring(body.skipped))
local card
for _, m in ipairs(body.meshes) do if m.name == 'door_card' then card = m end end
check(card and card.interior, 'the cockpit is interior')
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
-- a front dent: only vertices at the front move, and inward (-z) (smooth: no crunch for these checks)
H.storage.springs = 0
H.storage.crunch = 0
press('front')
local n, d = moved(H.bodyMesh.vertices, orig, function(p) return p.z > 2.2 - 0.6 end)
check(n > 0, 'front dent moves vertices: ' .. n)
check(n ~= -1, 'only at the front')
check(math.abs(d - math.min(H.storage.depth * H.storage.frontGive, H.storage.maxBodyIn)) < 0.02, ('as deep as asked (front give, half a foot at most): %.3f'):format(d))
local inward = true
for i = 0, orig.n - 1 do
  local a, b = H.bodyMesh.vertices.raw[i].pos, orig.raw[i].pos
  if a.z > b.z + 1e-4 then inward = false end  -- (0.1 mm: the hull blends neighbouring triangles)
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
check(H.altered.headlight_glass and H.altered.headlight_glass >= 1, 'the headlight lens (outside BODYTR) dented with the front')

H.storage.crunch = 1
-- crunch: the same dent with crunch is rough (vertices off the smooth dent, normals tilted); harder is rougher
local function snapshot(buf) local c = {} for i = 0, buf.n - 1 do local p, q = buf.raw[i].pos, buf.raw[i].normal c[i] = {p.x, p.y, p.z, q.x, q.y, q.z} end return c end
local function diff(a, b) local d, dn = 0, 0 for i, x in pairs(a) do
  d = math.max(d, math.abs(x[1] - b[i][1]), math.abs(x[2] - b[i][2]), math.abs(x[3] - b[i][3]))
  dn = math.max(dn, math.abs(x[4] - b[i][4]), math.abs(x[5] - b[i][5]), math.abs(x[6] - b[i][6])) end return d, dn end
press('Repair')
H.storage.crunch = 0
press('front')
local smooth = snapshot(H.bodyMesh.vertices)
press('Repair')
H.storage.crunch = 1
press('front')
local rough1 = snapshot(H.bodyMesh.vertices)
local d1, dn1 = diff(smooth, rough1)
check(d1 > 0.002 and d1 <= H.storage.maxCrunch + 1e-6 and dn1 > 0.05, ('crunch: off the smooth dent by up to %.4f m, normals tilted %.3f'):format(d1, dn1))
press('Repair')
check(moved(H.bodyMesh.vertices, orig) == 0, 'repair clears the crunch too')
H.storage.depth = 0.03
press('front')
local light = snapshot(H.bodyMesh.vertices)
press('Repair')
H.storage.crunch = 0
press('front')
local lightSmooth = snapshot(H.bodyMesh.vertices)
local dl = diff(lightSmooth, light)
check(dl < d1 * 0.25, ('a light dent is much less crunchy: %.4f vs %.4f'):format(dl, d1))
press('Repair')
H.storage.depth, H.storage.crunch = 0.12, 1

-- the front gives more than the sides (same test dent, smooth)
H.storage.crunch, H.storage.depth = 0, 0.06
press('front')
local _, frontD = moved(H.bodyMesh.vertices, orig)
press('Repair')
press('left')
local _, sideD = moved(H.bodyMesh.vertices, orig)
press('Repair')
check(frontD > sideD * 2, ('front %.3f m vs side %.3f m'):format(frontD, sideD))
-- limits: a very deep crunchy dent on each side: the body half a foot at most, the interior a quarter, the
-- steering wheel not at all; and the side panel stays outside the door card behind it
local origCard, origSteer = H.cardMesh.vertices:copy(), H.steerMesh.vertices:copy()
H.storage.crunch, H.storage.depth, H.storage.radius = 1, 0.5, 0.9
local worstBody, worstCard, through = 0, 0, false
for _, side in ipairs({'front', 'left', 'back', 'right', 'roof'}) do
  press(side)
  local _, b = moved(H.bodyMesh.vertices, orig)
  local _, c = moved(H.cardMesh.vertices, origCard)
  worstBody, worstCard = math.max(worstBody, b), math.max(worstCard, c)
  if side == 'left' then
    -- the wall (x = 0.9 at rest) in front of the card (y 0.3..0.8, z -0.5..0.5) vs the card's own x
    local wallMin, cardMax = 1e9, -1e9
    for i = 0, orig.n - 1 do
      local o = orig.raw[i].pos
      if o.x > 0.89 and o.y > 0.3 and o.y < 0.8 and o.z > -0.5 and o.z < 0.5 then wallMin = math.min(wallMin, H.bodyMesh.vertices.raw[i].pos.x) end
    end
    for i = 0, origCard.n - 1 do cardMax = math.max(cardMax, H.cardMesh.vertices.raw[i].pos.x) end
    through = wallMin <= cardMax
    check(not through, ('a deep side hit: the panel (x %.3f at the least) stays outside the door card (x %.3f at the most)'):format(wallMin, cardMax))
    check(cardMax < 0.75 - 0.005, 'the door card moved in with it: ' .. cardMax)
  end
  press('Repair')
end
check(worstBody <= H.storage.maxBodyIn + 1e-5, ('the body moved %.4f m at most (limit %.4f)'):format(worstBody, H.storage.maxBodyIn))
check(worstCard <= H.storage.maxInteriorIn + 1e-5 and worstCard > 0.01, ('the interior moved %.4f m at most (limit %.4f)'):format(worstCard, H.storage.maxInteriorIn))
check(moved(H.steerMesh.vertices, origSteer) == 0, 'the steering wheel never moves')
H.storage.depth, H.storage.radius = 0.12, 0.45

-- pushed sideways, the rear quarter gives more than the door (the same push, smooth)
do
  local crunch0, springs0 = H.storage.crunch, H.storage.springs
  H.storage.crunch, H.storage.springs = 0, 0
  local W = H.bodyWorld
  local function sideDent(z)
    press('Repair')
    H.state.dentWorld(body, W:transformPoint(vec3(0.9, 0.6, z)), W:transformVector(vec3(-1, 0, 0)), 0.1, 0.45)
    H.settle()
    local l, most = body.atoms, 0
    for i = 0, l.count - 1 do most = math.max(most, math.sqrt(l.dx[i] ^ 2 + l.dy[i] ^ 2 + l.dz[i] ^ 2)) end
    return most
  end
  local door, quarter = sideDent(0), sideDent(-1.9)
  check(quarter > door * 1.8, ('sideways: the rear quarter gives more than the door (%.3f vs %.3f m)'):format(quarter, door))
  press('Repair')
  H.storage.crunch, H.storage.springs = crunch0, springs0
end

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

-- a part outside BODYTR that turns out to move on the body (its node moves): put back, and not dented again
press('Repair')
H.storage.crunch = 0
local lensBefore = H.lensMesh.vertices:copy()
press('front')
check(moved(H.lensMesh.vertices, lensBefore) > 0, 'the lens dents')
H.lightsNode.world = H.compose(H.bodyWorld, H.rotY(0, 0, 0.2, 0))  -- lifted 20 cm on the body
press('back')
check(moved(H.lensMesh.vertices, lensBefore) == 0, 'a part that moves on the body: put back')
press('front')
check(moved(H.lensMesh.vertices, lensBefore) == 0, 'and not dented again')
H.lightsNode.world = H.bodyWorld
press('Repair')
H.storage.crunch = 1

-- crashes (on by default). The car drives forward (+z in its frame)
H.storage.crunch = 1
check(H.storage.crashDents == true, 'crash dents on by default')
local fwd = H.bodyWorld:transformVector(vec3(0, 0, 1))
-- speeds change like a car's (5 m/s2, half a g), unless a test means a hit
local current = 0
local function drive(speed, frames)
  for _ = 1, frames do
    current = current < speed and math.min(speed, current + 5 / 60) or math.max(speed, current - 5 / 60)
    H.car.velocity:set(fwd * current) H.frame()
  end
end
local function cruise(speed) drive(speed, math.ceil(math.abs(speed - current) * 12) + 40) end
local function hit(to) current = to H.car.velocity:set(fwd * to) H.frame() end
local function crashes() return body.crashes or 0 end
H.car.velocity:set(0, 0, 0) H.frame()
press('Repair')
cruise(15)
-- a wall: 15 m/s to 1 m/s in one frame, and AC reporting no contact at all (missed between frames)
local before = crashes()
hit(1)
drive(1, 30)
H.settle()
n = moved(H.bodyMesh.vertices, orig, function(p) return p.z > 2.2 - 1.2 end)
check(crashes() == before + 1 and n > 0, 'a wall hit without a contact reported: one dent at the front: ' .. n)
check(math.abs(body.lastCrash - 14) < 0.5, 'its speed: ' .. tostring(body.lastCrash))
-- hard braking (0.9 g for 2 s): no dent
cruise(20)
before = crashes()
local v = 20
for _ = 1, 120 do v = math.max(0, v - 9 / 60) H.car.velocity:set(fwd * v) H.frame() end
current = 0
check(crashes() == before, 'hard braking: no dent')
-- a teleport (back to the pits: 50 m away, stopped): no dent
cruise(20)
before = crashes()
local p = H.car.position
H.car.position = vec3(p.x + 50, p.y, p.z) hit(0)
drive(0, 30)
H.car.position = p hit(0)  -- (back where the mock's body is)
drive(0, 30)
check(crashes() == before, 'teleport: no dent')
-- AC's contact report alone (a scrape at low speed, 2 m/s lost): under 2.5 m/s, no dent
cruise(5)
before = crashes()
H.car.collisionDepth = 0.05 hit(3) H.car.collisionDepth = 0
drive(3, 20)
check(crashes() == before, 'a light scrape: no dent')
-- harder hits: deeper and crunchier
local function hitAt(speed)
  cruise(speed)
  press('Repair')
  hit(0)
  drive(0, 30)
  H.settle()
  local l, maxOff, maxCr = body.atoms, 0, 0
  for i = 0, l.count - 1 do
    maxOff = math.max(maxOff, math.sqrt(l.dx[i] ^ 2 + l.dy[i] ^ 2 + l.dz[i] ^ 2))
    maxCr = math.max(maxCr, l.cr[i])
  end
  return maxOff, maxCr
end
-- where a hit lands, from how the car's spin changes: a small rigid-body model. An impulse at r (from the body's
-- middle) changes the velocity by dv and the spin by (r x dv) / k^2; the car's axes then turn with the spin
local W = H.bodyWorld
local k2 = (4.5 ^ 2 + 1.9 ^ 2) / 12
local function crossv(a, b) return vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function rotate(v, w, dt)
  local wl = w:length()
  if wl < 1e-9 then return v end
  local a, t = vec3(w.x / wl, w.y / wl, w.z / wl), wl * dt
  local c, s = math.cos(t), math.sin(t)
  return v * c + crossv(a, v) * s + a * (a:dot(v) * (1 - c))
end
local function strike(rLocal, dvLocal, frames)
  local r, dv = W:transformVector(rLocal), W:transformVector(dvLocal)
  local w = crossv(r, dv) * (1 / k2)
  H.car.velocity:set(H.car.velocity + dv) current = nil
  for _ = 1, frames or 30 do
    H.car.look:set(rotate(H.car.look, w, 1 / 60))
    H.car.up:set(rotate(H.car.up, w, 1 / 60))
    H.frame()
  end
  H.settle()
end
-- the dent's middle (weighted by how far each vertex moved), in the body's frame
local function dentMiddle()
  local sx, sz, sw = 0, 0, 0
  for i = 0, orig.n - 1 do
    local a, b = H.bodyMesh.vertices.raw[i].pos, orig.raw[i].pos
    local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
    sx, sz, sw = sx + b.x * d, sz + b.z * d, sw + d
  end
  return sw > 0 and sx / sw or nil, sw > 0 and sz / sw or nil
end
local function reset()
  -- crash dents off while the car is put back (a speed dropped to 0 in a frame would be a crash)
  H.storage.crashDents = false
  H.car.velocity:set(0, 0, 0) H.car.look:set(W:transformVector(vec3(0, 0, 1))) H.car.up:set(W:transformVector(vec3(0, 1, 0)))
  current = 0
  for _ = 1, 5 do H.frame() end
  H.storage.crashDents = true
  for _ = 1, 30 do H.frame() end
  press('Repair')
end
H.storage.crunch = 1
-- drifting, the tail hits a wall on the right (-x): pushed left (+x) at the rear right corner
reset()
local n0 = crashes()
strike(vec3(-0.85, 0, -2.0), vec3(3, 0, 0))
local mx_, mz_ = dentMiddle()
check(crashes() == n0 + 1 and mz_ and mz_ < -1.2 and mx_ < 0, ('tail into a wall: dented at the rear right (x %.2f, z %.2f)'):format(mx_ or 0, mz_ or 0))
-- the front left quarter: pushed right (-x) near the front
reset()
strike(vec3(0.85, 0, 1.8), vec3(-3, 0, 0))
mx_, mz_ = dentMiddle()
check(mz_ and mz_ > 1.0 and mx_ > 0, ('front quarter: dented at the front left (x %.2f, z %.2f)'):format(mx_ or 0, mz_ or 0))
-- the middle of the side: the doors
reset()
strike(vec3(0.85, 0, 0), vec3(-5, 0, 0))
mx_, mz_ = dentMiddle()
check(mz_ and math.abs(mz_) < 0.6 and mx_ > 0, ('middle of the side: the doors (x %.2f, z %.2f)'):format(mx_ or 0, mz_ or 0))
-- a jump landing: pushed up 6 m/s from below: no dent
reset()
n0 = crashes()
strike(vec3(0, -0.6, 0), vec3(0, 6, 0))
check(crashes() == n0, 'a landing: no dent')
reset()

local o1, c1 = hitAt(5)
local o2, c2 = hitAt(12)
check(o2 > o1 * 1.5 and c2 > c1 * 1.5 and c2 <= H.storage.maxCrunch + 1e-9, ('harder hit (crunch capped at maxCrunch): deeper (%.3f vs %.3f) and crunchier (%.4f vs %.4f)'):format(o2, o1, c2, c1))
press('Repair')

-- the 'copy' way: the first dent makes a copy (same node, same material), hides the original, leaves its
-- vertices alone; the copy takes the dents
press('Repair')
H.storage.method = 'copy'
H.storage.crashDents = false
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
for i, b in pairs(H.state.cars) do check(not b.error, 'no errors in the background work: ' .. tostring(b.error)) end
check(not body.error, 'no errors in the first body either: ' .. tostring(body.error))
for _, l in ipairs(H.logs) do print(l) end
print(fails == 0 and 'app test passed' or ('app test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
