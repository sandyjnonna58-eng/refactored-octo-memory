-- Developer commands used to reproduce the test scenarios in docs (upright wound, ragdoll on back,
-- upside down, spinning, falling, wall/ceiling impacts ...). All require `abl_dev 1` and
-- superadmin (or the listen-server host / console).

local C, Z = ABL.Config, ABL.ZC

local function Allowed(ply)
	if not C.sv.dev:GetBool() then return false end
	if not IsValid(ply) then return true end
	return ply:IsSuperAdmin() or ply:IsListenServerHost() or game.SinglePlayer()
end

local BONES = {
	head = "ValveBiped.Bip01_Head1", neck = "ValveBiped.Bip01_Neck1",
	chest = "ValveBiped.Bip01_Spine2", upperchest = "ValveBiped.Bip01_Spine4", stomach = "ValveBiped.Bip01_Spine1",
	belly = "ValveBiped.Bip01_Spine", pelvis = "ValveBiped.Bip01_Pelvis",
	lupperarm = "ValveBiped.Bip01_L_UpperArm", lforearm = "ValveBiped.Bip01_L_Forearm", lhand = "ValveBiped.Bip01_L_Hand",
	rupperarm = "ValveBiped.Bip01_R_UpperArm", rforearm = "ValveBiped.Bip01_R_Forearm", rhand = "ValveBiped.Bip01_R_Hand",
	lthigh = "ValveBiped.Bip01_L_Thigh", lcalf = "ValveBiped.Bip01_L_Calf", lfoot = "ValveBiped.Bip01_L_Foot",
	rthigh = "ValveBiped.Bip01_R_Thigh", rcalf = "ValveBiped.Bip01_R_Calf", rfoot = "ValveBiped.Bip01_R_Foot",
}

function ABL.DevFindTarget(caller, token)
	token = token or "aim"
	if token == "self" then return caller end
	if token == "bot" then
		for _, p in ipairs(player.GetBots()) do return p end
		return nil
	end
	if tonumber(token) then
		local e = Entity(tonumber(token))
		return IsValid(e) and e or nil
	end
	if token == "aim" and IsValid(caller) then
		local e = caller:GetEyeTrace().Entity
		if IsValid(e) then
			if e:IsPlayer() then return e end
			local owner = Z.GetOwner(e)
			if IsValid(owner) then return owner end
			if e.organism then return e end
		end
		return caller
	end
	for _, p in ipairs(player.GetAll()) do
		if string.find(string.lower(p:Nick()), string.lower(token), 1, true) then return p end
	end
	return nil
end

-- Point on the surface of `boneName`'s hitbox, facing local direction `side` (1..6), in bone space.
local function SurfacePointOnBone(ent, bone, side, frac1, frac2)
	local set = ent:GetHitboxSet() or 0
	for hb = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
		if ent:GetHitBoxBone(hb, set) == bone then
			local mins, maxs = ent:GetHitBoxBounds(hb, set)
			local p = Vector(Lerp(frac1, mins.x, maxs.x), Lerp(frac2, mins.y, maxs.y), Lerp(frac2, mins.z, maxs.z))
			if side == 1 then p.x = maxs.x elseif side == 2 then p.x = mins.x
			elseif side == 3 then p.y = maxs.y elseif side == 4 then p.y = mins.y
			elseif side == 5 then p.z = maxs.z else p.z = mins.z end
			-- hitboxes are a little larger than the skin; pull 15% toward the centre
			local c = (mins + maxs) * 0.5
			return c + (p - c) * 0.85
		end
	end
	return Vector(0, 0, 0)
end

function ABL.DevAddWound(target, boneKey, amount, arterial, side, f1, f2)
	if not IsValid(target) or not istable(target.organism) then return false, "target has no Z-City organism" end
	local org = target.organism
	local boneName = BONES[boneKey] or boneKey
	local body = target:IsPlayer() and Z.GetBody(target) or target
	local bone = body:LookupBone(boneName)
	if not bone then return false, "bone not found: " .. tostring(boneName) end
	local lpos = SurfacePointOnBone(body, bone, side or 3, f1 or 0.5, f2 or 0.5)
	if arterial then
		local ldir = lpos:GetNormalized()
		table.insert(org.arterialwounds, { amount, lpos, angle_zero, boneName, CurTime(), ldir * 100, "abl_dev_artery_" .. boneKey })
		org.owner:SetNetVar("arterialwounds", org.arterialwounds)
	else
		if not (hg and hg.organism and hg.organism.AddWoundManual) then return false, "Z-City organism not loaded" end
		hg.organism.AddWoundManual(org.owner, amount * 2, lpos, angle_zero, boneName, CurTime())
	end
	return true
end

local function Reply(ply, msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[ABL] " .. msg) else print("[ABL] " .. msg) end
end

-- abl_dev_wound <bone> <amount> [arterial 0/1] [target] [side 1-6]
concommand.Add("abl_dev_wound", function(ply, _, args)
	if not Allowed(ply) then return Reply(ply, "requires abl_dev 1 and superadmin") end
	local target = ABL.DevFindTarget(ply, args[4])
	local ok, err = ABL.DevAddWound(target, args[1] or "chest", tonumber(args[2]) or 10, args[3] == "1", tonumber(args[5]) or 3)
	Reply(ply, ok and ("wound added to " .. tostring(target)) or err)
end)

function ABL.DevHeal(target)
	if not IsValid(target) or not target.organism then return end
	local org = target.organism
	org.wounds, org.arterialwounds = {}, {}
	for _, k in ipairs({ "arteria", "rarmartery", "larmartery", "rlegartery", "llegartery", "spineartery" }) do
		if org[k] then org[k] = 0 end
	end
	org.owner:SetNetVar("wounds", {})
	org.owner:SetNetVar("arterialwounds", {})
	org.blood = 5000
end

-- abl_dev_compare [bone] [amount]: two bots side by side in front of you with the same wound, the
-- left one drawn with the older bead model of body blood, the right one with the flow core.
concommand.Add("abl_dev_compare", function(ply, _, args)
	if not Allowed(ply) or not IsValid(ply) then return end
	local bots = player.GetBots()
	if #bots < 2 then
		for _ = #bots + 1, 2 do game.ConsoleCommand("bot\n") end
		Reply(ply, "two bots are joining: run abl_dev_compare again in a moment")
		return
	end
	local a, b = bots[1], bots[2]
	local fwd = ply:GetForward()
	fwd.z = 0
	fwd:Normalize()
	local right = fwd:Cross(Vector(0, 0, 1))
	local base = ply:GetPos() + fwd * 70
	for i, bot in ipairs({ a, b }) do
		if not bot:Alive() then bot:Spawn() end
		bot:SetPos(base + right * (i == 1 and -18 or 18) + Vector(0, 0, 2))
		bot:SetEyeAngles((-fwd):Angle())
		bot:SetLocalVelocity(vector_origin)
		bot:Freeze(true)
		ABL.DevHeal(bot)
	end
	local bone, amount = args[1] or "chest", tonumber(args[2]) or 2
	timer.Simple(0.5, function()
		if not (IsValid(a) and IsValid(b) and IsValid(ply)) then return end
		for i, bot in ipairs({ a, b }) do
			net.Start(ABL.Net.DEV)
			net.WriteUInt(bot:EntIndex(), 13)
			net.WriteBool(i == 1)
			net.Send(ply)
			ABL.DevAddWound(bot, bone, amount, false, 3, 0.55, 0.5)
		end
		Reply(ply, "left: the older bead model, right: the film (or the flow core's streams with abl_body_film 0)")
	end)
end)

concommand.Add("abl_dev_heal", function(ply, _, args)
	if not Allowed(ply) then return end
	ABL.DevHeal(ABL.DevFindTarget(ply, args[1]))
end)

concommand.Add("abl_dev_fake", function(ply, _, args)
	if not Allowed(ply) then return end
	local target = ABL.DevFindTarget(ply, args[1])
	if IsValid(target) and target:IsPlayer() and hg and hg.Fake then hg.Fake(target) end
end)

concommand.Add("abl_dev_getup", function(ply, _, args)
	if not Allowed(ply) then return end
	local target = ABL.DevFindTarget(ply, args[1])
	if IsValid(target) and target:IsPlayer() and hg and hg.FakeUp then hg.FakeUp(target, true, true) end
end)

-- Fire a real bullet at the target so the full Z-City damage pipeline (and abl_hit) runs.
-- abl_dev_shoot [target] [damage or -] [from: front/back/left/right/above] [bone] [ammunition] [distance]
--   ammunition: a key of hg.ammotypes (9x19mmparabellum, .45acp, 5.56x45mm, 7.62x39mm, 7.62x51mm,
--   12/70gauge, ...): the bullet carries that cartridge's speed, mass, diameter and penetration.
--   distance: muzzle to target in units (3: contact, 10: near, 30: medium, 80 and more: distant).
concommand.Add("abl_dev_shoot", function(ply, _, args)
	if not Allowed(ply) then return end
	local target = ABL.DevFindTarget(ply, args[1])
	if not IsValid(target) then return end
	local ok = ABL.DevShoot(IsValid(ply) and ply or nil, target, tonumber(args[2]), args[3], args[4], args[5], tonumber(args[6]))
	if args[5] and not ok then print("abl_dev_shoot: unknown ammunition type '" .. args[5] .. "' (use a key of hg.ammotypes)") end
end)

-- Pose a faked/dead ragdoll for orientation tests: abl_dev_pose <preset> [target] [freeze]
-- presets are relative to the body's own frame (head/up and facing), so they are correct for any
-- bone axis convention:  back, front, side, upside, tilt, spin, drop, free
local function RagdollOf(target)
	if not IsValid(target) then return nil end
	if target:IsRagdoll() then return target end
	local body = Z.GetBody(target)
	if IsValid(body) and body:IsRagdoll() then return body end
	local corpse = Z.GetCorpse(target)
	return corpse
end
ABL.DevRagdollOf = RagdollOf

-- Rodrigues rotation of v about unit axis k by angle a (radians)
local function RotAxis(v, k, a)
	local c, s = math.cos(a), math.sin(a)
	return v * c + k:Cross(v) * s + k * (k:Dot(v) * (1 - c))
end

local function BodyFrame(rag)
	local pelvis = rag:LookupBone("ValveBiped.Bip01_Pelvis")
	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	local lthigh, rthigh = rag:LookupBone("ValveBiped.Bip01_L_Thigh"), rag:LookupBone("ValveBiped.Bip01_R_Thigh")
	if not (pelvis and head and lthigh and rthigh) then return nil end
	local pp, hp = rag:GetBonePosition(pelvis), rag:GetBonePosition(head)
	local up = (hp - pp):GetNormalized()
	local right = (rag:GetBonePosition(rthigh) - rag:GetBonePosition(lthigh)):GetNormalized()
	local front = up:Cross(right):GetNormalized()   -- right-handed: front = up x right
	right = front:Cross(up):GetNormalized()
	return pp, up, right, front
end

function ABL.DevPose(rag, preset, freeze)
	if not IsValid(rag) then return false end
	local count = rag:GetPhysicsObjectCount()
	local function Each(fn) for i = 0, count - 1 do local po = rag:GetPhysicsObjectNum(i) if IsValid(po) then fn(po) end end end
	if preset == "spin" then
		Each(function(po) po:EnableMotion(true) po:SetVelocity(Vector(0, 0, 260)) po:AddAngleVelocity(Vector(0, 900, 300)) end)
		return true
	elseif preset == "drop" then
		Each(function(po) po:EnableMotion(true) po:SetPos(po:GetPos() + Vector(0, 0, 150)) po:SetVelocity(vector_origin) po:Wake() end)
		return true
	elseif preset == "free" then
		Each(function(po) po:EnableMotion(true) po:Wake() end)
		return true
	end
	local origin, up, right, front = BodyFrame(rag)
	if not origin then return false end
	-- desired world directions for the body's up and front axes
	local flatFront = Vector(front.x, front.y, 0)
	if flatFront:LengthSqr() < 0.01 then flatFront = Vector(1, 0, 0) end
	flatFront:Normalize()
	local wantUp, wantFront
	if preset == "back" then wantUp, wantFront = -flatFront, Vector(0, 0, 1)
	elseif preset == "front" then wantUp, wantFront = flatFront, Vector(0, 0, -1)
	elseif preset == "side" then wantUp, wantFront = flatFront:Cross(Vector(0, 0, 1)):GetNormalized(), flatFront
	elseif preset == "upside" then wantUp, wantFront = Vector(0, 0, -1), -flatFront
	elseif preset == "tilt" then wantUp, wantFront = (Vector(0, 0, 1) - flatFront):GetNormalized(), (Vector(0, 0, 1) + flatFront):GetNormalized()
	else return false end
	-- rotation taking (front, right, up) onto (wantFront, wantRight, wantUp), applied to each bone
	local wantRight = wantFront:Cross(wantUp):GetNormalized()
	local lift = (preset == "upside") and 45 or 6
	local newOrigin = origin + Vector(0, 0, lift)
	Each(function(po)
		local rel = po:GetPos() - origin
		local lx, ly, lz = rel:Dot(front), rel:Dot(right), rel:Dot(up)
		po:SetPos(newOrigin + wantFront * lx + wantRight * ly + wantUp * lz)
		local a = po:GetAngles()
		local f, r, u = a:Forward(), a:Right(), a:Up()
		local function Map(v) return wantFront * v:Dot(front) + wantRight * v:Dot(right) + wantUp * v:Dot(up) end
		local nf, nu = Map(f), Map(u)
		local na = nf:AngleEx(nu)
		po:SetAngles(na)
		po:SetVelocity(vector_origin)
		po:AddAngleVelocity(-po:GetAngleVelocity())
		po:EnableMotion(not freeze)
		po:Wake()
	end)
	return true
end

concommand.Add("abl_dev_pose", function(ply, _, args)
	if not Allowed(ply) then return end
	local rag = RagdollOf(ABL.DevFindTarget(ply, args[2]))
	if not IsValid(rag) then return Reply(ply, "target is not ragdolled (use abl_dev_fake first)") end
	local preset = args[1] or "back"
	ABL.DevPose(rag, preset, preset == "upside" or args[3] == "freeze")
end)

-- Drag a ragdoll along the floor: abl_dev_drag [target] [speed]
function ABL.DevDrag(rag, dir, speed)
	if not IsValid(rag) then return end
	local name = "ABL_Drag" .. rag:EntIndex()
	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	local pb = head and rag:TranslateBoneToPhysBone(head) or 0
	timer.Create(name, 0.05, 50, function()
		if not IsValid(rag) then timer.Remove(name) return end
		local po = rag:GetPhysicsObjectNum(pb)
		if IsValid(po) then po:SetVelocity(dir * speed + Vector(0, 0, 25)) end
	end)
end

concommand.Add("abl_dev_drag", function(ply, _, args)
	if not Allowed(ply) then return end
	local rag = RagdollOf(ABL.DevFindTarget(ply, args[1]))
	local dir = IsValid(ply) and ply:GetForward() or Vector(1, 0, 0)
	dir.z = 0 dir:Normalize()
	ABL.DevDrag(rag, dir, tonumber(args[2]) or 120)
end)

-- World centre of the hitbox of `boneKey` (the head bone's origin sits at the base of the skull).
function ABL.DevHitboxCenter(body, boneKey)
	local bone = body:LookupBone(BONES[boneKey] or boneKey)
	if not bone then return nil end
	local set = body:GetHitboxSet() or 0
	for hb = 0, (body:GetHitBoxCount(set) or 0) - 1 do
		if body:GetHitBoxBone(hb, set) == bone then
			local mins, maxs = body:GetHitBoxBounds(hb, set)
			local m = body:GetBoneMatrix(bone)
			if m and mins then return LocalToWorld((mins + maxs) * 0.5, angle_zero, m:GetTranslation(), m:GetAngles()) end
		end
	end
	return body:GetBonePosition(bone)
end

-- A Z-City ammunition type by its key in hg.ammotypes ("9x19mmparabellum") or by its name.
local function AmmoType(ammo)
	if not ammo or not istable(hg) then return nil end
	local t = istable(hg.ammotypes) and hg.ammotypes[ammo] or (istable(hg.ammotypeshuy) and hg.ammotypeshuy[ammo])
	if istable(t) and istable(t.BulletSettings) then return t end
	return nil
end

-- Real bullet at a world point from direction `fromDir` (unit, pointing from the target to the gun),
-- fired `dist` units away. ammo: a Z-City ammunition type; the bullet then carries that cartridge's
-- speed, mass, diameter and penetration through Z-City's damage pipeline, exactly like one fired
-- from a Z-City weapon (without it the hit is a plain engine bullet known only by its damage).
function ABL.DevShootAt(shooter, aimPos, fromDir, damage, dist, ammo)
	local src = aimPos + fromDir * (dist or 80)
	local dir = (aimPos - src):GetNormalized()
	shooter = IsValid(shooter) and shooter or game.GetWorld()
	local at = AmmoType(ammo)
	local wep = at and shooter.GetActiveWeapon and shooter:GetActiveWeapon()
	local old
	-- (a shot cartridge: its pellets, in a narrow cone)
	local num = at and tonumber(at.BulletSettings.NumBullet) or 1
	local spread = num > 1 and Vector(0.02, 0.02, 0) or vector_origin
	if at and IsValid(wep) then
		local bs = at.BulletSettings
		damage = damage or bs.Damage
		old = wep.bullet
		wep.bullet = {
			AmmoType = at.name, Penetration = bs.Penetration, Diameter = bs.Diameter, Speed = bs.Speed,
			Force = bs.Force or 2, Damage = damage, Src = src, Dir = dir, Num = 1, Spread = vector_origin,
		}
	else
		wep = nil
	end
	-- (one bullet per call, as Z-City's weapons fire them: the engine would book several pellets of
	-- one call on one body as a single hit)
	for _ = 1, num do
		-- (the engine draws a player's spread from the tick's seed, the same for every call in it)
		local d = num > 1 and (dir + VectorRand() * spread.x):GetNormalized() or dir
		shooter:FireBullets({
			Src = src, Dir = d, Damage = damage or 25,
			Force = 2, Num = 1, Tracer = 0, Spread = vector_origin, Attacker = shooter, IgnoreEntity = shooter,
		})
	end
	-- (Z-City keeps the table it read during the hit; the weapon gets its own back)
	if wep then wep.bullet = old end
	return at ~= nil
end

-- Real bullet through the Z-City damage pipeline. from: front/back/left/right/above
function ABL.DevShoot(shooter, target, damage, from, boneKey, ammo, dist)
	if not IsValid(target) then return end
	local body = target:IsPlayer() and Z.GetBody(target) or target
	local bone = body:LookupBone(BONES[boneKey or "chest"] or BONES.chest)
	local aimPos = bone and body:GetBonePosition(bone) or body:WorldSpaceCenter()
	local fwd = target:IsPlayer() and target:GetForward() or body:GetForward()
	local right = target:IsPlayer() and target:GetRight() or body:GetRight()
	local dirs = { front = fwd, back = -fwd, left = -right, right = right, above = Vector(0, 0, 1) }
	local fromDir = dirs[from or "front"] or dirs.front
	return ABL.DevShootAt(shooter, aimPos, fromDir, damage, dist, ammo)
end
