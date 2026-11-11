-- Server authority: publishes world gravity, turns Z-City wound creation into compact abl_hit
-- events, and turns bloody ragdoll collisions into throttled abl_rcol events.
-- Nothing per-droplet is ever networked; clients rebuild all visuals from these events plus
-- Z-City's own replicated wound netvars.

local C, N, Z = ABL.Config, ABL.Net, ABL.ZC

------------------------------------------------------------------------------------------
-- Gravity
------------------------------------------------------------------------------------------
local lastGrav
local function PublishGravity()
	local g = physenv.GetGravity()
	if not lastGrav or g:DistToSqr(lastGrav) > 0.01 then
		lastGrav = g
		SetGlobal2Vector("abl_grav", g)
	end
end
timer.Create("ABL_PublishGravity", 2, 0, PublishGravity)
hook.Add("InitPostEntity", "ABL_PublishGravity", PublishGravity)
PublishGravity()

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------
local function DamageClass(dtype)
	if bit.band(dtype, DMG_BUCKSHOT) ~= 0 then return N.DMG_BUCKSHOT end
	if bit.band(dtype, DMG_BULLET) ~= 0 then return N.DMG_BULLET end
	if bit.band(dtype, DMG_SLASH) ~= 0 then return N.DMG_SLASH end
	if bit.band(dtype, DMG_BLAST) ~= 0 then return N.DMG_BLAST end
	if bit.band(dtype, bit.bor(DMG_CLUB, DMG_GENERIC)) ~= 0 then return N.DMG_CLUB end
	return N.DMG_OTHER
end

-- Bone of `ent` whose hitbox is closest to world position `pos`.
local function NearestHitboxBone(ent, pos)
	local set = ent:GetHitboxSet() or 0
	local count = ent:GetHitBoxCount(set) or 0
	local best, bestD = nil, math.huge
	for hb = 0, count - 1 do
		local bone = ent:GetHitBoxBone(hb, set)
		if bone then
			local m = ent:GetBoneMatrix(bone)
			if m then
				local mins, maxs = ent:GetHitBoxBounds(hb, set)
				local lp = WorldToLocal(pos, angle_zero, m:GetTranslation(), m:GetAngles())
				-- distance from local point to the box
				local dx = math.max(mins.x - lp.x, 0, lp.x - maxs.x)
				local dy = math.max(mins.y - lp.y, 0, lp.y - maxs.y)
				local dz = math.max(mins.z - lp.z, 0, lp.z - maxs.z)
				local d = dx * dx + dy * dy + dz * dz
				if d < bestD then best, bestD = bone, d end
			end
		end
	end
	return best
end

local function ToBoneLocal(ent, bone, pos)
	local m = ent:GetBoneMatrix(bone)
	if not m then return nil end
	return (WorldToLocal(pos, angle_zero, m:GetTranslation(), m:GetAngles()))
end

------------------------------------------------------------------------------------------
-- Wound events
-- Z-City walks every bullet through its organ boxes (hg.organism.Trace) inside one
-- EntityTakeDamage call and fires, in this order:
--   PreHomigradDamage                 before the trace (players and fake ragdolls)
--   PreTraceOrganBulletDamage         once per organ / bone / artery / armour box the bullet enters
--   PreHomigradDamageBulletBleedAdd   with the entry / exit holes and the bleed amount
-- ABL notes the boxes during the trace and builds the wound event (sh_wound.lua) at the last hook:
-- what the projectile was, from how far it was fired, what it crossed and whether it left the body.
------------------------------------------------------------------------------------------
local WD = ABL.Wound
local band, bor = bit.band, bit.bor
local trails = setmetatable({}, { __mode = "k" })   -- organism -> boxes crossed by the bullet in flight
local hitEnts = setmetatable({}, { __mode = "k" })  -- organism -> the entity Z-City is damaging

hook.Add("PreHomigradDamage", "ABL_WoundTrail", function(ply, dmgInfo, hitgroup, ent)
	local org = IsValid(ent) and ent.organism
	if org then
		trails[org] = nil
		hitEnts[org] = ent
	end
end)

hook.Add("PreTraceOrganBulletDamage", "ABL_WoundTrail", function(org, bone, dmg, dmgInfo, box, dir, hit, ricochet, organ)
	if not istable(org) or not istable(organ) then return end
	local now = SysTime()
	local tr = trails[org]
	-- (the whole damage call is synchronous: anything older belongs to an earlier bullet)
	if not tr or now - tr.rt > 0.05 then
		tr = { tissue = 0, flags = 0, armorFirst = false, rt = now }
		trails[org] = tr
	end
	local f, armor = WD.OrganFlags(organ[1])
	if armor then
		if tr.tissue == 0 then tr.armorFirst = true end
	else
		tr.tissue = tr.tissue + 1
		tr.flags = bor(tr.flags, f)
	end
end)

local CLASS_NAMES = { [0] = "bullet", "buckshot", "slash", "club", "blast", "other" }

-- Where Z-City is about to store this hit's wound records (hg.organism.AddWound): in the space of
-- the bone it names, on the entity it damages, as that bone stands at the moment of the hit. ABL
-- sends the same coordinates. They name the same spot of the body whatever happens to it in between
-- (a player who drops into a ragdoll, or dies, in the tick of the hit), and they let the client tell
-- which of Z-City's wounds belong to this hit.
local function WoundSpace(ent, physBone, entry, exit)
	if not IsValid(ent) or not isnumber(physBone) or physBone < 0 then return nil end
	local bone = ent:TranslatePhysBoneToBone(physBone)
	if not bone or bone < 0 or bone > 255 then return nil end
	local pos, ang = ent:GetBonePosition(bone)
	if not pos or not ang then return nil end
	local le = WorldToLocal(entry, angle_zero, pos, ang)
	local lx = exit and WorldToLocal(exit, angle_zero, pos, ang) or nil
	return bone, le, lx
end

local function SendHit(body, rec)
	if not IsValid(body) then return end
	if body:IsPlayer() and not body:Alive() then return end
	local entry = rec.entry
	local bone, lEntry, lExit = rec.bone, rec.lEntry, rec.lExit
	if not bone or not body:GetBoneMatrix(bone) then
		-- (no bone named by Z-City: the closest one, as the body stands now)
		bone = NearestHitboxBone(body, entry)
		if not bone or bone > 255 then return end
		lEntry = ToBoneLocal(body, bone, entry)
		lExit = rec.exit and ToBoneLocal(body, bone, rec.exit) or nil
	end
	if not lEntry then return end
	-- (numbers only on the wire: a damage or a place that is none makes no event)
	local dir = rec.dir
	if not (rec.damage == rec.damage and rec.bleed == rec.bleed and lEntry.x == lEntry.x and lEntry.y == lEntry.y and lEntry.z == lEntry.z
		and dir.x == dir.x and dir.y == dir.y and dir.z == dir.z) then return end

	-- (kept, for clients that do not have the body in sight now: sv_woundstore.lua)
	if ABL.WoundStore and C.sv.netReplay:GetBool() then ABL.WoundStore.Keep(body, bone, lEntry, lExit, rec) end

	local rf = RecipientFilter()
	rf:AddPVS(body:WorldSpaceCenter())
	rf:AddPVS(entry)
	if rf:GetCount() == 0 then return end

	-- reliable: the wound it describes stays on the body for minutes
	net.Start(N.HIT)
	N.WriteEnt(body)
	net.WriteUInt(bone, 8)
	N.WriteLocal(lEntry)
	net.WriteNormal(rec.dir)
	net.WriteUInt(rec.class, 3)
	net.WriteUInt(math.Clamp(math.Round(rec.damage), 0, 1023), 10)
	net.WriteUInt(math.Clamp(math.Round(rec.bleed * 4), 0, 1023), 10)
	net.WriteUInt(math.Clamp(tonumber(rec.hitgroup) or 0, 0, 15), 4)
	WD.Write(rec)
	-- Z-City stores two wounds for a shot whose trace left the body (or met no organ box): the second
	-- at the point given here, or at the entry when none is given
	net.WriteBool(rec.second and true or false)
	net.WriteBool(lExit ~= nil)
	if lExit then N.WriteLocal(lExit) end
	-- the same bullet striking the same character again (see below)
	net.WriteBool(rec.continued and true or false)
	-- whose body it is: a living player's (their fake ragdoll may be so new that the client cannot
	-- tell yet), or nobody's (a corpse)
	local own = rec.owner
	net.WriteUInt((IsValid(own) and own:IsPlayer() and own:Alive()) and math.min(own:EntIndex(), 255) or 0, 8)
	net.Send(rf)
end

-- A bullet that Z-City lets carry on through a body is fired again from where it left, ignoring
-- the entity it came out of. When that hit dropped the player into a ragdoll, or killed them, the
-- ragdoll is a new entity standing in the bullet's way: the same bullet strikes the same character
-- a second time, and Z-City books a second pair of wounds for it. For ABL that is no new wound: the
-- event is marked as the continuation of the first. Only where it strikes the same part of the
-- body again: a bullet that leaves one leg and enters the other has made a second wound.
local recent = {}
local function Continued(ply, ent, bone, hitgroup)
	if not IsValid(ent) or ent:IsPlayer() then return false end
	local linked = ent:GetNWEntity("ply")
	for i = 1, #recent do
		local p = recent[i]
		local pp = p.ply
		if p.ent ~= ent and IsValid(pp) and (pp == ply or pp == linked or Z.GetCorpse(pp) == ent or pp:GetNWEntity("FakeRagdoll") == ent)
			and ((bone and p.bone == bone) or (hitgroup and p.hitgroup == hitgroup)) then
			return true
		end
	end
	return false
end

hook.Add("PreHomigradDamageBulletBleedAdd", "ABL_WoundHit", function(ply, org, dmgInfo, hitgroup, harm, hitBoxs, inputHole, hookInfo)
	if not ABL.Enabled() or not C.sv.netHits:GetBool() then return end
	if not istable(hookInfo) or not istable(org) then return end

	-- CTakeDamageInfo, the bullet table, the trail and the pose are only valid inside the hook: copy now.
	local dmgClass = DamageClass(dmgInfo:GetDamageType())
	local damage = dmgInfo:GetDamage()
	local force = dmgInfo:GetDamageForce()
	local dir = force:LengthSqr() > 1 and force:GetNormalized() or nil
	local dmgPos = dmgInfo:GetDamagePosition()
	local owner = org.owner
	local hitEnt = hitEnts[org]
	hitEnts[org] = nil
	if not IsValid(hitEnt) then hitEnt = (IsValid(ply) and ply) or owner end

	-- An edged or a blunt weapon: what the weapon itself says of its blow, as Z-City reads it off
	-- the inflictor in this very call: how deep it goes and how wide (its Penetration and
	-- PenetrationSize; a knife's thrust is 10 and 1, an axe's blow 5 and 3). They travel in the
	-- two fields that are a projectile's energy and diameter: a blade has neither.
	local bladeDepth, bladeWidth = 0, 0
	if dmgClass == N.DMG_SLASH or dmgClass == N.DMG_CLUB then
		local inf = dmgInfo:GetInflictor()
		local pen, size = IsValid(inf) and tonumber(inf.Penetration) or nil, IsValid(inf) and tonumber(inf.PenetrationSize) or nil
		if pen and pen > 0 and pen == pen then bladeDepth = math.Clamp(math.Round(pen / 1.5), 1, 7) end
		if size and size > 0 and size == size then bladeWidth = math.Clamp(math.Round(size * 4), 1, 15) end
	end

	local tr = trails[org]
	trails[org] = nil
	if tr and SysTime() - tr.rt > 0.05 then tr = nil end
	local flags = tr and tr.flags or 0
	local tissue = tr and tr.tissue or 0
	local armorFirst = tr ~= nil and tr.armorFirst
	if armorFirst then flags = bor(flags, WD.F.ARMOR) end

	local isBullet = dmgClass == N.DMG_BULLET or dmgClass == N.DMG_BUCKSHOT
	local energy, velocity, diameter, range = bladeDepth, 0, bladeWidth, WD.RANGE_DISTANT
	if isBullet then
		-- the projectile (Z-City weapons describe it; a plain engine bullet has only its damage)
		local inf, att = dmgInfo:GetInflictor(), dmgInfo:GetAttacker()
		local b = IsValid(inf) and istable(inf.bullet) and inf.bullet or nil
		local speed, mass, diam
		if b then
			speed, diam = tonumber(b.Speed), tonumber(b.Diameter)
			local at = istable(hg) and istable(hg.ammotypeshuy) and b.AmmoType and hg.ammotypeshuy[b.AmmoType]
			local bs = istable(at) and at.BulletSettings
			if istable(bs) then
				mass = tonumber(bs.Mass)
				speed = speed or tonumber(bs.Speed)
				diam = diam or tonumber(bs.Diameter)
				-- a shot cartridge: Z-City fires its pellets one by one as plain bullets, each with
				-- the shell's bore divided among them for a diameter. It is a pellet
				if (tonumber(bs.NumBullet) or 1) > 1 then
					dmgClass = N.DMG_BUCKSHOT
					diam = nil
				end
			end
			if (tonumber(b.penetrated) or 0) > 0 then flags = bor(flags, WD.F.INTERMEDIATE) end
		end
		energy = WD.EnergyClass(mass, speed)
		if energy == 0 then energy = WD.EnergyClassFromDamage(damage, dmgClass == N.DMG_BUCKSHOT) end
		velocity = WD.VelocityClass(speed)
		diameter = WD.DiameterCode(diam)
		-- muzzle to skin
		if band(flags, WD.F.INTERMEDIATE) == 0 then
			local d
			if IsValid(att) and att == owner then
				-- self-inflicted: the muzzle is on the skin
				d = 0
			elseif b and isvector(b.Src) then
				d = b.Src:Distance(dmgPos)
			elseif IsValid(att) and att.GetShootPos then
				-- only the eye position is known: the muzzle is about an arm length in front of it
				d = math.max(att:GetShootPos():Distance(dmgPos) - C.Wound.muzzleAhead, 0)
			end
			if d then
				if d <= C.Wound.contactDist then range = WD.RANGE_CONTACT
				elseif d <= C.Wound.nearDist then range = WD.RANGE_NEAR
				elseif d <= C.Wound.mediumDist then range = WD.RANGE_MEDIUM end
			end
		end
	end

	local inHoles, outHoles = hookInfo.input_hole, hookInfo.output_hole
	local entry = (istable(inHoles) and isvector(inHoles[1]) and Vector(inHoles[1])) or (isvector(dmgPos) and Vector(dmgPos)) or nil
	if not entry then return end
	local hasExit = istable(outHoles) and isvector(outHoles[1])
	local pen
	if not isBullet or tissue == 0 then
		-- (Z-City lets a bullet that met no organ box carry on: flesh only)
		pen = (isBullet and armorFirst and not hasExit) and WD.PEN_ARMOR or WD.PEN_SOFT
	elseif hasExit then
		pen = WD.PEN_THROUGH
	else
		pen = WD.PEN_RETAINED
	end
	-- where Z-City puts its second wound record of a shot whose trace left the body (the point the
	-- bullet left its last organ box)
	local exit = hasExit and Vector(outHoles[1]) or nil
	local bone, lEntry, lExit = WoundSpace(hitEnt, hookInfo.bone, entry, exit)
	local seed = math.random(0, 65535)

	local now = CurTime()
	for i = #recent, 1, -1 do
		if now - recent[i].t > 0.1 then table.remove(recent, i) end
	end
	local plyKey = (IsValid(ply) and ply:IsPlayer()) and ply or nil
	local continued = isBullet and band(flags, WD.F.INTERMEDIATE) ~= 0 and Continued(plyKey, hitEnt, bone, hitgroup)
	recent[#recent + 1] = { t = now, ply = plyKey, ent = hitEnt, bone = bone, hitgroup = hitgroup }

	-- Defer one tick so every other listener has had the chance to set hookInfo.restricted.
	-- A lethal hit (most headshots) kills the player in the same damage call: the hit then belongs
	-- to the corpse Z-City makes from the dying body. It may take a moment to appear, so look again a
	-- few times.
	local function Try(attempt)
		if hookInfo.restricted then if ABL.TestLog then ABL.TestLog("  abl_hit: restricted") end return end
		local bleed = tonumber(hookInfo.bleed) or 0
		-- (No blood: no event, but for a blunt blow hard enough to bruise. That one is sent, and
		-- the client lays a bruise and nothing else: no blood is thrown and none runs.)
		if bleed <= 0 and not (dmgClass == N.DMG_CLUB and damage >= C.Wound.bluntMin) then
			if ABL.TestLog then ABL.TestLog("  abl_hit: no bleed") end
			return
		end
		local body
		if IsValid(ply) and ply:IsPlayer() and not ply:Alive() then
			body = Z.GetCorpse(ply)
			if not IsValid(body) then
				if attempt < 4 then timer.Simple(0.05, function() Try(attempt + 1) end) elseif ABL.TestLog then ABL.TestLog("  abl_hit: dead, no corpse") end
				return
			end
		else
			body = IsValid(ply) and Z.GetBody(ply) or owner
		end
		if not IsValid(body) then return end
		dir = dir or (body:WorldSpaceCenter() - entry):GetNormalized()
		local rec = {
			entry = entry, dir = dir, class = dmgClass, damage = damage, bleed = bleed, hitgroup = hitgroup,
			bone = bone, lEntry = lEntry, lExit = (pen == WD.PEN_THROUGH) and lExit or nil,
			exit = (pen == WD.PEN_THROUGH) and exit or nil,
			pen = pen, energy = energy, velocity = velocity, diameter = diameter,
			range = range, flags = flags, seed = seed, second = hasExit, continued = continued,
			owner = (IsValid(ply) and ply:IsPlayer()) and ply or nil,
		}
		if ABL.TestLog then
			ABL.TestLog("  abl_hit: %s on %s | %s, energy %s, velocity class %d, diameter code %d, range %s | crossed: %s | seed %d%s (attempt %d)",
				CLASS_NAMES[dmgClass] or "?", tostring(body), WD.PenNames[pen], tostring(WD.EnergyNames[energy] or energy), velocity, diameter, WD.RangeNames[range], WD.FlagText(flags), seed,
				continued and " | continuation of the previous hit" or "", attempt)
		end
		SendHit(body, rec)
	end
	timer.Simple(0, function() Try(0) end)
end)

------------------------------------------------------------------------------------------
-- Bloody ragdoll collisions (Z-City: "Ragdoll Collide", fired from PhysicsCollide)
-- Physics callbacks must not do heavy work, so events are queued and flushed in Think.
------------------------------------------------------------------------------------------
local queue = {}
local nextAllowed = setmetatable({}, { __mode = "k" })
local MIN_SPEED = 140

local function HasBlood(rag)
	local org = rag.organism
	if not istable(org) then
		local ply = Z.GetOwner(rag)
		org = IsValid(ply) and ply.organism or nil
	end
	if istable(org) then
		if istable(org.wounds) and #org.wounds > 0 then return true end
		if istable(org.arterialwounds) and #org.arterialwounds > 0 then return true end
		if tonumber(org.blood) and org.blood < 4950 then return true end
	end
	return (rag.ABL_BloodyUntil or 0) > CurTime()
end

hook.Add("Ragdoll Collide", "ABL_RagdollCollide", function(rag, data)
	if not IsValid(rag) or not C.sv.netCollide:GetBool() then return end
	local speed = data.Speed or 0
	if speed < MIN_SPEED then return end
	local t = CurTime()
	if (nextAllowed[rag] or 0) > t then return end
	nextAllowed[rag] = t + 0.12
	if #queue > 64 then return end
	queue[#queue + 1] = {
		rag = rag, phys = data.PhysObject, pos = data.HitPos, normal = data.HitNormal,
		speed = speed, world = IsValid(data.HitEntity) and data.HitEntity:IsWorld() or data.HitEntity == game.GetWorld(),
	}
end)

local function PhysBoneIndex(rag, phys)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		if rag:GetPhysicsObjectNum(i) == phys then return i end
	end
	return nil
end

hook.Add("Think", "ABL_FlushCollisions", function()
	if #queue == 0 then return end
	local q = queue
	queue = {}
	if not ABL.Enabled() then return end
	for _, ev in ipairs(q) do
		local rag = ev.rag
		if IsValid(rag) and HasBlood(rag) then
			local pb = IsValid(ev.phys) and PhysBoneIndex(rag, ev.phys)
			local bone = pb and rag:TranslatePhysBoneToBone(pb)
			if bone and bone >= 0 and bone <= 255 then
				local rf = RecipientFilter()
				rf:AddPVS(ev.pos)
				if rf:GetCount() > 0 then
					net.Start(N.RCOL, true)
					N.WriteEnt(rag)
					net.WriteUInt(bone, 8)
					net.WriteVector(ev.pos)
					net.WriteNormal(ev.normal)
					net.WriteUInt(math.Clamp(math.Round(ev.speed), 0, 4095), 12)
					net.WriteBool(ev.world and true or false)
					net.Send(rf)
				end
			end
		end
	end
end)

-- Remember that a body bled recently even after its wounds were bandaged (blood is still on it).
hook.Add("HomigradDamage", "ABL_MarkBloody", function(ply, dmgInfo, hitgroup, ent)
	if IsValid(ent) then ent.ABL_BloodyUntil = CurTime() + 300 end
	if IsValid(ply) then
		local body = Z.GetBody(ply)
		if IsValid(body) then body.ABL_BloodyUntil = CurTime() + 300 end
	end
end)

hook.Add("Fake", "ABL_MarkBloody", function(ply, ragdoll)
	if IsValid(ply) and IsValid(ragdoll) and (ply.ABL_BloodyUntil or 0) > CurTime() then
		ragdoll.ABL_BloodyUntil = ply.ABL_BloodyUntil
	end
end)
