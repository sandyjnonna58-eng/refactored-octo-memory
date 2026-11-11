-- Wound event model (shared).
-- A projectile hit is described once, on the server, from what Z-City's damage pipeline works out
-- for that bullet (which organ, bone and artery boxes it crossed, whether it left the body, what was
-- fired and from how far), and sent as one compact event. Every client expands it into a wound
-- record (cl_wounds.lua) that drives the marks on the body, the first release of blood and how the
-- wound bleeds and ages. This file holds what both realms agree on: the classes, the structure
-- flags and the wire format.
--
-- This is a physically informed approximation for a game, not a medical model. Z-City stays the
-- authority for anatomy (its organ boxes), bleeding volume, pulse and death; ABL reads them.

ABL.Wound = ABL.Wound or {}
local WD = ABL.Wound

-- What became of the projectile.
--   SOFT      crossed no organ / bone box: skin, fat and muscle only (a graze when shallow)
--   RETAINED  stopped inside the body: no exit
--   THROUGH   left the body again
--   ARMOR     stopped by an armour piece before reaching tissue
WD.PEN_SOFT, WD.PEN_RETAINED, WD.PEN_THROUGH, WD.PEN_ARMOR = 0, 1, 2, 3
WD.PenNames = { [0] = "soft tissue", "retained", "through and through", "stopped by armour" }

-- Muzzle to skin (thresholds: C.Wound.contactDist / nearDist / mediumDist). What is left on the
-- skin around an entry differs: contact (muzzle imprint, soot driven into the wound, searing), near
-- (soot on the skin and stippling), medium (stippling only), distant or unknown (neither).
WD.RANGE_DISTANT, WD.RANGE_CONTACT, WD.RANGE_NEAR, WD.RANGE_MEDIUM = 0, 1, 2, 3
WD.RangeNames = { [0] = "distant", "contact", "near", "medium" }

-- Structures on the projectile's path.
local F = {
	BONE = 1, SKULL = 2, BRAIN = 4, ARTERY = 8, LUNG = 16, HEART = 32, ABDOMEN = 64, SPINE = 128,
	ARMOR = 256,         -- an armour piece was struck first (the projectile reached tissue through it)
	INTERMEDIATE = 512,  -- the projectile had already passed through something else (another body, a prop)
	JAW = 1024, AIRWAY = 2048,
}
WD.F = F
WD.FLAG_BITS = 12
WD.FlagNames = {
	{ F.BONE, "bone" }, { F.SKULL, "skull" }, { F.BRAIN, "brain" }, { F.ARTERY, "artery" }, { F.LUNG, "lung" },
	{ F.HEART, "heart" }, { F.ABDOMEN, "abdominal organ" }, { F.SPINE, "spine" }, { F.ARMOR, "armour first" },
	{ F.INTERMEDIATE, "intermediate target" }, { F.JAW, "jaw" }, { F.AIRWAY, "airway" },
}

-- What one of Z-City's organ boxes means for the wound, by the box's name. Returns flags, isArmour.
local organFlags = {
	skull = F.BONE + F.SKULL, jaw = F.BONE + F.JAW, brain = F.BRAIN,
	chest = F.BONE, pelvis = F.BONE,
	spine1 = F.BONE + F.SPINE, spine2 = F.BONE + F.SPINE, spine3 = F.BONE + F.SPINE,
	heart = F.HEART, lungsL = F.LUNG, lungsR = F.LUNG,
	liver = F.ABDOMEN, stomach = F.ABDOMEN, intestines = F.ABDOMEN,
	trachea = F.AIRWAY,
	arteria = F.ARTERY, spineartery = F.ARTERY,
}
function WD.OrganFlags(name)
	if not isstring(name) then return 0, false end
	local f = organFlags[name]
	if f then return f, false end
	if string.find(name, "artery", 1, true) then return F.ARTERY, false end
	-- limb bones: rarmup, larmdown, rlegup, ...
	if string.find(name, "armup", 1, true) or string.find(name, "armdown", 1, true)
		or string.find(name, "legup", 1, true) or string.find(name, "legdown", 1, true) then return F.BONE, false end
	if string.find(name, "vest", 1, true) or string.find(name, "helmet", 1, true) or string.find(name, "armor", 1, true)
		or string.find(name, "mask", 1, true) or string.find(name, "visor", 1, true) then return F.ARMOR, true end
	return 0, false
end

function WD.FlagText(flags)
	local out = {}
	for _, e in ipairs(WD.FlagNames) do
		if bit.band(flags, e[1]) ~= 0 then out[#out + 1] = e[2] end
	end
	return #out > 0 and table.concat(out, ", ") or "none"
end

------------------------------------------------------------------------------------------
-- Projectile classes
------------------------------------------------------------------------------------------
-- Energy class from the muzzle energy (J): 1 minimal (.22, rubber, single pellets), 2 low (service
-- pistols), 3 medium (magnums, heavy subsonic), 4 high (intermediate rifle cartridges), 5 very high
-- (full-power rifle, slugs), 6 extreme (anti-materiel). 0: unknown.
WD.EnergyJ = { 180, 650, 1400, 2600, 6000 }
WD.EnergyNames = { [0] = "unknown", "minimal", "low", "medium", "high", "very high", "extreme" }
function WD.EnergyClass(massG, speedMS)
	if not massG or not speedMS or massG <= 0 or speedMS <= 0 then return 0, 0 end
	local ke = 0.5 * (massG / 1000) * speedMS * speedMS
	local c = 1
	for i = 1, #WD.EnergyJ do
		if ke >= WD.EnergyJ[i] then c = i + 1 end
	end
	return c, ke
end

-- Without projectile data (a plain engine bullet): from the damage it does.
function WD.EnergyClassFromDamage(damage, buckshot)
	if buckshot then return 1 end
	damage = damage or 25
	if damage < 14 then return 1 elseif damage < 34 then return 2 elseif damage < 55 then return 3 elseif damage < 85 then return 4 end
	return 5
end

-- Velocity class: 1 below 400 m/s (most pistols, subsonic rifle), 2 up to 700 m/s, 3 above (the range
-- in which the temporary cavity around the track becomes a real source of damage). 0: unknown.
function WD.VelocityClass(speedMS)
	if not speedMS or speedMS <= 0 then return 0 end
	if speedMS < 400 then return 1 elseif speedMS < 700 then return 2 end
	return 3
end

-- Projectile diameter on the wire: 0 unknown, else 3 + n mm.
function WD.DiameterCode(mm)
	if not mm or mm < 3.5 then return 0 end
	return math.Clamp(math.Round(mm - 3), 1, 15)
end
function WD.DiameterMM(code)
	if not code or code <= 0 then return nil end
	return 3 + code
end

------------------------------------------------------------------------------------------
-- Wire format (appended to abl_hit, see sh_net.lua)
------------------------------------------------------------------------------------------
function WD.Write(rec)
	net.WriteUInt(rec.pen or 0, 2)
	net.WriteUInt(rec.energy or 0, 3)
	net.WriteUInt(rec.velocity or 0, 2)
	net.WriteUInt(rec.diameter or 0, 4)
	net.WriteUInt(rec.range or 0, 2)
	net.WriteUInt(bit.band(rec.flags or 0, 2 ^ WD.FLAG_BITS - 1), WD.FLAG_BITS)
	net.WriteUInt(rec.seed or 0, 16)
end

function WD.Read(ev)
	ev.pen = net.ReadUInt(2)
	ev.energy = net.ReadUInt(3)
	ev.velocity = net.ReadUInt(2)
	ev.diameter = net.ReadUInt(4)
	ev.range = net.ReadUInt(2)
	ev.flags = net.ReadUInt(WD.FLAG_BITS)
	ev.seed = net.ReadUInt(16)
	return ev
end
