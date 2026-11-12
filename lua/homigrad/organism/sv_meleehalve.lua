-- Разрубание пополам оружием ближнего боя. Удар режущим/рубящим оружием по туловищу (между поясом и плечами, по
-- хитбоксу) -> с шансом тело разрубается. Разрез ровный, как у Z-City: само разделение, обрубки и травма -
-- sv_torsohalve.lua (hg.CutTorso). Косой разрез от точки удара пробовали - рисовался с багами, убран по просьбе.
-- Шанс всегда случайный: база по оружию, каждая прошлая рана туловища режущим оружием +20% (до x3);
-- ножам нужно много ударов (не меньше KNIFE_HITS прошлых ран). Заведённая бензопила с зажатой ЛКМ режет
-- наверняка - через SAW_TIME секунд непрерывного пиления одного и того же человека.
local cvOn = CreateConVar("rem_halve", "1", FCVAR_ARCHIVE, "Melee weapons can cut a person in half", 0, 1)
local cvMul = CreateConVar("rem_halve_chance", "1", FCVAR_ARCHIVE, "Multiplier for melee halving chances", 0, 100)

local CHANCE = {
	-- мечи - выше всех
	weapon_hg_katana = 0.12,
	weapon_hg_slayersword = 0.15,
	-- топоры
	weapon_hg_axe = 0.08,
	weapon_hatchet = 0.05,
	-- мачете
	weapon_hg_machete = 0.06,
	weapon_fc3_machete = 0.06,
	weapon_fc3_tribalknife = 0.06,
	-- лопата
	weapon_hg_shovel = 0.04,
	-- ножи - ниже всех и только после многих ударов
	weapon_buck200knife = 0.012,
	weapon_combatknife = 0.012,
	weapon_sogknife = 0.012,
	weapon_pocketknife = 0.008,
	weapon_hg_spear_knife = 0.015,
}
local KNIFE = {weapon_buck200knife = true, weapon_combatknife = true, weapon_sogknife = true, weapon_pocketknife = true, weapon_hg_spear_knife = true}
local KNIFE_HITS = 6
local CLUB_OK = {weapon_hg_shovel = true} -- лопата бьёт DMG_CLUB, но ребром рубит

local SAW_CLASS = "weapon_chainsaw"
local SAW_TIME = 5      -- секунд зажатой ЛКМ
local SAW_GAP = 0.6     -- перерыв дольше - пиление сначала

local function Owner(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent end
	local ply = hg.RagdollOwner and hg.RagdollOwner(ent) or ent:GetNWEntity("ply")
	if IsValid(ply) and ply:IsPlayer() then return ply end
	return nil
end

-- позиция кости: у регдолла - по физике, у стоящего игрока - по матрице костей
local function BonePos(ent, name)
	local b = ent:LookupBone(name)
	if not b then return nil end
	local m = ent:GetBoneMatrix(b)
	return m and m:GetTranslation() or ent:GetBonePosition(b)
end

-- удар пришёлся по туловищу? (между поясом и плечами, не по руке сбоку)
local function CutFromHit(body, hitPos)
	if not IsValid(body) or not hitPos then return nil end
	local P = BonePos(body, "ValveBiped.Bip01_Pelvis")
	local top = BonePos(body, "ValveBiped.Bip01_Spine4") or BonePos(body, "ValveBiped.Bip01_Spine2")
	local L, Rr = BonePos(body, "ValveBiped.Bip01_L_UpperArm"), BonePos(body, "ValveBiped.Bip01_R_UpperArm")
	if not (P and top and L and Rr) then return nil end
	local up = (top - P):GetNormalized()
	local right = Rr - L
	right = (right - up * right:Dot(up)):GetNormalized()
	local yArm = ((L + Rr) * 0.5 - P):Dot(up)
	local w = math.max((Rr - L):Dot(right) * 0.4, 3)
	local d = hitPos - P
	local x, y = d:Dot(right), d:Dot(up)
	if yArm < 5 or y < math.max(4, yArm * 0.28) - 7 or y > yArm + 5 or math.abs(x) > w * 1.8 then return nil end
	return true
end

-- только урон, нанесённый самим оружием (не кровотечение и т.п. от того, кто держит нож)
local function Weapon(dmg)
	local wep = dmg:GetInflictor()
	return (IsValid(wep) and wep:IsWeapon()) and wep or nil
end

-- режущее оружие Z-City (MultiDmg1) бьёт каждый тик, пока клинок идёт по телу: один взмах - десятки событий
-- урона. Бросок шанса и счёт ран - один раз за взмах (пауза SWING_GAP по этому человеку)
local SWING_GAP = 0.6

local function DoCut(target, attacker, cut, dmg)
	local dir = IsValid(attacker) and attacker:GetAimVector() or dmg:GetDamageForce():GetNormalized()
	local force = dir * 300
	timer.Simple(0, function()
		if not IsValid(target) or not hg.CutTorso then return end
		hg.CutTorso(target, force)
	end)
end

local function OnDamage(target, dmg)
	if not cvOn:GetBool() or not IsValid(target) then return end
	if not (target:IsPlayer() or target:IsRagdoll()) then return end
	-- один удар разбираем один раз (слушаем оба хука: урон по игроку может заблокировать обработчик Z-City)
	local tick = engine.TickCount()
	if target.__remHalveTick == tick and target.__remHalveAtt == dmg:GetAttacker() then return end
	target.__remHalveTick, target.__remHalveAtt = tick, dmg:GetAttacker()
	if target:GetNWBool("hgTorsoSevered", false) then return end
	local wep = Weapon(dmg)
	if not wep then return end
	local class = wep:GetClass()
	local saw = class == SAW_CLASS
	if not saw and not CHANCE[class] then return end
	if not (dmg:IsDamageType(DMG_SLASH) or (CLUB_OK[class] and dmg:IsDamageType(DMG_CLUB))) then return end

	local attacker = dmg:GetAttacker()
	local ply = Owner(target)
	if IsValid(ply) and ply == attacker then return end -- себя не режем
	if IsValid(ply) and ply:GetNWBool("hgTorsoSevered", false) and (target == ply or target == ply.FakeRagdoll) then return end

	local body = target
	if target:IsPlayer() then body = hg.GetCurrentCharacter and hg.GetCurrentCharacter(target) or target end
	local cut = CutFromHit(body, dmg:GetDamagePosition())

	-- бензопила: только заведённая и с зажатой ЛКМ, разрез через SAW_TIME с непрерывного пиления
	if saw then
		if not wep.ChainsawOn or not wep.ChainsawAttacking then return end
		local now = CurTime()
		local st = wep.__remSaw
		if not st or st.target ~= target or now - st.last > SAW_GAP then
			st = {target = target, start = now, last = now}
			wep.__remSaw = st
		end
		st.last = now
		st.cut = st.cut or cut -- пила хоть раз прошла по туловищу
		if now - st.start >= SAW_TIME and st.cut then
			wep.__remSaw = nil
			DoCut(target, attacker, st.cut, dmg)
		end
		return
	end

	if not cut then return end -- не по туловищу
	local holder = IsValid(ply) and ply or target
	local now = CurTime()
	wep.__remHalveNext = wep.__remHalveNext or setmetatable({}, {__mode = "k"})
	if (wep.__remHalveNext[holder] or 0) > now then return end
	wep.__remHalveNext[holder] = now + SWING_GAP
	local hits = holder.__remCutHits or 0
	holder.__remCutHits = hits + 1
	if KNIFE[class] and hits < KNIFE_HITS then return end
	local chance = CHANCE[class] * cvMul:GetFloat() * math.min(1 + hits * 0.2, 3)
	if math.random() < chance then DoCut(target, attacker, cut, dmg) end
end

hook.Add("EntityTakeDamage", "rem_meleehalve", function(target, dmg) OnDamage(target, dmg) end)
hook.Add("PostEntityTakeDamage", "rem_meleehalve", function(target, dmg) OnDamage(target, dmg) end)

-- проверка (админ): rem_halve_test - разрубить того, на кого смотришь
concommand.Add("rem_halve_test", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	if not IsValid(ply) then return end
	local tr = util.TraceLine({start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 300, filter = {ply, ply.FakeRagdoll}, mask = MASK_SHOT})
	local target = tr.Entity
	if not IsValid(target) or not (target:IsPlayer() or target:IsRagdoll()) then
		ply:ChatPrint("rem_halve_test: look at a player or a body")
		return
	end
	hg.CutTorso(target, ply:GetAimVector() * 300)
end)
