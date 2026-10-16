-- A mock of the CSP calls the app makes (scene references with meshes and vertices, matrices, rays, a car),
-- with a fake car: a box body (subdivided, outward normals) and a panel under a rotated child node, the car
-- turned and moved in the world. local H = require('tests/scene_mock')(opts); H.load(); H.frame()
return function(opts)
  opts = opts or {}
  local H = {logs = {}, altered = {}, buttons = {}, keys = {}}
  -- vectors
  local V = {}
  V.__index = V
  function vec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, V) end
  function vec2(x, y) return {x = x or 0, y = y or 0} end
  function V:set(x, y, z) if type(x) == 'table' then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end return self end
  function V:clone() return vec3(self.x, self.y, self.z) end
  function V:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
  function V:lengthSquared() return self:dot(self) end
  function V:length() return math.sqrt(self:dot(self)) end
  function V:normalize() local l = self:length() if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end return self end
  V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
  V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
  V.__mul = function(a, b) if type(a) == 'number' then a, b = b, a end return vec3(a.x * b, a.y * b, a.z * b) end
  V.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end
  function rgbm(r, g, b, m) return {r, g, b, m} end
  -- rigid transforms: rows of a rotation r (3x3) and a translation t
  local M = {}
  M.__index = M
  local function mat(r, t) return setmetatable({r = r, t = t}, M) end
  function H.rotY(a, tx, ty, tz)
    local c, s = math.cos(a), math.sin(a)
    return mat({{c, 0, s}, {0, 1, 0}, {-s, 0, c}}, {tx or 0, ty or 0, tz or 0})
  end
  function M:transformVector(v) local r = self.r return vec3(r[1][1] * v.x + r[1][2] * v.y + r[1][3] * v.z, r[2][1] * v.x + r[2][2] * v.y + r[2][3] * v.z, r[3][1] * v.x + r[3][2] * v.y + r[3][3] * v.z) end
  function M:transformPoint(v) local p = self:transformVector(v) return vec3(p.x + self.t[1], p.y + self.t[2], p.z + self.t[3]) end
  function M:inverse()
    local r = self.r
    local rt = {{r[1][1], r[2][1], r[3][1]}, {r[1][2], r[2][2], r[3][2]}, {r[1][3], r[2][3], r[3][3]}}
    local m = mat(rt, {0, 0, 0})
    local t = m:transformVector(vec3(self.t[1], self.t[2], self.t[3]))
    m.t = {-t.x, -t.y, -t.z}
    return m
  end
  function M:clone() return mat({{unpack(self.r[1])}, {unpack(self.r[2])}, {unpack(self.r[3])}}, {unpack(self.t)}) end
  function H.compose(a, b) -- a after b
    local m = mat({}, {0, 0, 0})
    for i = 1, 3 do
      local col = {}
      m.r[i] = {}
    end
    for c = 1, 3 do
      local e = vec3(c == 1 and 1 or 0, c == 2 and 1 or 0, c == 3 and 1 or 0)
      local v = a:transformVector(b:transformVector(e))
      m.r[1][c], m.r[2][c], m.r[3][c] = v.x, v.y, v.z
    end
    local o = a:transformPoint(b:transformPoint(vec3()))
    m.t = {o.x, o.y, o.z}
    return m
  end
  -- vertex buffers: FFI arrays with CSP's vertex layout (lua_mesh_vertex: vec3 pos, normal; vec2 uv; vec3 extras),
  -- 0-based raw, copied as memory like CSP does
  local ffi = require('ffi')
  pcall(ffi.cdef, [[ typedef struct { float x, y, z; } mock_vec3; typedef struct { mock_vec3 pos; mock_vec3 normal; float uv[2]; mock_vec3 extras; } mock_vertex; ]])
  local function buffer(list, n)
    n = n or #list
    local b = {raw = ffi.new('mock_vertex[?]', math.max(n, 1)), n = n}
    for i, v in ipairs(list) do
      local r = b.raw[i - 1]
      r.pos.x, r.pos.y, r.pos.z, r.normal.x, r.normal.y, r.normal.z = v[1], v[2], v[3], v[4], v[5], v[6]
    end
    function b:size() return self.n end
    function b:clone()
      local c = buffer({}, self.n)
      ffi.copy(c.raw, self.raw, ffi.sizeof('mock_vertex') * self.n)
      return c
    end
    return b
  end
  H.buffer = buffer
  -- the fake car: a box 1.8 x 1.2 x 4.4 (y from 0), faces subdivided n x n
  local function boxSurface(n, sx, sy, sz)
    local list = {}
    local faces = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
    for _, f in ipairs(faces) do
      for a = 0, n do for b = 0, n do
        local u, v = a / n * 2 - 1, b / n * 2 - 1
        local p
        if f[1] ~= 0 then p = {f[1], u, v} elseif f[2] ~= 0 then p = {u, f[2], v} else p = {u, v, f[3]} end
        list[#list + 1] = {p[1] * sx / 2, p[2] * sy / 2 + sy / 2, p[3] * sz / 2, f[1], f[2], f[3]}
      end end
    end
    return list
  end
  H.bodyWorld = H.rotY(0.5, 100, 2, -50)  -- the car turned and moved
  local doorLocal = H.rotY(math.pi / 2, 0.9, 0.6, 0.3)  -- a panel under a rotated child node
  local nodes = {}
  local function node(name, world, parent) local n = {name = name, world = world, parent = parent, meshes = {}} nodes[name] = n return n end
  local root = node('carRoot:0', H.rotY(0))
  local body = node('BODYTR', H.bodyWorld, root)
  local door = node('DOOR', H.compose(H.bodyWorld, doorLocal), body)
  H.bodyMesh = {name = 'body', parent = body, vertices = buffer(boxSurface(opts.n or 20, 1.8, 1.2, 4.4))}
  H.doorMesh = {name = 'door', parent = door, vertices = buffer({{0, 0, 0, 1, 0, 0}, {0, 0.1, 0, 1, 0, 0}, {0.1, 0, 0, 1, 0, 0}})}
  body.meshes = {H.bodyMesh}
  door.meshes = {H.doorMesh}
  H.doorLocal = doorLocal
  -- scene references: a list of nodes or meshes
  local Ref = {}
  Ref.__index = Ref
  local function ref(items) return setmetatable({items = items}, Ref) end
  function Ref:size() return #self.items end
  function Ref:at(i) return ref({self.items[i]}) end
  function Ref:name(i) return self.items[i or 1].name end
  function Ref:findNodes(f) local out = {} for _, it in ipairs(self.items) do for _, n in pairs(nodes) do
    if n.name == f then local p = n.parent while p do if p == it then out[#out + 1] = n break end p = p.parent end end end end return ref(out) end
  function Ref:findMeshes(f)
    local out = {}
    for _, it in ipairs(self.items) do for _, n in pairs(nodes) do
      local p, under = n, false
      while p do if p == it then under = true break end p = p.parent end
      if under then for _, m in ipairs(n.meshes) do out[#out + 1] = m end end
    end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return ref(out)
  end
  function Ref:getVertices() local m = self.items[1] H.reads = H.reads + 1 return m and m.vertices:clone() end
  function Ref:alterVertices(v) local m = self.items[1] m.vertices = v:clone() H.altered[m.name] = (H.altered[m.name] or 0) + 1 return self end
  function Ref:getParent() return ref({self.items[1].parent}) end
  function Ref:getWorldTransformationRaw() return self.items[1].world end
  function Ref:isPhysicsOnlyMesh() return false end
  -- ray against the world-space box around the meshes (the fake car is a box)
  function Ref:raycast(ray)
    local mn, mx = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
    for _, m in ipairs(self.items) do
      local w = m.parent.world
      for i = 0, m.vertices.n - 1 do
        local p = w:transformPoint(m.vertices.raw[i].pos)
        mn = {math.min(mn[1], p.x), math.min(mn[2], p.y), math.min(mn[3], p.z)}
        mx = {math.max(mx[1], p.x), math.max(mx[2], p.y), math.max(mx[3], p.z)}
      end
    end
    -- slab test in the car's frame would be exact; the world AABB of a turned box is close enough to hit it
    local inv = H.bodyWorld:inverse()
    local o, d = inv:transformPoint(ray.pos), inv:transformVector(ray.dir)
    local bmin, bmax = {-0.9, 0, -2.2}, {0.9, 1.2, 2.2}
    local t0, t1 = 0, ray.length or 1e9
    for a, k in ipairs({'x', 'y', 'z'}) do
      if math.abs(d[k]) < 1e-9 then
        if o[k] < bmin[a] or o[k] > bmax[a] then return -1 end
      else
        local ta, tb = (bmin[a] - o[k]) / d[k], (bmax[a] - o[k]) / d[k]
        if ta > tb then ta, tb = tb, ta end
        t0, t1 = math.max(t0, ta), math.min(t1, tb)
        if t0 > t1 then return -1 end
      end
    end
    return t0
  end
  -- the car (AC: wheels 0 front-left, 1 front-right; in the fake car's frame left is +x)
  local car = {look = H.bodyWorld:transformVector(vec3(0, 0, 1)), up = vec3(0, 1, 0), velocity = vec3(), collisionDepth = 0,
    position = H.bodyWorld:transformPoint(vec3(0, 0.5, 0)),
    wheels = {[0] = {position = H.bodyWorld:transformPoint(vec3(0.8, 0.3, 1.4))}, {position = H.bodyWorld:transformPoint(vec3(-0.8, 0.3, 1.4))}}}
  H.car = car
  local sim = {focusedCar = 0, isPaused = false}
  H.sim = sim
  local storage = {}
  H.storage = storage
  H.jumps = {}
  ac = {
    storage = function(d) for k, v in pairs(d) do if storage[k] == nil then storage[k] = v end end return storage end,
    getSim = function() return sim end,
    getCar = function(i) return i == 0 and car or nil end,
    log = function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end H.logs[#H.logs + 1] = table.concat(t, ' ') end,
    findNodes = function(f) return ref({nodes[f]}) end,
    onCarJumped = function(i, cb) H.jumps[i] = cb end,
    isKeyDown = function(k) return H.keys[k] == true end,
    KeyIndex = {Control = 0x11, LeftButton = 0x01},
  }
  render = {
    createRay = function(pos, dir, length) return {pos = pos, dir = dir, length = length} end,
    createMouseRay = function() return H.mouseRay end,
  }
  ui = {
    text = function() end, textColored = function() end, textWrapped = function() end, separator = function() end,
    sameLine = function() end, button = function(label) return H.buttons[label] == true end,
    slider = function(_, v) return v end, checkbox = function() return false end,
  }
  os.preciseClock = os.clock
  script = {}
  H.reads = 0
  function H.load()
    __dirname = opts.dir or os.getenv('TMPDIR') or '/tmp'
    __softdamageTest = {}
    dofile('softdamage.lua')
    H.state = __softdamageTest
  end
  function H.frame(dt) script.update(dt or 1 / 60) script.windowMain(dt or 1 / 60) script.windowSettings(dt or 1 / 60) end
  function H.settle(max) for _ = 1, max or 2000 do H.frame() if #H.state.jobs == 0 then return true end end return false end
  return H
end
