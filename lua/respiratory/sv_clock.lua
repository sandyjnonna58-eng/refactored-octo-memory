-- Server: the breathing of every living character. One record an organism, stepped where Z-City
-- steps the organism (its hook "Org Think", ten times a second), and the only writer of it.
--
-- A record holds what Z-City keeps of the lungs (read through sv_zcity.lua, never written), what
-- the brain still drives of the breathing (asked of the brain module, sv_bridge.lua), what others
-- have asked of this module (RS.Modify), and the clock that follows from all of it: where in a
-- breath the character is, how fast and how deep it breathes, and whether it breathes at all.
-- The clock is what clients are told (sv_net.lua); everything a client draws follows from it
-- (sh_link.lua). Nothing a client draws comes back.
--
-- Whether there is a breath is Z-City's to say and the brain module's through it: no breath while
-- the lungs do not work (Z-City's lungsfunction, into which the brain module writes its pauses and
-- its stops), while the heart stands, in death. A breath held on purpose, and a head under water,
-- is a breath held. When the brain module moves the chest of an unconscious body itself, the clock
-- runs with that movement instead of beside it.

local RS = HemoRespiratory
local C, CK, Z, BR = RS.Config, RS.Clock, RS.ZC, RS.Brain
RS.Clocks = RS.Clocks or {}
local K = RS.Clocks
local abs = math.abs
local Clamp = CK.Clamp

-- organism -> record (an organism that is gone takes its record with it)
local recs = setmetatable({}, { __mode = "k" })
K.recs = recs
K.stats = K.stats or { steps = 0, jumps = 0, made = 0, cleared = 0 }

local function New(org, owner, now)
	local idx = IsValid(owner) and owner:EntIndex() or 0
	K.stats.made = K.stats.made + 1
	local rate, depth = C.sv.rate:GetFloat(), C.sv.depth:GetFloat()
	return {
		org = org, owner = owner, born = now, stepped = now,
		ver = 0,                 -- raised whenever the clock does not simply run on (sv_net.lua sends at once)
		s = {}, mods = {}, noAir = 0, latched = false,
		-- (characters do not all breathe in step: where each starts is its entity's number's)
		clock = { t = now, phase = (idx * 0.37) % 1, rate = rate, depth = depth, mode = CK.BREATHING, sym = false },
		target = { rate = rate, depth = depth, want = 0 },
		follows = "own", label = "NORMAL",
	}
end

-- What others have asked of the breathing, applied to what was read; returns the factors on rate and depth.
local function Mods(r, s, now)
	local rf, df = 1, 1
	for src, m in pairs(r.mods) do
		if m.till and now >= m.till then
			r.mods[src] = nil
		else
			rf, df = rf * m.rate, df * m.depth
			s.shareL, s.shareR, s.patency = s.shareL * m.left, s.shareR * m.right, s.patency * m.airway
		end
	end
	s.capacity = Clamp((s.shareL + s.shareR) / 2, 0, 1)
	return rf, df
end

-- Where a breath that was an even rise and fall stands in a breath of in, out and pause (and back):
-- the same fullness, on the same slope.
local function FromSym(phase, rate)
	local a, b = CK.Shares(rate)
	if phase < 0.5 then return phase * 2 * a end
	return a + ((phase - 0.5) * 2) ^ (1 / C.Breath.outCurve) * b
end

function K.Step(owner, org, now)
	local r = recs[org]
	if not r then r = New(org, owner, now) recs[org] = r end
	r.owner = owner
	local c, B = r.clock, C.Breath
	local dt = Clamp(now - r.stepped, 0, 1)
	r.stepped = now
	K.stats.steps = K.stats.steps + 1

	local s = Z.Read(org, r.s)
	local rf, df = Mods(r, s, now)

	-- Air that does not get in although everything is there that should make it: Z-City reads a grip
	-- on the throat and clears it in the same step, so the grip itself may not be there to read;
	-- what it does is. Leaky, so that one step without air is not an airway shut. Not counted while
	-- Z-City's own rule for a damaged brain lets breaths fail at random: that is no airway shut
	-- (seen in the game: a character whose breathing the brain module had made irregular was called
	-- obstructed half the time).
	local trying = s.breathing and s.pressure > 20 and s.stamina > 0 and s.zbrain < 0.4
	r.noAir = Clamp(r.noAir + ((trying and s.intake <= 0) and dt or -dt), 0, B.blockedAfter * 2)
	if r.noAir >= B.blockedAfter then r.latched = true elseif r.noAir <= B.blockedAfter * 0.4 then r.latched = false end
	if s.patency <= 0 then
		s.blocked, s.blockedWhy = true, s.submerged and "water" or (s.vomit and "vomit" or (s.choking and "grip" or "shut"))
	elseif r.latched then
		s.blocked, s.blockedWhy, s.patency = true, "no air enters", 0
	else
		s.blocked, s.blockedWhy = false, nil
	end

	-- what the brain still drives of it (nil: the brain module has nothing to say of this character)
	local control, pattern, pname = BR.Drive(org)
	r.control, r.pattern, r.patternName = control, pattern, pname

	local mode
	local alive = s.alive and (not owner:IsPlayer() or owner:Alive())
	if not alive or s.heartStopped or not s.works then
		mode = CK.STOPPED
	elseif s.holding or s.submerged then
		mode = CK.HELD
	else
		mode = CK.BREATHING
	end
	-- One step of "the lungs work" after a stop is not yet a breath. (Z-City's own step says so at
	-- random now and then for lungs the brain module is holding still, and that module takes it back
	-- in the same round: seen in the game as a breath that began and ended within a tenth of a
	-- second, every couple of seconds of a pause.)
	if mode == CK.BREATHING and c.mode == CK.STOPPED then
		r.wake = (r.wake or 0) + 1
		if r.wake < 2 then mode = CK.STOPPED end
	else
		r.wake = 0
	end

	local rate, depth, want = CK.Target(s, control, rf, df)
	local t = r.target
	t.rate, t.depth, t.want = rate, depth, want

	-- the clock, brought to now as it ran
	local phase = CK.PhaseAt(c, now)
	local jump = false
	if mode ~= c.mode then
		-- a breath begins again: with a breath in after a stop, with the breath out after one held
		if mode == CK.BREATHING then phase = (c.mode == CK.HELD) and (CK.Shares(c.rate)) or 0 end
		c.mode = mode
		jump = true
	end
	local hz, bphase
	if mode == CK.BREATHING and owner:IsPlayer() then hz, bphase = BR.RagdollBreath(owner) end
	if hz then
		-- the brain module is moving this chest: its breath is the breath
		local d = (bphase - phase + 0.5) % 1 - 0.5
		if not c.sym or abs(d) > 0.02 or abs(c.rate - hz * 60) > 0.01 then
			c.sym, c.rate, phase = true, hz * 60, bphase
			jump = true
		end
		r.follows = "brain"
	else
		if c.sym then
			c.sym = false
			phase = FromSym(phase, c.rate)
			jump = true
		end
		c.rate = CK.Toward(c.rate, rate, dt, rate > c.rate and B.tauUp or B.tauDown)
		r.follows = "own"
	end
	c.depth = CK.Toward(c.depth, depth, dt, depth > c.depth and B.tauUp or B.tauDown)
	c.phase, c.t = phase - math.floor(phase), now
	if jump then
		r.ver = r.ver + 1
		K.stats.jumps = K.stats.jumps + 1
	end

	local label = RS.LabelOf and RS.LabelOf(r) or "NORMAL"
	if label ~= r.label then
		local was = r.label
		r.label = label
		r.labelAt = now
		hook.Run("RS_StateChanged", owner, label, was)
	end
	return r
end

-- The record of an organism that is stepped, or nil.
function K.Of(org) return recs[org] end

-- A record for an organism that is not stepped (a corpse's, a dead player's): what Z-City keeps of
-- it, and no breath. Made when asked for, kept half a second.
local peeks = setmetatable({}, { __mode = "k" })
function K.Peek(org, owner, now)
	local r = peeks[org]
	if r and now - r.stepped < 0.5 then return r end
	r = r or New(org, owner, now)
	r.owner, r.stepped = owner, now
	local s = Z.Read(org, r.s)
	s.blocked, s.blockedWhy = s.patency <= 0, nil
	local c = r.clock
	c.mode, c.phase, c.t, c.sym = CK.STOPPED, 0, now, false
	r.target.rate, r.target.depth, r.target.want = 0, 0, 0
	r.control, r.pattern, r.patternName = nil, nil, nil
	r.follows, r.label = "own", "NOT_BREATHING"
	peeks[org] = r
	return r
end

hook.Add("Org Think", "RS_Clock", function(owner, org)
	if not RS.Active() then return end
	-- (corpses have organisms too, and Z-City steps every one of them: a corpse does not breathe, and
	-- nothing is kept or worked out for it until somebody asks, K.Peek)
	if not IsValid(owner) or not owner:IsPlayer() then return end
	K.Step(owner, org, CurTime())
end)

-- Z-City empties an organism at a death and at a real spawn (not when a character gets up from the
-- ground): the breathing starts anew with it.
hook.Add("Org Clear", "RS_Clock", function(org)
	if not istable(org) then return end
	if recs[org] then
		recs[org] = nil
		K.stats.cleared = K.stats.cleared + 1
	end
	peeks[org] = nil
end)

hook.Add("PlayerDisconnected", "RS_Clock", function(ply)
	local org = ply.organism
	if istable(org) then recs[org], peeks[org] = nil, nil end
end)

------------------------------------------------------------------------------------------
-- What others ask of the breathing
------------------------------------------------------------------------------------------
local function Num(v, d, a, b)
	v = tonumber(v)
	if v == nil or v ~= v then return d end
	return Clamp(v, a, b)
end

-- A source (any name of the caller's own) asks for the breathing of a living character to be
-- changed: t.rate and t.depth are factors on how fast and how deep (1: as it would be); t.left and
-- t.right on what each lung can do, t.airway on how open the way of the air is (0..1); t.ttl:
-- seconds it holds (none: until RS.Unmodify, a death or a spawn). The same source asking again
-- replaces what it asked before. Changes what this module says and shows, and nothing of
-- Z-City's: what the lungs give the blood is Z-City's arithmetic on Z-City's fields.
function RS.Modify(who, source, t)
	if not isstring(source) or source == "" then return false, "a source's name is needed" end
	if not istable(t) then return false, "what is asked must be a table" end
	local org = Z.Org(who)
	local owner = org and org.owner
	if not org or not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then return false, "no living character" end
	local now = CurTime()
	local r = recs[org]
	if not r then r = New(org, owner, now) recs[org] = r end
	local ttl = tonumber(t.ttl)
	r.mods[source] = {
		rate = Num(t.rate, 1, 0.25, 4), depth = Num(t.depth, 1, 0.1, 4),
		left = Num(t.left, 1, 0, 1), right = Num(t.right, 1, 0, 1), airway = Num(t.airway, 1, 0, 1),
		till = ttl and ttl > 0 and now + ttl or nil,
	}
	return true
end

function RS.Unmodify(who, source)
	local org = Z.Org(who)
	local r = org and recs[org]
	if not r then return false end
	if source == nil then
		local n = table.Count(r.mods)
		r.mods = {}
		return n > 0
	end
	local had = r.mods[source] ~= nil
	r.mods[source] = nil
	return had
end
