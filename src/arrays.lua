-- Compact per-vertex arrays (0-based, zeroed): FFI floats and ints, a few bytes a value where a Lua table takes
-- 16. With every car in a session read, that's the difference between tens of megabytes a car and a few.
local ffi = rawget(_G, 'ffi') or require('ffi')
local M = {}
function M.floats(n) return ffi.new('float[?]', math.max(n, 1)) end
function M.ints(n, fill)
  local a = ffi.new('int32_t[?]', math.max(n, 1))
  if fill and fill ~= 0 then for i = 0, n - 1 do a[i] = fill end end
  return a
end
return M
