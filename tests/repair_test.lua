-- Repairing slowly: held on a bindable button, the damage goes back smoothly; each step is told to other apps,
-- and one (Carmapeds) can stop it. luajit tests/repair_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local H = require('tests/scene_mock')({n = 30, replacementWheel = true})
H.storage.atoms = os.getenv('ATOMS') or 'hull'
local orig, origWheel = H.bodyMesh.vertices:copy(), H.replWheel.vertices:copy()
local function deepest(buf, ref)
  local most = 0
  for i = 0, ref.n - 1 do
    local a, b = buf.raw[i].pos, ref.raw[i].pos
    most = math.max(most, math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2))
  end
  return most
end
H.load()
H.settle()
for _ = 1, 5 do H.frame() end
H.settle()
local body = H.state.cars[0]
local W = H.bodyWorld
-- a deep hit at the front left: the body dented, the front left wheel bent
H.state.dentWorld(body, W:transformPoint(vec3(0.9, 0.5, 1.4)), W:transformVector(vec3(-1, 0, 0)), 0.4, 0.6)
H.state.dentWorld(body, W:transformPoint(vec3(0, 0.6, 2.2)), W:transformVector(vec3(0, 0, -1)), 0.3, 0.6)
H.settle()
local d0, w0 = deepest(H.bodyMesh.vertices, orig), deepest(H.replWheel.vertices, origWheel)
check(d0 > 0.1 and w0 > 0.001, ('damaged: body %.3f m, wheel bent %.4f m'):format(d0, w0))
local BUTTON = '__APP_SOFTDAMAGE_REPAIR_SLOWLY'
-- blocked (no credits, says Carmapeds): holding does nothing
H.state.broadcast = nil
local ac_ = ac
ac_.broadcastSharedEvent('softdamage.repairBlocked', {car = 0, blocked = true})
H.controls[BUTTON] = true
for _ = 1, 30 do H.frame() end
check(math.abs(deepest(H.bodyMesh.vertices, orig) - d0) < 1e-9, 'blocked: nothing repaired')
ac_.broadcastSharedEvent('softdamage.repairBlocked', {car = 0, blocked = false})
-- held: a little each frame, never back, the wheel straightening too; the steps told to other apps
local depths, sentBefore = {}, #H.shared
local smooth = true
for f = 1, 20 do
  H.frame()
  depths[f] = deepest(H.bodyMesh.vertices, orig)
  if f > 1 and (depths[f] > depths[f - 1] + 1e-9) then smooth = false end
end
check(depths[1] < d0 and depths[20] < d0 * 0.9 and depths[20] > 0, ('a step at a time: %.3f, then %.3f after 20 frames (from %.3f)'):format(depths[1], depths[20], d0))
check(smooth, 'never back')
check(deepest(H.replWheel.vertices, origWheel) < w0, 'the wheel straightening')
local repaired, reports = 0, 0
for k = sentBefore + 1, #H.shared do
  local e = H.shared[k]
  if e.key == 'softdamage.repair' and e.data.car == 0 then repaired, reports = repaired + e.data.repaired, reports + 1 end
end
check(reports == 20 and repaired > 0, ('each step told: %d reports, %.1f%% repaired'):format(reports, repaired))
-- let go: it stops where it is
H.controls[BUTTON] = nil
local held = deepest(H.bodyMesh.vertices, orig)
for _ = 1, 10 do H.frame() end
check(math.abs(deepest(H.bodyMesh.vertices, orig) - held) < 1e-9, 'let go: it stays as it is')
-- held to the end: back exactly, wheel straight, the reports adding up to what the damage was
H.controls[BUTTON] = true
for _ = 1, 600 do H.frame() end
H.controls[BUTTON] = nil
H.settle()
check(deepest(H.bodyMesh.vertices, orig) == 0 and deepest(H.replWheel.vertices, origWheel) == 0, 'all repaired, exactly')
check(body.dents == 0, 'no dents left')
local total, last = 0, nil
for _, e in ipairs(H.shared) do if e.key == 'softdamage.repair' then total = total + e.data.repaired last = e.data end end
check(last and last.damage == 0, 'the last report: no damage left')
-- dents after a repair start from the repaired car
H.state.dentWorld(body, W:transformPoint(vec3(0, 0.6, 2.2)), W:transformVector(vec3(0, 0, -1)), 0.1, 0.6)
H.settle()
check(deepest(H.bodyMesh.vertices, orig) > 0.03, 'a new dent after it')
print(fails == 0 and 'repair test passed' or ('repair test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
