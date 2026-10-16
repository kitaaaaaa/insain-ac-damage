-- luajit tests/lattice_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local L = require('src/lattice')
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local function near(a, b, e) return math.abs(a - b) < (e or 1e-6) end

local l = L.new({-1, 0, -2}, {1, 1.2, 2}, 0.25)
check(l.n[1] == 9 and l.n[3] == 17, 'node counts ' .. l.n[1] .. ' ' .. l.n[2] .. ' ' .. l.n[3])
check(L.sample(l, 0, 0.5, 0) == nil, 'untouched: no offset')
check(next(L.takeChanged(L.new({0, 0, 0}, {1, 1, 1}, 0.25))) == nil, 'a new lattice has nothing changed')
-- a dent on top at a node, pushing down 0.1 m with radius 0.6
local x, y, z = L.nodePos(l, 4, l.n[2] - 1, 8)
L.dent(l, x, y, z, 0, -1, 0, 0.1, 0.6, 0.5)
local ox, oy, oz = L.sample(l, x, y, z)
check(near(ox, 0) and near(oy, -0.1) and near(oz, 0), 'full depth at the centre: ' .. tostring(oy))
check(L.sample(l, -0.95, y, -1.95) == nil, 'far away: untouched')
local _, oy2 = L.sample(l, x + 0.3, y, z)
check(oy2 < 0 and oy2 > -0.1, 'falls off with distance: ' .. tostring(oy2))
-- the top surface's normal (0,1,0) beside the dent tilts towards the dent: to -x on the +x side
local s = {L.sample(l, x + 0.3, y, z)}
local nx, ny, nz = L.bendNormal(0, 1, 0, s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12])
check(nx < -0.01 and ny > 0.9 and near(nx * nx + ny * ny + nz * nz, 1, 1e-9), 'normal tilts towards the dent: ' .. nx)
s = {L.sample(l, x - 0.3, y, z)}
nx = L.bendNormal(0, 1, 0, s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12])
check(nx > 0.01, 'and to +x on the -x side: ' .. nx)
-- the offsets add up, each atom to at most maxOffset
for _ = 1, 10 do L.dent(l, x, y, z, 0, -1, 0, 0.1, 0.6, 0.3) end
_, oy = L.sample(l, x, y, z)
check(near(oy, -0.3), 'capped at maxOffset: ' .. oy)
-- springs spread a dent to the atoms around it
local l2 = L.new({-1, 0, -2}, {1, 1.2, 2}, 0.25)
local edge = {L.nodePos(l2, 4, l2.n[2] - 1, 10)}
L.dent(l2, x, y, z, 0, -1, 0, 0.1, 0.2, 0.5)
check(L.sample(l2, edge[1], edge[2], edge[3]) == nil, 'small dent: two atoms away untouched')
local l3 = L.new({-1, 0, -2}, {1, 1.2, 2}, 0.25)
L.dent(l3, x, y, z, 0, -1, 0, 0.1, 0.2, 0.5, 3, 0.35)
local _, e = L.sample(l3, edge[1], edge[2], edge[3])
check(e and e < 0, 'springs: spread to it: ' .. tostring(e))
local _, c = L.sample(l3, x, y, z)
check(c > -0.1 and c < 0, 'springs: the centre eases off: ' .. tostring(c))
-- an earlier dent stays as it is when another one lands elsewhere with springs
local _, before = L.sample(l3, x, y, z)
local fx, fy, fz = L.nodePos(l3, 4, 0, 1)
L.takeChanged(l3)
L.dent(l3, fx, fy, fz, 0, 1, 0, 0.1, 0.2, 0.5, 3, 0.35)
local _, after = L.sample(l3, x, y, z)
check(before == after, 'springs only spread the new dent')
local cells = 0 for _ in pairs(L.takeChanged(l3)) do cells = cells + 1 end
check(cells > 0 and cells < (l3.n[1] - 1) * (l3.n[2] - 1) * (l3.n[3] - 1) / 4, 'only cells near the new dent change: ' .. cells)
L.reset(l2)
check(L.sample(l2, x, y, z) == nil, 'reset')
print(fails == 0 and 'lattice tests passed' or ('lattice tests: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
