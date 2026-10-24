-- Галлюцинации в темноте: чем дольше сидишь без света, тем чаще и наглее мерещится.
-- Фонарик (обычный или фонарик сборки) считается светом. Всё только у этого игрока:
-- фигуры - клиентские модели, звуки - sound.Play в точке рядом, искажения - шейдеры.
local check_interval = 0.5
local dark_threshold = 0.025      -- яркость света у глаз, ниже - темно
local dark_grace = 15             -- секунд темноты до первых галлюцинаций
local dark_full = 75              -- ещё столько - и галлюцинации на полную
local light_recover = 3           -- в секунду света темнота "уходит" втрое быстрее
local event_gap_calm, event_gap_full = 35, 7

local phantom_models = {
	"models/player/group01/male_02.mdl",
	"models/player/group01/male_07.mdl",
	"models/player/group01/female_04.mdl",
	"models/player/group03/male_04.mdl",
	"models/player/group03/female_02.mdl",
}
local phantom_look_angle = 14      -- столько градусов от взгляда - исчезает
local phantom_near = 140

local snd_steps = {"player/footsteps/concrete1.wav", "player/footsteps/concrete2.wav", "player/footsteps/concrete3.wav", "player/footsteps/concrete4.wav"}
local snd_whispers = {}
for i = 1, 11 do snd_whispers[i] = "ambient/levels/citadel/strange_talk" .. i .. ".wav" end
local snd_breath = "player/breathe1.wav"
local snd_knock = "physics/wood/wood_box_impact_hard3.wav"
local snd_screams = {"ambient/voices/f_scream1.wav", "ambient/voices/m_scream1.wav", "ambient/creatures/town_child_scream1.wav"}
local snd_sting = "npc/fast_zombie/fz_alert_close1.wav"

local mat_fisheye = Material("effects/shaders/merc_fisheye")
local mat_glitch = Material("effects/shaders/merc_videoglitch")

local darkTime = 0
local forcedUntil = 0
local intensity = 0
local nextEvent = 0
local glitchUntil = 0
local phantoms = {}

local function Enabled(ply)
	local org = ply.organism
	if not ply:Alive() or (org and org.otrub) then return false end
	-- у последних моментов свой чёрный экран
	if ply:GetNWFloat("rem_lastmoments_until", 0) > CurTime() then return false end
	return true
end

local function IsDark(ply)
	if ply:FlashlightIsOn() or ply:GetNetVar("flashlight", false) then return false end
	local light = render.GetLightColor(ply:EyePos())
	return light.x * 0.299 + light.y * 0.587 + light.z * 0.114 < dark_threshold
end

net.Receive("rem_hallucinate", function()
	forcedUntil = CurTime() + net.ReadFloat()
	nextEvent = math.min(nextEvent, CurTime() + 2)
end)

-- точка на полу в стороне yawOffset от взгляда, на расстоянии dist (если стена - ближе)
local function GroundPoint(ply, yawOffset, dist)
	local ang = Angle(0, ply:EyeAngles().y + yawOffset, 0)
	local eye = ply:EyePos()
	local tr = util.TraceLine({start = eye, endpos = eye + ang:Forward() * dist, filter = ply, mask = MASK_SOLID_BRUSHONLY})
	local pos = tr.HitPos - ang:Forward() * 24
	local down = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, 300), mask = MASK_SOLID_BRUSHONLY})
	if not down.Hit then return end
	return down.HitPos
end

local function RemovePhantom(i)
	local ph = phantoms[i]
	if IsValid(ph.ent) then ph.ent:Remove() end
	table.remove(phantoms, i)
end

-- фигура: тёмный силуэт, смотрит на игрока; behind - стоит прямо за спиной
local function SpawnPhantom(ply, behind)
	local pos = behind and GroundPoint(ply, 180, 70) or GroundPoint(ply, (math.random(2) == 1 and 1 or -1) * math.Rand(40, 75), math.Rand(300, 700))
	if not pos then return end

	local model = phantom_models[math.random(#phantom_models)]
	local others = player.GetAll()
	local other = others[math.random(#others)]
	if IsValid(other) and other ~= ply and util.IsValidModel(other:GetModel()) then model = other:GetModel() end

	local ent = ClientsideModel(model, RENDERGROUP_BOTH)
	if not IsValid(ent) then return end

	ent:SetPos(pos)
	ent:SetAngles(Angle(0, (ply:GetPos() - pos):Angle().y, 0))
	local seq = ent:LookupSequence("idle_all_01")
	if seq and seq >= 0 then ent:ResetSequence(seq) end

	local ph = {ent = ent, born = CurTime(), life = behind and 6 or math.Rand(8, 15), behind = behind, alpha = 0}
	ent.RenderOverride = function(self)
		render.SetColorModulation(0.12, 0.12, 0.12)
		render.SetBlend(ph.alpha)
		self:DrawModel()
		render.SetBlend(1)
		render.SetColorModulation(1, 1, 1)
	end

	phantoms[#phantoms + 1] = ph
end

local function PlayAround(path, yawOffset, dist, level, pitch)
	local ply = LocalPlayer()
	local ang = Angle(0, ply:EyeAngles().y + yawOffset, 0)
	sound.Play(path, ply:EyePos() + ang:Forward() * dist, level or 70, pitch or 100, 1)
end

-- шаги подходят сзади: от далеко к близко
local function Footsteps()
	local yaw = 180 + math.Rand(-35, 35)
	local count = math.random(4, 7)
	for i = 1, count do
		timer.Simple(i * 0.45, function()
			if not IsValid(LocalPlayer()) then return end
			PlayAround(snd_steps[math.random(#snd_steps)], yaw, Lerp(i / count, 420, 120), 65, math.random(95, 105))
		end)
	end
end

local function RunEvent(ply, a)
	local roll = math.Rand(0, 1)

	if a >= 0.6 and roll < 0.15 then
		SpawnPhantom(ply, true)
		PlayAround(snd_breath, 180, 40, 60, 90)
	elseif a >= 0.25 and roll < 0.45 then
		SpawnPhantom(ply, false)
	elseif a >= 0.6 and roll < 0.55 then
		PlayAround(snd_screams[math.random(#snd_screams)], math.Rand(0, 360), 900, 80, math.random(80, 95))
	elseif roll < 0.7 then
		Footsteps()
	elseif roll < 0.85 then
		PlayAround(snd_whispers[math.random(#snd_whispers)], 180 + math.Rand(-60, 60), 120, 60, math.random(85, 100))
	else
		PlayAround(snd_knock, math.Rand(0, 360), 250, 70, math.random(90, 110))
		timer.Simple(0.5, function() if IsValid(LocalPlayer()) then PlayAround(snd_knock, 0, 250, 70, 100) end end)
	end

	if a >= 0.4 and math.random() < 0.35 then glitchUntil = CurTime() + math.Rand(0.15, 0.5) end
end

local nextCheck = 0

hook.Add("Think", "rem_hallucinations", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local now = CurTime()

	if now >= nextCheck then
		nextCheck = now + check_interval

		if Enabled(ply) and IsDark(ply) then
			darkTime = darkTime + check_interval
		else
			darkTime = math.max(darkTime - check_interval * light_recover, 0)
		end
	end

	local target = Enabled(ply) and math.Clamp((darkTime - dark_grace) / dark_full, 0, 1) or 0
	if forcedUntil > now and Enabled(ply) then target = 1 end
	intensity = math.Approach(intensity, target, FrameTime() * 0.2)

	if intensity > 0.01 and now >= nextEvent then
		nextEvent = now + Lerp(intensity, event_gap_calm, event_gap_full) * math.Rand(0.7, 1.3)
		RunEvent(ply, intensity)
	elseif intensity <= 0.01 then
		nextEvent = math.max(nextEvent, now + 5)
	end

	-- фигуры: проявляются, исчезают, если посмотреть прямо, подойти или когда время вышло
	local eye, aim = ply:EyePos(), ply:GetAimVector()
	for i = #phantoms, 1, -1 do
		local ph = phantoms[i]
		local ent = ph.ent

		if not IsValid(ent) then
			table.remove(phantoms, i)
		else
			local toPh = ent:WorldSpaceCenter() - eye
			local dist = toPh:Length()
			local looking = math.deg(math.acos(math.Clamp(aim:Dot(toPh:GetNormalized()), -1, 1))) < (ph.behind and 60 or phantom_look_angle)
			local expired = now - ph.born > ph.life or (not ph.behind and dist < phantom_near) or not Enabled(ply)

			if looking and ph.behind and not ph.stung then
				ph.stung = true
				surface.PlaySound(snd_sting)
				if hg.RemFX and hg.RemFX.Kick then hg.RemFX.Kick(0.9, ent:WorldSpaceCenter()) end
				glitchUntil = now + 0.3
			end

			if looking or expired then
				ph.alpha = math.max(ph.alpha - FrameTime() * (looking and 6 or 1), 0)
				if ph.alpha <= 0 then RemovePhantom(i) end
			else
				ph.alpha = math.min(ph.alpha + FrameTime() * 0.6, 0.85)
				ent:SetAngles(Angle(0, (ply:GetPos() - ent:GetPos()):Angle().y, 0))
				ent:FrameAdvance()
			end
		end
	end
end)

-- мир "дышит" (fisheye) и иногда глючит (videoglitch)
hook.Add("RenderScreenspaceEffects", "rem_hallucinations", function()
	if intensity <= 0.05 then return end

	if intensity > 0.3 and not mat_fisheye:IsError() then
		render.UpdateScreenEffectTexture()
		mat_fisheye:SetFloat("$c0_x", (intensity - 0.3) * 0.12 * (0.5 + 0.5 * math.sin(CurTime() * 0.8)))
		render.SetMaterial(mat_fisheye)
		render.DrawScreenQuad()
	end

	if glitchUntil > CurTime() and not mat_glitch:IsError() then
		render.UpdateScreenEffectTexture()
		mat_glitch:SetFloat("$c0_y", intensity)
		render.SetMaterial(mat_glitch)
		render.DrawScreenQuad()
	end
end)

hook.Add("ShutDown", "rem_hallucinations", function()
	for i = #phantoms, 1, -1 do RemovePhantom(i) end
end)
