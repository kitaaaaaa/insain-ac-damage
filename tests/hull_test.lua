-- The hull (src/hull.lua): built around a car-like shape, vertices pinned and following the atoms.
-- luajit tests/hull_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local hull = require('src/hull')
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end

-- a car-ish body: a lower box (4.4 x 1.8 x 0.7) and a narrower cabin on top (2 x 1.4 x 0.5), points on their
-- surfaces with outward normals
local mesh = {px = {}, py = {}, pz = {}, nx = {}, ny = {}, nz = {}, n = 0}
local function add(x, y, z, nx, ny, nz)
  local n = mesh.n
  mesh.px[n], mesh.py[n], mesh.pz[n], mesh.nx[n], mesh.ny[n], mesh.nz[n] = x, y, z, nx, ny, nz
  mesh.n = n + 1
end
local function box(x0, x1, y0, y1, z0, z1, steps)
  for a = 0, steps do for b = 0, steps do
    local u, v = a / steps, b / steps
    add(x0, y0 + (y1 - y0) * u, z0 + (z1 - z0) * v, -1, 0, 0) add(x1, y0 + (y1 - y0) * u, z0 + (z1 - z0) * v, 1, 0, 0)
    add(x0 + (x1 - x0) * u, y0, z0 + (z1 - z0) * v, 0, -1, 0) add(x0 + (x1 - x0) * u, y1, z0 + (z1 - z0) * v, 0, 1, 0)
    add(x0 + (x1 - x0) * u, y0 + (y1 - y0) * v, z0, 0, 0, -1) add(x0 + (x1 - x0) * u, y0 + (y1 - y0) * v, z1, 0, 0, 1)
  end end
end
box(-0.9, 0.9, 0.2, 0.9, -2.2, 2.2, 24)
box(-0.7, 0.7, 0.9, 1.4, -1.0, 1.0, 16)
local min, max = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
for v = 0, mesh.n - 1 do
  local p = {mesh.px[v], mesh.py[v], mesh.pz[v]}
  for a = 1, 3 do min[a], max[a] = math.min(min[a], p[a]), math.max(max[a], p[a]) end
end
local A = 20
local h = hull.new({mesh}, min, max, 0.3, A)
check(h.rings == 16 and h.count == (h.rings + h.caps[1].rings + h.caps[2].rings) * A + 2 and h.caps[1].rings >= 2,
  ('atoms: %d rings of 20, %d and %d more in the end caps and their middles: %d'):format(h.rings, h.caps[1].rings, h.caps[2].rings, h.count))
-- the caps follow the ends: the front cap's atoms just in front of the body's front (z -2.2)
local capZ = 0
for n = h.caps[1].first, h.caps[1].middle do capZ = math.max(capZ, math.abs(h.az[n] - (-2.21))) end
check(capZ < 1e-6, ('the front cap sits just in front of the body: off by %.3f'):format(capZ))
-- the hull's shape follows the car: rings at the cabin are taller than at the bonnet
local function ringTop(k) local t = -1e9 for s = 0, A - 1 do t = math.max(t, h.ay[k * A + s]) end return t end
check(ringTop(7) > 1.39 and ringTop(7) < 1.5 and ringTop(1) > 0.89 and ringTop(1) < 0.97, ('car-shaped: cabin ring top %.2f, bonnet ring top %.2f'):format(ringTop(7), ringTop(1)))
local b = hull.newBindings(mesh.n)
for v = 0, mesh.n - 1 do hull.bind(h, b, v, mesh.px[v], mesh.py[v], mesh.pz[v], mesh.nx[v], mesh.ny[v], mesh.nz[v]) end
-- each binding puts its vertex back where it is (1nsane's formula), and vertices sit within their nearest triangle
local worst, outside = 0, 0
for v = 0, mesh.n - 1 do
  for j = 0, hull.SLOTS - 1 do
    local k = v * hull.SLOTS + j
    local t = b.bt[k]
    if t >= 0 then
      local a, bb, c = h.ta[t], h.tb[t], h.tc[t]
      local u, w, hh = b.bu[k], b.bv[k], b.bh[k]
            local x = h.ax[a] + u * (h.ax[bb] - h.ax[a]) + w * (h.ax[c] - h.ax[a]) + hh * h.rcx[t]
      local y = h.ay[a] + u * (h.ay[bb] - h.ay[a]) + w * (h.ay[c] - h.ay[a]) + hh * h.rcy[t]
      local z = h.az[a] + u * (h.az[bb] - h.az[a]) + w * (h.az[c] - h.az[a]) + hh * h.rcz[t]
      worst = math.max(worst, math.abs(x - mesh.px[v]), math.abs(y - mesh.py[v]), math.abs(z - mesh.pz[v]))
      if j == 0 and (u < -1 or w < -1 or u + w > 2) then outside = outside + 1 end
    end
  end
end
check(worst < 1e-6, ('bindings rebuild their vertices (stored as floats): off by %.2g m'):format(worst))
check(outside == 0, 'vertices pinned near their triangles (in concave spots, a little off its edges): ' .. outside .. ' far off')
-- at rest nothing moves
local any = false
for v = 0, mesh.n - 1 do if hull.sample(h, b, v) then any = true end end
check(not any, 'at rest, no vertex moves')
-- the whole hull moved rigidly (turned 20 degrees about y and shifted): every vertex moves with it exactly
local ang = math.rad(20)
local c, s = math.cos(ang), math.sin(ang)
for n = 0, h.count - 1 do
  local x, y, z = h.ax[n], h.ay[n], h.az[n]
  h.dx[n], h.dy[n], h.dz[n], h.on[n] = c * x + s * z + 0.3 - x, y - 0.1 - y, -s * x + c * z + 0.5 - z, 1
end
hull.begin(h)
local worstP, worstN = 0, 0
for v = 0, mesh.n - 1 do
  local ox, oy, oz, qx, qy, qz = hull.sample(h, b, v)
  local x, y, z = mesh.px[v], mesh.py[v], mesh.pz[v]
  local ex, ey, ez = c * x + s * z + 0.3, y - 0.1, -s * x + c * z + 0.5
  worstP = math.max(worstP, math.abs(x + ox - ex), math.abs(y + oy - ey), math.abs(z + oz - ez))
  local nx, ny, nz = mesh.nx[v], mesh.ny[v], mesh.nz[v]
  worstN = math.max(worstN, math.abs(qx - (c * nx + s * nz)), math.abs(qy - ny), math.abs(qz - (-s * nx + c * nz)))
end
check(worstP < 1e-6 and worstN < 1e-6, ('rigid move: positions off by %.2g, normals by %.2g'):format(worstP, worstN))
-- a dent on the left (+x) side in the middle: only atoms on that side move, and the vertices there go in
hull.reset(h) hull.takeChanged(h)
local moved = hull.dent(h, 0.9, 0.55, 0, -1, 0, 0, 0.1, 0.45, 0.5, 0, 0.35, 0, 0.06)
check(moved > 0, 'the dent moves atoms: ' .. moved)
local wrong = 0
for n = 0, h.count - 1 do if h.on[n] == 1 and (h.ax[n] < 0.5 or math.abs(h.az[n]) > 0.8) then wrong = wrong + 1 end end
check(wrong == 0, 'only atoms on the left middle: ' .. wrong .. ' elsewhere')
local tris = hull.takeChanged(h)
local nt = 0 for _ in pairs(tris) do nt = nt + 1 end
check(nt > 0 and nt < h.tris / 4, 'triangles to redo: ' .. nt)
hull.begin(h)
local deepest, far, outward, most = 0, 0, 0, 0
for v = 0, mesh.n - 1 do
  local ox, oy, oz = hull.sample(h, b, v)
  if ox then
    if mesh.px[v] > 0.85 and math.abs(mesh.pz[v]) < 0.3 and math.abs(mesh.py[v] - 0.55) < 0.2 then deepest = math.max(deepest, -ox) end
    if mesh.px[v] < 0 and math.abs(ox) + math.abs(oy) + math.abs(oz) > 1e-4 then far = far + 1 end
    if mesh.px[v] > 0.85 and ox > 0.002 then outward = outward + 1 end
    most = math.max(most, math.sqrt(ox * ox + oy * oy + oz * oz))
  end
end
check(deepest > 0.05, ('the side goes in: %.3f m'):format(deepest))
check(far == 0, 'the other side stays: ' .. far .. ' moved')
check(outward == 0, 'nothing on the dented side goes out (over 2 mm): ' .. outward)
check(most <= 0.1 * 1.1, ('no vertex moves much more than the dent (0.1 m): %.3f m'):format(most))
-- a dent between atoms still moves the nearest
hull.reset(h)
check(hull.dent(h, 0.9, 0.55, 0.15, -1, 0, 0, 0.1, 0.01, 0.5, 0) > 0, 'a tiny dent moves the nearest atom')
-- springs spread a dent along the hull's edges
hull.reset(h)
local n0 = hull.dent(h, 0.9, 0.55, 0, -1, 0, 0, 0.1, 0.45, 0.5, 0)
hull.reset(h)
local n2 = hull.dent(h, 0.9, 0.55, 0, -1, 0, 0, 0.1, 0.45, 0.5, 2, 0.35)
check(n2 > n0, ('springs spread it: %d atoms vs %d'):format(n2, n0))
-- spring limits (1nsane's): a deep, narrow push; without limits it pokes a spike, with them no edge stretches
-- past 1.05 or squashes past 0.5, the middle stays as deep, and it drags more of the metal in
local function edgeRange()
  local lo, hi = 1e9, 0
  for e = 0, h.edges - 1 do
    local a, bb = h.ea[e], h.eb[e]
    local len = math.sqrt((h.ax[bb] + h.dx[bb] - h.ax[a] - h.dx[a]) ^ 2 + (h.ay[bb] + h.dy[bb] - h.ay[a] - h.dy[a]) ^ 2 + (h.az[bb] + h.dz[bb] - h.az[a] - h.dz[a]) ^ 2) / h.el[e]
    lo, hi = math.min(lo, len), math.max(hi, len)
  end
  return lo, hi
end
local function deepest() local d = 0 for n = 0, h.count - 1 do d = math.max(d, math.sqrt(h.dx[n] ^ 2 + h.dy[n] ^ 2 + h.dz[n] ^ 2)) end return d end
local function count() local c = 0 for n = 0, h.count - 1 do if h.on[n] == 1 then c = c + 1 end end return c end
local side = 7 * A  -- ring 7, the atom pointing +x (the left side, by the doors)
hull.setLimits(h, nil)
hull.reset(h)
hull.dent(h, h.ax[side], h.ay[side], h.az[side], -1, 0, 0, 0.3, 0.2, 0.5, 0)
local _, spike = edgeRange()
local d0, c0 = deepest(), count()
hull.setLimits(h, 1.05, 0.5, 0.9, 1)
hull.reset(h)
hull.dent(h, h.ax[side], h.ay[side], h.az[side], -1, 0, 0, 0.3, 0.2, 0.5, 0, 0.35, 0, 0.06)
local lo, hi = edgeRange()
check(spike > 1.2, ('without limits a narrow deep push stretches edges to %.2fx'):format(spike))
check(hi <= 1.05 + 0.01 and lo >= 0.5 - 0.01, ('with limits the edges stay within 0.5..1.05 (%.3f..%.3f)'):format(lo, hi))
check(math.abs(deepest() - d0) < 0.01, ('the middle of the dent holds its depth (%.3f vs %.3f)'):format(deepest(), d0))
check(count() > c0 * 2, ('it drags the metal around it in: %d atoms vs %d'):format(count(), c0))
-- squashed: the nose pushed straight back hard: edges along the car squash, the metal folds (crunch)
hull.reset(h)
local capMid = h.caps[1].middle
hull.dent(h, h.ax[capMid], h.ay[capMid], h.az[capMid], 0, 0, 1, 0.5, 0.9, 0.5, 2, 0.35, 0, 0.06)
local lo2 = edgeRange()
local folded = 0
for n = 0, h.count - 1 do if h.cr[n] > 0.005 then folded = folded + 1 end end
check(lo2 >= 0.5 - 0.01, ('squashed no further than 0.5x: %.3f'):format(lo2))
check(folded > 0, 'squashed metal folds: ' .. folded .. ' atoms with crunch')
hull.setLimits(h, nil)

print(fails == 0 and 'hull tests passed' or ('hull tests: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
