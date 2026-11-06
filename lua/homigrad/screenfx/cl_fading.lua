-- Уход сознания (как в Fading Vitality), три слоя поверх экрана:
--   засветка - при большой кровопотере всё выцветает в белёсый туман с крупным зерном, туман дышит в такт пульсу;
--   туннель  - когда сознание уходит, картинка сжимается в мутный овал, вокруг чернота;
--   веки     - сверху и снизу наползают тёмные веки с ресницами (кровопотеря, сознание), ближе к отключке
--              иногда "моргают" - смыкаются и снова открываются.
-- В отключке и на экране умирания не рисуется (там и так черно). Учитывает hg_reduce_screeneffects.
-- Текстуры - tools/fading_fx/make.py.
local mat_lids = Material("rem_fx/lids.png", "smooth")
local mat_tunnel = Material("rem_fx/tunnel.png", "smooth")
local mat_blur = Material("effects/shaders/merc_blur")
local mat_noise = {}
for i = 1, 4 do
	mat_noise[i] = Material("rem_death/vortex_static" .. i .. ".png") -- без smooth: крупные пиксели
end

local C = {
	-- засветка (кровь, мл; норма 5000)
	washStart = 3900, washFull = 2600,
	washAlpha = 120, washGrain = 70,
	-- веки: по крови и по сознанию (0..1)
	lidsBloodStart = 3300, lidsBloodFull = 2300,
	lidsConsStart = 0.75, lidsConsFull = 0.3,
	lidsMax = 0.82,            -- насколько смыкаются сами по себе (1 - закрыты)
	blinkFrom = 0.25,          -- с какой силы век начинают "моргать"
	-- туннель: по сознанию и по крови
	tunnelConsStart = 0.55, tunnelConsFull = 0.15,
	tunnelBloodStart = 2900, tunnelBloodFull = 2200,
	tunnelScaleOpen, tunnelScaleShut = 2.6, 0.7,
}

local lidsCol = Color(8, 4, 4)
local wash, lids, tunnel = 0, 0, 0
local blinkStart, blinkLen, nextBlink = 0, 0.3, 0

local hg_reduce_screeneffects = ConVarExists("hg_reduce_screeneffects") and GetConVar("hg_reduce_screeneffects")

local function Remap01(v, from, to)
	return math.Clamp((v - from) / (to - from), 0, 1)
end

local function GetOrganism()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	return ply.new_organism or ply.organism
end

hook.Add("Think", "rem_fading", function()
	local org = GetOrganism()
	local tw, tl, tt = 0, 0, 0
	if org and not org.otrub then
		local blood, cons = org.blood or 5000, org.consciousness or 1
		local mul = (hg_reduce_screeneffects and hg_reduce_screeneffects:GetBool()) and 0.5 or 1
		tw = Remap01(blood, C.washStart, C.washFull) * mul
		tl = math.max(Remap01(blood, C.lidsBloodStart, C.lidsBloodFull), Remap01(cons, C.lidsConsStart, C.lidsConsFull)) * mul
		tt = math.max(Remap01(cons, C.tunnelConsStart, C.tunnelConsFull), Remap01(blood, C.tunnelBloodStart, C.tunnelBloodFull)) * mul
	end
	local dt = FrameTime()
	wash = Lerp(math.min(dt * 1.5, 1), wash, tw)
	lids = Lerp(math.min(dt * 1.2, 1), lids, tl)
	tunnel = Lerp(math.min(dt * 1.2, 1), tunnel, tt)

	-- моргание: чем хуже, тем чаще и дольше глаза слипаются
	local now = CurTime()
	if lids > C.blinkFrom and now > nextBlink then
		blinkStart = now
		blinkLen = 0.25 + lids * 0.6
		nextBlink = now + blinkLen + math.Rand(1.5, 4.5) / (0.4 + lids)
	end
end)

local function DrawWash(a, sw, sh, org)
	-- туман дышит с пульсом
	local bpm = math.Clamp(org and org.pulse or 70, 30, 200)
	local beat = math.max(math.sin(CurTime() * bpm / 60 * math.pi * 2), 0) ^ 4
	surface.SetDrawColor(235, 235, 230, C.washAlpha * a * (0.85 + 0.15 * beat))
	surface.DrawRect(0, 0, sw, sh)
	local noise = mat_noise[math.floor(CurTime() * 20) % 4 + 1]
	if noise and not noise:IsError() then
		surface.SetMaterial(noise)
		surface.SetDrawColor(255, 255, 255, C.washGrain * a)
		surface.DrawTexturedRect(0, 0, sw, sh)
	end
end

local function DrawTunnel(a, sw, sh)
	local s = Lerp(a, C.tunnelScaleOpen, C.tunnelScaleShut)
	local w, h = sw * s, sh * s
	local x, y = (sw - w) / 2, (sh - h) / 2
	surface.SetMaterial(mat_tunnel)
	surface.SetDrawColor(255, 255, 255, 255 * math.min(a * 1.5, 1))
	surface.DrawTexturedRect(x, y, w, h)
	-- овал меньше экрана - снаружи просто чернота
	if s < 1 then
		surface.SetDrawColor(0, 0, 0, 255 * math.min(a * 1.5, 1))
		surface.DrawRect(0, 0, sw, y + 1)
		surface.DrawRect(0, y + h - 1, sw, sh - y - h + 1)
		surface.DrawRect(0, y, x + 1, h)
		surface.DrawRect(x + w - 1, y, sw - x - w + 1, h)
	end
end

local function DrawLids(close, sw, sh)
	local h = sh * 0.95
	local edge = Lerp(close, -0.06, 0.5) * sh -- где середина края верхнего века
	local y = edge - 0.30 * h
	surface.SetMaterial(mat_lids)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(0, y, sw, h)
	surface.DrawTexturedRectUV(0, sh - y - h, sw, h, 0, 1, 1, 0) -- нижнее веко - та же картинка вверх ногами
	if y > 0 then
		surface.SetDrawColor(lidsCol.r, lidsCol.g, lidsCol.b, 255)
		surface.DrawRect(0, 0, sw, y + 1)
		surface.DrawRect(0, sh - y - 1, sw, y + 1)
	end
end

hook.Add("Post Pain Post Processing", "rem_fading", function()
	if wash < 0.01 and lids < 0.01 and tunnel < 0.01 then return end
	local org = GetOrganism()
	if not org or org.otrub then return end
	if hg.VortexDeath and hg.VortexDeath.Active and hg.VortexDeath.Active() then return end
	local sw, sh = ScrW(), ScrH()

	-- туннель ещё и мутный
	if tunnel > 0.01 and not mat_blur:IsError() then
		render.UpdateScreenEffectTexture()
		mat_blur:SetFloat("$c0_x", tunnel * 0.6)
		render.SetMaterial(mat_blur)
		render.DrawScreenQuad()
	end

	cam.Start2D()
		if wash > 0.01 then DrawWash(wash, sw, sh, org) end
		if tunnel > 0.01 and not mat_tunnel:IsError() then DrawTunnel(tunnel, sw, sh) end
		if lids > 0.01 and not mat_lids:IsError() then
			local close = lids * C.lidsMax * (1 + 0.04 * math.sin(CurTime() * 1.3))
			local bt = (CurTime() - blinkStart) / blinkLen
			if bt >= 0 and bt <= 1 then close = close + (1 - close) * math.sin(bt * math.pi) end
			DrawLids(math.min(close, 1), sw, sh)
		end
	cam.End2D()
end)
