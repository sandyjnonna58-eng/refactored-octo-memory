-- What the player asks for against what the body can do.
--
-- The keys say what the player intends; the neurological state says what arrives. Both sides of
-- the network apply the same limits to the same command, from the same quantised numbers
-- (sv_net.lua), so the owner's prediction stays in step with the server:
--
--   walking speed   Z-City offers a hook to scale it (HG_MovementCalc_2): balance, the weaker leg,
--                   wakefulness
--   running         needs two legs that carry
--   jumping         needs both legs and some balance
--   direction       uneven legs pull the walk toward the weak side. Z-City reads sideways input as
--                   on or off, so the pull is given as a share of the commands (by command number,
--                   which server and client share), and its own inertia smooths it into a drift
--   the trigger     a hand that cannot close does not pull it; the right hand is the weapon hand
--   aiming          a long weapon is steadied by the left hand: without it, no aimed fire
--
-- With nobody injured the hooks return at once.

local NT = NeuroTrauma
local C = NT.Config
local CC = C.Control

-- The limits for one character, from quantised values (the same on server and client).
-- Returns: may run, may jump, may fire, may aim, veer (-3..3, positive: pulled to the left).
function NT.Control(legL, legR, handL, handR, balance, veerQ)
	local leg = math.min(legL, legR)
	return leg >= CC.runLeg and balance >= CC.runBalance, leg >= CC.jumpLeg and balance >= CC.jumpBalance,
		handR >= CC.fireHand, handL >= CC.aimHand, veerQ
end

local function Limits(ply)
	if SERVER then
		if NT.Brain.count == 0 then return nil end
		local org = ply.organism
		local st = org and NT.Get(org)
		if not st or st.mayRun == nil then return nil end
		-- (worked out with the state message, sv_net.lua)
		return st.mayRun, st.mayJump, st.mayFire, st.mayAim, st.veerQ or 0
	end
	local CL = NT.CL
	if not CL or next(CL.records) == nil then return nil end
	local r = CL.Get(ply)
	if not r or not r.detail then return nil end
	return NT.Control(r.legL, r.legR, r.handL, r.handR, r.balance, r.veerQ or 0)
end
NT.Limits = Limits

hook.Add("HG_MovementCalc_2", "NT_Move", function(mul, ply)
	local f
	if SERVER then
		if NT.Brain.count == 0 then return end
		f = NT.Net.MoveFactor(ply)
	else
		local CL = NT.CL
		if not CL or next(CL.records) == nil then return end
		f = CL.MoveFactor(ply)
	end
	if f < 1 and istable(mul) then mul[1] = (mul[1] or 1) * f end
end)

local function Staggering(ply)
	if SERVER then
		local K = NT.Collapse
		return K ~= nil and K.active[ply] ~= nil
	end
	local CL = NT.CL
	if not CL or next(CL.records) == nil then return false end
	local r = CL.Get(ply)
	return r ~= nil and r.anim == NT.Anim.Mode.STAGGER
end

function NT.ApplyControl(ply, cmd)
	-- a character that is losing its feet does not walk where it means to
	if Staggering(ply) then
		cmd:SetForwardMove(cmd:GetForwardMove() * CC.staggerInput)
		cmd:SetSideMove(cmd:GetSideMove() * CC.staggerInput)
		if cmd:KeyDown(IN_SPEED) then cmd:RemoveKey(IN_SPEED) end
		if cmd:KeyDown(IN_JUMP) then cmd:RemoveKey(IN_JUMP) end
	end
	local run, jump, fire, aim, veer = Limits(ply)
	if run == nil then return end
	if not run and cmd:KeyDown(IN_SPEED) then cmd:RemoveKey(IN_SPEED) end
	if not jump and cmd:KeyDown(IN_JUMP) then cmd:RemoveKey(IN_JUMP) end
	if veer ~= 0 and cmd:GetForwardMove() ~= 0 and cmd:GetSideMove() == 0 then
		-- (so many commands in eight carry the pull)
		local n = math.abs(veer) * CC.veerShare
		-- (a bot has no command numbers: the server tick does for it)
		local num = cmd:CommandNumber()
		if num == 0 then num = engine.TickCount() end
		if num % 8 < n then cmd:SetSideMove(veer > 0 and -10000 or 10000) end
	end
	if not fire or not aim then
		local wep = ply:GetActiveWeapon()
		if IsValid(wep) and ishgweapon and ishgweapon(wep) then
			if not fire and cmd:KeyDown(IN_ATTACK) then cmd:RemoveKey(IN_ATTACK) end
			if not aim and cmd:KeyDown(IN_ATTACK2) and not (wep.IsPistolHoldType and wep:IsPistolHoldType()) then cmd:RemoveKey(IN_ATTACK2) end
		end
	end
end
hook.Add("StartCommand", "NT_Control", NT.ApplyControl)
