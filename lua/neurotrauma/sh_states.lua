-- Enumerations shared by server and client: how the head was injured, where, and (from stage 4) the
-- neurological states. Names are for logs and the debug panel.

local NT = NeuroTrauma
NT.E = NT.E or {}
local E = NT.E

local function Enum(names)
	local t = { names = {} }
	for i, n in ipairs(names) do
		t[n] = i - 1
		t.names[i - 1] = string.lower(n)
	end
	return t
end

-- Mechanism of an injury event
E.Mech = Enum({ "UNATTRIBUTED", "RAGDOLL_IMPACT", "WHIPLASH", "BLUNT", "FALL", "PROJECTILE", "BLAST" })

-- Where the head was struck (head space). FACE is the front below the brow.
E.Region = Enum({ "NONE", "FRONT", "BACK", "LEFT", "RIGHT", "TOP", "BASE", "FACE" })

-- What a projectile did to the head
E.Pen = Enum({ "NONE", "GRAZE", "TANGENTIAL", "PENETRATING", "PERFORATING" })

-- Zones a wound track crossed (bit flags). A geometric abstraction of the head, not anatomy:
-- left and right half, the deep middle, the lower rear (where the brainstem lies).
E.Zone = { LEFT = 1, RIGHT = 2, DEEP = 4, LOWER_REAR = 8 }
function E.ZoneText(z)
	local out = {}
	if bit.band(z, 1) ~= 0 then out[#out + 1] = "left" end
	if bit.band(z, 2) ~= 0 then out[#out + 1] = "right" end
	if bit.band(z, 4) ~= 0 then out[#out + 1] = "deep" end
	if bit.band(z, 8) ~= 0 then out[#out + 1] = "lower-rear" end
	return #out > 0 and table.concat(out, "+") or "none"
end

------------------------------------------------------------------------------------------
-- Seeded generator (Park-Miller): every draw an injury makes comes from its own seed, so the same
-- events and seeds give the same course.
------------------------------------------------------------------------------------------
local RNG = {}
RNG.__index = RNG

function NT.RNG(seed)
	seed = math.floor(math.abs(seed or 1)) % 2147483646 + 1
	return setmetatable({ s = seed }, RNG)
end

function RNG:Next()
	local s = (self.s * 16807) % 2147483647
	self.s = s
	return s / 2147483647
end

function RNG:Range(a, b) return a + (b - a) * self:Next() end

function RNG:Normal()
	local u1 = self:Next()
	if u1 < 1e-7 then u1 = 1e-7 end
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * self:Next())
end

-- Logistic step: 0.5 at mid, steeper for smaller k.
function NT.Sigmoid(x, mid, k)
	return 1 / (1 + math.exp(-(x - mid) / k))
end

------------------------------------------------------------------------------------------
-- Neurological states. Exactly one base state; any number of overlays (bit flags). The state is a
-- label derived from the variables of the model, never the other way round.
------------------------------------------------------------------------------------------
E.State = Enum({ "NORMAL", "STUNNED", "CONFUSED", "IMPAIRED", "UNCONSCIOUS", "COMATOSE" })

E.Overlay = {
	SEIZURE = 1, MOTOR_DEFICIT = 2, ABNORMAL_POSTURING = 4, RESPIRATORY_ABNORMALITY = 8,
	AUTONOMIC_INSTABILITY = 16, HERNIATION_LIKE_STATE = 32, CARDIAC_ARREST = 64,
}
E.OverlayNames = {
	{ 1, "seizure" }, { 2, "motor deficit" }, { 4, "abnormal posturing" }, { 8, "respiratory abnormality" },
	{ 16, "autonomic instability" }, { 32, "herniation-like state" }, { 64, "cardiac arrest" },
}
function E.OverlayText(o)
	local out = {}
	for _, e in ipairs(E.OverlayNames) do
		if bit.band(o, e[1]) ~= 0 then out[#out + 1] = e[2] end
	end
	return #out > 0 and table.concat(out, ", ") or "-"
end

-- Kind of abnormal posture
E.Posture = Enum({ "NONE", "FLEXOR", "EXTENSOR", "FENCING" })
