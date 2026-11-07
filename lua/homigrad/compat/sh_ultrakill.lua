-- Совместимость с отдельными аддонами ULTRAKILL (в репозиторий не кладём - чужие модели/звуки, ставятся в garrysmod/addons):
--   "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk) - оружие с вьюмоделью первого лица;
--   "ULTRAKILL Movement Collection" (слайд, дэш, прыжки от стен): серверная ukmove_movement_enabled разрешает его на сервере,
--     а каждый игрок сам включает/выключает его у себя - rem_ukmove (настройки: Gameplay -> "ULTRAKILL movement").
--     У кого выключено - хуки аддона для него не работают, движение обычное homigrad;
--   "ULTRAKILL Coin Mechanics" (монетки, ultrakill_toss_coin) - урон идёт обычным TakeDamageInfo, отдельно не трогаем.
-- Пока в руках оружие пака, homigrad отдаёт камеру движку (cl_camera.lua: hg.CameraYield) - иначе он рисует своё тело
-- от первого лица и вьюмодель с руками не видна. Когда включено движение ULTRAKILL, инерция homigrad выключена
-- (movement/sh_inertia.lua), чтобы не гасила слайд/дэш. В регдолле homigrad всё как обычно.
hg.UK = hg.UK or {}

local UK_BASES = {weapon_dredux_base2_uk = true, weapon_dredux_base3_uk = true}

function hg.UK.Weapon(ply)
	if not IsValid(ply) or not ply:IsPlayer() or IsValid(ply.FakeRagdoll) then return false end
	local w = ply:GetActiveWeapon()
	if not IsValid(w) then return false end
	return string.sub(w:GetClass(), 1, 17) == "weapon_dredux_uk_" or UK_BASES[w.Base or ""] == true
end

-- личный переключатель: клиент шлёт его серверу (userinfo), сервер раздаёт всем (NW2 "rem_ukmove")
local cvPersonal = CLIENT and CreateClientConVar("rem_ukmove", "1", true, true, "ULTRAKILL movement for me (if the server allows it)", 0, 1)

local function Personal(ply)
	if CLIENT and ply == LocalPlayer() then return cvPersonal:GetBool() end
	return ply:GetNW2Bool("rem_ukmove", true)
end

-- включено на сервере (ply не дан) / включено на сервере и у этого игрока
function hg.UK.MoveOn(ply)
	local cv = GetConVar("ukmove_movement_enabled")
	if not (cv and cv:GetBool()) then return false end
	if IsValid(ply) and ply:IsPlayer() then return Personal(ply) end
	return true
end

-- хуки аддона движения работают только для тех, у кого оно включено
local UK_HOOKS = {
	{"SetupMove", "UKMovement"},
	{"StartCommand", "UKMovement_SprintDisabled"},
	{"CalcMainActivity", "UKMovement_OverrideSlideAnim"},
	{"PlayerFootstep", "UKMovement_MuteFootsteps"},
	{"PlayerPostThink", "UKMovement_HandleWindState"},
	{"EntityTakeDamage", "UKMove_DashStorageDMG"},
	{"OnPlayerHitGround", "UKMove_LandingSound"},
}
local wrapped = {}

local function StopUK(ply)
	if UKMove and UKMove.GetSliding and UKMove.GetSliding(ply) then UKMove.SetSliding(ply, false) end
	if ply.UKMove_WallSliding then
		ply:StopSound("ultrakill_movement/wallcling.wav")
		ply.UKMove_WallSliding = false
	end
end

local function WrapUK()
	if not UKMove then return end
	local tbl = hook.GetTable()
	for _, h in ipairs(UK_HOOKS) do
		local event, id = h[1], h[2]
		local fn = tbl[event] and tbl[event][id]
		if fn and wrapped[event .. id] ~= fn then
			local orig = fn
			local w = function(a, ...)
				if IsValid(a) and a:IsPlayer() and not Personal(a) then
					if event == "SetupMove" then StopUK(a) end
					return
				end
				return orig(a, ...)
			end
			wrapped[event .. id] = w
			hook.Add(event, id, w)
		end
	end
end
timer.Simple(0, WrapUK)
timer.Simple(2, WrapUK)
hook.Add("InitPostEntity", "rem_ukmove_wrap", WrapUK)

if SERVER then
	-- скорость приседания: аддон ставит 0 всем, у кого выключено - обычная homigrad (0.3)
	local function ApplyDuck(ply, on)
		if on then ply:SetDuckSpeed(0) ply:SetUnDuckSpeed(0) else ply:SetDuckSpeed(0.3) ply:SetUnDuckSpeed(0.3) end
	end
	timer.Create("rem_ukmove_sync", 0.5, 0, function()
		local global = hg.UK.MoveOn()
		for _, ply in player.Iterator() do
			local on = ply:GetInfoNum("rem_ukmove", 1) == 1
			if ply:GetNW2Bool("rem_ukmove", true) ~= on then
				ply:SetNW2Bool("rem_ukmove", on)
				if global then ApplyDuck(ply, on) if not on then StopUK(ply) end end
			end
		end
	end)
	hook.Add("PlayerSpawn", "rem_ukmove_duck", function(ply)
		timer.Simple(0.1, function()
			if IsValid(ply) and hg.UK.MoveOn() and not Personal(ply) then ApplyDuck(ply, false) end
		end)
	end)
end

-- общая уступка камеры чужим аддонам: Снейк (sh_mgsv.lua) или оружие ULTRAKILL
function hg.CameraYield(ply)
	if hg.MGSV and hg.MGSV.Owns and hg.MGSV.Owns(ply) then return true end
	return hg.UK.Weapon(ply)
end
