AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

DEFINE_BASECLASS("ent_calm_radio")

resource.AddSingleFile("materials/entities/ent_loud_radio.png")
for _, track in ipairs(ENT.Playlist) do resource.AddSingleFile(track.path) end

-- за секунду у самого радио (на краю радиуса - меньше)
local pain_per_second = 1.5
local ring_interval = 2
-- сколько "секунд у самого радио" выдерживают перепонки
local eardrum_exposure = 15
local exposure_decay = 0.5
-- лоботомия у радио: урон мозгу в секунду и до какого значения оно может довести
local lobotomy_per_second = 0.006
local lobotomy_cap = 0.4
local burst_ring_interval = 8
local notify_cooldown = 45

local colLoud = Color(255, 120, 120)

function ENT:Initialize()
	BaseClass.Initialize(self)
	self:SetColor(Color(170, 40, 40))
end

-- на рандом, но не тот же трек два раза подряд
function ENT:NextTrackIndex()
	local count = #self.Playlist
	if count < 2 then return 1 end

	local index = math.random(count - 1)
	if index >= self:GetTrack() then index = index + 1 end
	return index
end

function ENT:RadioEffect(ply, org, frac)
	local now = CurTime()
	ply.loudRadioLast = now
	ply.loudExposure = (ply.loudExposure or 0) + frac

	if (ply.loudNextRing or 0) < now then
		ply.loudNextRing = now + ring_interval
		ply:AddTinnitus(0.4 + frac * 0.6)
	end

	org.painadd = (org.painadd or 0) + pain_per_second * frac

	if not ply.remEardrumsBurst and ply.loudExposure >= eardrum_exposure then
		ply.remEardrumsBurst = true
		ply:AddTinnitus(5, true)
		org.painadd = org.painadd + 20
		ply:Notify("Your eardrums burst.", 0, "loud_radio_eardrums", 4, nil, colLoud)
	end

	-- совсем рядом бас бьёт по мозгу
	local lobFrac = math.Clamp((frac - (1 - self.LobotomyRange / self.CalmRange)) / (self.LobotomyRange / self.CalmRange), 0, 1)
	if lobFrac > 0 and (org.brain or 0) < lobotomy_cap then
		org.brain = math.min((org.brain or 0) + lobotomy_per_second * lobFrac, lobotomy_cap)

		if (ply.loudNotify or 0) < now then
			ply.loudNotify = now + notify_cooldown
			ply:Notify("The bass is tearing your brain apart.", 0, "loud_radio_brain", 3, nil, colLoud)
		end
	end
end

-- вне радиуса перепонки отходят; лопнувшие - звенят до смерти
timer.Create("rem_loud_radio", 1, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		if (ply.loudRadioLast or 0) < now - 1.5 and (ply.loudExposure or 0) > 0 then
			ply.loudExposure = math.max(ply.loudExposure - exposure_decay, 0)
		end

		if ply.remEardrumsBurst and ply:Alive() and (ply.loudBurstRing or 0) < now then
			ply.loudBurstRing = now + burst_ring_interval
			ply:AddTinnitus(burst_ring_interval / 4 + 0.5)
		end
	end
end)

local function Reset(ply)
	ply.remEardrumsBurst = nil
	ply.loudExposure = 0
end

hook.Add("PlayerDeath", "rem_loud_radio", Reset)
hook.Add("PlayerSpawn", "rem_loud_radio", Reset)
