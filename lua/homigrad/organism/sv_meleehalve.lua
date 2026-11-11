-- Горизонтальное разрубание пополам оружием ближнего боя (по рисунку пользователя).
-- Удар режущим/рубящим оружием по туловищу -> с шансом тело разрезается: начало разреза - точно место удара
-- (по хитбоксу), конец - случайная точка на другом боку, не ниже пояса (от подмышки до подмышки и наискось вниз).
-- Само разделение, обрубки и травма - sv_torsohalve.lua (hg.CutTorso), косой срез на клиенте - cl_torsocut.lua.
-- Шанс всегда случайный: база по оружию, каждая прошлая рана туловища режущим оружием +20% (до x3);
-- ножам нужно много ударов (не меньше KNIFE_HITS прошлых ран). Заведённая бензопила с зажатой ЛКМ режет
-- наверняка - через SAW_TIME секунд непрерывного пиления одного и того же человека.
local cvOn = CreateConVar("rem_halve", "1", FCVAR_ARCHIVE, "Melee weapons can cut a person in half (diagonal torso cut)", 0, 1)
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

-- точка удара -> разрез в координатах торса (hg.TorsoFrame); nil - удар не по туловищу
local function CutFromHit(body, hitPos)
	local f = hg.TorsoFrame and hg.TorsoFrame(body)
	if not f or not hitPos then return nil end
	local d = hitPos - f.P
	local x, y = d:Dot(f.right), d:Dot(f.up)
	local yLow, yHigh = math.max(4, f.yArm * 0.28), f.yArm - 3 -- пояс .. подмышки
	if y < yLow - 7 or y > f.yArm + 5 or math.abs(x) > f.w * 1.8 then return nil end
	local sx = math.Clamp(x, -f.w, f.w)
	if math.abs(sx) < 0.5 then sx = (math.random(2) == 1 and -0.5 or 0.5) end
	local sy = math.Clamp(y, yLow, yHigh)
	local ex = sx > 0 and -f.w or f.w
	local ey = math.Rand(yLow, yHigh)
	return {sx / f.w, sy / f.yArm, ex / f.w, ey / f.yArm}
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
		hg.CutTorso(target, force, cut)
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
		st.cut = st.cut or cut -- начало разреза - там, где пила вошла в туловище
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

-- проверка (админ): rem_halve_test - разрубить того, на кого смотришь (точка разреза - куда смотришь)
concommand.Add("rem_halve_test", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	if not IsValid(ply) then return end
	local tr = util.TraceLine({start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 300, filter = {ply, ply.FakeRagdoll}, mask = MASK_SHOT})
	local target = tr.Entity
	if not IsValid(target) or not (target:IsPlayer() or target:IsRagdoll()) then
		ply:ChatPrint("rem_halve_test: look at a player or a body")
		return
	end
	local body = target:IsPlayer() and hg.GetCurrentCharacter and hg.GetCurrentCharacter(target) or target
	local cut = CutFromHit(body, tr.HitPos)
	if not cut then
		local side = math.random(2) == 1 and -1 or 1
		cut = {side * 0.8, math.Rand(0.45, 0.8), -side, math.Rand(0.3, 0.8)}
	end
	hg.CutTorso(target, ply:GetAimVector() * 300, cut)
end)
