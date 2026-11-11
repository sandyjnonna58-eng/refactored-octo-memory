hg.LastBattle = hg.LastBattle or {}
local LB = hg.LastBattle

-- Начало последнего боя (как на видео): экран проваливается в темноту - тёмный туннель, всё блекнет и плывёт, по
-- центру красное "Not like this."; потом удар сердца - и сквозь серую зернистую засветку возвращается мир.
-- Таймера на экране нет: бой идёт, пока играет музыка.
local INTRO = {
	dark = 1.3,              -- за сколько темнеет
	textIn = 0.9, textOut = 3.7, textFade = 0.45,
	wake = 3.9,              -- удар сердца, начинается засветка
	wakeLen = 2.4,           -- за сколько засветка уходит
	total = 6.4,
}
local TEXT = "Not like this."

surface.CreateFont("RemLastStandText", {
	font = "Roboto",
	size = math.max(ScreenScale(12), 20),
	weight = 300,
	antialias = true,
	extended = true,
})

local tunnel = Material("rem_fx/tunnel.png", "smooth")
local grain = {}
for i = 1, 4 do grain[i] = Material("rem_death/vortex_static" .. i .. ".png") end
local introStart
local beatPlayed

local fade_time = 1

local station
local loadingPath
local fadeOutStart

local function StopMusic()
	loadingPath = nil
	if IsValid(station) then fadeOutStart = SysTime() end
end

local function PlayMusic(path)
	if IsValid(station) then station:Stop() station = nil end
	fadeOutStart = nil
	if path == "" then return end

	loadingPath = path
	sound.PlayFile(path, "noplay noblock", function(chan)
		if loadingPath ~= path then
			if IsValid(chan) then chan:Stop() end
			return
		end
		loadingPath = nil
		if not IsValid(chan) then return end

		local session = LB.Session
		if not session then chan:Stop() return end

		station = chan

		-- сервер ждёт длину музыки, если сам не смог её узнать
		if not session.endTime then
			net.Start("rem_lastbattle_length")
				net.WriteFloat(chan:GetLength())
			net.SendToServer()
		end

		local elapsed = CurTime() - session.startTime
		if elapsed > 0.5 and elapsed < chan:GetLength() then chan:SetTime(elapsed) end

		chan:SetVolume(1)
		chan:Play()
	end)
end

net.Receive("rem_lastbattle_state", function()
	if not net.ReadBool() then
		LB.Session = nil
		StopMusic()
		return
	end

	local path = net.ReadString()
	local startTime = net.ReadFloat()
	local endTime = net.ReadFloat()
	local restarted = not LB.Session or LB.Session.startTime ~= startTime or LB.Session.path ~= path

	LB.Session = {
		path = path,
		startTime = startTime,
		endTime = endTime > 0 and endTime or nil,
	}

	if restarted then
		PlayMusic(path)
		-- заставка только если бой начался только что (а не при переподключении посреди боя)
		if CurTime() - startTime < 2 then introStart, beatPlayed = CurTime(), false end
	end
end)

function LB.IsActive()
	return LB.Session ~= nil
end

hook.Add("Think", "rem_lastbattle_music", function()
	if not fadeOutStart then return end

	local frac = (SysTime() - fadeOutStart) / fade_time
	if not IsValid(station) or frac >= 1 then
		if IsValid(station) then station:Stop() end
		station = nil
		fadeOutStart = nil
		return
	end

	station:SetVolume(1 - frac)
end)

local function Smooth(x) x = math.Clamp(x, 0, 1) return x * x * (3 - 2 * x) end

-- насколько темно (0..1) и насколько засвечено (0..1) в момент t заставки
local function Phases(t)
	local dark = Smooth(t / INTRO.dark)
	local wake = 0
	if t >= INTRO.wake then
		local w = (t - INTRO.wake) / INTRO.wakeLen
		dark = dark * (1 - Smooth(w * 1.4))
		wake = (1 - Smooth(w)) * Smooth((t - INTRO.wake) / 0.15)
	end
	return dark, wake
end

local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

-- мир блекнет и плывёт
hook.Add("RenderScreenspaceEffects", "rem_lastbattle_intro", function()
	if not introStart then return end
	local t = CurTime() - introStart
	if t > INTRO.total then return end
	local dark, wake = Phases(t)
	local k = math.max(dark, wake)
	cm["$pp_colour_colour"] = 1 - 0.85 * k
	cm["$pp_colour_contrast"] = 1 - 0.25 * dark + 0.1 * wake
	cm["$pp_colour_brightness"] = -0.06 * dark + 0.12 * wake
	DrawColorModify(cm)
	if k > 0.05 then DrawMotionBlur(0.12, 0.85 * k, 0.01) end
end)

local textCol = Color(200, 28, 28, 0)
hook.Add("HUDPaint", "rem_lastbattle_hud", function()
	if not introStart then return end
	local now = CurTime()
	local t = now - introStart
	if t > INTRO.total or not LB.Session then introStart = nil return end
	local w, h = ScrW(), ScrH()
	local dark, wake = Phases(t)

	-- темнота: туннель сжимается, сверху ровная чернота
	if dark > 0.01 then
		local s = Lerp(dark, 2.6, 1.15)
		surface.SetMaterial(tunnel)
		surface.SetDrawColor(0, 0, 0, 255 * math.min(dark * 1.2, 1))
		surface.DrawTexturedRect(w * 0.5 - w * s * 0.5, h * 0.5 - h * s * 0.55, w * s, h * s * 1.1)
		surface.SetDrawColor(8, 8, 10, 215 * dark)
		surface.DrawRect(0, 0, w, h)
	end

	-- засветка: серо-белая зернистая дымка, тёмное пятно в середине
	if wake > 0.01 then
		surface.SetDrawColor(200, 196, 192, 185 * wake)
		surface.DrawRect(0, 0, w, h)
		surface.SetMaterial(tunnel)
		surface.SetDrawColor(20, 18, 18, 150 * wake)
		surface.DrawTexturedRect(-w * 0.1, -h * 0.1, w * 1.2, h * 1.2)
		if not grain[1]:IsError() then
			surface.SetMaterial(grain[math.floor(now * 12) % 4 + 1])
			surface.SetDrawColor(255, 255, 255, 60 * wake)
			surface.DrawTexturedRect(0, 0, w, h)
		end
	end

	-- удар сердца на пробуждении
	if not beatPlayed and t >= INTRO.wake then
		beatPlayed = true
		surface.PlaySound("player/heartbeat1.wav")
	end

	-- "Not like this."
	local a = Smooth((t - INTRO.textIn) / INTRO.textFade) * (1 - Smooth((t - INTRO.textOut) / INTRO.textFade))
	if a > 0.01 then
		textCol.a = 255 * a
		draw.SimpleText(TEXT, "RemLastStandText", w * 0.5, h * 0.5, textCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end)
