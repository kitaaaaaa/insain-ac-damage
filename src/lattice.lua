-- A lattice of "atoms" over a car's body (in the body's own coordinates) that takes the dents, and everything
-- the mesh needs from it: each vertex moves by the lattice's offset where it sits (trilinear interpolation, a
-- free-form deformation), and its normal turns with the lattice's local stretch, so dents catch the light.
-- Plain Lua, no CSP calls: tests run it offline.
local M = {}

local function idx(l, i, j, k) return (k * l.n[2] + j) * l.n[1] + i end
M.index = idx

-- A lattice over the box min..max (tables {x, y, z}) with nodes at most `spacing` apart (at least 2 per axis).
function M.new(min, max, spacing)
  local l = {min = {min[1], min[2], min[3]}, n = {}, step = {}}
  for a = 1, 3 do
    local size = math.max(max[a] - min[a], 1e-3)
    l.n[a] = math.max(2, math.ceil(size / spacing) + 1)
    l.step[a] = size / (l.n[a] - 1)
  end
  l.count = l.n[1] * l.n[2] * l.n[3]
  l.dx, l.dy, l.dz = {}, {}, {}
  l.on = {}  -- 1 where an atom has moved, else 0 (one sum tells if a cell has anything to do)
  M.reset(l)
  l.changed = {}  -- a new lattice has nothing to redo
  return l
end

-- Nodes changed since the last takeChanged() are kept in l.changed (a set), so only the vertices near them
-- need moving again.
function M.reset(l)
  l.changed = l.changed or {}
  for i = 0, l.count - 1 do
    if l.dx[i] ~= 0 or l.dy[i] ~= 0 or l.dz[i] ~= 0 then l.changed[i] = true end
    l.dx[i], l.dy[i], l.dz[i], l.on[i] = 0, 0, 0, 0
  end
  l.dirty = true
end

-- The cells (index of their lowest corner node) next to nodes changed since last time; clears the record.
function M.takeChanged(l)
  local cells, nx, ny, nz = {}, l.n[1], l.n[2], l.n[3]
  for n in pairs(l.changed) do
    local i = n % nx
    local j = math.floor(n / nx) % ny
    local k = math.floor(n / (nx * ny))
    for dk = -1, 0 do for dj = -1, 0 do for di = -1, 0 do
      local ci, cj, ck = i + di, j + dj, k + dk
      if ci >= 0 and ci < nx - 1 and cj >= 0 and cj < ny - 1 and ck >= 0 and ck < nz - 1 then
        cells[idx(l, ci, cj, ck)] = true
      end
    end end end
  end
  l.changed = {}
  return cells
end

-- The cell a point is in (index of its lowest corner node), clamped to the lattice.
function M.cellOf(l, x, y, z)
  local i = math.floor((x - l.min[1]) / l.step[1])
  local j = math.floor((y - l.min[2]) / l.step[2])
  local k = math.floor((z - l.min[3]) / l.step[3])
  if i < 0 then i = 0 elseif i > l.n[1] - 2 then i = l.n[1] - 2 end
  if j < 0 then j = 0 elseif j > l.n[2] - 2 then j = l.n[2] - 2 end
  if k < 0 then k = 0 elseif k > l.n[3] - 2 then k = l.n[3] - 2 end
  return idx(l, i, j, k)
end


-- The position of node (i, j, k) at rest.
function M.nodePos(l, i, j, k)
  return l.min[1] + i * l.step[1], l.min[2] + j * l.step[2], l.min[3] + k * l.step[3]
end

-- A dent: nodes within `radius` of point p move along dir (unit, into the body) by up to `depth` metres, with
-- a smooth falloff ((1 - (d/r)^2)^2). With `springs` passes, the dent then spreads to the atoms around it (each
-- moves `stiffness` of the way to its neighbours' average) -- only this dent: earlier ones stay as they are.
-- Offsets add up (the metal stays bent), each atom's to at most maxOffset. Returns how many atoms moved.
function M.dent(l, px, py, pz, dirx, diry, dirz, depth, radius, maxOffset, springs, stiffness)
  springs, stiffness = springs or 0, stiffness or 0.35
  local nx, ny, nz = l.n[1], l.n[2], l.n[3]
  -- the region it can reach: the radius, plus a node per spring pass
  local i0 = math.max(0, math.floor((px - radius - l.min[1]) / l.step[1]) - springs)
  local i1 = math.min(nx - 1, math.ceil((px + radius - l.min[1]) / l.step[1]) + springs)
  local j0 = math.max(0, math.floor((py - radius - l.min[2]) / l.step[2]) - springs)
  local j1 = math.min(ny - 1, math.ceil((py + radius - l.min[2]) / l.step[2]) + springs)
  local k0 = math.max(0, math.floor((pz - radius - l.min[3]) / l.step[3]) - springs)
  local k1 = math.min(nz - 1, math.ceil((pz + radius - l.min[3]) / l.step[3]) + springs)
  -- the push (a scalar along dir), on the region's nodes
  local w = {}
  local r2 = radius * radius
  for k = k0, k1 do for j = j0, j1 do for i = i0, i1 do
    local x, y, z = M.nodePos(l, i, j, k)
    local d2 = (x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2
    local f = d2 < r2 and 1 - d2 / r2 or 0
    w[idx(l, i, j, k)] = depth * f * f
  end end end
  -- springs: spread it (atoms outside the region count as not pushed)
  for _ = 1, springs do
    local out = {}
    for k = k0, k1 do for j = j0, j1 do for i = i0, i1 do
      local n = idx(l, i, j, k)
      local s, c = 0, 0
      if i > 0 then s, c = s + (w[n - 1] or 0), c + 1 end
      if i < nx - 1 then s, c = s + (w[n + 1] or 0), c + 1 end
      if j > 0 then s, c = s + (w[n - nx] or 0), c + 1 end
      if j < ny - 1 then s, c = s + (w[n + nx] or 0), c + 1 end
      if k > 0 then s, c = s + (w[n - nx * ny] or 0), c + 1 end
      if k < nz - 1 then s, c = s + (w[n + nx * ny] or 0), c + 1 end
      out[n] = w[n] + stiffness * (s / c - w[n])
    end end end
    w = out
  end
  local moved = 0
  for n, a in pairs(w) do
    if a > 1e-6 then
      local ox, oy, oz = l.dx[n] + dirx * a, l.dy[n] + diry * a, l.dz[n] + dirz * a
      local len = math.sqrt(ox * ox + oy * oy + oz * oz)
      if maxOffset and len > maxOffset then local s = maxOffset / len ox, oy, oz = ox * s, oy * s, oz * s end
      if ox ~= l.dx[n] or oy ~= l.dy[n] or oz ~= l.dz[n] then
        l.dx[n], l.dy[n], l.dz[n], l.on[n] = ox, oy, oz, 1
        l.changed[n] = true
        moved = moved + 1
      end
    end
  end
  if moved > 0 then l.dirty = true end
  return moved
end

-- The offset at a point and its derivatives: returns ox, oy, oz and the 9 partials (d(ox,oy,oz)/dx, /dy, /dz),
-- or nil when the cell around the point has no offset at all (the common case: the vertex stays put).
function M.sample(l, x, y, z)
  local nx, ny, nz = l.n[1], l.n[2], l.n[3]
  local u, v, w = (x - l.min[1]) / l.step[1], (y - l.min[2]) / l.step[2], (z - l.min[3]) / l.step[3]
  local i, j, k = math.floor(u), math.floor(v), math.floor(w)
  if i < 0 then i = 0 elseif i > nx - 2 then i = nx - 2 end
  if j < 0 then j = 0 elseif j > ny - 2 then j = ny - 2 end
  if k < 0 then k = 0 elseif k > nz - 2 then k = nz - 2 end
  local fu, fv, fw = math.max(0, math.min(1, u - i)), math.max(0, math.min(1, v - j)), math.max(0, math.min(1, w - k))
  local dx, dy, dz = l.dx, l.dy, l.dz
  local n000, n100 = idx(l, i, j, k), idx(l, i + 1, j, k)
  local n010, n110 = idx(l, i, j + 1, k), idx(l, i + 1, j + 1, k)
  local n001, n101 = idx(l, i, j, k + 1), idx(l, i + 1, j, k + 1)
  local n011, n111 = idx(l, i, j + 1, k + 1), idx(l, i + 1, j + 1, k + 1)
  local on = l.on
  if on[n000] + on[n100] + on[n010] + on[n110] + on[n001] + on[n101] + on[n011] + on[n111] == 0 then return nil end
  local gu, gv, gw = 1 - fu, 1 - fv, 1 - fw
  local su, sv, sw = l.step[1], l.step[2], l.step[3]
  -- trilinear value and partials, per component (written out: no closures in this hot path)
  local a000, a100, a010, a110, a001, a101, a011, a111 = dx[n000], dx[n100], dx[n010], dx[n110], dx[n001], dx[n101], dx[n011], dx[n111]
  local c0 = (a000 * gu + a100 * fu) * gv + (a010 * gu + a110 * fu) * fv
  local c1 = (a001 * gu + a101 * fu) * gv + (a011 * gu + a111 * fu) * fv
  local ox = c0 * gw + c1 * fw
  local oxx = (((a100 - a000) * gv + (a110 - a010) * fv) * gw + ((a101 - a001) * gv + (a111 - a011) * fv) * fw) / su
  local oxy = (((a010 - a000) * gu + (a110 - a100) * fu) * gw + ((a011 - a001) * gu + (a111 - a101) * fu) * fw) / sv
  local oxz = (c1 - c0) / sw
  a000, a100, a010, a110, a001, a101, a011, a111 = dy[n000], dy[n100], dy[n010], dy[n110], dy[n001], dy[n101], dy[n011], dy[n111]
  c0 = (a000 * gu + a100 * fu) * gv + (a010 * gu + a110 * fu) * fv
  c1 = (a001 * gu + a101 * fu) * gv + (a011 * gu + a111 * fu) * fv
  local oy = c0 * gw + c1 * fw
  local oyx = (((a100 - a000) * gv + (a110 - a010) * fv) * gw + ((a101 - a001) * gv + (a111 - a011) * fv) * fw) / su
  local oyy = (((a010 - a000) * gu + (a110 - a100) * fu) * gw + ((a011 - a001) * gu + (a111 - a101) * fu) * fw) / sv
  local oyz = (c1 - c0) / sw
  a000, a100, a010, a110, a001, a101, a011, a111 = dz[n000], dz[n100], dz[n010], dz[n110], dz[n001], dz[n101], dz[n011], dz[n111]
  c0 = (a000 * gu + a100 * fu) * gv + (a010 * gu + a110 * fu) * fv
  c1 = (a001 * gu + a101 * fu) * gv + (a011 * gu + a111 * fu) * fv
  local oz = c0 * gw + c1 * fw
  local ozx = (((a100 - a000) * gv + (a110 - a010) * fv) * gw + ((a101 - a001) * gv + (a111 - a011) * fv) * fw) / su
  local ozy = (((a010 - a000) * gu + (a110 - a100) * fu) * gw + ((a011 - a001) * gu + (a111 - a101) * fu) * fw) / sv
  local ozz = (c1 - c0) / sw
  return ox, oy, oz, oxx, oyx, ozx, oxy, oyy, ozy, oxz, oyz, ozz
end

-- A normal through the deformation (for small stretches: n - J^T n, normalised). The partials as sample()
-- returns them: (dO/dx), (dO/dy), (dO/dz), each a vector.
function M.bendNormal(nx, ny, nz, ax, ay, az, bx, by, bz, cx, cy, cz)
  local rx = nx - (nx * ax + ny * ay + nz * az)
  local ry = ny - (nx * bx + ny * by + nz * bz)
  local rz = nz - (nx * cx + ny * cy + nz * cz)
  local len = math.sqrt(rx * rx + ry * ry + rz * rz)
  if len < 1e-6 then return nx, ny, nz end
  return rx / len, ry / len, rz / len
end

return M
