-- What clients are told about an injured character. The server alone decides the state; clients
-- only draw it and, for the owner, apply the same limits to predicted movement. Ragdoll limbs are
-- server physics and need no message. The brain itself (regions, vessels, the graph) is never
-- sent: only what it results in.
--
--   nt_state   to everybody who can see the character (PVS) and to its owner, unreliable, when
--              something changes and once a second while a record exists:
--                player 8 | version 8 | present 1
--                state 3 | overlays 7 | motor left 4, right 4 | balance 4 | consciousness 4 |
--                walking speed 4 | posture 2 | seizure phase 3, side 2 | pupils 3 + 3 | seed 5
--                animation mode 4, intensity 4 (sh_anim.lua) | direction of a stagger 3
--                detail 1, and if set:
--                  arm, hand, leg left and right 3 each | face left, right 2 each |
--                  coordination left, right 3 each | hand state left, right 3 each | gaze 2 |
--                  veer 3 | circulation label 4 | seizure category 4
--              77 bits without detail, 124 with.
--   nt_self    to the owner only, unreliable, on change and every two seconds while it is not all
--              normal: what the owner's own senses and language have lost (34 bits).
--
-- The version counts up with every message of a character. A client drops a message that is not
-- newer than the last one it took (unreliable messages can overtake each other); the counter wraps
-- at 256 and "newer" means less than half a turn ahead.
-- A debug stream for developers is separate (sv_debug.lua).

local NT = NeuroTrauma
NT.Net = NT.Net or {}
local N = NT.Net
local C, Z, E = NT.Config, NT.ZC, NT.E
local floor, min, max = math.floor, math.min, math.max

util.AddNetworkString("nt_state")
util.AddNetworkString("nt_self")

local sent = setmetatable({}, { __mode = "k" })   -- organism -> { key, t, selfKey, selfT, version }
-- (the version outlives the record: a new record of the same character must count on from the
-- message that closed the old one, or clients would take it for a late message and drop it)
local versions = setmetatable({}, { __mode = "k" })   -- player -> version of its last message
N.bytes, N.messages, N.selfBytes, N.selfMessages = 0, 0, 0, 0

local function Q(x, levels)
	if x < 0 then x = 0 elseif x > 1 then x = 1 end
	return floor(x * levels + 0.5)
end

-- How fast an injured character walks, as a share of normal: balance, the weaker leg, wakefulness.
-- Quantised here so that the server and the owner's client use the very same number.
function N.MoveQ(st)
	local f = min(st.balance, 0.45 + 0.55 * min(st.legL, st.legR), 0.4 + 0.6 * st.consciousness)
	return Q(f, 15)
end

-- Which way an uneven pair of legs pulls the walk: toward the weak side, -3 .. 3 (positive: to the
-- character's left). Quantised for the same reason.
function N.VeerQ(st)
	local d = st.legR - st.legL          -- left leg weaker: positive
	local c = (st.coordR - st.coordL) * 0.5
	local v = math.Clamp((d + c) * 3, -3, 3)
	return floor(v + (v >= 0 and 0.5 or -0.5))
end

-- What the hand of one side is doing, for the fingers a client draws.
local HAND = { NORMAL = 0, LIMP = 1, FIST = 2, TREMOR = 3, FUMBLE = 4, SPLAY = 5 }
N.Hand = HAND
local function HandState(st, side)
	local hand = side == "L" and st.handL or st.handR
	if hand < 0.6 then return HAND.LIMP end
	return HAND.NORMAL
end

local CARDIO = {}
local CATEGORY = {}

local function Detail(st)
	return st.motorL < 0.97 or st.motorR < 0.97 or st.faceL < 0.97 or st.faceR < 0.97 or st.coordL < 0.97 or st.coordR < 0.97
		or st.gaze ~= 0 or st.sz ~= nil or (st.cardio and st.cardio ~= "NORMAL") or st.postictalUntil ~= nil
end

local function Send(ply, org, st, clear, s)
	local body = Z.Body(ply)
	if not IsValid(body) then return end
	local rf = RecipientFilter()
	rf:AddPVS(body:GetPos())
	if ply:IsPlayer() and not ply:IsBot() then rf:AddPlayer(ply) end
	if rf:GetCount() == 0 then return end
	s.version = ((versions[ply] or 0) + 1) % 256
	versions[ply] = s.version
	if st then st.netVersion = s.version end
	net.Start("nt_state", true)
	net.WriteUInt(ply:EntIndex(), 8)
	net.WriteUInt(s.version, 8)
	-- (one bit says whether a record exists at all: a recovered character may still carry one, with
	-- state and overlays at zero, and the walking speed must stay the same on both sides)
	net.WriteBool(not clear)
	if not clear then
		net.WriteUInt(st.state, 3)
		net.WriteUInt(st.overlays, 7)
		net.WriteUInt(Q(st.motorL, 15), 4)
		net.WriteUInt(Q(st.motorR, 15), 4)
		net.WriteUInt(Q(st.balance, 15), 4)
		net.WriteUInt(Q(st.effective, 15), 4)
		net.WriteUInt(st.moveQ, 4)
		net.WriteUInt(st.postureKind, 2)
		net.WriteUInt(st.seizurePhase or 0, 3)
		net.WriteUInt(st.seizureSide or 0, 2)
		net.WriteUInt(Q((st.pupilL - 0.5) * 2, 7), 3)
		net.WriteUInt(Q((st.pupilR - 0.5) * 2, 7), 3)
		net.WriteUInt(st.netSeed, 5)
		local an = st.anim
		net.WriteUInt(an and an.mode or 0, 4)
		net.WriteUInt(Q(an and an.blend or 0, 15), 4)
		net.WriteUInt(st.stagger and st.stagger.oct or 0, 3)
		local detail = Detail(st)
		net.WriteBool(detail)
		if detail then
			net.WriteUInt(Q(st.armL, 7), 3) net.WriteUInt(Q(st.armR, 7), 3)
			net.WriteUInt(Q(st.handL, 7), 3) net.WriteUInt(Q(st.handR, 7), 3)
			net.WriteUInt(Q(st.legL, 7), 3) net.WriteUInt(Q(st.legR, 7), 3)
			net.WriteUInt(Q(st.faceL, 3), 2) net.WriteUInt(Q(st.faceR, 3), 2)
			net.WriteUInt(Q(st.coordL, 7), 3) net.WriteUInt(Q(st.coordR, 7), 3)
			net.WriteUInt(HandState(st, "L"), 3) net.WriteUInt(HandState(st, "R"), 3)
			net.WriteUInt(st.gaze == 0 and 0 or (st.gaze > 0 and 1 or 2), 2)
			net.WriteUInt(st.veerQ + 3, 3)
			net.WriteUInt(N.CardioIndex(st.cardio), 4)
			net.WriteUInt(N.CategoryIndex(st.category), 4)
		end
	end
	N.bytes = N.bytes + net.BytesWritten()
	N.messages = N.messages + 1
	net.Send(rf)
end

function N.CardioIndex(label)
	if not label then return 0 end
	if not next(CARDIO) and NT.Cardio then for i, n in ipairs(NT.Cardio.States) do CARDIO[n] = i - 1 end end
	return CARDIO[label] or 0
end
function N.CategoryIndex(label)
	if not label then return 0 end
	if not next(CATEGORY) and NT.Seizure then for i, n in ipairs(NT.Seizure.Category) do CATEGORY[n] = i end end
	return CATEGORY[label] or 0
end

-- The owner's own losses: fields of vision (quarter by quarter), neglect of one side, hearing,
-- understanding and reading, memory, attention, sedation.
local function SelfKey(st, ch)
	local k = 0
	local function P(v, bits) k = k * 2 ^ bits + v end
	P(Q(1 - ch.vision_upperL, 3), 2) P(Q(1 - ch.vision_lowerL, 3), 2) P(Q(1 - ch.vision_upperR, 3), 2) P(Q(1 - ch.vision_lowerR, 3), 2)
	P(Q(ch.neglectL, 3), 2) P(Q(ch.neglectR, 3), 2)
	P(Q(1 - ch.hearing, 7), 3) P(Q(1 - ch.language_comprehension, 7), 3) P(Q(1 - ch.reading, 7), 3)
	P(Q(1 - ch.memory, 3), 2) P(Q(1 - ch.attention, 3), 2) P(Q(st.sedation or 0, 7), 3)
	return k
end

local function SendSelf(ply, st, ch, clear)
	net.Start("nt_self", true)
	net.WriteBool(not clear)
	if not clear then
		net.WriteUInt(Q(1 - ch.vision_upperL, 3), 2) net.WriteUInt(Q(1 - ch.vision_lowerL, 3), 2)
		net.WriteUInt(Q(1 - ch.vision_upperR, 3), 2) net.WriteUInt(Q(1 - ch.vision_lowerR, 3), 2)
		net.WriteUInt(Q(ch.neglectL, 3), 2) net.WriteUInt(Q(ch.neglectR, 3), 2)
		net.WriteUInt(Q(1 - ch.hearing, 7), 3)
		net.WriteUInt(Q(1 - ch.language_comprehension, 7), 3)
		net.WriteUInt(Q(1 - ch.reading, 7), 3)
		net.WriteUInt(Q(1 - ch.memory, 3), 2)
		net.WriteUInt(Q(1 - ch.attention, 3), 2)
		net.WriteUInt(Q(st.sedation or 0, 7), 3)
	end
	N.selfBytes = N.selfBytes + net.BytesWritten()
	N.selfMessages = N.selfMessages + 1
	net.Send(ply)
end

function N.Update(ply, org, st, now)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	st.netSeed = st.netSeed or math.random(0, 31)
	st.moveQ = N.MoveQ(st)
	st.veerQ = N.VeerQ(st)
	-- what the keys may do (sh_move.lua), from the values as the client is sent them; worked out
	-- here, once per step of the model, not with every command of every player
	st.mayRun, st.mayJump, st.mayFire, st.mayAim = NT.Control(Q(st.legL, 7) / 7, Q(st.legR, 7) / 7, Q(st.handL, 7) / 7, Q(st.handR, 7) / 7, Q(st.balance, 15) / 15, st.veerQ)
	st.category = NT.Seizure and NT.Seizure.CategoryOf(st, now) or nil
	local key = st.state + st.overlays * 8 + Q(st.motorL, 15) * 1024 + Q(st.motorR, 15) * 16384 + Q(st.balance, 15) * 262144
		+ st.moveQ * 4194304 + (st.seizurePhase or 0) * 67108864 + st.postureKind * 536870912
		+ (Q((st.pupilL - 0.5) * 2, 7) + Q((st.pupilR - 0.5) * 2, 7) * 8 + Q(st.effective, 15) * 64) * 2147483648
	-- (the detail block changes more rarely; its own key)
	local key2 = Q(st.armL, 7) + Q(st.armR, 7) * 8 + Q(st.handL, 7) * 64 + Q(st.handR, 7) * 512 + Q(st.legL, 7) * 4096 + Q(st.legR, 7) * 32768
		+ Q(st.faceL, 3) * 262144 + Q(st.faceR, 3) * 1048576 + Q(st.coordL, 7) * 4194304 + Q(st.coordR, 7) * 33554432
		+ (st.gaze + 1) * 268435456 + (st.veerQ + 3) * 1073741824 + N.CardioIndex(st.cardio) * 8589934592 + N.CategoryIndex(st.category) * 137438953472
	local an = st.anim
	local key3 = an and (an.mode + Q(an.blend, 15) * 16 + (st.stagger and st.stagger.oct or 0) * 256) or 0
	local s = sent[org]
	if not s then s = { key = -1, key2 = -1, key3 = -1, t = 0, selfKey = 0, selfT = 0, version = 0 } sent[org] = s end
	if key ~= s.key or key2 ~= s.key2 or key3 ~= s.key3 or now - s.t >= 1 then
		s.key, s.key2, s.key3, s.t = key, key2, key3, now
		Send(ply, org, st, false, s)
	end
	-- the owner's block
	if not ply:IsBot() or N.selfToBots then
		local ch = NT.Anatomy.Channels(st)
		local sk = SelfKey(st, ch)
		if sk ~= s.selfKey or (sk ~= 0 and now - s.selfT >= 2) then
			s.selfKey, s.selfT = sk, now
			SendSelf(N.selfToBots or ply, st, ch, false)
		end
	end
end

hook.Add("NT_Closed", "NT_Net", function(ply, org)
	local s = sent[org]
	if s then
		sent[org] = nil
		if IsValid(ply) and ply:IsPlayer() then
			Send(ply, org, nil, true, s)
			if not ply:IsBot() then SendSelf(ply, nil, nil, true) end
		end
	end
end)

-- Walking speed, server side (the owner's client applies the same factor: sh_move.lua)
function N.MoveFactor(ply)
	local org = ply.organism
	local st = org and NT.Get(org)
	if not st or not st.moveQ then return 1 end
	return C.Motor.moveFloor + (1 - C.Motor.moveFloor) * st.moveQ / 15
end
