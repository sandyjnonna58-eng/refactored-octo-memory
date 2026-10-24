-- Шейдеры из Simple Custom Shaders:
-- радиальное размытие - попадания (от игроков сильнее), взрывы, адреналин и боль (постоянно), старт последнего боя;
-- серость по глубине - кровопотеря, таймер смерти, депрессия;
-- размытие по глубине - урон мозгу, дезориентация.
hg.RemFX = hg.RemFX or {}
local FX = hg.RemFX

local mat_radialblur = Material("effects/shaders/merc_radialblur")
local mat_grayscale = Material("effects/shaders/merc_grayscale")
local mat_depthblur = Material("effects/shaders/merc_depthblur2")

-- мозговая травма (sv_screenfx.lua): весь набор шейдеров разом
local mat_tr_blur = Material("effects/shaders/merc_blur")
local mat_tr_depthblur = Material("effects/shaders/merc_depthblur")
local mat_tr_grain = Material("effects/shaders/merc_filmgrain")
local mat_tr_posterize = Material("effects/shaders/merc_posterize")
local mat_tr_vhs = Material("effects/shaders/merc_vhs1")
local mat_tr_caber = Material("effects/shaders/merc_chromaticaberration")

-- вспышка удара: тёмный взрыв из лучей поверх экрана (картинка-референс без фона)
local mat_burst = Material("rem_fx/hit_burst.png", "smooth")
local burst_aspect = 1370 / 768
-- светлый контур референса без лучей (белая маска), красится в радугу
local mat_glow = Material("rem_fx/hit_glow.png", "smooth")
local glow_aspect = 1024 / 512

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
-- радужный контур: оборотов радуги в секунду и насколько ярче основной вспышки
local burst_hue_speed = 1.5
local burst_glow_mul = 1.2

-- мозговая травма: как быстро накрывает и отпускает, сколько гаснет приступ после удара
local trauma_rise = 1.5
local trauma_fall = 0.35
local trauma_hit_fade = 3
local trauma = 0

local burst = 0
local burstStart, burstLength = 0, 1
local burstHue = 0
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
	burstHue = math.Rand(0, 360)
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

	local ply = LocalPlayer()
	local traumaTarget = 0
	if org and IsValid(ply) then
		-- эпизод лоботомии сборки (cl_screeneffects.lua, глобальный brain_motionblur) - вместе с его блюром весь набор
		if ply:GetNWBool("rem_braintrauma", false) or (brain_motionblur and not org.otrub) then
			traumaTarget = 1
		else
			local left = ply:GetNWFloat("rem_braintrauma_until", 0) - CurTime()
			if left > 0 then traumaTarget = math.min(left / trauma_hit_fade, 1) end
		end
	end
	traumaTarget = traumaTarget * EffectMul()
	trauma = math.Approach(trauma, traumaTarget, dt * (traumaTarget > trauma and trauma_rise or trauma_fall))

	local adrenaline = org and Remap01(org.adrenaline or 0, adrenaline_start, adrenaline_full) * adrenaline_max * EffectMul() or 0
	adrenalineBlur = Lerp(math.min(dt * 3, 1), adrenalineBlur, adrenaline)

	local pain = org and not org.otrub and Remap01(org.pain or 0, pain_start, pain_full) * pain_max * EffectMul() or 0
	painBlur = Lerp(math.min(dt * 2, 1), painBlur, pain)
end)

hook.Add("NeedsDepthPass", "rem_fx", function()
	if gray > 0.01 or blur > 0.01 or trauma > 0.01 then return true end
end)


local function DrawShader(mat)
	render.UpdateScreenEffectTexture()
	render.SetMaterial(mat)
	render.DrawScreenQuad()
end

-- кислотная каша: серость и размытие по глубине, блюр, разъезд цветов, постеризация, VHS, зерно
local function DrawTrauma(a)
	if not DepthEffectsAllowed() then a = a * 0.6 end

	if not mat_grayscale:IsError() then
		mat_grayscale:SetFloat("$c0_x", 1 - a * 0.7)
		mat_grayscale:SetFloat("$c0_y", 1)
		DrawShader(mat_grayscale)
	end

	if not mat_tr_depthblur:IsError() then
		mat_tr_depthblur:SetFloat("$c0_x", 0)
		mat_tr_depthblur:SetFloat("$c0_y", 1)
		mat_tr_depthblur:SetFloat("$c0_z", a * 0.25)
		DrawShader(mat_tr_depthblur)
	end

	if not mat_depthblur:IsError() then
		mat_depthblur:SetFloat("$c0_x", a * 0.5)
		mat_depthblur:SetFloat("$c0_y", Lerp(a, 0.5, 0))
		mat_depthblur:SetFloat("$c0_z", 1)
		DrawShader(mat_depthblur)
	end

	if not mat_tr_blur:IsError() then
		mat_tr_blur:SetFloat("$c0_x", a * 0.5)
		DrawShader(mat_tr_blur)
	end

	if not mat_tr_caber:IsError() then
		mat_tr_caber:SetFloat("$c0_x", a * 0.9)
		mat_tr_caber:SetInt("$c0_y", 0)
		DrawShader(mat_tr_caber)
	end

	if not mat_tr_posterize:IsError() then
		mat_tr_posterize:SetInt("$c0_x", math.Round(Lerp(a, 24, 4)))
		mat_tr_posterize:SetFloat("$c0_y", 3)
		DrawShader(mat_tr_posterize)
	end

	if not mat_tr_vhs:IsError() then
		mat_tr_vhs:SetFloat("$c0_y", a * 0.02)
		mat_tr_vhs:SetFloat("$c0_z", a * 0.012)
		DrawShader(mat_tr_vhs)
	end

	if not mat_tr_grain:IsError() then
		mat_tr_grain:SetInt("$c0_y", 0)
		mat_tr_grain:SetFloat("$c0_z", 2)
		mat_tr_grain:SetFloat("$c0_w", a * 0.3)
		mat_tr_grain:SetFloat("$c1_x", 0)
		mat_tr_grain:SetFloat("$c1_y", 0.5)
		DrawShader(mat_tr_grain)
	end
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

	-- вспышка удара поверх всего: картинка на весь экран (по ширине, без искажения), гаснет
	if burstA > 0 and LocalPlayer():Alive() then
		if not mat_burst:IsError() then
			local w = math.max(ScrW(), ScrH() * burst_aspect)
			local h = w / burst_aspect

			cam.Start2D()
				-- ядерно-радужный контур: аддитивно, переливается по радуге, пока вспышка гаснет
				if not mat_glow:IsError() then
					local gw = math.max(ScrW(), ScrH() * glow_aspect)
					local gh = gw / glow_aspect
					local col = HSVToColor((burstHue + (CurTime() - burstStart) * burst_hue_speed * 360) % 360, 1, 1)

					render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE, BLENDFUNC_ADD)
					surface.SetMaterial(mat_glow)
					surface.SetDrawColor(col.r, col.g, col.b, 255 * math.min(burstA * burst_glow_mul, 1))
					surface.DrawTexturedRect((ScrW() - gw) / 2, (ScrH() - gh) / 2, gw, gh)
					render.OverrideBlend(false)
				end

				surface.SetMaterial(mat_burst)
				surface.SetDrawColor(255, 255, 255, 255 * math.min(burstA, 1))
				surface.DrawTexturedRect((ScrW() - w) / 2, (ScrH() - h) / 2, w, h)
			cam.End2D()
		end
	elseif burst > 0 then
		burst = 0
	end

	if radial > 0.01 and not mat_radialblur:IsError() then
		local fromKick = kick >= pulse
		mat_radialblur:SetFloat("$c0_x", fromKick and kickX or 0.5)
		mat_radialblur:SetFloat("$c0_y", fromKick and kickY or 0.5)
		mat_radialblur:SetFloat("$c0_z", radial * kick_width)
		DrawShader(mat_radialblur)
	end

	-- мозговая травма последней - поверх всего остального
	if trauma > 0.01 and LocalPlayer():Alive() then DrawTrauma(trauma) end
end)
