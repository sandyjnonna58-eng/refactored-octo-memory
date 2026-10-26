-- Сдача в плен и стойка на коленях (из MELEECITY, автор оригинала adodser).
-- Радиальное меню: "Surrender" - поднять руки (бросает оружие), ПКМ - сразу на колени с поднятыми руками.
-- Во время сдачи ПКМ по пункту: опустить руки, встать на колени, руки за голову.
-- Команды surrender_toggle / kneel_toggle (есть в биндах). Руки нельзя опустить раньше surrender_min_time.
-- ЛКМ (попытка ударить) или взятое в руки оружие - выход из сдачи.
CreateClientConVar("surrender_text", "1", true, false, "Show surrender/kneel chat messages (1=on, 0=off)")
CreateClientConVar("surrender_voicel", "1", true, false, "Play scared voice line when surrendering (1=on, 0=off)")

local cv_text = GetConVar("surrender_text")
local cv_voice = GetConVar("surrender_voicel")

local function Say(ply, text)
	if cv_text:GetBool() then ply:ChatPrint(text) end
end

local SURR_VARIANTS = {
	{"G_Surrender", "g_surrenderloopArms", "G_Surrenderend"},
	{"G_Surrender2", "g_surrenderloopArms2", "G_Surrenderend2"},
	{"G_Surrender3", "g_surrenderloopArms3", "G_Surrenderend3"},
}
local SURR_RANDOM_MAX = 2 -- третий вариант - руки за головой
local HBH_VARIANT = 3

local KNEEL_VARIANTS = {
	{"kneeldown", "kneeldownloop", "kneeldownEND"},
	{"kneeldown2", "kneeldown2loop", "kneeldown2END"},
	{"kneeldown3", "kneeldown3loop", "kneeldown3end"},
}

local KNEEL_HBH_TRANSITIONS = {
	[1] = {"kneeldownTransition", "kneeldownTransitionBack"},
	[2] = {"kneeldown2Transition", "kneeldown2TransitionBack"},
}

local SURR_BEGIN_DURATION = 0.8
local SURR_LOOP_DURATION = 1.8
local SURR_EXIT_DURATION = 0.6
local KNEEL_BEGIN_DURATION = 1.3
local KNEEL_LOOP_DURATION = 1.8
local KNEEL_EXIT_DURATION = 1.3
local HBH_KNEEL_TRANSITION_DURATION = 0.39
local HBH_TRANSITION_TIME = 0.5

local KNEEL_CD = 2.0
local HBH_CD = 1.2
local SURR_CD_TIME = 4.0
local STAND_CD = 1.5
local WEAPON_LOCK_TIME = 10

local SURR_SLOT = GESTURE_SLOT_ATTACK_AND_RELOAD
local KNEEL_SLOT = GESTURE_SLOT_CUSTOM

local MIN_SURRENDER_TIME = 5.0

net.Receive("hg_surrender_min_time_sync", function()
	MIN_SURRENDER_TIME = net.ReadFloat()
end)

local kneelCD, hbhCD, standCD, surrenderCD = 0, 0, 0, 0

local inSurrender = false
local currentSurrVariantIndex = 1
local previousSurrVariantIndex = 1
local inHandsBehindHead = false
local hbhTransitioning = false
local surrenderStartTime = 0

local inKneel = false
local kneelExiting = false
local kneelReady = false
local currentKneelVariantIndex = 1
local kneelBaseYaw = 0

local weaponAllowTime = 0
local weaponReachActive = false
local forcedExiting = false

local remoteKneeling = {}

local function PlayGesture(ply, slot, seqName, actFallback)
	if not seqName then return end
	local seq = ply:LookupSequence(seqName)
	if seq and seq ~= -1 then
		ply:AddVCDSequenceToGestureSlot(slot, seq, 0, false)
	else
		ply:AnimRestartGesture(slot, actFallback, false)
	end
end

local function PlaySurrBegin(ply, vi)
	local v = SURR_VARIANTS[vi]
	if v then PlayGesture(ply, SURR_SLOT, v[1], ACT_GMOD_GESTURE_TAUNT_ZOMBIE) end
end

local function PlaySurrLoop(ply, vi)
	local v = SURR_VARIANTS[vi]
	if v then PlayGesture(ply, SURR_SLOT, v[2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE) end
end

local function PlaySurrExit(ply, vi)
	local v = SURR_VARIANTS[vi]
	if not v then return end
	PlayGesture(ply, SURR_SLOT, v[3], ACT_GMOD_GESTURE_ITEM_PLACE)
	timer.Simple(SURR_EXIT_DURATION, function()
		if IsValid(ply) then ply:AnimResetGestureSlot(SURR_SLOT) end
	end)
end

local function PlayKneelBegin(ply, vi)
	local v = KNEEL_VARIANTS[vi]
	if v then PlayGesture(ply, KNEEL_SLOT, v[1], ACT_GMOD_GESTURE_TAUNT_ZOMBIE) end
end

local function PlayKneelLoop(ply, vi)
	local v = KNEEL_VARIANTS[vi]
	if v then PlayGesture(ply, KNEEL_SLOT, v[2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE) end
end

local function PlayKneelExit(ply, vi)
	local v = KNEEL_VARIANTS[vi]
	if not v then return end
	PlayGesture(ply, KNEEL_SLOT, v[3], ACT_GMOD_GESTURE_ITEM_PLACE)
	timer.Simple(KNEEL_EXIT_DURATION, function()
		if IsValid(ply) then ply:AnimResetGestureSlot(KNEEL_SLOT) end
	end)
end

local function PlayKneelHBHTransition(ply, baseVI, direction)
	local t = KNEEL_HBH_TRANSITIONS[baseVI]
	if t then PlayGesture(ply, KNEEL_SLOT, direction == "enter" and t[1] or t[2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE) end
end

local function Send(name, vi, extra)
	net.Start(name)
	net.WriteUInt(vi, 4)
	if extra then net.WriteString(extra) end
	net.SendToServer()
end

-- жесты других игроков
net.Receive("hg_surrender_enter", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if not IsValid(ply) or ply == LocalPlayer() then return end
	PlaySurrBegin(ply, vi)
	timer.Simple(SURR_BEGIN_DURATION, function() if IsValid(ply) then PlaySurrLoop(ply, vi) end end)
end)

net.Receive("hg_surrender_loop", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if IsValid(ply) and ply ~= LocalPlayer() then PlaySurrLoop(ply, vi) end
end)

net.Receive("hg_surrender_exit", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if IsValid(ply) and ply ~= LocalPlayer() then PlaySurrExit(ply, vi) end
end)

net.Receive("hg_kneel_enter", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if not IsValid(ply) or ply == LocalPlayer() then return end
	remoteKneeling[ply] = true
	PlayKneelBegin(ply, vi)
	timer.Simple(KNEEL_BEGIN_DURATION, function()
		if IsValid(ply) and remoteKneeling[ply] then PlayKneelLoop(ply, vi) end
	end)
end)

net.Receive("hg_kneel_loop", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if IsValid(ply) and ply ~= LocalPlayer() then PlayKneelLoop(ply, vi) end
end)

net.Receive("hg_kneel_exit", function()
	local ply, vi = net.ReadEntity(), net.ReadUInt(4)
	if not IsValid(ply) or ply == LocalPlayer() then return end
	remoteKneeling[ply] = nil
	PlayKneelExit(ply, vi)
end)

net.Receive("hg_kneel_hbh_transition", function()
	local ply, baseVI, dir = net.ReadEntity(), net.ReadUInt(4), net.ReadString()
	if IsValid(ply) and ply ~= LocalPlayer() then PlayKneelHBHTransition(ply, baseVI, dir) end
end)

local function CanExitSurrender()
	return CurTime() >= surrenderStartTime + MIN_SURRENDER_TIME
end

local function StartSurrenderLoop(ply, vi)
	if not inSurrender then return end
	PlaySurrLoop(ply, vi)
	timer.Create("surrender_loop_timer", SURR_LOOP_DURATION, 0, function()
		if not inSurrender or not IsValid(ply) then
			timer.Remove("surrender_loop_timer")
			return
		end
		PlaySurrLoop(ply, currentSurrVariantIndex)
		Send("hg_surrender_loop", currentSurrVariantIndex)
	end)
end

local function StartKneelLoop(ply, vi)
	if not inKneel then return end
	PlayKneelLoop(ply, vi)
	timer.Create("kneel_loop_timer", KNEEL_LOOP_DURATION, 0, function()
		if not inKneel or not IsValid(ply) then
			timer.Remove("kneel_loop_timer")
			return
		end
		PlayKneelLoop(ply, currentKneelVariantIndex)
		Send("hg_kneel_loop", currentKneelVariantIndex)
	end)
end

local function ExitSurrender(ply, silent)
	if not inSurrender then return end
	if not CanExitSurrender() then
		Say(ply, "You cannot lower your hands yet! (" .. math.ceil(surrenderStartTime + MIN_SURRENDER_TIME - CurTime()) .. "s)")
		return
	end

	inSurrender = false
	inHandsBehindHead = false
	hbhTransitioning = false
	timer.Remove("surrender_loop_timer")
	timer.Remove("hbh_transition_timer")
	PlaySurrExit(ply, currentSurrVariantIndex)
	Send("hg_surrender_exit", currentSurrVariantIndex)
	currentSurrVariantIndex = 1
	previousSurrVariantIndex = 1
	if not silent then Say(ply, "You lower your hands.") end
end

local function EnterSurrender(ply)
	local vi = math.random(SURR_RANDOM_MAX)
	currentSurrVariantIndex = vi
	previousSurrVariantIndex = vi
	inSurrender = true
	inHandsBehindHead = false
	surrenderStartTime = CurTime()
	weaponAllowTime = CurTime() + WEAPON_LOCK_TIME

	PlaySurrBegin(ply, vi)
	Send("hg_surrender_enter", vi)

	if cv_voice:GetBool() then
		net.Start("hg_surrender_voice")
		net.SendToServer()
	end

	if (ply.NextFoley or 0) < CurTime() then
		ply:EmitSound("player/clothes_generic_foley_0" .. math.random(5) .. ".wav", 55)
		ply.NextFoley = CurTime() + 2.5
	end

	Say(ply, "You raise your hands.")

	timer.Create("surrender_begin_timer", SURR_BEGIN_DURATION, 1, function()
		if IsValid(ply) and inSurrender then StartSurrenderLoop(ply, vi) end
	end)
end

local function ExitKneel(ply, silent)
	if not inKneel or CurTime() < kneelCD then return end
	if inSurrender and not CanExitSurrender() then
		Say(ply, "You cannot stand up yet! (" .. math.ceil(surrenderStartTime + MIN_SURRENDER_TIME - CurTime()) .. "s)")
		return
	end

	kneelCD = CurTime() + KNEEL_CD
	standCD = CurTime() + STAND_CD

	inKneel = false
	kneelReady = false
	kneelExiting = true
	timer.Remove("kneel_loop_timer")
	timer.Remove("kneel_begin_timer")

	PlayKneelExit(ply, currentKneelVariantIndex)
	Send("hg_kneel_exit", currentKneelVariantIndex)

	if (ply.NextFoley or 0) < CurTime() then
		ply:EmitSound("player/clothes_generic_foley_0" .. math.random(5) .. ".wav", 55)
		ply.NextFoley = CurTime() + 2.5
	end

	net.Start("hg_kneel_hull") net.WriteBool(false) net.SendToServer()

	timer.Create("kneel_exit_timer", KNEEL_EXIT_DURATION, 1, function()
		kneelExiting = false
		if IsValid(ply) and not silent then Say(ply, "You stand back up.") end
	end)
	currentKneelVariantIndex = 1
end

local function EnterKneel(ply)
	if CurTime() < kneelCD or CurTime() < standCD then return end
	kneelCD = CurTime() + KNEEL_CD

	local vi = currentSurrVariantIndex
	currentKneelVariantIndex = vi

	inKneel = true
	kneelExiting = false
	kneelReady = false
	kneelBaseYaw = ply:EyeAngles().y
	weaponAllowTime = math.max(weaponAllowTime, CurTime() + WEAPON_LOCK_TIME)

	PlayKneelBegin(ply, vi)
	Send("hg_kneel_enter", vi)

	if (ply.NextFoley or 0) < CurTime() then
		ply:EmitSound("player/clothes_generic_foley_0" .. math.random(5) .. ".wav", 55)
		ply.NextFoley = CurTime() + 2.5
	end

	Say(ply, "You kneel down.")

	timer.Create("kneel_begin_timer", KNEEL_BEGIN_DURATION, 1, function()
		if not IsValid(ply) or not inKneel then return end
		kneelReady = true
		StartKneelLoop(ply, vi)
		net.Start("hg_kneel_hull") net.WriteBool(true) net.SendToServer()

		if inSurrender then
			timer.Simple(0.1, function()
				if IsValid(ply) and inSurrender then PlaySurrLoop(ply, currentSurrVariantIndex) end
			end)
		end
	end)
end

local function EnterKneelWithSurrender(ply)
	EnterSurrender(ply)
	timer.Simple(0.25, function()
		if IsValid(ply) then EnterKneel(ply) end
	end)
end

-- смена "руки вверх" <-> "руки за голову" (вариант 3); на коленях - отдельные переходы
local function DoHandsBehindHeadTransition(ply, fromVI, toVI, onComplete)
	hbhTransitioning = true
	timer.Remove("surrender_loop_timer")
	timer.Remove("kneel_loop_timer")
	timer.Remove("hbh_transition_timer")

	if inKneel then
		local baseVI = toVI == HBH_VARIANT and fromVI or toVI
		local direction = toVI == HBH_VARIANT and "enter" or "exit"

		PlayKneelHBHTransition(ply, baseVI, direction)
		Send("hg_kneel_hbh_transition", baseVI, direction)

		PlaySurrBegin(ply, toVI)
		Send("hg_surrender_enter", toVI)

		timer.Create("hbh_transition_timer", HBH_KNEEL_TRANSITION_DURATION, 1, function()
			hbhTransitioning = false
			if not IsValid(ply) or not inSurrender then return end
			currentSurrVariantIndex = toVI
			currentKneelVariantIndex = toVI

			StartKneelLoop(ply, toVI)
			Send("hg_kneel_loop", toVI)

			if onComplete then onComplete() end
			StartSurrenderLoop(ply, toVI)
		end)
	else
		local vFrom = SURR_VARIANTS[fromVI]
		if vFrom then
			PlayGesture(ply, SURR_SLOT, vFrom[3], ACT_GMOD_GESTURE_ITEM_PLACE)
			Send("hg_surrender_exit", fromVI)
		end

		timer.Create("hbh_transition_timer", HBH_TRANSITION_TIME, 1, function()
			if not IsValid(ply) or not inSurrender then hbhTransitioning = false return end

			PlaySurrBegin(ply, toVI)
			Send("hg_surrender_enter", toVI)

			timer.Simple(SURR_BEGIN_DURATION, function()
				hbhTransitioning = false
				if not IsValid(ply) or not inSurrender then return end
				currentSurrVariantIndex = toVI
				if onComplete then onComplete() end
				StartSurrenderLoop(ply, toVI)
			end)
		end)
	end
end

local function EnterHandsBehindHead(ply)
	if not inSurrender or hbhTransitioning or CurTime() < hbhCD or inHandsBehindHead then return end
	if inKneel and not kneelReady then return end
	hbhCD = CurTime() + HBH_CD
	previousSurrVariantIndex = currentSurrVariantIndex
	DoHandsBehindHeadTransition(ply, currentSurrVariantIndex, HBH_VARIANT, function()
		inHandsBehindHead = true
		Say(ply, "You put your hands behind your head.")
	end)
end

local function ExitHandsBehindHead(ply)
	if not inSurrender or not inHandsBehindHead or hbhTransitioning or CurTime() < hbhCD then return end
	if inKneel and not kneelReady then return end
	hbhCD = CurTime() + HBH_CD
	DoHandsBehindHeadTransition(ply, HBH_VARIANT, previousSurrVariantIndex, function()
		inHandsBehindHead = false
		Say(ply, "You raise your hands back up.")
	end)
end

local function DropWeaponIfHeld(ply)
	local wep = ply:GetActiveWeapon()
	if IsValid(wep) and wep:GetClass() ~= "weapon_hands_sh" then RunConsoleCommand("dropweapon") end
end

local function CanStart(ply)
	return IsValid(ply) and ply:Alive() and not (ply.organism and ply.organism.otrub) and hg.GetCurrentCharacter(ply) == ply
end

local function StartSurrender(ply, withKneel)
	if CurTime() < surrenderCD then return end
	surrenderCD = CurTime() + SURR_CD_TIME
	DropWeaponIfHeld(ply)
	timer.Simple(0.15, function()
		if not IsValid(ply) then return end
		if withKneel then EnterKneelWithSurrender(ply) else EnterSurrender(ply) end
	end)
end

-- движение и обзор на коленях
hook.Add("SetupMove", "kneel_movement_lock", function(ply, mv)
	if ply ~= LocalPlayer() or not (inKneel or kneelExiting) then return end
	mv:SetForwardSpeed(0)
	mv:SetSideSpeed(0)
	mv:SetUpSpeed(0)
	mv:SetVelocity(Vector(0, 0, mv:GetVelocity().z))
	mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_FORWARD + IN_BACK + IN_MOVELEFT + IN_MOVERIGHT + IN_JUMP)))
end)

hook.Add("CreateMove", "surrender_input", function(cmd)
	if inKneel then
		local ang = cmd:GetViewAngles()
		ang.y = kneelBaseYaw + math.Clamp(math.NormalizeAngle(ang.y - kneelBaseYaw), -20, 20)
		ang.p = math.Clamp(ang.p, -100, 100)
		cmd:SetViewAngles(ang)
	end

	if (inSurrender or inKneel) and CurTime() < weaponAllowTime then
		cmd:SetButtons(bit.band(cmd:GetButtons(), bit.bnot(IN_USE + IN_ATTACK + IN_ATTACK2)))
		cmd:SetImpulse(0)
	end
end)

-- первые WEAPON_LOCK_TIME секунд в руках только кулаки
local function ForceHands(ply)
	local hands = ply:GetWeapon("weapon_hands_sh")
	if IsValid(hands) and ply:GetActiveWeapon() ~= hands then input.SelectWeapon(hands) end
end

hook.Add("PlayerSwitchWeapon", "surrender_block_switch", function(ply, old, new)
	if ply ~= LocalPlayer() or not (inSurrender or inKneel) or CurTime() >= weaponAllowTime then return end
	if IsValid(new) and new:GetClass() == "weapon_hands_sh" then return end
	return true
end)

local function SurrenderForceReset(ply)
	if not inSurrender then return end
	timer.Remove("surrender_loop_timer")
	timer.Remove("surrender_begin_timer")
	timer.Remove("hbh_transition_timer")
	if IsValid(ply) then ply:AnimResetGestureSlot(SURR_SLOT) end
	inSurrender = false
	inHandsBehindHead = false
	hbhTransitioning = false
	currentSurrVariantIndex = 1
	previousSurrVariantIndex = 1
	forcedExiting = false
	weaponReachActive = false
	weaponAllowTime = 0
end

local function KneelForceReset(ply)
	if not inKneel and not kneelExiting then return end
	timer.Remove("kneel_loop_timer")
	timer.Remove("kneel_begin_timer")
	timer.Remove("kneel_exit_timer")
	if IsValid(ply) then ply:AnimResetGestureSlot(KNEEL_SLOT) end
	inKneel = false
	kneelExiting = false
	kneelReady = false
	currentKneelVariantIndex = 1
	kneelBaseYaw = 0
	kneelCD = 0
	standCD = 0
	forcedExiting = false
	weaponReachActive = false
	weaponAllowTime = 0
	net.Start("hg_kneel_hull") net.WriteBool(false) net.SendToServer()
end

local function ForceReset(ply)
	if ply ~= LocalPlayer() then return end
	SurrenderForceReset(ply)
	KneelForceReset(ply)
end

hook.Add("HG_OnOtrub", "surrender_reset", ForceReset)
hook.Add("Player_Death", "surrender_reset", ForceReset)
hook.Add("Fake", "surrender_reset", ForceReset)

hook.Add("Think", "surrender_watch", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not (inSurrender or inKneel or kneelExiting) then
		weaponReachActive = false
		return
	end

	if not ply:Alive() or IsValid(ply.FakeRagdoll) or (ply.organism and ply.organism.otrub) then
		ForceReset(ply)
		return
	end

	if CurTime() < weaponAllowTime then
		ForceHands(ply)
	elseif not weaponReachActive then
		-- взял оружие - сдача кончилась
		local wep = ply:GetActiveWeapon()
		if IsValid(wep) and wep:GetClass() ~= "weapon_hands_sh" then
			weaponReachActive = true
			if inKneel then
				ExitKneel(ply, true)
				timer.Simple(KNEEL_EXIT_DURATION * 0.6, function()
					if inSurrender then ExitSurrender(ply, true) end
					timer.Simple(SURR_EXIT_DURATION, function() weaponReachActive = false end)
				end)
			else
				ExitSurrender(ply, true)
				timer.Simple(SURR_EXIT_DURATION, function() weaponReachActive = false end)
			end
		end
	end

	-- ЛКМ - попытка ударить: опускаем руки
	if forcedExiting or gui.IsGameUIVisible() or vgui.CursorVisible() then return end
	if not (inSurrender or inKneel) or not input.IsMouseDown(MOUSE_LEFT) or CurTime() <= surrenderStartTime + 0.3 then return end

	forcedExiting = true
	weaponAllowTime = math.max(weaponAllowTime, CurTime() + 5)

	if inKneel and inSurrender then
		ExitKneel(ply, true)
		timer.Simple(KNEEL_EXIT_DURATION, function()
			if IsValid(ply) and inSurrender then ExitSurrender(ply) end
			forcedExiting = false
		end)
	elseif inKneel then
		ExitKneel(ply)
		timer.Simple(KNEEL_EXIT_DURATION, function() forcedExiting = false end)
	else
		ExitSurrender(ply)
		timer.Simple(SURR_EXIT_DURATION, function() forcedExiting = false end)
	end
end)

hook.Add("PlayerBindPress", "surrender_block_binds", function(ply, bind, pressed)
	if not (inSurrender or inKneel) then return end
	if string.find(bind, "+attack", 1, true) or string.find(bind, "fake", 1, true) then return true end
	if inKneel and string.find(bind, "hg_kick", 1, true) then return true end
end)

hook.Add("radialOptions", "surrender_option", function()
	local ply = LocalPlayer()
	if not CanStart(ply) then return end

	if kneelExiting then
		hg.radialOptions[#hg.radialOptions + 1] = {function() return -1 end, "Getting Up..."}
		return
	end

	if hbhTransitioning then
		hg.radialOptions[#hg.radialOptions + 1] = {function() return -1 end, "..."}
		return
	end

	if inKneel then
		hg.radialOptions[#hg.radialOptions + 1] = {
			function(mouseClick)
				if mouseClick ~= 2 then ExitKneel(ply) return end
				hg.CreateRadialMenu({
					{function() ExitKneel(ply) end, "Stand Up"},
					inHandsBehindHead and {function() ExitHandsBehindHead(ply) end, "Hands Up (normal)"}
						or {function() EnterHandsBehindHead(ply) end, "Hands Behind Head"},
				})
				return -1
			end,
			inHandsBehindHead and "Kneeling + Hands Behind Head\nRMB - Options" or "Kneeling + Hands Up\nRMB - Options"
		}
		return
	end

	if inSurrender then
		hg.radialOptions[#hg.radialOptions + 1] = {
			function(mouseClick)
				if mouseClick ~= 2 then ExitSurrender(ply) return end
				hg.CreateRadialMenu({
					{function() ExitSurrender(ply) end, "Stop Surrendering"},
					{function() EnterKneel(ply) end, "Kneel Down"},
					inHandsBehindHead and {function() ExitHandsBehindHead(ply) end, "Hands Up (normal)"}
						or {function() EnterHandsBehindHead(ply) end, "Hands Behind Head"},
				})
				return -1
			end,
			inHandsBehindHead and "Surrendering (Hands Behind Head)\nRMB - Options" or "Surrendering\nRMB - Options"
		}
		return
	end

	hg.radialOptions[#hg.radialOptions + 1] = {
		function(mouseClick)
			if CurTime() < surrenderCD then return -1 end
			StartSurrender(ply, mouseClick == 2)
		end,
		"Surrender\nRMB - Kneel+Surrender"
	}
end)

concommand.Add("surrender_toggle", function()
	local ply = LocalPlayer()
	if not CanStart(ply) then return end

	if inSurrender then
		ExitSurrender(ply)
	else
		StartSurrender(ply, false)
	end
end)

concommand.Add("kneel_toggle", function()
	local ply = LocalPlayer()
	if not CanStart(ply) then return end

	if inKneel then
		ExitKneel(ply)
	elseif kneelExiting then
		return
	elseif inSurrender then
		EnterKneel(ply)
	else
		StartSurrender(ply, true)
	end
end)
