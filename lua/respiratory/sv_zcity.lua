-- Z-City adapter (server): the only file of the module that names a field of Z-City's organism.
-- Z-City owns the lungs: how damaged and how punctured each is, the air in the pleural space, the
-- windpipe, the oxygen store, whether the lungs work at all (lua/homigrad/organism/tier_1/modules/
-- sv_lungs.lua). This file reads those under plain names and writes none of them; where Z-City has
-- a formula of its own, the same formula stands here, so that what the module says of the lungs can
-- never disagree with what Z-City does with them.

local RS = HemoRespiratory
RS.ZC = RS.ZC or {}
local Z = RS.ZC
local L = RS.Link
local max, min = math.max, math.min

local function Clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function N(v, d)
	v = tonumber(v)
	if v == nil or v ~= v then return d end
	return v
end

function Z.Present() return istable(hg) and istable(hg.organism) end

-- In a harness run that asks for no scene of this module, the module acts on nothing (RS.Quiet).
function RS.Active() return RS.Enabled() and not RS.Quiet and Z.Present() end

-- The organism of a body: a player's; the ragdoll's a living player lies in (the same table); a
-- corpse's (the copy Z-City made of it at the death).
function Z.Org(ent)
	if not IsValid(ent) then return nil end
	if istable(ent.organism) then return ent.organism end
	if not ent:IsPlayer() and istable(hg) and isfunction(hg.RagdollOwner) then
		local o = hg.RagdollOwner(ent)
		if IsValid(o) and istable(o.organism) then return o.organism end
	end
	return nil
end

-- The living player a body is, or nil (a corpse, a prop).
function Z.Owner(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent:Alive() and ent or nil end
	if istable(hg) and isfunction(hg.RagdollOwner) then
		local o = hg.RagdollOwner(ent)
		if IsValid(o) and o:IsPlayer() and o:Alive() then return o end
	end
	return nil
end

-- The entity that is a player's body now (the ragdoll while Z-City has laid them down).
function Z.Body(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return ply end
	if istable(hg) and isfunction(hg.GetCurrentCharacter) then
		local c = hg.GetCurrentCharacter(ply)
		if IsValid(c) then return c end
	end
	return ply
end

-- What Z-City keeps of an organism's breathing, and what follows from it. s (optional) is filled
-- and returned.
function Z.Read(org, s)
	s = s or {}
	local owner = org.owner
	local ll, lr, o2, st = org.lungsL, org.lungsR, org.o2, org.stamina
	s.damageL = Clamp(N(istable(ll) and ll[1], 0), 0, 1)
	s.breachL = Clamp(N(istable(ll) and ll[2], 0), 0, 1)
	s.damageR = Clamp(N(istable(lr) and lr[1], 0), 0, 1)
	s.breachR = Clamp(N(istable(lr) and lr[2], 0), 0, 1)
	s.pneumothorax = Clamp(N(org.pneumothorax, 0), 0, 1)
	s.needle = Clamp(N(org.needle, 0), 0, 1)
	s.trachea = Clamp(N(org.trachea, 0), 0, 1)
	s.choking = org.choking == true
	s.vomit = org.vomitInThroat == true
	s.submerged = IsValid(owner) and owner:WaterLevel() >= 3 or false
	s.holding = org.holdingbreath == true
	local range = istable(o2) and N(o2.range, 30) or 30
	s.oxygen = istable(o2) and Clamp(N(o2[1], range) / max(range, 1), 0, 1) or 1
	s.intake = istable(o2) and N(o2.curregen, 0) or 0
	s.demand = N(org.losing_oxy, 0)
	s.works = org.lungsfunction ~= false
	s.alive = org.alive ~= false
	s.heartStopped = org.heartstop == true
	s.heartRate = N(org.heartbeat, 70)
	s.pressure = N(org.pulse, 70)
	s.blood = N(org.blood, 5000)
	s.stamina = (istable(st) and N(st.max, 0) > 0) and Clamp(N(st[1], 0) / N(st.max, 1), 0, 1) or 1
	s.ribs = Clamp(N(org.chest, 0), 0, 1)
	-- (Z-City's one number for the brain: from 0.4 its own lung step lets breaths fail at random)
	s.zbrain = Clamp(N(org.brain, 0), 0, 1)

	-- how far each lung has let go of the chest wall (Z-City keeps one number for both: sh_link.lua)
	s.collapseL, s.collapseR = L.Collapse(s.pneumothorax, s.breachL, s.breachR)
	-- what each lung can still do
	s.shareL = (1 - s.damageL) * (1 - s.collapseL)
	s.shareR = (1 - s.damageR) * (1 - s.collapseR)
	s.capacity = Clamp((s.shareL + s.shareR) / 2, 0, 1)
	-- how open the way of the air is: shut by a grip on the throat, by vomit, under water
	s.patency = (s.choking or s.vomit or s.submerged) and 0 or (1 - s.trachea)
	-- how well the lungs load the blood: Z-City's own factor (its OxygenateBlood, without the store's rate)
	s.ventilation = max(((1 - s.damageL) + (1 - s.damageR)) / 2, 0.5) * (1 - s.trachea) * (s.submerged and 0 or 1)
	-- what the oxygen store can hold now: Z-City's own cap, as a share of the full store
	s.ceiling = max(1 - s.pneumothorax * s.pneumothorax, 0.1) * min(s.blood / 4500, 1) * max(1 - (s.damageL + s.damageR) / 2, 0.5)
	-- is there a breath at all: Z-City's own conditions for the chest it shows
	s.breathing = s.alive and not s.heartStopped and s.works and not s.holding
	return s
end

-- Z-City's own number for how well the lungs load the blood, asked of Z-City itself (for the check
-- that s.ventilation is the same number). nil where its function is not there.
function Z.VentilationByZCity(org)
	if not (Z.Present() and isfunction(hg.organism.OxygenateBlood) and istable(org.o2)) then return nil end
	local regen = N(org.o2.regen, 4)
	if regen <= 0 or not IsValid(org.owner) then return nil end
	local ok, v = pcall(hg.organism.OxygenateBlood, org)
	if not ok or not isnumber(v) then return nil end
	return v / (regen / 4)
end
