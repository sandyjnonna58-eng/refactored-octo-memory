-- Every switch and constant of the skeleton module.
-- Units: game units; one is 1.9 cm (as in the other modules).

HemoSkeleton.Config = HemoSkeleton.Config or {}
local SK = HemoSkeleton
local C = SK.Config

local SV = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
C.sv = {
	enabled = CreateConVar("skel_enabled", "1", SV, "Skeleton module master switch (records and queries; the view has its own)", 0, 1),
	zcity   = CreateConVar("skel_zcity", "1", SV, "Bone damage Z-City books is resolved to bones of the registry (records only: nothing of Z-City's is changed)", 0, 1),
	-- (not archived: a developer mode does not come back by itself after a restart)
	dev     = CreateConVar("skel_dev", "0", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "Skeleton developer commands and the inspection view (superadmin)", 0, 1),
}

function SK.Enabled() return C.sv.enabled:GetBool() end

-- Who may use the developer commands and the view: a superadmin (or the listen server's host, or
-- the console) while skel_dev is 1. The same rule as the brain module's.
function SK.DevAllowed(ply)
	if not C.sv.dev:GetBool() then return false end
	if SERVER and not IsValid(ply) then return true end
	if not IsValid(ply) then return false end
	return ply:IsSuperAdmin() or ply:IsListenServerHost() or game.SinglePlayer()
end

------------------------------------------------------------------------------------------
-- What can be wrong with a bone. A record says what is known, not what follows from it: nothing
-- in this module slows a character, weakens it or changes its health.
------------------------------------------------------------------------------------------
C.State = { INTACT = 0, BRUISED = 1, FISSURE = 2, FRACTURE = 3, COMMINUTED = 4, LOST = 5 }
C.StateName = { [0] = "intact", "bruised", "fissure", "fracture", "comminuted", "lost" }
C.Flag = { OPEN = 1, DISPLACED = 2, APPROX = 4, GROUP = 8 }     -- APPROX: the bone is the nearest to the path, not one it was found to cross; GROUP: only the region is known
C.JointState = { SOUND = 0, DISLOCATED = 1 }

-- Z-City's own numbers for a region (0 intact .. 1 broken) as a state. A record that comes from
-- Z-City never says more than this of its region. Ours to set.
C.ZCity = {
	bruiseAt = 0.05,
	fissureAt = 0.5,
	fractureAt = 1,
	watch = 0.5,             -- s between two looks at a character's numbers
	pendingFor = 0.25,       -- s a located hit waits for Z-City's number to move
}

C.Records = {
	perChar = 64,            -- bones with a record, for one character
	age = 3600,              -- s after which a record of a body that still lies there is dropped
}

C.Net = {
	rate = 4, burst = 8,     -- what one client may ask a second, and at once
	again = 0.5,             -- s before the same body is sent to the same client again unasked-for change aside
}

C.View = {
	dist = 900,              -- units beyond which no skeleton is drawn
	shown = 6,               -- skeletons drawn at once
	labelDist = 260,         -- units within which a bone under the crosshair is named
	buildMs = 2.5,           -- ms a frame for taking the model apart
	ambient = 0.30, key = 0.85, fill = 0.30,
}

-- The fitting view of a head (cl_headview.lua): how far from the head its camera stands, and how wide it looks.
C.HeadView = { dist = 38, fov = 34 }

-- The skull's outside is asked about in steps of this length along a path (units).
C.ShellStep = 0.2
