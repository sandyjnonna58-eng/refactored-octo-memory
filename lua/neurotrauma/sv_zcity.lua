-- Z-City adapter (server). Every read and write of Z-City state goes through this file, so the rest
-- of the module works with plain entities, vectors and numbers, and a change inside Z-City breaks one
-- place only. Nothing of Z-City is copied or edited: its functions are called, its fields are read.
-- Each feature is checked once; a missing one switches off what depends on it instead of erroring.

local NT = NeuroTrauma
NT.ZC = NT.ZC or {}
local Z = NT.ZC
local C = NT.Config

Z.has = Z.has or {}
local has = Z.has
local checked = false

function Z.Check()
	local h = istable(hg)
	has.present   = h and istable(hg.organism)
	has.character = h and isfunction(hg.GetCurrentCharacter)
	has.owner     = h and isfunction(hg.RagdollOwner)
	has.fake      = h and isfunction(hg.Fake) and isfunction(hg.FakeUp)
	has.physnum   = h and isfunction(hg.realPhysNum)
	has.stun      = h and isfunction(hg.LightStunPlayer)
	has.ammo      = h and istable(hg.ammotypeshuy)
	has.armor     = h and istable(hg.armor) and istable(hg.armor.head)
	if not checked and has.present then
		checked = true
		local missing = {}
		for _, k in ipairs({ "character", "owner", "fake", "physnum", "stun", "ammo", "armor" }) do
			if not has[k] then missing[#missing + 1] = k end
		end
		NT.Print("Z-City found%s", #missing > 0 and (" (not available: " .. table.concat(missing, ", ") .. ")") or "")
	end
	return has.present
end

function Z.Present()
	if has.present then return true end
	return Z.Check()
end

hook.Add("InitPostEntity", "NT_ZCityCheck", function() Z.Check() end)
hook.Add("HomigradRun", "NT_ZCityCheck", function() timer.Simple(0, Z.Check) end)

function NT.Enabled()
	return C.sv.enabled:GetBool() and Z.Present()
end

------------------------------------------------------------------------------------------
-- Characters
------------------------------------------------------------------------------------------
-- Living player that a fake ragdoll belongs to (nil for corpses and props).
function Z.Owner(rag)
	if not IsValid(rag) then return nil end
	if rag:IsPlayer() then return rag end
	local ply = has.owner and hg.RagdollOwner(rag) or nil
	if IsValid(ply) and ply:IsPlayer() and ply:Alive() then return ply end
	return nil
end

-- Entity that represents the character physically (the ragdoll while faked, else the player).
function Z.Body(ply)
	if not IsValid(ply) then return nil end
	if not ply:IsPlayer() or not has.character then return ply end
	local c = hg.GetCurrentCharacter(ply)
	return IsValid(c) and c or ply
end

function Z.IsRagdolled(ply)
	return IsValid(ply) and ply:IsPlayer() and IsValid(ply.FakeRagdoll)
end

-- Organism of a player or of a living player's ragdoll.
function Z.Org(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return istable(ent.organism) and ent.organism or nil end
	local owner = Z.Owner(ent)
	if owner then return istable(owner.organism) and owner.organism or nil end
	return nil
end

-- Z-City's consciousness (1 = awake) as it stands now.
function Z.Consciousness(org)
	if org.otrub then return 0 end
	return math.Clamp(tonumber(org.consciousness) or 1, 0, 1)
end

------------------------------------------------------------------------------------------
-- What the module writes. Z-City decides who stands, who lies and who dies from these two fields
-- (its thresholds: consciousness < 0.4 ragdolls, < 0.1 unconscious; brain >= 0.05 sway and falls,
-- >= 0.3 unconscious, >= 0.6 arrest and no breathing, >= 0.7 death). The module only pushes them
-- the way an injury would: consciousness down to a ceiling, brain damage up to a floor. It never
-- writes needotrub / needfake (zeroed at the start of Z-City's own tick) and never raises
-- consciousness or lowers brain damage: recovery is Z-City's.
------------------------------------------------------------------------------------------
function Z.CapConsciousness(org, cap)
	local c = tonumber(org.consciousness)
	if c and c > cap then org.consciousness = cap end
	-- Z-City runs an achievement check at the moment a player goes unconscious that compares a
	-- timer it only sets on a head hit in the same session; for a player who carries that
	-- achievement's state over from an earlier session the timer is missing, the check errors, and
	-- Z-City's whole tick stops before it makes the player unconscious, every time. An expired
	-- timer is what the missing one means.
	if cap < 0.1 then
		local owner = org.owner
		if IsValid(owner) and owner:IsPlayer() and owner.illbeback == nil then owner.illbeback = 0 end
	end
end

function Z.FloorBrain(org, floor)
	local b = tonumber(org.brain)
	if b and b < floor then org.brain = floor end
end

function Z.Brain(org) return tonumber(org.brain) or 0 end
function Z.HeartStopped(org) return org.heartstop == true end

------------------------------------------------------------------------------------------
-- The head
------------------------------------------------------------------------------------------
local HEAD_BONE = "ValveBiped.Bip01_Head1"

-- Physics object of a ragdoll's head (cached on the ragdoll; false when it has none).
function Z.HeadPhys(rag)
	local idx = rag.NT_headPhys
	if idx == nil then
		idx = false
		if has.physnum then
			local n = hg.realPhysNum(rag, 10)
			if n and IsValid(rag:GetPhysicsObjectNum(n)) then idx = n end
		end
		if not idx then
			local b = rag:LookupBone(HEAD_BONE)
			local n = b and rag:TranslateBoneToPhysBone(b)
			if n and n >= 0 and IsValid(rag:GetPhysicsObjectNum(n)) then idx = n end
		end
		rag.NT_headPhys = idx
	end
	if not idx then return nil end
	local phys = rag:GetPhysicsObjectNum(idx)
	return IsValid(phys) and phys or nil
end

-- Which way the head bone's third axis points differs between skeletons: found once per model from
-- the collar bones. 1 = the bone's up axis points to the character's left.
local lateralSign = {}
local function LateralSign(ent, ang)
	local mdl = ent:GetModel() or ""
	local s = lateralSign[mdl]
	if s then return s end
	s = 1
	local l, r = ent:LookupBone("ValveBiped.Bip01_L_Clavicle"), ent:LookupBone("ValveBiped.Bip01_R_Clavicle")
	if l and r then
		local pl, pr = ent:GetBonePosition(l), ent:GetBonePosition(r)
		if pl and pr and pl ~= pr then
			s = (pl - pr):Dot(ang:Up()) >= 0 and 1 or -1
			lateralSign[mdl] = s
		end
	end
	return s
end

-- Head frame in the world: centre of the skull and three unit vectors (toward the crown, toward the
-- face, toward the character's left). The ValveBiped head bone runs up the neck (its first axis),
-- the face is on the negative side of its second axis (Z-City's own skull, jaw and mask boxes sit
-- there). Returns nil when the entity has no head bone.
function Z.HeadFrame(ent)
	local b = ent:LookupBone(HEAD_BONE)
	if not b then return nil end
	local pos, ang = ent:GetBonePosition(b)
	if not pos or not ang then return nil end
	local up, face = ang:Forward(), ang:Right()
	local left = ang:Up() * LateralSign(ent, ang)
	return pos + up * 4.2 + face * 0.8, up, face, left
end

------------------------------------------------------------------------------------------
-- Protection and projectiles
------------------------------------------------------------------------------------------
-- How much of a contact load a helmet takes (0 = none). Z-City rates helmets ballistically
-- (2.4 .. 16); any shell spreads a blow, a better one more. The mapping is ours [G].
function Z.HeadShield(ply)
	if not has.armor or not IsValid(ply) then return 0 end
	local armors = ply.armors
	local name = istable(armors) and armors["head"]
	local def = name and hg.armor.head[name]
	if not istable(def) then return 0 end
	return math.Clamp(0.3 + 0.03 * (tonumber(def.protection) or 0), 0, 0.75)
end

-- The projectile of a bullet hit as Z-City describes it: speed (m/s), mass (g), diameter (mm),
-- whether it is one pellet of a shot load, whether it came through something first, where it was
-- fired from and which way. Any may be nil.
function Z.Projectile(dmgInfo)
	local inf = dmgInfo:GetInflictor()
	local b = IsValid(inf) and istable(inf.bullet) and inf.bullet or nil
	if not b then return nil end
	local speed, diam, mass, pellet = tonumber(b.Speed), tonumber(b.Diameter), nil, false
	local at = has.ammo and b.AmmoType and hg.ammotypeshuy[b.AmmoType]
	local bs = istable(at) and at.BulletSettings
	if istable(bs) then
		mass = tonumber(bs.Mass)
		speed = speed or tonumber(bs.Speed)
		diam = diam or tonumber(bs.Diameter)
		pellet = (tonumber(bs.NumBullet) or 1) > 1
	end
	local dir = isvector(b.Dir) and b.Dir:LengthSqr() > 0.01 and b.Dir:GetNormalized() or nil
	return speed, mass, diam, pellet, (tonumber(b.penetrated) or 0) > 0, isvector(b.Src) and b.Src or nil, dir
end

-- Stiffness class (0..1) of an engine surface property.
local surfCache = {}
function Z.SurfaceStiffness(id)
	if not id then return C.SurfaceDefault, "?" end
	local c = surfCache[id]
	if c then return c[1], c[2] end
	local name = string.lower(util.GetSurfacePropName(id) or "")
	local v = C.SurfaceDefault
	for _, e in ipairs(C.Surface) do
		if string.find(name, e[1], 1, true) then v = e[2] break end
	end
	surfCache[id] = { v, name }
	return v, name
end

------------------------------------------------------------------------------------------
-- Other levers
------------------------------------------------------------------------------------------
-- A short loss of balance: Z-City drops the character into its ragdoll for a moment.
function Z.Stumble(ply, seconds)
	if has.stun and IsValid(ply) and ply:Alive() and not IsValid(ply.FakeRagdoll) then
		hg.LightStunPlayer(ply, seconds)
		return true
	end
	return false
end

-- What the owner sees (Z-City blurs and sways the view from 3 up, and caps it at 10).
function Z.Disorient(org, amount)
	local d = tonumber(org.disorientation)
	if d and d < amount then org.disorientation = math.min(amount, 10) end
end

------------------------------------------------------------------------------------------
-- Takeover (neuro_zcity_takeover, default 1). Z-City throws a "fencing" spasm on one skull hit in
-- three and a rigor spasm on a share of deaths by head injury, both by chance alone. With the
-- switch on, the model decides whether and how a living body postures (sv_motor.lua) and Z-City's
-- fencing spasm stays quiet; with it off it runs exactly as shipped and the model's own impact
-- posturing is not shown, so the two never act on one body together.
-- The spasm of the dead is Z-City's response to a death, and a death is not the model's to
-- show: it is left to run, with one exception. A character the model has just shown dying
-- without circulation lay limp and still (sv_cardioresp.lua); that body does not stiffen at the
-- moment Z-City books the death. (Until phase 22 the takeover silenced the spasm for every death
-- and put nothing in its place: a character killed outright simply dropped.)
-- neuro_zcity_deathspasm 0 holds it back for every death, as before.
-- Wrapped, not edited; the originals are kept.
------------------------------------------------------------------------------------------
Z.wrapped = Z.wrapped or false

function Z.Takeover()
	return C.sv.takeover:GetBool() and C.sv.enabled:GetBool()
end

local function Wrap()
	if Z.wrapped or not istable(hg) or not isfunction(hg.applyFencingToPlayer) then return Z.wrapped end
	Z.origFencing = hg.applyFencingToPlayer
	hg.applyFencingToPlayer = function(ply, org, ...)
		if Z.Takeover() then return end
		return Z.origFencing(ply, org, ...)
	end
	local ht = hook.GetTable()["RagdollDeath"]
	local death = ht and ht["BrainfuckStart"]
	if isfunction(death) then
		Z.origDeathSpasm = death
		hook.Add("RagdollDeath", "BrainfuckStart", function(ply, rag, ...)
			if Z.Takeover() and IsValid(ply) and (not C.sv.deathSpasm:GetBool() or (ply.NT_arrestSeen or 0) > CurTime() - 2) then
				Z.spasmHeld = (Z.spasmHeld or 0) + 1
				return
			end
			Z.spasmPassed = (Z.spasmPassed or 0) + 1
			return Z.origDeathSpasm(ply, rag, ...)
		end)
	end
	Z.wrapped = true
	has.takeover = true
	return true
end

hook.Add("InitPostEntity", "NT_ZCityWrap", function()
	if Wrap() then return end
	timer.Create("NT_ZCityWrapRetry", 1, 30, function()
		if Wrap() then timer.Remove("NT_ZCityWrapRetry") end
	end)
end)
hook.Add("HomigradRun", "NT_ZCityWrap", function() timer.Simple(0, Wrap) end)
