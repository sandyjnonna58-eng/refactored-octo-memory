-- Шейдеры из Simple Custom Shaders:
-- радиальное размытие - попадания (от игроков сильнее), взрывы, адреналин и боль (постоянно), старт последнего боя;
-- серость по глубине - кровопотеря, таймер смерти, депрессия;
-- размытие по глубине - урон мозгу, дезориентация.
hg.RemFX = hg.RemFX or {}
local FX = hg.RemFX

local mat_radialblur = Material("effects/shaders/merc_radialblur")
local mat_grayscale = Material("effects/shaders/merc_grayscale")
local mat_depthblur = Material("effects/shaders/merc_depthblur2")

-- вспышка удара: картинка выцветает в серый, края светлеют, всё размывает из центра
local mat_vignette = Material("rem_fx/vignette_light.png", "smooth")

local hg_reduce_screeneffects = ConVarExists("hg_reduce_screeneffects") and GetConVar("hg_reduce_screeneffects") or CreateClientConVar("hg_reduce_screeneffects", "0", true, false, "Reduce screen shader effects by 50%", 0, 1)
local hg_potatopc = ConVarExists("hg_potatopc") and GetConVar("hg_potatopc")

local kick_width = 0.15
local kick_decay = 2.5
local kick_max = 2.5

-- адреналин: постоянное размытие, пульсирует как сердце
local adrenaline_start = 0.2
local adrenaline_full = 2.5
local adrenaline_max = 1.1
local adrenaline_pulse_speed = 7
local adrenaline_pulse = 0.35

-- боль: тоже постоянное, медленно ноет; складывается с адреналином
local pain_start = 15
local pain_full = 100
local pain_max = 1
local pain_pulse_speed = 2
local pain_pulse = 0.2

local blood_gray_start = 4200
local blood_gray_full = 2600
local depression_gray_start = 0.3
local depression_gray_max = 0.6
local brain_blur_start = 0.05
local brain_blur_full = 0.5
local disorientation_blur_start = 0.5
local disorientation_blur_full = 4

local kick = 0
local kickX, kickY = 0.5, 0.5
local gray = 0
local blur = 0
local adrenalineBlur = 0

local burst_time_min = 0.45
local burst_time_add = 0.75

-- насколько сильно вспышка размывает из центра (в единицах kick)
local burst_radial = 1.6

local burst = 0
local burstStart, burstLength = 0, 1
local painBlur = 0

local function EffectMul()
	return hg_reduce_screeneffects:GetBool() and 0.5 or 1
end

local function DepthEffectsAllowed()
	return not (hg_potatopc and hg_potatopc:GetBool())
end

local function Remap01(value, from, to)
	return math.Clamp((value - from) / (to - from), 0, 1)
end

-- strength ~1 - сильное попадание; pos - точка в мире, из которой идёт размытие
function FX.Kick(strength, pos)
	if strength * EffectMul() < kick then return end

	kick = math.min(strength * EffectMul(), kick_max)
	kickX, kickY = 0.5, 0.5

	if pos then
		local screen = pos:ToScreen()
		if screen.visible then
			kickX = math.Clamp(screen.x / ScrW(), 0, 1)
			kickY = math.Clamp(screen.y / ScrH(), 0, 1)
		end
	end
end

function FX.Burst(strength)
	strength = strength * EffectMul()
	if strength < burst then return end

	burst = strength
	burstStart = CurTime()
	burstLength = burst_time_min + burst_time_add * strength
end

net.Receive("rem_fx_burst", function()
	FX.Burst(net.ReadFloat())
end)

net.Receive("rem_fx_kick", function()
	local strength = net.ReadFloat()
	local pos = net.ReadBool() and net.ReadVector() or nil
	FX.Kick(strength, pos)
end)

local function GetOrganism()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	return ply.new_organism or ply.organism
end

local function GrayTarget(org)
	local target = Remap01(org.blood or 5000, blood_gray_start, blood_gray_full)

	local deathStateEnd = org.deathStateEnd
	if org.otrub and org.incapacitated and deathStateEnd and deathStateEnd > CurTime() then target = 1 end

	target = math.max(target, Remap01(org.depression or 0, depression_gray_start, 1) * depression_gray_max)
	return target * EffectMul()
end

local function BlurTarget(org)
	local brain = Remap01(org.brain or 0, brain_blur_start, brain_blur_full)
	local disorientation = Remap01(org.disorientation or 0, disorientation_blur_start, disorientation_blur_full)
	return math.max(brain, disorientation) * EffectMul()
end

hook.Add("Think", "rem_fx", function()
	local dt = FrameTime()
	kick = math.Approach(kick, 0, dt * kick_decay * math.max(kick, 0.3))

	local org = GetOrganism()
	local allowed = DepthEffectsAllowed()
	gray = Lerp(math.min(dt * 2, 1), gray, (org and allowed) and GrayTarget(org) or 0)
	blur = Lerp(math.min(dt * 2, 1), blur, (org and allowed) and BlurTarget(org) or 0)

	local adrenaline = org and Remap01(org.adrenaline or 0, adrenaline_start, adrenaline_full) * adrenaline_max * EffectMul() or 0
	adrenalineBlur = Lerp(math.min(dt * 3, 1), adrenalineBlur, adrenaline)

	local pain = org and not org.otrub and Remap01(org.pain or 0, pain_start, pain_full) * pain_max * EffectMul() or 0
	painBlur = Lerp(math.min(dt * 2, 1), painBlur, pain)
end)

hook.Add("NeedsDepthPass", "rem_fx", function()
	if gray > 0.01 or blur > 0.01 then return true end
end)

local function DrawShader(mat)
	render.UpdateScreenEffectTexture()
	render.SetMaterial(mat)
	render.DrawScreenQuad()
end

-- первым слоем, до виньетки и зерна
hook.Add("Post Processing", "rem_fx", function()
	if gray > 0.01 and not mat_grayscale:IsError() then
		mat_grayscale:SetFloat("$c0_x", 1 - gray * 1.6)
		mat_grayscale:SetFloat("$c0_y", 1)
		DrawShader(mat_grayscale)
	end

	if blur > 0.01 and not mat_depthblur:IsError() then
		mat_depthblur:SetFloat("$c0_x", blur * 0.5)
		mat_depthblur:SetFloat("$c0_y", Lerp(blur, 0.5, 0))
		mat_depthblur:SetFloat("$c0_z", 1)
		DrawShader(mat_depthblur)
	end

	-- адреналин и боль всегда из центра; удар перекрывает их, если сильнее
	local time = CurTime()
	local pulse = adrenalineBlur * (1 - adrenaline_pulse + adrenaline_pulse * math.abs(math.sin(time * adrenaline_pulse_speed)))
		+ painBlur * (1 - pain_pulse + pain_pulse * math.abs(math.sin(time * pain_pulse_speed)))
	pulse = math.min(pulse, kick_max)
	local radial = math.max(kick, pulse)

	local burstFrac = 1 - (CurTime() - burstStart) / burstLength
	local burstA = (burst > 0 and burstFrac > 0) and burst * burstFrac ^ 1.5 or 0
	local burstRadial = burstA * burst_radial

	-- вспышка удара поверх всего: серый, светлые края; размытие из центра - ниже, вместе с остальным
	if burstA > 0 and LocalPlayer():Alive() then
		local a = burstA

		DrawColorModify({
			["$pp_colour_addr"] = 0.06 * a,
			["$pp_colour_addg"] = 0.06 * a,
			["$pp_colour_addb"] = 0.06 * a,
			["$pp_colour_brightness"] = 0.04 * a,
			["$pp_colour_contrast"] = 1 - 0.3 * a,
			["$pp_colour_colour"] = 1 - 0.95 * a,
			["$pp_colour_mulr"] = 0,
			["$pp_colour_mulg"] = 0,
			["$pp_colour_mulb"] = 0,
		})

		if not mat_vignette:IsError() then
			cam.Start2D()
				surface.SetMaterial(mat_vignette)
				surface.SetDrawColor(255, 255, 255, 255 * math.min(a, 1))
				surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
			cam.End2D()
		end
	elseif burst > 0 then
		burst = 0
	end

	-- вспышка размывает из центра; удар из точки перекрывает, если сильнее
	if burstRadial > math.max(kick, pulse) then
		radial = burstRadial
		pulse = burstRadial
	end

	if radial > 0.01 and not mat_radialblur:IsError() then
		local fromKick = kick >= pulse
		mat_radialblur:SetFloat("$c0_x", fromKick and kickX or 0.5)
		mat_radialblur:SetFloat("$c0_y", fromKick and kickY or 0.5)
		mat_radialblur:SetFloat("$c0_z", radial * kick_width)
		DrawShader(mat_radialblur)
	end
end)
