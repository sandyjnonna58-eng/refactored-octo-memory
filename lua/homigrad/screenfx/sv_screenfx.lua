-- Радиальное размытие при попаданиях и взрывах (рисует cl_screenfx.lua)
util.AddNetworkString("rem_fx_kick")

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

hook.Add("HomigradDamage", "rem_fx_kick", function(ply, dmgInfo)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	if dmgInfo:IsDamageType(DMG_BLAST) then return end

	local strength = math.Clamp(dmgInfo:GetDamage() / hit_damage_full, 0.2, 1)
	local attacker = dmgInfo:GetAttacker()

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
