-- Сосуды на экране (сервер - sv_vessels.lua, NW2 "rem_vessels" от -1 до +1):
-- сужены - картинка бледнеет и холодеет (меньше цвета, чуть синее), расширены - теплеет и краснеет, сильно расширены -
-- лёгкая пульсация яркости (кровь отливает от головы).
local lerped = 0
local tab = {}

hook.Add("RenderScreenspaceEffects", "rem_vessels", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then lerped = 0 return end
	local v = ply:GetNW2Float("rem_vessels", 0)
	lerped = Lerp(math.min(FrameTime() * 2, 1), lerped, v)
	if math.abs(lerped) < 0.08 then return end

	-- одна таблица на все кадры, без мусора
	if lerped < 0 then
		local k = -lerped
		tab["$pp_colour_addr"], tab["$pp_colour_addg"], tab["$pp_colour_addb"] = 0, 0, 0.012 * k
		tab["$pp_colour_brightness"] = 0.01 * k
		tab["$pp_colour_contrast"] = 1
		tab["$pp_colour_colour"] = 1 - 0.4 * k
		tab["$pp_colour_mulr"], tab["$pp_colour_mulg"], tab["$pp_colour_mulb"] = 0, 0, 0.15 * k
	else
		local k = lerped
		local pulse = k > 0.6 and math.sin(CurTime() * 2.2) * 0.025 * (k - 0.6) / 0.4 or 0
		tab["$pp_colour_addr"], tab["$pp_colour_addg"], tab["$pp_colour_addb"] = 0.025 * k, 0.004 * k, 0
		tab["$pp_colour_brightness"] = pulse - 0.01 * k
		tab["$pp_colour_contrast"] = 1 + 0.05 * k
		tab["$pp_colour_colour"] = 1 + 0.18 * k
		tab["$pp_colour_mulr"], tab["$pp_colour_mulg"], tab["$pp_colour_mulb"] = 0.25 * k, 0, 0
	end
	DrawColorModify(tab)
end)
