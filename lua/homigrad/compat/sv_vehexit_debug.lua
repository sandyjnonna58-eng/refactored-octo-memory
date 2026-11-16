-- Отладка высадки из техники (жалоба: на некоторых картах из любой техники сразу выкидывает, V.A.C. и др.).
-- rem_debug_vehexit 1 - в консоль сервера: посадка (карта, класс сиденья и его родителя, без регдолла ли - hg.NoFakeInCar,
-- InfMap), высадка через сколько секунд и кто высадил: ExitVehicle() из Lua - со стеком вызова (видно файл: Z-City,
-- V.A.C., Glide, карта...), иначе движок (E, смерть, удалили сиденье, телепорт). hg.fallfromveh - сломалась сварка
-- регдолла с машиной (Z-City, fake/sv_tier_0.lua "removeOwO").
local cv = CreateConVar("rem_debug_vehexit", "0", FCVAR_ARCHIVE, "Print who forces players out of vehicles (server console)", 0, 1)
local PLAYER = FindMetaTable("Player")

local wrapper
local function Wrap()
	if PLAYER.ExitVehicle == wrapper then return end
	local orig = PLAYER.ExitVehicle
	wrapper = function(self, ...)
		if cv:GetBool() and IsValid(self) and self:InVehicle() then
			self.remExitByLua = CurTime()
			print(("[rem_vehexit] %s: ExitVehicle() из Lua через %.2f с после посадки; hg.leaveveh=%s hg.fallfromveh=%s")
				:format(self:Nick(), CurTime() - (self.remEnterT or 0), tostring(hg.leaveveh), tostring(hg.fallfromveh)))
			print(debug.traceback("[rem_vehexit] кто вызвал:", 2))
		end
		return orig(self, ...)
	end
	PLAYER.ExitVehicle = wrapper
end
Wrap()
-- аддоны могли переопределить ExitVehicle позже - оборачиваем то, что стоит после загрузки
hook.Add("InitPostEntity", "rem_vehexit", function() timer.Simple(5, Wrap) end)

hook.Add("PlayerEnteredVehicle", "rem_vehexit", function(ply, veh, role)
	ply.remEnterT = CurTime()
	ply.remExitByLua = nil
	if not cv:GetBool() then return end
	local parent = IsValid(veh) and veh:GetParent()
	print(("[rem_vehexit] %s сел: карта %s, сиденье %s (%s), родитель %s, роль %s, без регдолла Z-City: %s, InfMap: %s")
		:format(ply:Nick(), game.GetMap(), IsValid(veh) and veh:GetClass() or "?", IsValid(veh) and tostring(veh:GetVehicleClass()) or "?",
			IsValid(parent) and parent:GetClass() or "нет", tostring(role),
			tostring(hg.NoFakeInCar and hg.NoFakeInCar(veh) or false), tostring(InfMap ~= nil)))
end)

hook.Add("PlayerLeaveVehicle", "rem_vehexit", function(ply, veh)
	if not cv:GetBool() then return end
	local byLua = ply.remExitByLua and CurTime() - ply.remExitByLua < 0.5
	print(("[rem_vehexit] %s вышел через %.2f с (%s), жив: %s, в регдолле: %s")
		:format(ply:Nick(), CurTime() - (ply.remEnterT or CurTime()), byLua and "ExitVehicle из Lua - стек выше" or
			"движком: E / смерть / сиденье удалено / телепорт", tostring(ply:Alive()), tostring(IsValid(ply.FakeRagdoll))))
end)
