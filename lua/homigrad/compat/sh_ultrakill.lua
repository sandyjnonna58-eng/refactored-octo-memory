-- Совместимость с отдельными аддонами ULTRAKILL (в репозиторий не кладём - чужие модели/звуки, ставятся в garrysmod/addons):
--   "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk) - оружие с вьюмоделью первого лица;
--   "ULTRAKILL Movement Collection" (слайд, дэш, прыжки от стен): серверная ukmove_movement_enabled разрешает его на сервере,
--     а конкретным игрокам его выдаёт админ: чат !ukmove <игрок|*> [1|0], консоль rem_ukmove <игрок|*|^> [1|0]
--     (1 - выдать, 0 - забрать; по нику, SteamID или * - всем). Выдача сохраняется (data/zcity_ukmove.txt).
--     У кого не выдано - хуки аддона для него не работают, движение обычное homigrad;
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

-- выдано ли игроку (выдаёт админ, сервер раздаёт всем через NW2 "rem_ukmove")
local function Personal(ply)
	return ply:GetNW2Bool("rem_ukmove", false)
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
	-- скорость приседания: аддон ставит 0 всем, у кого не выдано - обычная homigrad (0.3)
	local function ApplyDuck(ply, on)
		if on then ply:SetDuckSpeed(0) ply:SetUnDuckSpeed(0) else ply:SetDuckSpeed(0.3) ply:SetUnDuckSpeed(0.3) end
	end

	-- кому выдано: SteamID64 -> true, хранится между перезаходами и рестартами
	local SAVE = "zcity_ukmove.txt"
	local granted = util.JSONToTable(file.Read(SAVE, "DATA") or "") or {}
	local function Save() file.Write(SAVE, util.TableToJSON(granted)) end

	function hg.UK.SetMove(ply, on)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		on = on and true or false
		granted[ply:SteamID64()] = on or nil
		Save()
		ply:SetNW2Bool("rem_ukmove", on)
		if hg.UK.MoveOn() then ApplyDuck(ply, on) end
		if not on then StopUK(ply) end
	end

	hook.Add("PlayerInitialSpawn", "rem_ukmove_load", function(ply)
		ply:SetNW2Bool("rem_ukmove", granted[ply:SteamID64()] == true)
	end)
	hook.Add("PlayerSpawn", "rem_ukmove_duck", function(ply)
		timer.Simple(0.1, function()
			if IsValid(ply) and hg.UK.MoveOn() and not Personal(ply) then ApplyDuck(ply, false) end
		end)
	end)

	-- кто может выдавать: админ, хост локального сервера, консоль сервера (как выдача уровней в skills/sv_skills.lua)
	local function CanManage(ply)
		if not IsValid(ply) then return true end
		if game.SinglePlayer() or ply:IsListenServerHost() then return true end
		return COMMAND_GETACCES and COMMAND_GETACCES(ply) >= 1 or ply:IsAdmin()
	end
	local function Targets(caller, name)
		if not name or name == "" or name == "^" then return {caller} end
		if name == "*" then return player.GetAll() end
		local found = {}
		for _, other in ipairs(player.GetAll()) do
			if other:SteamID() == name or other:SteamID64() == name or string.find(string.lower(other:Nick()), string.lower(name), 1, true) then
				found[#found + 1] = other
			end
		end
		return found
	end
	local function Run(caller, name, val, reply)
		local on = val == nil or val == "" or tonumber(val) ~= 0
		local targets = Targets(caller, name)
		if #targets == 0 or not IsValid(targets[1]) then reply("Player not found.") return end
		for _, t in ipairs(targets) do
			hg.UK.SetMove(t, on)
			if t ~= caller then
				t:ChatPrint((IsValid(caller) and caller:Nick() or "Server") .. ": ULTRAKILL movement " .. (on and "given" or "taken"))
			end
		end
		local note = hg.UK.MoveOn() and "" or " (note: ukmove_movement_enabled is 0 on the server)"
		reply(string.format("ULTRAKILL movement %s for %d player(s).%s", on and "given" or "taken", #targets, note))
	end

	COMMANDS = COMMANDS or {}
	COMMANDS.ukmove = {function(ply, args)
		if not CanManage(ply) then return end
		Run(ply, args[1], args[2], function(msg) ply:ChatPrint(msg) end)
	end, 1, "player or * for everyone (default - you); 1 give / 0 take"}

	concommand.Add("rem_ukmove", function(ply, _, args)
		if not CanManage(ply) then return end
		Run(IsValid(ply) and ply or nil, args[1], args[2], function(msg)
			if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
		end)
	end)
end
