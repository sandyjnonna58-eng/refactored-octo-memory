-- Every switch and constant of the respiratory module.
-- Units: game units, taken as an inch where a volume is spoken of (as the blood and the brain
-- module take them). Rates are breaths a minute; times are seconds; shares are 0..1.

HemoRespiratory.Config = HemoRespiratory.Config or {}
local RS = HemoRespiratory
local C = RS.Config

local SV = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
C.sv = {
	enabled = CreateConVar("resp_enabled", "1", SV, "Respiratory module master switch (the breathing state and its clock; the view has its own)", 0, 1),
	-- Z-City makes the breath a player sees on each client, on that client's own clock. With this
	-- on, that clock is set from the server's breathing state, so that chest, breath sound and lungs
	-- are one breath on every screen. 0: Z-City's chest runs exactly as shipped.
	chest = CreateConVar("resp_zcity_chest", "1", SV, "Z-City's visible breathing follows the respiratory module's clock (0: Z-City's own, as shipped)", 0, 1),
	rate = CreateConVar("resp_rate", "14", SV, "Breaths a minute at rest", 6, 30),
	depth = CreateConVar("resp_depth", "1", SV, "Depth of a breath at rest (1: a quiet breath)", 0.3, 2),
	-- (not archived: a developer mode does not come back by itself after a restart)
	dev = CreateConVar("resp_dev", "0", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "Respiratory developer commands and the lung view (superadmin)", 0, 1),
}

function RS.Enabled() return C.sv.enabled:GetBool() end

-- Who may use the developer commands and the view: the skeleton module's rule, which is the brain
-- module's: a superadmin (or the listen server's host, or the console) while resp_dev is 1.
function RS.DevAllowed(ply)
	if not C.sv.dev:GetBool() then return false end
	if SERVER and not IsValid(ply) then return true end
	if not IsValid(ply) then return false end
	return ply:IsSuperAdmin() or ply:IsListenServerHost() or game.SinglePlayer()
end

------------------------------------------------------------------------------------------
-- The breathing. Ours to set: none of these numbers is a measurement of anybody, and none is
-- Z-City's. What they are meant to give: a character at rest breathes fourteen times a minute,
-- in for two fifths of a breath, out a little longer, then a short pause; asked for more air it
-- breathes faster and deeper within some seconds and loses the pause; lungs that can do less are
-- breathed with faster and shallower.
------------------------------------------------------------------------------------------
C.Breath = {
	-- Limits: whatever is asked of it, a breathing character's rate and depth stay within these.
	rateMin = 4, rateMax = 44,
	depthMin = 0.15, depthMax = 2.6,

	-- More air. What asks for it: exertion, read off Z-City's heart rate (none at hrRest, all of it
	-- at hrFull) and off its stamina (an empty one counts as staminaShare of all); and Z-City's
	-- oxygen store (none above o2Ok of the full store, all of it at o2Low). The most of the three.
	hrRest = 70, hrFull = 170,
	staminaShare = 0.8,
	o2Ok = 0.85, o2Low = 0.4,
	rateDemand = 34, depthDemand = 2.2,        -- rate and depth when all of it is asked for
	tauUp = 2.5, tauDown = 6,                  -- s in which rate and depth go most of the way up, and down again

	-- Lungs that can do nothing at all: this much faster, this much shallower (in proportion for less).
	labouredRate = 0.6, labouredDepth = 0.45,

	-- One breath. Of what is not pause, inShare is breathing in; the pause is pauseRest of a breath
	-- up to pauseFrom breaths a minute and gone at pauseGone. outCurve below 1: breathing out
	-- starts quickly and ends slowly. A held breath stands at heldAt of full.
	inShare = 0.476,
	pauseRest = 0.16, pauseFrom = 14, pauseGone = 26,
	outCurve = 0.8,
	heldAt = 0.85,

	-- The airway. Air that does not get in for blockedAfter seconds although the body tries: shut.
	blockedAfter = 0.5,

	-- What the breathing is called (sv_state.lua).
	obstructedBelow = 0.3,     -- how open the airway is
	labouredBelow = 0.75,      -- what the two lungs can do together
	fastAt = 22,               -- breaths a minute
	shallowAt = 0.6,           -- depth

	-- The picture (sh_link.lua, cl_net.lua). None of these changes what is true of the breathing.
	quietDia = 0.38,           -- how much of the diaphragm's travel a breath of depth 1 uses
	leftShare = 0.94,          -- the left half's travel against the right's (the heart lies on it)
	lagLeft = 0.012,           -- of a breath: how far the left lung is behind the right
	struggle = 0.25,           -- how much of its travel the diaphragm still makes against a shut airway
	ease = 0.45,               -- s in which what is shown comes to what a new clock says
}

C.Net = {
	every = 0.25,              -- s between two looks at what has to be sent
	keep = 2,                  -- s after which a running clock is sent again unchanged
	rateStep = 0.5, depthStep = 0.05,          -- how far rate and depth move before they are sent
	stale = 6,                 -- s after which a client no longer believes a clock it has not heard of
	recEvery = 0.5,            -- s between two looks at the records clients watch (developer view)
	rate = 4, burst = 8,       -- what one client may ask a second, and at once
	askAgain = 2,              -- s after which a client asks for a watched body again
}

C.View = {
	dist = 900,                -- units beyond which nothing is drawn
	shown = 6,                 -- bodies drawn at once
	ambient = 0.32, key = 0.80, fill = 0.30,
}
