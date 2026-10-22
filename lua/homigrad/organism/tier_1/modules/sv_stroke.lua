-- Инсульт: от сильного удара в голову, когда мозг падает до 92% (8% урона), после резкого урона мозгу,
-- иногда при кровоизлиянии в мозг или очень высоком давлении.
-- Картинка у игрока замирает и звучит rem_lobotomy.ogg (cl_stroke.lua), сам он падает и не может встать.
hg.Stroke = hg.Stroke or {}

util.AddNetworkString("rem_stroke")

local check_interval = 1
local stroke_cooldown = 180
local freeze_time = 6

local trauma_jump = 0.15
-- org.brain - урон мозгу (0 - здоров, с 0.6 встаёт сердце): 92% мозга = 0.08 урона
local brain_threshold = 0.08
-- сильный удар в голову за одно попадание: тупой удар (бита, лом, сковорода ~20-33 урона) и всё остальное
local head_hit_blunt = 25
local head_hit_other = 40
local hemorrhage_threshold = 0.35
local hemorrhage_chance = 0.03
local hypertension_threshold = 0.75
local hypertension_chance = 0.004

local stroke_brain_damage = 0.08
local stroke_hemorrhage = 0.05

function hg.Stroke.Trigger(ply)
	local org = ply.organism
	if not org or not ply:Alive() then return end

	ply.strokeCooldown = CurTime() + stroke_cooldown

	org.brain = math.min((org.brain or 0) + stroke_brain_damage, 1)
	org.brainHemorrhage = math.min((org.brainHemorrhage or 0) + stroke_hemorrhage, 1)
	org.disorientation = math.max(org.disorientation or 0, 4)
	hg.StunPlayer(ply, freeze_time)

	net.Start("rem_stroke")
		net.WriteFloat(freeze_time)
	net.Send(ply)
end

timer.Create("rem_stroke_check", check_interval, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		local org = ply.organism
		if not ply:Alive() or not org or not org.alive then
			ply.strokeLastBrain = nil
			ply.strokeThresholdDone = nil
			continue
		end

		local brain = org.brain or 0
		local jump = brain - (ply.strokeLastBrain or brain)
		ply.strokeLastBrain = brain

		-- порог 92% срабатывает один раз, пока мозг снова не подлечат
		if brain < brain_threshold * 0.75 then ply.strokeThresholdDone = nil end
		local crossed = brain >= brain_threshold and not ply.strokeThresholdDone

		if (ply.strokeCooldown or 0) > now then
			if crossed then ply.strokeThresholdDone = true end
			continue
		end

		if crossed then
			ply.strokeThresholdDone = true
			hg.Stroke.Trigger(ply)
		elseif jump >= trauma_jump
			or (org.brainHemorrhage or 0) >= hemorrhage_threshold and math.Rand(0, 1) < hemorrhage_chance
			or (org.hypertension or 0) >= hypertension_threshold and math.Rand(0, 1) < hypertension_chance then
			hg.Stroke.Trigger(ply)
		end
	end
end)

hook.Add("HomigradDamage", "rem_stroke_headhit", function(ply, dmgInfo, hitgroup)
	if hitgroup ~= HITGROUP_HEAD or not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	if (ply.strokeCooldown or 0) > CurTime() then return end

	local blunt = dmgInfo:IsDamageType(DMG_CLUB) or dmgInfo:IsDamageType(DMG_CRUSH)
	if dmgInfo:GetDamage() < (blunt and head_hit_blunt or head_hit_other) then return end

	-- после урона мозг тоже перешёл бы порог - не даём сработать второй раз
	ply.strokeThresholdDone = true
	hg.Stroke.Trigger(ply)
end)

COMMANDS = COMMANDS or {}
COMMANDS.stroke = {function(ply, args)
	local target = ply
	if args[1] then
		target = nil
		for _, other in player.Iterator() do
			if string.find(string.lower(other:Nick()), string.lower(args[1]), 1, true) then target = other break end
		end
	end

	if not IsValid(target) then ply:ChatPrint("Player not found.") return end
	hg.Stroke.Trigger(target)
	ply:ChatPrint("Stroke: " .. target:Nick())
end, 1, "player"}
