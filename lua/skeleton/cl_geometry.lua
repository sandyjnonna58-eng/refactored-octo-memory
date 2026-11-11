-- Client: what is drawn. The game's own skeleton model (models/player/skeleton.mdl, in every
-- installation of the game) is read from the game at run time and taken apart into the bones of the
-- registry. Nothing of that model is in this addon: sh_stock.lua only says how to find its pieces
-- again (by their triangle count and place) and where the fused ones are cut.
--
--   the model's triangles, weights and rest pose      util.GetModelMeshes (the model need not be in the world)
--   its separate pieces                               triangles joined by shared corners
--   which piece is what                               sh_stock.lua, pieces
--   a fused piece cut into bones                      each triangle to the unit of the nearest seed
--   the jaw closed                                    the jaw's pieces turned about the line through its joints
--   one mesh a unit                                   in the rest pose's own space: it is drawn with the unit's
--                                                     matrix of the moment (sh_pose.lua), rigidly
-- The meshes are made once, a little each frame, when a view first asks for them, and are shared by
-- every body shown. Without the view nothing is read and nothing is built.
--
-- If the model on this machine is not the stock one (another addon has replaced it) its pieces are
-- not found. Then it is drawn by animation bone instead, whole and rigid on each: a skeleton still,
-- but one whose bones cannot be told apart, and the view says so.

local SK = HemoSkeleton
SK.NoJIT()
SK.Geo = SK.Geo or {}
local G = SK.Geo
local ST, M, C = SK.Stock, SK.M, SK.Config
local floor, sqrt, cos, sin = math.floor, math.sqrt, math.cos, math.sin

G.state = G.state or "none"       -- none, building, ready, failed
G.units = G.units or {}           -- [unit id] = { mesh, n, bones, carry, c, pts }
G.order = G.order or {}
G.note = G.note or ""
G.stats = G.stats or { ms = 0, steps = 0, engineMs = 0 }

local cvCoarse = CreateClientConVar("skel_geo_coarse", "0", false, false, "Skeleton: take the model apart by animation bone only, as if it were not the stock one (for trying that out; build again with skel_geo_reload)", 0, 1)

function G.Free()
	for _, u in pairs(G.units) do
		if u.mesh then u.mesh:Destroy() end
	end
	G.units, G.order = {}, {}
	G.state, G.co, G.coarse, G.note = "none", nil, nil, ""
end

-- a point turned about a line (through o, along the unit vector k) by an angle
local function Turn(x, y, z, o, k, ang)
	local vx, vy, vz = x - o[1], y - o[2], z - o[3]
	local c, s = cos(ang), sin(ang)
	local cx, cy, cz = k[2] * vz - k[3] * vy, k[3] * vx - k[1] * vz, k[1] * vy - k[2] * vx
	local d = (k[1] * vx + k[2] * vy + k[3] * vz) * (1 - c)
	return o[1] + vx * c + cx * s + k[1] * d, o[2] + vy * c + cy * s + k[2] * d, o[3] + vz * c + cz * s + k[3] * d
end

local function Build()
	local yield = coroutine.yield
	local t0 = SysTime()
	util.PrecacheModel(ST.model)
	local meshes, binds = util.GetModelMeshes(ST.model, 0, 0)
	G.stats.engineMs = (SysTime() - t0) * 1000
	if not meshes or #meshes == 0 then
		G.state, G.note = "failed", "the game's skeleton model (" .. ST.model .. ") could not be read"
		return
	end
	yield()
	-- corners: place, normal, texture coordinates, the bone they hang on most; three a triangle
	local px, py, pz, nx, ny, nz, tu, tv, dom = {}, {}, {}, {}, {}, {}, {}, {}, {}
	local n = 0
	for _, sub in ipairs(meshes) do
		local tri = sub.triangles
		if istable(tri) then
			for i = 1, #tri do
				local v = tri[i]
				n = n + 1
				local p, nm = v.pos, v.normal or vector_up
				px[n], py[n], pz[n] = p.x, p.y, p.z
				nx[n], ny[n], nz[n] = nm.x, nm.y, nm.z
				tu[n], tv[n] = v.u or 0, v.v or 0
				local best, bw = 0, -1
				if istable(v.weights) then
					for _, w in ipairs(v.weights) do if (w.weight or 0) > bw then best, bw = w.bone or 0, w.weight or 0 end end
				end
				dom[n] = best
				if n % 3000 == 0 then yield() end
			end
		end
	end
	local nt = floor(n / 3)
	-- pieces: triangles joined by shared corners (corners at one place are one corner)
	local weld, wid, par, nw = {}, {}, {}, 0
	for i = 1, nt * 3 do
		local key = floor(px[i] * 64 + 0.5) .. "," .. floor(py[i] * 64 + 0.5) .. "," .. floor(pz[i] * 64 + 0.5)
		local w = weld[key]
		if not w then nw = nw + 1 w = nw weld[key] = w par[w] = w end
		wid[i] = w
		if i % 4000 == 0 then yield() end
	end
	weld = nil
	local function Find(i)
		while par[i] ~= i do par[i] = par[par[i]] i = par[i] end
		return i
	end
	for t = 0, nt - 1 do
		local a, b, c = Find(wid[t * 3 + 1]), Find(wid[t * 3 + 2]), Find(wid[t * 3 + 3])
		par[b] = a
		par[Find(c)] = a
	end
	yield()
	local comp, comps = {}, {}
	local tcx, tcy, tcz = {}, {}, {}
	for t = 0, nt - 1 do
		local i = t * 3
		local r = Find(wid[i + 1])
		local c = comp[r]
		if not c then c = { n = 0, x = 0, y = 0, z = 0, tris = {} } comp[r] = c comps[#comps + 1] = c end
		local cx, cy, cz = (px[i + 1] + px[i + 2] + px[i + 3]) / 3, (py[i + 1] + py[i + 2] + py[i + 3]) / 3, (pz[i + 1] + pz[i + 2] + pz[i + 3]) / 3
		tcx[t], tcy[t], tcz[t] = cx, cy, cz
		c.n = c.n + 1
		c.x, c.y, c.z = c.x + cx, c.y + cy, c.z + cz
		c.tris[c.n] = t
		if t % 3000 == 0 then yield() end
	end
	for _, c in ipairs(comps) do c.x, c.y, c.z = c.x / c.n, c.y / c.n, c.z / c.n end
	-- which piece is what: by its triangle count and place
	local unitOfTri, turned = {}, {}
	local found, lost = 0, 0
	if not cvCoarse:GetBool() then
		for _, pc in ipairs(ST.pieces) do
			local best, bd
			for _, c in ipairs(comps) do
				if c.n == pc[1] and not c.taken then
					local d = (c.x - pc[2]) ^ 2 + (c.y - pc[3]) ^ 2 + (c.z - pc[4]) ^ 2
					if d < 0.01 and (not bd or d < bd) then best, bd = c, d end
				end
			end
			if best then
				best.taken = true
				found = found + 1
				local seeds = pc.seeds
				for _, t in ipairs(best.tris) do
					if seeds then
						local x, y, z = tcx[t], tcy[t], tcz[t]
						local unit, ud
						for _, s in ipairs(seeds) do
							local d = (x - s[2]) ^ 2 + (y - s[3]) ^ 2 + (z - s[4]) ^ 2
							if not ud or d < ud then unit, ud = s[1], d end
						end
						unitOfTri[t] = unit
					else
						unitOfTri[t] = pc[5]
					end
					if pc.turn then turned[t] = true end
				end
			else
				lost = lost + 1
			end
		end
		yield()
	end
	local stock = found == #ST.pieces and nt == ST.tris and #comps == ST.npieces
	G.coarse = not stock
	local units = {}
	if stock then
		-- the jaw closed
		local J = ST.jaw
		for t in pairs(turned) do
			for k = 1, 3 do
				local i = t * 3 + k
				px[i], py[i], pz[i] = Turn(px[i], py[i], pz[i], J.p, J.axis, J.closed)
				nx[i], ny[i], nz[i] = Turn(nx[i], ny[i], nz[i], { 0, 0, 0 }, J.axis, J.closed)
			end
		end
		for t = 0, nt - 1 do
			local uid = unitOfTri[t]
			local u = units[uid]
			if not u then
				local def = ST.units[uid]
				u = { id = uid, verts = {}, pts = {}, n = 0, bones = def and def.bones or {}, carry = def and def.carry or { { "pelvis", 1 } }, c = def and def.c or { 0, 0, 0 }, how = def and def.how or "extra", want = def and def.n or 0 }
				units[uid] = u
			end
			for k = 1, 3 do
				local i = t * 3 + k
				u.verts[#u.verts + 1] = { pos = Vector(px[i], py[i], pz[i]), normal = Vector(nx[i], ny[i], nz[i]), u = tu[i], v = tv[i] }
				u.pts[#u.pts + 1] = { px[i], py[i], pz[i] }
			end
			u.n = u.n + 1
			if t % 800 == 0 then yield() end
		end
		G.note = string.format("the stock model: %d pieces found, %d triangles", found, nt)
	else
		-- not the stock model: by animation bone, each in that bone's own space (the model's own rest pose)
		local cs = ClientsideModel(ST.model)
		local keyOf = {}
		if IsValid(cs) then
			cs:SetNoDraw(true)
			cs:SetupBones()
			local prof = SK.Rig.ResolveWith("geometry", function(name) return cs:LookupBone(name) end)
			if prof.ok then for key, idx in pairs(prof.bone) do keyOf[idx] = key end end
			cs:Remove()
		end
		-- (the rest pose as the engine gives it: model -> bone, or the other way round; told apart by
		-- which keeps a bone's own corners near it)
		local base = binds and (binds[0] and 0 or 1) or 0
		local function Rows(b)
			local bp = binds and binds[b + base]
			return bp and bp.matrix and M.FromMatrix(bp.matrix) or nil
		end
		for t = 0, nt - 1 do
			local b = dom[t * 3 + 1]
			local key = keyOf[b]
			if key then
				local u = units["on_" .. key]
				if not u then
					local r = Rows(b)
					local inv = r and M.Inv(r)
					local i1 = t * 3 + 1
					local toBone = r
					if r and inv then
						local ax, ay, az = M.Xf(r, px[i1], py[i1], pz[i1])
						local bx, by, bz = M.Xf(inv, px[i1], py[i1], pz[i1])
						if bx * bx + by * by + bz * bz < ax * ax + ay * ay + az * az then toBone = inv end
					end
					u = { id = "on_" .. key, verts = {}, pts = {}, n = 0, bones = {}, key = key, toBone = toBone, how = "bone", want = 0, c = { 0, 0, 0 } }
					units[u.id] = u
				end
				if u.toBone then
					for k = 1, 3 do
						local i = t * 3 + k
						local x, y, z = M.Xf(u.toBone, px[i], py[i], pz[i])
						local a, b2, c2 = M.Rot(u.toBone, nx[i], ny[i], nz[i])
						u.verts[#u.verts + 1] = { pos = Vector(x, y, z), normal = Vector(a, b2, c2), u = tu[i], v = tv[i] }
					end
					u.n = u.n + 1
				end
			end
			if t % 800 == 0 then yield() end
		end
		G.note = string.format("NOT the stock model (%d of %d pieces found, %d triangles where the stock model has %d, %d pieces where it has %d): drawn by animation bone, its bones cannot be told apart",
			found, #ST.pieces, nt, ST.tris, #comps, ST.npieces)
	end
	-- the meshes
	local order, wrong = {}, 0
	for uid, u in pairs(units) do
		if u.n > 0 then
			u.mesh = Mesh()
			u.mesh:BuildFromTriangles(u.verts)
			u.verts = nil
			if u.want > 0 and u.want ~= u.n then wrong = wrong + 1 end
			order[#order + 1] = uid
			yield()
		end
	end
	table.sort(order)
	G.units, G.order = units, order
	if wrong > 0 then G.note = G.note .. string.format("; %d unit(s) with another number of triangles than the generator found", wrong) end
	-- the reference rig's rest pose, as the engine has it, against the data's (the same model: the same pose)
	if stock and binds then
		local cs = ClientsideModel(ST.model)
		if IsValid(cs) then
			cs:SetNoDraw(true)
			cs:SetupBones()
			local base = binds[0] and 0 or 1
			local worst = 0
			for _, key in ipairs({ "pelvis", "spine_up", "head", "thigh_l", "forearm_r", "foot_l" }) do
				local idx = cs:LookupBone(SK.Rig.profiles[1].names[key][1])
				local bp = idx and binds[idx + base]
				if bp and bp.matrix then
					local r = M.FromMatrix(bp.matrix)
					local inv = M.Inv(r)
					local a, b = 0, 0
					for k = 1, 12 do
						a = math.max(a, math.abs(r[k] - ST.rest[key][k]))
						if inv then b = math.max(b, math.abs(inv[k] - ST.rest[key][k])) end
					end
					worst = math.max(worst, math.min(a, b))
				end
			end
			cs:Remove()
			G.restOff = worst
			G.note = G.note .. string.format("; its rest pose is the data's to within %.4f", worst)
		end
	end
	G.state = "ready"
	G.stats.ms = (SysTime() - t0) * 1000
	SK.Print("geometry ready: %s (%d units; %.0f ms of work over %d frames, %.0f ms of it the engine reading the model)", G.note, #order, G.stats.work or 0, G.stats.steps, G.stats.engineMs)
end

-- Asks for the geometry: starts the work if it has not begun. Returns the state.
function G.Request()
	if G.state == "none" then
		G.state = "building"
		G.stats.steps, G.stats.work = 0, 0
		G.co = coroutine.create(Build)
	end
	return G.state
end

-- Does a part of the work (called every frame by whoever wants the geometry). True when it is there.
function G.Step(budgetMs)
	if G.state ~= "building" then return G.state == "ready" end
	local t0 = SysTime()
	G.stats.steps = G.stats.steps + 1
	while G.state == "building" and (SysTime() - t0) * 1000 < (budgetMs or C.View.buildMs) do
		local ok, err = coroutine.resume(G.co)
		if not ok then
			G.state, G.note = "failed", "the model could not be taken apart: " .. tostring(err)
			SK.Print("%s", G.note)
			break
		end
		if coroutine.status(G.co) == "dead" then break end
	end
	G.stats.work = (G.stats.work or 0) + (SysTime() - t0) * 1000
	if G.state == "building" and G.co and coroutine.status(G.co) == "dead" then G.state = "failed" end
	return G.state == "ready"
end

concommand.Add("skel_geo_reload", function()
	G.Free()
	SK.Print("geometry dropped: it is built again when a view next asks for it")
end, nil, "Skeleton: drop the meshes made from the game's skeleton model; they are made again when the view next needs them")
