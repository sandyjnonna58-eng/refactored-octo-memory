-- Серверная часть тейкдаунов (описание в sh_takedowns.lua)
-- cl_ грузится раньше sh_ (по алфавиту), поэтому таблица создаётся здесь тоже
hg.Takedown = hg.Takedown or {}
local TD = hg.Takedown

util.AddNetworkString("rem_takedown")
util.AddNetworkString("rem_takedown_end")

local COOLDOWN = 1.0
local vector_up = Vector(0, 0, 1)

local modelsOk
local function ModelsOk()
	if modelsOk == nil then
		modelsOk = util.IsValidModel(TD.PlyModel) and util.IsValidModel(TD.TgtModel)
		if not modelsOk then
			print("[remorseism] takedowns are off: " .. TD.PlyModel .. " / " .. TD.TgtModel .. " are not in the server content")
		end
	end
	return modelsOk
end

local function HasTakedownWeapon(ply)
	local wep = ply:GetActiveWeapon()
	return IsValid(wep) and wep.Takedowns and wep or nil
end

local function CanAttack(ply)
	if not ply:Alive() or TD.ByEnt[ply] or IsValid(ply.FakeRagdoll) or ply:InVehicle() then return false end
	if (ply.rem_td_cd or 0) > CurTime() then return false end
	if ply:GetMoveType() == MOVETYPE_NOCLIP then return false end
	return HasTakedownWeapon(ply) ~= nil and ModelsOk()
end

local function ValidVictim(ply, ent)
	if not IsValid(ent) or ent == ply or TD.ByEnt[ent] then return false end
	if ent:IsPlayer() then
		if not ent:Alive() or IsValid(ent.FakeRagdoll) or ent:InVehicle() or ent:GetMoveType() == MOVETYPE_NOCLIP then return false end
	elseif ent:IsNPC() then
		if ent:Health() <= 0 then return false end
	else
		return false
	end
	return ent:LookupBone("ValveBiped.Bip01_Spine") ~= nil and ent:LookupBone("ValveBiped.Bip01_Head1") ~= nil
end

local function Flat(v) return Vector(v.x, v.y, 0) end

-- цель перед ply (по взгляду), в радиусе dist по горизонтали и с разницей высот (цель минус ply) от dzMin до dzMax
local function FindTarget(ply, dist, dzMin, dzMax, minDot)
	local eye = ply:EyePos()
	local aim = Flat(ply:GetAimVector()):GetNormalized()
	local best, bestScore
	for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), dist + 120)) do
		if not ValidVictim(ply, ent) then continue end
		local d = ent:GetPos() - ply:GetPos()
		local dz = d.z
		local flat = Flat(d)
		local len = flat:Length()
		if len > dist or dz < dzMin or dz > dzMax then continue end
		local dot = len > 1 and aim:Dot(flat / len) or 1
		if dot < (minDot or 0.5) then continue end
		-- видно голову цели
		local tr = util.TraceLine({start = eye, endpos = ent:EyePos(), filter = {ply, ent}, mask = MASK_SOLID_BRUSHONLY})
		if tr.Hit then continue end
		local score = len - dot * 40
		if not bestScore or score < bestScore then best, bestScore = ent, score end
	end
	return best
end

-- низкое укрытие между ply и целью: на уровне пояса что-то есть, на уровне глаз - нет
local function LowCoverBetween(ply, target)
	local a = ply:GetPos() + vector_up * 24
	local b = target:GetPos() + vector_up * 24
	local low = util.TraceLine({start = a, endpos = b, filter = {ply, target}})
	if not low.Hit then return false end
	local high = util.TraceLine({start = ply:EyePos(), endpos = target:EyePos(), filter = {ply, target}})
	return not high.Hit
end

local function FrontOrBack(side)
	if side == "front" or side == "back" then return side end
	return math.random(2) == 1 and "front" or "back"
end

-- выбрать приём: kind, имя анимации, сторона для расстановки и параметры расстановки (как в BSMod)
-- drop - насколько ниже ног цели стоит шаблон жертвы, shift - на сколько назад от её "вперёд", dist - убивающий позади шаблона жертвы
local function Choose(kind, side)
	local v = ({"A", "B", "C", "D"})
	if kind == "back" then
		return "fc4_back" .. v[math.random(4)] .. "_machete", "back", 0, 0, 32
	elseif kind == "cover" then
		local s = FrontOrBack(side)
		return "fc4_cover_" .. s .. "_machete", s, 0, 8, 0.1
	elseif kind == "dfb" then
		local s = FrontOrBack(side)
		return "fc4_dfb_" .. s .. "_machete", s, 64, 16, 36
	elseif kind == "water" then
		-- с боков BSMod берёт случайную из двух, развернув цель боком
		local s = side == "front" and "front" or side == "back" and "back" or (math.random(2) == 1 and "front" or "back")
		return "fc4_water_" .. s .. "_machete", side, 64, 16, 32
	elseif kind == "dfa" then
		if side == "left" or side == "right" then
			return "fc4_dfa_" .. side .. "_machete", side, 0, 0, 32
		end
		return "fc4_dfa_" .. side .. v[math.random(2)] .. "_machete", side, 0, 0, 32
	end
end

local function SoundFor(seq)
	local list = {}
	for _, s in ipairs(TD.Seq[seq].snd) do
		local path = "fc4tkdwn_sfx/" .. s .. ".wav"
		if file.Exists("sound/" .. path, "GAME") then list[#list + 1] = path end
	end
	return list[math.random(#list)]
end

-- кости шаблона на последнем кадре (для позы трупа и того, где убивающий окажется в конце)
local function FinalBones(model, seq, pos, ang)
	local e = ents.Create("prop_dynamic")
	if not IsValid(e) then return {} end
	e:SetModel(model)
	e:SetKeyValue("solid", "0")
	e:SetPos(pos)
	e:SetAngles(ang)
	e:Spawn()
	local out = {}
	local id = e:LookupSequence(seq)
	if id and id >= 0 then
		e:ResetSequence(id)
		e:SetPlaybackRate(0)
		e:SetCycle(0.999)
		if e.SetupBones then e:SetupBones() end
		for i = 0, e:GetBoneCount() - 1 do
			local m = e:GetBoneMatrix(i)
			if m then out[e:GetBoneName(i)] = m end
		end
	end
	e:Remove()
	return out
end

local function PoseRagdoll(rag, bones)
	if not IsValid(rag) or not bones then return end
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if not IsValid(phys) then continue end
		local m = bones[rag:GetBoneName(rag:TranslatePhysBoneToBone(i))]
		if not m then continue end
		phys:SetPos(m:GetTranslation())
		phys:SetAngles(m:GetAngles())
		phys:SetVelocity(vector_origin)
		phys:AddAngleVelocity(-phys:GetAngleVelocity())
		phys:Wake()
	end
end

TD.PendingRagPose = TD.PendingRagPose or {}

-- NPC, у которых сервер делает свой труп
hook.Add("CreateEntityRagdoll", "rem_takedown_pose", function(owner, rag)
	local bones = TD.PendingRagPose[owner]
	if not bones then return end
	TD.PendingRagPose[owner] = nil
	PoseRagdoll(rag, bones)
	timer.Simple(0, function() PoseRagdoll(rag, bones) end)
end)

local function Freeze(ent)
	ent.rem_td_movetype = ent:GetMoveType()
	ent:SetMoveType(MOVETYPE_NONE)
	ent:SetLocalVelocity(vector_origin)
	ent:SetVelocity(-ent:GetVelocity())
	if ent:IsNPC() then
		ent:SetSchedule(SCHED_NPC_FREEZE)
		ent:AddEFlags(EFL_NO_THINK_FUNCTION)
	end
end

local function Unfreeze(ent)
	if not IsValid(ent) then return end
	if ent:IsNPC() then
		ent:RemoveEFlags(EFL_NO_THINK_FUNCTION)
		ent:SetMoveType(ent.rem_td_movetype ~= MOVETYPE_NONE and ent.rem_td_movetype or MOVETYPE_STEP)
		ent:SetSchedule(SCHED_IDLE_STAND)
	else
		ent:SetMoveType(MOVETYPE_WALK)
	end
	ent.rem_td_movetype = nil
end

local function SendEnd(td)
	net.Start("rem_takedown_end")
	net.WriteUInt(td.id, 16)
	net.Broadcast()
end

local function Clear(td)
	if TD.ByEnt[td.attacker] and TD.ByEnt[td.attacker].td == td then TD.ByEnt[td.attacker] = nil end
	if TD.ByEnt[td.victim] and TD.ByEnt[td.victim].td == td then TD.ByEnt[td.victim] = nil end
	timer.Remove("rem_td_" .. td.id)
end

-- где убивающий стоит и куда смотрит после приёма
local function PlaceAttackerAtEnd(td)
	local ply = td.attacker
	local bones = FinalBones(TD.PlyModel, td.plySeq, td.plyPos, td.plyAng)
	local pelvis, head = bones["ValveBiped.Bip01_Pelvis"], bones["ValveBiped.Bip01_Head1"]
	local filter = {ply, td.victim, td.rag}
	local placed = false
	if pelvis then
		local p = pelvis:GetTranslation()
		local down = util.TraceLine({start = p + vector_up * 8, endpos = p - vector_up * 96, filter = filter, mask = MASK_PLAYERSOLID})
		local spot = down.Hit and down.HitPos + vector_up * 1 or p - vector_up * 36
		local mins, maxs = ply:GetHull()
		local fit = util.TraceHull({start = spot, endpos = spot, mins = mins, maxs = maxs, filter = filter, mask = MASK_PLAYERSOLID})
		if not fit.StartSolid then
			ply:SetPos(spot)
			placed = true
		end
	end
	if not placed then ply:SetPos(td.startPos) end
	if head then
		local _, eang = LocalToWorld(TD.EyesPos, TD.EyesAng, head:GetTranslation(), head:GetAngles())
		ply:SetEyeAngles(Angle(0, eang.y, 0))
	end
end

local function KillVictim(td)
	local victim, ply = td.victim, td.attacker
	if not IsValid(victim) then return end
	local bones = FinalBones(TD.TgtModel, td.tgtSeq, td.tgtPos, td.tgtAng)

	if victim:IsPlayer() then
		if not victim:Alive() then return end
		Unfreeze(victim)
		victim:SetPos(td.victimStart)
		victim:Kill()
		local rag = victim.RagdollDeath or victim.FakeRagdoll
		if not IsValid(rag) then rag = victim:GetNWEntity("RagdollDeath") end
		if IsValid(rag) then
			td.rag = rag
			PoseRagdoll(rag, bones)
			timer.Simple(0, function() PoseRagdoll(rag, bones) end)
		end
	else
		Unfreeze(victim)
		TD.PendingRagPose[victim] = bones
		local dmg = DamageInfo()
		dmg:SetDamage(math.max(victim:Health(), 1) * 10 + 1000)
		dmg:SetDamageType(DMG_SLASH)
		dmg:SetAttacker(IsValid(ply) and ply or game.GetWorld())
		dmg:SetInflictor(IsValid(td.wep) and td.wep or (IsValid(ply) and ply or game.GetWorld()))
		dmg:SetDamagePosition(victim:EyePos())
		victim:TakeDamageInfo(dmg)
		timer.Simple(1, function() if IsValid(victim) then TD.PendingRagPose[victim] = nil end end)
	end
end

-- прервать (кто-то умер, вышел и т.п.)
local function Abort(td)
	if td.done then return end
	td.done = true
	Clear(td)
	if IsValid(td.attacker) then
		Unfreeze(td.attacker)
		td.attacker.rem_td_cd = CurTime() + COOLDOWN
	end
	if IsValid(td.victim) and not td.killed then Unfreeze(td.victim) end
	SendEnd(td)
end

local nextId = 0
TD.Active = TD.Active or {}

function TD.Start(ply, target, kind)
	local side = TD.Side(ply, target)
	local seq, placeSide, drop, shift, dist = Choose(kind, side)
	local info = seq and TD.Seq[seq]
	if not info then return false end

	local ang = Angle(0, TD.TargetYaw(target) + TD.SideYaw[placeSide], 0)
	local f = ang:Forward()
	local tgtPos = target:GetPos() - vector_up * drop - f * shift
	local plyPos = tgtPos - f * dist

	nextId = (nextId + 1) % 65536
	local wep = HasTakedownWeapon(ply)
	local td = {
		id = nextId, attacker = ply, victim = target, kind = kind, wep = wep,
		plySeq = seq, tgtSeq = seq, plyPos = plyPos, plyAng = ang, tgtPos = tgtPos, tgtAng = ang,
		start = CurTime(), startPos = ply:GetPos(), victimStart = target:GetPos(),
	}
	TD.Active[td.id] = td
	TD.ByEnt[ply] = {td = td, role = "attacker"}
	TD.ByEnt[target] = {td = td, role = "victim"}

	Freeze(ply)
	Freeze(target)
	-- убивающего ставим туда, где его тело по анимации (чтобы не отсекалось и звук шёл оттуда), если там не стена
	local mins, maxs = ply:GetHull()
	local fit = util.TraceHull({start = plyPos, endpos = plyPos, mins = mins, maxs = maxs, filter = {ply, target}, mask = MASK_PLAYERSOLID})
	if not fit.StartSolid then ply:SetPos(plyPos) end

	net.Start("rem_takedown")
	net.WriteUInt(td.id, 16)
	net.WriteEntity(ply)
	net.WriteEntity(target)
	net.WriteString(seq)
	net.WriteVector(plyPos)
	net.WriteAngle(ang)
	net.WriteVector(tgtPos)
	net.WriteAngle(ang)
	net.WriteFloat(td.start)
	net.WriteString(IsValid(wep) and wep:GetClass() or "")
	net.Broadcast()

	local snd = SoundFor(seq)
	if snd then
		timer.Simple(0.1, function() if IsValid(ply) and not td.done then ply:EmitSound(snd, 75, 100, 1, CHAN_AUTO) end end)
	end

	timer.Simple(info.tgt, function()
		if td.done then return end
		td.killed = true
		KillVictim(td)
		if TD.ByEnt[target] and TD.ByEnt[target].td == td then TD.ByEnt[target] = nil end
	end)

	timer.Simple(info.ply, function()
		if td.done then return end
		td.done = true
		Clear(td)
		if IsValid(ply) then
			Unfreeze(ply)
			if ply:Alive() then PlaceAttackerAtEnd(td) end
			ply:SetLocalVelocity(vector_origin)
			ply.rem_td_cd = CurTime() + COOLDOWN
		end
		if IsValid(target) and not td.killed then Unfreeze(target) end
		SendEnd(td)
		TD.Active[td.id] = nil
	end)

	return true
end

-- присмотр: если кто-то из двоих умер / вышел / упал в рэгдолл раньше времени - отменяем
hook.Add("Think", "rem_takedown_watch", function()
	for id, td in pairs(TD.Active) do
		if td.done then TD.Active[id] = nil continue end
		local a, v = td.attacker, td.victim
		local bad = not IsValid(a) or not a:Alive() or IsValid(a.FakeRagdoll)
		if not td.killed then
			bad = bad or not IsValid(v) or (v:IsPlayer() and (not v:Alive() or IsValid(v.FakeRagdoll))) or (v:IsNPC() and v:Health() <= 0)
		end
		if bad then
			Abort(td)
			TD.Active[id] = nil
		end
	end
end)

hook.Add("PlayerDisconnected", "rem_takedown_leave", function(ply)
	local e = TD.ByEnt[ply]
	if e then Abort(e.td) end
end)

-- E: со спины, через укрытие, снизу с уступа/лестницы, из воды
hook.Add("KeyPress", "rem_takedown_use", function(ply, key)
	if key ~= IN_USE or not CanAttack(ply) then return end

	local target, kind
	if ply:GetMoveType() == MOVETYPE_LADDER then
		target = FindTarget(ply, 72, 20, 110, 0.2)
		if target then
			kind = "dfb"
		else
			target = FindTarget(ply, 64, -220, -40, 0.2)
			kind = target and "dfa"
		end
	elseif ply:WaterLevel() >= 2 then
		target = FindTarget(ply, 80, -24, 90, 0.3)
		kind = target and "water"
	else
		-- цель на уступе над нами (по пояс-грудь) - стаскиваем
		target = FindTarget(ply, 64, 36, 96, 0.4)
		if target then
			kind = "dfb"
		else
			target = FindTarget(ply, 72, -30, 30, 0.5)
			if target then
				if LowCoverBetween(ply, target) then
					kind = "cover"
				elseif TD.Side(ply, target) == "back" then
					kind = "back"
				else
					target = nil
				end
			end
		end
	end

	if target and kind then TD.Start(ply, target, kind) end
end)

-- прыжок / падение с высоты на цель - сам, без E
local DFA_MIN_HEIGHT = 96
hook.Add("Tick", "rem_takedown_dfa", function()
	for _, ply in ipairs(player.GetAll()) do
		if ply:OnGround() or ply:WaterLevel() >= 1 or ply:GetMoveType() ~= MOVETYPE_WALK or not ply:Alive() then
			ply.rem_td_airZ = nil
			continue
		end
		local z = ply:GetPos().z
		ply.rem_td_airZ = math.max(ply.rem_td_airZ or z, z)
		if ply:GetVelocity().z > -120 or not CanAttack(ply) then continue end

		for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 140)) do
			if not ValidVictim(ply, ent) then continue end
			local d = ply:GetPos() - ent:GetPos()
			-- ноги убивающего над головой цели, близко по горизонтали, а прыгал он с высоты
			if d.z < 56 or d.z > 130 or Flat(d):Length() > 56 then continue end
			if ply.rem_td_airZ - ent:GetPos().z < DFA_MIN_HEIGHT then continue end
			if TD.Start(ply, ent, "dfa") then
				ply.rem_td_airZ = nil
				break
			end
		end
	end
end)

-- во время приёма никакого урона от падения / оглушения приземлением
hook.Add("OnPlayerHitGround", "rem_takedown_nofall", function(ply)
	if TD.ByEnt[ply] or (ply.rem_td_cd or 0) > CurTime() then return true end
end)
hook.Add("GetFallDamage", "rem_takedown_nofall", function(ply)
	if TD.ByEnt[ply] or (ply.rem_td_cd or 0) > CurTime() then return 0 end
end)
