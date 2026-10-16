-- Soft Body Damage (prototype): visual dents on any car, no per-car setup. The car's body meshes (under its
-- BODYTR node) follow a lattice of "atoms" over the body; dents push atoms in, springs between them spread it,
-- and every vertex moves with the lattice where it sits (src/lattice.lua). Visual only: AC's physics and
-- collisions don't change.
-- This first version is for finding out what works in game: dents from buttons, Ctrl+click on the car, and
-- (experimental) crashes; timings are shown in the window.
local lattice = require('src/lattice')

local settings = ac.storage{
  depth = 0.12,        -- test dent: metres
  radius = 0.45,       -- test dent: metres
  spacing = 0.35,      -- lattice: metres between atoms (applies on rebuild)
  springs = 2,         -- spring passes after each dent (0 = a dent stays exactly where it's pushed)
  maxOffset = 0.5,     -- how far an atom can be pushed in total
  autoRead = false,    -- read the car being watched without pressing the button
  method = 'copy',     -- how dents are shown: 'copy' (our own copies of the meshes, the originals hidden) or
                       -- 'direct' (the car's own meshes changed: crashed AC in the first test)
  crashes = false,     -- dents from crashes (experimental)
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
      trace('mesh %d/%d "%s": getVertices', m, body.meshCount, name)
      local verts = ref:getVertices()
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
      t0 = coroutine.yield()  -- one mesh per frame: the trace shows which one, should one crash
    end
    if #body.meshes == 0 then body.state = 'no meshes with vertices under BODYTR' return end
    for a = 1, 3 do min[a], max[a] = min[a] - 0.05, max[a] + 0.05 end
    body.min, body.max = min, max
    body.lattice = lattice.new(min, max, settings.spacing)
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

-- Shows a mesh's new vertices. 'direct': the car's own mesh takes them. 'copy': at its first dent, a copy of the
-- mesh is made under the same node with the same material and the original hidden; the copy takes them.
local function send(mesh)
  if settings.method == 'direct' and not mesh.copy then
    if not mesh.sent then trace('alterVertices "%s" (%d vertices), first time', mesh.name, mesh.n) end
    mesh.ref:alterVertices(mesh.work)
    if not mesh.sent then trace('alterVertices "%s": done', mesh.name) mesh.sent = true end
    return
  end
  if not mesh.copy then
    trace('copy of "%s": getIndices', mesh.name)
    local indices = mesh.ref:getIndices()
    trace('copy of "%s": %s indices; createMesh', mesh.name, indices and indices:size() or 'no')
    if not indices then return end
    local copy = mesh.ref:getParent():createMesh('softdamage_' .. mesh.name, nil, mesh.work:clone(), indices, false, false)
    trace('copy of "%s": %s; assignMaterialFrom', mesh.name, copy and 'made' or 'failed')
    if not copy then return end
    copy:assignMaterialFrom(mesh.ref)
    trace('copy of "%s": material set; hiding the original', mesh.name)
    mesh.ref:setVisible(false)
    mesh.copy = copy
    trace('copy of "%s": done', mesh.name)
    return
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
      for cell in pairs(lattice.takeChanged(l)) do
        local list = body.cells[cell]
        if list then
          for e = 1, #list, 2 do
            local mesh, v = body.meshes[list[e]], list[e + 1]
            if not mesh.work then mesh.work = mesh.orig:clone() end
            local raw, orig = mesh.work.raw, mesh.orig.raw
            local T = mesh.toMesh
            local ox, oy, oz, ax, ay, az, bx, by, bz, cx, cy, cz = lattice.sample(l, mesh.px[v], mesh.py[v], mesh.pz[v])
            if ox then
              -- the offset into the mesh's own space
              raw[v].pos.x = orig[v].pos.x + T[1] * ox + T[4] * oy + T[7] * oz
              raw[v].pos.y = orig[v].pos.y + T[2] * ox + T[5] * oy + T[8] * oz
              raw[v].pos.z = orig[v].pos.z + T[3] * ox + T[6] * oy + T[9] * oz
              local qx, qy, qz = lattice.bendNormal(mesh.nx[v], mesh.ny[v], mesh.nz[v], ax, ay, az, bx, by, bz, cx, cy, cz)
              local mx, my, mz = T[1] * qx + T[4] * qy + T[7] * qz, T[2] * qx + T[5] * qy + T[8] * qz, T[3] * qx + T[6] * qy + T[9] * qz
              local len = math.sqrt(mx * mx + my * my + mz * mz)
              if len > 0 then raw[v].normal.x, raw[v].normal.y, raw[v].normal.z = mx / len, my / len, mz / len end
              mesh.moved[v] = true
              changed[mesh] = true
            elseif mesh.moved[v] then
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
      for mesh in pairs(changed) do send(mesh) end
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
    mesh.sent, mesh.work, mesh.moved = nil, nil, {}
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
local function dentWorld(body, worldPos, worldDir, depth, radius)
  if not body or body.state ~= 'ready' then return false end
  local w = body.node:getWorldTransformationRaw()
  local inv = w:inverse()
  local p = inv:transformPoint(worldPos)
  local d = inv:transformVector(worldDir):normalize()
  lattice.dent(body.lattice, p.x, p.y, p.z, d.x, d.y, d.z, depth, radius, settings.maxOffset, settings.springs, 0.35)
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
-- Crashes (experimental): the velocity change from just before a contact, over 150 ms (an AC crash takes a
-- few frames); the dent goes where the car was hit, pushed the way the car was pushed.
local crash = {}
local function updateCrash(i, dt)
  local car = ac.getCar(i)
  local body = cars[i]
  if not car or not body or body.state ~= 'ready' then return end
  local c = crash[i] or {}
  crash[i] = c
  if car.collisionDepth > 0 and not c.at and c.prevVel then c.at, c.before, c.maxDv = 0, c.prevVel:clone(), vec3() end
  if c.at then
    c.at = c.at + dt
    local dv = car.velocity - c.before
    if dv:lengthSquared() > c.maxDv:lengthSquared() then c.maxDv:set(dv) end
    if c.at > 0.15 then
      local speed = c.maxDv:length()
      c.at = nil
      if speed > 1.5 then
        local dir = c.maxDv:clone():normalize()
        -- where it was hit: a ray from the obstacle's side, towards the middle of the car
        local mid = car.position + car.up * 0.3
        local hit = hitCar(body, mid - dir * 6, dir) or (mid - dir * 1.5)
        local depth = math.min(settings.maxOffset, (speed - 1.5) * 0.025 * settings.crashScale)
        dentWorld(body, hit, dir, depth, 0.35 + 0.025 * speed)
        body.lastCrash = speed
      end
    end
  end
  c.prevVel = c.prevVel or vec3()
  c.prevVel:set(car.velocity)
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
function script.update(dt)
  local i = sim.focusedCar
  if settings.autoRead and i >= 0 and not cars[i] then setupCar(i) hookJumps(i) end
  -- Ctrl + left click on the car: a dent there, along the view
  local click = ac.isKeyDown(ac.KeyIndex.Control) and ac.isKeyDown(ac.KeyIndex.LeftButton)
  if click and not wasClick and cars[i] and cars[i].state == 'ready' then
    local ray = render.createMouseRay()
    local body = cars[i]
    local dist = body.node:findMeshes('?'):raycast(ray, false)
    if dist and dist >= 0 then dentWorld(body, ray.pos + ray.dir * dist, ray.dir, settings.depth, settings.radius) end
  end
  wasClick = click
  if settings.crashes and not sim.isPaused then updateCrash(i, dt) end
  runJobs()
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
  local v = mesh.orig:clone()
  local copy = mesh.ref:getParent():createMesh('softdamage_test', nil, v:clone(), indices, false, false)
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
    ui.text(('%d meshes (of %d), %d vertices; lattice %d x %d x %d'):format(#body.meshes, body.meshCount or 0,
      body.vertices, l.n[1], l.n[2], l.n[3]))
    ui.text(('Setup %.0f ms. Last re-skin: %d vertices, %.0f ms of work over %.0f ms.'):format(body.setupMs,
      body.lastSkinCount or 0, body.lastSkinMs or 0, body.lastSkinSpan or 0))
    ui.text(('Dents: %d%s'):format(body.dents, body.lastCrash and ('; last crash %.1f m/s'):format(body.lastCrash) or ''))
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
  end
  for _, k in ipairs({'A', 'B', 'C'}) do if testResult[k] then ui.textWrapped(k .. ': ' .. testResult[k]) end end
  slider('depth', 'Dent depth: %.2f m', 0.01, 0.5)
  slider('radius', 'Dent radius: %.2f m', 0.1, 1.5)
end

function script.windowSettings(dt)
  slider('springs', 'Spring passes: %.0f', 0, 6, 1, true)
  slider('maxOffset', 'Most an atom moves: %.2f m', 0.1, 1)
  slider('spacing', 'Atom spacing: %.2f m (rebuild)', 0.15, 0.8)
  slider('budgetMs', 'Work per frame: %.1f ms', 1, 16)
  if ui.checkbox('Read the car I\'m watching without the button', settings.autoRead) then settings.autoRead = not settings.autoRead end
  if ui.checkbox('Dent the car\'s own meshes (not copies; crashed AC in the first test)', settings.method == 'direct') then
    settings.method = settings.method == 'direct' and 'copy' or 'direct'
  end
  if ui.checkbox('Dents from crashes (experimental)', settings.crashes) then settings.crashes = not settings.crashes end
  slider('crashScale', 'Crash dent scale: %.2f', 0.1, 3)
  if ui.button('Rebuild (re-read the car)') then
    local i = sim.focusedCar
    if cars[i] then cars[i].state = 'replaced' restoreNow(cars[i]) end
    for n = #jobs, 1, -1 do if jobs[n].body == cars[i] then table.remove(jobs, n) end end
    cars[i] = nil
    if i >= 0 then setupCar(i) end
  end
end

if __softdamageTest then __softdamageTest.cars = cars __softdamageTest.jobs = jobs end
