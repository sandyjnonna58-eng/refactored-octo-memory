-- Оружие из паков Мастерской «Sandstorm SWEPs» в Z-City (weapon_rem_sand_*): в сборке только Lua, модели и звуки -
-- из паков (сервер подписан на них в своей коллекции Мастерской -> игроки качают при входе, rem_downloads.lua).
-- Здесь: подсказка, если паков нет, и подгонка положения модели в руке прямо в игре (админ).
hg = hg or {}
hg.Sandstorm = hg.Sandstorm or {}

local PROBE = "models/weapons/sandswep/w_sand_akm.mdl"

-- подгонка (суперадмин, с оружием weapon_rem_sand_* в руках):
--   rem_sand_tune <pitch> <yaw> <roll> [x y z]  - добавить к WorldAng (и WorldPos) этого ствола у всех
--   rem_sand_tune reset                          - вернуть как было
-- в консоль печатаются готовые строки для weapon_rem_sand_<имя>.lua
local function Apply(class, ang, pos)
	local stored = weapons.GetStored(class)
	if not stored then return end
	stored.__remOrigAng = stored.__remOrigAng or stored.WorldAng
	stored.__remOrigPos = stored.__remOrigPos or stored.WorldPos
	stored.WorldAng, stored.WorldPos = ang, pos
	for _, w in ipairs(ents.FindByClass(class)) do
		w.WorldAng, w.WorldPos = ang, pos
	end
end

if SERVER then
	util.AddNetworkString("rem_sand_tune")

	concommand.Add("rem_sand_tune", function(ply, _, args)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end
		local wep = IsValid(ply) and ply:GetActiveWeapon()
		if not IsValid(wep) or not string.StartWith(wep:GetClass(), "weapon_rem_sand_") then
			if IsValid(ply) then ply:ChatPrint("rem_sand_tune: возьми в руки оружие Sandstorm (weapon_rem_sand_*)") end
			return
		end
		local class = wep:GetClass()
		local stored = weapons.GetStored(class)
		local ang, pos
		if args[1] == "reset" then
			ang, pos = stored.__remOrigAng or stored.WorldAng, stored.__remOrigPos or stored.WorldPos
		else
			local n = function(i) return tonumber(args[i]) or 0 end
			ang = stored.WorldAng + Angle(n(1), n(2), n(3))
			pos = stored.WorldPos + Vector(n(4), n(5), n(6))
		end
		Apply(class, ang, pos)
		net.Start("rem_sand_tune")
			net.WriteString(class)
			net.WriteAngle(ang)
			net.WriteVector(pos)
		net.Broadcast()
		local line = string.format("SWEP.WorldPos = Vector(%.3f, %.3f, %.3f)\nSWEP.WorldAng = Angle(%.3f, %.3f, %.3f)",
			pos.x, pos.y, pos.z, ang.p, ang.y, ang.r)
		print("[rem_sand] " .. class .. "\n" .. line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[rem_sand] " .. class .. "\n" .. line .. "\n") end
	end)
else
	net.Receive("rem_sand_tune", function()
		local class, ang, pos = net.ReadString(), net.ReadAngle(), net.ReadVector()
		Apply(class, ang, pos)
	end)

	-- паков нет - вместо моделей будет ERROR: подсказать в консоли, какие паки нужны
	hook.Add("InitPostEntity", "rem_sandstorm_check", function()
		timer.Simple(5, function()
			if util.IsValidModel(PROBE) then return end
			MsgC(Color(255, 170, 60), "[remorse] Оружие Sandstorm (weapon_rem_sand_*): нет моделей. Нужны паки Мастерской ",
				"«Sandstorm SWEPs - Pistols / Assault Rifles / Shotguns» (сервер добавляет их в свою коллекцию).\n")
		end)
	end)
end

-- сами SWEP из паков (weapon_sand_*) прячем из меню: в Z-City они не работают как надо (своя вьюмодель с руками -
-- камера Z-City её разворачивает боком, без основы weapon_sand_base они вообще сломаны). Остаются наши
-- weapon_rem_sand_* (категория «Sandstorm (Z-City)»). Показать оригиналы: rem_sand_show_originals 1 (+ перезапуск карты)
local cvShow = CreateConVar("rem_sand_show_originals", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Show the original Sandstorm SWEPs (weapon_sand_*) in the spawn menu", 0, 1)
hook.Add("Initialize", "rem_sandstorm_hide", function()
	if cvShow:GetBool() then return end
	for _, t in ipairs(weapons.GetList()) do
		local class = t.ClassName or ""
		if string.StartWith(class, "weapon_sand_") then
			local stored = weapons.GetStored(class)
			if stored then stored.Spawnable = false end
		end
	end
end)
