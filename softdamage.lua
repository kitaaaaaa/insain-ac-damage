-- Soft Body Damage (prototype): visual dents on any car, no per-car setup. The car's body meshes (under its
-- BODYTR node) follow "atoms": by default a car-shaped hull of them, built from the body, with every vertex
-- pinned to the nearest hull triangles the way 1nsane did it (src/hull.lua); or a box lattice of them (a
-- free-form deformation, src/lattice.lua). Dents push atoms in, springs between them spread it. Visual only:
-- AC's physics and collisions don't change.
-- This first version is for finding out what works in game: dents from buttons, Ctrl+click on the car, and
-- (experimental) crashes; timings are shown in the window.
local lattice = require('src/lattice')
local hull = require('src/hull')
local arrays = require('src/arrays')
local noise = require('src/noise')

local settings = ac.storage{
  depth = 0.12,        -- test dent: metres
  radius = 0.45,       -- test dent: metres
  atoms = 'hull',      -- 'hull' (car-shaped, on the body's outside, 1nsane's way) or 'box' (a lattice over its box)
  hullRing = 0.3,      -- hull: metres between rings of atoms along the car (applies on rebuild)
  hullAround = 20,     -- hull: atoms around each ring (applies on rebuild)
  spacing = 0.35,      -- box lattice: metres between atoms (applies on rebuild)
  springs = 2,         -- spring passes after each dent (0 = a dent stays exactly where it's pushed)
  springLimits = true, -- (the hull) 1nsane's spring limits: the metal between atoms stretches and squashes only so far
  stretchLimit = 1.05, -- an edge stretches to this times its length at most: sheet metal hardly stretches, a deep
                       -- dent drags the metal around it in
  squashLimit = 0.5,   -- and squashes to this at most (1nsane's own limits were 1.5 and 0.5)
  foldAt = 0.9,        -- squashed past this, the metal folds: crunch from the squeeze
  foldCrunch = 1,      -- metres of crunch per metre squashed past foldAt (times the crunch setting)
  maxOffset = 0.5,     -- how far an atom can be pushed in total
  maxBodyIn = 0.1524,  -- the most any spot of the body moves (half a foot)
  maxInteriorIn = 0.0762, -- the most any spot of the interior moves (a quarter foot)
  interiorShare = 0.5, -- the interior moves this much of what the body around it does
  frontGive = 1.5,     -- how much each way gives: the front (a crumple zone) most, the sides (door beams) least
  rearGive = 1.2,
  sideGive = 0.6,      -- (the doors: beams in them; the sides ramp up to endGive towards the ends)
  endGive = 1.3,       -- the front and rear quarters, pushed sideways: crumple zones, no door beams
  roofGive = 0.8,
  crunch = 1,          -- crunchy damage: noise on dented metal, more the harder the hit (0 = smooth dents)
  crunchSize = 0.25,   -- metres: the size of the biggest creases (finer ones on top)
  crunchStyle = 'creases', -- 'creases' (ridged noise: sharp folds, like crumpled metal) or 'hammered' (bumps)
  maxCrunch = 0.06,    -- metres: the most the crunch moves the metal
  readWatched = true,  -- read cars without pressing the button: the watched one, and (allCars) the others
  allCars = true,      -- every car in the session within readDistance, not just the watched one
  readDistance = 100,  -- metres from the camera
  maxVertices = 1000000, -- no more cars read once this many vertices are (memory: about 150 bytes each, and
                       -- AC's copies); the watched car always is
  keepDetailed = true, -- damaged cars keep their detailed model (the one with the dents) up to detailedDistance
  detailedDistance = 60,
  detailedMax = 3,     -- ... for this many damaged cars at most, the nearest (each costs drawing time)
  method = 'direct',   -- how dents are shown: 'direct' (the car's own meshes changed) or 'copy' (our own copies
                       -- of the meshes, the originals hidden: createMesh crashed AC in test C)
  outsideBody = true,  -- also dent the car's meshes outside BODYTR (lights, glass, trim), unless on moving parts
  crashDents = true,   -- dents from crashes
  crashScale = 1,
  budgetMs = 4,        -- work per frame on dents (re-skinning), first
  setupBudgetMs = 2,   -- then on reading cars
  sendBudget = 150000, -- vertices sent to AC a frame at most (alterVertices), the rest the next
}

local sim = ac.getSim()
local PACK = 16777216  -- (mesh, vertex) pairs in one number: mesh * PACK + vertex
local function log(...) ac.log('[softdamage]', ...) end

-- A trace of every call into CSP, one line at a time to a file closed after each line, so that if AC crashes
-- the file's last line shows where (softdamage_trace.txt in this app's folder).
local tracePath = __dirname .. '/softdamage_trace.txt'
local function trace(fmt, ...)
  local line = select('#', ...) > 0 and fmt:format(...) or fmt
  log(line)
  local ok, f = pcall(io.open, tracePath, 'a')
  if ok and f then f:write(os.date('%H:%M:%S '), line, '\n') f:close() end
end
do
  local ok, f = pcall(io.open, tracePath, 'w')
  if ok and f then f:write(os.date('%H:%M:%S '), 'app loaded\n') f:close() end
end
local function nowMs() return os.preciseClock() * 1000 end

-- ---------------------------------------------------------------------------------------------
-- A car's deformable body
local cars = {}   -- car index -> body
local jobs = {}   -- coroutines doing work over frames: {co, name}
local function totalVertices()
  local n = 0
  for _, b in pairs(cars) do n = n + (b.vertices or 0) end
  return n
end

-- The background work, a frame at a time: dents first (re-skinning: what you see), up to budgetMs; then reading
-- cars, up to setupBudgetMs (it can wait).
local jobBudget = 4
local function runPhase(setup, ms)
  local t0 = nowMs()
  jobBudget = ms
  local k = 1
  while k <= #jobs and nowMs() - t0 < ms do
    local j = jobs[k]
    if (j.setup == true) ~= setup then
      k = k + 1
    else
      local ok, err = coroutine.resume(j.co, t0)
      if not ok then log(j.name .. ': ' .. tostring(err)) j.body.error = tostring(err) table.remove(jobs, k)
      elseif coroutine.status(j.co) == 'dead' then table.remove(jobs, k)
      else break end  -- (it yielded: the budget's used)
    end
  end
end
local function runJobs()
  runPhase(false, settings.budgetMs)
  runPhase(true, settings.setupBudgetMs)
end
-- yields when the frame's budget is used up
local function budget(t0) if nowMs() - t0 > jobBudget then t0 = coroutine.yield() end return t0 end

-- What a mesh is, by AC's node names: 'skip' for the driver, the steering wheel and gauge needles (they never
-- move; CSP animates some of them), 'interior' for the cockpit (it moves a little with the body), or nil for
-- bodywork. Returns the kind and the name that decided it.
local function partKind(ref, meshName)
  if meshName:lower():find('needle', 1, true) then return 'skip', 'needle' end
  local interior
  local node = ref:getParent()
  for _ = 1, 12 do
    if node:size() == 0 then break end
    local n = node:name()
    if n == 'BODYTR' then break end
    if n:find('^DRIVER') or n:find('^STEER_') or n:lower():find('needle', 1, true) then return 'skip', n end
    if n:find('^COCKPIT_') then interior = n end
    node = node:getParent()
  end
  if meshName:find('^DRIVER') or meshName:find('^STEER_') then return 'skip', meshName end
  if interior or meshName:find('^COCKPIT_') then return 'interior', interior or meshName end
  return nil
end

-- Parts outside BODYTR that move on their own (by their nodes' names): not dented. Anything else outside it
-- (lights, glass, trim some cars keep there) is read with the body.
local MOVING = {'WHEEL', 'SUSP', 'HUB', 'DISC', 'RIM', 'TYRE', 'TIRE', 'CALIPER', 'BRAKE', 'DAMPER', 'SHOCK',
  'SPRING', 'AXLE', 'ARM', 'STEER', 'DRIVER', 'WIPER', 'SHADOW', 'BLUR'}
local function movingPart(ref, meshName)
  local names = {meshName}
  local node = ref:getParent()
  for _ = 1, 12 do
    if node:size() == 0 then break end
    names[#names + 1] = node:name()
    node = node:getParent()
  end
  for _, n in ipairs(names) do
    local up = n:upper()
    for _, m in ipairs(MOVING) do if up:find(m, 1, true) then return n end end
  end
  return nil
end

-- Reads the body meshes of car i: their vertices in the body's own coordinates (BODYTR space), once.
local function setupCar(i)
  local body = {index = i, meshes = {}, vertices = 0, state = 'reading meshes', setupMs = 0, lastSkinMs = 0, dents = 0}
  cars[i] = body
  local co = coroutine.create(function(t0)
    local started = nowMs()
    trace('car %d: finding carRoot:%d', i, i)
    local root = ac.findNodes('carRoot:' .. i)
    trace('car %d: %d root nodes; finding BODYTR', i, root:size())
    local bodyNode = root:findNodes('BODYTR')
    trace('car %d: %d BODYTR nodes', i, bodyNode:size())
    if bodyNode:size() == 0 then body.state = 'no BODYTR node found' return end
    body.node = bodyNode
    local bodyWorld = bodyNode:getWorldTransformationRaw():clone()
    local invBody = bodyWorld:inverse()
    trace('car %d: body transform read; finding meshes', i)
    -- the meshes to read: everything under BODYTR, and (a setting) the car's other meshes that aren't on moving
    -- parts. body.parts says what became of each, for the window
    local list, under = {}, {}
    body.parts = {}
    local meshes = bodyNode:findMeshes('?')
    for m = 1, meshes:size() do
      list[#list + 1] = {ref = meshes:at(m), name = meshes:name(m)}
      under[meshes:name(m)] = true
    end
    trace('car %d: %d meshes under BODYTR', i, #list)
    if settings.outsideBody then
      local all = root:findMeshes('?')
      for m = 1, all:size() do
        local name = all:name(m)
        if not under[name] then
          local ref = all:at(m)
          local moving = movingPart(ref, name)
          if moving then
            body.parts[#body.parts + 1] = {name = name, status = 'outside BODYTR, on a moving part (' .. moving .. '): left alone'}
            trace('mesh "%s": outside BODYTR, on a moving part (%s): left alone', name, moving)
          else
            list[#list + 1] = {ref = ref, name = name, outside = true}
          end
        end
      end
      trace('car %d: %d meshes in all', i, #list)
    end
    body.meshCount = #list
    local min, max = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
    for m, item in ipairs(list) do
      local ref, name = item.ref, item.name
      body.reading = ('%d/%d %s'):format(m, body.meshCount, name)
      local kind, because = partKind(ref, name)
      local skip = kind == 'skip' and because
      local where = item.outside and 'outside BODYTR, ' or ''
      local status
      if skip then
        trace('mesh %d/%d "%s": skipped (%s)', m, body.meshCount, name, skip) body.skipped = (body.skipped or 0) + 1
        status = where .. 'left still (' .. skip .. ')'
      end
      if not skip then trace('mesh %d/%d "%s"%s: getVertices', m, body.meshCount, name, item.outside and ' (outside BODYTR)' or '') end
      local verts = not skip and ref:getVertices() or nil
      if not skip then
      trace('mesh %d/%d: %s', m, body.meshCount, verts and (verts:size() .. ' vertices') or 'no vertices')
      if not verts or verts:size() == 0 then status = where .. 'no vertices (getVertices gave none)'
      elseif ref:isPhysicsOnlyMesh() then status = where .. 'physics only (not drawn)' end
      if verts and verts:size() > 0 and not ref:isPhysicsOnlyMesh() then
        local parentNode = ref:getParent()
        local parentWorld = parentNode:getWorldTransformationRaw():clone()
        local invParent = parentWorld:inverse()
        -- mesh -> body: origin and the images of the unit vectors; body -> mesh for offsets and normals
        local function toBody(p) return invBody:transformPoint(parentWorld:transformPoint(p)) end
        local o = toBody(vec3(0, 0, 0))
        local ex, ey, ez = toBody(vec3(1, 0, 0)) - o, toBody(vec3(0, 1, 0)) - o, toBody(vec3(0, 0, 1)) - o
        local function toMesh(v) return invParent:transformVector(bodyWorld:transformVector(v)) end
        local bx, by, bz = toMesh(vec3(1, 0, 0)), toMesh(vec3(0, 1, 0)), toMesh(vec3(0, 0, 1))
        local mesh = {ref = ref, name = name, orig = verts, n = verts:size(), interior = kind == 'interior',  -- work: a copy made at the first dent
          px = arrays.floats(verts:size()), py = arrays.floats(verts:size()), pz = arrays.floats(verts:size()),
          nx = arrays.floats(verts:size()), ny = arrays.floats(verts:size()), nz = arrays.floats(verts:size()),
          moved = arrays.bytes(verts:size()), seen = arrays.ints(verts:size()),  -- (FFI: the GC doesn't walk them)
          toMesh = {bx.x, bx.y, bx.z, by.x, by.y, by.z, bz.x, bz.y, bz.z}}
        if item.outside then
          -- where its node sat on the body (its origin and two axes' ends), to tell if it moves after all
          mesh.outside = true
          mesh.parentNode = parentNode
          mesh.rest = {o, toBody(vec3(1, 0, 0)), toBody(vec3(0, 0, 1))}
        end
        status = where .. (mesh.interior and 'interior (moves ' .. math.floor(settings.interiorShare * 100 + 0.5) .. '%)' or 'body')
          .. ', ' .. verts:size() .. ' vertices'
        local raw = verts.raw
        local mmin, mmax = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
        for v = 0, mesh.n - 1 do
          local p, nn = raw[v].pos, raw[v].normal
          local x = o.x + ex.x * p.x + ey.x * p.y + ez.x * p.z
          local y = o.y + ex.y * p.x + ey.y * p.y + ez.y * p.z
          local z = o.z + ex.z * p.x + ey.z * p.y + ez.z * p.z
          mesh.px[v], mesh.py[v], mesh.pz[v] = x, y, z
          local qx = ex.x * nn.x + ey.x * nn.y + ez.x * nn.z
          local qy = ex.y * nn.x + ey.y * nn.y + ez.y * nn.z
          local qz = ex.z * nn.x + ey.z * nn.y + ez.z * nn.z
          local len = math.sqrt(qx * qx + qy * qy + qz * qz)
          if len > 0 then qx, qy, qz = qx / len, qy / len, qz / len end
          mesh.nx[v], mesh.ny[v], mesh.nz[v] = qx, qy, qz
          if x < mmin[1] then mmin[1] = x end if x > mmax[1] then mmax[1] = x end
          if y < mmin[2] then mmin[2] = y end if y > mmax[2] then mmax[2] = y end
          if z < mmin[3] then mmin[3] = z end if z > mmax[3] then mmax[3] = z end
          if v % 2000 == 0 then t0 = budget(t0) end
        end
        mesh.min, mesh.max = mmin, mmax
        body.meshes[#body.meshes + 1] = mesh
        item.mesh = mesh
        body.vertices = body.vertices + mesh.n
        trace('mesh %d/%d: read', m, body.meshCount)
      end
      end
      body.parts[#body.parts + 1] = {name = name, status = status or '?', mesh = item.mesh}
      t0 = budget(t0)
    end
    -- the car's box: AC's bounding box of the car (or, without one, around the middle of its meshes). Some cars
    -- have a mesh far from the body (hundreds of metres, in one test): left alone, or the hull would be built
    -- over all that space (tens of thousands of atoms) and a crash's lever arm would reach out to it
    local bmin, bmax
    local car = ac.getCar(i)
    local size, centre = car and car.aabbSize, car and car.aabbCenter
    if size and centre and car.bodyTransform and size.z > 1 and size.z < 30 and size.x > 0.5 and size.x < 15 then
      local c = invBody:transformPoint(car.bodyTransform:transformPoint(centre))
      bmin = {c.x - size.x / 2, c.y - size.y / 2, c.z - size.z / 2}
      bmax = {c.x + size.x / 2, c.y + size.y / 2, c.z + size.z / 2}
      trace('car %d: AC\'s box %.2f x %.2f x %.2f m', i, size.x, size.y, size.z)
    else
      local xs, ys, zs = {}, {}, {}
      for _, mesh in ipairs(body.meshes) do
        xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = (mesh.min[1] + mesh.max[1]) / 2, (mesh.min[2] + mesh.max[2]) / 2, (mesh.min[3] + mesh.max[3]) / 2
      end
      table.sort(xs) table.sort(ys) table.sort(zs)
      local mid = math.max(1, math.floor(#xs / 2 + 0.5))
      bmin, bmax = {xs[mid] - 1.5, ys[mid] - 1.5, zs[mid] - 3.5}, {xs[mid] + 1.5, ys[mid] + 1.5, zs[mid] + 3.5}
      trace('car %d: no box from AC: around the middle of its meshes', i)
    end
    local kept = {}
    for _, mesh in ipairs(body.meshes) do
      local far = 0
      for a = 1, 3 do
        local c = (mesh.min[a] + mesh.max[a]) / 2
        far = math.max(far, bmin[a] - 1 - c, c - bmax[a] - 1)
      end
      if far > 0 then
        trace('"%s": %.1f m outside the car\'s box: left alone', mesh.name, far)
        for _, part in ipairs(body.parts) do if part.mesh == mesh then part.status = ('%.1f m outside the car\'s box: left alone'):format(far) part.mesh = nil end end
        body.vertices = body.vertices - mesh.n
      else
        kept[#kept + 1] = mesh
        for a = 1, 3 do
          min[a] = math.min(min[a], mesh.min[a])
          max[a] = math.max(max[a], mesh.max[a])
        end
      end
    end
    body.meshes = kept
    if #body.meshes == 0 then body.state = 'no meshes with vertices under BODYTR' return end
    -- the box: the meshes', no more than 0.6 m past AC's
    for a = 1, 3 do
      min[a] = math.max(min[a], bmin[a] - 0.6) - 0.05
      max[a] = math.min(max[a], bmax[a] + 0.6) + 0.05
    end
    body.min, body.max = min, max
    body.noiseOffset = {math.random() * 200, math.random() * 200, math.random() * 200}  -- each car crumples its own way
    -- the vertices to redo when atoms move: per lattice cell, or per hull triangle (a list of mesh, vertex pairs)
    local users = {}
    local function use(key, mi, v)  -- (mesh, vertex) packed in one number
      local list = users[key]
      if not list then list = {} users[key] = list end
      list[#list + 1] = mi * PACK + v
    end
    if settings.atoms == 'box' then
      body.kind = 'box'
      body.atoms = lattice.new(min, max, settings.spacing)
      for mi, mesh in ipairs(body.meshes) do
        for v = 0, mesh.n - 1 do
          use(lattice.cellOf(body.atoms, mesh.px[v], mesh.py[v], mesh.pz[v]), mi, v)
          if v % 4000 == 0 then t0 = budget(t0) end
        end
      end
    else
      body.kind = 'hull'
      trace('car %d: building the hull', i)
      body.atoms = hull.new(body.meshes, min, max, settings.hullRing, math.floor(settings.hullAround + 0.5),
        function() t0 = budget(t0) end)
      trace('car %d: hull of %d atoms, %d triangles; pinning vertices', i, body.atoms.count, body.atoms.tris)
      for mi, mesh in ipairs(body.meshes) do
        mesh.bind = hull.newBindings(mesh.n)
        for v = 0, mesh.n - 1 do
          local t1, t2 = hull.bind(body.atoms, mesh.bind, v, mesh.px[v], mesh.py[v], mesh.pz[v], mesh.nx[v], mesh.ny[v], mesh.nz[v])
          if t1 >= 0 then use(t1, mi, v) end
          if t2 >= 0 and mesh.bind.bt[v * hull.SLOTS + 1] >= 0 then use(t2, mi, v) end
          if v % 300 == 0 then t0 = budget(t0) end
        end
      end
    end
    -- into FFI arrays: the GC doesn't walk them (as Lua tables, every damaged car's lists were rescanned by each
    -- garbage collection, more of them the more cars)
    for key, list in pairs(users) do
      local a = arrays.doubles(#list)
      for e = 1, #list do a[e - 1] = list[e] end
      users[key] = {a = a, n = #list}
      t0 = budget(t0)
    end
    body.users = users
    -- each vertex's crunch noise, now (in the background), so a crash only has to move vertices
    local key = settings.crunchStyle .. settings.crunchSize
    body.noiseKey, body.noiseVer = key, 1
    local crunchFn = settings.crunchStyle == 'hammered' and noise.fbm or noise.ridged
    local f, no = 1 / settings.crunchSize, body.noiseOffset
    for _, mesh in ipairs(body.meshes) do
      mesh.noise, mesh.noiseVer = arrays.floats(mesh.n * 4), arrays.bytes(mesh.n)
      local cache = mesh.noise
      for v = 0, mesh.n - 1 do
        local n0, g0, g1, g2 = noise.withGrad(crunchFn, mesh.px[v] * f + no[1], mesh.py[v] * f + no[2], mesh.pz[v] * f + no[3], 3, 0.5, 0.05)
        cache[v * 4], cache[v * 4 + 1], cache[v * 4 + 2], cache[v * 4 + 3] = n0, g0, g1, g2
        mesh.noiseVer[v] = 1
        if v % 500 == 0 then t0 = budget(t0) end
      end
    end
    -- each body vertex's clearance: how far it is from the nearest interior vertex (it can't go in further than
    -- that plus what the interior there gives), through a 0.1 m grid of the interior's vertices
    local G = 0.1
    local grid, interiorCount = {}, 0
    local function key(x, y, z) return math.floor(x / G) * 73856093 + math.floor(y / G) * 19349663 + math.floor(z / G) * 83492791 end
    for _, mesh in ipairs(body.meshes) do
      if mesh.interior then
        interiorCount = interiorCount + mesh.n
        for v = 0, mesh.n - 1 do
          local k = key(mesh.px[v], mesh.py[v], mesh.pz[v])
          local list = grid[k]
          if not list then list = {} grid[k] = list end
          list[#list + 1] = mesh.px[v] list[#list + 1] = mesh.py[v] list[#list + 1] = mesh.pz[v]
          if v % 4000 == 0 then t0 = budget(t0) end
        end
      end
    end
    body.interiorVertices = interiorCount
    local REACH = 3  -- cells searched each way: 0.3 m (further than that, the body's own limit is the tighter one)
    for _, mesh in ipairs(body.meshes) do
      if not mesh.interior then
        mesh.clear = arrays.floats(mesh.n)
        for v = 0, mesh.n - 1 do
          local x, y, z = mesh.px[v], mesh.py[v], mesh.pz[v]
          local best = 1e9
          if interiorCount > 0 then
            local cx, cy, cz = math.floor(x / G), math.floor(y / G), math.floor(z / G)
            for dz = -REACH, REACH do for dy = -REACH, REACH do for dx = -REACH, REACH do
              local list = grid[(cx + dx) * 73856093 + (cy + dy) * 19349663 + (cz + dz) * 83492791]
              if list then
                for e = 1, #list, 3 do
                  local d2 = (list[e] - x) ^ 2 + (list[e + 1] - y) ^ 2 + (list[e + 2] - z) ^ 2
                  if d2 < best then best = d2 end
                end
              end
            end end end
          end
          mesh.clear[v] = math.sqrt(best)
          if v % 500 == 0 then t0 = budget(t0) end
        end
      end
    end
    -- which ways are forward and left in body space (from the car's heading, and its front-left and
    -- front-right wheels: AC's wheels 0 and 1)
    local car = ac.getCar(i)
    local fwd = invBody:transformVector(car.look)
    body.forward = fwd.z >= 0 and 1 or -1
    local fl, fr = invBody:transformPoint(car.wheels[0].position), invBody:transformPoint(car.wheels[1].position)
    body.left = fl.x >= fr.x and 1 or -1
    body.setupMs = nowMs() - started
    body.state = 'ready'
    log(('car %d: %d meshes with %d vertices, %d atoms (%s), set up in %.0f ms'):format(i, #body.meshes,
      body.vertices, body.atoms.count, body.kind, body.setupMs))
  end)
  jobs[#jobs + 1] = {co = co, name = 'setup car ' .. i, body = body, setup = true}
  return body
end

local sendQueue = {}  -- meshes with new vertices to send (outside of coroutines)

-- A new copy of a mesh's vertices. Not VertexBuffer:clone(): in game that crashed AC (tests C and D died right
-- at it); getVertices() makes its own copy and works.
local function freshVertices(mesh, why)
  trace('getVertices "%s" again (%s)', mesh.name, why)
  local v = mesh.ref:getVertices()
  trace('getVertices "%s": %s', mesh.name, v and (v:size() .. ' vertices') or 'nil')
  if not v or v:size() ~= mesh.n then return nil end
  return v
end

-- Shows a mesh's new vertices. 'direct': the car's own mesh takes them. 'copy': at its first dent, a copy of the
-- mesh is made under the same node with the same material and the original hidden; the copy takes them.
local function send(mesh)
  if not mesh.work then return end  -- repaired or rebuilt since it was queued
  if settings.method == 'direct' and not mesh.copy then
    trace('alterVertices "%s" (%d vertices)', mesh.name, mesh.n)
    mesh.ref:alterVertices(mesh.work)
    trace('alterVertices "%s": done', mesh.name)
    mesh.sent = true
    return
  end
  if not mesh.copy then
    trace('copy of "%s": getIndices', mesh.name)
    local indices = mesh.ref:getIndices()
    trace('copy of "%s": %s indices; createMesh', mesh.name, indices and indices:size() or 'no')
    if not indices then return end
    local start = freshVertices(mesh, 'for the copy')
    if not start then return end
    local copy = mesh.ref:getParent():createMesh('softdamage_' .. mesh.name, mesh.ref:materialName(), start, indices, false, false)
    trace('copy of "%s": %s; assignMaterialFrom', mesh.name, copy and 'made' or 'failed')
    if not copy then return end
    copy:assignMaterialFrom(mesh.ref)
    trace('copy of "%s": material set; hiding the original', mesh.name)
    mesh.ref:setVisible(false)
    mesh.copy = copy
    trace('copy of "%s": done', mesh.name)
    -- the copy starts as the original: the dents go to it next
  end
  if not mesh.sent then trace('alterVertices on the copy of "%s", first time', mesh.name) end
  mesh.copy:alterVertices(mesh.work)
  if not mesh.sent then trace('alterVertices on the copy of "%s": done', mesh.name) mesh.sent = true end
end

-- Moves one vertex with the atoms (into mesh.work) and says if it changed. Its own function: the loop around it
-- then carries few values, so LuaJIT compiles it (written inline it didn't: "register coalescing too complex").
-- The crunch on a vertex's move: returns it with the crunch added (noise kept per vertex, see setupCar).
local function crunchVertex(ctx, mesh, v, ox, oy, oz, qx, qy, qz, crunch, limit)
  local f, n4 = ctx.cf, v * 4
  local cache = mesh.noise
  if mesh.noiseVer[v] ~= ctx.noiseVer then
    local no = ctx.no
    local n0, g0, g1, g2 = noise.withGrad(ctx.crunchFn, mesh.px[v] * f + no[1], mesh.py[v] * f + no[2], mesh.pz[v] * f + no[3], 3, 0.5, 0.05)
    cache[n4], cache[n4 + 1], cache[n4 + 2], cache[n4 + 3] = n0, g0, g1, g2
    mesh.noiseVer[v] = ctx.noiseVer
  end
  local nx0, ny0, nz0 = mesh.nx[v], mesh.ny[v], mesh.nz[v]
  local d = crunch * cache[n4]
  ox, oy, oz = ox + nx0 * d, oy + ny0 * d, oz + nz0 * d
  -- the crunch doesn't take it past its limit either
  local l2 = ox * ox + oy * oy + oz * oz
  local k = l2 > limit * limit and limit / math.sqrt(l2) or 1
  local s = f * crunch  -- slope of the surface, per metre
  local gx, gy, gz = cache[n4 + 1] * s, cache[n4 + 2] * s, cache[n4 + 3] * s
  local gn = gx * nx0 + gy * ny0 + gz * nz0
  qx, qy, qz = qx - (gx - gn * nx0), qy - (gy - gn * ny0), qz - (gz - gn * nz0)
  local ql = math.sqrt(qx * qx + qy * qy + qz * qz)
  if ql < 1e-6 then ql = 1 end
  return ox * k, oy * k, oz * k, qx / ql, qy / ql, qz / ql
end

-- Moves one vertex with the atoms (into mesh.work) and says if it changed. Its own function, so the loop around
-- it carries few values (LuaJIT compiles it).
local function skinVertex(ctx, mesh, v)
  local raw, orig = mesh.work.raw, mesh.orig.raw
  local ox, oy, oz, qx, qy, qz, crunch
  if ctx.isHull then
    ox, oy, oz, qx, qy, qz, crunch = hull.sample(ctx.l, mesh.bind, v)
  else
    local ax, ay, az, bx, by, bz, cx, cy, cz
    ox, oy, oz, ax, ay, az, bx, by, bz, cx, cy, cz, crunch = lattice.sample(ctx.l, mesh.px[v], mesh.py[v], mesh.pz[v])
    if ox then qx, qy, qz = lattice.bendNormal(mesh.nx[v], mesh.ny[v], mesh.nz[v], ax, ay, az, bx, by, bz, cx, cy, cz) end
  end
  if not ox then
    if mesh.moved[v] == 1 then  -- back as it was
      raw[v].pos.x, raw[v].pos.y, raw[v].pos.z = orig[v].pos.x, orig[v].pos.y, orig[v].pos.z
      raw[v].normal.x, raw[v].normal.y, raw[v].normal.z = orig[v].normal.x, orig[v].normal.y, orig[v].normal.z
      mesh.moved[v] = 0
      mesh.movedCount = (mesh.movedCount or 1) - 1
      return true
    end
    return false
  end
  local share, maxInterior = ctx.share, ctx.maxInterior
  if mesh.interior then  -- the interior: a share of what the body does
    local k = share
    ox, oy, oz, crunch = ox * k, oy * k, oz * k, crunch * k
    local nx0, ny0, nz0 = mesh.nx[v], mesh.ny[v], mesh.nz[v]
    qx, qy, qz = nx0 + k * (qx - nx0), ny0 + k * (qy - ny0), nz0 + k * (qz - nz0)
    local ql = math.sqrt(qx * qx + qy * qy + qz * qz)
    if ql < 1e-9 then ql = 1 end
    qx, qy, qz = qx / ql, qy / ql, qz / ql
  end
  -- how far it may move: the interior a quarter foot; the body half a foot, and only as far as closes the gap to
  -- the interior behind it. The same dent moves the interior there `share` as much (up to its own limit), so the
  -- body may move L with L - min(maxInterior, share L) <= its clearance. Beyond that the metal crumples instead:
  -- the excess goes to the crunch
  local limit = maxInterior
  if not mesh.interior then
    local c = math.max(0, mesh.clear[v] - 0.015)
    local L = c / (1 - share)
    if share * L > maxInterior then L = c + maxInterior end
    limit = math.min(ctx.maxBody, L)
  end
  local len = math.sqrt(ox * ox + oy * oy + oz * oz)
  local k = len > limit and limit / len or 1
  ox, oy, oz = ox * k, oy * k, oz * k
  crunch = math.min(ctx.maxCrunch, crunch + math.max(0, len - limit) * 0.3)
  -- crunch: the metal pushed in and out along its surface's normal by noise (creases ~crunchSize and finer), as
  -- much as the crunch there; the normal tilts with the noise's slope
  if crunch > 1e-4 then ox, oy, oz, qx, qy, qz = crunchVertex(ctx, mesh, v, ox, oy, oz, qx, qy, qz, crunch, limit) end
  -- the offset and normal into the mesh's own space
  local T = mesh.toMesh
  local r, o = raw[v], orig[v]
  r.pos.x = o.pos.x + T[1] * ox + T[4] * oy + T[7] * oz
  r.pos.y = o.pos.y + T[2] * ox + T[5] * oy + T[8] * oz
  r.pos.z = o.pos.z + T[3] * ox + T[6] * oy + T[9] * oz
  local mx, my, mz = T[1] * qx + T[4] * qy + T[7] * qz, T[2] * qx + T[5] * qy + T[8] * qz, T[3] * qx + T[6] * qy + T[9] * qz
  local ml = math.sqrt(mx * mx + my * my + mz * mz)
  if ml > 0 then r.normal.x, r.normal.y, r.normal.z = mx / ml, my / ml, mz / ml end
  if mesh.moved[v] == 0 then mesh.movedCount = (mesh.movedCount or 0) + 1 end
  mesh.moved[v] = 1
  return true
end

-- Moves the vertices near atoms that moved since last time (in the lattice cells or on the hull triangles next
-- to them) with the atoms, then sends each changed mesh to the GPU.
local function skin(body)
  if body.skinning then body.skinAgain = true return end
  body.skinning = true
  local co = coroutine.create(function(t0)
    repeat
      body.skinAgain = false
      local started, work, count = nowMs(), 0, 0
      local l, isHull = body.atoms, body.kind == 'hull'
      local changed = {}
      -- (hull) a vertex is in up to two triangles' lists: once a pass is enough (mesh.seen: the pass it was done in)
      body.pass = (body.pass or 0) + 1
      local pass = body.pass
      if isHull then hull.begin(l) end
      local invBody = body.node:getWorldTransformationRaw():inverse()
      for _, mesh in ipairs(body.meshes) do
        if mesh.outside and not mesh.moving then
          local w = mesh.parentNode:getWorldTransformationRaw()
          local o, ax, az = mesh.rest[1], mesh.rest[2], mesh.rest[3]
          local d = math.max(invBody:transformPoint(w:transformPoint(vec3(0, 0, 0))):distanceSquared(o),
            invBody:transformPoint(w:transformPoint(vec3(1, 0, 0))):distanceSquared(ax),
            invBody:transformPoint(w:transformPoint(vec3(0, 0, 1))):distanceSquared(az))
          if d > 0.01 ^ 2 then
            mesh.moving = true
            if mesh.work then  -- all of it back as it was
              local r, o = mesh.work.raw, mesh.orig.raw
              for v = 0, mesh.n - 1 do if mesh.moved[v] == 1 then
                r[v].pos.x, r[v].pos.y, r[v].pos.z = o[v].pos.x, o[v].pos.y, o[v].pos.z
                r[v].normal.x, r[v].normal.y, r[v].normal.z = o[v].normal.x, o[v].normal.y, o[v].normal.z
              end end
              arrays.zero(mesh.moved, mesh.n)
              mesh.movedCount = 0
              changed[mesh] = true
            end
            trace('"%s" (outside BODYTR) moves on the body: not dented from now on', mesh.name)
            for _, part in ipairs(body.parts) do if part.mesh == mesh then part.status = part.status .. '; moves on the body: no longer dented' end end
          end
        end
      end
      -- the crunch's noise, picked once for this pass
      local crunchFn = settings.crunchStyle == 'hammered' and noise.fbm or noise.ridged
      -- each vertex's noise is kept (it depends only on where the vertex is at rest), till the crunch's style or
      -- size changes
      local key = settings.crunchStyle .. settings.crunchSize
      if body.noiseKey ~= key then body.noiseKey, body.noiseVer = key, (body.noiseVer or 0) % 255 + 1 end
      local ctx = {isHull = isHull, l = l, share = settings.interiorShare, maxBody = settings.maxBodyIn,
        maxInterior = settings.maxInteriorIn, maxCrunch = settings.maxCrunch, crunchFn = crunchFn,
        cf = 1 / settings.crunchSize, no = body.noiseOffset, noiseVer = body.noiseVer}
      for key in pairs(isHull and hull.takeChanged(l) or lattice.takeChanged(l)) do
        local list = body.users[key]
        if list then
          local la = list.a
          for e = 0, list.n - 1 do
            local packed = la[e]
            local mi = math.floor(packed / PACK)
            local v = packed - mi * PACK
            local mesh = body.meshes[mi]
            if mesh.seen[v] == pass then mesh = nil else mesh.seen[v] = pass end
            if mesh and mesh.moving then  -- a part that moves on its own: back as it was, and no more
              if mesh.work and mesh.moved[v] == 1 then
                local r, o = mesh.work.raw, mesh.orig.raw
                r[v].pos.x, r[v].pos.y, r[v].pos.z = o[v].pos.x, o[v].pos.y, o[v].pos.z
                r[v].normal.x, r[v].normal.y, r[v].normal.z = o[v].normal.x, o[v].normal.y, o[v].normal.z
                mesh.moved[v] = 0
                mesh.movedCount = (mesh.movedCount or 1) - 1
                changed[mesh] = true
              end
              mesh = nil
            end
            if mesh then
              if not mesh.work and not mesh.failed then
                mesh.work = freshVertices(mesh, 'to dent')
                mesh.failed = mesh.work == nil  -- left as it is
                if mesh.work and not mesh.noise then mesh.noise, mesh.noiseVer = arrays.floats(mesh.n * 4), arrays.bytes(mesh.n) end
              end
              if mesh.work and skinVertex(ctx, mesh, v) then changed[mesh] = true end
            end
            count = count + 1
            if count % 1000 == 0 then
              local t = nowMs()
              if t - t0 > jobBudget then work = work + (t - t0) t0 = coroutine.yield() end
            end
          end
        end
      end
      -- sent from script.update, not from inside this coroutine
      for mesh in pairs(changed) do sendQueue[#sendQueue + 1] = mesh end
      work = work + (nowMs() - t0)
      body.lastSkinMs, body.lastSkinSpan, body.lastSkinCount = work, nowMs() - started, count
    until not body.skinAgain
    body.skinning = false
  end)
  jobs[#jobs + 1] = {co = co, name = 'skin car ' .. body.index, body = body}
end

-- Puts every mesh back as it was, now (not over frames).
local function restoreNow(body)
  for _, mesh in ipairs(body and body.meshes or {}) do
    if mesh.copy then
      mesh.copy:dispose()
      mesh.copy = nil
      mesh.ref:setVisible(true)
    elseif mesh.sent then
      mesh.ref:alterVertices(mesh.orig)
    end
    arrays.zero(mesh.moved, mesh.n)
    mesh.sent, mesh.work, mesh.failed, mesh.movedCount = nil, nil, nil, 0
  end
end
-- unloading (AC closing, the app reloaded): the originals back
ac.onRelease(function() for _, body in pairs(cars) do restoreNow(body) end end)

local function repair(body)
  if not body or not body.atoms then return end
  if body.kind == 'hull' then hull.reset(body.atoms) else lattice.reset(body.atoms) end
  body.dents = 0
  skin(body)
end

-- A dent at a world position, pushed along a world direction.
-- severity: how hard the hit was, 0..about 2 (a test dent: from its depth; a crash: from its speed). The crunch
-- grows with it, faster than the dent does: a tap leaves a smooth dent, a big hit crumples the metal.
local function crunchFor(depth, severity)
  return settings.crunch * 0.4 * depth * math.min(2.5, severity) ^ 1.5
end

local function dentWorld(body, worldPos, worldDir, depth, radius, severity)
  if not body or body.state ~= 'ready' then return false end
  local w = body.node:getWorldTransformationRaw()
  local inv = w:inverse()
  local p = inv:transformPoint(worldPos)
  local d = inv:transformVector(worldDir):normalize()
  -- how much this way gives: pushed backwards (hit in the front), forwards (from behind), sideways, down. Sideways,
  -- the doors give least (beams in them) and the quarters towards the ends most (crumple zones): from the
  -- middle 40% of the length to the last 20% at each end, the side's give goes from sideGive to endGive
  local along = d.z * body.forward  -- > 0: pushed forwards (a hit from behind)
  local half = (body.max[3] - body.min[3]) / 2
  local e = math.abs(p.z - (body.min[3] + body.max[3]) / 2) / half
  local t = math.max(0, math.min(1, (e - 0.4) / 0.4))
  t = t * t * (3 - 2 * t)
  local side = settings.sideGive + (settings.endGive - settings.sideGive) * t
  local give = (along < 0 and settings.frontGive or settings.rearGive) * d.z * d.z + side * d.x * d.x
    + settings.roofGive * d.y * d.y
  depth = depth * give
  local dent = body.kind == 'hull' and hull.dent or lattice.dent
  if body.kind == 'hull' then
    if settings.springLimits then
      hull.setLimits(body.atoms, settings.stretchLimit, settings.squashLimit, settings.foldAt, settings.foldCrunch * settings.crunch)
    else
      hull.setLimits(body.atoms, nil)
    end
  end
  dent(body.atoms, p.x, p.y, p.z, d.x, d.y, d.z, depth, radius, settings.maxOffset, settings.springs, 0.35,
    crunchFor(depth, (severity or depth / 0.1) * give), settings.maxCrunch)
  body.dents = body.dents + 1
  body.lastDent = {x = p.x, y = p.y, z = p.z}
  skin(body)
  return true
end

-- The car's surface along a ray (world), or nil.
local function hitCar(body, from, dir)
  local meshes = body.node:findMeshes('?')
  local dist = meshes:raycast(render.createRay(from, dir, 20), false)
  if dist and dist >= 0 then return from + dir * dist end
  return nil
end

-- A test dent on one side: a ray from outside the car towards its middle, at mid height.
local function dentSide(body, side)
  if not body or body.state ~= 'ready' then return end
  local w = body.node:getWorldTransformationRaw()
  local mn, mx = body.min, body.max
  local cx, cy, cz = (mn[1] + mx[1]) / 2, mn[2] + (mx[2] - mn[2]) * 0.45, (mn[3] + mx[3]) / 2
  local f = body.forward
  local lf = body.left
  -- each side's push: into the car from that side
  local dirs = {front = vec3(0, 0, -f), back = vec3(0, 0, f), left = vec3(-lf, 0, 0), right = vec3(lf, 0, 0), roof = vec3(0, -1, 0)}
  local d = dirs[side]
  local centre = vec3(cx, side == 'roof' and mn[2] + (mx[2] - mn[2]) * 0.6 or cy, cz)
  local fromLocal = centre - d * 6
  local from, dirW = w:transformPoint(fromLocal), w:transformVector(d):normalize()
  local hit = hitCar(body, from, dirW) or w:transformPoint(centre - d * 1)
  dentWorld(body, hit, dirW, settings.depth, settings.radius)
end

-- ---------------------------------------------------------------------------------------------
-- Crashes. An impulse J at r from the car's middle changes its velocity by J/m and its spin by I^-1 (r x J), so
-- from the two changes (dv, dw) the hit is found: r = k^2 (dv x dw) / |dv|^2 (k: the body's radius of gyration,
-- from its size). The spin comes from how the car's own axes turn between frames, with the same cross product,
-- so the signs agree whatever the world's handedness. A hit at the tail mostly spins the car: what counts is the
-- change at the contact point, dv + dw x r.
-- An impact starts with a jump over 3 g (braking and cornering stay under about 2 g) at the middle or, through
-- the spin, at the ends, or AC reporting a contact (contacts can come and go between frames); the biggest change
-- over the next 150 ms is the hit, and from 2.5 m/s at the contact point it dents there. A push from below (a
-- landing) counts 15%: the suspension takes it. A teleport (over 5 m in a frame) isn't a crash.
local IMPACT_ACCEL, IMPACT_WINDOW, MIN_HIT, COOLDOWN, FROM_BELOW = 30, 0.15, 2.5, 0.3, 0.15
local crash = {}
local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end

-- The car's spin over the last frame (rad/s, world), from its axes then and now: for a small turn by angle t
-- about axis a, the sum of e x e' over three orthonormal axes is 2 t a.
local function spin(c, car, dt)
  local l0, u0, l1, u1 = c.prevLook, c.prevUp, car.look, car.up
  local s0x, s0y, s0z = cross(l0.x, l0.y, l0.z, u0.x, u0.y, u0.z)
  local s1x, s1y, s1z = cross(l1.x, l1.y, l1.z, u1.x, u1.y, u1.z)
  local ax, ay, az = cross(l0.x, l0.y, l0.z, l1.x, l1.y, l1.z)
  local bx, by, bz = cross(u0.x, u0.y, u0.z, u1.x, u1.y, u1.z)
  local cx, cy, cz = cross(s0x, s0y, s0z, s1x, s1y, s1z)
  local k = 0.5 / dt
  return (ax + bx + cx) * k, (ay + by + cy) * k, (az + bz + cz) * k
end

-- Crash dents waiting: one is made a frame (each re-skins a car's meshes and sends them).
local crashQueue = {}

-- A crash's dent: r (world) from the car's middle, pushed along dir (world).
local function makeCrashDent(i, body, r, dir, speed, dvLen, along)
  local mn, mx = body.min, body.max
  local W = body.node:getWorldTransformationRaw()
  local centre = W:transformPoint(vec3((mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2))
  local aim = centre + r
  local hit = hitCar(body, aim - dir * 6, dir) or (aim - dir * 1.0)
  local depth = math.min(settings.maxOffset, (speed - MIN_HIT) * 0.025 * settings.crashScale + 0.01)
  trace('crash: car %d, %.1f m/s at the contact (%.1f at the middle), %.2f m from the middle (along %.2f): dent %.3f m',
    i, speed, dvLen, r:length(), along, depth)
  dentWorld(body, hit, dir, depth, 0.35 + 0.025 * speed, speed / 12)
  body.lastCrash = speed
  body.crashes = (body.crashes or 0) + 1
end

local function crashDent(i, body, r, dir, speed, dvLen, along)
  -- in the car's frame now (it moves on while waiting): r and dir kept relative to the body
  local inv = body.node:getWorldTransformationRaw():inverse()
  if #crashQueue >= 32 then table.remove(crashQueue, 1) end
  crashQueue[#crashQueue + 1] = {i = i, body = body, r = inv:transformVector(r), dir = inv:transformVector(dir), speed = speed,
    dvLen = dvLen, along = along}
end

local function nextCrashDent()
  local q = table.remove(crashQueue, 1)
  if not q then return end
  if cars[q.i] ~= q.body or q.body.state ~= 'ready' then return end
  local W = q.body.node:getWorldTransformationRaw()
  makeCrashDent(q.i, q.body, W:transformVector(q.r), W:transformVector(q.dir):normalize(), q.speed, q.dvLen, q.along)
end

-- Crashes of cars not read yet: kept (in the car's own axes) until the car is, then dented.
local pending = {}
local function carAxes(car)
  local l, u = car.look, car.up
  local sx, sy, sz = cross(u.x, u.y, u.z, l.x, l.y, l.z)
  return vec3(sx, sy, sz):normalize(), u, l
end

local requestSetup  -- (below)

local function updateCrash(i, dt)
  local car = ac.getCar(i)
  local body = cars[i]
  if not car or dt <= 0 then return end
  local ready = body and body.state == 'ready'
  local c = crash[i]
  if not c then
    c = {prevVel = vec3():set(car.velocity), prevPos = vec3():set(car.position), prevLook = vec3():set(car.look),
      prevUp = vec3():set(car.up), w = {0, 0, 0}, cool = 0}
    crash[i] = c
    return
  end
  -- the car's size: its body's box once read, AC's bounding box till then
  local L, Wd, Hd
  if ready then
    L, Wd, Hd = body.max[3] - body.min[3], body.max[1] - body.min[1], body.max[2] - body.min[2]
  else
    local a = car.aabbSize
    L, Wd, Hd = a and a.z > 0.5 and a.z or 4.5, a and a.x > 0.5 and a.x or 1.9, a and a.y > 0.3 and a.y or 1.4
  end
  local halfLen = math.max(L, Wd) / 2
  c.cool = math.max(0, c.cool - dt)
  local teleported = car.position:distanceSquared(c.prevPos) > 25
  local wx, wy, wz = spin(c, car, dt)
  if teleported then c.at = nil wx, wy, wz = c.w[1], c.w[2], c.w[3] end
  local vel, pv = car.velocity, c.prevVel
  local jump = math.sqrt((vel.x - pv.x) ^ 2 + (vel.y - pv.y) ^ 2 + (vel.z - pv.z) ^ 2) / dt
  local spinJump = math.sqrt((wx - c.w[1]) ^ 2 + (wy - c.w[2]) ^ 2 + (wz - c.w[3]) ^ 2) / dt * halfLen
  if not c.at and not teleported and c.cool == 0 and (jump + spinJump > IMPACT_ACCEL or car.collisionDepth > 0) then
    c.at, c.before, c.maxDv = 0, c.prevVel:clone(), vec3()
    c.wBefore = {c.w[1], c.w[2], c.w[3]}
  end
  if c.at then
    c.at = c.at + dt
    local b = c.before
    local ex, ey, ez = vel.x - b.x, vel.y - b.y, vel.z - b.z
    if ex * ex + ey * ey + ez * ez > c.maxDv:lengthSquared() then c.maxDv:set(ex, ey, ez) end
    if c.at >= IMPACT_WINDOW then
      c.at = nil
      local up = car.up
      local dvx, dvy, dvz = c.maxDv.x, c.maxDv.y, c.maxDv.z
      -- a push from below (along the car's up): mostly the suspension's
      local vu = dvx * up.x + dvy * up.y + dvz * up.z
      if vu > 0 then
        local cut = vu * (1 - FROM_BELOW)
        dvx, dvy, dvz = dvx - up.x * cut, dvy - up.y * cut, dvz - up.z * cut
      end
      local dv2 = dvx * dvx + dvy * dvy + dvz * dvz
      local dwx, dwy, dwz = wx - c.wBefore[1], wy - c.wBefore[2], wz - c.wBefore[3]
      -- where: r = k^2 (dv x dw) / |dv|^2, kept inside the car's box (in its own frame: the body's once read,
      -- the car's axes till then)
      local k2 = (L * L + Wd * Wd) / 12
      local rx, ry, rz = 0, 0, 0
      if dv2 > 1e-6 then
        rx, ry, rz = cross(dvx, dvy, dvz, dwx, dwy, dwz)
        rx, ry, rz = rx * k2 / dv2, ry * k2 / dv2, rz * k2 / dv2
      end
      local W, inv, ax, ay, az
      local rl
      if ready then
        W = body.node:getWorldTransformationRaw()
        inv = W:inverse()
        rl = inv:transformVector(vec3(rx, ry, rz))
      else
        ax, ay, az = carAxes(car)
        rl = vec3(rx * ax.x + ry * ax.y + rz * ax.z, rx * ay.x + ry * ay.y + rz * ay.z, rx * az.x + ry * az.y + rz * az.z)
      end
      rl.x = math.max(-Wd / 2, math.min(Wd / 2, rl.x))
      rl.y = math.max(-Hd / 2, math.min(Hd / 2, rl.y))
      rl.z = math.max(-L / 2, math.min(L / 2, rl.z))
      local r = ready and W:transformVector(rl) or (ax * rl.x + ay * rl.y + az * rl.z)
      -- the change at the contact point: dv + dw x r (at most three times the middle's: noise in the spin)
      local px, py, pz = cross(dwx, dwy, dwz, r.x, r.y, r.z)
      local dvLen = math.sqrt(dv2)
      local speed = math.min(dvLen * 3 + 1, math.sqrt((dvx + px) ^ 2 + (dvy + py) ^ 2 + (dvz + pz) ^ 2))
      if speed > MIN_HIT and dvLen > 1e-3 then
        c.cool = COOLDOWN
        local dir = vec3(dvx, dvy, dvz):normalize()
        if ready then
          crashDent(i, body, r, dir, speed, dvLen, rl.z)
        else
          -- not read yet: kept in the car's axes, and the car read first of all
          if i == sim.focusedCar or totalVertices() < settings.maxVertices then
            local p = pending[i] or {}
            pending[i] = p
            if #p >= 3 then  -- the three hardest are enough
              local weakest = 1
              for k = 2, #p do if p[k].speed < p[weakest].speed then weakest = k end end
              if p[weakest].speed < speed then table.remove(p, weakest) end
            end
            if #p < 3 then
              p[#p + 1] = {r = {rl.x, rl.y, rl.z}, dir = {dir:dot(ax), dir:dot(ay), dir:dot(az)}, speed = speed, dvLen = dvLen}
            end
            trace('crash: car %d (not read yet), %.1f m/s: reading it to dent it', i, speed)
            requestSetup(i, true)
          end
        end
      end
    end
  end
  c.w[1], c.w[2], c.w[3] = wx, wy, wz
  c.prevVel:set(car.velocity)
  c.prevPos:set(car.position)
  c.prevLook:set(car.look)
  c.prevUp:set(car.up)
end

-- Crashes kept for cars now read: dented, in the car's axes as they are now.
local function applyPending()
  for i, list in pairs(pending) do
    local body, car = cars[i], ac.getCar(i)
    if body and body.state == 'ready' and car then
      local ax, ay, az = carAxes(car)
      for _, p in ipairs(list) do
        local r = ax * p.r[1] + ay * p.r[2] + az * p.r[3]
        local dir = (ax * p.dir[1] + ay * p.dir[2] + az * p.dir[3]):normalize()
        crashDent(i, body, r, dir, p.speed, p.dvLen, p.r[3])
      end
      pending[i] = nil
    elseif not body or (body.state ~= 'ready' and body.state ~= 'reading meshes') then
      if body then pending[i] = nil end  -- couldn't be read: dropped
    end
  end
end

-- Repairs: going to the pits or being reset (ac.onCarJumped) mends the body.
local jumpHooked = {}
local function hookJumps(i)
  if jumpHooked[i] then return end
  jumpHooked[i] = true
  ac.onCarJumped(i, function() repair(cars[i]) end)
end

-- ---------------------------------------------------------------------------------------------
local wasClick = false
-- Sends what's queued, up to sendBudget vertices a frame (at least one mesh); the rest next frame.
local function sendQueued()
  local q = sendQueue
  sendQueue = {}
  local seen, sent = {}, 0
  for _, mesh in ipairs(q) do
    if not seen[mesh] then
      seen[mesh] = true
      if sent > 0 and sent + mesh.n > settings.sendBudget then
        sendQueue[#sendQueue + 1] = mesh
      else
        send(mesh)
        sent = sent + mesh.n
      end
    end
  end
end

-- Which cars are read: the watched one, and (a setting) every other car within readDistance of the camera, the
-- nearest first, one at a time. A car read and still undamaged that's gone further than one and a half times
-- that is let go again (memory); a damaged one stays, and keeps its detailed model (AC shows simpler models of
-- far cars, which don't have the dents) up to detailedDistance.
local function readingNow()
  for _, j in ipairs(jobs) do if j.setup then return j.body.index end end
  return nil
end

function requestSetup(i, urgent)
  if cars[i] then return end
  local body = setupCar(i)
  hookJumps(i)
  if urgent and #jobs > 1 then
    -- next after whatever runs now
    local job = table.remove(jobs)
    table.insert(jobs, 2, job)
  end
  return body
end

local function letGo(i)
  local body = cars[i]
  if not body then return end
  restoreNow(body)
  body.state = 'let go'
  for n = #jobs, 1, -1 do if jobs[n].body == body then table.remove(jobs, n) end end
  cars[i] = nil
  trace('car %d: let go (far away, undamaged)', i)
end

local function damaged(body) return body.dents > 0 end

local detailedList, detailedDist = {}, {}
local function byDistance(a, b) return detailedDist[a] < detailedDist[b] end
local perf = {ms = 0, crashMs = 0, jobsMs = 0, detailed = 0}

local function manageCars()
  local focused = sim.focusedCar
  if focused >= 0 and not cars[focused] then requestSetup(focused, true) end
  if not settings.allCars then return end
  local far = settings.readDistance * 1.5
  local nearest, nearestD
  for k = #detailedList, 1, -1 do detailedList[k] = nil end
  for i = 0, (sim.carsCount or 1) - 1 do
    local car = ac.getCar(i)
    if car and car.isConnected ~= false then
      local d = car.distanceToCamera or 0
      local body = cars[i]
      if not body and d < settings.readDistance and (not nearestD or d < nearestD) then nearest, nearestD = i, d end
      if body and i ~= focused and body.state == 'ready' and not damaged(body) and not pending[i] and d > far
        and totalVertices() > settings.maxVertices * 0.9 then
        letGo(i)  -- only to make room: reading a car again costs more than keeping it
      end
      if body and body.state == 'ready' and damaged(body) and settings.keepDetailed and d < settings.detailedDistance then
        detailedList[#detailedList + 1] = i
        detailedDist[i] = d
      end
    end
  end
  perf.full = totalVertices() >= settings.maxVertices
  if nearest and not readingNow() and not perf.full then requestSetup(nearest) end
  -- the main model costs drawing time: kept only for the nearest few damaged cars
  table.sort(detailedList, byDistance)
  perf.detailed = math.min(#detailedList, settings.detailedMax)
  if ac.forceDetailedCarLOD then
    for k = 1, perf.detailed do ac.forceDetailedCarLOD(detailedList[k]) end
  end
end

function script.update(dt)
  local tStart = nowMs()
  local i = sim.focusedCar
  if settings.readWatched then manageCars() end
  -- Ctrl + left click on the car: a dent there, along the view
  local click = ac.isKeyDown(ac.KeyIndex.Control) and ac.isKeyDown(ac.KeyIndex.LeftButton)
  if click and not wasClick and cars[i] and cars[i].state == 'ready' then
    local ray = render.createMouseRay()
    local body = cars[i]
    local dist = body.node:findMeshes('?'):raycast(ray, false)
    if dist and dist >= 0 then dentWorld(body, ray.pos + ray.dir * dist, ray.dir, settings.depth, settings.radius) end
  end
  wasClick = click
  -- crashes: every car that's read, and (all cars on) every car in the session
  local tCrash = nowMs()
  if settings.crashDents and not sim.isPaused and not sim.isReplayActive then
    if settings.readWatched and settings.allCars then
      for ci = 0, (sim.carsCount or 1) - 1 do
        local car = ac.getCar(ci)
        if car and car.isConnected ~= false then updateCrash(ci, dt) end
      end
    else
      for ci in pairs(cars) do if cars[ci].state == 'ready' then updateCrash(ci, dt) end end
    end
  else
    -- not watching: forget the last frame, so the next one isn't compared with a stale one (a false crash)
    for ci in pairs(crash) do crash[ci] = nil end
  end
  local tJobs = nowMs()
  applyPending()
  nextCrashDent()
  runJobs()
  sendQueued()
  local tEnd = nowMs()
  -- (smoothed) how long the app takes a frame: all of it, the crash watching, the background work
  perf.ms = perf.ms + (tEnd - tStart - perf.ms) * 0.05
  perf.crashMs = perf.crashMs + (tJobs - tCrash - perf.crashMs) * 0.05
  perf.jobsMs = perf.jobsMs + (tEnd - tJobs - perf.jobsMs) * 0.05
end

local function slider(key, label, min, max, scale, integer)
  local v = ui.slider('##' .. key, settings[key] * (scale or 1), min, max, label) / (scale or 1)
  if integer then v = math.floor(v + 0.5) end
  if v ~= settings[key] then settings[key] = v end
end

-- ---------------------------------------------------------------------------------------------
-- Tests, one at a time (a crash ends AC; the trace file shows the step): A, a track mesh sent back unchanged
-- (does the call work at all?); B, the car's smallest body mesh sent back unchanged (car meshes?); C, a copy
-- of that mesh made, the original hidden, and the copy lifted 5 cm (the 'copy' way).
local testResult = {}
local testCopy
local function smallestMesh(body)
  local best
  for _, m in ipairs(body.meshes) do if not best or m.n < best.n then best = m end end
  return best
end
local function testA()
  trace('test A: finding track meshes')
  local meshes = ac.findNodes('trackRoot:yes'):findMeshes('?')
  trace('test A: %d track meshes', meshes:size())
  for m = 1, math.min(meshes:size(), 300) do
    local ref = meshes:at(m)
    local v = ref:getVertices()
    if v and v:size() > 0 and v:size() < 5000 then
      trace('test A: alterVertices on "%s" (%d vertices), unchanged', meshes:name(m), v:size())
      ref:alterVertices(v)
      trace('test A: done')
      return 'passed ("' .. meshes:name(m) .. '", ' .. v:size() .. ' vertices)'
    end
  end
  return 'no small track mesh found'
end
local function testB(body)
  local mesh = smallestMesh(body)
  trace('test B: alterVertices on "%s" (%d vertices), unchanged', mesh.name, mesh.n)
  mesh.ref:alterVertices(mesh.orig)
  trace('test B: done')
  return 'passed ("' .. mesh.name .. '")'
end
local function testC(body)
  local mesh = smallestMesh(body)
  trace('test C: "%s" (%d vertices): getIndices', mesh.name, mesh.n)
  local indices = mesh.ref:getIndices()
  trace('test C: %s indices; createMesh', indices and indices:size() or 'no')
  if not indices then return 'no indices' end
  local v = freshVertices(mesh, 'test C')
  local start = freshVertices(mesh, 'test C, for the copy')
  if not v or not start then return 'getVertices failed' end
  trace('test C: material "%s"', mesh.ref:materialName())
  local copy = mesh.ref:getParent():createMesh('softdamage_test', mesh.ref:materialName(), start, indices, false, false)
  trace('test C: %s', copy and 'made' or 'createMesh failed')
  if not copy then return 'createMesh failed' end
  copy:assignMaterialFrom(mesh.ref)
  trace('test C: material set; hiding the original')
  mesh.ref:setVisible(false)
  testCopy = {copy = copy, mesh = mesh}
  -- lift it 5 cm (body space up, into the mesh's space)
  local T = mesh.toMesh
  for i = 0, v:size() - 1 do
    v.raw[i].pos.x, v.raw[i].pos.y, v.raw[i].pos.z = v.raw[i].pos.x + T[4] * 0.05, v.raw[i].pos.y + T[5] * 0.05, v.raw[i].pos.z + T[6] * 0.05
  end
  trace('test C: alterVertices on the copy (lifted 5 cm)')
  copy:alterVertices(v)
  trace('test C: done')
  return 'passed ("' .. mesh.name .. '" should be 5 cm up; Undo C puts it back)'
end
-- D: the smallest mesh lifted 5 cm (changed vertices), sent from here; E: the same, sent from inside a coroutine
local function lifted(mesh, dy)
  local v = freshVertices(mesh, 'test D/E')
  if not v then return nil end
  local T = mesh.toMesh
  for i = 0, v:size() - 1 do
    v.raw[i].pos.x, v.raw[i].pos.y, v.raw[i].pos.z = v.raw[i].pos.x + T[4] * dy, v.raw[i].pos.y + T[5] * dy, v.raw[i].pos.z + T[6] * dy
  end
  return v
end
local testLifted
local function testD(body)
  local mesh = smallestMesh(body)
  local v = lifted(mesh, 0.05)
  if not v then return 'getVertices failed' end
  trace('test D: alterVertices on "%s" (%d vertices), lifted 5 cm', mesh.name, mesh.n)
  mesh.ref:alterVertices(v)
  trace('test D: done')
  testLifted = {mesh = mesh, v = v}
  return 'passed ("' .. mesh.name .. '" should be 5 cm up; Undo D/E puts it back)'
end
local function testE(body)
  local mesh = smallestMesh(body)
  local v = lifted(mesh, 0.05)
  if not v then return 'getVertices failed' end
  local co = coroutine.create(function()
    trace('test E: alterVertices on "%s" (%d vertices), lifted 5 cm, inside a coroutine', mesh.name, mesh.n)
    mesh.ref:alterVertices(v)
    trace('test E: done')
  end)
  local ok, err = coroutine.resume(co)
  testLifted = {mesh = mesh, v = v}
  return ok and ('passed ("' .. mesh.name .. '" should be 5 cm up)') or ('error: ' .. tostring(err))
end
local function undoLift()
  if not testLifted then return end
  testLifted.mesh.ref:alterVertices(testLifted.mesh.orig)
  trace('test D/E undone')
  testLifted = nil
end

local function undoC()
  if not testCopy then return end
  testCopy.copy:dispose()
  testCopy.mesh.ref:setVisible(true)
  testCopy = nil
  trace('test C undone')
end

local showParts = false
function script.windowMain(dt)
  local read, dented = 0, 0
  for _, b in pairs(cars) do if b.state == 'ready' then read = read + 1 if b.dents > 0 then dented = dented + 1 end end end
  local now = readingNow()
  ui.text(('Cars read: %d (%d dented)%s'):format(read, dented, now and (', reading car ' .. now) or ''))
  ui.text(('App: %.2f ms a frame (crashes %.2f, background work %.2f); Lua memory %.0f MB; %d cars kept detailed'):format(
    perf.ms, perf.crashMs, perf.jobsMs, collectgarbage('count') / 1024, perf.detailed))
  ui.text(('Vertices read: %.2f million of %.2f%s'):format(totalVertices() / 1e6, settings.maxVertices / 1e6,
    perf.full and ' (full: no more cars read)' or ''))
  local body = cars[sim.focusedCar]
  if not body then
    ui.textWrapped('Reads the body of the car you are watching (a trace of each step goes to softdamage_trace.txt in '
      .. 'this app\'s folder).')
    if ui.button('Read this car') and sim.focusedCar >= 0 then setupCar(sim.focusedCar) hookJumps(sim.focusedCar) end
    return
  end
  ui.text(('Car %d: %s%s'):format(body.index, body.state, body.state == 'reading meshes' and body.reading and (' ' .. body.reading) or ''))
  if body.error then ui.textColored('Error: ' .. body.error, rgbm(1, 0.4, 0.3, 1)) end
  if body.atoms then
    local l = body.atoms
    local interior = 0
    for _, m in ipairs(body.meshes) do if m.interior then interior = interior + 1 end end
    ui.text(('%d meshes (%d interior; of %d, %d left still), %d vertices'):format(#body.meshes,
      interior, body.meshCount or 0, body.skipped or 0, body.vertices))
    if body.kind == 'hull' then
      ui.text(('Hull: %d atoms (%d rings of %d, and the ends), %d triangles'):format(l.count, l.rings, l.around, l.tris))
    else
      ui.text(('Box lattice: %d x %d x %d atoms'):format(l.n[1], l.n[2], l.n[3]))
    end
    ui.text(('Setup %.0f ms. Last re-skin: %d vertices, %.0f ms of work over %.0f ms.'):format(body.setupMs,
      body.lastSkinCount or 0, body.lastSkinMs or 0, body.lastSkinSpan or 0))
    ui.text(('Dents: %d (%d from crashes%s)'):format(body.dents, body.crashes or 0,
      body.lastCrash and ('; last %.1f m/s'):format(body.lastCrash) or ''))
  end
  if body.parts and ui.checkbox('Show the parts (what was read, and what\'s dented now)', showParts) then showParts = not showParts end
  if showParts and body.parts then
    for _, part in ipairs(body.parts) do
      local moved = part.mesh and (part.mesh.movedCount or 0) or 0
      ui.textWrapped(('%s: %s%s'):format(part.name, part.status, moved > 0 and ('; %d vertices moved now'):format(moved) or ''))
    end
  end
  ui.separator()
  ui.text('Test dents:')
  for _, side in ipairs({'front', 'back', 'left', 'right', 'roof'}) do
    if ui.button(side) then dentSide(body, side) end
    ui.sameLine()
  end
  if ui.button('Repair') then repair(body) end
  ui.textWrapped('Or hold Ctrl and click on the car.')
  ui.separator()
  ui.text('Tests (one per AC launch if they crash):')
  if ui.button('A: track mesh') then testResult.A = testA() end
  ui.sameLine()
  if body.state == 'ready' then
    if ui.button('B: car mesh') then testResult.B = testB(body) end
    ui.sameLine()
    if ui.button('C: car mesh copy') then testResult.C = testC(body) end
    ui.sameLine()
    if ui.button('Undo C') then undoC() testResult.C = nil end
    if ui.button('D: change a car mesh') then testResult.D = testD(body) end
    ui.sameLine()
    if ui.button('E: same, in a coroutine') then testResult.E = testE(body) end
    ui.sameLine()
    if ui.button('Undo D/E') then undoLift() testResult.D, testResult.E = nil, nil end
  end
  for _, k in ipairs({'A', 'B', 'C', 'D', 'E'}) do if testResult[k] then ui.textWrapped(k .. ': ' .. testResult[k]) end end
  slider('depth', 'Dent depth: %.2f m', 0.01, 0.5)
  slider('radius', 'Dent radius: %.2f m', 0.1, 1.5)
  slider('crunch', 'Crunch: %.0f%%', 0, 300, 100)
end

function script.windowSettings(dt)
  slider('frontGive', 'Front gives: %.0f%%', 20, 300, 100)
  slider('rearGive', 'Rear gives: %.0f%%', 20, 300, 100)
  slider('sideGive', 'Doors give (pushed sideways): %.0f%%', 20, 300, 100)
  slider('endGive', 'Quarters give (sideways, at the ends): %.0f%%', 20, 300, 100)
  slider('roofGive', 'Roof gives: %.0f%%', 20, 300, 100)
  slider('maxBodyIn', 'Body moves at most: %.3f m', 0.03, 0.5)
  slider('maxInteriorIn', 'Interior moves at most: %.3f m', 0, 0.3)
  slider('interiorShare', 'Interior moves %.0f%% of the body', 0, 90, 100)
  slider('springs', 'Spring passes: %.0f', 0, 6, 1, true)
  if ui.checkbox('Spring limits (the hull; 1nsane\'s way)', settings.springLimits) then settings.springLimits = not settings.springLimits end
  if settings.springLimits then
    slider('stretchLimit', 'Metal stretches to %.2fx at most', 1.0, 1.5)
    slider('squashLimit', 'Squashes to %.2fx at most', 0.2, 0.95)
    slider('foldAt', 'Folds when squashed past %.2fx', 0.5, 1.0)
    slider('foldCrunch', 'Fold crunch: %.0f%%', 0, 300, 100)
  end
  slider('maxOffset', 'Most an atom moves: %.2f m', 0.1, 1)
  local kinds = {'hull', 'box'}
  local pickKind = ui.combo('Atoms (rebuild)', settings.atoms == 'box' and 2 or 1, ui.ComboFlags.None,
    {'Car-shaped hull (1nsane)', 'Box lattice (0.4)'})
  if kinds[pickKind] then settings.atoms = kinds[pickKind] end
  if settings.atoms == 'box' then
    slider('spacing', 'Atom spacing: %.2f m (rebuild)', 0.15, 0.8)
  else
    slider('hullRing', 'Hull rings every %.2f m (rebuild)', 0.15, 0.8)
    slider('hullAround', 'Hull atoms around: %.0f (rebuild)', 6, 24, 1, true)
  end
  slider('budgetMs', 'Work per frame: %.1f ms', 1, 16)
  if ui.checkbox('Read cars without the button', settings.readWatched) then settings.readWatched = not settings.readWatched end
  if ui.checkbox('Every car in the session (not just the one I\'m watching)', settings.allCars) then settings.allCars = not settings.allCars end
  if settings.allCars then
    slider('readDistance', 'Read cars within %.0f m of the camera', 20, 500)
    slider('maxVertices', 'Vertices read at most: %.1f million', 0.2, 6, 1e-6)
  end
  if ui.checkbox('Damaged cars keep their detailed model', settings.keepDetailed) then settings.keepDetailed = not settings.keepDetailed end
  if settings.keepDetailed then
    slider('detailedDistance', '... up to %.0f m', 20, 500)
    slider('detailedMax', '... the nearest %.0f of them', 1, 20, 1, true)
  end
  if ui.checkbox('Dent copies of the meshes (createMesh crashed AC in test C)', settings.method == 'copy') then
    settings.method = settings.method == 'copy' and 'direct' or 'copy'
  end
  if ui.checkbox('Dents from crashes', settings.crashDents) then settings.crashDents = not settings.crashDents end
  if ui.checkbox('Also dent parts outside BODYTR (not wheels etc.; rebuild)', settings.outsideBody) then settings.outsideBody = not settings.outsideBody end
  slider('crashScale', 'Crash dent scale: %.2f', 0.1, 3)
  slider('crunchSize', 'Crunch: biggest creases %.2f m', 0.04, 0.5)
  slider('maxCrunch', 'Crunch: at most %.3f m', 0.005, 0.2)
  local styles = {'creases', 'hammered'}
  local pick = ui.combo('Crunch style', settings.crunchStyle == 'hammered' and 2 or 1, ui.ComboFlags.None,
    {'Creases (crumpled metal)', 'Hammered (bumps)'})
  if styles[pick] then settings.crunchStyle = styles[pick] end
  if ui.button('Rebuild (re-read the car)') then
    local i = sim.focusedCar
    if cars[i] then cars[i].state = 'replaced' restoreNow(cars[i]) end
    for n = #jobs, 1, -1 do if jobs[n].body == cars[i] then table.remove(jobs, n) end end
    cars[i] = nil
    if i >= 0 then setupCar(i) end
  end
end

if __softdamageTest then __softdamageTest.cars = cars __softdamageTest.jobs = jobs __softdamageTest.dentWorld = dentWorld end
