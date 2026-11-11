-- Z-City compatibility, server side. (The client side is client/cl_compat.lua; every Z-City lookup
-- goes through sh_zcity.lua; the whole of it is described in docs/ZCITY_INTEGRATION.md.)
--
-- Nothing in this file touches Z-City's physiology: damage, the organism, wounds, blood volume,
-- clotting, pain and death run as Z-City runs them. What it deals with is the blood Z-City's
-- server code puts on the world by itself, next to the blood AdvancedBlood shows for the same
-- injury:
--
--   1. hook PostEntityTakeDamage / "ResponsiveHits_PostEntityTakeDamage" (homigrad/sv_util.lua):
--      an engine blood decal behind and another below every bullet hit;
--   2. util.Decal with a blood decal name: a cut or a claw (on the victim and on what stands behind
--      it), the meat of a burst head wherever it lands, a breach charge on every body around it,
--      the flesh splat Z-City's own bullets stamp where they hit;
--   3. util.Effect with a blood effect name: the engine's red puff at a bullet hit on the brain.
--
-- 2 and 3 have no hook to go through: the calls sit in weapon methods, physics callbacks and
-- timers. They are caught where all of them end, in util.Decal and util.Effect, by name
-- (ABL.Config.ZCity). Only those names, only on a server that runs Z-City, only while abl_enabled
-- is 1 and abl_zcity_hitdecals is 0; every other call goes to the original function as it came.
-- Z-City's own decal names are its blood wherever they are asked for. The engine's names ("Blood",
-- "Impact.Flesh", the "BloodImpact" puff) are anybody's: those are left out only where a body
-- with a Z-City organism is close by, a body ABL bleeds for. Blood on something Z-City runs no
-- organism for is not ABL's to replace and stays as it is.
-- A Z-City file that keeps its own reference to one of the two (local Effect = util.Effect, as its
-- helicopter rotor does) is not reached.

local C, N, Z = ABL.Config, ABL.Net, ABL.ZC

ABL.CompatSV = ABL.CompatSV or {}
local SV = ABL.CompatSV
SV.stat = SV.stat or { hits = 0, decals = 0, effects = 0, names = {} }
local stat = SV.stat

local function Suppressing()
	return ABL.Enabled() and not C.sv.hitDecals:GetBool() and Z.Present()
end
SV.Suppressing = Suppressing

local function Count(kind, name)
	stat[kind] = stat[kind] + 1
	stat.names[name] = (stat.names[name] or 0) + 1
end

------------------------------------------------------------------------------------------
-- 1. Z-City's canned hit decals: on every bullet hit it stamps an engine blood decal on whatever
-- lies 25 to 200 units behind the victim and another on the floor under that point, whatever the
-- bullet did. With ABL the blood that leaves a body is thrown, flies and lands where it lands (and
-- none is thrown forward without an exit), so for bodies ABL bleeds for the pair is left out. The
-- original also switches the engine's own bleeding off for the body it is called for; that part
-- is kept.
------------------------------------------------------------------------------------------
local REWRAP_MAX = 8
SV.hookWraps = 0
local function WrapResponsiveHits()
	local set = hook.GetTable().PostEntityTakeDamage
	local orig = set and set["ResponsiveHits_PostEntityTakeDamage"]
	if not isfunction(orig) or ABL.wrapResponsiveHits == orig then return end
	-- (something that keeps putting its own function there is left alone after a few times:
	-- abl_zcity_status shows the hook as not wrapped then)
	if SV.hookWraps >= REWRAP_MAX then return end
	SV.hookWraps = SV.hookWraps + 1
	ABL.origResponsiveHits = orig
	local function wrapped(ent, dmg, ...)
		if C.sv.hitDecals:GetBool() or not ABL.Enabled() or not IsValid(ent) or not istable(ent.organism) then
			return orig(ent, dmg, ...)
		end
		if (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) and ent:GetBloodColor() ~= DONT_BLEED then
			ent.bloodColorHitFix = ent:GetBloodColor()
			ent:SetBloodColor(DONT_BLEED)
		end
		stat.hits = stat.hits + 1
	end
	ABL.wrapResponsiveHits = wrapped
	hook.Add("PostEntityTakeDamage", "ResponsiveHits_PostEntityTakeDamage", wrapped)
end

------------------------------------------------------------------------------------------
-- 2 and 3. Blood decals and blood effects by name.
------------------------------------------------------------------------------------------
-- 0 = not blood, 1 = one of Z-City's own blood decals, 2 = an engine blood decal
local isBlood = {}
local function BloodDecal(name)
	local v = isBlood[name]
	if v == nil then
		v = 0
		for _, pat in ipairs(C.ZCity.decals) do
			if string.find(name, pat) then v = 1 break end
		end
		if v == 0 then
			for _, pat in ipairs(C.ZCity.engineDecals) do
				if string.find(name, pat) then v = 2 break end
			end
		end
		isBlood[name] = v
	end
	return v
end

-- Is a body Z-City runs an organism for close to this point?
local function NearOrganism(pos)
	if not isvector(pos) then return false end
	for _, e in ipairs(ents.FindInSphere(pos, C.ZCity.nearBody)) do
		if istable(e.organism) then return true end
	end
	return false
end

-- (an effect of another blood colour, yellow or green, is not this blood)
local function Red(data)
	if data == nil then return true end
	local ok, col = pcall(function() return data:GetColor() end)
	return not ok or col == nil or col == 0
end

-- (lua refresh: the wrappers of the previous load come off first, if they are still on top)
if SV.wrapDecal and util.Decal == SV.wrapDecal then util.Decal = SV.origDecal end
if SV.wrapEffect and util.Effect == SV.wrapEffect then util.Effect = SV.origEffect end
SV.wrapDecal, SV.wrapEffect = nil, nil

local function WrapUtil()
	if SV.wrapDecal then return end
	local decal, effect = util.Decal, util.Effect
	if not isfunction(decal) or not isfunction(effect) then return end
	SV.origDecal, SV.origEffect = decal, effect
	SV.wrapDecal = function(name, from, ...)
		if isstring(name) then
			local kind = BloodDecal(name)
			if kind ~= 0 and Suppressing() and (kind == 1 or NearOrganism(from)) then
				Count("decals", name)
				return
			end
		end
		return decal(name, from, ...)
	end
	SV.wrapEffect = function(name, data, ...)
		if isstring(name) and C.ZCity.effects[name] and Suppressing() and Red(data) then
			local ok, at = pcall(function() return data:GetOrigin() end)
			if ok and NearOrganism(at) then
				Count("effects", name)
				return
			end
		end
		return effect(name, data, ...)
	end
	util.Decal, util.Effect = SV.wrapDecal, SV.wrapEffect
end

local function Install()
	if not Z.Present() then return false end
	WrapResponsiveHits()
	WrapUtil()
	if not SV.told then
		SV.told = true
		ABL.Print("Z-City found: its blood decals and blood puffs are %s", Suppressing() and "left to AdvancedBlood" or "kept (abl_zcity_hitdecals 1 or abl_enabled 0)")
	end
	return true
end
SV.Install = Install

hook.Add("InitPostEntity", "ABL_CompatSV", Install)
hook.Add("HomigradRun", "ABL_CompatSV", function() timer.Simple(0, Install) end)
timer.Simple(0, Install)
-- (Z-City loaded again puts its own hit-decal hook back: looked at now and then)
timer.Create("ABL_CompatSVWatch", 10, 0, function()
	if Z.Present() then WrapResponsiveHits() end
end)

------------------------------------------------------------------------------------------
-- A headless body's neck (sh_zcity.lua, Z.StumpWounds): the point Z-City keeps its fountain at,
-- put on the body itself so that it reaches every client together with the body.
------------------------------------------------------------------------------------------
timer.Create("ABL_CompatNeck", 0.5, 0, function()
	local all = Z.Fountains()
	if not all or not ABL.Enabled() then return end
	for rag, f in pairs(all) do
		if IsValid(rag) and not rag.ABL_neck and istable(f) then
			rag.ABL_neck = true
			rag:SetNW2Vector("ABL_Neck", isvector(f.lpos) and not f.lpos:IsZero() and f.lpos or Vector(4, 0, 0))
		end
	end
end)

------------------------------------------------------------------------------------------
-- abl_zcity_status: the server's part of the answer (asked for by the client command, at most
-- once a second per player).
------------------------------------------------------------------------------------------
net.Receive(N.ZCS, function(_, ply)
	if not IsValid(ply) then return end
	local now = CurTime()
	if (ply.ABL_zcsNext or 0) > now then return end
	ply.ABL_zcsNext = now + 1
	local set = hook.GetTable().PostEntityTakeDamage
	local rh = set and set["ResponsiveHits_PostEntityTakeDamage"]
	local orgs = 0
	for _, p in ipairs(player.GetAll()) do
		if istable(p.organism) then orgs = orgs + 1 end
	end
	local org = istable(ply.organism) and ply.organism or nil
	net.Start(N.ZCS)
	net.WriteBool(Z.Present())
	net.WriteBool(Suppressing())
	-- 0 = Z-City has no such hook, 1 = it is there and not wrapped, 2 = wrapped
	net.WriteUInt(not isfunction(rh) and 0 or (rh == ABL.wrapResponsiveHits and 2 or 1), 2)
	net.WriteBool(SV.wrapDecal ~= nil and util.Decal == SV.wrapDecal)
	net.WriteBool(SV.wrapEffect ~= nil and util.Effect == SV.wrapEffect)
	net.WriteUInt(math.min(stat.hits, 16777215), 24)
	net.WriteUInt(math.min(stat.decals, 16777215), 24)
	net.WriteUInt(math.min(stat.effects, 16777215), 24)
	net.WriteUInt(math.min(orgs, 255), 8)
	net.WriteBool(org ~= nil)
	if org then
		net.WriteFloat(tonumber(org.blood) or 0)
		net.WriteFloat(tonumber(org.bleed) or 0)
		net.WriteFloat(tonumber(org.pulse) or 0)
		net.WriteUInt(math.min(istable(org.wounds) and #org.wounds or 0, 255), 8)
		net.WriteUInt(math.min(istable(org.arterialwounds) and #org.arterialwounds or 0, 255), 8)
	end
	net.Send(ply)
end)
