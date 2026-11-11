-- Client half of the look scenes (developer tool; server/sv_looktest.lua). Inert without the test
-- harness.

ABL.NoJIT()
local TC = ABL.TestClient
if not TC then return end
local H, Log = TC.H, TC.Log

-- How many stains there are and whose (a line "lookcount <name>"). t.ents: characters to count for.
function H.lookcount(t)
	local G, S = ABL.Ground, ABL.Stains
	local parts = {}
	for i, e in ipairs(t.ents or {}) do
		local log, carried = 0, 0
		if S.BodyDecals and IsValid(e) then log, carried = S.BodyDecals(ABL.ZC.GetBody(e) or e) end
		parts[i] = string.format("%s: %d ground stains, %d body decals kept (%d on it since it was last cleared)", tostring(e), G.CountFor and G.CountFor(e) or -1, log, carried)
	end
	Log(string.format("lookcount %s | ground stains %d (taken off at a character's own limit so far: %s; removed in all: %d) | overlays %d | spots put on bodies %s, asked for where no body was %s, bodies cleared at their limit %s | %s",
		tostring(t.name), G.Count(), tostring(G.stats.capped), G.stats.removed, S.Count(), tostring(S.stats.bodySpots or 0), tostring(S.stats.bodyMissed or 0),
		tostring(S.stats.bodyClears or 0), table.concat(parts, " ; ")))
end

-- Hand one character's stains to another, as when a player's body becomes a corpse.
function H.lookmove(t)
	if ABL.Ground.MoveOwner then ABL.Ground.MoveOwner(t.from, t.to) end
end

-- Every spot a drop is to leave on a body (ABL.Stains.OnCharacter), counted by body while watched.
local asked = {}
local orig
function H.lookwatch(t)
	asked = {}
	if orig then return end
	orig = ABL.Stains.OnCharacter
	ABL.Stains.OnCharacter = function(ent, x, y, z, nx, ny, nz, vol)
		local a = asked[ent]
		if not a then a = { n = 0, vol = 0 } asked[ent] = a end
		a.n = a.n + 1
		a.vol = a.vol + (vol or 0)
		return orig(ent, x, y, z, nx, ny, nz, vol)
	end
end

-- What a body is to the renderer (a line "lookbody <name>"): its model, the materials it is drawn
-- with, and how many spots were asked to be put on it since lookwatch.
function H.lookbody(t)
	local e = t.ent
	if not IsValid(e) then Log("lookbody " .. tostring(t.name) .. " | no entity") return end
	local mats = {}
	for i, name in ipairs(e:GetMaterials() or {}) do
		local sub = e:GetSubMaterial(i - 1)
		mats[i] = string.format("[%d] %s%s", i - 1, name, sub ~= "" and (" -> " .. sub) or "")
	end
	local a = asked[e]
	Log(string.format("lookbody %s | %s %s model %s | spots asked for %d (%.2f ml) | %s",
		tostring(t.name), tostring(e), e:GetClass(), tostring(e:GetModel()), a and a.n or 0, a and a.vol or 0, table.concat(mats, " ; ")))
end

-- All of the engine's decals off a body (what is still seen on it then is no decal).
function H.lookdecals(t)
	if IsValid(t.ent) then t.ent:RemoveAllDecals() end
end

-- Stains with a known direction through ABL.Stains.Place, on the map (no t.ent) or on a thing:
-- t.stamps = { { pos, n, d, fam, idx, w, h }, ... }. t.modelV: which way a model's decal picture
-- is taken to run (ABL.Stains.MODEL_V) for these; t.wipe: the thing's decals off first.
function H.lookstamp(t)
	local S = ABL.Stains
	if t.modelV then S.MODEL_V = t.modelV end
	if t.wipe and IsValid(t.ent) then t.ent:RemoveAllDecals() end
	local placed = 0
	for _, s in ipairs(t.stamps or {}) do
		if S.Place(s.fam or "elong", s.idx or 1, s.pos.x, s.pos.y, s.pos.z, s.n.x, s.n.y, s.n.z, s.d.x, s.d.y, s.d.z, s.w or 9, s.h or 9,
			ABL.Config.Colors.decal, 255, IsValid(t.ent) and t.ent or nil, 0) then placed = placed + 1 end
	end
	Log(string.format("lookstamp %s | %d of %d placed on %s, a model's picture taken to run %s", tostring(t.name), placed, #(t.stamps or {}), tostring(t.ent or "the map"), tostring(S.MODEL_V)))
end

-- The highlight of the key light on the stains' liquid, set while the game runs (for pictures of
-- the same stains under several settings): t.exp, t.boost of the lit material; t.glossMin,
-- t.glossFull, t.crownTan of ABL.Config.Ground (those are in the meshes: built again after
-- abl_ground_debug has been 4 and 0).
function H.lookgloss(t)
	local GC = ABL.Config.Ground
	local m = ABL.Mat.groundPhong
	if t.exp then m:SetFloat("$phongexponent", t.exp) end
	if t.boost then m:SetFloat("$phongboost", t.boost) end
	for _, k in ipairs({ "glossMin", "glossFull", "crownTan" }) do
		if t[k] then GC[k] = t[k] end
	end
	m:Recompute()
	-- (what the engine says of the sun's disc in this view, and what the stains would take from it)
	local info = util.GetSunInfo and util.GetSunInfo()
	local sx = ABL.Render.Sun()
	local dx = ABL.Render.SunDir and ABL.Render.SunDir()
	Log(string.format("lookgloss %s | exponent %s boost %s | no highlight below %s units, all of the top from %s, a top leans %s | the sun's disc: obstruction %s; Render.Sun gives %s, Render.SunDir %s",
		tostring(t.name), tostring(m:GetFloat("$phongexponent")), tostring(m:GetFloat("$phongboost")), tostring(GC.glossMin), tostring(GC.glossFull), tostring(GC.crownTan),
		info and tostring(info.obstruction) or "no sun", sx and "a sun" or "none", dx and "a sun" or (ABL.Render.SunDir and "none" or "not there")))
end

-- Does a decal of the engine show on the map's own surfaces? Five marks in a row at t.pos (a
-- floor), 30 units apart along t.dir: 1 the engine's own decal by name, 2 one of ours through
-- util.DecalEx, 3 a turned variant of it, 4 through ABL.Stains.Place without an overlay, 5 with.
function H.lookprobe(t)
	local S, M = ABL.Stains, ABL.Mat
	local up = Vector(0, 0, 1)
	local function At(i) return t.pos + t.dir * ((i - 3) * 30) end
	local world = game.GetWorld()
	local white = Color(255, 255, 255, 255)
	util.Decal("Scorch", At(1) + up * 8, At(1) - up * 8)
	util.DecalEx(Material("advancedblood/decals/splat1"), world, At(2) + up, up, white, 12, 12)
	util.DecalEx(M.Decal("splat", 1, 4), world, At(3) + up, up, white, 12, 12)
	local p = At(4)
	local ok4 = S.Place("splat", 1, p.x, p.y, p.z, 0, 0, 1, nil, nil, nil, 12, 12, ABL.Config.Colors.decal, 255, nil, 0)
	p = At(5)
	local ok5 = S.Place("splat", 1, p.x, p.y, p.z, 0, 0, 1, nil, nil, nil, 12, 12, ABL.Config.Colors.decal, 255, nil, 30)
	local function CV(n) local c = GetConVar(n) return c and c:GetString() or "?" end
	Log(string.format("lookprobe %s | Stains.Place without an overlay %s, with one %s | r_decals %s mp_decals %s r_drawdecals %s r_drawmodeldecals %s | world %s",
		tostring(t.name), tostring(ok4), tostring(ok5), CV("r_decals"), CV("mp_decals"), CV("r_drawdecals"), CV("r_drawmodeldecals"), tostring(world)))
end

-- Why does a decal of ours not show on the map? Seven marks in a row at t.pos, 26 units apart along
-- t.dir, each one thing different from the way ABL.Stains.Place lays a decal on the map:
--   1 as Place does it (our material, 12 times its own size of one unit, a unit above the floor)
--   2 a material whose own size is 12 units, laid at once its size
--   3 as 1 without "$vertexcolor" / "$vertexalpha"
--   4 as 1, the normal pointing into the floor
--   5 as 1, at the floor itself (not a unit above it)
--   6 as 2 with shader DecalModulate
--   7 as 1 at 48 times its size
function H.lookprobe2(t)
	local up = Vector(0, 0, 1)
	local function At(i) return t.pos + t.dir * ((i - 4) * 26) end
	local world = game.GetWorld()
	local white = Color(255, 255, 255, 255)
	local tex = "advancedblood/decals/splat1"
	local serial = math.floor(RealTime() * 1000)
	local function Mat(name, shader, scale, plain)
		local kv = { ["$basetexture"] = tex, ["$decal"] = 1, ["$decalscale"] = scale, ["$translucent"] = 1 }
		if not plain then kv["$vertexcolor"] = 1 kv["$vertexalpha"] = 1 end
		return CreateMaterial("abl_lp_" .. name .. serial, shader, kv)
	end
	util.DecalEx(Material(tex), world, At(1) + up, up, white, 12, 12)
	util.DecalEx(Mat("big", "LightmappedGeneric", 12 / 512), world, At(2) + up, up, white, 1, 1)
	util.DecalEx(Mat("plain", "LightmappedGeneric", 1 / 512, true), world, At(3) + up, up, white, 12, 12)
	util.DecalEx(Material(tex), world, At(4) + up, -up, white, 12, 12)
	util.DecalEx(Material(tex), world, At(5), up, white, 12, 12)
	util.DecalEx(Mat("mod", "DecalModulate", 12 / 512, true), world, At(6) + up, up, white, 1, 1)
	util.DecalEx(Material(tex), world, At(7) + up, up, white, 48, 48)
	local m = Material(tex)
	local function CV(n) local c = GetConVar(n) return c and c:GetString() or "?" end
	Log(string.format("lookprobe2 %s | our material: shader %s, error %s, base %s %dx%d, $decalscale %s | r_decal_cullsize %s r_decals %s",
		tostring(t.name), m:GetShader(), tostring(m:IsError()), tostring(m:GetTexture("$basetexture") and m:GetTexture("$basetexture"):GetName()), m:Width(), m:Height(),
		tostring(m:GetFloat("$decalscale")), CV("r_decal_cullsize"), CV("r_decals")))
end
