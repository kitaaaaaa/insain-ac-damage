-- A hard head-on crash that pitches the car (as real ones do, nose diving): the dent goes into the front, not up
-- the bonnet into the windscreen. luajit tests/crash_test.lua <pitch rad/s>   (from the app folder)
local pitchRate = tonumber(arg[1] or '3')  -- rad/s of nose-down pitch the hit gives
local H = require('tests/scene_mock')({n = 30})
H.storage.atoms = os.getenv('ATOMS') or 'hull'
H.storage.bendTime = 0
local orig = H.bodyMesh.vertices:copy()
H.load() H.settle() for _ = 1, 5 do H.frame() end H.settle()
local W = H.bodyWorld
local fwd = W:transformVector(vec3(0, 0, 1))
local v = 0
while v < 25 do v = v + 5 / 60 H.car.velocity:set(fwd * v) H.frame() end
for _ = 1, 20 do H.frame() end
-- the wall: stopped, and pitching nose down (about the car's side axis)
local side = W:transformVector(vec3(1, 0, 0))
local function rot(u, axis, t)
  local c, s = math.cos(t), math.sin(t)
  local cx, cy, cz = axis.y * u.z - axis.z * u.y, axis.z * u.x - axis.x * u.z, axis.x * u.y - axis.y * u.x
  local d = axis.x * u.x + axis.y * u.y + axis.z * u.z
  return vec3(u.x * c + cx * s + axis.x * d * (1 - c), u.y * c + cy * s + axis.y * d * (1 - c), u.z * c + cz * s + axis.z * d * (1 - c))
end
H.car.velocity:set(fwd * 0.5)
for _ = 1, 12 do
  H.car.look:set(rot(H.car.look, side, pitchRate / 60))
  H.car.up:set(rot(H.car.up, side, pitchRate / 60))
  H.frame()
end
H.car.look:set(fwd) H.car.up:set(vec3(0, 1, 0))
for _ = 1, 30 do H.frame() end
H.settle()
local front, upper, roof = 0, 0, 0
for i = 0, orig.n - 1 do
  local a, b = H.bodyMesh.vertices.raw[i].pos, orig.raw[i].pos
  local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
  if b.z > 2.19 and b.y < 0.7 then front = math.max(front, d) end  -- the bumper: low on the front face
  if b.y > 1.19 and b.z < 1.6 then roof = math.max(roof, d) end    -- the top, back from the front (cowl, screen)
end
local ok = front > 0.4 and roof < front * 0.15
print((ok and "crash test passed: " or "FAIL: ") .. ("pitch %g rad/s: the bumper moved %.2f m, the top behind the front %.2f m"):format(pitchRate, front, roof))
os.exit(ok and 0 or 1)
