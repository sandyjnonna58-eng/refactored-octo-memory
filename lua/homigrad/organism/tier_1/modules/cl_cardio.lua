-- Давление и пульс с монитора осмотра - что видит и чувствует сам игрок (уровни - sh_cardio.lua, сервер - sv_cardio.lua):
--   низкое давление: мир серее и темнее по краям, на бегу и первые 4 с после подъёма с земли темнеет сильнее
--     (до туннеля), картинка плывёт;
--   высокое: краснее, с каждым ударом сердца по краям вспыхивает красным (стучит в висках) и толкает взгляд;
--   частый пульс: каждый удар толкает взгляд/прицел (сильнее с частотой);
--   редкий пульс: между ударами темнеет, удар - светлеет.
-- Удары - hg.ECG.ownBeats (cl_ecg.lua: свои удары, даже если монитор показывает чужое сердце). Без сознания нет.
-- Кровь из носа (NW2 rem_nosebleed от сервера) - капли у носа у всех игроков рядом (hg.addBloodPart, кровь Z-City).
-- Выкл. картинки: rem_cardio_fx 0; hg_reduce_screeneffects - вдвое слабее.
hg.Cardio = hg.Cardio or {}
local C = hg.Cardio

local cvFX = CreateClientConVar("rem_cardio_fx", "1", true, false, "Screen effects of blood pressure and heart rate", 0, 1)
local hg_reduce = ConVarExists("hg_reduce_screeneffects") and GetConVar("hg_reduce_screeneffects")

local mat_tunnel = Material("rem_fx/tunnel.png", "smooth")
local mat_edge = Material("rem_fx/pain_edge.png", "smooth")

local grey_base, grey_wave, grey_run, grey_stand, grey_brady = 0.15, 0.1, 0.5, 0.6, 0.35
local stand_time = 4           -- сколько секунд после подъёма темнеет сильнее
local punch_tachy, punch_high = 0.35, 0.5 -- толчок взгляда на удар, градусов

local L = {}
local grey, dip, flush, throb, run = 0, 0, 0, 0, 0
local standT, wasDown, lastBeat = -100, false, nil

local function EffectMul()
	return (hg_reduce and hg_reduce:GetBool()) and 0.5 or 1
end

hook.Add("Think", "rem_cardio", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local org = ply:Alive() and (ply.new_organism or ply.organism) or nil
	local on = org and not org.otrub and cvFX:GetBool()
	C.Levels(on and org or nil, L)
	local dt, now = FrameTime(), CurTime()
	local mul = EffectMul()

	local down = IsValid(ply.FakeRagdoll) or IsValid(ply:GetNWEntity("FakeRagdoll"))
	if wasDown and not down then standT = now end
	wasDown = down

	local running = on and not down and ply:KeyDown(IN_SPEED) and ply:GetVelocity():Length2D() > 160
	run = math.Approach(run, running and 1 or 0, dt * (running and 0.6 or 0.35))
	local stand = math.max(0, 1 - (now - standT) / stand_time)
	local wave = 0.5 + 0.5 * math.sin(now * 0.9) * math.sin(now * 0.37 + 1)
	local greyT = L.low * (grey_base + grey_wave * wave + grey_run * run + grey_stand * stand)
	grey = Lerp(math.min(dt * 2.5, 1), grey, math.Clamp(greyT, 0, 0.85) * mul)
	flush = Lerp(math.min(dt * 2, 1), flush, L.high * mul)
	throb = math.Approach(throb, 0, dt * 2.5)
	-- редкий пульс: темнеет к следующему удару
	dip = math.Approach(dip, 1, dt * math.Clamp(L.hr or 70, 20, 200) / 60)

	local beats = hg.ECG and hg.ECG.ownBeats
	if beats ~= lastBeat then
		local first = lastBeat == nil
		lastBeat = beats
		if beats and not first and on then
			dip = 0
			throb = math.max(throb, L.high * mul)
			local amp = (punch_tachy * L.tachy + punch_high * L.high) * mul
			if amp > 0.02 and ViewPunch2 and not (hg.InSpecialVehicle and hg.InSpecialVehicle(ply)) then
				ViewPunch2(Angle(-amp, math.Rand(-0.5, 0.5) * amp, math.Rand(-0.3, 0.3) * amp))
			end
		end
	end
end)

local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

hook.Add("Post Pain Post Processing", "rem_cardio", function()
	local dark = L.brady * grey_brady * dip * dip * EffectMul()
	local g = math.min(grey + dark, 1)
	if g < 0.01 and flush < 0.01 and throb < 0.01 then return end
	if not LocalPlayer():Alive() then return end

	cm["$pp_colour_addr"] = 0.03 * flush + 0.06 * throb
	cm["$pp_colour_brightness"] = -0.16 * g
	cm["$pp_colour_contrast"] = 1 - 0.15 * g + 0.05 * flush
	cm["$pp_colour_colour"] = math.max(1 - 0.75 * g + 0.15 * flush, 0)
	DrawColorModify(cm)

	local sw, sh = ScrW(), ScrH()
	cam.Start2D()
		if g > 0.01 and not mat_tunnel:IsError() then
			local s = Lerp(g, 2.2, 1)
			local w, h = sw * s, sh * s
			surface.SetMaterial(mat_tunnel)
			surface.SetDrawColor(255, 255, 255, 255 * math.min(g * 1.3, 1))
			surface.DrawTexturedRect((sw - w) / 2, (sh - h) / 2, w, h)
		end
		local a = math.min(flush * 0.2 + throb * 0.6, 1)
		if a > 0.01 and not mat_edge:IsError() then
			local s = Lerp(a, 1.5, 1.15)
			local w, h = sw * s, sh * s
			surface.SetMaterial(mat_edge)
			surface.SetDrawColor(255, 0, 0, 230 * a)
			surface.DrawTexturedRect((sw - w) / 2, (sh - h) / 2, w, h)
		end
	cam.End2D()
end)

-- кровь из носа: капли у всех, у кого rem_nosebleed (ближе 1500)
local nextDrop = setmetatable({}, {__mode = "k"})
local nextScan = 0
hook.Add("Think", "rem_cardio_nose", function()
	local now = CurTime()
	if now < nextScan or not hg.addBloodPart then return end
	nextScan = now + 0.05
	local eye = EyePos()
	for _, ply in player.Iterator() do
		if not ply:GetNW2Bool("rem_nosebleed", false) or not ply:Alive() then nextDrop[ply] = nil continue end
		if now < (nextDrop[ply] or 0) then continue end
		nextDrop[ply] = now + math.Rand(0.25, 0.6)
		local body = ply:GetNWEntity("FakeRagdoll")
		if not IsValid(body) then body = ply end
		if body:GetPos():DistToSqr(eye) > 1500 * 1500 then continue end
		local att = body:LookupAttachment("eyes")
		local a = att and att > 0 and body:GetAttachment(att)
		if not a then continue end
		local fwd, up = a.Ang:Forward(), a.Ang:Up()
		local pos = a.Pos + fwd * 2.5 - up * 3 + VectorRand(-0.4, 0.4)
		hg.addBloodPart(pos, fwd * math.Rand(4, 10) + VectorRand(-3, 3) + body:GetVelocity() * 0.8, nil, 1.5, 1.5, false, false, ply)
	end
end)
