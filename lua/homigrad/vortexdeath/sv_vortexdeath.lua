-- Экран умирания "вихрь": когда ты вырублен и пошёл таймер смерти, с шансом (раньше последних моментов: 50 на 50 с ними)
-- таймер растягивается на всю песню rem_death_cfyt.ogg (~84 с), а клиент показывает красный вихрь (cl_vortexdeath.lua).
-- "Give up" (зажатый прыжок) - время смерти идёт в GiveUpSpeed раз быстрее.
hg.VortexDeath = hg.VortexDeath or {}
local VD = hg.VortexDeath

local chance = CreateConVar("zb_vortexdeath_chance", "50", FCVAR_ARCHIVE, "Chance (%) that the death timer turns into the red vortex dying screen with its song", 0, 100)
VD.Duration = 84
VD.GiveUpSpeed = 4

util.AddNetworkString("rem_vortexdeath_giveup")

resource.AddSingleFile("sound/rem_death_cfyt.ogg")
for _, name in ipairs({"vortex_swirl", "vortex_rays", "vortex_centre", "vortex_noise1", "vortex_noise2", "vortex_noise3", "vortex_noise4"}) do
	resource.AddSingleFile("materials/rem_death/" .. name .. ".png")
end
resource.AddSingleFile("resource/fonts/VT323-Regular.ttf")

local function Start(ply, org, now)
	org.deathStateEnd = now + VD.Duration
	ply:SetNWFloat("rem_vortex_start", now)
	ply:SetNWFloat("rem_vortex_until", org.deathStateEnd)
end

-- вызывается из sv_organism.lua в момент, когда таймер смерти только начался
function VD.OnDeathTimer(owner, org, now)
	if not IsValid(owner) or not owner:IsPlayer() then return end
	if hg.LastBattle and hg.LastBattle.IsActiveFor and hg.LastBattle.IsActiveFor(owner) then return end
	if math.Rand(0, 100) >= chance:GetFloat() then return end
	Start(owner, org, now)
end

local function Active(ply)
	return ply:GetNWFloat("rem_vortex_until", 0) > CurTime()
end

-- очнулся, умер или подняли - вихрь кончился
timer.Create("rem_vortexdeath", 0.5, 0, function()
	for _, ply in player.Iterator() do
		if ply:GetNWFloat("rem_vortex_until", 0) > 0 then
			local org = ply.organism
			local testing = (ply.remVortexTest or 0) > CurTime()
			if not ply:Alive() or not org or (not org.deathStateEnd and not testing) then
				ply:SetNWFloat("rem_vortex_until", 0)
			end
		end
	end
end)

-- "Give up": пока клиент держит прыжок, таймер смерти (и экран с песней) идут быстрее
net.Receive("rem_vortexdeath_giveup", function(len, ply)
	if not IsValid(ply) then return end
	ply.remVortexHold = net.ReadBool() or nil
end)

hook.Add("Think", "rem_vortexdeath_giveup", function()
	local dt = FrameTime()
	for _, ply in player.Iterator() do
		if ply.remVortexHold then
			if not ply:Alive() or not Active(ply) then
				ply.remVortexHold = nil
			else
				-- лишние (speed - 1) секунд за каждую секунду: сдвигаем конец таймера и начало экрана
				local skip = dt * (VD.GiveUpSpeed - 1)
				local org = ply.organism
				if org and org.deathStateEnd then org.deathStateEnd = org.deathStateEnd - skip end
				if ply.remVortexTest then ply.remVortexTest = ply.remVortexTest - skip end
				ply:SetNWFloat("rem_vortex_until", ply:GetNWFloat("rem_vortex_until", 0) - skip)
				ply:SetNWFloat("rem_vortex_start", ply:GetNWFloat("rem_vortex_start", 0) - skip)
			end
		end
	end
end)

COMMANDS = COMMANDS or {}
-- проверка: !vortexdeath - вихрь со звуком; если уже идёт таймер смерти - он растягивается
COMMANDS.vortexdeath = {function(ply, args)
	local org = ply.organism
	if not org or not ply:Alive() then return end

	local now = CurTime()
	if org.deathStateEnd then
		Start(ply, org, now)
	else
		ply:SetNWFloat("rem_vortex_start", now)
		ply:SetNWFloat("rem_vortex_until", now + VD.Duration)
	end
	ply.remVortexTest = now + VD.Duration
	ply:ChatPrint("Vortex dying screen started. Hold jump to give up faster.")
end, 1}

hook.Add("PlayerSpawn", "rem_vortexdeath", function(ply)
	ply.remVortexTest = nil
	ply.remVortexHold = nil
	ply:SetNWFloat("rem_vortex_until", 0)
end)
