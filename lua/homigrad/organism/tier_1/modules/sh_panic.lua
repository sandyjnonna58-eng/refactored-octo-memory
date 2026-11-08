-- Паника: тело делает само (решает сервер в sv_panic.lua, пишет время в NW2; здесь - на клиенте и сервере одинаково,
-- чтобы предсказание не дёргало):
--   rem_panic_fire       - до этого времени зажат спуск (рефлекторный выстрел, когда кто-то внезапно появился);
--   rem_panic_walk_until - непроизвольный шаг в сторону rem_panic_walk (вперёд/вбок относительно взгляда);
--   rem_panic_flee_until - бежит прочь от точки rem_panic_flee_from (камера не крутится, ноги несут сами).
hook.Add("StartCommand", "rem_panic", function(ply, cmd)
	if not ply:Alive() or IsValid(ply.FakeRagdoll) or ply:InVehicle() then return end
	if ply:GetNW2Float("rem_panic", 0) <= 0 then return end
	local now = CurTime()

	if ply:GetNW2Float("rem_panic_fire", 0) > now then
		cmd:AddKey(IN_ATTACK)
	end

	if ply:GetNW2Float("rem_panic_flee_until", 0) > now then
		local away = ply:GetPos() - ply:GetNW2Vector("rem_panic_flee_from", ply:GetPos())
		away.z = 0
		if away:LengthSqr() < 1 then away = -ply:GetAimVector() away.z = 0 end
		away:Normalize()
		local ang = cmd:GetViewAngles()
		ang.p, ang.r = 0, 0
		local speed = ply:GetRunSpeed()
		cmd:SetForwardMove(away:Dot(ang:Forward()) * speed)
		cmd:SetSideMove(away:Dot(ang:Right()) * speed)
		cmd:AddKey(IN_SPEED)
		cmd:RemoveKey(IN_DUCK)
		return
	end

	if ply:GetNW2Float("rem_panic_walk_until", 0) > now then
		local dir = ply:GetNW2Vector("rem_panic_walk", vector_origin)
		local speed = ply:GetWalkSpeed()
		cmd:SetForwardMove(dir.x * speed)
		cmd:SetSideMove(dir.y * speed)
	end
end)
