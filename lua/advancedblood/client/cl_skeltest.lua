-- Skeleton probe (developer tool, phase 1 of the anatomical skeleton: an audit, not a feature).
-- Inert unless the test harness is running (see cl_selftest.lua). It answers, in this build of the
-- game, the questions a plan for a visible skeleton rests on:
--   * which skeleton models the game itself has mounted;
--   * whether the engine hands out the stock skeleton model's triangles, bone weights and rest
--     pose to Lua (util.GetModelMeshes) without the model being in the world;
--   * whether that model, bone-merged onto one of Z-City's characters, follows it (standing, as
--     the ragdoll Z-City lays it down in), and how well it fits inside male and female bodies;
--   * whether a piece of it (the skull) can be drawn as a rigid mesh of its own on a body's bone.
-- Nothing here is used by the addon; the files can be deleted with the probe.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local BM = ABL.BodyMesh

local SKEL = "models/player/skeleton.mdl"
local probes = {}          -- [body entity] = { cs = clientside skeleton, mode = ..., head = IMesh, headBone = n }
local white = Material("models/debug/debugwhite")

local function Body(idx)
	local ent = Entity(idx or 0)
	if not IsValid(ent) then return nil end
	return ent:IsPlayer() and ABL.ZC.GetBody(ent) or ent
end

-- What is mounted, and what the engine gives of the stock model.
function H.skelassets()
	for _, f in ipairs({ SKEL, "models/skeleton/skeleton_whole.mdl", "models/skeleton/skeleton_torso.mdl", "models/gibs/hgibs.mdl", "models/gibs/hgibs_spine.mdl",
		"materials/models/skeleton/skeleton.vmt", "materials/models/skeleton/skeleton_bloody.vmt" }) do
		local isModel = string.EndsWith(f, ".mdl")
		Log(string.format("skelprobe: %s | in the game's files: %s%s", f, tostring(file.Exists(f, "GAME")), isModel and (" | a valid model: " .. tostring(util.IsValidModel(f))) or ""))
	end
	util.PrecacheModel(SKEL)
	local t0 = SysTime()
	local meshes, binds = util.GetModelMeshes(SKEL, 0, 0)
	local ms = (SysTime() - t0) * 1000
	if not meshes then Log("skelprobe: util.GetModelMeshes gives nothing for " .. SKEL) return end
	local tris, corners, most, bones = 0, 0, 0, {}
	local mats = {}
	for _, sub in ipairs(meshes) do
		mats[#mats + 1] = tostring(sub.material)
		local tr = sub.triangles or {}
		tris = tris + #tr / 3
		for _, v in ipairs(tr) do
			corners = corners + 1
			local ws = v.weights
			if istable(ws) then
				if #ws > most then most = #ws end
				for _, bw in ipairs(ws) do bones[bw.bone] = true end
			end
		end
	end
	local nb, nbind = 0, 0
	for _ in pairs(bones) do nb = nb + 1 end
	for _ in pairs(binds or {}) do nbind = nbind + 1 end
	Log(string.format("skelprobe: util.GetModelMeshes(%s) in %.1f ms: %d part(s) (%s), %d triangles, up to %d bone weights a corner, %d bones carry geometry, %d rest-pose matrices",
		SKEL, ms, #meshes, table.concat(mats, ", "), tris, most, nb, nbind))
end

-- How much of the stock skeleton lies outside a body's surface in the rest pose: each of its
-- corners is carried from the skeleton model's rest pose into the body's by the bones it hangs
-- on (which is what bone-merging does), and measured against the nearest triangle of the body.
local function Fit(body, cs)
	local bm, sm = BM.Get(body), BM.Get(cs)
	if not bm or not sm then return nil, "surface models not built yet" end
	local map = {}
	for b = 0, cs:GetBoneCount() - 1 do
		local name = cs:GetBoneName(b)
		map[b] = name and body:LookupBone(name) or nil
	end
	local X = BM.Xform
	local n, out05, out1, worst, far, lost = 0, 0, 0, 0, 0, 0
	for i = 1, sm.nv, 3 do
		local px, py, pz = sm.vx[i], sm.vy[i], sm.vz[i]
		local x, y, z, wsum = 0, 0, 0, 0
		for k = 1, 3 do
			local b = (k == 1 and sm.b1[i]) or (k == 2 and sm.b2[i]) or sm.b3[i]
			local w = (k == 1 and sm.w1[i]) or (k == 2 and sm.w2[i]) or sm.w3[i]
			local bb = b and b >= 0 and map[b]
			if bb and w > 0 and sm.inv[b] and bm.bind[bb] then
				local lx, ly, lz = X(sm.inv[b], px, py, pz)
				local wx, wy, wz = X(bm.bind[bb], lx, ly, lz)
				x, y, z, wsum = x + wx * w, y + wy * w, z + wz * w, wsum + w
			end
		end
		if wsum > 0 then
			x, y, z = x / wsum, y / wsum, z / wsum
			n = n + 1
			local tri, u, v = BM.Closest(bm, x, y, z, 8)
			if tri then
				local qx, qy, qz = BM.BindPoint(bm, tri, u, v)
				local nx, ny, nz = BM.BindNormal(bm, tri)
				local d = (x - qx) * nx + (y - qy) * ny + (z - qz) * nz
				if d > 0.5 then out05 = out05 + 1 end
				if d > 1 then out1 = out1 + 1 end
				if d > worst then worst = d end
			else
				far = far + 1
			end
		else
			lost = lost + 1
		end
	end
	return string.format("%d corners looked at: %d (%.1f %%) more than 0.5 units outside the nearest surface, %d (%.1f %%) more than 1 unit, the furthest %.1f units; %d with no surface within 8 units; %d on bones the body has not",
		n, out05, 100 * out05 / math.max(n, 1), out1, 100 * out1 / math.max(n, 1), worst, far, lost)
end

-- A skeleton for body t.ent: bone-merged, drawn by this file in the way t.mode says
--   "depth"  as part of the world (what shows of it has come through the body's surface)
--   "xray"   over everything
--   "head"   the skull alone, as a rigid mesh of its own on the body's head bone, over everything
--   "off"    not at all
function H.skelshow(t)
	local body = Body(t.ent)
	if not IsValid(body) then Log("skelprobe: no body for entity " .. tostring(t.ent)) return end
	local p = probes[body]
	if not p then
		local cs = ClientsideModel(SKEL)
		if not IsValid(cs) then Log("skelprobe: no clientside model") return end
		cs:SetNoDraw(true)
		cs:SetParent(body)
		cs:AddEffects(EF_BONEMERGE)
		p = { cs = cs }
		probes[body] = p
		local same, missing = 0, {}
		for b = 0, cs:GetBoneCount() - 1 do
			local name = cs:GetBoneName(b)
			if name and body:LookupBone(name) then same = same + 1 else missing[#missing + 1] = tostring(name) end
		end
		Log(string.format("skelprobe: %s (%s, %d bones): the skeleton model has %d bones, %d of them by the same name on the body%s",
			tostring(body), tostring(body:GetModel()), body:GetBoneCount(), cs:GetBoneCount(), same, #missing > 0 and (" (not: " .. table.concat(missing, ", ") .. ")") or ""))
	end
	p.mode = t.mode
	if t.fit then
		-- (both surface models are built over a few frames: asked for now, measured a moment later)
		BM.Get(body)
		BM.Get(p.cs)
		timer.Simple(1.5, function()
			if not IsValid(body) or not IsValid(p.cs) then return end
			local ok, res, why = pcall(Fit, body, p.cs)
			Log("skelprobe: fit in the rest pose, " .. tostring(body:GetModel()) .. ": " .. (ok and tostring(res or why) or ("failed: " .. tostring(res))))
		end)
	end
	if t.mode == "head" and not p.head then
		local sm = BM.Get(p.cs)
		local hb = p.cs:LookupBone("ValveBiped.Bip01_Head1")
		if sm and hb and sm.inv[hb] then
			local X = BM.Xform
			local verts = {}
			for tri = 1, sm.nt do
				local a, b, c = sm.t1[tri], sm.t2[tri], sm.t3[tri]
				if sm.b1[a] == hb and sm.b1[b] == hb and sm.b1[c] == hb then
					local P = {}
					for k, id in ipairs({ a, b, c }) do
						P[k] = Vector(X(sm.inv[hb], sm.vx[id], sm.vy[id], sm.vz[id]))
					end
					-- (the triangle's own normal, by the model's own winding sign)
					local n = (P[2] - P[1]):Cross(P[3] - P[1])
					n:Normalize()
					n = n * (sm.tsg[tri] or 1)
					for k = 1, 3 do verts[#verts + 1] = { pos = P[k], normal = n, u = 0, v = 0 } end
				end
			end
			if #verts >= 3 then
				p.head = Mesh()
				p.head:BuildFromTriangles(verts)
				p.headBone = body:LookupBone("ValveBiped.Bip01_Head1")
				Log(string.format("skelprobe: the skull as a mesh of its own: %d triangles in the head bone's space", #verts / 3))
			end
		else
			Log("skelprobe: no surface model of the skeleton yet for the skull piece")
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "ABL_SkelProbe", function(depth, sky)
	if sky then return end
	for body, p in pairs(probes) do
		if not IsValid(body) or not IsValid(p.cs) then
			if IsValid(p.cs) then p.cs:Remove() end
			probes[body] = nil
		elseif p.mode == "depth" or p.mode == "xray" then
			-- (a body that has become another entity, a ragdoll: the skeleton goes to that)
			if p.cs:GetParent() ~= body then p.cs:SetParent(body) end
			p.cs:SetupBones()
			if p.mode == "xray" then cam.IgnoreZ(true) end
			p.cs:DrawModel()
			if p.mode == "xray" then cam.IgnoreZ(false) end
		elseif p.mode == "head" and p.head and p.headBone then
			local m = body:GetBoneMatrix(p.headBone)
			if m then
				cam.IgnoreZ(true)
				render.SetMaterial(white)
				cam.PushModelMatrix(m)
				p.head:Draw()
				cam.PopModelMatrix()
				cam.IgnoreZ(false)
			end
		end
	end
end)

-- The skeleton of one body goes to another entity (the ragdoll the character lies in now).
function H.skelmove(t)
	local from, to = Entity(t.from or 0), Body(t.to)
	for body, p in pairs(probes) do
		if (body == from or (IsValid(from) and from:IsPlayer() and body == from)) and IsValid(to) and to ~= body then
			probes[body] = nil
			p.cs:SetParent(to)
			p.head = nil
			probes[to] = p
			Log(string.format("skelprobe: the skeleton goes from %s to %s (%s)", tostring(body), tostring(to), tostring(to:GetModel())))
		end
	end
end

function H.skelclear()
	for body, p in pairs(probes) do
		if IsValid(p.cs) then p.cs:Remove() end
		if p.head then p.head:Destroy() end
		probes[body] = nil
	end
end
