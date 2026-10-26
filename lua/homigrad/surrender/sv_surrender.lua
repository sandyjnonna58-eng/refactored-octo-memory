-- Сдача в плен и стойка на коленях (из MELEECITY, автор оригинала adodser).
-- Клиент (cl_surrender.lua) решает, когда поднять руки/встать на колени, и сообщает серверу,
-- сервер проигрывает жест на модели и рассылает его остальным. Анимации - models/surrender_anim (wOS DynaBase).
util.AddNetworkString("hg_surrender_enter")
util.AddNetworkString("hg_surrender_exit")
util.AddNetworkString("hg_surrender_loop")
util.AddNetworkString("hg_surrender_voice")
util.AddNetworkString("hg_kneel_enter")
util.AddNetworkString("hg_kneel_exit")
util.AddNetworkString("hg_kneel_loop")
util.AddNetworkString("hg_kneel_hull")
util.AddNetworkString("hg_kneel_hbh_transition")
util.AddNetworkString("hg_surrender_min_time_sync")

resource.AddFile("models/surrender_anim/m_surrender.mdl")
resource.AddFile("models/surrender_anim/f_surrender.mdl")

local SURR = hg.Surrender or {}
hg.Surrender = SURR

local kneelingPlayers = {}
local kneelTransition = {}
local kneelLockedPos = {}
local surrenderingPlayers = {}

local SURR_EXIT_DURATION = 0.6
local KNEEL_EXIT_DURATION = 1.3
local VOICE_COOLDOWN = 2.5
local NET_COOLDOWN = 0.1

local SURRENDER_MIN_TIME_CVAR = CreateConVar("surrender_min_time", "5", FCVAR_NOTIFY + FCVAR_REPLICATED,
	"Minimum seconds a player must stay surrendered before they can lower their hands.", 0, 300)

local function SyncMinTime(target)
	net.Start("hg_surrender_min_time_sync")
	net.WriteFloat(SURRENDER_MIN_TIME_CVAR:GetFloat())
	if IsValid(target) then net.Send(target) else net.Broadcast() end
end

cvars.AddChangeCallback("surrender_min_time", function() SyncMinTime() end, "surrender_min_time_broadcast")

hook.Add("PlayerInitialSpawn", "surrender_min_time_join_sync", function(ply)
	timer.Simple(2, function()
		if IsValid(ply) then SyncMinTime(ply) end
	end)
end)

local SURR_VARIANTS = {
	{"G_Surrender", "g_surrenderloopArms", "G_Surrenderend"},
	{"G_Surrender2", "g_surrenderloopArms2", "G_Surrenderend2"},
	{"G_Surrender3", "g_surrenderloopArms3", "G_Surrenderend3"},
}

local KNEEL_VARIANTS = {
	{"kneeldown", "kneeldownloop", "kneeldownEND"},
	{"kneeldown2", "kneeldown2loop", "kneeldown2END"},
	{"kneeldown3", "kneeldown3loop", "kneeldown3end"},
}

local KNEEL_HBH_TRANSITIONS = {
	[1] = {"kneeldownTransition", "kneeldownTransitionBack"},
	[2] = {"kneeldown2Transition", "kneeldown2TransitionBack"},
}

local SURR_SLOT = GESTURE_SLOT_ATTACK_AND_RELOAD
local KNEEL_SLOT = GESTURE_SLOT_CUSTOM

local SCARED_LINES = {
	"vo/episode_1/npc/male01/cit_evac_casualty10.wav", "vo/npc/male01/ohno.wav",
	"vo/npc/male01/startle01.wav", "vo/npc/male01/startle02.wav",
	"vo/episode_1/npc/male01/cit_alert_head06.wav", "vo/episode_1/npc/male01/cit_buddykilled04.wav",
	"vo/episode_1/npc/male01/cit_evac_casualty09.wav"
}

local function PlayGesture(ply, slot, seqName, actFallback)
	if not seqName then return end
	local seq = ply:LookupSequence(seqName)
	if seq and seq ~= -1 then
		ply:AddVCDSequenceToGestureSlot(slot, seq, 0, false)
	else
		ply:AnimRestartGesture(slot, actFallback, false)
	end
end

local function ResetSlotLater(ply, slot, delay)
	timer.Simple(delay, function()
		if IsValid(ply) then ply:AnimResetGestureSlot(slot) end
	end)
end

-- клиенты шлют сообщения часто (петли анимаций), но не чаще NET_COOLDOWN на тип
local function Throttled(ply, key)
	ply.remSurrNet = ply.remSurrNet or {}
	if (ply.remSurrNet[key] or 0) > CurTime() then return true end
	ply.remSurrNet[key] = CurTime() + NET_COOLDOWN
	return false
end

local function CanAct(ply)
	return IsValid(ply) and ply:Alive() and not IsValid(ply.FakeRagdoll)
end

local function Relay(name, ply, vi, extra)
	net.Start(name)
	net.WriteEntity(ply)
	net.WriteUInt(vi, 4)
	if extra then net.WriteString(extra) end
	net.SendOmit(ply)
end

net.Receive("hg_surrender_enter", function(len, ply)
	if not CanAct(ply) or Throttled(ply, "enter") then return end
	local vi = net.ReadUInt(4)
	if not SURR_VARIANTS[vi] then return end

	surrenderingPlayers[ply] = true
	ply:SetNWBool("Surrendering", true)
	PlayGesture(ply, SURR_SLOT, SURR_VARIANTS[vi][1], ACT_GMOD_GESTURE_TAUNT_ZOMBIE)
	Relay("hg_surrender_enter", ply, vi)
end)

net.Receive("hg_surrender_loop", function(len, ply)
	if not CanAct(ply) or Throttled(ply, "loop") then return end
	local vi = net.ReadUInt(4)
	if not SURR_VARIANTS[vi] then return end

	PlayGesture(ply, SURR_SLOT, SURR_VARIANTS[vi][2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE)
	Relay("hg_surrender_loop", ply, vi)
end)

net.Receive("hg_surrender_exit", function(len, ply)
	if not IsValid(ply) or Throttled(ply, "exit") then return end
	local vi = net.ReadUInt(4)
	if not SURR_VARIANTS[vi] then return end

	surrenderingPlayers[ply] = nil
	ply:SetNWBool("Surrendering", false)
	PlayGesture(ply, SURR_SLOT, SURR_VARIANTS[vi][3], ACT_GMOD_GESTURE_ITEM_PLACE)
	ResetSlotLater(ply, SURR_SLOT, SURR_EXIT_DURATION)
	Relay("hg_surrender_exit", ply, vi)
end)

-- испуганная фраза при поднятии рук: фразу выбирает сервер, клиент только просит
net.Receive("hg_surrender_voice", function(len, ply)
	if not CanAct(ply) or not surrenderingPlayers[ply] then return end
	if (ply.remSurrVoice or 0) > CurTime() then return end
	ply.remSurrVoice = CurTime() + VOICE_COOLDOWN

	local phrase = SCARED_LINES[math.random(#SCARED_LINES)]
	if ThatPlyIsFemale and ThatPlyIsFemale(ply) then phrase = string.Replace(phrase, "male01", "female01") end
	local muffed = ply.armors and ply.armors["face"] == "mask2"
	ply:EmitSound(phrase, muffed and 75 or 85, ply.VoicePitch or 100, 1, CHAN_AUTO, 0, muffed and 14 or 0)
end)

net.Receive("hg_kneel_enter", function(len, ply)
	if not CanAct(ply) or Throttled(ply, "kenter") then return end
	local vi = net.ReadUInt(4)
	if not KNEEL_VARIANTS[vi] then return end

	kneelingPlayers[ply] = true
	kneelTransition[ply] = CurTime() + 1.5
	kneelLockedPos[ply] = ply:GetPos()
	ply.Kneeling = true
	ply:SetNWBool("Kneeling", true)
	PlayGesture(ply, KNEEL_SLOT, KNEEL_VARIANTS[vi][1], ACT_GMOD_GESTURE_TAUNT_ZOMBIE)
	Relay("hg_kneel_enter", ply, vi)
end)

net.Receive("hg_kneel_loop", function(len, ply)
	if not CanAct(ply) or Throttled(ply, "kloop") then return end
	local vi = net.ReadUInt(4)
	if not KNEEL_VARIANTS[vi] then return end

	PlayGesture(ply, KNEEL_SLOT, KNEEL_VARIANTS[vi][2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE)
	Relay("hg_kneel_loop", ply, vi)
end)

net.Receive("hg_kneel_exit", function(len, ply)
	if not IsValid(ply) or Throttled(ply, "kexit") then return end
	local vi = net.ReadUInt(4)
	if not KNEEL_VARIANTS[vi] then return end

	kneelingPlayers[ply] = nil
	kneelTransition[ply] = CurTime() + KNEEL_EXIT_DURATION
	kneelLockedPos[ply] = nil
	ply.Kneeling = false
	ply:SetNWBool("Kneeling", false)
	PlayGesture(ply, KNEEL_SLOT, KNEEL_VARIANTS[vi][3], ACT_GMOD_GESTURE_ITEM_PLACE)
	ResetSlotLater(ply, KNEEL_SLOT, KNEEL_EXIT_DURATION)
	Relay("hg_kneel_exit", ply, vi)
end)

net.Receive("hg_kneel_hbh_transition", function(len, ply)
	if not CanAct(ply) or Throttled(ply, "hbh") then return end
	local baseVI = net.ReadUInt(4)
	local direction = net.ReadString() == "enter" and "enter" or "exit"
	local t = KNEEL_HBH_TRANSITIONS[baseVI]
	if not t then return end

	PlayGesture(ply, KNEEL_SLOT, direction == "enter" and t[1] or t[2], ACT_GMOD_GESTURE_TAUNT_ZOMBIE)
	Relay("hg_kneel_hbh_transition", ply, baseVI, direction)
end)

net.Receive("hg_kneel_hull", function(len, ply)
	if not IsValid(ply) then return end
	kneelLockedPos[ply] = (net.ReadBool() and kneelingPlayers[ply]) and ply:GetPos() or nil
end)

hook.Add("SetupMove", "kneel_movement_lock_server", function(ply, mv, cmd)
	if not (kneelingPlayers[ply] or (kneelTransition[ply] or 0) > CurTime()) then return end

	mv:SetForwardSpeed(0)
	mv:SetSideSpeed(0)
	mv:SetUpSpeed(0)
	mv:SetVelocity(Vector(0, 0, mv:GetVelocity().z))
	mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_FORWARD + IN_BACK + IN_MOVELEFT + IN_MOVERIGHT + IN_JUMP)))
end)

hook.Add("FinishMove", "kneel_position_lock_server", function(ply, mv)
	local locked = kneelLockedPos[ply]
	if not locked then return end
	local cur = ply:GetPos()
	if cur.x ~= locked.x or cur.y ~= locked.y then
		ply:SetPos(Vector(locked.x, locked.y, cur.z))
	end
end)

local function ClearState(ply)
	if not IsValid(ply) then return end
	kneelingPlayers[ply] = nil
	kneelTransition[ply] = nil
	kneelLockedPos[ply] = nil
	surrenderingPlayers[ply] = nil
	ply.Kneeling = false
	ply:SetNWBool("Kneeling", false)
	ply:SetNWBool("Surrendering", false)
end

function SURR.IsSurrendering(ply)
	return surrenderingPlayers[ply] or kneelingPlayers[ply] or false
end

hook.Add("PlayerDisconnected", "kneel_cleanup", ClearState)
hook.Add("PlayerDeath", "kneel_cleanup_death", ClearState)
hook.Add("PlayerSpawn", "kneel_cleanup_spawn", ClearState)
hook.Add("Fake", "kneel_cleanup_ragdoll", ClearState)

-- на коленях пинаться нельзя (рэгдолл и удары блокирует клиент, cl_surrender.lua)
hook.Add("PlayerCanLegAttack", "surrender_block_kick", function(ply)
	if kneelingPlayers[ply] then return false end
end)
