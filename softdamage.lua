-- Soft Body Damage (prototype): visual dents on any car, no per-car setup. The car's body meshes (under its
-- BODYTR node) follow a lattice of "atoms" over the body; dents push atoms in, springs between them spread it,
-- and every vertex moves with the lattice where it sits (src/lattice.lua). Visual only: AC's physics and
-- collisions don't change.
-- This first version is for finding out what works in game: dents from buttons, Ctrl+click on the car, and
-- (experimental) crashes; timings are shown in the window.
local lattice = require('src/lattice')
local noise = require('src/noise')

local settings = ac.storage{
  depth = 0.12,        -- test dent: metres
  radius = 0.45,       -- test dent: metres
  spacing = 0.35,      -- lattice: metres between atoms (applies on rebuild)
  springs = 2,         -- spring passes after each dent (0 = a dent stays exactly where it's pushed)
  maxOffset = 0.5,     -- how far an atom can be pushed in total
  crunch = 1,          -- crunchy damage: noise on dented metal, more the harder the hit (0 = smooth dents)
  crunchSize = 0.25,   -- metres: the size of the biggest creases (finer ones on top)
  crunchStyle = 'creases', -- 'creases' (ridged noise: sharp folds, like crumpled metal) or 'hammered' (bumps)
  maxCrunch = 0.06,    -- metres: the most the crunch moves the metal
  readWatched = true,  -- read the car being watched without pressing the button
  method = 'direct',   -- how dents are shown: 'direct' (the car's own meshes changed) or 'copy' (our own copies
                       -- of the meshes, the originals hidden: createMesh crashed AC in test C)
  crashDents = true,   -- dents from crashes
  crashScale = 1,
  budgetMs = 4,        -- work per frame (setup and re-skinning)
}

local sim = ac.getSim()
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

local function runJobs()
  local t0 = nowMs()
  while #jobs > 0 and nowMs() - t0 < settings.budgetMs do
    local j = jobs[1]
    local ok, err = coroutine.resume(j.co, t0)
    if not ok then log(j.name .. ': ' .. tostring(err)) j.body.error = tostring(err) table.remove(jobs, 1)
    elseif coroutine.status(j.co) == 'dead' then table.remove(jobs, 1) end
  end
end
-- yields when the frame's budget is used up
local function budget(t0) if nowMs() - t0 > settings.budgetMs then t0 = coroutine.yield() end return t0 end

-- Parts that aren't bodywork, by AC's node names: the driver, the steering wheel, the cockpit, and gauge
-- needles (by name). CSP animates some of these itself.
local function excludedPart(ref, meshName)
  if meshName:lower():find('needle', 1, true) then return 'needle' end
  local node = ref:getParent()
  for _ = 1, 12 do
    if node:size() == 0 then break end
    local n = node:name()
    if n == 'BODYTR' then break end
    if n:find('^DRIVER') or n:find('^STEER_') or n:find('^COCKPIT_') or n:lower():find('needle', 1, true) then return n end
    node = node:getParent()
  end
  if meshName:find('^DRIVER') or meshName:find('^STEER_') or meshName:find('^COCKPIT_') then return meshName end
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
    local meshes = bodyNode:findMeshes('?')
    body.meshCount = meshes:size()
    trace('car %d: %d meshes', i, body.meshCount)
    local min, max = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
    for m = 1, meshes:size() do
      local ref = meshes:at(m)
      local name = meshes:name(m)
      body.reading = ('%d/%d %s'):format(m, body.meshCount, name)
      local skip = excludedPart(ref, name)
      if skip then trace('mesh %d/%d "%s": skipped (%s)', m, body.meshCount, name, skip) body.skipped = (body.skipped or 0) + 1 end
      if not skip then trace('mesh %d/%d "%s": getVertices', m, body.meshCount, name) end
      local verts = not skip and ref:getVertices() or nil
      if not skip then
      trace('mesh %d/%d: %s', m, body.meshCount, verts and (verts:size() .. ' vertices') or 'no vertices')
      if verts and verts:size() > 0 and not ref:isPhysicsOnlyMesh() then
        local parentWorld = ref:getParent():getWorldTransformationRaw():clone()
        local invParent = parentWorld:inverse()
        -- mesh -> body: origin and the images of the unit vectors; body -> mesh for offsets and normals
        local function toBody(p) return invBody:transformPoint(parentWorld:transformPoint(p)) end
        local o = toBody(vec3(0, 0, 0))
        local ex, ey, ez = toBody(vec3(1, 0, 0)) - o, toBody(vec3(0, 1, 0)) - o, toBody(vec3(0, 0, 1)) - o
        local function toMesh(v) return invParent:transformVector(bodyWorld:transformVector(v)) end
        local bx, by, bz = toMesh(vec3(1, 0, 0)), toMesh(vec3(0, 1, 0)), toMesh(vec3(0, 0, 1))
        local mesh = {ref = ref, name = name, orig = verts, n = verts:size(),  -- work: a copy made at the first dent
          px = {}, py = {}, pz = {}, nx = {}, ny = {}, nz = {}, moved = {},
          toMesh = {bx.x, bx.y, bx.z, by.x, by.y, by.z, bz.x, bz.y, bz.z}}
        local raw = verts.raw
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
          if x < min[1] then min[1] = x end if x > max[1] then max[1] = x end
          if y < min[2] then min[2] = y end if y > max[2] then max[2] = y end
          if z < min[3] then min[3] = z end if z > max[3] then max[3] = z end
          if v % 2000 == 0 then t0 = budget(t0) end
        end
        body.meshes[#body.meshes + 1] = mesh
        body.vertices = body.vertices + mesh.n
        trace('mesh %d/%d: read', m, body.meshCount)
      end
      end
      t0 = coroutine.yield()  -- one mesh per frame: the trace shows which one, should one crash
    end
    if #body.meshes == 0 then body.state = 'no meshes with vertices under BODYTR' return end
    for a = 1, 3 do min[a], max[a] = min[a] - 0.05, max[a] + 0.05 end
    body.min, body.max = min, max
    body.lattice = lattice.new(min, max, settings.spacing)
    body.noiseOffset = {math.random() * 200, math.random() * 200, math.random() * 200}  -- each car crumples its own way
    -- every vertex in its lattice cell, so a dent only revisits the vertices near the atoms that moved
    local cells = {}
    for mi, mesh in ipairs(body.meshes) do
      for v = 0, mesh.n - 1 do
        local c = lattice.cellOf(body.lattice, mesh.px[v], mesh.py[v], mesh.pz[v])
        local list = cells[c]
        if not list then list = {} cells[c] = list end
        list[#list + 1] = mi
        list[#list + 1] = v
        if v % 4000 == 0 then t0 = budget(t0) end
      end
    end
    body.cells = cells
    -- which ways are forward and left in body space (from the car's heading, and its front-left and
    -- front-right wheels: AC's wheels 0 and 1)
    local car = ac.getCar(i)
    local fwd = invBody:transformVector(car.look)
    body.forward = fwd.z >= 0 and 1 or -1
    local fl, fr = invBody:transformPoint(car.wheels[0].position), invBody:transformPoint(car.wheels[1].position)
    body.left = fl.x >= fr.x and 1 or -1
    body.setupMs = nowMs() - started
    body.state = 'ready'
    log(('car %d: %d meshes with %d vertices, lattice %dx%dx%d, set up in %.0f ms'):format(i, #body.meshes,
      body.vertices, body.lattice.n[1], body.lattice.n[2], body.lattice.n[3], body.setupMs))
  end)
  jobs[#jobs + 1] = {co = co, name = 'setup car ' .. i, body = body}
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

-- Moves the vertices near atoms that moved since last time (the cells next to them) with the lattice, then
-- sends each changed mesh to the GPU.
local function skin(body)
  if body.skinning then body.skinAgain = true return end
  body.skinning = true
  local co = coroutine.create(function(t0)
    repeat
      body.skinAgain = false
      local started, work, count = nowMs(), 0, 0
      local l = body.lattice
      local changed = {}
      -- the crunch's noise, picked once for this pass
      local crunchFn = settings.crunchStyle == 'hammered' and noise.fbm or noise.ridged
      local cf, no = 1 / settings.crunchSize, body.noiseOffset
      local withGrad = noise.withGrad
      for cell in pairs(lattice.takeChanged(l)) do
        local list = body.cells[cell]
        if list then
          for e = 1, #list, 2 do
            local mesh, v = body.meshes[list[e]], list[e + 1]
            if not mesh.work and not mesh.failed then
              mesh.work = freshVertices(mesh, 'to dent')
              mesh.failed = mesh.work == nil  -- left as it is
            end
            local raw, orig = mesh.work and mesh.work.raw, mesh.orig.raw
            local T = mesh.toMesh
            local ox, oy, oz, ax, ay, az, bx, by, bz, cx, cy, cz, crunch
            if raw then ox, oy, oz, ax, ay, az, bx, by, bz, cx, cy, cz, crunch = lattice.sample(l, mesh.px[v], mesh.py[v], mesh.pz[v]) end
            if ox then
              local nx0, ny0, nz0 = mesh.nx[v], mesh.ny[v], mesh.nz[v]
              local qx, qy, qz = lattice.bendNormal(nx0, ny0, nz0, ax, ay, az, bx, by, bz, cx, cy, cz)
              -- crunch: the metal pushed in and out along its surface's normal by noise (creases ~crunchSize and
              -- finer), as much as the crunch there; the normal tilts with the noise's slope
              if crunch > 1e-4 then
                local f = cf
                local nn, gx, gy, gz = withGrad(crunchFn, mesh.px[v] * f + no[1], mesh.py[v] * f + no[2], mesh.pz[v] * f + no[3], 3, 0.5, 0.05)
                local d = crunch * nn
                ox, oy, oz = ox + nx0 * d, oy + ny0 * d, oz + nz0 * d
                gx, gy, gz = gx * f * crunch, gy * f * crunch, gz * f * crunch  -- slope of the surface, per metre
                local gn = gx * nx0 + gy * ny0 + gz * nz0
                qx, qy, qz = qx - (gx - gn * nx0), qy - (gy - gn * ny0), qz - (gz - gn * nz0)
                local ql = math.sqrt(qx * qx + qy * qy + qz * qz)
                if ql > 1e-6 then qx, qy, qz = qx / ql, qy / ql, qz / ql end
              end
              -- the offset into the mesh's own space
              raw[v].pos.x = orig[v].pos.x + T[1] * ox + T[4] * oy + T[7] * oz
              raw[v].pos.y = orig[v].pos.y + T[2] * ox + T[5] * oy + T[8] * oz
              raw[v].pos.z = orig[v].pos.z + T[3] * ox + T[6] * oy + T[9] * oz
              local mx, my, mz = T[1] * qx + T[4] * qy + T[7] * qz, T[2] * qx + T[5] * qy + T[8] * qz, T[3] * qx + T[6] * qy + T[9] * qz
              local len = math.sqrt(mx * mx + my * my + mz * mz)
              if len > 0 then raw[v].normal.x, raw[v].normal.y, raw[v].normal.z = mx / len, my / len, mz / len end
              mesh.moved[v] = true
              changed[mesh] = true
            elseif raw and mesh.moved[v] then
              raw[v].pos.x, raw[v].pos.y, raw[v].pos.z = orig[v].pos.x, orig[v].pos.y, orig[v].pos.z
              raw[v].normal.x, raw[v].normal.y, raw[v].normal.z = orig[v].normal.x, orig[v].normal.y, orig[v].normal.z
              mesh.moved[v] = nil
              changed[mesh] = true
            end
            count = count + 1
            if count % 1000 == 0 then
              local t = nowMs()
              if t - t0 > settings.budgetMs then work = work + (t - t0) t0 = coroutine.yield() end
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
    mesh.sent, mesh.work, mesh.moved, mesh.failed = nil, nil, {}, nil
  end
end
-- unloading (AC closing, the app reloaded): the originals back
ac.onRelease(function() for _, body in pairs(cars) do restoreNow(body) end end)

local function repair(body)
  if not body or not body.lattice then return end
  lattice.reset(body.lattice)
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
  lattice.dent(body.lattice, p.x, p.y, p.z, d.x, d.y, d.z, depth, radius, settings.maxOffset, settings.springs, 0.35,
    crunchFor(depth, severity or depth / 0.1), settings.maxCrunch)
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
-- Crashes. An impact shows as a jump in the car's velocity: over 30 m/s2 (3 g; braking and cornering stay under
-- about 2 g) in a frame, or AC reporting a contact (collisionDepth; AC's physics runs faster than the app's
-- frames, so a contact can come and go between two of them: the velocity catches it either way). From there,
-- the biggest change from the velocity just before it over 150 ms (an AC crash takes a few frames) is the hit:
-- over 2.5 m/s it dents, where the car was hit (a ray from that side towards its middle), pushed the way the car
-- was pushed, deeper and crunchier the harder. A teleport (over 5 m in a frame) isn't a crash.
local IMPACT_ACCEL, IMPACT_WINDOW, MIN_HIT, COOLDOWN = 30, 0.15, 2.5, 0.3
local crash = {}
local function updateCrash(i, dt)
  local car = ac.getCar(i)
  local body = cars[i]
  if not car or not body or body.state ~= 'ready' or dt <= 0 then return end
  local c = crash[i]
  if not c then c = {prevVel = vec3():set(car.velocity), prevPos = vec3():set(car.position), cool = 0} crash[i] = c return end
  c.cool = math.max(0, c.cool - dt)
  local teleported = car.position:distanceSquared(c.prevPos) > 25
  if teleported then c.at = nil end
  local jump = (car.velocity - c.prevVel):length() / dt
  if not c.at and not teleported and c.cool == 0 and (jump > IMPACT_ACCEL or car.collisionDepth > 0) then
    c.at, c.before, c.maxDv = 0, c.prevVel:clone(), vec3()
  end
  if c.at then
    c.at = c.at + dt
    local dv = car.velocity - c.before
    if dv:lengthSquared() > c.maxDv:lengthSquared() then c.maxDv:set(dv) end
    if c.at >= IMPACT_WINDOW then
      local speed = c.maxDv:length()
      c.at = nil
      if speed > MIN_HIT then
        c.cool = COOLDOWN
        local dir = c.maxDv:clone():normalize()
        -- aimed at the middle of the body's box (in the body's own frame, so it's where the meshes are)
        local mn, mx = body.min, body.max
        local mid = body.node:getWorldTransformationRaw():transformPoint(vec3((mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2))
        local hit = hitCar(body, mid - dir * 6, dir) or (mid - dir * 1.5)
        local depth = math.min(settings.maxOffset, (speed - MIN_HIT) * 0.025 * settings.crashScale + 0.01)
        trace('crash: car %d, %.1f m/s: dent %.3f m', i, speed, depth)
        dentWorld(body, hit, dir, depth, 0.35 + 0.025 * speed, speed / 12)
        body.lastCrash = speed
        body.crashes = (body.crashes or 0) + 1
      end
    end
  end
  c.prevVel:set(car.velocity)
  c.prevPos:set(car.position)
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
local function sendQueued()
  local q = sendQueue
  sendQueue = {}
  local seen = {}
  for _, mesh in ipairs(q) do if not seen[mesh] then seen[mesh] = true send(mesh) end end
end

function script.update(dt)
  local i = sim.focusedCar
  if settings.readWatched and i >= 0 and not cars[i] then setupCar(i) hookJumps(i) end
  -- Ctrl + left click on the car: a dent there, along the view
  local click = ac.isKeyDown(ac.KeyIndex.Control) and ac.isKeyDown(ac.KeyIndex.LeftButton)
  if click and not wasClick and cars[i] and cars[i].state == 'ready' then
    local ray = render.createMouseRay()
    local body = cars[i]
    local dist = body.node:findMeshes('?'):raycast(ray, false)
    if dist and dist >= 0 then dentWorld(body, ray.pos + ray.dir * dist, ray.dir, settings.depth, settings.radius) end
  end
  wasClick = click
  -- every car that's been read
  if settings.crashDents and not sim.isPaused and not sim.isReplayActive then
    for ci in pairs(cars) do updateCrash(ci, dt) end
  end
  runJobs()
  sendQueued()
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

function script.windowMain(dt)
  local body = cars[sim.focusedCar]
  if not body then
    ui.textWrapped('Reads the body of the car you are watching (a trace of each step goes to softdamage_trace.txt in '
      .. 'this app\'s folder).')
    if ui.button('Read this car') and sim.focusedCar >= 0 then setupCar(sim.focusedCar) hookJumps(sim.focusedCar) end
    return
  end
  ui.text(('Car %d: %s%s'):format(body.index, body.state, body.state == 'reading meshes' and body.reading and (' ' .. body.reading) or ''))
  if body.error then ui.textColored('Error: ' .. body.error, rgbm(1, 0.4, 0.3, 1)) end
  if body.lattice then
    local l = body.lattice
    ui.text(('%d meshes (of %d; %d not bodywork), %d vertices; lattice %d x %d x %d'):format(#body.meshes,
      body.meshCount or 0, body.skipped or 0, body.vertices, l.n[1], l.n[2], l.n[3]))
    ui.text(('Setup %.0f ms. Last re-skin: %d vertices, %.0f ms of work over %.0f ms.'):format(body.setupMs,
      body.lastSkinCount or 0, body.lastSkinMs or 0, body.lastSkinSpan or 0))
    ui.text(('Dents: %d (%d from crashes%s)'):format(body.dents, body.crashes or 0,
      body.lastCrash and ('; last %.1f m/s'):format(body.lastCrash) or ''))
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
  slider('springs', 'Spring passes: %.0f', 0, 6, 1, true)
  slider('maxOffset', 'Most an atom moves: %.2f m', 0.1, 1)
  slider('spacing', 'Atom spacing: %.2f m (rebuild)', 0.15, 0.8)
  slider('budgetMs', 'Work per frame: %.1f ms', 1, 16)
  if ui.checkbox('Read the car I\'m watching without the button', settings.readWatched) then settings.readWatched = not settings.readWatched end
  if ui.checkbox('Dent copies of the meshes (createMesh crashed AC in test C)', settings.method == 'copy') then
    settings.method = settings.method == 'copy' and 'direct' or 'copy'
  end
  if ui.checkbox('Dents from crashes', settings.crashDents) then settings.crashDents = not settings.crashDents end
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

if __softdamageTest then __softdamageTest.cars = cars __softdamageTest.jobs = jobs end
