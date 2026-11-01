-- Лечение как в Far Cry - сервер (описание в sh_fcheal.lua)
hg = hg or {}
hg.FCHeal = hg.FCHeal or {}
local FH = hg.FCHeal

util.AddNetworkString("rem_fcheal")

local COOLDOWN = 6
-- что даёт одно лечение
local HEAL = {
	blood = 700,      -- мл крови обратно (до 5000)
	health = 30,      -- здоровья
	painMul = 0.45,   -- боль умножается на это
}
FH.Heal = HEAL

local S = "weapons/fc_heals/"
local SOUNDS = {
	movement = {S .. "movement1.wav", S .. "movement2.wav", S .. "movement3.wav"},
	bleeding = {S .. "bleeding1.wav", S .. "bleeding2.wav", S .. "bleeding3.wav", "physics/flesh/flesh_squishy_impact_hard1.wav"},
	extract = {S .. "bullet_extract2.wav", S .. "bullet_extract3.wav", S .. "bullet_extract4.wav", "physics/flesh/flesh_impact_bullet3.wav"},
	mechanic = {S .. "mechanic_ins_01.ogg", S .. "mechanic_ins_02.ogg", S .. "mechanic_ins_05.ogg"},
	knifepush = {S .. "knife_push_attack1_heavy_01.wav", S .. "knife_push_attack1_heavy_02.wav", S .. "knife_push_attack1_heavy_03.wav", S .. "knife_push_attack1_heavy_04.wav"},
	dagger = {S .. "dagger_stab_00.wav", S .. "dagger_stab_01.wav", S .. "dagger_stab_02.wav", "physics/flesh/flesh_impact_bullet1.wav"},
	shamrock = {S .. "shamrock_ins_04.ogg"},
	pullout = {S .. "b_knife_pullout_quick.ogg", S .. "b_knife_pullout_first_2.ogg", "physics/flesh/flesh_impact_bullet2.wav"},
	syringe = {"items/medshot4.wav"},
	flesh = {"physics/flesh/flesh_impact_hard1.wav", "physics/flesh/flesh_impact_hard2.wav", "physics/flesh/flesh_impact_hard3.wav",
		"physics/flesh/flesh_impact_hard4.wav", "physics/flesh/flesh_impact_hard5.wav", "physics/flesh/flesh_impact_hard6.wav"},
	flame = {"ambient/fire/mtov_flame2.wav"},
	bone = {},
}
for i = 1, 19 do
	if i ~= 5 and i ~= 11 then table.insert(SOUNDS.bone, S .. "bone" .. i .. ".wav") end -- 5 и 11 в архиве битые
end
table.insert(SOUNDS.bone, "physics/body/body_medium_break2.wav")

-- из группы берём только то, что есть на диске (звуки FC - в контент-паке; если их нет - запасные из HL2)
local available = {}
local function Pick(group)
	local list = available[group]
	if not list then
		local fallback = {}
		list = {}
		for _, p in ipairs(SOUNDS[group] or {}) do
			if file.Exists("sound/" .. p, "GAME") then
				if string.StartWith(p, S) then list[#list + 1] = p else fallback[#fallback + 1] = p end
			end
		end
		if #list == 0 then list = fallback end
		available[group] = list
	end
	return list[math.random(#list)]
end

local function HasHealItem(ply)
	for _, w in ipairs(ply:GetWeapons()) do
		if w.FCHeal then return true end
	end
	return false
end

local function Injured(ply)
	if ply:IsOnFire() or ply:Health() < ply:GetMaxHealth() then return true end
	local org = ply.organism
	if not org then return false end
	if (org.wounds and #org.wounds > 0) or (org.arterialwounds and #org.arterialwounds > 0) then return true end
	if (org.blood or 5000) < 4900 or (org.avgpain or 0) > 15 or (org.internalBleed or 0) > 0.05 then return true end
	return org.larmdislocation or org.rarmdislocation or org.llegdislocation or org.rlegdislocation or org.jawdislocation or false
end

function FH.CanHeal(ply)
	if not IsValid(ply) or not ply:Alive() or IsValid(ply.FakeRagdoll) or ply:InVehicle() then return false end
	if ply.rem_fcheal or (ply.rem_fcheal_cd or 0) > CurTime() then return false end
	if hg.Takedown and hg.Takedown.ByEnt and hg.Takedown.ByEnt[ply] then return false end
	if ply.organism and ply.organism.otrub then return false end
	return HasHealItem(ply) and Injured(ply)
end

-- чем ранили последним (для выбора анимации)
hook.Add("EntityTakeDamage", "rem_fcheal_lastdmg", function(target, dmg)
	local ply = target
	if not ply:IsPlayer() then
		ply = target:IsRagdoll() and hg.RagdollOwner and hg.RagdollOwner(target)
		if not IsValid(ply) or not ply:IsPlayer() then return end
	end
	ply.rem_fcheal_dmg = dmg:GetDamageType()
end)

local function ChooseKind(ply)
	local org = ply.organism or {}
	local t = ply.rem_fcheal_dmg or 0
	local has = function(flag) return bit.band(t, flag) ~= 0 end
	if ply:IsOnFire() or has(DMG_BURN) or has(DMG_SLOWBURN) then return "burn" end
	if org.larmdislocation or org.rarmdislocation or org.llegdislocation or org.rlegdislocation or org.jawdislocation
		or has(DMG_FALL) or has(DMG_CRUSH) or has(DMG_CLUB) or has(DMG_VEHICLE) then return "disloc" end
	if has(DMG_BULLET) or has(DMG_BUCKSHOT) or has(DMG_SNIPER) or has(DMG_AIRBOAT) then return "bullet" end
	if has(DMG_BLAST) or has(DMG_BLAST_SURFACE) then return math.random(2) == 1 and "frag_a" or "frag_c" end
	if has(DMG_SLASH) then return "frag_c" end
	if org.arterialwounds and #org.arterialwounds > 0 then return "bullet" end
	return "syringe"
end

-- само лечение
local function ApplyHeal(ply, kind)
	local org = ply.organism
	if org then
		-- кровотечения остановлены (пуля вынута, рана зашита/прижжена)
		org.wounds = {}
		org.arterialwounds = {}
		for _, a in ipairs({"arteria", "rarmartery", "larmartery", "rlegartery", "llegartery", "spineartery"}) do
			if org[a] then org[a] = 0 end
		end
		ply:SetNetVar("wounds", org.wounds)
		ply:SetNetVar("arterialwounds", org.arterialwounds)
		org.internalBleed = (org.internalBleed or 0) * 0.5
		org.blood = math.min((org.blood or 5000) + HEAL.blood, 5000)
		org.avgpain = (org.avgpain or 0) * HEAL.painMul
		org.pain = (org.pain or 0) * HEAL.painMul
		org.painadd = 0
		if kind == "disloc" then
			org.larmdislocation, org.rarmdislocation, org.llegdislocation, org.rlegdislocation, org.jawdislocation = false, false, false, false, false
		end
	end
	if kind == "burn" or ply:IsOnFire() then ply:Extinguish() end
	ply:SetHealth(math.min(ply:Health() + HEAL.health, ply:GetMaxHealth()))
end

local function Finish(ply, healed)
	local st = ply.rem_fcheal
	if not st then return end
	st.finishing = true
	if IsValid(ply) and ply:Alive() then
		if IsValid(st.prev) and st.prev:GetOwner() == ply then
			ply:SelectWeapon(st.prev:GetClass())
		end
		ply:StripWeapon(st.class)
	end
	if ply.organism then ply.organism.allowholster = st.allowholster end
	ply.rem_fcheal = nil
	ply.rem_fcheal_cd = CurTime() + (healed and COOLDOWN or 1)
	ply:SetNW2Bool("rem_fcheal", false)
end

function FH.Start(ply)
	if not FH.CanHeal(ply) then return false end
	local kind = ChooseKind(ply)
	local data = FH.Kinds[kind]
	local class = "rem_fcheal_" .. kind
	local org = ply.organism

	local st = {kind = kind, class = class, prev = ply:GetActiveWeapon(), seq = data.seqs[math.random(#data.seqs)],
		allowholster = org and org.allowholster, start = CurTime()}
	ply.rem_fcheal = st
	-- пока лечимся, сборка не выбрасывает то, что нельзя убирать (NoHolster)
	if org then org.allowholster = true end

	local wep = ply:Give(class, true)
	if not IsValid(wep) then wep = ply:GetWeapon(class) end
	if not IsValid(wep) then
		if org then org.allowholster = st.allowholster end
		ply.rem_fcheal = nil
		return false
	end
	ply:SelectWeapon(class)
	-- руки лечения рисует клиент сам (cl_fcheal.lua): вид, анимация и когда началась
	ply:SetNW2String("rem_fcheal_kind", kind)
	ply:SetNW2String("rem_fcheal_seq", st.seq)
	ply:SetNW2Float("rem_fcheal_start", CurTime())
	ply:SetNW2Bool("rem_fcheal", true)

	for _, s in ipairs(data.snd) do
		timer.Simple(s[1], function()
			if ply.rem_fcheal ~= st then return end
			local snd = Pick(s[2])
			if snd then ply:EmitSound(snd, 65, 100, 1, CHAN_AUTO) end
			if s[3] then
				local ed = EffectData()
				ed:SetOrigin(ply:GetPos() + Vector(0, 0, 40))
				ed:SetNormal(ply:GetForward())
				util.Effect("BloodImpact", ed)
			end
		end)
	end
	timer.Simple(data.dur * 0.85, function()
		if ply.rem_fcheal ~= st or not IsValid(ply) or not ply:Alive() then return end
		ApplyHeal(ply, kind)
		st.healed = true
	end)
	timer.Simple(data.dur, function()
		if IsValid(ply) and ply.rem_fcheal == st then Finish(ply, st.healed) end
	end)
	return true
end

net.Receive("rem_fcheal", function(_, ply)
	FH.Start(ply)
end)

-- F: если можно лечиться (или уже лечимся) - фонарик не переключается
hook.Add("PlayerSwitchFlashlight", "rem_fcheal_f", function(ply, on)
	if ply.rem_fcheal or FH.CanHeal(ply) then return false end
end)

-- во время лечения оружие не сменить
hook.Add("PlayerSwitchWeapon", "rem_fcheal_lock", function(ply, old, new)
	local st = ply.rem_fcheal
	if st and not st.finishing and IsValid(old) and old:GetClass() == st.class and IsValid(new) and new:GetClass() ~= st.class then
		return true
	end
end)

-- упал / умер / сел в машину - лечение обрывается
hook.Add("Think", "rem_fcheal_watch", function()
	for _, ply in ipairs(player.GetAll()) do
		local st = ply.rem_fcheal
		if st and (not ply:Alive() or IsValid(ply.FakeRagdoll) or ply:InVehicle() or CurTime() - st.start > 10) then
			Finish(ply, false)
		end
	end
end)

-- временное оружие лечения не выпадает и не остаётся после смерти
hook.Add("PlayerDroppedWeapon", "rem_fcheal_nodrop", function(ply, wep)
	if IsValid(wep) and wep.FCHealWeapon then timer.Simple(0, function() if IsValid(wep) then wep:Remove() end end) end
end)
hook.Add("PlayerDeath", "rem_fcheal_death", function(ply)
	if ply.rem_fcheal then Finish(ply, false) end
end)
