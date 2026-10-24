-- Радиальное размытие при попаданиях и взрывах; вспышка-удар (тёмный взрыв из лучей, materials/rem_fx/hit_burst.png,
-- и радужный светящийся контур вокруг него, materials/rem_fx/hit_glow.png)
-- только при очень сильном ударе по голове или когда ломается череп. Рисует cl_screenfx.lua.
util.AddNetworkString("rem_fx_kick")
util.AddNetworkString("rem_fx_burst")

local burst_cooldown = 0.15
-- очень сильный удар по голове за одно попадание: тупой (бита, лом ~20-33) и любой другой
local burst_head_blunt = 25
local burst_head_other = 40
local burst_damage_full = 60
local skull_check_interval = 0.1

resource.AddSingleFile("materials/rem_fx/hit_burst.png")
resource.AddSingleFile("materials/rem_fx/hit_glow.png")

local function SendBurst(ply, strength)
	if (ply.remFxNextBurst or 0) > CurTime() then return end
	ply.remFxNextBurst = CurTime() + burst_cooldown

	net.Start("rem_fx_burst", true)
		net.WriteFloat(strength)
	net.Send(ply)
end

local kick_cooldown = 0.1
local hit_damage_full = 40
-- удар от другого игрока размывает сильнее, чем падение или NPC
local player_hit_mul = 1.8
local player_hit_min = 0.5
local blast_radius = 600

local function SendKick(ply, strength, pos)
	if (ply.remFxNextKick or 0) > CurTime() then return end
	ply.remFxNextKick = CurTime() + kick_cooldown

	net.Start("rem_fx_kick", true)
		net.WriteFloat(strength)
		net.WriteBool(pos ~= nil)
		if pos then net.WriteVector(pos) end
	net.Send(ply)
end

hook.Add("HomigradDamage", "rem_fx_kick", function(ply, dmgInfo, hitgroup)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	if dmgInfo:IsDamageType(DMG_BLAST) then return end

	local strength = math.Clamp(dmgInfo:GetDamage() / hit_damage_full, 0.2, 1)
	local attacker = dmgInfo:GetAttacker()

	if hitgroup == HITGROUP_HEAD then
		local blunt = dmgInfo:IsDamageType(DMG_CLUB) or dmgInfo:IsDamageType(DMG_CRUSH)
		if dmgInfo:GetDamage() >= (blunt and burst_head_blunt or burst_head_other) then
			SendBurst(ply, math.Clamp(dmgInfo:GetDamage() / burst_damage_full, 0.7, 1))
		end
	end

	-- размытие идёт от того, кто ударил
	if IsValid(attacker) and attacker:IsPlayer() and attacker ~= ply then
		SendKick(ply, math.max(strength, player_hit_min) * player_hit_mul, attacker:EyePos())
		return
	end

	SendKick(ply, strength)
end)

-- взрыв: размытие из точки взрыва у всех, кто рядом, даже без урона
hook.Add("EntityTakeDamage", "rem_fx_kick", function(ent, dmgInfo)
	if not dmgInfo:IsDamageType(DMG_BLAST) then return end

	-- граната/бочка точнее, чем позиция урона
	local inflictor = dmgInfo:GetInflictor()
	local pos = (IsValid(inflictor) and not inflictor:IsPlayer() and not inflictor:IsWorld()) and inflictor:WorldSpaceCenter() or dmgInfo:GetDamagePosition()
	if pos:IsZero() then return end

	for _, ply in player.Iterator() do
		local dist = ply:EyePos():Distance(pos)
		if ply:Alive() and dist < blast_radius then SendKick(ply, 1.5 * (1 - dist / blast_radius) + 0.3, pos) end
	end
end)

-- череп сломался (org.skull дошёл до 1) - вспышка на полную, мимо кулдауна
timer.Create("rem_fx_skull", skull_check_interval, 0, function()
	for _, ply in player.Iterator() do
		local org = ply.organism
		local skull = (ply:Alive() and org and org.skull) or 0

		if skull >= 1 and (ply.remFxLastSkull or 0) < 1 then
			ply.remFxNextBurst = 0
			SendBurst(ply, 1)
		end

		ply.remFxLastSkull = skull
	end
end)

-- Мозговая травма (рисует cl_screenfx.lua): blur, хроматическая аберрация, depth blur 1 и 2, серость по глубине,
-- зерно, постеризация, VHS. Пока сломан череп и идёт лоботомия (урон мозгу > 10%) - держится постоянно;
-- если лоботомия уже 33% и прилетает удар по голове - приступ на trauma_hit_time секунд.
-- "Лоботомия" = org.brain, как у админской кнопки Lobotomize.
local trauma_lobotomy = 0.1
local trauma_hit_brain = 0.33
local trauma_hit_min_damage = 5
local trauma_hit_time = 10

for _, name in ipairs({"blur", "depthblur", "filmgrain", "posterize", "vhs1"}) do
	resource.AddSingleFile("materials/effects/shaders/merc_" .. name .. ".vmt")
	resource.AddSingleFile("shaders/fxc/merc_" .. name .. "_ps20b.vcs")
end

timer.Create("rem_fx_braintrauma", 0.25, 0, function()
	for _, ply in player.Iterator() do
		local org = ply.organism
		local active = ply:Alive() and org and (org.skull or 0) >= 1 and (org.brain or 0) > trauma_lobotomy or false
		if ply:GetNWBool("rem_braintrauma", false) ~= active then ply:SetNWBool("rem_braintrauma", active) end
	end
end)

hook.Add("HomigradDamage", "rem_fx_braintrauma", function(ply, dmgInfo, hitgroup)
	if hitgroup ~= HITGROUP_HEAD or not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	if dmgInfo:GetDamage() < trauma_hit_min_damage then return end

	local org = ply.organism
	if not org or (org.brain or 0) < trauma_hit_brain then return end

	ply:SetNWFloat("rem_braintrauma_until", CurTime() + trauma_hit_time)
end)

-- проверка: !braintrauma [секунды] [ник] - сразу эффект мозговой травмы; !breakskull [ник] - сломать череп
local function FindTarget(ply, name)
	if not name or name == "" then return ply end

	for _, other in player.Iterator() do
		if string.find(string.lower(other:Nick()), string.lower(name), 1, true) then return other end
	end
end

COMMANDS = COMMANDS or {}

COMMANDS.braintrauma = {function(ply, args)
	local seconds = math.Clamp(tonumber(args[1]) or trauma_hit_time, 1, 120)
	local target = FindTarget(ply, args[2])
	if not IsValid(target) then ply:ChatPrint("Player not found.") return end

	target:SetNWFloat("rem_braintrauma_until", CurTime() + seconds)
	ply:ChatPrint("Brain trauma effect for " .. target:Nick() .. ": " .. seconds .. "s")
end, 1, "seconds; player"}

COMMANDS.breakskull = {function(ply, args)
	local target = FindTarget(ply, args[1])
	local org = IsValid(target) and target.organism
	if not org then ply:ChatPrint("Player not found.") return end

	org.skull = 1
	ply:ChatPrint(target:Nick() .. "'s skull is broken (with brain damage over 10% the trauma effect stays on).")
end, 1, "player"}
