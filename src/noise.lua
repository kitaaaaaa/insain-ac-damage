-- 3D gradient noise (Ken Perlin's improved noise, 2002) for crunchy damage: noise() in about -1..1, fbm() adds
-- octaves for detail at several sizes, ridged() makes sharp creases of it, and withGrad() also returns the
-- gradient (finite differences) for bending normals. Deterministic: a seed picks the permutation. Plain Lua, no closures in the hot paths.
local M = {}

local perm = {}

-- Shuffles the permutation table with a simple LCG from the seed.
function M.seed(seed)
  local p = {}
  for i = 0, 255 do p[i] = i end
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  for i = 255, 1, -1 do
    s = (s * 16807) % 2147483647
    local j = s % (i + 1)
    p[i], p[j] = p[j], p[i]
  end
  for i = 0, 511 do perm[i] = p[i % 256] end
end
M.seed(1)

local floor = math.floor

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end

-- Perlin's 16 gradient directions (h % 16), as a table: no branches, so LuaJIT compiles noise() well
local GX = {[0] = 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0, 1, 0, -1, 0}
local GY = {[0] = 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1, 1, -1, 1, -1}
local GZ = {[0] = 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1, 0, 1, 0, -1}
local function grad(h, x, y, z)
  h = h % 16
  return GX[h] * x + GY[h] * y + GZ[h] * z
end

function M.noise(x, y, z)
  local X, Y, Z = floor(x), floor(y), floor(z)
  x, y, z = x - X, y - Y, z - Z
  X, Y, Z = X % 256, Y % 256, Z % 256
  local u, v, w = fade(x), fade(y), fade(z)
  local p = perm
  local A, B = p[X] + Y, p[X + 1] + Y
  local AA, AB, BA, BB = p[A] + Z, p[A + 1] + Z, p[B] + Z, p[B + 1] + Z
  local x1, y1, z1 = x - 1, y - 1, z - 1
  local g000, g100 = grad(p[AA], x, y, z), grad(p[BA], x1, y, z)
  local g010, g110 = grad(p[AB], x, y1, z), grad(p[BB], x1, y1, z)
  local g001, g101 = grad(p[AA + 1], x, y, z1), grad(p[BA + 1], x1, y, z1)
  local g011, g111 = grad(p[AB + 1], x, y1, z1), grad(p[BB + 1], x1, y1, z1)
  local a = g000 + u * (g100 - g000)
  local b = g010 + u * (g110 - g010)
  local c = g001 + u * (g101 - g001)
  local d = g011 + u * (g111 - g011)
  local e = a + v * (b - a)
  local f = c + v * (d - c)
  return e + w * (f - e)
end

-- Octaves of noise, each twice the frequency and `gain` the amplitude of the last, normalised to about -1..1.
function M.fbm(x, y, z, octaves, gain)
  local sum, amp, norm, f = 0, 1, 0, 1
  for _ = 1, octaves do
    sum = sum + amp * M.noise(x * f, y * f, z * f)
    norm = norm + amp
    amp, f = amp * gain, f * 2.03  -- not exactly 2: the octaves' grids don't line up
  end
  return sum / norm
end

-- Ridged noise: sharp folds where the noise crosses zero, like crumpled sheet metal; about -1..1. Each octave
-- (1 - 2|noise|), squared keeping its sign, so the creases are sharp and the metal between them flatter.
function M.ridged(x, y, z, octaves, gain)
  local sum, amp, norm, f = 0, 1, 0, 1
  for _ = 1, octaves do
    local v = 1 - 2 * math.abs(M.noise(x * f, y * f, z * f))
    sum = sum + amp * v * math.abs(v)  -- squared, keeping its sign
    norm = norm + amp
    amp, f = amp * gain, f * 2.03
  end
  return sum / norm
end

-- A noise function and its gradient (per unit of x, y, z), by finite differences over `eps`.
function M.withGrad(fn, x, y, z, octaves, gain, eps)
  local n = fn(x, y, z, octaves, gain)
  local gx = (fn(x + eps, y, z, octaves, gain) - n) / eps
  local gy = (fn(x, y + eps, z, octaves, gain) - n) / eps
  local gz = (fn(x, y, z + eps, octaves, gain) - n) / eps
  return n, gx, gy, gz
end

function M.fbmGrad(x, y, z, octaves, gain, eps) return M.withGrad(M.fbm, x, y, z, octaves, gain, eps) end

return M
