-- Server: the respiratory state of a character as others read it.
--
--   RS.Read(who)       who: a player, a body (a ragdoll a player lies in, a corpse), an organism.
--                      Returns the state, or nil (no organism, or the module is switched off).
--                      Read-only: the table is the module's own and is filled again at every
--                      step; copy what is kept.
--   hook RS_StateChanged(owner, label, was)     the label of a living character has changed
--
-- The state:
--   mode        "breathing", "held", "stopped";  breathing: true while a breath runs
--   label       one of RS.Labels: what the breathing is like, in one word
--   rate        breaths a minute now;  depth: of a breath now (1: a quiet one); both 0 while no breath is taken
--   target      { rate, depth, want }: where rate and depth are going, and how much more air is asked for (0..1)
--   airway      { patency 0..1, blocked, why, trachea }
--   lungs       { l = { damage, breach, collapse, share }, r = the same, capacity }      all 0..1
--   pleura      { pneumothorax, needle }
--   ventilation how well the lungs load the blood now, 0..1 (Z-City's own factor; 0 while no air moves)
--   exchange    the same whether or not air moves: what the lungs could do
--   moving      air moved a minute against a breath at rest (0 while no breath; above 1 when breathing hard)
--   oxygen      { now, ceiling, intake, demand, falling }: Z-City's oxygen store as shares of the full store
--   drive       { control (0..1 or nil), pattern, patternName, kind, brain }: what the brain module says of it
--   follows     "own" or "brain" (the brain module moves this chest; the clock runs with it)
--   clock       { t, phase, rate, depth, mode, sym }: what clients are told (sh_clock.lua)
--   mods        the sources that have asked for a change (RS.Modify)
--   ver, t      the clock's version, and the game time of the step
-- Rate, depth, mode and label are what the breathing does; damage, breach, collapse and patency are
-- what is wrong; neither is a picture, and no picture is in here.

local RS = HemoRespiratory
local C, CK, Z, BR, K = RS.Config, RS.Clock, RS.ZC, RS.Brain, RS.Clocks

-- What the breathing of a record is like (RS.Labels, sh_clock.lua). The worst that is true of it.
function RS.LabelOf(r)
	local s, c, B = r.s, r.clock, C.Breath
	local kind = BR.PatternKind(r.pattern)
	-- (the brain module's gasps of an arrest: no breath runs, and it is not simply none either)
	if kind == "gasping" then return "AGONAL" end
	if c.mode == CK.STOPPED then return "NOT_BREATHING" end
	if c.mode == CK.HELD then return "HELD" end
	if s.blocked or s.patency < B.obstructedBelow then return "OBSTRUCTED" end
	if s.capacity < B.labouredBelow then return "LABOURED" end
	if kind == "irregular" then return "IRREGULAR" end
	if c.rate >= B.fastAt then return "FAST" end
	if c.depth <= B.shallowAt then return "SHALLOW" end
	return "NORMAL"
end

local function Publish(r)
	local p = r.pub
	if p and p.t == r.stepped then return p end
	if not p then
		p = { target = {}, airway = {}, lungs = { l = {}, r = {} }, pleura = {}, oxygen = {}, drive = {}, mods = {} }
		r.pub = p
	end
	local s, c = r.s, r.clock
	p.ver, p.t = r.ver, r.stepped
	p.mode, p.breathing, p.label = CK.ModeName[c.mode], c.mode == CK.BREATHING, r.label
	-- (no breath is taken while one is held or none is there: the clock keeps the pace it will go on at)
	p.rate, p.depth = p.breathing and c.rate or 0, p.breathing and c.depth or 0
	p.target.rate, p.target.depth, p.target.want = r.target.rate, r.target.depth, r.target.want
	local a = p.airway
	a.patency, a.blocked, a.why, a.trachea = s.patency, s.blocked == true, s.blockedWhy, s.trachea
	local l, rr = p.lungs.l, p.lungs.r
	l.damage, l.breach, l.collapse, l.share = s.damageL, s.breachL, s.collapseL, s.shareL
	rr.damage, rr.breach, rr.collapse, rr.share = s.damageR, s.breachR, s.collapseR, s.shareR
	p.lungs.capacity = s.capacity
	p.pleura.pneumothorax, p.pleura.needle = s.pneumothorax, s.needle
	local moves = c.mode == CK.BREATHING and not s.blocked
	p.exchange = s.ventilation
	p.ventilation = moves and s.ventilation or 0
	local rest = math.max(C.sv.rate:GetFloat() * C.sv.depth:GetFloat(), 0.01)
	p.moving = c.mode == CK.BREATHING and c.rate * c.depth / rest * s.patency * s.capacity or 0
	local o = p.oxygen
	o.now, o.ceiling, o.intake, o.demand, o.falling = s.oxygen, s.ceiling, s.intake, s.demand, s.intake < s.demand
	local d = p.drive
	d.control, d.pattern, d.patternName, d.kind, d.brain = r.control, r.pattern, r.patternName, BR.PatternKind(r.pattern), BR.Available()
	p.follows, p.clock = r.follows, c
	for k in pairs(p.mods) do p.mods[k] = nil end
	for src in pairs(r.mods) do p.mods[#p.mods + 1] = src end
	table.sort(p.mods)
	return p
end

-- The record behind a state (the module's own files use it: sv_net.lua, sv_dev.lua).
function RS.RecordOf(who)
	local org
	if istable(who) and not IsEntity(who) then org = who else org = Z.Org(who) end
	if not istable(org) then return nil end
	local owner = org.owner
	if not IsValid(owner) then return nil end
	local now = CurTime()
	if owner:IsPlayer() and owner:Alive() then
		-- (asked for before Z-City has stepped this organism for the first time: stepped now)
		local r = K.Of(org)
		if not r or now - r.stepped > 1 then r = K.Step(owner, org, now) end
		return r
	end
	-- a corpse, a player who is dead: what Z-City keeps of it, and no breath
	return K.Peek(org, owner, now)
end

function RS.Read(who)
	if not RS.Active() then return nil end
	local r = RS.RecordOf(who)
	return r and Publish(r) or nil
end

-- A state as lines of text (the developer command and the tests).
function RS.Describe(who)
	local p = RS.Read(who)
	if not p then return { "no organism" } end
	local c = p.clock
	local lines = {}
	lines[#lines + 1] = string.format("%s: %s (%s) | %.1f breaths a minute, depth %.2f | going to %.1f and %.2f, wants %.0f%% more air | clock v%d phase %.2f%s, follows %s",
		tostring(IsEntity(who) and who or "organism"), p.label, p.mode, p.rate, p.depth, p.target.rate, p.target.depth, p.target.want * 100, p.ver, CK.PhaseAt(c, CurTime()), c.sym and " (even)" or "", p.follows)
	lines[#lines + 1] = string.format("  airway: open %.2f%s, windpipe damage %.2f | left lung: damage %.2f puncture %.2f let go %.2f, can do %.2f | right: %.2f %.2f %.2f, %.2f | both %.2f",
		p.airway.patency, p.airway.blocked and (" BLOCKED (" .. tostring(p.airway.why) .. ")") or "", p.airway.trachea, p.lungs.l.damage, p.lungs.l.breach, p.lungs.l.collapse, p.lungs.l.share,
		p.lungs.r.damage, p.lungs.r.breach, p.lungs.r.collapse, p.lungs.r.share, p.lungs.capacity)
	lines[#lines + 1] = string.format("  air in the pleural space %.2f (needle %.2f) | loads the blood %.2f (could: %.2f), moves %.2f of a breath at rest | oxygen %.2f of %.2f, in %.4f out %.4f a step%s",
		p.pleura.pneumothorax, p.pleura.needle, p.ventilation, p.exchange, p.moving, p.oxygen.now, p.oxygen.ceiling, p.oxygen.intake, p.oxygen.demand, p.oxygen.falling and " FALLING" or "")
	lines[#lines + 1] = string.format("  brain: %s%s | asked for by: %s", p.drive.brain and (p.drive.control and string.format("drives %.2f of it, pattern %s", p.drive.control, tostring(p.drive.patternName)) or "no record of this character (all of it)") or "module not loaded",
		p.follows == "brain" and "; it moves this chest itself" or "", #p.mods > 0 and table.concat(p.mods, ", ") or "nobody")
	return lines
end
