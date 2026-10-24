-- Голоса (rem_theytalktoyou.mp3, cl_voices.lua): при высокой депрессии иногда, когда вокруг спокойно,
-- и всегда, когда начинается позыв к суициду (sv_suicideurges.lua). Немного пугают.
hg.Voices = hg.Voices or {}
local V = hg.Voices

util.AddNetworkString("rem_voices")
resource.AddSingleFile("sound/rem_theytalktoyou.mp3")

local depression_threshold = 0.6
-- "спокойно": нет свежего раздражителя страха и сам страх невысокий
local calm_fearadd = 0.05
local calm_fear = 0.3
local gap_min, gap_max = 120, 300
local check_interval = 5
-- чтобы два раза подряд не накладывались (звук 12.6 с)
local replay_cooldown = 15
local fear_add = 0.3

function V.Play(ply)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	if (ply.remVoicesNext or 0) > CurTime() then return end
	ply.remVoicesNext = CurTime() + replay_cooldown

	net.Start("rem_voices")
	net.Send(ply)

	local org = ply.organism
	if org then org.fearadd = (org.fearadd or 0) + fear_add end
end

timer.Create("rem_voices", check_interval, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		local org = ply.organism
		if not ply:Alive() or not org or org.otrub or (org.depression or 0) < depression_threshold then
			ply.remVoicesDue = nil
			continue
		end

		ply.remVoicesDue = ply.remVoicesDue or now + math.Rand(gap_min, gap_max)
		if now < ply.remVoicesDue then continue end
		if (org.fearadd or 0) > calm_fearadd or (org.fear or 0) > calm_fear then continue end

		ply.remVoicesDue = now + math.Rand(gap_min, gap_max)
		V.Play(ply)
	end
end)

-- проверка: !voices [ник]
COMMANDS = COMMANDS or {}
COMMANDS.voices = {function(ply, args)
	local target = ply
	if args[1] then
		target = nil
		for _, other in player.Iterator() do
			if string.find(string.lower(other:Nick()), string.lower(args[1]), 1, true) then target = other break end
		end
	end

	if not IsValid(target) then ply:ChatPrint("Player not found.") return end
	target.remVoicesNext = 0
	V.Play(target)
	ply:ChatPrint("Voices: " .. target:Nick())
end, 1, "player"}
