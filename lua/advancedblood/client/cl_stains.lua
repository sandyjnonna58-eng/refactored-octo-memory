-- Stains. Every stain is an engine decal (correct lightmapping, clipped to the surface so it can
-- never float or poke through geometry, zero per-frame cost) plus, while fresh, a "wet" overlay
-- quad drawn on top with the same shape. The overlay is fresh wet blood (its colour and translucent
-- thin rim from the atlas, a Fresnel reflection of the surroundings on top) and dries from the
-- rim inward (shrinks + fades), revealing the darker decal: fresh -> ageing -> dried.
-- Directional stains (elongated, smears, satellites) are rotated with $basetexturetransform
-- variants matched to the engine's decal basis so they point along the impact direction.

ABL.NoJIT()
ABL.Stains = ABL.Stains or {}
local S = ABL.Stains
local C, M, L = ABL.Config, ABL.Mat, ABL.LOD
local sqrt, abs, atan2, floor, min, max, cos, sin = math.sqrt, math.abs, math.atan2, math.floor, math.min, math.max, math.cos, math.sin

-- wet overlays live in chunks of static meshes (one atlas material, rebuilt only when changed).
-- A chunk is the map's, or one thing's (a prop, a door, a lift): a thing's overlays are kept in
-- its own space and drawn where it is now, so they go where it goes and end when it does. (Until
-- phase 46 every overlay was a quad at a place of the map: move a spattered crate and its wet
-- blood stayed behind in the air until it had dried, or take the crate away and it hung there.)
local chunks = {}
S.chunks = chunks
local ovCount = 0
local CHUNK = 48
local openMap                                          -- the map's chunk that still takes overlays
local openOf = setmetatable({}, { __mode = "k" })      -- thing -> its chunk that still takes overlays

-- verified by the in-game test (decal texture space rotation sign)
S.ROT_SIGN = 1

------------------------------------------------------------------------------------------
-- Engine decal basis (replicates the engine's texture-space basis for decals without an
-- explicit s-axis): floors/ceilings use world X for S; walls use world down for T.
------------------------------------------------------------------------------------------
function S.Basis(nx, ny, nz)
	local sx, sy, sz, tx, ty, tz
	if abs(nz) > 0.70710678 then
		sx, sy, sz = 1, 0, 0
		tx, ty, tz = sy * nz - sz * ny, sz * nx - sx * nz, sx * ny - sy * nx
		sx, sy, sz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
	else
		tx, ty, tz = 0, 0, -1
		sx, sy, sz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
		tx, ty, tz = sy * nz - sz * ny, sz * nx - sx * nz, sx * ny - sy * nx
	end
	local sl = sqrt(sx * sx + sy * sy + sz * sz)
	local tl = sqrt(tx * tx + ty * ty + tz * tz)
	if sl < 1e-6 then sl = 1 end
	if tl < 1e-6 then tl = 1 end
	return sx / sl, sy / sl, sz / sl, tx / tl, ty / tl, tz / tl
end

-- The same for a decal on a model (studiorender, AddDecal): the engine lays u along up x n, or
-- along (0, 1, 0) x n where the surface faces straight up or down, and v along n x u. On a wall
-- that is the basis above; on anything that leans it is not (above, a floor's u is the world's
-- x axis whichever way the floor leans; on a model it lies across the slope).
-- S.MODEL_V: which way the picture's v runs along n x u. Found with scene look_turn (run q46b):
-- with 1 a stain given a direction points that way on top of a crate and on its side; with -1
-- it is mirrored (down becomes up). So a model's decal is the map's seen in a mirror.
S.MODEL_V = 1
function S.BasisModel(nx, ny, nz)
	local ux, uy, uz = -ny, nx, 0
	local l = sqrt(ux * ux + uy * uy)
	if l < 1e-3 then
		ux, uy, uz = nz, 0, -nx
		l = sqrt(ux * ux + uz * uz)
		if l < 1e-6 then return 1, 0, 0, 0, -1, 0 end
	end
	ux, uy, uz = ux / l, uy / l, uz / l
	local k = S.MODEL_V
	return ux, uy, uz, (ny * uz - nz * uy) * k, (nz * ux - nx * uz) * k, (nx * uy - ny * ux) * k
end

------------------------------------------------------------------------------------------
-- Rate limiting
------------------------------------------------------------------------------------------
local tokens, lastRefill = 0, 0
-- small stains may only use the bucket while it is comfortably full, so large splashes, pools
-- and runoff streaks still get placed during heavy bleeding
local function TakeDecal(size)
	local now = RealTime()
	local rate = C.cl.decalRate:GetFloat()
	tokens = min(rate * 0.5, tokens + (now - lastRefill) * rate)
	lastRefill = now
	local need = (size and size < 1.5) and 6 or 1
	if tokens < need then return false end
	tokens = tokens - 1
	return true
end
S.stats = { decals = 0, rejected = 0 }

local vecPos, vecNorm = Vector(), Vector()
local colTmp = Color(255, 255, 255, 255)
local world

-- Place a stain.
--   fam/idx : texture family / variant (see cl_materials)
--   x,y,z   : point on the surface;  nx,ny,nz: outward surface normal
--   dx,dy,dz: in-plane unit direction the stain points to (nil = random orientation)
--   w, h    : world size of the texture: w along the direction, h across it ("streak" textures
--             run along v, so for them h is the length)
--   col     : {r,g,b} decal colour, alpha 0..255
--   wetT    : seconds the wet overlay lasts (nil/0 = no overlay)
-- Engine decals are scaled along the surface's own fixed decal basis while the stain is rotated
-- inside the texture, so only square decals keep their shape at any angle: a long directional
-- stain is laid down as a row of overlapping squares along its direction.
-- Engine decals (timed for the profiler: placing one is the costliest single call a stain makes).
local function Decal(mat, ent, pos, normal, col, w, h)
	local t0 = SysTime()
	util.DecalEx(mat, ent, pos, normal, col, w, h)
	ABL.Prof.Add("sub.decals", SysTime() - t0)
end

function S.Place(fam, idx, x, y, z, nx, ny, nz, dx, dy, dz, w, h, col, alpha, ent, wetT, rng)
	-- (a stain needs a place, a surface and a size)
	if not (ABL.InWorld(x, y, z) and nx * nx + ny * ny + nz * nz > 0.5 and w > 0 and w < 1e3 and h > 0 and h < 1e3) then return false end
	if dx and not ABL.Finite3(dx, dy, dz) then dx = nil end
	alpha = alpha * C.BloodMarkOpacity
	local stainScale = C.cl.stainScale:GetFloat()
	w, h = w * stainScale, h * stainScale
	if S.CellFull(x, y, z) then S.stats.rejected = S.stats.rejected + 1 return false end
	if not TakeDecal(w) then S.stats.rejected = S.stats.rejected + 1 return false end

	world = world or game.GetWorld()
	local target = IsValid(ent) and ent or world
	-- (a model: a prop, a body. A door or a lift is a piece of the map's own kind of geometry.)
	local onModel = target ~= world and string.sub(target:GetModel() or "*", 1, 1) ~= "*"
	local sx, sy, sz, tx, ty, tz
	if onModel then sx, sy, sz, tx, ty, tz = S.BasisModel(nx, ny, nz) else sx, sy, sz, tx, ty, tz = S.Basis(nx, ny, nz) end
	local step = 0
	local ang = 0
	if dx then
		local du = dx * sx + dy * sy + dz * sz
		local dv = dx * tx + dy * ty + dz * tz
		ang = atan2(dv, du)
	elseif rng then
		ang = rng:Next() * 6.2831853
	else
		ang = math.random() * 6.2831853
	end
	if fam == "streak" then ang = ang - 1.5707963 end -- streak textures run along +v
	local steps = M.ROT_STEPS
	step = floor(ang / 6.2831853 * steps + 0.5) % steps
	local tm = SysTime()
	local mat
	if onModel then mat = M.DecalModel(fam, idx, (step * S.ROT_SIGN) % steps) else mat = M.Decal(fam, idx, (step * S.ROT_SIGN) % steps) end
	ABL.Prof.Add("sub.decalmat", SysTime() - tm)
	if not mat then return false end

	-- A long dry mark on a model (the trail a stream left on a crate that was moved). The engine's
	-- decals on a model are square, and a model keeps fifty of them: laid as a row of squares the
	-- trail was a dotted line, and four squares a stain for thirty stains pushed the crate's other
	-- stains off it. It is one flat mark of ABL's own instead, kept in the thing's space like a
	-- wet overlay, which stays (C.Stain.trailLife).
	if onModel and dx and fam ~= "streak" and w > h * 1.6 and not (wetT and wetT > 0) then
		local dn = dx * nx + dy * ny + dz * nz
		local ax, ay, az = ABL.Norm(dx - nx * dn, dy - ny * dn, dz - nz * dn)
		if ax ~= 0 or ay ~= 0 or az ~= 0 then
			local bx, by, bz = ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax
			if S.AddOverlay(fam, idx, x, y, z, nx, ny, nz, ax, ay, az, bx, by, bz, w * 0.5, h * 0.5, C.Stain.trailLife, alpha, target, true) then
				S.stats.trails = (S.stats.trails or 0) + 1
				ABL.Surface.CountDecal(x, y, z)
				return true
			end
		end
	end

	vecNorm:SetUnpacked(nx, ny, nz)
	colTmp.r, colTmp.g, colTmp.b, colTmp.a = min(255, col[1]), min(255, col[2]), min(255, col[3]), min(255, alpha)
	-- Where the decal is laid. On the map: at the surface itself. The engine takes the surfaces
	-- that lie within the decal's OWN size of that place, and ours is one unit whatever it is
	-- scaled to (cl_materials.lua): laid a unit above a floor it found none, and no decal of
	-- ABL's showed on the map at all (phase 46, scene look_decal2: the same decal a unit up and
	-- at the floor). A smear, a print or what a pool leaves was its wet overlay alone and was
	-- gone when that had dried. On a model the decal is shot along a line and starts outside it.
	local lift = onModel and 1 or 0.1
	local lx, ly, lz = nx * lift, ny * lift, nz * lift
	if dx and fam ~= "streak" and w > h * 1.15 then
		local n = min(4, math.ceil(w / h - 0.15))
		local span = w - h
		for i = 1, n do
			local t = (n == 1) and 0 or ((i - 1) / (n - 1) - 0.5) * span
			vecPos:SetUnpacked(x + lx + dx * t, y + ly + dy * t, z + lz + dz * t)
			Decal(mat, target, vecPos, vecNorm, colTmp, h, h)
		end
		S.stats.decals = S.stats.decals + n
	else
		local aspect = (fam == "streak") and 2 or 1
		vecPos:SetUnpacked(x + lx, y + ly, z + lz)
		Decal(mat, target, vecPos, vecNorm, colTmp, w, h / aspect)
		S.stats.decals = S.stats.decals + 1
	end
	ABL.Surface.CountDecal(x, y, z)

	if wetT and wetT > 0 then
		local qa = step * 6.2831853 / steps
		local ca, sa = cos(qa), sin(qa)
		-- in-plane axes of the texture after rotation
		local ux, uy, uz = sx * ca + tx * sa, sy * ca + ty * sa, sz * ca + tz * sa
		local vx, vy, vz = -sx * sa + tx * ca, -sy * sa + ty * ca, -sz * sa + tz * ca
		S.AddOverlay(fam, idx, x, y, z, nx, ny, nz, ux, uy, uz, vx, vy, vz, w * 0.5, h * 0.5, wetT, alpha, target ~= world and target or nil)
	end
	return true
end

function S.CellFull(x, y, z)
	return ABL.Surface.CellDecals(x, y, z) >= C.Stain.cellCap
end

------------------------------------------------------------------------------------------
-- Wet overlays
------------------------------------------------------------------------------------------
local function NewChunk(ent)
	local c = { items = {}, mesh = nil, dirty = true, nextBuild = 0, nextAge = 0, x = 0, y = 0, z = 0, rad = 0, ent = ent }
	chunks[#chunks + 1] = c
	return c
end

-- (The oldest overlay there is: of the first chunk that still holds one. A chunk emptied here stays
-- in the list until the next draw; taking "one more" from it counted an overlay off that was not
-- there, and after a burst the cap let that many more through.)
local function DropOldest()
	for i = 1, #chunks do
		local c = chunks[i]
		if #c.items > 0 then
			table.remove(c.items, 1)
			ovCount = ovCount - 1
			c.dirty = true
			return
		end
	end
end

-- Can overlays ride on this thing? What moves as a whole carries them. What bends (a ragdoll that
-- is no character, an NPC) does not: its stains are the engine's decals alone, which bend with it.
local function Carries(ent)
	return not (ent:IsRagdoll() or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot())
end

-- (a place or a direction of the map in the space of a thing at pos, ang)
local toLocal = Vector()
local function Into(x, y, z, pos, ang)
	toLocal:SetUnpacked(x, y, z)
	local v = WorldToLocal(toLocal, angle_zero, pos, ang)
	return v.x, v.y, v.z
end
-- (where a thing is now, as the matrix its chunk is drawn under)
local frame = Matrix()
local function Frame(ent)
	frame:Identity()
	frame:SetTranslation(ent:GetPos())
	frame:SetAngles(ent:GetAngles())
	return frame
end

-- ent: the thing the stain is on (nil: the map). dry: a mark of blood that has set (it does not
-- shrink and go as a wet overlay does: it stays for `life` seconds and fades at the end).
-- Returns true when the overlay was made.
function S.AddOverlay(fam, idx, x, y, z, nx, ny, nz, ux, uy, uz, vx, vy, vz, hw, hh, life, alpha, ent, dry)
	if ent and not Carries(ent) then return false end
	if ovCount >= L.Cap(C.cl.maxOverlays) then DropOldest() end
	local c
	if ent then c = openOf[ent] else c = openMap end
	if not c or c.gone or #c.items >= CHUNK then
		c = NewChunk(ent)
		if ent then openOf[ent] = c else openMap = c end
	end
	local off = C.Stain.offset + (#c.items % 5) * 0.004 -- tiny layering offset avoids z-fighting between overlays
	x, y, z = x + nx * off, y + ny * off, z + nz * off
	if ent then
		local pos, ang = ent:GetPos(), ent:GetAngles()
		x, y, z = Into(x, y, z, pos, ang)
		nx, ny, nz = Into(nx, ny, nz, vector_origin, ang)
		ux, uy, uz = Into(ux, uy, uz, vector_origin, ang)
		vx, vy, vz = Into(vx, vy, vz, vector_origin, ang)
	end
	c.items[#c.items + 1] = {
		x = x, y = y, z = z, nx = nx, ny = ny, nz = nz,
		ux = ux, uy = uy, uz = uz, vx = vx, vy = vy, vz = vz, hw = hw, hh = hh,
		born = CurTime(), life = dry and life or life * C.sv.drying:GetFloat(), alpha = alpha, dry = dry,
		cell = M.AtlasCell(fam, idx), tone = math.Rand(C.ToneRange[1], C.ToneRange[2]),
	}
	ovCount = ovCount + 1
	c.dirty = true
	return true
end

local vec = Vector()
local function Vert(x, y, z, u, v, r, g, b, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

-- Two static meshes per chunk: the wet overlays (their colour from the atlas, lit on the CPU) and
-- their reflection (gloss atlas, additive; the view-dependent Fresnel strength is applied per draw
-- through $color, the mesh holds wetness and light).
local function Build(c, now)
	if c.mesh then c.mesh:Destroy() c.mesh = nil end
	if c.gloss then c.gloss:Destroy() c.gloss = nil end
	local items = c.items
	local n = #items
	local ent = c.ent
	c.dirty = false
	if n == 0 then return end
	local R = ABL.Render
	local quads = {}
	local sx, sy, sz, nx, ny, nz = 0, 0, 0, 0, 0, 0
	for i = 1, n do
		local o = items[i]
		sx, sy, sz = sx + o.x, sy + o.y, sz + o.z
		nx, ny, nz = nx + (o.nx or 0), ny + (o.ny or 0), nz + (o.nz or 1)
		local k = math.Clamp((now - o.born) / o.life, 0, 1)
		-- dries from the rim inward: shrink a little, fade out; the reflection goes first
		local sc = 1 - 0.28 * k
		local a = o.alpha * (1 - k) ^ 1.4
		local wet = (1 - k) ^ 2
		local dr, dg = 1, 1
		if o.dry then
			-- (as it is for nearly all of its time, then it fades; the darker red of blood that has set)
			sc, a, wet = 1, o.alpha * min(1, (1 - k) * 8), 0
			dr, dg = 0.5, 0.62
		end
		-- (the light of the place on the map where it is now)
		local lx, ly, lz = o.x, o.y, o.z
		if ent then
			toLocal:SetUnpacked(lx, ly, lz)
			local w = ent:LocalToWorld(toLocal)
			lx, ly, lz = w.x, w.y, w.z
		end
		local lr, lg, lb = R.Light(lx, ly, lz)
		local t = o.tone or 1
		local hw, hh = o.hw * sc, o.hh * sc
		local ax, ay, az = o.ux * hw, o.uy * hw, o.uz * hw
		local bx, by, bz = o.vx * hh, o.vy * hh, o.vz * hh
		quads[i] = { o.x - ax - bx, o.y - ay - by, o.z - az - bz, o.x + ax - bx, o.y + ay - by, o.z + az - bz,
			o.x + ax + bx, o.y + ay + by, o.z + az + bz, o.x - ax + bx, o.y - ay + by, o.z - az + bz,
			min(255, 255 * lr * t * dr), min(255, 255 * lg * dg), min(255, 255 * lb * dg), a,
			min(255, 255 * wet * lr), min(255, 255 * wet * lg), min(255, 255 * wet * lb), o.cell }
	end
	for pass = 1, 2 do
		local m = Mesh()
		mesh.Begin(m, MATERIAL_QUADS, n)
		for i = 1, n do
			local q = quads[i]
			local cell = q[20]
			local u0, v0, u1, v1 = cell[1], cell[2], cell[3], cell[4]
			local r, g, b = q[13], q[14], q[15]
			if pass == 2 then r, g, b = q[17], q[18], q[19] end
			Vert(q[1], q[2], q[3], u0, v0, r, g, b, q[16])
			Vert(q[4], q[5], q[6], u1, v0, r, g, b, q[16])
			Vert(q[7], q[8], q[9], u1, v1, r, g, b, q[16])
			Vert(q[10], q[11], q[12], u0, v1, r, g, b, q[16])
		end
		mesh.End()
		if pass == 1 then c.mesh = m else c.gloss = m end
	end
	c.x, c.y, c.z = sx / n, sy / n, sz / n
	c.nx, c.ny, c.nz = ABL.Norm(nx, ny, nz)
	local rad = 0
	for i = 1, n do
		local o = items[i]
		local d = math.sqrt((o.x - c.x) ^ 2 + (o.y - c.y) ^ 2 + (o.z - c.z) ^ 2) + math.max(o.hw, o.hh)
		if d > rad then rad = d end
	end
	c.rad = rad
end

local glossList, glossCol, glossOff, glossMat = {}, Vector(), Vector(), Matrix()

function S.Draw()
	local now = CurTime()
	local rt = RealTime()
	local maxD = math.min(C.cl.drawDist:GetFloat(), 2500)
	local builds = 0
	local set = false
	local ng = 0
	for i = #chunks, 1, -1 do
		local c = chunks[i]
		local ent = c.ent
		-- (a thing that is gone takes its overlays with it)
		if ent ~= nil and not IsValid(ent) then
			ovCount = ovCount - #c.items
			c.items = {}
			ent = nil
		end
		-- ageing step: drop dried overlays, refresh fading colours about once per second
		if rt > c.nextAge then
			c.nextAge = rt + 1 + math.random() * 0.2
			local items = c.items
			for j = #items, 1, -1 do
				if now - items[j].born >= items[j].life then
					table.remove(items, j)
					ovCount = ovCount - 1
				end
			end
			c.dirty = true
		end
		if #c.items == 0 then
			if c.mesh then c.mesh:Destroy() end
			if c.gloss then c.gloss:Destroy() end
			c.gone = true
			table.remove(chunks, i)
		else
			if (c.dirty or not c.mesh) and rt > c.nextBuild and builds < 4 then
				Build(c, now)
				builds = builds + 1
				c.nextBuild = rt + 0.1
				-- (building a mesh does not keep the material that was set: cl_render.lua, FilterDraw)
				set = false
			end
			if c.mesh then
				-- (where the chunk is: its own place, or where its thing has carried it)
				local cx, cy, cz = c.x, c.y, c.z
				if ent then
					toLocal:SetUnpacked(cx, cy, cz)
					local w = ent:LocalToWorld(toLocal)
					cx, cy, cz = w.x, w.y, w.z
				end
				local d2, vis = L.View(cx, cy, cz, c.rad)
				if vis and d2 < (maxD + c.rad) ^ 2 and not (ent and (ent:IsDormant() or ent:GetNoDraw())) then
					if not set then render.SetMaterial(M.atlas) set = true end
					if ent then
						cam.PushModelMatrix(Frame(ent))
						c.mesh:Draw()
						cam.PopModelMatrix()
					else
						c.mesh:Draw()
					end
					c.wx, c.wy, c.wz = cx, cy, cz
					if c.gloss and d2 < 1200 * 1200 then ng = ng + 1 glossList[ng] = c end
				end
			end
		end
	end
	-- wet reflection: Fresnel of the view angle on the chunk's (mean) surface, pattern slid with the view
	if ng > 0 then
		local gm = M.atlasGloss
		glossOff:SetUnpacked((L.eyeX - L.eyeY) / 70 % 1, (L.eyeZ + L.eyeX) / 70 % 1, 0)
		glossMat:SetTranslation(glossOff)
		gm:SetMatrix("$detailtexturetransform", glossMat)
		render.SetMaterial(gm)
		for i = 1, ng do
			local c = glossList[i]
			glossList[i] = nil
			local ent = c.ent
			-- (the way the chunk's surface faces: its thing may have turned)
			local nx, ny, nz = c.nx, c.ny, c.nz
			if ent then
				toLocal:SetUnpacked(nx, ny, nz)
				local w = LocalToWorld(toLocal, angle_zero, vector_origin, ent:GetAngles())
				nx, ny, nz = w.x, w.y, w.z
			end
			local dx, dy, dz = c.wx - L.eyeX, c.wy - L.eyeY, c.wz - L.eyeZ
			local d = max(sqrt(dx * dx + dy * dy + dz * dz), 1)
			local k = min(C.Ground.sheen * ABL.Render.Fresnel((dx * nx + dy * ny + dz * nz) / d), 0.7)
			if k > 0.01 then
				glossCol:SetUnpacked(k, k, k)
				gm:SetVector("$color", glossCol)
				if ent then
					cam.PushModelMatrix(Frame(ent))
					c.gloss:Draw()
					cam.PopModelMatrix()
				else
					c.gloss:Draw()
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
-- Convenience placements
------------------------------------------------------------------------------------------
-- Tiny stain (particles landing): a ground spot on floors, a small decal elsewhere
function S.Tiny(pos, normal)
	local n = normal
	local gx, gy, gz, gmag = ABL.Gravity()
	if -(n.x * gx + n.y * gy + n.z * gz) / gmag > 0.64 then
		ABL.Ground.Tiny(pos.x, pos.y, pos.z, n.x, n.y, n.z)
		return
	end
	S.Place("drop", math.random(1, 4), pos.x, pos.y, pos.z, n.x, n.y, n.z, nil, nil, nil, 0.9, 0.9, C.Colors.decal, 220, nil, 0)
end

------------------------------------------------------------------------------------------
-- Studio decals on bodies.
-- The engine stamps its own red splat ("Impact.Flesh") on a body wherever a bullet strikes it. ABL
-- draws the wound there itself, and a decal on a model cannot be taken off singly: so, with the
-- takeover on, ABL clears the body's decals a moment after each hit it has a wound for and puts its
-- own back. It keeps the last few it placed on each body, in the space of the nearest bone.
------------------------------------------------------------------------------------------
-- abl_max_body_decals is how many a body keeps. One decal cannot be taken off a model: when a
-- body carries twice as many as it may keep, all of them are cleared and the newest put back
-- (only while ABL clears the engine's hit decals anyway: with abl_engine_hit_decals 1 what is on
-- a body is the engine's to keep, and the engine's own limit for a model holds).
local bodyLog = setmetatable({}, { __mode = "k" })
local bodyNew = setmetatable({}, { __mode = "k" })   -- body -> decals put on it since it was last cleared
local ClearBody

local function NearestBone(ent, pos)
	local best, bd
	for b = 0, (ent:GetBoneCount() or 0) - 1 do
		local m = ABL.ZC.BoneMatrix(ent, b)
		if m then
			local d = m:GetTranslation():DistToSqr(pos)
			if not bd or d < bd then best, bd = b, d end
		end
	end
	return best
end

local function BodyDecal(mat, ent, pos, normal, w, h)
	local most = C.cl.maxBodyDecals:GetInt()
	if most <= 0 then return end
	Decal(mat, ent, pos, normal, colTmp, w, h)
	local bone = NearestBone(ent, pos)
	local m = bone and ABL.ZC.BoneMatrix(ent, bone)
	if not m then return end
	local ang = m:GetAngles()
	local log = bodyLog[ent]
	if not log then log = {} bodyLog[ent] = log end
	while #log >= most do table.remove(log, 1) end
	log[#log + 1] = {
		mat = mat, bone = bone, w = w, h = h,
		lpos = WorldToLocal(pos, angle_zero, m:GetTranslation(), ang),
		lnorm = WorldToLocal(normal, angle_zero, vector_origin, ang),
	}
	local n = (bodyNew[ent] or 0) + 1
	bodyNew[ent] = n
	if n >= most * 2 and not C.cl.fleshDecals:GetBool() then
		S.stats.bodyClears = (S.stats.bodyClears or 0) + 1
		ClearBody(ent)
	end
end

-- A bullet struck this body and ABL has a wound for it: the engine's own decal goes. The effect
-- that places it reaches the client with the hit, but the client plays effects late by its
-- interpolation delay; so the body is cleared just after that, and once more a little later.
local clearAt = setmetatable({}, { __mode = "k" })
local cvInterp, cvRatio, cvRate

function ClearBody(ent)
	if not IsValid(ent) then return end
	ent:RemoveAllDecals()
	local log = bodyLog[ent]
	bodyNew[ent] = log and #log or 0
	if not log then return end
	-- (no more than the body may keep now: the limit may have been lowered since they were placed)
	local most = C.cl.maxBodyDecals:GetInt()
	while #log > most do table.remove(log, 1) end
	bodyNew[ent] = #log
	colTmp.r, colTmp.g, colTmp.b, colTmp.a = 255, 255, 255, 255
	for i = 1, #log do
		local d = log[i]
		local m = ABL.ZC.BoneMatrix(ent, d.bone)
		if m then
			local ang = m:GetAngles()
			local pos = LocalToWorld(d.lpos, angle_zero, m:GetTranslation(), ang)
			local nrm = LocalToWorld(d.lnorm, angle_zero, vector_origin, ang)
			Decal(d.mat, ent, pos, nrm, colTmp, d.w, d.h)
		end
	end
end

function S.ClearEngineHitDecal(ent)
	if not IsValid(ent) or clearAt[ent] then return end
	clearAt[ent] = true
	cvInterp = cvInterp or GetConVar("cl_interp")
	cvRatio = cvRatio or GetConVar("cl_interp_ratio")
	cvRate = cvRate or GetConVar("cl_updaterate")
	local lerp = 0.1
	if cvInterp and cvRatio and cvRate then
		lerp = math.Clamp(max(cvInterp:GetFloat(), cvRatio:GetFloat() / max(cvRate:GetFloat(), 1)), 0, 0.5)
	end
	timer.Simple(lerp + 0.03, function() ClearBody(ent) end)
	timer.Simple(lerp + 0.22, function()
		clearAt[ent] = nil
		ClearBody(ent)
	end)
end

-- Studio decal on a character that was hit by a droplet: the spot of a drop that stays where it
-- landed. Every spot is one of its family's pictures at a turn and a size of its own (until
-- phase 46 all lay the same way up in one size: a row of equal ovals).
local charTokens = setmetatable({}, { __mode = "k" })
function S.OnCharacter(ent, x, y, z, nx, ny, nz, vol)
	if not IsValid(ent) or not (ABL.InWorld(x, y, z) and ABL.Finite3(nx, ny, nz) and vol > 0) then return end
	local now = RealTime()
	if (charTokens[ent] or 0) > now then return end
	charTokens[ent] = now + 0.12
	if not TakeDecal() then return end
	local size = math.Clamp(ABL.DropDiameterMM(vol) / 25.4 * 3, 0.6, 3.5) * (0.8 + 0.5 * math.random())
	world = world or game.GetWorld()
	-- normal points from the surface toward where the drop came from
	vecPos:SetUnpacked(x + nx * 2, y + ny * 2, z + nz * 2)
	vecNorm:SetUnpacked(nx, ny, nz)
	colTmp.r, colTmp.g, colTmp.b, colTmp.a = 255, 255, 255, 255
	local fam = vol > 0.05 and "splat" or "drop"
	-- (in the colour of the fresh blood on that body: cl_materials.lua, M.DecalSpot)
	BodyDecal(M.DecalSpot(fam, math.random(1, M.families[fam]), math.random(0, M.ROT_STEPS - 1)), ent, vecPos, vecNorm, size, size)
	S.stats.decals = S.stats.decals + 1
	S.stats.bodySpots = (S.stats.bodySpots or 0) + 1
end

-- Blood soaking into clothes / skin around a wound: a studio decal projected onto the model,
-- so it follows animation and ragdoll poses exactly (engine skinned decal).
function S.BodySoak(ent, x, y, z, nx, ny, nz, size)
	if not IsValid(ent) or not (ABL.InWorld(x, y, z) and ABL.Finite3(nx, ny, nz) and size > 0) or not TakeDecal(size) then return end
	vecPos:SetUnpacked(x + nx * 1.5, y + ny * 1.5, z + nz * 1.5)
	vecNorm:SetUnpacked(nx, ny, nz)
	colTmp.r, colTmp.g, colTmp.b, colTmp.a = 255, 255, 255, 255
	BodyDecal(M.DecalModel("soak", math.random(1, M.families.soak), math.random(0, M.ROT_STEPS - 1)), ent, vecPos, vecNorm, size, size)
	S.stats.decals = S.stats.decals + 1
end

-- Wound mark on a body (studio decal at the wound)
function S.WoundMark(ent, x, y, z, nx, ny, nz, size)
	if not IsValid(ent) or not (ABL.InWorld(x, y, z) and ABL.Finite3(nx, ny, nz) and size > 0) or not TakeDecal() then return end
	vecPos:SetUnpacked(x + nx * 2, y + ny * 2, z + nz * 2)
	vecNorm:SetUnpacked(nx, ny, nz)
	colTmp.r, colTmp.g, colTmp.b, colTmp.a = 255, 255, 255, 255
	Decal(M.decal.wound[1], ent, vecPos, vecNorm, colTmp, size, size)
end

function S.Clear()
	for i = #chunks, 1, -1 do
		if chunks[i].mesh then chunks[i].mesh:Destroy() end
		if chunks[i].gloss then chunks[i].gloss:Destroy() end
		chunks[i].gone = true
		chunks[i] = nil
	end
	openMap = nil
	for k in pairs(openOf) do openOf[k] = nil end
	ovCount = 0
end

function S.Count() return ovCount end
-- (developer: how many of ABL's decals a body's log holds, and how many it carries since it was last cleared)
function S.BodyDecals(ent) return bodyLog[ent] and #bodyLog[ent] or 0, bodyNew[ent] or 0 end
