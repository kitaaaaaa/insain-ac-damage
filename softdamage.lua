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

local DEFAULTS = {
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
  maxOffset = 3,       -- how far an atom can be pushed in total (3: unlimited)
  maxBodyIn = 3,       -- the most any spot of the body moves (3: unlimited)
  interiorBlocks = true, -- the body doesn't go through the interior: it crumples against it
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
  bendTime = 0.3,      -- seconds the metal takes to bend in (0: at once)
  repairRate = 25,     -- repairing slowly (held on a button): per cent of a wreck put right a second
  instantMs = 12,      -- work on a new dent the frame it happens (most of it shows at once)
  budgetMs = 4,        -- work per frame on dents (re-skinning) after that, first
  setupBudgetMs = 2,   -- then on reading cars
  sendBudget = 400000, -- vertices sent to AC a frame at most (alterVertices), the rest the next
}
local settings = ac.storage(DEFAULTS)

-- Every setting back to its default (the ones marked "rebuild" apply to cars read after).
local function resetSettings()
  for k, v in pairs(DEFAULTS) do settings[k] = v end
end

local sim = ac.getSim()
local PACK = 16777216  -- (mesh, vertex) pairs in one number: mesh * PACK + vertex
local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
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
      else k = k + 1 end  -- (it yielded: its turn's over; the next, if there's time)
    end
  end
end
local function runJobs()
  -- a new dent gets a bigger first slice (instantMs), so most of it shows the frame it happens
  local ms = settings.budgetMs
  for _, j in ipairs(jobs) do
    if not j.setup and j.body.fresh then ms = math.max(ms, settings.instantMs) j.body.fresh = false end
  end
  runPhase(false, ms)
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

-- Which wheel a mesh is part of, if any: centred on its hub (within a third of the tyre's radius), about as
-- tall and long as the tyre (1.3 to 2.6 radii), and no wider than the wheel's space. Else nil.
local function wheelOf(wheels, mn, mx)
  for k, W in ipairs(wheels) do
    local r = W[6]
    local cx, cy, cz = (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2
    local sy, sz, sx = mx[2] - mn[2], mx[3] - mn[3], mx[1] - mn[1]
    if math.sqrt((cx - W[1]) ^ 2 + (cy - W[2]) ^ 2 + (cz - W[3]) ^ 2) < r * 0.35
      and sy > r * 1.3 and sy < r * 2.6 and sz > r * 1.3 and sz < r * 2.6 and sx < W[5] * 2 then
      return k
    end
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
    -- the wheels (body space, at rest): where each is and how big its tyre (from AC). Used to keep the wheel
    -- wells clear of them (each a cylinder across the car, a little bigger than the tyre for the suspension's
    -- travel, wider at the front for the steering), and to tell which meshes are wheels
    body.wheels, body.wheelParts = {}, {}
    local carNow = ac.getCar(i)
    for w = 0, 3 do
      local wh = carNow and carNow.wheels and carNow.wheels[w]
      if wh and wh.position then
        local p = invBody:transformPoint(wh.position)
        local r = (wh.tyreRadius and wh.tyreRadius > 0.01) and wh.tyreRadius or 0.33
        local hw = ((wh.tyreWidth and wh.tyreWidth > 0.005) and wh.tyreWidth or r * 0.75) / 2
        body.wheels[#body.wheels + 1] = {p.x, p.y, p.z, r * 1.2, hw + r * (w < 2 and 0.3 or 0.12), r, hw}
        trace('car %d: wheel %d, radius %.3f m, width %.3f m', i, w, r, hw * 2)
      end
    end
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
          local turns = moving and (moving:upper():find('WHEEL', 1, true) or moving:upper():find('RIM', 1, true)
            or moving:upper():find('TYRE', 1, true) or moving:upper():find('TIRE', 1, true))
          if turns then
            list[#list + 1] = {ref = ref, name = name, outside = true, wheelCandidate = moving}
          elseif moving then
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
        -- work: the copy read now, which the dents go into (no copying at crash time); op: the original positions
        -- and normals (mesh space, 6 floats a vertex), to put back
        local mesh = {ref = ref, name = name, work = verts, op = arrays.floats(verts:size() * 6), n = verts:size(), interior = kind == 'interior',
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
        local op = mesh.op
        for v = 0, mesh.n - 1 do
          local p, nn = raw[v].pos, raw[v].normal
          op[v * 6], op[v * 6 + 1], op[v * 6 + 2], op[v * 6 + 3], op[v * 6 + 4], op[v * 6 + 5] = p.x, p.y, p.z, nn.x, nn.y, nn.z
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
        -- a wheel's part: centred on a wheel's hub and about as big as its tyre, whatever it's called and wherever
        -- it hangs in the model (CSP's replacement wheels too). Not bodywork: it turns with the wheel, and
        -- bends with it on a hard hit (see bendWheel)
        local wk = wheelOf(body.wheels, mmin, mmax)
        if wk then
          local W = body.wheels[wk]
          mesh.wheel = wk
          mesh.hubM = invParent:transformPoint(bodyWorld:transformPoint(vec3(W[1], W[2], W[3])))
          mesh.tilt = {1, 0, 0, 0, 1, 0, 0, 0, 1}
          body.wheelParts[#body.wheelParts + 1] = mesh
          status = where .. ('wheel %d: turns with it, bends on hard hits'):format(wk)
          trace('mesh %d/%d: wheel %d', m, body.meshCount, wk)
        elseif item.wheelCandidate then
          status = 'outside BODYTR, on a moving part (' .. item.wheelCandidate .. '): left alone'
        else
          body.meshes[#body.meshes + 1] = mesh
          item.mesh = mesh
          body.vertices = body.vertices + mesh.n
        end
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
      min[a] = math.max(min[a], bmin[a] - 0.6)
      max[a] = math.min(max[a], bmax[a] + 0.6)
    end
    -- the car's size against an ordinary car's (4.5 m): the hull's spacing, dents, crunch and margins scale with
    -- it, so a model car half a metre long dents like a real one, not as if hit by something its own size
    body.scale = math.max(0.05, math.min(2, (max[3] - min[3]) / 4.5))
    for a = 1, 3 do min[a], max[a] = min[a] - 0.05 * body.scale, max[a] + 0.05 * body.scale end
    trace('car %d: %.2f m long: scale %.2f', i, max[3] - min[3], body.scale)
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
      body.atoms = lattice.new(min, max, math.max(0.02, settings.spacing * body.scale))
      for mi, mesh in ipairs(body.meshes) do
        for v = 0, mesh.n - 1 do
          use(lattice.cellOf(body.atoms, mesh.px[v], mesh.py[v], mesh.pz[v]), mi, v)
          if v % 4000 == 0 then t0 = budget(t0) end
        end
      end
    else
      body.kind = 'hull'
      trace('car %d: building the hull', i)
      body.atoms = hull.new(body.meshes, min, max, math.max(0.02, settings.hullRing * body.scale), math.floor(settings.hullAround + 0.5),
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
    local key = settings.crunchStyle .. settings.crunchSize * body.scale
    body.noiseKey, body.noiseVer = key, 1
    local crunchFn = settings.crunchStyle == 'hammered' and noise.fbm or noise.ridged
    local f, no = 1 / (settings.crunchSize * body.scale), body.noiseOffset
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
    local G = math.max(0.01, 0.1 * body.scale)
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
    for _, mesh in ipairs(body.meshes) do
      if not mesh.interior and #body.wheels > 0 then
        local near = 0
        for v = 0, mesh.n - 1 do
          local x, y, z = mesh.px[v], mesh.py[v], mesh.pz[v]
          for k, W in ipairs(body.wheels) do
            local ax = math.abs(x - W[1])
            local dyz = math.sqrt((y - W[2]) ^ 2 + (z - W[3]) ^ 2)
            if ax < W[5] + W[6] * 1.2 and dyz < W[4] + W[6] * 1.2 then
              if not mesh.wheelI then mesh.wheelI, mesh.wheelPen = arrays.bytes(mesh.n), arrays.floats(mesh.n) end
              -- which wheel (and which side of it: 1 or 2 more than 4 for the inner side), and how far into its
              -- space the vertex is at rest
              mesh.wheelI[v] = k + ((x - W[1]) * (W[1] >= 0 and 1 or -1) < 0 and 4 or 0)
              mesh.wheelPen[v] = math.max(0, math.min(W[5] - ax, W[4] - dyz))
              near = near + 1
              break
            end
          end
          if v % 2000 == 0 then t0 = budget(t0) end
        end
        if near > 0 then trace('"%s": %d vertices by the wheels', mesh.name, near) end
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

-- A vertex back as it was (into mesh.work).
local function putBack(mesh, v)
  local r, op, k = mesh.work.raw[v], mesh.op, v * 6
  r.pos.x, r.pos.y, r.pos.z = op[k], op[k + 1], op[k + 2]
  r.normal.x, r.normal.y, r.normal.z = op[k + 3], op[k + 4], op[k + 5]
end

-- Bending: a vertex isn't put where a dent moves it at once; it eases there over settings.bendTime (game
-- time), fast at first and settling (ease-out), so the metal is seen giving way. Each vertex from wherever it
-- is shown now, so a hit landing mid-bend carries on smoothly. The work per frame is a blend per bending vertex
-- (the dent itself, where each vertex ends up, is worked out once).
local animClock, frameDt = 0, 1 / 60
local animating = {}  -- meshes with vertices on their way
local function animArrays(mesh)
  local n = mesh.n
  mesh.af, mesh.at = arrays.floats(n * 6), arrays.floats(n * 6)  -- from, and the change: position and normal
  mesh.as, mesh.aon, mesh.alist, mesh.an = arrays.floats(n), arrays.bytes(n), arrays.ints(n), 0
end
local function stopBending(mesh)
  if mesh.aon and mesh.an > 0 then
    for i = 0, mesh.an - 1 do mesh.aon[mesh.alist[i]] = 0 end
    mesh.an = 0
  end
  animating[mesh] = nil
end
-- A vertex's new place (mesh space): shown at once (bend 0), or eased to.
local function show(bendTime, mesh, v, x, y, z, nx, ny, nz)
  -- never anything but a finite number to AC (a NaN or a huge value in a vertex could take the game down)
  if not (x == x and y == y and z == z and nx == nx and ny == ny and nz == nz and x * x + y * y + z * z < 1e8) then
    if not mesh.badWarned then mesh.badWarned = true trace('"%s": a vertex came out not finite: left as it was', mesh.name) end
    return
  end
  local r = mesh.work.raw[v]
  if bendTime <= 0 then
    if mesh.aon and mesh.aon[v] == 1 then  -- (if bending: there now, at the next step)
      local k, af = v * 6, mesh.af
      af[k], af[k + 1], af[k + 2], af[k + 3], af[k + 4], af[k + 5] = x, y, z, nx, ny, nz
      mesh.at[k], mesh.at[k + 1], mesh.at[k + 2], mesh.at[k + 3], mesh.at[k + 4], mesh.at[k + 5] = 0, 0, 0, 0, 0, 0
      mesh.as[v] = -1e9
    end
    r.pos.x, r.pos.y, r.pos.z, r.normal.x, r.normal.y, r.normal.z = x, y, z, nx, ny, nz
    return
  end
  local px, py, pz = r.pos.x, r.pos.y, r.pos.z
  if (x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2 < 0.001 ^ 2 and not (mesh.aon and mesh.aon[v] == 1) then
    r.pos.x, r.pos.y, r.pos.z, r.normal.x, r.normal.y, r.normal.z = x, y, z, nx, ny, nz  -- (under a mm: at once)
    return
  end
  if not mesh.af then animArrays(mesh) end
  local k = v * 6
  local af, at = mesh.af, mesh.at  -- from, and the change (to - from)
  af[k], af[k + 1], af[k + 2], af[k + 3], af[k + 4], af[k + 5] = px, py, pz, r.normal.x, r.normal.y, r.normal.z
  at[k], at[k + 1], at[k + 2] = x - px, y - py, z - pz
  at[k + 3], at[k + 4], at[k + 5] = nx - af[k + 3], ny - af[k + 4], nz - af[k + 5]
  mesh.as[v] = animClock
  if mesh.aon[v] == 0 then
    mesh.aon[v] = 1
    mesh.alist[mesh.an] = v
    mesh.an = mesh.an + 1
  end
  animating[mesh] = true
end
-- Moves every bending vertex on to where it is now in its bend; returns the meshes that changed.
local function bendStep()
  local T = math.max(1e-3, settings.bendTime)
  local changed = {}
  for mesh in pairs(animating) do
    if mesh.moving then stopBending(mesh) else
      local raw, af, at, as, aon, alist = mesh.work.raw, mesh.af, mesh.at, mesh.as, mesh.aon, mesh.alist
      local i = 0
      while i < mesh.an do
        local v = alist[i]
        local f = (animClock - as[v]) / T
        local k, r = v * 6, raw[v]
        if f >= 1 then
          r.pos.x, r.pos.y, r.pos.z = af[k] + at[k], af[k + 1] + at[k + 1], af[k + 2] + at[k + 2]
          r.normal.x, r.normal.y, r.normal.z = af[k + 3] + at[k + 3], af[k + 4] + at[k + 4], af[k + 5] + at[k + 5]
          aon[v] = 0
          mesh.an = mesh.an - 1
          alist[i] = alist[mesh.an]
        else
          local g = 1 - f
          local e = 1 - g * g * g  -- ease-out: fast at first, settling
          r.pos.x, r.pos.y, r.pos.z = af[k] + at[k] * e, af[k + 1] + at[k + 1] * e, af[k + 2] + at[k + 2] * e
          -- (the normal blended: a touch short of unit length mid-bend; the shading normalises it)
          r.normal.x, r.normal.y, r.normal.z = af[k + 3] + at[k + 3] * e, af[k + 4] + at[k + 4] * e, af[k + 5] + at[k + 5] * e
          i = i + 1
        end
      end
      changed[#changed + 1] = mesh
      if mesh.an == 0 then animating[mesh] = nil end
    end
  end
  return changed
end

-- Shows a mesh's new vertices. 'direct': the car's own mesh takes them. 'copy': at its first dent, a copy of the
-- mesh is made under the same node with the same material and the original hidden; the copy takes them.
local function send(mesh)
  if not mesh.work then return end
  if settings.method == 'direct' and not mesh.copy then
    if not mesh.sent then trace('alterVertices "%s" (%d vertices), first time', mesh.name, mesh.n) end
    mesh.ref:alterVertices(mesh.work)
    if not mesh.sent then trace('alterVertices "%s": done', mesh.name) end
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
  -- along the way the metal was pushed (its surface's normal where it hardly moved): along each vertex's own
  -- normal, round parts (tubes, bars) went in and out all round, and looked swollen
  local d = crunch * cache[n4]
  local ol = math.sqrt(ox * ox + oy * oy + oz * oz)
  local w = math.min(1, ol * 200)  -- (blends to the normal below 5 mm; no branch: LuaJIT compiles it)
  local io = w / math.max(ol, 1e-9)
  local ux, uy, uz = nx0 * (1 - w) + ox * io, ny0 * (1 - w) + oy * io, nz0 * (1 - w) + oz * io
  ox, oy, oz = ox + ux * d, oy + uy * d, oz + uz * d
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
  local raw, op, k6 = mesh.work.raw, mesh.op, v * 6
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
      local op = mesh.op
      show(ctx.bend, mesh, v, op[k6], op[k6 + 1], op[k6 + 2], op[k6 + 3], op[k6 + 4], op[k6 + 5])
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
  -- how far it may move: the interior a quarter foot; the body as far as it's pushed (or a setting), but not
  -- through the interior behind it. Beyond that the metal crumples instead: the excess goes to the crunch
  local limit = maxInterior
  if not mesh.interior then
    limit = ctx.maxBody
    -- not through the interior: only as far as closes the gap to it (less 1.5 cm). The interior there moves in
    -- with the body too, so the gap's only ever bigger than that
    if ctx.interiorBlocks then limit = math.min(limit, math.max(0, mesh.clear[v] - 0.015 * ctx.scale)) end
  end
  local len = math.sqrt(ox * ox + oy * oy + oz * oz)
  local k = len > limit and limit / len or 1
  ox, oy, oz = ox * k, oy * k, oz * k
  crunch = math.min(ctx.maxCrunch, crunch + math.max(0, len - limit) * 0.3)
  -- crunch: the metal pushed in and out along its surface's normal by noise (creases ~crunchSize and finer), as
  -- much as the crunch there; the normal tilts with the noise's slope
  if crunch > 1e-4 then ox, oy, oz, qx, qy, qz = crunchVertex(ctx, mesh, v, ox, oy, oz, qx, qy, qz, crunch, limit) end
  -- the wheel wells: not into the wheels' space (deeper than it was at rest): back out the shorter way, sideways
  -- or out from the axle
  local wi = mesh.wheelI and mesh.wheelI[v] or 0
  if wi > 0 then
    -- the side of the wheel the vertex started on: going in from there counts all the way through (a panel
    -- pushed right through the tyre is in it, not out the other side)
    local inner = wi > 4
    local W = ctx.wheels[inner and wi - 4 or wi]
    local out = (W[1] >= 0 and 1 or -1) * (inner and -1 or 1)  -- which way is out, across the car
    local x, y, z = mesh.px[v] + ox, mesh.py[v] + oy, mesh.pz[v] + oz
    local dx, ry, rz = x - W[1], y - W[2], z - W[3]
    local dyz = math.sqrt(ry * ry + rz * rz)
    local side, round = W[5] - dx * out, W[4] - dyz  -- how far in, each way
    local allowed = mesh.wheelPen[v]
    if side > allowed and round > allowed then
      if round < side and dyz > 1e-6 then
        local k = (W[4] - allowed) / dyz
        y, z = W[2] + ry * k, W[3] + rz * k
      else
        x = W[1] + out * (W[5] - allowed)
      end
      ox, oy, oz = x - mesh.px[v], y - mesh.py[v], z - mesh.pz[v]
    end
  end
  -- the offset and normal into the mesh's own space
  local T = mesh.toMesh
  local mx, my, mz = T[1] * qx + T[4] * qy + T[7] * qz, T[2] * qx + T[5] * qy + T[8] * qz, T[3] * qx + T[6] * qy + T[9] * qz
  local ml = math.sqrt(mx * mx + my * my + mz * mz)
  if ml < 1e-9 then ml = 1 end
  show(ctx.bend, mesh, v, op[k6] + T[1] * ox + T[4] * oy + T[7] * oz, op[k6 + 1] + T[2] * ox + T[5] * oy + T[8] * oz,
    op[k6 + 2] + T[3] * ox + T[6] * oy + T[9] * oz, mx / ml, my / ml, mz / ml)
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
              for v = 0, mesh.n - 1 do if mesh.moved[v] == 1 then putBack(mesh, v) end end
              arrays.zero(mesh.moved, mesh.n)
              stopBending(mesh)
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
      local key = settings.crunchStyle .. settings.crunchSize * body.scale
      if body.noiseKey ~= key then body.noiseKey, body.noiseVer = key, (body.noiseVer or 0) % 255 + 1 end
      local ctx = {isHull = isHull, l = l, share = settings.interiorShare, interiorBlocks = settings.interiorBlocks,
        maxBody = settings.maxBodyIn >= 2.99 and 1e9 or settings.maxBodyIn,
        maxInterior = settings.maxInteriorIn * body.scale, maxCrunch = settings.maxCrunch * body.scale, crunchFn = crunchFn,
        scale = body.scale,
        bend = body.instantNext and 0 or settings.bendTime,
        cf = 1 / (settings.crunchSize * body.scale), no = body.noiseOffset, noiseVer = body.noiseVer, wheels = body.wheels}
      -- nearest the dent first: what's there shows in the first frame, the edges after
      local keys = {}
      for key in pairs(isHull and hull.takeChanged(l) or lattice.takeChanged(l)) do keys[#keys + 1] = key end
      local at = body.lastDent
      if at and #keys > 1 then
        local dist = {}
        for _, key in ipairs(keys) do
          local x, y, z
          if isHull then
            local a, b, c = l.ta[key], l.tb[key], l.tc[key]
            x, y, z = (l.ax[a] + l.ax[b] + l.ax[c]) / 3, (l.ay[a] + l.ay[b] + l.ay[c]) / 3, (l.az[a] + l.az[b] + l.az[c]) / 3
          else
            local nx, ny = l.n[1], l.n[2]
            local ci, cj, ck = key % nx, math.floor(key / nx) % ny, math.floor(key / (nx * ny))
            x, y, z = lattice.nodePos(l, ci + 0.5, cj + 0.5, ck + 0.5)
          end
          dist[key] = (x - at.x) ^ 2 + (y - at.y) ^ 2 + (z - at.z) ^ 2
        end
        table.sort(keys, function(p, q) return dist[p] < dist[q] end)
      end
      for _, key in ipairs(keys) do
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
                putBack(mesh, v)
                mesh.moved[v] = 0
                mesh.movedCount = (mesh.movedCount or 1) - 1
                changed[mesh] = true
              end
              mesh = nil
            end
            if mesh then
              if not mesh.noise then mesh.noise, mesh.noiseVer = arrays.floats(mesh.n * 4), arrays.bytes(mesh.n) end
              if skinVertex(ctx, mesh, v) then changed[mesh] = true end
            end
            count = count + 1
            if count % 1000 == 0 then
              local t = nowMs()
              if t - t0 > jobBudget then
                -- what's done so far goes to AC now (the dent shows as it's made), the rest next frame
                for mesh in pairs(changed) do sendQueue[#sendQueue + 1] = mesh end
                changed = {}
                work = work + (t - t0)
                t0 = coroutine.yield()
              end
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
    body.instantNext = nil
  end)
  jobs[#jobs + 1] = {co = co, name = 'skin car ' .. body.index, body = body}
end

-- Puts every mesh back as it was, now (not over frames).
local function restoreNow(body)
  for _, mesh in ipairs(body and body.wheelParts or {}) do
    stopBending(mesh)
    if mesh.tilt and (mesh.tilt[1] ~= 1 or mesh.tilt[5] ~= 1) then
      for v = 0, mesh.n - 1 do putBack(mesh, v) end
      mesh.ref:alterVertices(mesh.work)
    end
  end
  for _, mesh in ipairs(body and body.meshes or {}) do
    if mesh.copy then
      mesh.copy:dispose()
      mesh.copy = nil
      mesh.ref:setVisible(true)
    end
    if mesh.movedCount and mesh.movedCount > 0 then
      for v = 0, mesh.n - 1 do if mesh.moved[v] == 1 then putBack(mesh, v) end end
    end
    if mesh.sent and not mesh.moving then mesh.ref:alterVertices(mesh.work) end
    arrays.zero(mesh.moved, mesh.n)
    stopBending(mesh)
    mesh.sent, mesh.movedCount = nil, 0
  end
end
-- unloading (AC closing, the app reloaded): the originals back
ac.onRelease(function() for _, body in pairs(cars) do restoreNow(body) end end)

-- Bent wheels: a hard hit near a wheel tilts its parts a little about the hub, across the way they turn, so the
-- wheel wobbles as it turns (a bent rim or axle). `angle` radians more, the tilt towards the push (body space
-- `dir`); 6 degrees at most in all. The parts bend in like the body (see show).
local MAX_TILT = 0.1
local function tiltOf(m) return math.acos(math.max(-1, math.min(1, m[1]))) end
-- A wheel part tilted by P (3 x 3, its own space) about its hub: shown (eased over bendTime) and sent.
local function applyTilt(mesh, P, bendTime)
  mesh.tilt = P
  local h, op = mesh.hubM, mesh.op
  for v = 0, mesh.n - 1 do
    local k6 = v * 6
    local x, y, z = op[k6] - h.x, op[k6 + 1] - h.y, op[k6 + 2] - h.z
    local nx, ny, nz = op[k6 + 3], op[k6 + 4], op[k6 + 5]
    show(bendTime, mesh, v, h.x + P[1] * x + P[2] * y + P[3] * z, h.y + P[4] * x + P[5] * y + P[6] * z,
      h.z + P[7] * x + P[8] * y + P[9] * z, P[1] * nx + P[2] * ny + P[3] * nz, P[4] * nx + P[5] * ny + P[6] * nz,
      P[7] * nx + P[8] * ny + P[9] * nz)
  end
  sendQueue[#sendQueue + 1] = mesh
end
-- The same rotation, f of the way (0: none, 1: all of it).
local function partRotation(M, f)
  local angle = math.acos(math.max(-1, math.min(1, (M[1] + M[5] + M[9] - 1) / 2)))
  if angle < 1e-6 or f <= 0 then return {1, 0, 0, 0, 1, 0, 0, 0, 1} end
  local s2 = 2 * math.sin(angle)
  local ux, uy, uz = (M[8] - M[6]) / s2, (M[3] - M[7]) / s2, (M[4] - M[2]) / s2
  local a = angle * f
  local c, sn = math.cos(a), math.sin(a)
  return {c + ux * ux * (1 - c), ux * uy * (1 - c) - uz * sn, ux * uz * (1 - c) + uy * sn,
    uy * ux * (1 - c) + uz * sn, c + uy * uy * (1 - c), uy * uz * (1 - c) - ux * sn,
    uz * ux * (1 - c) - uy * sn, uz * uy * (1 - c) + ux * sn, c + uz * uz * (1 - c)}
end
local function bendWheel(body, k, dir, angle)
  if angle < 0.002 then return end
  for _, mesh in ipairs(body.wheelParts) do
    if mesh.wheel == k and mesh.work then
      -- the turning axis, and the tilt's axis across it (towards the push), in the part's own space
      local T = mesh.toMesh
      local axx, axy, axz = T[1], T[2], T[3]  -- body x (the axle) into mesh space
      local al = math.sqrt(axx * axx + axy * axy + axz * axz)
      axx, axy, axz = axx / al, axy / al, axz / al
      local dx, dy, dz = T[1] * dir.x + T[4] * dir.y + T[7] * dir.z, T[2] * dir.x + T[5] * dir.y + T[8] * dir.z, T[3] * dir.x + T[6] * dir.y + T[9] * dir.z
      local ux, uy, uz = cross(axx, axy, axz, dx, dy, dz)  -- across both the axle and the push
      local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
      if ul < 1e-6 then ux, uy, uz = cross(axx, axy, axz, 0, 1, 0) ul = math.sqrt(ux * ux + uy * uy + uz * uz) end
      if ul < 1e-6 then ux, uy, uz, ul = 0, 0, 1, 1 end
      ux, uy, uz = ux / ul, uy / ul, uz / ul
      -- this bend (Rodrigues) after the ones before, the whole no more than MAX_TILT
      local c, sn = math.cos(angle), math.sin(angle)
      local R = {c + ux * ux * (1 - c), ux * uy * (1 - c) - uz * sn, ux * uz * (1 - c) + uy * sn,
        uy * ux * (1 - c) + uz * sn, c + uy * uy * (1 - c), uy * uz * (1 - c) - ux * sn,
        uz * ux * (1 - c) - uy * sn, uz * uy * (1 - c) + ux * sn, c + uz * uz * (1 - c)}
      local M, P = mesh.tilt, {}
      for r = 0, 2 do for q = 0, 2 do
        P[r * 3 + q + 1] = R[r * 3 + 1] * M[q + 1] + R[r * 3 + 2] * M[q + 4] + R[r * 3 + 3] * M[q + 7]
      end end
      if tiltOf(P) <= MAX_TILT then
        applyTilt(mesh, P, settings.bendTime)
        body.bentWheels = (body.bentWheels or 0) + 1
        trace('car %d: wheel %d bent %.1f degrees ("%s")', body.index, k, math.deg(tiltOf(P)), mesh.name)
      end
    end
  end
end
-- Straightens the wheels (a repair).
local function straightenWheels(body)
  for _, mesh in ipairs(body.wheelParts or {}) do
    if mesh.tilt[1] ~= 1 or mesh.tilt[5] ~= 1 then
      stopBending(mesh)
      for v = 0, mesh.n - 1 do putBack(mesh, v) end
      mesh.tilt = {1, 0, 0, 0, 1, 0, 0, 0, 1}
      sendQueue[#sendQueue + 1] = mesh
    end
  end
  body.bentWheels = 0
end

local function repair(body)
  if not body or not body.atoms then return end
  if body.kind == 'hull' then hull.reset(body.atoms) else lattice.reset(body.atoms) end
  body.dents = 0
  for _, mesh in ipairs(body.meshes) do stopBending(mesh) end
  straightenWheels(body)
  body.instantNext = true  -- (a repair is at once)
  skin(body)
end

-- Repairing slowly (held on a button, as in Carmageddon): the damage goes back a step a frame, settings.repairRate
-- per cent of a wreck a second. The atoms' offsets (and crunch) and every moved vertex go the same fraction of
-- the way back each frame (a blend, cheap and smooth; the next dent starts from the shape this leaves), bent
-- wheels straighten as much; at nothing left, an exact repair. Each step is told to other apps
-- ('softdamage.repair': {car, repaired, damage}, per cent of a wreck), and one (Carmapeds) can stop it while
-- there's no money for it ('softdamage.repairBlocked': {car, blocked}).
local repairBlocked = {}
if ac.onSharedEvent then
  ac.onSharedEvent('softdamage.repairBlocked', function(ev)
    if type(ev) == 'table' and type(ev.car) == 'number' then repairBlocked[ev.car] = ev.blocked == true end
  end)
end
local repairButton = ac.ControlButton and ac.ControlButton('__APP_SOFTDAMAGE_REPAIR_SLOWLY') or nil

-- How damaged a car is: per cent of a wreck (every atom in by 15 cm, scaled to the car), at most 100.
local function damageOf(body)
  local l = body.atoms
  if not l then return 0 end
  local sum = 0
  for n = 0, l.count - 1 do sum = sum + math.sqrt(l.dx[n] * l.dx[n] + l.dy[n] * l.dy[n] + l.dz[n] * l.dz[n]) end
  -- over the atoms on the car's outside: all of the hull's; the box lattice's on its outer faces (most of the
  -- rest are inside the car, or in the air round it)
  local outside = l.count
  if body.kind == 'box' then
    local nx, ny, nz = l.n[1], l.n[2], l.n[3]
    outside = math.max(1, nx * ny * nz - math.max(0, nx - 2) * math.max(0, ny - 2) * math.max(0, nz - 2))
  end
  return math.min(100, 100 * sum / (outside * 0.15 * body.scale))
end

local function repairStep(body, dt)
  if body.skinning then return end  -- (a dent still being worked out: next frame)
  local D = damageOf(body)
  local bent = false
  for _, mesh in ipairs(body.wheelParts) do if tiltOf(mesh.tilt) > 1e-4 then bent = true end end
  if D < 0.05 and not bent then
    if body.dents > 0 then
      if D > 0 and ac.broadcastSharedEvent then ac.broadcastSharedEvent('softdamage.repair', {car = body.index, repaired = D, damage = 0}) end
      repair(body)
    end
    return
  end
  local k = D > 0.05 and math.min(1, settings.repairRate * dt / D) or math.min(1, settings.repairRate * dt / 5)
  local keep = 1 - k
  local l = body.atoms
  for n = 0, l.count - 1 do
    l.dx[n], l.dy[n], l.dz[n], l.cr[n] = l.dx[n] * keep, l.dy[n] * keep, l.dz[n] * keep, l.cr[n] * keep
  end
  for _, mesh in ipairs(body.meshes) do
    if (mesh.movedCount or 0) > 0 and not mesh.moving then
      stopBending(mesh)
      local raw, op, moved = mesh.work.raw, mesh.op, mesh.moved
      for v = 0, mesh.n - 1 do
        if moved[v] == 1 then
          local r, k6 = raw[v], v * 6
          r.pos.x, r.pos.y, r.pos.z = op[k6] + (r.pos.x - op[k6]) * keep, op[k6 + 1] + (r.pos.y - op[k6 + 1]) * keep, op[k6 + 2] + (r.pos.z - op[k6 + 2]) * keep
          r.normal.x = op[k6 + 3] + (r.normal.x - op[k6 + 3]) * keep
          r.normal.y = op[k6 + 4] + (r.normal.y - op[k6 + 4]) * keep
          r.normal.z = op[k6 + 5] + (r.normal.z - op[k6 + 5]) * keep
        end
      end
      sendQueue[#sendQueue + 1] = mesh
    end
  end
  for _, mesh in ipairs(body.wheelParts) do
    if mesh.tilt[1] ~= 1 or mesh.tilt[5] ~= 1 then
      stopBending(mesh)
      applyTilt(mesh, partRotation(mesh.tilt, keep), 0)
    end
  end
  if ac.broadcastSharedEvent then
    ac.broadcastSharedEvent('softdamage.repair', {car = body.index, repaired = D * k, damage = D * keep})
  end
  body.repairing = true
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
    crunchFor(depth, (severity or depth / (0.1 * body.scale)) * give), settings.maxCrunch * body.scale)
  body.dents = body.dents + 1
  body.lastDent = {x = p.x, y = p.y, z = p.z}
  body.fresh = true
  skin(body)
  -- a wheel near the hit: bent, if the hit was deep enough
  for k, W in ipairs(body.wheels) do
    local dist = math.sqrt((p.x - W[1]) ^ 2 + (p.y - W[2]) ^ 2 + (p.z - W[3]) ^ 2)
    local reach = W[6] * 1.6 + radius
    if dist < reach and depth > W[6] * 0.25 then
      bendWheel(body, k, d, math.min(0.05, (depth / W[6]) * 0.08) * (1 - dist / reach))
    end
  end
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
  dentWorld(body, hit, dirW, settings.depth * body.scale, settings.radius * body.scale)
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
local STEP = 3  -- m/s: a hit still building gets more dent each time it's this much harder
local crash = {}

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
local function crashDepth(speed) return (speed - MIN_HIT) * 0.025 * settings.crashScale + 0.01 end
local function makeCrashDent(i, body, r, dir, speed, dvLen, along, from)
  -- the push mostly level in the car's frame: a hard crash's speed change often has a big up or down part (AC
  -- lifting or pressing the car), which aimed dents down onto the bonnet instead of into the bumper. Kept as it is
  -- when it's mostly up or down (a roll onto the roof)
  do
    local Wb = body.node:getWorldTransformationRaw()
    local dl = Wb:inverse():transformVector(dir)
    if math.abs(dl.y) < 0.75 then
      dl.y = dl.y * 0.3
      dir = Wb:transformVector(dl):normalize()
    end
  end
  -- where it hit, in the car's frame. Along the push, the motion can't tell (a push straight along the car says
  -- nothing about how far along it landed): a ray from outside the car along the push finds the surface. Its
  -- height isn't trusted either: in a hard hit the car pitches (the nose dives), which the motion read as a
  -- contact high up, and the ray went over the bonnet into the windscreen. A level hit lands at bumper height
  -- (a third of the way up the body)
  local mn, mx = body.min, body.max
  local W = body.node:getWorldTransformationRaw()
  local inv = W:inverse()
  local rl, dl = inv:transformVector(r), inv:transformVector(dir):normalize()
  local ax = (mn[1] + mx[1]) / 2 + rl.x
  local ay = (mn[2] + mx[2]) / 2 + rl.y
  local az = (mn[3] + mx[3]) / 2 + rl.z
  if math.abs(dl.y) < 0.75 then ay = mn[2] + (mx[2] - mn[2]) * 0.35 end
  local far = (mx[1] - mn[1]) + (mx[2] - mn[2]) + (mx[3] - mn[3])  -- (from well outside the car)
  local ox, oy, oz = ax - dl.x * far, ay - dl.y * far, az - dl.z * far
  local hit
  local t = body.kind == 'hull' and hull.raycast(body.atoms, ox, oy, oz, dl.x, dl.y, dl.z) or nil
  if t then
    hit = W:transformPoint(vec3(ox + dl.x * t, oy + dl.y * t, oz + dl.z * t))
  else
    local from = W:transformPoint(vec3(ox, oy, oz))
    hit = hitCar(body, from, dir) or W:transformPoint(vec3(ax, ay, az))
  end
  -- (a hit still building: only what it adds to its dent so far)
  from = from or 0
  local depth = (math.min(settings.maxOffset, crashDepth(speed)) - (from > 0 and math.min(settings.maxOffset, crashDepth(from)) or 0)) * body.scale
  if depth <= 0 then return end
  trace('crash: car %d, %.1f m/s at the contact (%.1f at the middle), %.2f m from the middle (along %.2f): dent %.3f m%s',
    i, speed, dvLen, r:length(), along, depth, from > 0 and (' more (was %.1f m/s)'):format(from) or '')
  -- harder hits go deeper, not wider (a wide dent looked like the whole corner hit from all sides)
  dentWorld(body, hit, dir, depth, math.min(0.6, 0.35 + 0.01 * speed) * body.scale, speed / 12)
  body.lastCrash = speed
  if from == 0 then body.crashes = (body.crashes or 0) + 1 end
end

local function crashDent(i, body, r, dir, speed, dvLen, along, from)
  -- in the car's frame now (it moves on while waiting): r and dir kept relative to the body
  local inv = body.node:getWorldTransformationRaw():inverse()
  if #crashQueue >= 32 then table.remove(crashQueue, 1) end
  crashQueue[#crashQueue + 1] = {i = i, body = body, r = inv:transformVector(r), dir = inv:transformVector(dir), speed = speed,
    dvLen = dvLen, along = along, from = from}
end

local function nextCrashDent()
  local q = table.remove(crashQueue, 1)
  if not q then return end
  if cars[q.i] ~= q.body or q.body.state ~= 'ready' then return end
  local W = q.body.node:getWorldTransformationRaw()
  makeCrashDent(q.i, q.body, W:transformVector(q.r), W:transformVector(q.dir):normalize(), q.speed, q.dvLen, q.along, q.from)
end

-- Crashes of cars not read yet: kept (in the car's own axes) until the car is, then dented.
local pending = {}
local function carAxes(car)
  local l, u = car.look, car.up
  local sx, sy, sz = cross(u.x, u.y, u.z, l.x, l.y, l.z)
  return vec3(sx, sy, sz):normalize(), u, l
end

local requestSetup  -- (below)

-- Where and how hard the hit so far was (since the impact began): r (world) from the car's middle, rl the same
-- in the car's own frame, the push's direction, the speed change at the contact point and at the middle; and the
-- car's axes (for a car not read yet). r = k^2 (dv x dw) / |dv|^2, kept inside the car's box.
local function crashHit(car, body, ready, c, wx, wy, wz, L, Wd, Hd)
  local up = car.up
  local dvx, dvy, dvz = c.maxDv.x, c.maxDv.y, c.maxDv.z
  -- a push from below (along the car's up): mostly the suspension's
  local vu = dvx * up.x + dvy * up.y + dvz * up.z
  if vu > 0 then
    local cut = vu * (1 - FROM_BELOW)
    dvx, dvy, dvz = dvx - up.x * cut, dvy - up.y * cut, dvz - up.z * cut
  end
  local dv2 = dvx * dvx + dvy * dvy + dvz * dvz
  if dv2 < 1e-6 then return nil end
  local dwx, dwy, dwz = wx - c.wBefore[1], wy - c.wBefore[2], wz - c.wBefore[3]
  local k2 = (L * L + Wd * Wd) / 12
  local rx, ry, rz = cross(dvx, dvy, dvz, dwx, dwy, dwz)
  rx, ry, rz = rx * k2 / dv2, ry * k2 / dv2, rz * k2 / dv2
  local W, ax, ay, az, rl
  if ready then
    W = body.node:getWorldTransformationRaw()
    rl = W:inverse():transformVector(vec3(rx, ry, rz))
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
  return r, rl, vec3(dvx, dvy, dvz):normalize(), speed, dvLen, ax, ay, az
end

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
    c.at, c.before, c.maxDv, c.dented = 0, c.prevVel:clone(), vec3(), 0
    c.wBefore = {c.w[1], c.w[2], c.w[3]}
  end
  if c.at then
    c.at = c.at + dt
    local b = c.before
    local ex, ey, ez = vel.x - b.x, vel.y - b.y, vel.z - b.z
    if ex * ex + ey * ey + ez * ez > c.maxDv:lengthSquared() then c.maxDv:set(ex, ey, ez) end
    -- dent as soon as the hit is clear, the first frame if it can be: then, if it keeps building over the window
    -- (a hit lasting a few frames), the rest at once as it comes (STEP at a time). Cars not read yet: at the end
    local done = c.at >= IMPACT_WINDOW
    if ready or done then
      local r, rl, dir, speed, dvLen, ax, ay, az = crashHit(car, body, ready, c, wx, wy, wz, L, Wd, Hd)
      if speed and speed > MIN_HIT and dvLen > 1e-3 and speed >= c.dented + (c.dented > 0 and STEP or 0) then
        if ready then
          -- one impact, one place and one way: what it adds as it builds goes where the first dent went
          local W = body.node:getWorldTransformationRaw()
          if c.dented == 0 then
            local inv = W:inverse()
            c.hitR, c.hitDir = inv:transformVector(r), inv:transformVector(dir)
          else
            r, dir = W:transformVector(c.hitR), W:transformVector(c.hitDir):normalize()
          end
          crashDent(i, body, r, dir, speed, dvLen, rl.z, c.dented)
        elseif i == sim.focusedCar or totalVertices() < settings.maxVertices then
          -- not read yet: kept in the car's axes, and the car read first of all
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
        c.dented = speed
      end
    end
    if done then
      c.at = nil
      if c.dented > 0 then c.cool = COOLDOWN end
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
  frameDt = math.max(0, math.min(dt or 0, 0.1))
  if not sim.isPaused then animClock = animClock + frameDt end
  local i = sim.focusedCar
  if settings.readWatched then manageCars() end
  -- Ctrl + left click on the car: a dent there, along the view
  local click = ac.isKeyDown(ac.KeyIndex.Control) and ac.isKeyDown(ac.KeyIndex.LeftButton)
  if click and not wasClick and cars[i] and cars[i].state == 'ready' then
    local ray = render.createMouseRay()
    local body = cars[i]
    local dist = body.node:findMeshes('?'):raycast(ray, false)
    if dist and dist >= 0 then dentWorld(body, ray.pos + ray.dir * dist, ray.dir, settings.depth * body.scale, settings.radius * body.scale) end
  end
  wasClick = click
  -- repairing slowly, while the button's held: the car you're watching (not paused, not while it can't be paid)
  local body = cars[i]
  if repairButton and repairButton:down() and body and body.state == 'ready' and not sim.isPaused and not sim.isReplayActive
    and not repairBlocked[i] then
    repairStep(body, math.max(0, math.min(dt or 0, 0.1)))
  elseif body then
    body.repairing = false
  end
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
  for _, mesh in ipairs(bendStep()) do sendQueue[#sendQueue + 1] = mesh end
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
  mesh.ref:alterVertices(mesh.work)
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
  testLifted.mesh.ref:alterVertices(testLifted.mesh.work)
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
  if repairButton then
    ui.text('Repair slowly (hold):')
    ui.sameLine()
    repairButton:control(vec2(-0.1, 0))
    ui.text(('Damage: %.0f%%%s'):format(damageOf(body), body.repairing and ' (repairing)' or
      (repairBlocked[body.index] and ' (no credits to repair)' or '')))
  end
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
  if ui.button('Reset all settings to their defaults') then resetSettings() end
  ui.separator()
  slider('frontGive', 'Front gives: %.0f%%', 20, 300, 100)
  slider('rearGive', 'Rear gives: %.0f%%', 20, 300, 100)
  slider('sideGive', 'Doors give (pushed sideways): %.0f%%', 20, 300, 100)
  slider('endGive', 'Quarters give (sideways, at the ends): %.0f%%', 20, 300, 100)
  slider('roofGive', 'Roof gives: %.0f%%', 20, 300, 100)
  slider('maxBodyIn', settings.maxBodyIn >= 2.99 and 'Body moves at most: unlimited' or 'Body moves at most: %.2f m', 0.03, 3)
  if ui.checkbox('The body crumples against the interior, not through it', settings.interiorBlocks) then settings.interiorBlocks = not settings.interiorBlocks end
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
  slider('maxOffset', settings.maxOffset >= 2.99 and 'Most an atom moves: unlimited' or 'Most an atom moves: %.2f m', 0.1, 3)
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
  slider('repairRate', 'Repairing slowly: %.0f%% of a wreck a second', 5, 100)
  slider('bendTime', settings.bendTime < 0.01 and 'Metal bends in: at once' or 'Metal bends in over %.2f s', 0, 1)
  slider('instantMs', 'Work on a new dent, its first frame: %.0f ms', 2, 40)
  slider('budgetMs', 'Work per frame after that: %.1f ms', 1, 16)
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

if __softdamageTest then __softdamageTest.busy = function() return next(animating) ~= nil end __softdamageTest.cars = cars __softdamageTest.jobs = jobs __softdamageTest.dentWorld = dentWorld end
