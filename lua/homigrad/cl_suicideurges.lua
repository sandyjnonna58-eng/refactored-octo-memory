local lastPress = 0
local plainUntil = 0
local flashRed = 0
local wasActive = false
local wasSelfHarmActive = false
local urgeSound

local refuseFovTarget = 0
local refuseFov = 0

local refuseSnd = nil
local refusePitch = 100
local refuseLastCall = 0

net.Receive("rem_suicide_attempt", function()
	local frac = net.ReadFloat() or 0
	local now = CurTime()

	if now - refuseLastCall > 2 then
		refusePitch = 100
	end

	refuseLastCall = now

	refusePitch = math.max(refusePitch - 5, 60)

	if not refuseSnd then
		refuseSnd = CreateSound(LocalPlayer(), "rem_refuse.mp3")
	end

	refuseSnd:Stop()
	refuseSnd:PlayEx(1, refusePitch)

	refuseFovTarget = 1

	hg.CreateShakyNotification(frac >= 0.45 and "Just do it." or "You shouldnt do this.", 1.5, frac)
end)

hook.Add("HG_CalcView", "REM_SuicideRefuseFov", function(ply, origin, angles, fova)
	if not istable(fova) then return end
	if refuseFov > 0.001 and ply ~= LocalPlayer() then return end

	fova[1] = fova[1] - refuseFov * 18
end)

hook.Add("Think", "REM_SuicideRefuseFovThink", function()
	local target = refuseFovTarget > 0 and 1 or 0

	refuseFov = LerpFT(0.04, refuseFov, target)
	refuseFovTarget = math.max(refuseFovTarget - FrameTime() * 1.6, 0)
end)

local urgeLoopPath = "sound/rem_earsringaswounddeepens.ogg"
local urgeLoop = nil
local urgeLoopLoading = false
local urgeLoopVol = 0
local urgeLoopFadeSpeed = 1.2

local function ensureUrgeLoop()
	if IsValid(urgeLoop) or urgeLoopLoading then return end

	urgeLoopLoading = true
	sound.PlayFile(urgeLoopPath, "noblock noplay", function(station, errCode, errStr)
		urgeLoopLoading = false

		if not IsValid(station) then return end

		station:SetVolume(0)
		station:Play()
		station:EnableLooping(true)
		urgeLoop = station
	end)
end

local function stopUrgeLoop()
	urgeLoopVol = 0

	if IsValid(urgeLoop) then
		urgeLoop:Stop()
	end

	urgeLoop = nil
end

local function updateUrgeLoop(active)
	if active then
		ensureUrgeLoop()
	elseif IsValid(urgeLoop) and urgeLoopVol <= 0.01 then
		stopUrgeLoop()
		return
	end

	if not IsValid(urgeLoop) then return end

	local target = active and 1 or 0
	urgeLoopVol = math.Approach(urgeLoopVol, target, FrameTime() * urgeLoopFadeSpeed)
	urgeLoop:SetVolume(urgeLoopVol)
end

local flashMat = Material("vgui/flash.png")
local flashFade = 0

local function stopUrges()
	if urgeSound then
		urgeSound:Stop()
		urgeSound = nil
	end

	wasActive = false
end

net.Receive("rem_selfharm_end", function()
	flashFade = 1
	surface.PlaySound("rem_enditall.mp3")
end)

net.Receive("rem_urges_end", function()
	flashFade = 1
	surface.PlaySound("rem_enditall.mp3")
end)

-- позыв проигран: оружие у головы, звенит в ушах
net.Receive("rem_urges_lost", function()
	stopUrgeLoop()
	sound.PlayFile(urgeLoopPath, "noblock", function(station)
		if IsValid(station) then station:Play() end
	end)
end)

hook.Add("PlayerButtonDown", "REM_UrgesPress", function(ply, button)
	if ply ~= LocalPlayer() or button ~= KEY_E then return end

	local selfharmEnd = ply:GetNWFloat("rem_selfharm_wave_end", 0)
	if selfharmEnd > CurTime() then
		lastPress = CurTime()
		plainUntil = CurTime() + 0.1

		net.Start("rem_selfharm_press")
		net.SendToServer()
		return
	end

	if ply:GetNWFloat("rem_urges_end", 0) < CurTime() then return end

	lastPress = CurTime()
	plainUntil = CurTime() + 0.1

	net.Start("rem_urges_press")
	net.SendToServer()
end)

local function drawResistText(text, x, y)
	local pressAmt = math.max(1 - (CurTime() - lastPress) / 0.25, 0)
	local col = Color(255, 255 - 255 * pressAmt, 255 - 255 * pressAmt, 255)

	draw.SimpleText(text, "HomigradFontGigantoNormous", x, y, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

hook.Add("HUDPaint", "REM_SuicideUrges", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then
		stopUrges()
		stopUrgeLoop()
		return
	end

	local now = CurTime()
	local drew = false

	local selfHarmEnd = ply:GetNWFloat("rem_selfharm_wave_end", 0)
	if selfHarmEnd > now then
		drew = true

		if not wasSelfHarmActive then
			wasSelfHarmActive = true
		end

		local text = now < plainUntil and "E FIGHT THE URGE" or ">E< FIGHT THE URGE"
		drawResistText(text, ScrW() / 2 + math.random(-4, 4), ScrH() / 2 + ScrH() * 0.12 + math.random(-3, 3))
	elseif wasSelfHarmActive then
		wasSelfHarmActive = false
		lastPress = 0
	end

	local endT = ply:GetNWFloat("rem_urges_end", 0)
	if endT > now then
		drew = true

		if not wasActive then
			wasActive = true
			flashRed = 1

			if not urgeSound then
				urgeSound = CreateSound(LocalPlayer(), "rem_resisttheurges.mp3")
				urgeSound:Play()
			end
		end

		local text = now < plainUntil and "RESIST THE URGES" or ">E< RESIST THE URGES"
		drawResistText(text, ScrW() / 2 + math.random(-4, 4), ScrH() / 2 + ScrH() * 0.12 + math.random(-3, 3))
	end

	local pendingT = ply:GetNWFloat("rem_selfharm_pending", 0)
	local minigameActive = selfHarmEnd > now or endT > now or pendingT > now

	updateUrgeLoop(minigameActive)

	if not drew then
		stopUrges()
	end

	if flashRed > 0 then
		surface.SetDrawColor(255, 0, 0, 255 * flashRed)
		surface.DrawRect(0, 0, ScrW(), ScrH())
		flashRed = math.max(flashRed - FrameTime() * 3, 0)
	end

	if flashFade > 0 then
		surface.SetDrawColor(255, 255, 255, 255 * flashFade)
		surface.SetMaterial(flashMat)
		surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		flashFade = math.max(flashFade - FrameTime(), 0)
	end
end)

-- шёпот, пока оружие у головы; после проигранного позыва курок жмёт сам игрок
surface.CreateFont("Rem_SuicideWhisper", {
	font = "Lora",
	size = ScreenScale(14),
	weight = 700,
	antialias = true,
	extended = true,
})

local whisperTexts = {
	"Worthless.",
	"No one will remember you.",
	"Mistake of nature.",
	"Nobody cares.",
	"You are nothing.",
	"They are better off without you.",
	"Just do it.",
	"Pull the trigger.",
}

local whisper_life = 2.6
local whisper_interval_max = 1.4
local whisper_interval_min = 0.35
local whisper_ramp_time = 8

local whispers = {}
local nextWhisper = 0
local whisperStart
local lastWhisperText

local function spawnWhisper(now)
	local text
	repeat
		text = whisperTexts[math.random(#whisperTexts)]
	until text ~= lastWhisperText or #whisperTexts < 2
	lastWhisperText = text

	-- не в центре экрана, чтобы не закрывать подсказку
	local x, y
	repeat
		x = math.Rand(0.12, 0.88) * ScrW()
		y = math.Rand(0.12, 0.88) * ScrH()
	until math.abs(x - ScrW() / 2) > ScrW() * 0.18 or math.abs(y - ScrH() / 2) > ScrH() * 0.16

	whispers[#whispers + 1] = {text = text, x = x, y = y, start = now}
end

local whisperColor = Color(255, 255, 255)

hook.Add("HUDPaint", "REM_SuicideWhispers", function()
	local ply = LocalPlayer()
	local now = CurTime()
	local active = IsValid(ply) and ply:Alive() and ply:GetNWBool("suiciding", false)

	if active then
		whisperStart = whisperStart or now
		if now >= nextWhisper then
			spawnWhisper(now)
			local ramp = math.Clamp((now - whisperStart) / whisper_ramp_time, 0, 1)
			nextWhisper = now + Lerp(ramp, whisper_interval_max, whisper_interval_min) * math.Rand(0.7, 1.3)
		end
	else
		whisperStart = nil
	end

	for i = #whispers, 1, -1 do
		local w = whispers[i]
		local t = (now - w.start) / whisper_life
		if t >= 1 or not active and t > 0.5 then
			table.remove(whispers, i)
		else
			local alpha = math.sin(t * math.pi) * 230
			local red = math.Clamp(t * 2, 0, 1) * 200
			whisperColor.r = 255
			whisperColor.g = 255 - red
			whisperColor.b = 255 - red
			whisperColor.a = alpha
			draw.SimpleText(w.text, "Rem_SuicideWhisper", w.x + math.Rand(-2, 2), w.y + math.Rand(-2, 2), whisperColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end

	if not active or ply:GetNWFloat("rem_suicide_hold", 0) <= now or ply:GetNWFloat("rem_urges_end", 0) > now then return end

	local wep = ply:GetActiveWeapon()
	local melee = IsValid(wep) and (wep.ismelee2 or wep.Base == "weapon_melee" or wep.ClawSuicide)
	local left = math.ceil(ply:GetNWFloat("rem_suicide_hold", 0) - now)
	drawResistText((melee and "DO IT" or "PULL THE TRIGGER") .. " " .. left, ScrW() / 2 + math.random(-4, 4), ScrH() / 2 + ScrH() * 0.12 + math.random(-3, 3))
end)

-- музыка суицида: пока оружие у головы/горла (своя поза после позыва и обычный суицид оружием);
-- выжил - затихает, умер - обрывается быстро (дальше свой звук у экрана смерти)
local suicideMusicPath = "sound/rem_aftermath.mp3"
local suicideMusicFadeIn = 0.6
local suicideMusicFadeOut = 2
local suicideMusicFadeDeath = 0.5

local suicideMusic
local suicideMusicLoading = false
local suicideMusicVol = 0
local suicideMusicWanted = false
local MusicVolume = GetConVar("snd_musicvolume")

hook.Add("Think", "REM_SuicideMusic", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local alive = ply:Alive()
	suicideMusicWanted = alive and (ply:GetNWBool("suiciding", false) or ply:GetNWFloat("rem_suicide_hold", 0) > CurTime())

	if suicideMusicWanted and not IsValid(suicideMusic) and not suicideMusicLoading then
		suicideMusicLoading = true
		sound.PlayFile(suicideMusicPath, "noblock noplay", function(station)
			suicideMusicLoading = false
			if not IsValid(station) then return end
			if not suicideMusicWanted then station:Stop() return end

			suicideMusic = station
			suicideMusicVol = 0
			station:EnableLooping(true)
			station:SetVolume(0)
			station:Play()
		end)
	end

	if not IsValid(suicideMusic) then return end

	local dt = FrameTime()
	if suicideMusicWanted then
		suicideMusicVol = math.min(suicideMusicVol + dt / suicideMusicFadeIn, 1)
	else
		suicideMusicVol = suicideMusicVol - dt / (alive and suicideMusicFadeOut or suicideMusicFadeDeath)
		if suicideMusicVol <= 0 then
			suicideMusic:Stop()
			suicideMusic = nil
			return
		end
	end

	suicideMusic:SetVolume(suicideMusicVol * MusicVolume:GetFloat())
end)
