-- Алкоголь: пьяная походка (сервер - sv_alcohol.lua, NW2 "rem_bac_eff" - действующее опьянение, промилле)
-- на ходу заносит в стороны, чем пьянее - тем сильнее; с ~1.8 промилле сильно мотает (волны накладываются и
-- иногда тянут в одну сторону надолго), бегом ещё сильнее; вперёд-назад тоже "плывёт"
hook.Add("StartCommand", "rem_alcohol_walk", function(ply, cmd)
	local bac = ply:GetNW2Float("rem_bac_eff", 0)
	if bac < 0.5 or not ply:Alive() then return end
	if cmd:GetForwardMove() == 0 and cmd:GetSideMove() == 0 then return end
	local k = math.Clamp((bac - 0.5) / 2, 0, 1)
	local heavy = math.Clamp((bac - 1.8) / 1.2, 0, 1)
	local t = CurTime() + ply:EntIndex() * 3.7
	local wave = math.sin(t * 1.3) + math.sin(t * 0.47) * 0.6 + heavy * (math.sin(t * 0.21) * 1.4 + math.sin(t * 2.3) * 0.5)
	local mul = ply:KeyDown(IN_SPEED) and 1.5 or 1
	cmd:SetSideMove(cmd:GetSideMove() + wave * (170 * k + 260 * heavy) * mul)
	if heavy > 0 then
		cmd:SetForwardMove(cmd:GetForwardMove() * (1 - 0.45 * heavy * (math.sin(t * 0.9) * 0.5 + 0.5)))
	end
end)
