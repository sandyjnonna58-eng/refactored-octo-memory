-- Client: drawing a skeleton inside a body. Called by the inspection view only (cl_view.lua):
-- nothing here runs in ordinary play.
--
-- Every unit of the geometry is one mesh in the rest pose's space, drawn with the unit's matrix of
-- this frame (sh_pose.lua): the body's own animation bones, read after the body has been drawn, so
-- what the engine and every other addon did to them this frame is in them (Z-City's breathing, a
-- limb it has scaled away, the free-hand module's arms). No bone is skinned and no mesh is ever
-- rebuilt.
--
--   SK.Draw.Body(body, opts)   opts.xray: over the body (its own parts still hide each other);
--                              else as part of the world (what shows has come through the surface);
--                              opts.tint(unit) -> r, g, b (0..1) or nil; opts.tier: the highest tier shown

local SK = HemoSkeleton
SK.NoJIT()
SK.Draw = SK.Draw or {}
local D = SK.Draw
local G, M, ST, C = SK.Geo, SK.M, SK.Stock, SK.Config

D.stats = { bodies = 0, units = 0, ms = 0, frame = -1, last = { bodies = 0, units = 0, ms = 0 } }

local mat
local function Material()
	if mat then return mat end
	-- the game's own texture for the model, by its name
	mat = CreateMaterial("skel_bone_" .. math.floor(SysTime() * 1000) % 100000, "VertexLitGeneric", {
		["$basetexture"] = ST.texture, ["$halflambert"] = 1,
	})
	return mat
end

local lights = {
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
}
-- Light fixed to the eye: a key from the upper left, a fill from the right, the place's own light
-- as the ground of it. (A mesh drawn with a lit material and no lights set is black.)
local function LightsOn(at)
	local ang = EyeAngles()
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local V = C.View
	local amb = render.GetLightColor(at)
	local a = V.ambient
	lights[1].color = Vector(V.key, V.key, V.key * 0.96)
	lights[2].color = Vector(V.fill * 0.9, V.fill * 0.95, V.fill)
	lights[1].dir = (f * 0.6 + r * 0.45 - u * 0.65):GetNormalized()
	lights[2].dir = (f * 0.5 - r * 0.8 - u * 0.1):GetNormalized()
	render.SuppressEngineLighting(true)
	render.SetLightingOrigin(at)
	render.ResetModelLighting(a + amb.x * 0.25, a + amb.y * 0.25, a + amb.z * 0.25)
	render.SetLocalModelLights(lights)
end
local function LightsOff()
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
end

local vm = Matrix()
local WHITE = Vector(1, 1, 1)
local col = Vector(1, 1, 1)

-- The lowest tier among a unit's bones (what a level of detail goes by); units that are no bone: 2.
local tierOf = {}
local function Tier(u)
	local t = tierOf[u.id]
	if t then return t end
	t = 3
	for _, id in ipairs(u.bones) do local b = SK.Bones[id] if b and b.tier < t then t = b.tier end end
	if #u.bones == 0 then t = 2 end
	tierOf[u.id] = t
	return t
end

function D.Body(body, opts)
	if G.state ~= "ready" then return 0 end
	local pose = SK.PoseOf(body)
	if not pose then return 0 end
	local t0 = SysTime()
	-- (the body's bones as they are now, after it was drawn)
	pose:Fresh()
	local m = Material()
	local at = body:WorldSpaceCenter()
	LightsOn(at)
	if opts.xray then render.DepthRange(0, 0.02) end
	local tint, maxTier, only = opts.tint, opts.tier or 3, opts.only
	local n = 0
	local last
	-- (opts.alpha: as glass, for what lies inside to be seen; opts.only(unit): these units alone)
	if opts.alpha then m:SetFloat("$alpha", opts.alpha) end
	render.SetMaterial(m)
	for _, uid in ipairs(G.order) do
		local u = G.units[uid]
		if u.mesh and Tier(u) <= maxTier and (not only or only(u)) then
			local rows
			if u.key then
				-- (the model is not the stock one: this unit is everything on one animation bone, in that bone's space)
				rows = pose:Carrier(u.key) or (pose.prof.via[u.key] and pose:Carrier(pose.prof.via[u.key]))
			else
				rows = pose:Carry(u.carry, u.c[1], u.c[2], u.c[3])
			end
			if rows then
				local r, g, b = 1, 1, 1
				if tint then
					local tr, tg, tb = tint(u)
					if tr then r, g, b = tr, tg, tb end
				end
				local key = r * 65536 + g * 256 + b
				if key ~= last then
					col.x, col.y, col.z = r, g, b
					m:SetVector("$color2", col)
					last = key
					-- (the material is bound again so that the colour is taken)
					render.SetMaterial(m)
				end
				M.ToMatrix(rows, vm)
				cam.PushModelMatrix(vm)
				u.mesh:Draw()
				cam.PopModelMatrix()
				n = n + 1
			end
		end
	end
	if opts.xray then render.DepthRange(0, 1) end
	m:SetVector("$color2", WHITE)
	if opts.alpha then m:SetFloat("$alpha", 1) end
	LightsOff()
	local s = D.stats
	local fr = FrameNumber()
	if s.frame ~= fr then
		s.last.bodies, s.last.units, s.last.ms = s.bodies, s.units, s.ms
		s.frame, s.bodies, s.units, s.ms = fr, 0, 0, 0
	end
	s.bodies, s.units, s.ms = s.bodies + 1, s.units + n, s.ms + (SysTime() - t0) * 1000
	return n
end

-- A proxy solid as lines, in the rest pose: put(x0, y0, z0, x1, y1, z1) is handed each of them.
local function Ring(put, cx, cy, cz, ux, uy, uz, vx, vy, vz)
	local px, py, pz
	for i = 0, 12 do
		local a = i / 12 * math.pi * 2
		local c, s = math.cos(a), math.sin(a)
		local x, y, z = cx + ux * c + vx * s, cy + uy * c + vy * s, cz + uz * c + vz * s
		if px then put(px, py, pz, x, y, z) end
		px, py, pz = x, y, z
	end
end
local function ShapeLines(s, put)
	if s[1] == "c" then
		local ax, ay, az, bx, by, bz, r = s[2], s[3], s[4], s[5], s[6], s[7], s[8]
		local dx, dy, dz = bx - ax, by - ay, bz - az
		local l = math.sqrt(dx * dx + dy * dy + dz * dz)
		local ux, uy, uz, vx, vy, vz
		if l < 1e-6 then dx, dy, dz, l = 0, 0, 1, 1 end
		dx, dy, dz = dx / l, dy / l, dz / l
		-- two directions across the axis
		if math.abs(dz) < 0.9 then ux, uy, uz = -dy, dx, 0 else ux, uy, uz = 0, -dz, dy end
		local n = math.sqrt(ux * ux + uy * uy + uz * uz)
		ux, uy, uz = ux / n * r, uy / n * r, uz / n * r
		vx, vy, vz = (dy * uz - dz * uy), (dz * ux - dx * uz), (dx * uy - dy * ux)
		Ring(put, ax, ay, az, ux, uy, uz, vx, vy, vz)
		Ring(put, bx, by, bz, ux, uy, uz, vx, vy, vz)
		for _, k in ipairs({ 1, -1 }) do
			put(ax + ux * k, ay + uy * k, az + uz * k, bx + ux * k, by + uy * k, bz + uz * k)
			put(ax + vx * k, ay + vy * k, az + vz * k, bx + vx * k, by + vy * k, bz + vz * k)
		end
		return
	end
	local cx, cy, cz = s[2], s[3], s[4]
	local h1, h2, h3 = s[14], s[15], s[16]
	local a = { s[5] * h1, s[6] * h1, s[7] * h1 }
	local b = { s[8] * h2, s[9] * h2, s[10] * h2 }
	local c = { s[11] * h3, s[12] * h3, s[13] * h3 }
	if s[1] == "e" then
		Ring(put, cx, cy, cz, a[1], a[2], a[3], b[1], b[2], b[3])
		Ring(put, cx, cy, cz, a[1], a[2], a[3], c[1], c[2], c[3])
		Ring(put, cx, cy, cz, b[1], b[2], b[3], c[1], c[2], c[3])
		return
	end
	local function P(i, j, k) return cx + a[1] * i + b[1] * j + c[1] * k, cy + a[2] * i + b[2] * j + c[2] * k, cz + a[3] * i + b[3] * j + c[3] * k end
	for _, i in ipairs({ -1, 1 }) do
		for _, j in ipairs({ -1, 1 }) do
			local x0, y0, z0 = P(i, j, -1) local x1, y1, z1 = P(i, j, 1) put(x0, y0, z0, x1, y1, z1)
			x0, y0, z0 = P(i, -1, j) x1, y1, z1 = P(i, 1, j) put(x0, y0, z0, x1, y1, z1)
			x0, y0, z0 = P(-1, i, j) x1, y1, z1 = P(1, i, j) put(x0, y0, z0, x1, y1, z1)
		end
	end
end

-- One solid drawn at once, in the world (rows: rest pose -> world).
function D.Shape(rows, s, colr)
	ShapeLines(s, function(x0, y0, z0, x1, y1, z1)
		local ax, ay, az = M.Xf(rows, x0, y0, z0)
		local bx, by, bz = M.Xf(rows, x1, y1, z1)
		render.DrawLine(Vector(ax, ay, az), Vector(bx, by, bz), colr, false)
	end)
end

-- The proxies of one bone, or of every bone (only nil), as lines. They are drawn line by line, as
-- the engine draws a line: every solid of a body is some twelve thousand of them and costs about
-- seventeen milliseconds each time the scene is drawn (measured), so the view shows them for one
-- body. (Keeping each bone's lines as a mesh of lines made once drew nothing in the game: tried
-- and taken out again, docs/SKELETON_PHASE2.md.)
function D.Proxies(body, only, colr)
	local pose = SK.PoseOf(body)
	if not pose then return end
	render.SetColorMaterialIgnoreZ()
	for _, id in ipairs(only and { only } or SK.Proxy.list) do
		local st = ST.bones[id]
		local rows = st and type(st.proxy) == "table" and pose:Bone(id)
		if rows then for _, s in ipairs(st.proxy) do D.Shape(rows, s, colr) end end
	end
end
