-- Последние моменты: когда ты вырублен и пошёл таймер смерти, с шансом таймер растягивается на всю песню
-- (rem_theseareyourlastmoments.mp3, 1:12), а клиент показывает воспоминания - скриншоты жизни (cl_lastmoments.lua)
hg.LastMoments = hg.LastMoments or {}
local LM = hg.LastMoments

-- вихрь проверяется раньше (zb_dying_vortex_chance 50), так что при 100 здесь выходит 50 на 50.
-- Новое имя вместо zb_lastmoments_chance: старое значение (20) оставалось сохранённым в конфиге
local chance = CreateConVar("zb_dying_lastmoments_chance", "100", FCVAR_ARCHIVE, "Chance (%) that the death timer turns into your last moments: a song and memories for 1:12", 0, 100)
local duration = 72

resource.AddSingleFile("sound/rem_theseareyourlastmoments.mp3")
resource.AddSingleFile("materials/rem_death/vignette.png")
-- пиксельный шум и шрифт VT323 общие с вихрем: их раздаёт vortexdeath/sv_vortexdeath.lua

-- вызывается из sv_organism.lua в момент, когда таймер смерти только начался
function LM.OnDeathTimer(owner, org, now)
	if not IsValid(owner) or not owner:IsPlayer() then return end
	if hg.LastBattle and hg.LastBattle.IsActiveFor and hg.LastBattle.IsActiveFor(owner) then return end
	if math.Rand(0, 100) >= chance:GetFloat() then return end

	org.deathStateEnd = now + duration
	owner:SetNWFloat("rem_lastmoments_until", org.deathStateEnd)
end

-- очнулся (или последний бой поднял) - последние моменты кончились
timer.Create("rem_lastmoments", 0.5, 0, function()
	for _, ply in player.Iterator() do
		if ply:GetNWFloat("rem_lastmoments_until", 0) > 0 then
			local org = ply.organism
			local testing = (ply.remLastMomentsTest or 0) > CurTime()
			if not ply:Alive() or not org or (not org.deathStateEnd and not testing) then ply:SetNWFloat("rem_lastmoments_until", 0) end
		end
	end
end)

COMMANDS = COMMANDS or {}
-- проверка: !lastmoments - песня и воспоминания на 1:12; если уже идёт таймер смерти - он растягивается
COMMANDS.lastmoments = {function(ply, args)
	local org = ply.organism
	if not org or not ply:Alive() then return end

	local untilTime = CurTime() + duration
	if org.deathStateEnd then org.deathStateEnd = untilTime end
	ply.remLastMomentsTest = untilTime
	ply:SetNWFloat("rem_lastmoments_until", untilTime)
	ply:ChatPrint("Last moments started.")
end, 1}

hook.Add("PlayerSpawn", "rem_lastmoments", function(ply)
	ply.remLastMomentsTest = nil
	ply:SetNWFloat("rem_lastmoments_until", 0)
end)
