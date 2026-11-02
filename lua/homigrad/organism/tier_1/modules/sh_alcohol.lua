-- Алкоголь: пьяная походка (сервер - sv_alcohol.lua, NW2 "rem_bac" - промилле)
-- на ходу заносит в стороны, чем пьянее - тем сильнее; бегом ещё сильнее
hook.Add("StartCommand", "rem_alcohol_walk", function(ply, cmd)
	local bac = ply:GetNW2Float("rem_bac", 0)
	if bac < 0.5 or not ply:Alive() then return end
	if cmd:GetForwardMove() == 0 and cmd:GetSideMove() == 0 then return end
	local k = math.Clamp((bac - 0.5) / 2, 0, 1)
	local t = CurTime() + ply:EntIndex() * 3.7
	local sway = (math.sin(t * 1.3) + math.sin(t * 0.47) * 0.6) * k * (ply:KeyDown(IN_SPEED) and 260 or 170)
	cmd:SetSideMove(cmd:GetSideMove() + sway)
end)
