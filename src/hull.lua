-- A car-shaped hull of atoms, the way 1nsane did it: atoms on the outside of the body, triangles between them,
-- and every vertex pinned to the nearest triangles. A vertex sits at
--   p = a + u (b - a) + v (c - a) + h (b - a) x (c - a)
-- for its triangle's atoms a, b, c (the normal offset uses the cross product as it is, not normalised, so it
-- scales with the triangle). 1nsane stored these u, v, h per vertex in its models (RELP); here they're worked
-- out from the car's own meshes, so any car works.
-- The hull: rings of atoms around the body's length (z), each atom as far out as the body goes in its
-- direction from the ring's middle, and at each end, smaller rings down to a middle atom, following the nose or
-- the tail. Plain Lua, no CSP calls: tests run it offline.
local arrays = require('src/arrays')
local M = {}

local sqrt, floor, atan2, pi = math.sqrt, math.floor, math.atan2, math.pi

-- Builds the hull around meshes ({px, py, pz, n}; body space, z along the car) inside min..max: rings at most
-- ringSpacing apart, `around` atoms on each. tick() is called now and then (for yielding).
function M.new(meshes, min, max, ringSpacing, around, tick)
  local len = math.max(max[3] - min[3], 1e-3)
  ringSpacing = math.max(ringSpacing, len / 60)  -- (a safety net: 61 rings at most)
  local K = math.max(2, math.ceil(len / ringSpacing) + 1)
  local step = len / (K - 1)
  local cx = (min[1] + max[1]) / 2
  local A = around
  local h = {rings = K, around = A, step = step, zmin = min[3], cx = cx}
  -- each ring's height range, then its middle
  local ylo, yhi = {}, {}
  local count = 0
  for _, mesh in ipairs(meshes) do
    for v = 0, mesh.n - 1 do
      local k = floor((mesh.pz[v] - min[3]) / step + 0.5)
      if k < 0 then k = 0 elseif k > K - 1 then k = K - 1 end
      local y = mesh.py[v]
      if not ylo[k] or y < ylo[k] then ylo[k] = y end
      if not yhi[k] or y > yhi[k] then yhi[k] = y end
      count = count + 1
      if tick and count % 4000 == 0 then tick() end
    end
  end
  local cy = {}
  for k = 0, K - 1 do cy[k] = ylo[k] and (ylo[k] + yhi[k]) / 2 or (min[2] + max[2]) / 2 end
  -- how far out the body goes from each ring's middle in each atom's direction (s: angle 2 pi s / A, from +x):
  -- the farthest vertex within a sixth of the way to the next atom; failing that (a sparse mesh) the vertex
  -- nearest that direction. The pass after this pushes atoms out as far as needed to go around everything.
  local rad, near, nearAng = {}, {}, {}
  for k = 0, K - 1 do rad[k], near[k], nearAng[k] = {}, {}, {} end
  local D = 2 * pi / A
  for _, mesh in ipairs(meshes) do
    for v = 0, mesh.n - 1 do
      local k = floor((mesh.pz[v] - min[3]) / step + 0.5)
      if k < 0 then k = 0 elseif k > K - 1 then k = K - 1 end
      local dx, dy = mesh.px[v] - cx, mesh.py[v] - cy[k]
      local f = atan2(dy, dx) / D
      local s = floor(f + 0.5)
      local off = math.abs(f - s) * D  -- radians from the atom's direction
      s = s % A
      local r = sqrt(dx * dx + dy * dy)
      if off < D / 6 and (not rad[k][s] or r > rad[k][s]) then rad[k][s] = r end
      local na = nearAng[k][s]
      if not na or off < na - 0.01 or (off < na + 0.01 and r > near[k][s]) then near[k][s], nearAng[k][s] = r, off end
      count = count + 1
      if tick and count % 4000 == 0 then tick() end
    end
  end
  for k = 0, K - 1 do for s = 0, A - 1 do rad[k][s] = rad[k][s] or near[k][s] end end
  -- gaps: a direction with nothing in it takes the average of the nearest ones around; a ring with nothing in
  -- it, the nearest ring's
  for k = 0, K - 1 do
    local any = false
    for s = 0, A - 1 do if rad[k][s] then any = true end end
    if any then
      local fill = {}
      for s = 0, A - 1 do
        if not rad[k][s] then
          local a, b
          for d = 1, A do if rad[k][(s - d) % A] then a = rad[k][(s - d) % A] break end end
          for d = 1, A do if rad[k][(s + d) % A] then b = rad[k][(s + d) % A] break end end
          fill[s] = (a + b) / 2
        end
      end
      for s, r in pairs(fill) do rad[k][s] = r end
    end
  end
  for k = 0, K - 1 do
    if not rad[k][0] then
      for d = 1, K do
        local src = (k - d >= 0 and rad[k - d][0] and k - d) or (k + d < K and rad[k + d][0] and k + d)
        if src then for s = 0, A - 1 do rad[k][s] = rad[src][s] end cy[k] = cy[src] break end
      end
    end
  end
  -- the hull goes around the body, as 1nsane's did: the edges between a ring's atoms pass outside every vertex
  -- near that ring (both rings either side of it), so vertices sit inside their triangles and don't get pushed
  -- out when the hull bends. Atoms only move out, so a vertex once inside stays inside.
  local sinD = math.sin(D)
  for k = 0, K - 1 do for s = 0, A - 1 do rad[k][s] = math.max(rad[k][s] or 0, 0.02) end end
  for _, mesh in ipairs(meshes) do
    for v = 0, mesh.n - 1 do
      local f = (mesh.pz[v] - min[3]) / step
      local k0 = floor(f)
      if k0 < 0 then k0 = 0 elseif k0 > K - 1 then k0 = K - 1 end
      local k1 = k0 + 1 < K and k0 + 1 or k0
      for k = k0, k1, math.max(1, k1 - k0) do
        local dx, dy = mesh.px[v] - cx, mesh.py[v] - cy[k]
        local r = sqrt(dx * dx + dy * dy)
        if r > 1e-6 then
          local phi = atan2(dy, dx) % (2 * pi)
          local s = floor(phi / D) % A
          local s1 = (s + 1) % A
          local t = phi - s * D
          local ra, rb = rad[k][s], rad[k][s1]
          -- the edge's distance from the middle in this direction
          local re = ra * rb * sinD / (ra * math.sin(t) + rb * math.sin(D - t))
          if r * 1.005 > re then
            local g = r * 1.005 / re
            rad[k][s], rad[k][s1] = ra * g, rb * g
          end
        end
      end
      count = count + 1
      if tick and count % 4000 == 0 then tick() end
    end
  end
  -- atoms: ring k, direction s at k * A + s; the front and back caps after them
  local ax, ay, az = {}, {}, {}
  for k = 0, K - 1 do
    local z = min[3] + k * step
    for s = 0, A - 1 do
      local t = 2 * pi * s / A
      local r = math.max(rad[k][s] or 0, 0.02)
      local n = k * A + s
      ax[n], ay[n], az[n] = cx + r * math.cos(t), cy[k] + r * math.sin(t), z
    end
  end
  -- the ends: concentric rings of atoms inside the end rings, down to a middle atom, each as far forward (back)
  -- as the body goes at its spot, so the caps follow the nose and the tail. The body's front-most and rear-most
  -- points per spot, on a grid (cells of half the ring spacing) across the car
  local G = ringSpacing * 0.5
  local front, back = {}, {}
  for _, mesh in ipairs(meshes) do
    for v = 0, mesh.n - 1 do
      local key = floor(mesh.px[v] / G) * 65536 + floor(mesh.py[v] / G)
      local z = mesh.pz[v]
      if not front[key] or z < front[key] then front[key] = z end
      if not back[key] or z > back[key] then back[key] = z end
      count = count + 1
      if tick and count % 4000 == 0 then tick() end
    end
  end
  local function farthest(grid, x, y, pick, default)  -- the farthest point within a cell of (x, y)
    local gx, gy, best = floor(x / G), floor(y / G), nil
    for i = -1, 1 do for j = -1, 1 do
      local z = grid[(gx + i) * 65536 + gy + j]
      if z and (not best or pick(z, best)) then best = z end
    end end
    return best or default
  end
  local function less(a, b) return a < b end
  local function more(a, b) return a > b end
  local n = K * A
  h.caps = {}
  for e = 1, 2 do
    local k = e == 1 and 0 or K - 1
    local grid, pick, edge = e == 1 and front or back, e == 1 and less or more, min[3] + k * step
    local reach = 0
    for s = 0, A - 1 do reach = math.max(reach, rad[k][s]) end
    local C = math.min(8, math.max(2, math.ceil(reach / ringSpacing)))  -- rings from the edge to the middle
    local cap = {first = n, rings = C - 1}
    for c = 1, C - 1 do
      local frac = 1 - c / C
      for s = 0, A - 1 do
        local o = k * A + s
        local x, y = cx + (ax[o] - cx) * frac, cy[k] + (ay[o] - cy[k]) * frac
        local z = farthest(grid, x, y, pick, edge)
        -- a little out from the body, and never past the middle of the car
        z = e == 1 and math.min(z - 0.01, (min[3] + max[3]) / 2) or math.max(z + 0.01, (min[3] + max[3]) / 2)
        ax[n], ay[n], az[n] = x, y, z
        n = n + 1
      end
    end
    local mz = farthest(grid, cx, cy[k], pick, edge)
    ax[n], ay[n], az[n] = cx, cy[k], e == 1 and mz - 0.01 or mz + 0.01
    cap.middle = n
    n = n + 1
    h.caps[e] = cap
  end
  h.count = n
  h.ax, h.ay, h.az = ax, ay, az
  -- triangles: two per quad between rings (row r: rings r and r + 1), then the caps: quads between their
  -- rings (the end ring, then the cap's rings inwards) and a fan to the middle
  local ta, tb, tc = {}, {}, {}
  local nt = 0
  local function tri(a, b, c) ta[nt], tb[nt], tc[nt] = a, b, c nt = nt + 1 end  -- (setup only)
  for r = 0, K - 2 do
    for s = 0, A - 1 do
      local a, b = r * A + s, r * A + (s + 1) % A
      local c, d = a + A, b + A
      tri(a, b, c) tri(b, d, c)
    end
  end
  for e = 1, 2 do
    local cap = h.caps[e]
    cap.tris = nt
    local k = e == 1 and 0 or K - 1
    local outer = k * A
    for c = 1, cap.rings do
      local inner = cap.first + (c - 1) * A
      for s = 0, A - 1 do
        local a, b = outer + s, outer + (s + 1) % A
        local c2, d = inner + s, inner + (s + 1) % A
        tri(a, b, c2) tri(b, d, c2)
      end
      outer = inner
    end
    for s = 0, A - 1 do tri(cap.middle, outer + (s + 1) % A, outer + s) end
    cap.trisEnd = nt - 1
  end
  h.tris = nt
  h.ta, h.tb, h.tc = ta, tb, tc
  -- each atom's neighbours (the triangles' edges) and triangles
  local nb, atomTris = {}, {}
  for n = 0, h.count - 1 do nb[n], atomTris[n] = {}, {} end
  local function link(a, b) nb[a][b] = true nb[b][a] = true end
  for t = 0, nt - 1 do
    local a, b, c = ta[t], tb[t], tc[t]
    link(a, b) link(b, c) link(c, a)
    atomTris[a][#atomTris[a] + 1] = t atomTris[b][#atomTris[b] + 1] = t atomTris[c][#atomTris[c] + 1] = t
  end
  h.neighbours = {}
  for n = 0, h.count - 1 do
    local list = {}
    for m in pairs(nb[n]) do list[#list + 1] = m end
    table.sort(list)
    h.neighbours[n] = list
  end
  h.atomTris = atomTris
  -- springs: one per edge, with its length at rest (the limits are set with setLimits)
  h.ea, h.eb, h.el = {}, {}, {}
  local ne = 0
  for n = 0, h.count - 1 do
    for _, m in ipairs(h.neighbours[n]) do
      if m > n then
        h.ea[ne], h.eb[ne] = n, m
        h.el[ne] = sqrt((ax[m] - ax[n]) ^ 2 + (ay[m] - ay[n]) ^ 2 + (az[m] - az[n]) ^ 2)
        ne = ne + 1
      end
    end
  end
  h.edges = ne
  -- each triangle's cross product at rest
  h.rcx, h.rcy, h.rcz = {}, {}, {}
  for t = 0, nt - 1 do
    local a, b, c = ta[t], tb[t], tc[t]
    local e1x, e1y, e1z = ax[b] - ax[a], ay[b] - ay[a], az[b] - az[a]
    local e2x, e2y, e2z = ax[c] - ax[a], ay[c] - ay[a], az[c] - az[a]
    h.rcx[t], h.rcy[t], h.rcz[t] = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
  end
  h.dx, h.dy, h.dz, h.cr, h.on = {}, {}, {}, {}, {}
  M.reset(h)
  h.changed = {}
  -- the triangles' shapes now, worked out once per pass (see begin())
  h.pass, h.stamp = 0, {}
  h.dcx, h.dcy, h.dcz = {}, {}, {}
  h.f1x, h.f1y, h.f1z, h.f2x, h.f2y, h.f2z, h.fnx, h.fny, h.fnz = {}, {}, {}, {}, {}, {}, {}, {}, {}
  return h
end

function M.reset(h)
  h.changed = h.changed or {}
  for n = 0, h.count - 1 do
    if (h.dx[n] or 0) ~= 0 or (h.dy[n] or 0) ~= 0 or (h.dz[n] or 0) ~= 0 or (h.cr[n] or 0) ~= 0 then h.changed[n] = true end
    h.dx[n], h.dy[n], h.dz[n], h.cr[n], h.on[n] = 0, 0, 0, 0, 0
  end
  h.dirty = true
end

-- The triangles next to atoms changed since last time; clears the record.
function M.takeChanged(h)
  local tris = {}
  for n in pairs(h.changed) do for _, t in ipairs(h.atomTris[n]) do tris[t] = true end end
  h.changed = {}
  return tris
end

-- A point's coordinates on triangle t (rest): u, v in the triangle's plane and h along its cross product.
local function coords(h, t, px, py, pz)
  local ax, ay, az = h.ax, h.ay, h.az
  local a, b, c = h.ta[t], h.tb[t], h.tc[t]
  local e1x, e1y, e1z = ax[b] - ax[a], ay[b] - ay[a], az[b] - az[a]
  local e2x, e2y, e2z = ax[c] - ax[a], ay[c] - ay[a], az[c] - az[a]
  local cx, cy, cz = h.rcx[t], h.rcy[t], h.rcz[t]
  local c2 = cx * cx + cy * cy + cz * cz
  local qx, qy, qz = px - ax[a], py - ay[a], pz - az[a]
  local hh = (qx * cx + qy * cy + qz * cz) / c2
  qx, qy, qz = qx - hh * cx, qy - hh * cy, qz - hh * cz
  local d11, d12, d22 = e1x * e1x + e1y * e1y + e1z * e1z, e1x * e2x + e1y * e2y + e1z * e2z, e2x * e2x + e2y * e2y + e2z * e2z
  local r1, r2 = qx * e1x + qy * e1y + qz * e1z, qx * e2x + qy * e2y + qz * e2z
  local den = d11 * d22 - d12 * d12
  return (d22 * r1 - d12 * r2) / den, (d11 * r2 - d12 * r1) / den, hh, c2
end

M.SLOTS = 2  -- triangles a vertex follows: the nearest, and a second as near (within BLEND) for smooth seams
local BLEND = 0.05

-- Pins a vertex (position p, normal n; body space) to the hull: writes its u, v, h, weight and normal (in the
-- triangle's frame) into the arrays of `b` at slots i * SLOTS + j; bt = -1 for a slot not used.
function M.bind(h, b, i, px, py, pz, nx, ny, nz)
  local K, A = h.rings, h.around
  local k = floor((pz - h.zmin) / h.step + 0.5)
  if k < 0 then k = 0 elseif k > K - 1 then k = K - 1 end
  local ax, ay, az, ta, tb, tc = h.ax, h.ay, h.az, h.ta, h.tb, h.tc
  local best1, best2, d1, d2, out1 = -1, -1, 1e18, 1e18, nil
  -- the candidates: the rows of triangles either side of its ring, and a cap at the ends (three ranges; an empty
  -- range has from > to)
  local r0, r1 = math.max(0, k - 1), math.min(K - 2, k)
  local from1, to1 = r0 * 2 * A, r1 * 2 * A + 2 * A - 1
  local cf, cb = h.caps[1], h.caps[2]
  local from2, to2 = cf.tris, k <= 1 and cf.trisEnd or cf.tris - 1
  local from3, to3 = cb.tris, k >= K - 2 and cb.trisEnd or cb.tris - 1
  local rcx, rcy, rcz = h.rcx, h.rcy, h.rcz
  for range = 1, 3 do
    local from, to = from1, to1
    if range == 2 then from, to = from2, to2 elseif range == 3 then from, to = from3, to3 end
    for t = from, to do
      if rcx[t] * rcx[t] + rcy[t] * rcy[t] + rcz[t] * rcz[t] > 1e-12 then
        -- how well it fits: its distance from the triangle's plane, and how far off the triangle's edges it is
        -- (in metres, about: the triangle's size), so a vertex goes to a triangle over it rather than one it's
        -- only near the edge of (whose coordinates would reach far out of it, and swing it as the hull bends)
        local u, v, hh, c2 = coords(h, t, px, py, pz)
        local out = math.max(0, -u, -v, u + v - 1)
        local d = math.abs(hh) * sqrt(c2) + out * sqrt(sqrt(c2))
        -- the second (for blending across a seam) only from triangles it's over
        if d < d1 then
          if out1 and out1 <= 0.02 then best2, d2 = best1, d1 end
          best1, d1, out1 = t, d, out
        elseif d < d2 and out <= 0.02 then best2, d2 = t, d end
      end
    end
  end
  local base = i * M.SLOTS
  local s1, s2 = d1, d2
  local w1 = 1 / (s1 + 0.03) ^ 2
  local w2 = (best2 >= 0 and s2 < s1 + BLEND) and (1 / (s2 + 0.03) ^ 2) * (1 - (s2 - s1) / BLEND) or 0
  local sum = w1 + w2
  for j = 0, M.SLOTS - 1 do
    local t = j == 0 and best1 or best2
    local w = (j == 0 and w1 or w2) / sum
    if t < 0 or w <= 0 then b.bt[base + j] = -1 b.bw[base + j] = 0
    else
      local a, bb = ta[t], tb[t]
      local e1x, e1y, e1z = ax[bb] - ax[a], ay[bb] - ay[a], az[bb] - az[a]
      local cx, cy, cz = h.rcx[t], h.rcy[t], h.rcz[t]
      local u, v, hh, c2 = coords(h, t, px, py, pz)
      b.bt[base + j], b.bw[base + j] = t, w
      b.bu[base + j], b.bv[base + j], b.bh[base + j] = u, v, hh
      -- the normal in the triangle's frame (f1 along ab, fn its normal, f2 = fn x f1)
      local l1, ln = sqrt(e1x * e1x + e1y * e1y + e1z * e1z), sqrt(c2)
      local f1x, f1y, f1z = e1x / l1, e1y / l1, e1z / l1
      local fnx, fny, fnz = cx / ln, cy / ln, cz / ln
      local f2x, f2y, f2z = fny * f1z - fnz * f1y, fnz * f1x - fnx * f1z, fnx * f1y - fny * f1x
      b.b1[base + j], b.b2[base + j], b.b3[base + j] = nx * f1x + ny * f1y + nz * f1z, nx * f2x + ny * f2y + nz * f2z, nx * fnx + ny * fny + nz * fnz
    end
  end
  return best1, best2
end

-- Arrays for n vertices' bindings (compact: FFI floats).
function M.newBindings(n)
  local k = n * M.SLOTS
  return {bt = arrays.ints(k, -1), bw = arrays.floats(k), bu = arrays.floats(k), bv = arrays.floats(k), bh = arrays.floats(k),
    b1 = arrays.floats(k), b2 = arrays.floats(k), b3 = arrays.floats(k)}
end

-- A new pass over the vertices: every triangle's shape worked out now (a few thousand at most), so the loop
-- over the vertices never branches off to do it (LuaJIT then compiles that loop).
local prep
function M.begin(h)
  h.pass = h.pass + 1
  for t = 0, h.tris - 1 do prep(h, t) end
end

function prep(h, t)
  local a, b, c = h.ta[t], h.tb[t], h.tc[t]
  local ax, ay, az, dx, dy, dz = h.ax, h.ay, h.az, h.dx, h.dy, h.dz
  local Ax, Ay, Az = ax[a] + dx[a], ay[a] + dy[a], az[a] + dz[a]
  local e1x, e1y, e1z = ax[b] + dx[b] - Ax, ay[b] + dy[b] - Ay, az[b] + dz[b] - Az
  local e2x, e2y, e2z = ax[c] + dx[c] - Ax, ay[c] + dy[c] - Ay, az[c] + dz[c] - Az
  local cx, cy, cz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
  h.dcx[t], h.dcy[t], h.dcz[t] = cx - h.rcx[t], cy - h.rcy[t], cz - h.rcz[t]
  local l1 = sqrt(e1x * e1x + e1y * e1y + e1z * e1z)
  local ln = sqrt(cx * cx + cy * cy + cz * cz)
  if l1 < 1e-9 or ln < 1e-12 then  -- crushed flat: keep the rest frame
    local rx, ry, rz = h.rcx[t], h.rcy[t], h.rcz[t]
    ln = sqrt(rx * rx + ry * ry + rz * rz)
    e1x, e1y, e1z = ax[b] - ax[a], ay[b] - ay[a], az[b] - az[a]
    l1 = sqrt(e1x * e1x + e1y * e1y + e1z * e1z)
    cx, cy, cz = rx, ry, rz
  end
  local f1x, f1y, f1z = e1x / l1, e1y / l1, e1z / l1
  local fnx, fny, fnz = cx / ln, cy / ln, cz / ln
  h.f1x[t], h.f1y[t], h.f1z[t] = f1x, f1y, f1z
  h.fnx[t], h.fny[t], h.fnz[t] = fnx, fny, fnz
  h.f2x[t], h.f2y[t], h.f2z[t] = fny * f1z - fnz * f1y, fnz * f1x - fnx * f1z, fnx * f1y - fny * f1x
  h.stamp[t] = h.pass
end

-- One slot's share of a vertex's move (weighted): offset, normal, crunch; zeros for an unused slot.
local function slot(h, b, k)
  local t = b.bt[k]
  if t < 0 then return 0, 0, 0, 0, 0, 0, 0 end
  local w, u, v, hh = b.bw[k], b.bu[k], b.bv[k], b.bh[k]
  local a, bb, c = h.ta[t], h.tb[t], h.tc[t]
  local dx, dy, dz, cr = h.dx, h.dy, h.dz, h.cr
  -- (a' + u e1' + v e2' + h c') - (a + u e1 + v e2 + h c): the atoms' offsets mixed, and the cross product's change
  local wa = 1 - u - v
  local c1, c2, c3 = w * b.b1[k], w * b.b2[k], w * b.b3[k]
  -- the crunch: the atoms' mixed inside the triangle (clamped to it)
  local pu = u > 0 and u or 0
  local pv = v > 0 and v or 0
  local pa = wa > 0 and wa or 0
  return w * (wa * dx[a] + u * dx[bb] + v * dx[c] + hh * h.dcx[t]),
    w * (wa * dy[a] + u * dy[bb] + v * dy[c] + hh * h.dcy[t]),
    w * (wa * dz[a] + u * dz[bb] + v * dz[c] + hh * h.dcz[t]),
    c1 * h.f1x[t] + c2 * h.f2x[t] + c3 * h.fnx[t],
    c1 * h.f1y[t] + c2 * h.f2y[t] + c3 * h.fny[t],
    c1 * h.f1z[t] + c2 * h.f2z[t] + c3 * h.fnz[t],
    w * (pa * cr[a] + pu * cr[bb] + pv * cr[c]) / (pa + pu + pv)
end

-- A vertex's offset from rest (ox, oy, oz), its new normal (qx, qy, qz) and the crunch there; nil when none of
-- its atoms has moved (the common case: it stays put). The two slots (M.SLOTS) written out: a loop carrying
-- seven sums, LuaJIT couldn't compile ("register coalescing too complex").
function M.sample(h, b, i)
  local k = i * 2
  local bt, on, ta, tb, tc = b.bt, h.on, h.ta, h.tb, h.tc
  local t0, t1 = bt[k], bt[k + 1]
  local any = 0
  if t0 >= 0 then any = any + on[ta[t0]] + on[tb[t0]] + on[tc[t0]] end
  if t1 >= 0 then any = any + on[ta[t1]] + on[tb[t1]] + on[tc[t1]] end
  if any == 0 then return nil end
  local ox, oy, oz, qx, qy, qz, cr = slot(h, b, k)
  local ox2, oy2, oz2, qx2, qy2, qz2, cr2 = slot(h, b, k + 1)
  qx, qy, qz = qx + qx2, qy + qy2, qz + qz2
  local ql = sqrt(qx * qx + qy * qy + qz * qz)
  if ql < 1e-9 then ql = 1 end
  return ox + ox2, oy + oy2, oz + oz2, qx / ql, qy / ql, qz / ql, cr + cr2
end

-- A dent: atoms within `radius` of p (at least the nearest one) move along dir by up to `depth`, with a smooth
-- falloff; `springs` passes then spread it along the hull's edges (each atom moves `stiffness` of the way to
-- its neighbours' average). As lattice.dent: offsets add up to at most maxOffset, the crunch to maxCrunch.
function M.dent(h, px, py, pz, dirx, diry, dirz, depth, radius, maxOffset, springs, stiffness, crunch, maxCrunch)
  springs, stiffness, crunch = springs or 0, stiffness or 0.35, crunch or 0
  local ax, ay, az = h.ax, h.ay, h.az
  local nearest = 1e18
  for n = 0, h.count - 1 do
    local d2 = (ax[n] + h.dx[n] - px) ^ 2 + (ay[n] + h.dy[n] - py) ^ 2 + (az[n] + h.dz[n] - pz) ^ 2
    if d2 < nearest then nearest = d2 end
  end
  nearest = sqrt(nearest)
  if radius < nearest * 1.25 then radius = nearest * 1.25 end
  local r2 = radius * radius
  local w, cw, region = {}, {}, {}
  for n = 0, h.count - 1 do
    local d2 = (ax[n] + h.dx[n] - px) ^ 2 + (ay[n] + h.dy[n] - py) ^ 2 + (az[n] + h.dz[n] - pz) ^ 2
    if d2 < r2 then
      local f = 1 - d2 / r2
      w[n], cw[n] = depth * f * f, crunch * f * f
      region[#region + 1] = n
    end
  end
  -- the atoms the springs can reach: a step along the edges per pass
  local inRegion = {}
  for _, n in ipairs(region) do inRegion[n] = true end
  local frontier = region
  for _ = 1, springs do
    local nextF = {}
    for _, n in ipairs(frontier) do
      for _, m in ipairs(h.neighbours[n]) do
        if not inRegion[m] then inRegion[m] = true region[#region + 1] = m nextF[#nextF + 1] = m w[m], cw[m] = 0, 0 end
      end
    end
    frontier = nextF
  end
  for _ = 1, springs do
    local out, cout = {}, {}
    for _, n in ipairs(region) do
      local s, t, list = 0, 0, h.neighbours[n]
      for _, m in ipairs(list) do s, t = s + (w[m] or 0), t + (cw[m] or 0) end
      out[n] = w[n] + stiffness * (s / #list - w[n])
      cout[n] = cw[n] + stiffness * (t / #list - cw[n])
    end
    w, cw = out, cout
  end
  local moved = 0
  for _, n in ipairs(region) do
    local a, ca = w[n] or 0, cw[n] or 0
    if a > 1e-6 or ca > 1e-6 then
      local ox, oy, oz = h.dx[n] + dirx * a, h.dy[n] + diry * a, h.dz[n] + dirz * a
      local len = sqrt(ox * ox + oy * oy + oz * oz)
      if maxOffset and len > maxOffset then local k = maxOffset / len ox, oy, oz = ox * k, oy * k, oz * k end
      local c = h.cr[n] + ca
      if maxCrunch and c > maxCrunch then c = maxCrunch end
      if ox ~= h.dx[n] or oy ~= h.dy[n] or oz ~= h.dz[n] or c ~= h.cr[n] then
        h.dx[n], h.dy[n], h.dz[n], h.cr[n], h.on[n] = ox, oy, oz, c, 1
        h.changed[n] = true
        moved = moved + 1
      end
    end
  end
  if h.limits then
    -- how firmly each atom holds where this dent put it: the middle of the dent fully, its edges hardly
    local most, pin = 0, {}
    for _, n in ipairs(region) do if (w[n] or 0) > most then most = w[n] end end
    if most > 1e-9 then for _, n in ipairs(region) do pin[n] = math.min(1, (w[n] or 0) / most) end end
    moved = moved + M.relax(h, pin, maxOffset, maxCrunch)
  end
  if moved > 0 then h.dirty = true end
  return moved
end

-- The springs' limits, 1nsane's way: each edge between atoms may stretch to `stretch` times its length at rest
-- and squash to `squash` times, no further; squashed past `fold` times, the metal there folds: its atoms get
-- crunch, `foldCrunch` metres per metre squashed past that. nil turns the limits off.
function M.setLimits(h, stretch, squash, fold, foldCrunch, iterations)
  if not stretch then h.limits = nil return end
  h.limits = {stretch = stretch, squash = squash, fold = fold or 1, foldCrunch = foldCrunch or 0, iterations = iterations or 10}
end

-- Keeps every edge within its limits: an edge stretched or squashed too far moves its atoms back within them
-- (a few passes over all of them, each correction shared by how free each atom is: `pin` [atom] = 1 holds it
-- still, as the middle of a dent). So a deep dent drags the metal around it in, rather than poking a spike.
-- Then the folds. Returns how many atoms changed.
function M.relax(h, pin, maxOffset, maxCrunch)
  local L = h.limits
  local ax, ay, az, dx, dy, dz = h.ax, h.ay, h.az, h.dx, h.dy, h.dz
  local ea, eb, el = h.ea, h.eb, h.el
  local hi, lo = L.stretch, L.squash
  local touched = {}
  for _ = 1, L.iterations do
    local worst = 0
    for e = 0, h.edges - 1 do
      local a, b = ea[e], eb[e]
      local vx = ax[b] + dx[b] - ax[a] - dx[a]
      local vy = ay[b] + dy[b] - ay[a] - dy[a]
      local vz = az[b] + dz[b] - az[a] - dz[a]
      local len = sqrt(vx * vx + vy * vy + vz * vz)
      local rest = el[e]
      local target = len > rest * hi and rest * hi or (len < rest * lo and rest * lo or len)
      if target ~= len and len > 1e-9 then
        local wa, wb = 1 - (pin[a] or 0), 1 - (pin[b] or 0)
        local sum = wa + wb
        if sum > 1e-9 then
          local k = (len - target) / len / sum
          dx[a], dy[a], dz[a] = dx[a] + vx * k * wa, dy[a] + vy * k * wa, dz[a] + vz * k * wa
          dx[b], dy[b], dz[b] = dx[b] - vx * k * wb, dy[b] - vy * k * wb, dz[b] - vz * k * wb
          if wa > 0 then touched[a] = true end
          if wb > 0 then touched[b] = true end
          local off = math.abs(len - target) / rest
          if off > worst then worst = off end
        end
      end
    end
    if worst < 1e-4 then break end
  end
  local changed = 0
  for n in pairs(touched) do
    local len = sqrt(dx[n] * dx[n] + dy[n] * dy[n] + dz[n] * dz[n])
    if maxOffset and len > maxOffset then local k = maxOffset / len dx[n], dy[n], dz[n] = dx[n] * k, dy[n] * k, dz[n] * k end
    if h.on[n] == 0 or not h.changed[n] then changed = changed + 1 end
    h.on[n] = 1
    h.changed[n] = true
  end
  -- folds: squashed past `fold`, the metal crumples (at least this much crunch: it doesn't pile up dent after dent)
  if L.foldCrunch > 0 then
    for e = 0, h.edges - 1 do
      local a, b = ea[e], eb[e]
      local len = sqrt((ax[b] + dx[b] - ax[a] - dx[a]) ^ 2 + (ay[b] + dy[b] - ay[a] - dy[a]) ^ 2 + (az[b] + dz[b] - az[a] - dz[a]) ^ 2)
      local short = el[e] * L.fold - len
      if short > 0 then
        local c = short * L.foldCrunch
        if maxCrunch and c > maxCrunch then c = maxCrunch end
        if c > h.cr[a] then h.cr[a] = c h.on[a] = 1 h.changed[a] = true changed = changed + 1 end
        if c > h.cr[b] then h.cr[b] = c h.on[b] = 1 h.changed[b] = true changed = changed + 1 end
      end
    end
  end
  return changed
end

return M
