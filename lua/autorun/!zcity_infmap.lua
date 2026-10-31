-- Z-City + InfMap: слой совместимости.
--
-- Работает только на картах InfMap: сам InfMap инициализируется лишь на картах,
-- у которых второе слово в названии "infmap" (gm_infmap, gm_infmap_backrooms и т.п.),
-- поэтому на обычных картах этот файл ничего не делает.
--
-- Файлы Z-City и InfMap не правятся: всё делается обёртками во время игры.
--
-- Имя файла начинается с "!": он грузится сразу после InfMap ("!!inf_init.lua"),
-- но раньше модулей Z-City (lua/autorun/loader.lua). Это нужно, потому что часть кода
-- Z-City запоминает net.ReadVector / net.WriteVector в local при загрузке.
--
-- Выключить: zc_infmap 0 (действует со следующей карты).

if not InfMap or not InfMap.localize_vector then return end

local cv = CreateConVar("zc_infmap", "1", {FCVAR_ARCHIVE, FCVAR_REPLICATED},
	"Z-City: слой совместимости с InfMap (действует со следующей карты)", 0, 1)

local DIR = "zcity_infmap/"
local FILES = {
	"sh_core.lua",
	"sh_net.lua",
	"sh_find.lua",
	"sv_bones.lua",
	"sv_damage.lua",
	"sv_bullets.lua",
	"sv_world.lua",
	"sv_players.lua",
	"cl_world.lua",
	"cl_render.lua",
}

if SERVER then
	for _, f in ipairs(FILES) do
		if string.sub(f, 1, 3) ~= "sv_" then AddCSLuaFile(DIR .. f) end
	end
end

if not cv:GetBool() then
	print("[Z-City/InfMap] zc_infmap 0: слой совместимости выключен")
	return
end

ZCInf = ZCInf or {}

for _, f in ipairs(FILES) do
	local side = string.sub(f, 1, 3)
	if side == "sh_" or (SERVER and side == "sv_") or (CLIENT and side == "cl_") then
		include(DIR .. f)
	end
end

print("[Z-City/InfMap] InfMap найден (" .. game.GetMap() .. "): слой совместимости включён (" .. (SERVER and "server" or "client") .. ")")
