-- Инсульт: когда мозг сам слабеет до 92% (8% урона: нехватка кислорода, кровоизлияние), иногда при кровоизлиянии
-- в мозг или очень высоком давлении. От ударов - нет (по просьбе): если мозг перешёл порог сразу после урона,
-- инсульта не будет.
-- Картинка у игрока замирает и звучит rem_lobotomy.ogg (cl_stroke.lua), сам он падает и не может встать.
hg.Stroke = hg.Stroke or {}

util.AddNetworkString("rem_stroke")

local check_interval = 1
local stroke_cooldown = 180
local freeze_time = 6

local hit_grace = 5 -- столько секунд после урона порог мозга инсульт не вызывает
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
			ply.strokeThresholdDone = nil
			continue
		end

		local brain = org.brain or 0

		-- порог 92% срабатывает один раз, пока мозг снова не подлечат; перешёл от удара - не считается
		if brain < brain_threshold * 0.75 then ply.strokeThresholdDone = nil end
		local crossed = brain >= brain_threshold and not ply.strokeThresholdDone
		if crossed and now - (ply.strokeHitAt or -100) < hit_grace then
			ply.strokeThresholdDone = true
			crossed = false
		end

		if (ply.strokeCooldown or 0) > now then
			if crossed then ply.strokeThresholdDone = true end
			continue
		end

		if crossed then
			ply.strokeThresholdDone = true
			hg.Stroke.Trigger(ply)
		elseif (org.brainHemorrhage or 0) >= hemorrhage_threshold and math.Rand(0, 1) < hemorrhage_chance
			or (org.hypertension or 0) >= hypertension_threshold and math.Rand(0, 1) < hypertension_chance then
			hg.Stroke.Trigger(ply)
		end
	end
end)

-- от ударов инсульта нет: запоминаем время урона, чтобы порог мозга сразу после него не сработал
hook.Add("HomigradDamage", "rem_stroke_headhit", function(ply)
	if IsValid(ply) and ply:IsPlayer() then ply.strokeHitAt = CurTime() end
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
