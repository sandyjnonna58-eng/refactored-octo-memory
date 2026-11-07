-- Рикошетная пуля красного револьвера (lua/weapons/weapon_rem_ricochet.lua).
-- Летит отрезками: стена - отскок под случайным углом, но с шансом (25% и +5% за каждый отскок) прямо в человека,
-- которого видно с места отскока (не в стрелявшего). Попала в человека - разрывает на части (смертельный урон,
-- потом hg.FullBodyExplode), летит дальше к ближайшей стене, шанс снова 25%. Конец - 17 отскоков или 2 убийства.
-- Клиентам уходят точки пути (net "rem_ricochet"), луч рисует cl_ricochet.lua.
util.AddNetworkString("rem_ricochet")

hg.RemRicochet = hg.RemRicochet or {}
local RR = hg.RemRicochet

local function Cfg()
	local w = weapons.GetStored("weapon_rem_ricochet")
	return w and w.RicochetConfig or {maxBounces = 17, maxKills = 2, chance = 0.25, chanceAdd = 0.05, range = 8000, gibForce = 6000, lethal = 1000, segmentTime = 0.035}
end

-- человек ли это (игрок, NPC или регдолл живого/упавшего игрока); возвращает "кого убивать"
local function PersonOf(ent)
	if not IsValid(ent) then return end
	if ent:IsPlayer() then return ent:Alive() and ent or nil end
	if ent:IsNPC() or ent:IsNextBot() then return ent:Health() > 0 and ent or nil end
	if ent:IsRagdoll() then
		local ply = hg.RagdollOwner and hg.RagdollOwner(ent)
		if IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply.FakeRagdoll == ent then return ply end
	end
end

-- случайный отскок: полусфера вокруг нормали стены, не слишком вдоль неё
local function RandomBounce(normal)
	for _ = 1, 8 do
		local d = VectorRand():GetNormalized()
		local dot = d:Dot(normal)
		if dot < 0 then d = -d dot = -dot end
		if dot > 0.15 then return d end
	end
	return normal
end

-- кого видно с точки отскока (кроме стрелявшего и уже убитых)
local function PickTarget(from, shooter, skip)
	local list = {}
	for _, e in ipairs(ents.FindInSphere(from, 3000)) do
		local p = PersonOf(e)
		if p and p == e and p ~= shooter and not skip[p] then
			local aim = p:WorldSpaceCenter() + Vector(0, 0, 8)
			local tr = util.TraceLine({start = from, endpos = aim, mask = MASK_SHOT, filter = function(x) return x ~= shooter and not skip[x] and not (x:IsRagdoll() and skip[PersonOf(x) or x]) end})
			local hit = PersonOf(tr.Entity)
			if not tr.Hit or hit == p then list[#list + 1] = p end
		end
	end
	if #list > 0 then return list[math.random(#list)] end
end

-- разорвать на части
local function Gib(victim, ent, dir, shooter, wep, pos, C)
	local d = DamageInfo()
	d:SetDamage(C.lethal)
	d:SetDamageType(DMG_BULLET)
	d:SetAttacker(IsValid(shooter) and shooter or victim)
	d:SetInflictor(IsValid(wep) and wep or (IsValid(shooter) and shooter or victim))
	d:SetDamagePosition(pos)
	d:SetDamageForce(dir * C.gibForce)
	ent:TakeDamageInfo(d)
	if victim:IsPlayer() then
		timer.Simple(0, function()
			if IsValid(victim) and victim:Alive() then victim:Kill() end
			timer.Simple(0.05, function()
				if IsValid(victim) and hg.FullBodyExplode then hg.FullBodyExplode(victim, dir * C.gibForce) end
			end)
		end)
	elseif hg.FullBodyExplode then
		timer.Simple(0, function()
			if IsValid(victim) and hg.FullBodyExplode(victim, dir * C.gibForce) then return end
			if IsValid(victim) and victim:Health() > 0 then victim:TakeDamageInfo(d) end
		end)
	end
end

function RR.Fire(shooter, wep, start, dir)
	local C = Cfg()
	local pos, d = start, dir:GetNormalized()
	local bounces, kills, chance = 0, 0, C.chance
	local skip = {}
	local points = {start}

	for _ = 1, C.maxBounces + C.maxKills + 4 do
		local tr = util.TraceLine({start = pos, endpos = pos + d * C.range, mask = MASK_SHOT,
			filter = function(x) return x ~= shooter and not skip[x] and not (x:IsRagdoll() and skip[PersonOf(x) or false]) end})
		points[#points + 1] = tr.HitPos
		if not tr.Hit or tr.HitSky then break end

		local victim = PersonOf(tr.Entity)
		if victim and victim ~= shooter then
			Gib(victim, tr.Entity, d, shooter, wep, tr.HitPos, C)
			skip[victim] = true
			skip[tr.Entity] = true
			kills = kills + 1
			if kills >= C.maxKills then break end
			-- дальше - туда же, до ближайшей стены; шанс снова базовый
			chance = C.chance
			pos = tr.HitPos + d * 4
		else
			bounces = bounces + 1
			sound.Play("weapons/fx/rics/ric" .. math.random(1, 5) .. ".wav", tr.HitPos, 80, math.random(95, 115))
			local fx = EffectData()
			fx:SetOrigin(tr.HitPos)
			fx:SetNormal(tr.HitNormal)
			fx:SetMagnitude(2)
			util.Effect("MetalSpark", fx, true, true)
			if bounces >= C.maxBounces then break end

			local target = math.random() < chance and PickTarget(tr.HitPos + tr.HitNormal * 2, shooter, skip)
			if target then
				d = (target:WorldSpaceCenter() + Vector(0, 0, 8) - tr.HitPos):GetNormalized()
			else
				d = RandomBounce(tr.HitNormal)
			end
			chance = chance + C.chanceAdd
			pos = tr.HitPos + tr.HitNormal * 2
		end
	end

	net.Start("rem_ricochet")
		net.WriteUInt(#points, 6)
		for _, p in ipairs(points) do net.WriteVector(p) end
		net.WriteFloat(C.segmentTime)
	net.Broadcast()
end
