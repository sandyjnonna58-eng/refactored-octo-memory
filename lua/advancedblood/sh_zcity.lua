-- Z-City integration adapter. Every Z-City specific lookup goes through here so the rest of the
-- addon works with plain entities, bone indices and numbers. See docs/ZCITY_INTEGRATION.md.

ABL.ZC = ABL.ZC or {}
local Z = ABL.ZC

-- Is Z-City's organism and blood code loaded here? Not asked of the gamemode's name: the code this
-- addon works with (lua/homigrad) also runs under other gamemodes, and a gamemode of that name
-- without it would be of no use. One sign is not relied on either: any of the three will do.
function Z.Present()
	return istable(hg) and (isfunction(hg.GetCurrentCharacter) or istable(hg.organism) or isfunction(hg.addBloodPart))
end

-- The signs looked at, for abl_zcity_status: { name, found }.
function Z.Signals()
	local h = istable(hg)
	local out = {
		{ "hg", h },
		{ "hg.GetCurrentCharacter", h and isfunction(hg.GetCurrentCharacter) },
		{ "hg.organism", h and istable(hg.organism) },
		{ "zb", istable(zb) },
	}
	if CLIENT then
		local set = hook.GetTable()["Player-Ragdoll think"]
		out[#out + 1] = { "hg.addBloodPart", h and isfunction(hg.addBloodPart) }
		out[#out + 1] = { "particle-lists", h and istable(hg.bloodparticles1) }
		out[#out + 1] = { "wound-think", set ~= nil and isfunction(set["organism-think-client-blood"]) }
	else
		local set = hook.GetTable().PostEntityTakeDamage
		out[#out + 1] = { "hg.organism.AddWound", h and istable(hg.organism) and isfunction(hg.organism.AddWound) }
		out[#out + 1] = { "hit-decal-hook", set ~= nil and isfunction(set["ResponsiveHits_PostEntityTakeDamage"]) }
	end
	return out
end

-- Entity that currently represents the character physically (ragdoll while faked, else player).
function Z.GetBody(ply)
	if not IsValid(ply) then return nil end
	if not ply:IsPlayer() then return ply end
	local c
	if istable(hg) and isfunction(hg.GetCurrentCharacter) then
		c = hg.GetCurrentCharacter(ply)
		if IsValid(c) and c ~= ply then return c end
	end
	-- The networked link is authoritative. Z-City's client-side ply.FakeRagdoll can be missing (a
	-- player ragdolled right after joining), and then GetCurrentCharacter returns the hidden player.
	-- While faked the player itself is not rendered; checking that ignores a stale link during the
	-- second in which Z-City removes the ragdoll after getting up.
	local rag = ply:GetNWEntity("FakeRagdoll")
	if IsValid(rag) and rag:IsRagdoll() and (not IsValid(c) or ply:GetRenderMode() == RENDERMODE_NONE or ply:GetNoDraw()) then
		return rag
	end
	if IsValid(c) then return c end
	return ply
end

-- Living player that owns a fake ragdoll, or nil for corpses / props.
function Z.GetOwner(rag)
	if not IsValid(rag) then return nil end
	if rag:IsPlayer() then return rag end
	local ply = rag:GetNWEntity("ply")
	if not (IsValid(ply) and ply:IsPlayer()) then return nil end
	local link = ply:GetNWEntity("FakeRagdoll")
	if link == rag then return ply end
	-- the player's side of the link can arrive later than the ragdoll's (a player ragdolled right
	-- after joining): a living, hidden player whose link is not set yet owns it too
	if not IsValid(link) and ply:Alive() and ply:GetRenderMode() == RENDERMODE_NONE and not IsValid(ply:GetNWEntity("RagdollDeath")) then
		return ply
	end
	return nil
end

function Z.GetCorpse(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return nil end
	local rag = ply:GetNWEntity("RagdollDeath")
	if IsValid(rag) then return rag end
	return nil
end

-- Raw Z-City wound lists (venous, arterial). Either may be nil.
function Z.GetWoundLists(ent)
	if not IsValid(ent) or not ent.GetNetVar then return nil, nil end
	local w, a = ent:GetNetVar("wounds"), ent:GetNetVar("arterialwounds")
	if not istable(w) then w = nil end
	if not istable(a) then a = nil end
	return w, a
end

-- A headless body. Z-City keeps a "fountain" for it (hg.fountains on the server, the global netvar
-- "fountains" for clients: the neck bone and a point in its space) and drips its particles from
-- there for as long as the body lies; it stores no wound for it, so ABL would show nothing at the
-- neck. The same state is handed to ABL as one arterial wound at that point, in the layout of
-- Z-City's own wound lists: it bleeds like any other, with the pulse while there is one and
-- running dry after. The netvar is keyed by entity and often reaches a client before the body
-- does (a head that comes off as its owner dies: the key is then no entity at all, for Z-City's
-- own fountain as well), so the server puts the point on the body itself (server/sv_compat.lua).
if SERVER then
	-- Bodies Z-City has a fountain for: { [ragdoll] = { bone, lpos, lang } }, or nil.
	function Z.Fountains()
		local all = istable(hg) and hg.fountains or nil
		return istable(all) and all or nil
	end
end

-- Returns a list of one wound, or nil.
local stumps = setmetatable({}, { __mode = "k" })
function Z.StumpWounds(ent)
	if not IsValid(ent) or not ent:IsRagdoll() then return nil end
	local lpos = ent:GetNW2Vector("ABL_Neck", vector_origin)
	if lpos:IsZero() then return nil end
	local list = stumps[ent]
	if not list then
		-- (Z-City stores the direction blood is driven against: the stump bleeds along the neck)
		list = { { ABL.Config.ZCity.stumpSize, Vector(lpos), angle_zero, "ValveBiped.Bip01_Neck1", CurTime(), Vector(-100, 0, 0), "abl_neck_stump" } }
		stumps[ent] = list
	end
	return list
end

function Z.GetOrganism(ent, owner)
	if IsValid(ent) and istable(ent.organism) then return ent.organism end
	if IsValid(owner) and istable(owner.organism) then return owner.organism end
	return nil
end

-- Returns pulse (bpm) and whether the organism is alive.
function Z.Vitals(ent, owner)
	local org = Z.GetOrganism(ent, owner)
	local alive
	if IsValid(owner) and owner:IsPlayer() then
		alive = owner:Alive() and (not org or org.alive ~= false)
	else
		alive = org ~= nil and org.alive == true
	end
	local pulse = org and tonumber(org.pulse) or (alive and 75 or 0)
	if not alive then pulse = 0 end
	local blood = org and tonumber(org.blood) or 5000
	return pulse, alive, blood, org
end

------------------------------------------------------------------------------------------
-- Amputation / hidden limbs: blood must never flow on a limb that is not rendered.
------------------------------------------------------------------------------------------
local limbOfBone = {}
local limbPatterns = {
	{ "L_Calf", "lleg" }, { "L_Foot", "lleg" }, { "L_Toe", "lleg" },
	{ "R_Calf", "rleg" }, { "R_Foot", "rleg" }, { "R_Toe", "rleg" },
	{ "L_Forearm", "larm" }, { "L_Hand", "larm" }, { "L_Finger", "larm" },
	{ "R_Forearm", "rarm" }, { "R_Hand", "rarm" }, { "R_Finger", "rarm" },
	{ "Head1", "head" },
}

function Z.BoneLimb(boneName)
	local v = limbOfBone[boneName]
	if v ~= nil then return v or nil end
	v = false
	for _, p in ipairs(limbPatterns) do
		if string.find(boneName, p[1], 1, true) then v = p[2] break end
	end
	limbOfBone[boneName] = v
	return v or nil
end

function Z.LimbMissing(ent, org, boneName)
	if not boneName then return false end
	local limb = Z.BoneLimb(boneName)
	if not limb then return false end
	if org and org[limb .. "amputated"] then return true end
	if limb == "head" and IsValid(ent) and ent.headexploded then return true end
	return false
end

if CLIENT then
	-- Bones scaled to ~0 by any gore system are treated as missing.
	function Z.BoneHidden(ent, bone)
		local s = ent:GetManipulateBoneScale(bone)
		return s and (s.x * s.x + s.y * s.y + s.z * s.z) < 0.03
	end
end
