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
  function V:distanceSquared(o) return (self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2 end
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
    function b:copy()  -- the mock's own copies (what getVertices does natively)
      local c = buffer({}, self.n)
      ffi.copy(c.raw, self.raw, ffi.sizeof('mock_vertex') * self.n)
      return c
    end
    -- in game, VertexBuffer:clone() crashed AC: the app must not use it
    function b:clone()
      if H.noClone then error('VertexBuffer:clone() called by the app (it crashed AC in game)', 2) end
      return self:copy()
    end
    return b
  end
  H.buffer = buffer
  -- opts.size: the whole car scaled (0.12: a model car half a metre long)
  local S = opts.size or 1
  H.size = S
  local function sc(list) for _, v in ipairs(list) do v[1], v[2], v[3] = v[1] * S, v[2] * S, v[3] * S end return list end
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
  local doorLocal = H.rotY(math.pi / 2, 0.9 * S, 0.6 * S, 0.3 * S)  -- a panel under a rotated child node
  local nodes = {}
  local function node(name, world, parent) local n = {name = name, world = world, parent = parent, meshes = {}} nodes[#nodes + 1] = n return n end
  local root = node('carRoot:0', H.rotY(0))
  local body = node('BODYTR', H.bodyWorld, root)
  local door = node('DOOR', H.compose(H.bodyWorld, doorLocal), body)
  H.bodyMesh = {name = 'body', parent = body, vertices = buffer(boxSurface(opts.n or 20, 1.8 * S, 1.2 * S, 4.4 * S))}
  H.doorMesh = {name = 'door', parent = door, vertices = buffer(sc({{0, 0, 0, 1, 0, 0}, {0, 0.1, 0, 1, 0, 0}, {0.1, 0, 0, 1, 0, 0}}))}
  body.meshes = {H.bodyMesh}
  door.meshes = {H.doorMesh}
  if opts.farMesh then  -- (as some cars have: a mesh hundreds of metres from the body, under BODYTR)
    H.farMesh = {name = 'far_away_plane', parent = body, vertices = buffer({{0, 0, 300, 0, 1, 0}, {1, 0, 300, 0, 1, 0}, {0, 0, 301, 0, 1, 0}})}
    body.meshes[#body.meshes + 1] = H.farMesh
  end
  -- not bodywork: the driver (by its node) and a gauge needle (by its name)
  local driver = node('DRIVER:DRIVER', H.bodyWorld, body)
  H.driverMesh = {name = 'DRIVER:suit', parent = driver, vertices = buffer(sc({{0, 0.5, 0, 0, 1, 0}, {0.1, 0.5, 0, 0, 1, 0}, {0, 0.6, 0, 0, 1, 0}}))}
  driver.meshes = {H.driverMesh}
  H.needleMesh = {name = 'car_needle_speed', parent = body, vertices = buffer(sc({{0, 0.7, 1, 0, 1, 0}, {0.01, 0.7, 1, 0, 1, 0}, {0, 0.71, 1, 0, 1, 0}}))}
  body.meshes[#body.meshes + 1] = H.needleMesh
  -- the interior: a door card 0.15 m in from the left (+x) side, facing the cabin, under COCKPIT_HR; and the
  -- steering wheel (left still)
  local cockpit = node('COCKPIT_HR', H.bodyWorld, body)
  local card = {}
  for a = 0, 10 do for b = 0, 10 do card[#card + 1] = {0.75, 0.3 + a * 0.05, -0.5 + b * 0.1, -1, 0, 0} end end
  H.cardMesh = {name = 'door_card', parent = cockpit, vertices = buffer(sc(card))}
  cockpit.meshes = {H.cardMesh}
  local steer = node('STEER_HR', H.bodyWorld, body)
  H.steerMesh = {name = 'steering_wheel', parent = steer, vertices = buffer(sc({{0.4, 0.8, 0.6, 0, 0, -1}, {0.3, 0.8, 0.6, 0, 0, -1}, {0.35, 0.9, 0.6, 0, 0, -1}}))}
  steer.meshes = {H.steerMesh}
  -- outside BODYTR, as some cars have them: a headlight lens on a node of its own (fixed to the body), and a
  -- wheel (moves on its own: left alone)
  H.lightsNode = node('LIGHTS', H.bodyWorld, root)
  local lens = {}
  for a = 0, 4 do for b = 0, 4 do lens[#lens + 1] = {0.4 + a * 0.05, 0.6 + b * 0.05, 2.19, 0, 0, 1} end end
  H.lensMesh = {name = 'headlight_glass', parent = H.lightsNode, vertices = buffer(sc(lens))}
  H.lightsNode.meshes = {H.lensMesh}
  local wheel = node('WHEEL_LF', H.compose(H.bodyWorld, H.rotY(0, 0.8 * S, 0.3 * S, 1.4 * S)), root)
  H.wheelMesh = {name = 'tyre_lf', parent = wheel, vertices = buffer(sc({{0, 0, 0, 1, 0, 0}, {0, 0.1, 0, 1, 0, 0}, {0, 0, 0.1, 1, 0, 0}}))}
  if opts.replacementWheel then
    -- a wheel CSP put in from an extension's model, hanging under BODYTR with a name of its own: a ring 0.3 m
    -- round (the tyre's 0.33), 0.2 m wide, on the front left hub
    local ring = {}
    for a = 0, 23 do
      local t = a / 24 * 2 * math.pi
      for _, x in ipairs({0.7, 0.8, 0.9}) do
        ring[#ring + 1] = {x, 0.3 + 0.3 * math.cos(t), 1.4 + 0.3 * math.sin(t), 0, math.cos(t), math.sin(t)}
      end
    end
    H.replWheel = {name = 'ext_wheel_fl_model', parent = body, vertices = buffer(sc(ring))}
    body.meshes[#body.meshes + 1] = H.replWheel
  end
  wheel.meshes = {H.wheelMesh}
  -- a second car (opts.cars = 2): the same box body, 30 m away, turned the other way
  H.body2World = H.rotY(-1.0, 130, 2, -50)
  local root2 = node('carRoot:1', H.rotY(0))
  local body2 = node('BODYTR', H.body2World, root2)
  H.body2Mesh = {name = 'body', parent = body2, vertices = buffer(boxSurface(opts.n or 20, 1.8, 1.2, 4.4))}
  body2.meshes = {H.body2Mesh}
  local track = node('trackRoot:yes', H.rotY(0))
  H.trackMesh = {name = 'road', parent = track, vertices = buffer({{0, 0, 0, 0, 1, 0}, {1, 0, 0, 0, 1, 0}, {0, 0, 1, 0, 1, 0}})}
  track.meshes = {H.trackMesh}
  H.created = {}
  H.doorLocal = doorLocal
  -- scene references: a list of nodes or meshes
  local Ref = {}
  Ref.__index = Ref
  local function ref(items) return setmetatable({items = items}, Ref) end
  function Ref:size() return #self.items end
  function Ref:at(i) return ref({self.items[i]}) end
  function Ref:name(i) return self.items[i or 1].name end
  function Ref:findNodes(f) local out = {} for _, it in ipairs(self.items) do for _, n in ipairs(nodes) do
    if n.name == f then local p = n.parent while p do if p == it then out[#out + 1] = n break end p = p.parent end end end end return ref(out) end
  function Ref:findMeshes(f)
    local out = {}
    for _, it in ipairs(self.items) do for _, n in ipairs(nodes) do
      local p, under = n, false
      while p do if p == it then under = true break end p = p.parent end
      if under then for _, m in ipairs(n.meshes) do out[#out + 1] = m end end
    end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return ref(out)
  end
  function Ref:getVertices() local m = self.items[1] H.reads = H.reads + 1 return m and m.vertices:copy() end
  function Ref:alterVertices(v) local m = self.items[1] m.vertices = v:copy() H.altered[m.name] = (H.altered[m.name] or 0) + 1 return self end
  function Ref:getParent() return ref({self.items[1].parent}) end
  function Ref:materialName() return 'mat_' .. self.items[1].name end
  function Ref:getWorldTransformationRaw() return self.items[1].world end
  function Ref:isPhysicsOnlyMesh() return false end
  function Ref:getIndices() local m = self.items[1] local b = {n = m.vertices.n} function b:size() return self.n end return b end
  function Ref:createMesh(name, material, vertices, indices, keepAlive, moveData)
    local parent = self.items[1]
    assert(vertices.n > 0 and indices:size() > 0, 'createMesh args')
    local m = {name = name, parent = parent, vertices = vertices:copy(), created = true, visible = true}
    parent.meshes[#parent.meshes + 1] = m
    H.created[#H.created + 1] = m
    return ref({m})
  end
  function Ref:assignMaterialFrom(other) self.items[1].material = other.items[1].name return self end
  function Ref:setVisible(v) for _, m in ipairs(self.items) do m.hidden = not v end return self end
  function Ref:dispose()
    for _, m in ipairs(self.items) do
      m.disposed = true
      for i, x in ipairs(m.parent.meshes) do if x == m then table.remove(m.parent.meshes, i) break end end
    end
    self.items = {}
  end
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
    local bw = H.bodyWorld
    local p = self.items[1] and self.items[1].parent
    while p do if p.name == 'BODYTR' then bw = p.world break end p = p.parent end
    local inv = bw:inverse()
    local o, d = inv:transformPoint(ray.pos), inv:transformVector(ray.dir)
    local bmin, bmax = {-0.9 * S, 0, -2.2 * S}, {0.9 * S, 1.2 * S, 2.2 * S}
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
    position = H.bodyWorld:transformPoint(vec3(0, 0.5 * S, 0)),
    wheels = {[0] = {position = H.bodyWorld:transformPoint(vec3(0.8 * S, 0.3 * S, 1.4 * S))}, {position = H.bodyWorld:transformPoint(vec3(-0.8 * S, 0.3 * S, 1.4 * S))}}}
  if S ~= 1 then for w = 0, 1 do car.wheels[w].tyreRadius, car.wheels[w].tyreWidth = 0.33 * S, 0.25 * S end end
  car.distanceToCamera, car.isConnected, car.aabbSize = 5, true, vec3(1.8 * S, 1.2 * S, 4.4 * S)
  car.aabbCenter, car.bodyTransform = vec3(0, 0.6 * S, 0), H.bodyWorld
  H.car = car
  local car2 = {look = H.body2World:transformVector(vec3(0, 0, 1)), up = vec3(0, 1, 0), velocity = vec3(), collisionDepth = 0,
    position = H.body2World:transformPoint(vec3(0, 0.5, 0)), distanceToCamera = 30, isConnected = true, aabbSize = vec3(1.8, 1.2, 4.4),
    aabbCenter = vec3(0, 0.6, 0), bodyTransform = H.body2World,
    wheels = {[0] = {position = H.body2World:transformPoint(vec3(0.8, 0.3, 1.4))}, {position = H.body2World:transformPoint(vec3(-0.8, 0.3, 1.4))}}}
  H.car2 = car2
  H.detailed = {}
  local sim = {focusedCar = 0, isPaused = false, carsCount = opts.cars or 1}
  H.sim = sim
  local storage = {}
  H.storage = storage
  H.jumps = {}
  ac = {
    storage = function(d) for k, v in pairs(d) do if storage[k] == nil then storage[k] = v end end return storage end,
    getSim = function() return sim end,
    getCar = function(i) if i == 0 then return car elseif i == 1 and (opts.cars or 1) > 1 then return car2 end return nil end,
    log = function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end H.logs[#H.logs + 1] = table.concat(t, ' ') end,
    findNodes = function(f) for _, n in ipairs(nodes) do if n.name == f then return ref({n}) end end return ref({}) end,
    forceDetailedCarLOD = function(i) H.detailed[i] = (H.detailed[i] or 0) + 1 end,
    onCarJumped = function(i, cb) H.jumps[i] = cb end,
    onRelease = function(cb) H.release = cb end,
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
    combo = function(_, selected) return selected end, ComboFlags = {None = 0},
  }
  os.preciseClock = os.clock
  script = {}
  H.reads = 0
  function H.load()
    __dirname = opts.dir or os.getenv('TMPDIR') or '/tmp'
    __softdamageTest = {}
    H.noClone = true
    dofile('softdamage.lua')
    H.state = __softdamageTest
  end
  function H.frame(dt) script.update(dt or 1 / 60) script.windowMain(dt or 1 / 60) script.windowSettings(dt or 1 / 60) end
  function H.settle(max) for _ = 1, max or 2000 do H.frame() if #H.state.jobs == 0 and not H.state.busy() then return true end end return false end
  return H
end
