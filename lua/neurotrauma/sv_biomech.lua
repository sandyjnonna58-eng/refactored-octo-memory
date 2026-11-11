-- From the kinematics of an injury event to the quantities the neurological model works with.
-- Two separate inputs describe a head impact: how hard the skull was struck (contact) and how fast
-- the head was turned (rotation). Rotation is what strains the brain; contact is what breaks the
-- skull and bruises what lies under it [S: B3 B5]. Everything here is in m/s and rad/s.

local NT = NeuroTrauma
NT.Biomech = NT.Biomech or {}
local B = NT.Biomech
local C, E = NT.Config, NT.E
local abs, sqrt, max, min, exp = math.abs, math.sqrt, math.max, math.min, math.exp
local Clamp, Sig = math.Clamp, NT.Sigmoid

-- A change of angular velocity (world vector) split into the head's three planes of motion:
-- sagittal (nodding: about the left-right axis), coronal (ear to shoulder: about the front-back
-- axis), axial (turning: about the vertical axis).
function B.SplitRotation(dw, up, face, left)
	return abs(dw:Dot(left)), abs(dw:Dot(face)), abs(dw:Dot(up))
end

-- One number for a rotation: sideways motion weighs most, nodding least [R: B1 B8 B6].
function B.RotMetric(sag, cor, ax)
	local b = C.Biomech
	local c, a, s = cor * b.axisCoronal, ax * b.axisAxial, sag * b.axisSagittal
	return sqrt(c * c + a * a + s * s)
end

-- Where on the head a point lies, from the unit direction centre -> point.
-- Also returns how far to the character's left (+) or right (-) it is, -1..1.
function B.Region(dir, up, face, left)
	local u, f, l = dir:Dot(up), dir:Dot(face), dir:Dot(left)
	local R = E.Region
	local region
	if u > 0.72 then region = R.TOP
	elseif u < -0.62 then region = R.BASE
	elseif abs(f) >= abs(l) then
		if f > 0 then region = (u < -0.1) and R.FACE or R.FRONT else region = R.BACK end
	else
		region = l > 0 and R.LEFT or R.RIGHT
	end
	return region, l
end

-- Fills the derived quantities of an event from its raw kinematics:
--   rot      weighted rotation, rad/s (what the diffuse injury and loss of consciousness follow)
--   contact  speed lost against the surface, scaled by how hard the surface is and by the helmet, m/s
-- and, for a fall, what is left of both after the arms and the neck of an awake character have
-- taken their share (rotEff, contactEff).
function B.Evaluate(ev)
	local b = C.Biomech
	local M = E.Mech
	ev.rot = B.RotMetric(ev.sag or 0, ev.cor or 0, ev.ax or 0)
	-- A head that whips without striking anything turns as far as one that strikes, but far more
	-- slowly; the criteria in the literature count the acceleration as well as the speed [R: B2 B4].
	if ev.mech == M.WHIPLASH then ev.rot = ev.rot * math.Clamp((ev.alpha or 0) / b.whipAlphaFull, 0.25, 1) end
	ev.contact = (ev.dvn or 0) * (ev.stiff or 1) * (1 - (ev.shield or 0))
	if ev.mech == M.BLUNT then
		ev.contact = ev.contact * b.bluntContact
		-- (a blow to a standing character is an estimate that grows in a straight line with Z-City's
		-- damage number. Beyond the hardest impacts that were measured on ragdolls it is not
		-- trusted: a swing does not turn a head faster than a head-first fall from a roof)
		if not ev.measured and ev.rot > b.bluntRotMax then ev.rot = b.bluntRotMax end
	end
	-- (only a fall can be broken by the one who falls: a blow, a bullet or a blast cannot)
	local awake = 0
	if ev.mech == M.RAGDOLL_IMPACT or ev.mech == M.WHIPLASH or ev.mech == M.FALL then awake = ev.awake or 0 end
	ev.protect = awake
	ev.rotEff = max(ev.rot - b.protectRot * awake, 0)
	ev.contactEff = max(ev.contact - b.protectContact * awake, 0)
	return ev
end

local function Ramp(x, from, full, pow)
	if x <= from then return 0 end
	local v = (x - from) / (full - from)
	return pow and v ^ pow or v
end

-- What an event does to a brain: the loads it adds and the transient effects it starts. Every
-- chance is drawn from the event's own seed. `tol` is the character's tolerance (around 1), `vuln`
-- how much an earlier injury still counts (1 = not at all). Returns a table:
--   diffuse, focalL, focalR, stem, fracture   added to the injury variables
--   loc (s), stun (s), apnoea (s), fencing (s), convulsion (s)   transient effects, nil when none
--   mass = { rate (per compressed second), final, side (+1 left, -1 right), kind }   a growing lesion
--   why   a short text for the log
function B.Loads(ev, tol, vuln)
	local L, M = C.Load, E.Mech
	local rng = NT.RNG(ev.seed)
	local out = { diffuse = 0, focalL = 0, focalR = 0, stem = 0, fracture = 0 }
	local scale = (vuln or 1) / (tol or 1)
	local x, k = (ev.rotEff or 0) * scale, (ev.contactEff or 0) * scale
	local why = {}
	local side = (ev.lat or 0)

	local function Focal(amount, lat)
		if amount <= 0 then return end
		-- under the impact and, less, opposite it; a blow on the midline is shared
		local l = 0.5
		if lat > 0.25 then l = L.focalCoup elseif lat < -0.25 then l = 1 - L.focalCoup end
		out.focalL = out.focalL + amount * l
		out.focalR = out.focalR + amount * (1 - l)
	end
	local function Mass(p, minutes, kind, lat, sev)
		if rng:Next() >= p then return end
		local mins = rng:Range(minutes[1], minutes[2])
		local s = lat
		if abs(s) < 0.25 then s = rng:Next() < 0.5 and 1 or -1 end
		out.mass = { rate = 1 / (mins * 60), final = rng:Range(L.massFinal[1], L.massFinal[2] + L.massFinalSevere * Clamp(sev or 1, 0, 1)), side = s > 0 and 1 or -1, kind = kind }
		why[#why + 1] = string.format("%s lesion begins (%s side, critical in %.0f min if it gets that far, ends at %.2f)", kind, s > 0 and "left" or "right", mins, out.mass.final)
	end

	if ev.mech == M.PROJECTILE then
		local e = Clamp((ev.energy or 0) / L.energyRef, L.energyMin, L.energyMax)
		local P, Zn = E.Pen, E.Zone
		if ev.pen == P.GRAZE then
			if rng:Next() < L.grazeStunP then out.stun = L.stunBase end
			why[#why + 1] = "graze"
		elseif ev.pen == P.TANGENTIAL then
			-- the skull is struck, the vault is not entered: a contact injury under the track
			k = (L.tangentialContact + (ev.energy or 0) * L.tangentialPerJ) * (1 - (ev.shield or 0)) * scale
			why[#why + 1] = string.format("tangential: contact %.1f", k)
		else
			-- A bullet inside the skull. What it does goes with where it went [S: G1 G2 G3 G4]: a
			-- track through one hemisphere or through both frontal lobes is the survivable kind;
			-- one that crosses both hemispheres further back, the deep middle and the ventricles,
			-- or the posterior fossa is the kind that kills. The structures on the track are
			-- destroyed in the anatomy (sv_anatomy.lua), and what the character can no longer do
			-- follows from that. Here: what the wound does to the brain as a whole.
			local sv = NT.Anatomy and NT.Anatomy.SurveyEvent(ev) or nil
			local z = ev.zones or 0
			local l, r = bit.band(z, Zn.LEFT) ~= 0, bit.band(z, Zn.RIGHT) ~= 0
			local central, both, fossa = 0, l and r, 0
			if sv then
				l, r = sv.hemiL > 0.1, sv.hemiR > 0.1
				central, both, fossa = sv.central, sv.both, sv.fossa
			elseif bit.band(z, Zn.DEEP) ~= 0 then
				central = 0.7
			end
			if l then out.focalL = out.focalL + L.shotFocal * e end
			if r then out.focalR = out.focalR + L.shotFocal * e end
			-- The temporary cavity cannot give way inside a closed skull: a peak of pressure that
			-- injures the whole brain, slight for a slow light bullet and of the explosive kind for
			-- a rifle's [S: G5]. More when the track is central or crosses both halves.
			local cav = L.shotCavity * e ^ L.shotCavityPow
			out.diffuse = out.diffuse + cav * (1 + L.shotCentral * central + (both and L.shotBoth or 0))
			-- the brainstem: the wave reaches it at high energy; a track through the deep middle
			-- lies just above it [S: G1]; a track through the brainstem itself is in the anatomy
			out.stem = out.stem + L.shotWaveStem * max(e - L.shotWaveFrom, 0) + L.shotCentralStem * central * e
			out.fracture = 1
			-- Unconscious at once: nearly always with the tracks that kill, often but not always
			-- with the others (people have gone on acting after a slow bullet through one frontal
			-- lobe; never after one through the middle, the brainstem or the motor pathways [S: G6])
			local grave = both or central > 0.3 or fossa > 0.3
			if grave or rng:Next() < L.shotLocP then
				out.loc = L.locBase * (grave and 4 or 1) * (1 + 2 * e) * exp(rng:Normal() * 0.5)
			else
				out.stun = L.stunBase * 2
			end
			-- bleeding along the track: certain and fast for the grave tracks
			local side = l and not r and 1 or (r and not l and -1 or 0)
			if central > 0.3 then Mass(1, L.shotMinutesCentral, "bleeding along the track, into the ventricles", side, 1)
			elseif both or fossa > 0.3 then Mass(1, L.shotMinutesBoth, "bleeding along the track", side, 1)
			else Mass(L.shotMassP, L.epiMinutes, "bleeding along the track", side, 0.5) end
			local kind = central > 0.3 and "through the deep middle" or (fossa > 0.3 and "through the posterior fossa" or (both and "through both hemispheres" or ((l and r) and "through both frontal lobes" or "through one hemisphere")))
			ev.trajectory = kind
			why[#why + 1] = string.format("track %s, energy x%.1f", kind, e)
		end
	elseif ev.mech == M.BLAST then
		x = (ev.damage or 0) * L.blastRotPerDamage * scale
		why[#why + 1] = string.format("blast: equivalent rotation %.1f", x)
	elseif ev.mech == M.FALL then
		x = max(x, Ramp(ev.landing or 0, L.landRotFrom, L.landRotFrom + 1) * L.landRotPer * scale)
	end

	-- rotation: knockout or daze, diffuse injury, brainstem at the extreme
	if x > 0 then
		local pLoc = Sig(x, L.locMid, L.locK)
		-- (a blow whose knockout and daze are somebody else's to decide: sv_injury.lua, "A blow
		-- of the free-hand module". Not drawn at all, so that the log does not tell of one.)
		if ev.owned then
		elseif not out.loc and rng:Next() < pLoc then
			out.loc = min(L.locBase * exp((x - L.locMid) / L.locDurK) * exp(rng:Normal() * 0.5), L.locMax)
			out.loc = max(out.loc, 2)
			why[#why + 1] = string.format("knockout %.0f s (rotation %.1f, chance %.0f%%)", out.loc, x, pLoc * 100)
		elseif not out.loc and rng:Next() < Sig(x, L.stunMid, L.stunK) then
			out.stun = L.stunBase * (0.6 + x / L.stunMid * 0.6)
			why[#why + 1] = string.format("dazed %.0f s (rotation %.1f)", out.stun, x)
		end
		local d = Ramp(x, L.diffuseFrom, L.diffuseFull, L.diffusePow)
		if d > 0 then out.diffuse = out.diffuse + d end
		local s = Ramp(x, L.stemFrom, L.stemFull)
		if s > 0 then out.stem = out.stem + s end
	end
	-- the whole body stopped at speed
	local land = Ramp(ev.landing or 0, L.landingFrom, L.landingFull, 1.2)
	if land > 0 and ev.mech ~= M.PROJECTILE then
		land = min(land, L.landingMax) * scale
		-- (a landing an awake character takes on the legs is worth half)
		out.diffuse = out.diffuse + land * (1 - 0.5 * (ev.protect or 0))
	end
	-- contact: fracture, bruising under it
	if k > 0 then
		local pf = Sig(k, L.fracMid, L.fracK)
		if rng:Next() < pf then
			out.fracture = max(out.fracture, Clamp((k - 5) / 8, 0.2, 1))
			why[#why + 1] = string.format("skull fracture (contact %.1f, chance %.0f%%)", k, pf * 100)
		end
		Focal(Ramp(k, L.focalFrom, L.focalFull, L.focalPow) + (out.fracture > 0 and L.focalFracture or 0), side)
	end
	-- what a knockout brings with it
	if out.loc then
		local ap = max(x - L.apnoeaRot, 0) * L.apnoeaPerRot + max(k - L.apnoeaContact, 0) * L.apnoeaPerContact
		if out.stem > 0.3 then ap = ap + 15 * out.stem end
		if ap > 1 then out.apnoea = min(ap, L.apnoeaMax) end
		if ev.mech ~= M.PROJECTILE then
			if rng:Next() < min(L.fencingP * Sig(x, L.fencingMid, L.fencingK) * 2, 0.9) then
				out.fencing = rng:Range(L.fencingMin, L.fencingMax)
			end
			if rng:Next() < L.convulsionP then out.convulsion = rng:Range(L.convulsionMin, L.convulsionMax) end
		end
	end
	-- The rule of the game for the first bullet in a brain (neuro_headshot_rules, counted in
	-- sv_injury.lua): whatever the track, the character is down and unconscious for a while, holds
	-- the posture of the first moments, and does not breathe for some seconds. What follows that is
	-- the track's. (A rifle round has its own course: sv_trauma.lua.)
	if ev.headWound and not ev.terminal then
		local H = C.Headshot
		out.loc = max(out.loc or 0, H.minLoc)
		out.stun = nil
		out.fencing = rng:Range(H.posture[1], H.posture[2])
		out.apnoea = max(out.apnoea or 0, rng:Range(H.apnoea[1], H.apnoea[2]))
		why[#why + 1] = string.format("rule: down for at least %.0f s, a posture for %.0f s, no breath for %.0f s", out.loc, out.fencing, out.apnoea)
	end
	-- a lesion that grows afterwards
	if not out.mass and ev.mech ~= M.PROJECTILE then
		if out.fracture > 0 then Mass(L.epiP * (0.5 + out.fracture), L.epiMinutes, "epidural-like", side, out.fracture) end
		if not out.mass then Mass(L.subP * Sig(x, L.subMid, L.subK), L.subMinutes, "subdural-like", rng:Next() < 0.5 and 1 or -1, Sig(x, L.subMid, L.subK) * 1.6) end
	end
	out.diffuse = min(out.diffuse, 1.5)
	out.stem = min(out.stem, 1.5)
	out.x, out.k = x, k
	out.why = table.concat(why, "; ")
	return out
end
