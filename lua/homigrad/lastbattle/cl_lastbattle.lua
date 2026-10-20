hg.LastBattle = hg.LastBattle or {}
local LB = hg.LastBattle

-- тот же стиль, что у таймера смерти ("You are incapacitated, You will die in ...")
surface.CreateFont("RemDeathStateFont", {
	font = "Lora",
	size = ScreenScale(22),
	weight = 1100,
	outline = true
})

local fade_time = 1
local text_fade_time = 2
local textColor = Color(255, 255, 255, 0)

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
		if hg.RemFX and hg.RemFX.Kick then hg.RemFX.Kick(1.5) end
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

hook.Add("HUDPaint", "rem_lastbattle_hud", function()
	local session = LB.Session
	if not session then return end

	local text = "This is your last stand"
	if session.endTime then
		text = text .. ", " .. math.max(math.ceil(session.endTime - CurTime()), 0)
	end

	textColor.a = math.Clamp((CurTime() - session.startTime) / text_fade_time, 0, 1) * 255
	draw.SimpleText(text, "RemDeathStateFont", ScrW() / 2, ScrH() * 0.15, textColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
