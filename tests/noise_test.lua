-- luajit tests/noise_test.lua   (from the app folder)
package.path = './?.lua;' .. package.path
local N = require('src/noise')
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
N.seed(7)
local mn, mx, sum, sum2, cnt = 1e9, -1e9, 0, 0, 0
for i = 1, 20000 do
  local x, y, z = i * 0.173, i * 0.071, i * 0.391
  local v = N.fbm(x, y, z, 3, 0.5)
  mn, mx, sum, sum2, cnt = math.min(mn, v), math.max(mx, v), sum + v, sum2 + v * v, cnt + 1
end
local mean, sd = sum / cnt, math.sqrt(sum2 / cnt - (sum / cnt) ^ 2)
check(mn > -1.05 and mx < 1.05, ('range %.3f..%.3f'):format(mn, mx))
check(math.abs(mean) < 0.05 and sd > 0.1, ('mean %.3f, spread %.3f'):format(mean, sd))
check(N.noise(3, 4, 5) == 0, 'zero on lattice points')
-- continuous: a small step changes it a little
check(math.abs(N.fbm(1.234, 2.345, 3.456, 3, 0.5) - N.fbm(1.2345, 2.345, 3.456, 3, 0.5)) < 0.01, 'continuous')
-- deterministic per seed, different between seeds
local a = N.fbm(1.5, 2.5, 3.7, 3, 0.5)
N.seed(7) check(N.fbm(1.5, 2.5, 3.7, 3, 0.5) == a, 'same seed, same noise')
N.seed(8) check(N.fbm(1.5, 2.5, 3.7, 3, 0.5) ~= a, 'other seed, other noise')
-- the gradient matches the slope
N.seed(7)
local n, gx = N.fbmGrad(0.7, 1.3, 2.1, 3, 0.5, 1e-4)
local slope = (N.fbm(0.7 + 0.01, 1.3, 2.1, 3, 0.5) - N.fbm(0.7 - 0.01, 1.3, 2.1, 3, 0.5)) / 0.02
check(math.abs(gx - slope) < 0.05 * math.max(1, math.abs(slope)), ('gradient %.3f vs slope %.3f'):format(gx, slope))
-- ridged: in range, and sharper (bigger slopes for the same scale) than fbm
local rmn, rmx, rs, fs = 1e9, -1e9, 0, 0
for i = 1, 5000 do
  local x, y, z = i * 0.137, i * 0.059, i * 0.311
  local r = N.ridged(x, y, z, 3, 0.5)
  rmn, rmx = math.min(rmn, r), math.max(rmx, r)
  local _, gx, gy, gz = N.withGrad(N.ridged, x, y, z, 3, 0.5, 1e-3)
  local _, hx, hy, hz = N.withGrad(N.fbm, x, y, z, 3, 0.5, 1e-3)
  rs, fs = rs + math.sqrt(gx * gx + gy * gy + gz * gz), fs + math.sqrt(hx * hx + hy * hy + hz * hz)
end
check(rmn >= -1.0001 and rmx <= 1.0001 and rmx - rmn > 0.8, ('ridged range %.3f..%.3f'):format(rmn, rmx))
check(rs > fs * 1.3, ('ridged is sharper: mean slope %.2f vs %.2f'):format(rs / 5000, fs / 5000))
print(fails == 0 and 'noise tests passed' or ('noise tests: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
