-- Уход сознания (как в Fading Vitality), два слоя поверх экрана:
--   засветка - при большой кровопотере всё выцветает в белёсый туман с крупным зерном, туман дышит в такт пульсу;
--   туннель  - когда сознание уходит, картинка сжимается в мутный овал, вокруг чернота.
-- В отключке и на экране умирания не рисуется (там и так черно). Учитывает hg_reduce_screeneffects;
-- на hg_potatopc туннель без размытия (оно копирует весь экран - самое дорогое здесь).
-- Оптимизация: состояние организма читается 10 раз в секунду, а не каждый кадр; пока всё по нулям - хук рисования
-- сразу выходит; размытие включается только когда туннель уже заметный.
-- Текстура туннеля - tools/fading_fx/make.py.
local mat_tunnel = Material("rem_fx/tunnel.png", "smooth")
local mat_blur = Material("effects/shaders/merc_blur")
local mat_noise = {}
for i = 1, 4 do
	mat_noise[i] = Material("rem_death/vortex_static" .. i .. ".png") -- без smooth: крупные пиксели
end
local tunnelOk = not mat_tunnel:IsError()
local blurOk = not mat_blur:IsError()
local noiseOk = not mat_noise[1]:IsError()

local C = {
	-- засветка (кровь, мл; норма 5000)
	washStart = 3900, washFull = 2600,
	washAlpha = 120, washGrain = 70,
	-- туннель: по сознанию и по крови
	tunnelConsStart = 0.55, tunnelConsFull = 0.15,
	tunnelBloodStart = 2900, tunnelBloodFull = 2200,
	tunnelScaleOpen = 2.6, tunnelScaleShut = 0.7,
	tunnelBlurFrom = 0.15, -- с какой силы туннеля включается размытие
	poll = 0.1,            -- как часто читать организм, секунд
}

local wash, tunnel = 0, 0
local washTarget, tunnelTarget = 0, 0
local pulse = 70
local nextPoll = 0

local hg_reduce_screeneffects = ConVarExists("hg_reduce_screeneffects") and GetConVar("hg_reduce_screeneffects")
local hg_potatopc = ConVarExists("hg_potatopc") and GetConVar("hg_potatopc")

local function Remap01(v, from, to)
	return math.Clamp((v - from) / (to - from), 0, 1)
end

local function GetOrganism()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	return ply.new_organism or ply.organism
end

local function Poll()
	local org = GetOrganism()
	washTarget, tunnelTarget = 0, 0
	if not org or org.otrub then return end
	if hg.VortexDeath and hg.VortexDeath.Active and hg.VortexDeath.Active() then return end

	local blood, cons = org.blood or 5000, org.consciousness or 1
	-- здоровый - ничего не считаем
	if blood > C.washStart and cons > C.tunnelConsStart then return end

	local mul = (hg_reduce_screeneffects and hg_reduce_screeneffects:GetBool()) and 0.5 or 1
	washTarget = Remap01(blood, C.washStart, C.washFull) * mul
	tunnelTarget = math.max(Remap01(cons, C.tunnelConsStart, C.tunnelConsFull), Remap01(blood, C.tunnelBloodStart, C.tunnelBloodFull)) * mul
	pulse = math.Clamp(org.pulse or 70, 30, 200)
end

hook.Add("Think", "rem_fading", function()
	local now = CurTime()
	if now >= nextPoll then
		nextPoll = now + C.poll
		Poll()
	end
	if wash == 0 and tunnel == 0 and washTarget == 0 and tunnelTarget == 0 then return end

	local dt = FrameTime()
	wash = Lerp(math.min(dt * 1.5, 1), wash, washTarget)
	tunnel = Lerp(math.min(dt * 1.2, 1), tunnel, tunnelTarget)
	if wash < 0.005 and washTarget == 0 then wash = 0 end
	if tunnel < 0.005 and tunnelTarget == 0 then tunnel = 0 end
end)

local function DrawWash(a, sw, sh)
	-- туман дышит с пульсом
	local now = CurTime()
	local beat = math.max(math.sin(now * pulse / 60 * math.pi * 2), 0) ^ 4
	surface.SetDrawColor(235, 235, 230, C.washAlpha * a * (0.85 + 0.15 * beat))
	surface.DrawRect(0, 0, sw, sh)
	if noiseOk then
		surface.SetMaterial(mat_noise[math.floor(now * 20) % 4 + 1])
		surface.SetDrawColor(255, 255, 255, C.washGrain * a)
		surface.DrawTexturedRect(0, 0, sw, sh)
	end
end

local function DrawTunnel(a, sw, sh)
	local s = Lerp(a, C.tunnelScaleOpen, C.tunnelScaleShut)
	local w, h = sw * s, sh * s
	local x, y = (sw - w) / 2, (sh - h) / 2
	local alpha = 255 * math.min(a * 1.5, 1)
	surface.SetMaterial(mat_tunnel)
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.DrawTexturedRect(x, y, w, h)
	-- овал меньше экрана - снаружи просто чернота
	if s < 1 then
		surface.SetDrawColor(0, 0, 0, alpha)
		surface.DrawRect(0, 0, sw, y + 1)
		surface.DrawRect(0, y + h - 1, sw, sh - y - h + 1)
		surface.DrawRect(0, y, x + 1, h)
		surface.DrawRect(x + w - 1, y, sw - x - w + 1, h)
	end
end

hook.Add("Post Pain Post Processing", "rem_fading", function()
	if wash == 0 and tunnel == 0 then return end
	local sw, sh = ScrW(), ScrH()

	-- туннель ещё и мутный (не на слабом ПК)
	if tunnel > C.tunnelBlurFrom and blurOk and not (hg_potatopc and hg_potatopc:GetBool()) then
		render.UpdateScreenEffectTexture()
		mat_blur:SetFloat("$c0_x", (tunnel - C.tunnelBlurFrom) / (1 - C.tunnelBlurFrom) * 0.6)
		render.SetMaterial(mat_blur)
		render.DrawScreenQuad()
	end

	cam.Start2D()
		if wash > 0.01 then DrawWash(wash, sw, sh) end
		if tunnel > 0.01 and tunnelOk then DrawTunnel(tunnel, sw, sh) end
	cam.End2D()
end)
