-- Наркотики на клиенте (сервер - sv_drugs.lua; уровни - NW2 "rem_heroin" / "rem_meth" / "rem_lsd"):
--   героин - мир тёплый, мягкий и размытый, всё тянется (шлейф), края темнеют, прицел плывёт медленно;
--   мет - резкость, яркие насыщенные цвета, мелкая дрожь прицела;
--   кислота - цвета переливаются по кругу, экран "дышит" и плывёт волнами, при бэд-трипе (> 2) - темнее и краснее.
local function L(ply, key) return ply:GetNW2Float(key, 0) end

local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}
local warp = Material("effects/water_warp01")

hook.Add("RenderScreenspaceEffects", "rem_drugs", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local h, m, l = L(ply, "rem_heroin"), L(ply, "rem_meth"), L(ply, "rem_lsd")
	if h < 0.05 and m < 0.05 and l < 0.05 then return end
	local t = CurTime()
	local hk, mk, lk = math.min(h, 2) / 2, math.min(m, 2.5) / 2.5, math.min(l, 2.5) / 2.5

	local addr, addg, addb = 0.025 * hk, 0.012 * hk, 0
	local colour = 1 - 0.25 * hk + 0.5 * mk + 1.2 * lk
	local contrast = 1 - 0.08 * hk + 0.12 * mk
	local bright = -0.02 * hk
	if lk > 0 then
		-- цвета бегут по кругу
		addr = addr + math.sin(t * 0.9) * 0.06 * lk
		addg = addg + math.sin(t * 0.9 + 2.1) * 0.06 * lk
		addb = addb + math.sin(t * 0.9 + 4.2) * 0.06 * lk
		if l > 2 then -- бэд-трип
			local bad = math.min(l - 2, 1)
			addr = addr + 0.05 * bad
			bright = bright - 0.06 * bad
			contrast = contrast + 0.2 * bad
		end
	end
	cm["$pp_colour_addr"], cm["$pp_colour_addg"], cm["$pp_colour_addb"] = addr, addg, addb
	cm["$pp_colour_colour"] = colour
	cm["$pp_colour_contrast"] = contrast
	cm["$pp_colour_brightness"] = bright
	DrawColorModify(cm)

	if hk > 0.05 then DrawMotionBlur(0.12, 0.5 * hk, 0.02) end
	if mk > 0.05 then DrawSharpen(1 + mk * 1.5, 1.2) end
	if lk > 0.05 then
		-- волны: экран "дышит"
		DrawMaterialOverlay("effects/water_warp01", 0.015 * lk + math.sin(t * 1.3) * 0.006 * lk)
		DrawBloom(0.6, lk * 1.5, 9, 9, 1, 1, 1, 1, 1)
	end
end)

-- прицел: героин - медленно плывёт, мет - мелко дрожит, кислота - покачивает
hook.Add("CreateMove", "rem_drugs_aim", function(cmd)
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local h, m, l = L(ply, "rem_heroin"), L(ply, "rem_meth"), L(ply, "rem_lsd")
	if h < 0.1 and m < 0.3 and l < 0.1 then return end
	local t = CurTime()
	local ft = math.min(FrameTime() * 60, 3)
	local dp = math.sin(t * 0.7) * h * 0.08 + math.sin(t * 61) * math.max(m - 0.3, 0) * 0.12 + math.sin(t * 1.1) * l * 0.06
	local dy = math.cos(t * 0.5) * h * 0.1 + math.cos(t * 53) * math.max(m - 0.3, 0) * 0.12 + math.cos(t * 0.8) * l * 0.08
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + dp * ft, -89, 89)
	ang.y = ang.y + dy * ft
	cmd:SetViewAngles(ang)
end)
