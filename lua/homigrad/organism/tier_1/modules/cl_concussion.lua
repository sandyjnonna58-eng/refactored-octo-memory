-- Сотрясение (из MELEECITY): звон в ушах shellshock/1-3.mp3 (громче с силой сотрясения),
-- глухой звук выше 1 и голубоватый засвет. Значение org.concussion приходит с сервера (sv_concussion.lua).
local concussion_smooth = 0
local concussion_sound
local dsp_set = false

local ring_full = 5 -- громкость звона 100% при этом сотрясении
local muffle_threshold = 1
local muffle_dsp = 14

local function stopSound(fade)
	if not concussion_sound then return end
	if fade then concussion_sound:FadeOut(fade) else concussion_sound:Stop() end
	concussion_sound = nil
end

local function reset(fade)
	concussion_smooth = 0
	stopSound(fade)
	dsp_set = false
end

-- последний из цепочки постобработки: cl_main каждый кадр ставит обычный DSP раньше
hook.Add("Post Pain Processing", "rem_concussion", function()
	local ply = LocalPlayer()
	local org = IsValid(ply) and ply:Alive() and ply.organism
	if not org then reset() return end

	local concussion = org.concussion or 0
	concussion_smooth = math.Approach(concussion_smooth, concussion, FrameTime() * 2)

	if org.otrub or (concussion <= 0 and concussion_smooth <= 0.01) then
		reset(1)
		return
	end

	if not concussion_sound then
		concussion_sound = CreateSound(ply, "shellshock/" .. math.random(3) .. ".mp3")
		concussion_sound:Play()
	end
	concussion_sound:ChangeVolume(math.Clamp(concussion_smooth / ring_full, 0, 1), 0.1)

	if concussion_smooth > muffle_threshold then
		ply:SetDSP(muffle_dsp, false)
		dsp_set = true
	elseif dsp_set then
		ply:SetDSP(0, false)
		dsp_set = false
	end

	local intensity = math.Clamp(concussion_smooth / 10, 0, 1)
	DrawBloom(0.15 * intensity, 2.88 * intensity, 20 + intensity * 30, 0, 1, 0.5, 134 / 255, 210 / 255, 240 / 255)
end)
