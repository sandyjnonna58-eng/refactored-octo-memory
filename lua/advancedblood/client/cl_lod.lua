-- Importance ranking, LOD tiers, hard budgets and the performance governor.
-- Every source (bleeding character) gets an LOD tier from its distance to the camera, whether it
-- is on screen and its severity. When measured simulation time exceeds abl_budget_ms the governor
-- shrinks all tier distances, so far/low-priority effects lose detail first.

ABL.NoJIT()
ABL.LOD = ABL.LOD or {}
local L = ABL.LOD
local C = ABL.Config
local CV = C.cl

L.scale = L.scale or 1
L.eyeX, L.eyeY, L.eyeZ = 0, 0, 0
L.fwdX, L.fwdY, L.fwdZ = 1, 0, 0
L.fovCos = 0.5
L.simMs = 0
L.traces = 0
L.traceBudget = 150

-- The view actually rendered last frame (Z-City renders its own camera through RenderScene /
-- CalcView, so EyePos() in Think is not reliable). Captured inside the render hook.
local viewT, viewOrigin, viewAngles, viewFov = -1, nil, nil, 90
-- Returns false for secondary views (water reflections, render-target cameras).
function L.CaptureView()
	-- (the view a pool's mirror draws of the scene: cl_poolmirror.lua)
	if ABL.PoolMirror and ABL.PoolMirror.rendering then return false end
	local vs = render.GetViewSetup()
	if not vs or not vs.origin or not vs.angles then return false end
	if vs.width and vs.height and (vs.width ~= ScrW() or vs.height ~= ScrH()) then return false end
	-- (The water's own two views of the world, mirrored in it and seen through it, are as large as
	-- the screen where water is drawn at its best, and the size alone does not tell them from the
	-- player's view: on a map with water in sight all blood was drawn three times a frame.)
	local rt = render.GetRenderTarget()
	if rt then
		if string.find(string.lower(rt:GetName()), "_rt_water", 1, true) then return false end
	end
	viewOrigin, viewAngles, viewFov = vs.origin, vs.angles, vs.fov or 90
	viewT = RealTime()
	return true
end

function L.UpdateView()
	L.ApplyView()
	L.traces = 0
	L.traceBudget = CV.maxTraces:GetInt()
end

function L.ApplyView()
	local pos, ang, fov
	if viewOrigin and RealTime() - viewT < 0.5 then
		pos, ang, fov = viewOrigin, viewAngles, viewFov
	else
		pos, ang = EyePos(), EyeAngles()
		local lp = LocalPlayer()
		fov = IsValid(lp) and lp:GetFOV() or 90
	end
	L.eyeX, L.eyeY, L.eyeZ = pos.x, pos.y, pos.z
	local f = ang:Forward()
	L.fwdX, L.fwdY, L.fwdZ = f.x, f.y, f.z
	-- view setup fov is horizontal; widen a little so things at the screen edge still count
	L.fovCos = math.cos(math.rad(math.min(fov * 0.5 + 8, 89)))
	-- pixels a unit covers at distance 1 (apparent size = size * pxK / distance)
	L.pxK = ScrW() * 0.5 / math.tan(math.rad(math.min(fov * 0.5, 89)))
end

function L.QualityScale()
	return C.QualityScale[CV.quality:GetInt()] or 1
end

-- Budget caps, scaled by the quality preset.
function L.Cap(cv)
	return math.max(1, math.floor(cv:GetInt() * math.Clamp(L.QualityScale(), 0.4, 1.5)))
end

function L.TakeTrace()
	if L.traces >= L.traceBudget then return false end
	L.traces = L.traces + 1
	return true
end

-- Distance squared from the camera and whether a point is roughly on screen.
function L.View(x, y, z, radius)
	local dx, dy, dz = x - L.eyeX, y - L.eyeY, z - L.eyeZ
	local d2 = dx * dx + dy * dy + dz * dz
	local d = math.sqrt(d2)
	if d < (radius or 0) + 8 then return d2, true end
	local dot = (dx * L.fwdX + dy * L.fwdY + dz * L.fwdZ) / d
	-- widen the cone by the object's angular radius
	local ang = (radius or 0) / d
	return d2, dot > (L.fovCos - ang)
end

L.cvRoute = CreateClientConVar("abl_flow_by_distance", "1", true, false, "Where a wound's blood goes (onto the body's film, straight off the wound, or a deposit under the body) by the body's distance alone (1), or, as before, by a distance the governor shortens while the addon is over its budget and by whether the body is in view (0).", 0, 1)

-- Does blood go onto this body's film (it is near enough by its distance alone, and there is a
-- body to step)? A dormant body (not sent to this client) has no bones and is never stepped.
function L.FlowOn(src)
	local fl = src.flowLod or src.lod
	local tier = fl and C.LODTiers[fl]
	return tier ~= nil and tier.bodyflow and src.lod ~= C.LOD_OFF
end

function L.Evaluate(src)
	local ent = src.body
	if not IsValid(ent) then src.lod = C.LOD_OFF src.flowLod = C.LOD_OFF src.visible = false return end
	local c = ent:WorldSpaceCenter()
	local d2, onScreen = L.View(c.x, c.y, c.z, 48)
	local d = math.sqrt(d2)
	src.dist = d
	local dormant = ent:IsDormant()
	local isLocal = src.owner == LocalPlayer()
	-- (a body the game itself drew in the player's view a moment ago is in sight, whatever the
	-- cone says: cl_bodyflow.lua, the hook that draws its blood)
	local seen = src.seenFrame ~= nil and src.seenFrame >= FrameNumber() - 3
	src.visible = (not dormant) and (onScreen or isLocal or seen)

	if dormant or d > CV.drawDist:GetFloat() then src.lod = C.LOD_OFF src.flowLod = C.LOD_OFF src.importance = 0 return end

	local qs = L.QualityScale() * L.scale
	local lod = C.LOD_OFF
	for tier = C.LOD_ULTRA, C.LOD_VERYFAR, -1 do
		if d <= C.LODTiers[tier].dist * qs then lod = tier break end
	end
	if lod == C.LOD_OFF and d <= CV.drawDist:GetFloat() then lod = C.LOD_VERYFAR end
	if not src.visible and lod > C.LOD_MEDIUM then lod = C.LOD_MEDIUM end
	src.lod = lod
	-- Where the body's blood goes (onto its film, straight off the wound, or a deposit under it), by
	-- its distance alone (L.FlowOn). By the tier above, the governor's scale decided it: with the
	-- addon over its budget (the scale at its floor in nearly every recorded scene) a body 240 units
	-- away had its wounds drip straight off and its film stood still, and one 430 units away had
	-- what it bled laid as a pool under its middle once a second; and a body one looked away from
	-- dropped about three quarters of its blood straight off the wound (scene cont_away). What a
	-- frame costs, or which way the camera looks, should change how much detail is drawn, not where
	-- the blood is. (abl_flow_by_distance 0: as it was.)
	if L.cvRoute:GetBool() then
		local qr = L.QualityScale()
		local fl = C.LOD_OFF
		for tier = C.LOD_ULTRA, C.LOD_VERYFAR, -1 do
			if d <= C.LODTiers[tier].dist * qr then fl = tier break end
		end
		if fl == C.LOD_OFF then fl = C.LOD_VERYFAR end
		src.flowLod = fl
	else
		src.flowLod = lod
	end

	local sev = math.min((src.flowRate or 0) / 4, 2) + 0.25
	src.importance = (lod / 5) * sev * (src.visible and 1 or 0.35) * (isLocal and 1.4 or 1)
end

-- Importance of an arbitrary world point (used for droplets / pools without a live source).
function L.PointImportance(x, y, z)
	local d2, vis = L.View(x, y, z, 4)
	local d = math.sqrt(d2)
	return (vis and 1 or 0.3) / (1 + d / 350), d
end

------------------------------------------------------------------------------------------
-- Simulation clock (cl_sim.lua runs it).
-- Blood is simulated on one fixed tick whose rate targets abl_sim_hz (165 by default). Objects
-- are stepped at the rate their priority allows (C.LODTiers[].hz): every object keeps its own
-- time accumulator and steps once that reaches its period, with that accumulated time as its
-- step. ULTRA blood runs at the full tick rate; lower tiers skip ticks. Renderers interpolate an
-- object between its last two states: Alpha(lastStepTime, stepLength).
------------------------------------------------------------------------------------------
ABL.Sim = ABL.Sim or {}
local Sim = ABL.Sim
Sim.rate = Sim.rate or 165       -- current tick rate (Hz), adapted by the governor
Sim.t = Sim.t or 0               -- simulated time at the end of the last tick
Sim.acc = Sim.acc or 0           -- simulated time owed (not yet ticked)
Sim.tick = Sim.tick or 0
Sim.steps = Sim.steps or 0       -- ticks run in the last frame (EMA)

function Sim.Target()
	return math.Clamp(CV.simHz:GetFloat(), 30, 240)
end

-- Step period (s) for an object that wants `hz`: never faster than the tick itself.
function Sim.Period(hz)
	if not hz or hz <= 0 then return math.huge end
	return 1 / math.min(hz, Sim.rate)
end

-- Where the renderer is in simulated time (between the last tick and the next).
function Sim.RenderT() return Sim.t + Sim.acc end

-- Interpolation factor for an object last stepped at simulated time `lt` with a step of `sd`.
function Sim.Alpha(lt, sd)
	if not lt or not sd or sd <= 0 then return 1 end
	local a = (Sim.t + Sim.acc - lt) / sd
	if a < 0 then return 0 elseif a > 1 then return 1 end
	return a
end

-- LOD tier (C.LODTiers entry) an effect at distance d falls in, when it has no source.
function Sim.TierAt(d)
	local qs = L.QualityScale() * L.scale
	for tier = C.LOD_ULTRA, C.LOD_VERYFAR, -1 do
		local t = C.LODTiers[tier]
		if d <= t.dist * qs then return t end
	end
	return C.LODTiers[C.LOD_VERYFAR]
end

-- Update rate of a droplet / effect at distance d (no source).
function Sim.HzAt(d) return Sim.TierAt(d).hz end

------------------------------------------------------------------------------------------
-- Governor
--   * tick rate: follows the cost of the simulation itself (which is what the rate changes). When
--     the simulation takes more than 60 % of abl_budget_ms the rate gives way, down to 50 Hz;
--     near blood stays detailed and only moves in larger steps. It climbs back to abl_sim_hz when
--     there is room again.
--   * detail: the whole cost (simulation, drawing, body blood, pool painting) against the budget
--     shrinks or restores the LOD distances, so far blood loses detail first.
------------------------------------------------------------------------------------------
local nextAdjust = 0
local RATE_MIN = 50
L.tickMs = L.tickMs or 0
function L.Governor(totalMs, simMs)
	L.simMs = L.simMs * 0.9 + totalMs * 0.1
	L.tickMs = L.tickMs * 0.9 + (simMs or totalMs) * 0.1
	local now = RealTime()
	local target = Sim.Target()
	if Sim.rate > target then Sim.rate = target end
	if now < nextAdjust then return end
	nextAdjust = now + 0.5
	local budget = CV.budget:GetFloat()
	if L.tickMs > budget * 0.6 then
		Sim.rate = math.max(math.min(RATE_MIN, target), Sim.rate * 0.88)
	elseif L.tickMs < budget * 0.35 then
		Sim.rate = math.min(target, Sim.rate * 1.08)
	end
	if L.simMs > budget then
		L.scale = math.max(0.25, L.scale * 0.85)
	elseif L.simMs < budget * 0.55 then
		L.scale = math.min(1, L.scale * 1.06)
	end
end
