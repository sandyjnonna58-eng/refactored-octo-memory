-- Seizures: a subsystem of its own, not one animation.
--
--   impact convulsion   within a second or two of a knockout: brief stiffening, then a short run
--                       of jerks; a benign impact phenomenon, not epilepsy [R: C5]
--   early seizure       minutes to days after the injury (here on the compressed clock). It can
--                       begin in one place (focal) or everywhere at once [S: Z4 N89]:
--                         focal, aware            one arm or one side jerks, the person stays awake
--                         focal, awareness lost   the person stands or sits and stares, does not
--                                                 answer, fumbles with a hand
--                         spreading to both sides, or generalised from the start: a tonic phase,
--                         a clonic phase, either of which can be missing [S: Z5]
--                       then the postictal state [S: Z7 Z12]
--   prolonged, status   most seizures stop by themselves within a minute or two. One that has not
--                       stopped after five minutes is unlikely to, and is treated as status
--                       epilepticus; after thirty minutes lasting harm is to be expected
--                       [S: Z8, time points t1 and t2 for convulsive status]. Here a seizure is
--                       planned with or without an end of its own; without one it runs on, weaker
--                       and weaker, until it is stopped by a drug (sv_treatment.lua) or the brain
--                       is exhausted.
--
-- Each seizure is planned when it starts, from its own seed: which phases, how long, which side,
-- whether it will stop. The plan runs in real time. The movement is made by sv_motor.lua
-- (ragdoll) and cl_pose.lua (standing); this file only says which phase it is.

local NT = NeuroTrauma
NT.Seizure = NT.Seizure or {}
local SZ = NT.Seizure
local C, Z, E, A = NT.Config, NT.ZC, NT.E, NT.Atlas
local CS = C.Seizure

SZ.Phase = { none = 0, focal = 1, tonic = 2, clonic = 3, postictal = 4, jerks = 5, impaired = 6, subtle = 7 }
local PHASE = SZ.Phase
-- phases in which the whole body convulses
local CONVULSIVE = { tonic = true, clonic = true, subtle = true }

-- Categories, for the log, the panel and the API [S: Z4 Z8]
SZ.Category = {
	"FOCAL_MOTOR", "FOCAL_IMPAIRED_AWARENESS", "GENERALIZED_TONIC", "GENERALIZED_CLONIC", "TONIC_CLONIC",
	"PROLONGED_SEIZURE", "STATUS_EPILEPTICUS", "POSTICTAL", "IMPACT_CONVULSION",
}

local function Range(rng, r) return rng:Range(r[1], r[2]) end

-- What kind of seizure this is right now.
function SZ.CategoryOf(st, now)
	local sz = st.sz
	if not sz then return st.postictalUntil and "POSTICTAL" or nil end
	if sz.phase == "postictal" then return "POSTICTAL" end
	if sz.kind == "convulsion" then return "IMPACT_CONVULSION" end
	if sz.kind == "jerks" then return nil end
	if sz.convSince then
		local t = now - sz.convSince
		if t >= CS.statusAfter then return "STATUS_EPILEPTICUS" end
		if t >= CS.prolongedAfter then return "PROLONGED_SEIZURE" end
	end
	if sz.phase == "focal" then return "FOCAL_MOTOR" end
	if sz.phase == "impaired" then return "FOCAL_IMPAIRED_AWARENESS" end
	if sz.hasTonic and sz.hasClonic then return "TONIC_CLONIC" end
	if sz.phase == "tonic" then return "GENERALIZED_TONIC" end
	return "GENERALIZED_CLONIC"
end

-- The minutes after a seizure that began on one side: the half of the brain it began in works
-- badly for a while. Weakness of the opposite side is the classic form; language and other
-- functions of that hemisphere can be down as well [S: N88 Z7 Z12].
local TODD = { "precentral_face", "precentral_hand", "precentral_arm", "precentral_trunk", "paracentral", "sma", "caudalmiddlefrontal",
	"parsopercularis", "parstriangularis", "superiortemporal_post", "supramarginal" }
local function Todd(st, level)
	local q = math.floor(level * 10 + 0.5) / 10
	if q == (st.toddQ or 0) then return end
	st.toddQ = q
	if q <= 0 or not st.postictalSide then
		NT.Anatomy.Suppress(st, "todd", nil, nil)
		return
	end
	-- (postictalSide +1: the left side of the body is weak, so the right hemisphere is the tired one)
	local hemi = st.postictalSide > 0 and "R" or "L"
	local map = {}
	for i, key in ipairs(TODD) do
		local id = A.regionOf[hemi .. "_" .. key]
		-- motor areas in full, the language areas half as much
		if id then map[id] = math.min(q * (i <= 7 and 1 or 0.5), 0.95) end
	end
	NT.Anatomy.Suppress(st, "todd", map, nil)
end

local function Finish(ply, st, sz, now)
	st.sz = nil
	st.seizing = false
	st.ictal = 0
	st.seizurePhase, st.seizureSide = 0, 0
	st.lastSeizureEnd = now
	if sz.kind ~= "jerks" then NT.States.Push(st, ply, "seizure over") end
	hook.Run("NT_SeizureEnd", ply, st, sz)
end

local function Enter(ply, st, sz, now)
	local step = sz.plan[sz.index]
	if not step then return Finish(ply, st, sz, now) end
	sz.phase, sz.t0, sz.tEnd, sz.beat = step.phase, now, now + step.dur, 0
	st.seizurePhase = PHASE[step.phase] or 0
	st.seizureSide = (sz.side > 0) and 1 or 2
	if CONVULSIVE[step.phase] and not sz.convSince then sz.convSince = now end
	if step.phase == "tonic" then sz.hasTonic = true elseif step.phase == "clonic" then sz.hasClonic = true end
	-- (the jerks of a brain without blood flow are not a seizure)
	st.seizing = step.phase ~= "postictal" and sz.kind ~= "jerks"
	if sz.kind ~= "jerks" then
		NT.States.Push(st, ply, string.format("seizure: %s phase, %.0f s%s", step.phase, step.dur,
			(step.phase == "focal" or step.phase == "impaired") and (sz.side > 0 and ", left side" or ", right side") or ""))
	end
	if step.phase == "postictal" then
		if sz.todd then
			st.postictalSide, st.postictalFull, st.postictalFrom, st.postictalUntil = sz.side, CS.toddDeficit, now, now + step.dur * 2
		elseif not st.postictalUntil then
			-- (no one-sided weakness: the state still has a length, for the label)
			st.postictalSide, st.postictalFull, st.postictalFrom, st.postictalUntil = nil, 0, now, now + step.dur
		end
	end
	-- a character on its feet goes down when the seizure takes the whole body
	if (CONVULSIVE[step.phase] or step.phase == "jerks") and IsValid(ply) and ply:IsPlayer() and not IsValid(ply.FakeRagdoll) and Z.has.fake then
		-- (stiff as a felled tree if it begins with the tonic phase: sv_collapse.lua)
		local K = NT.Collapse
		if not (K and K.TakeDown(ply, st, step.phase == "tonic" and "rigid" or "limp")) then hg.Fake(ply) end
	end
end

-- Does this seizure stop by itself? Most do. The share that does not grows with the injury [G].
local function WillStop(st, rng)
	local p = CS.statusP * (0.5 + 1.5 * (st.seizureRisk or 0))
	return rng:Next() >= p
end

-- A seizure begins. kind: "early" (planned from the injury) or "convulsion" (at an impact).
function SZ.Start(ply, st, now, kind, seed, dur, opts)
	if st.sz then return false end
	opts = opts or {}
	local rng = NT.RNG(seed or math.random(1, 2147483646))
	local plan = {}
	-- the side opposite the more injured half of the brain, more often than not
	local an = st.an
	local hurtL = math.max(st.focalL, an and an.lesionL * 3 or 0)
	local hurtR = math.max(st.focalR, an and an.lesionR * 3 or 0)
	local side = (hurtL > hurtR) and -1 or 1
	if hurtL == hurtR or rng:Next() < 0.2 then side = rng:Next() < 0.5 and 1 or -1 end
	local sz = { plan = plan, index = 1, side = opts.side or side, strength = 1, kind = kind, stops = true }
	if kind == "convulsion" then
		plan[#plan + 1] = { phase = "tonic", dur = Range(rng, CS.convulsionTonic) }
		plan[#plan + 1] = { phase = "jerks", dur = math.max((dur or 10) - plan[1].dur, 2) }
	elseif kind == "jerks" then
		plan[#plan + 1] = { phase = "jerks", dur = dur or 4 }
	else
		local focal = rng:Next() < CS.focalOnset
		if opts.focal ~= nil then focal = opts.focal end
		local general = true
		if focal then
			local aware = rng:Next() < CS.awareP
			if opts.aware ~= nil then aware = opts.aware end
			if aware then
				plan[#plan + 1] = { phase = "focal", dur = Range(rng, CS.focalTime) }
			else
				plan[#plan + 1] = { phase = "impaired", dur = Range(rng, CS.impairedTime) }
			end
			sz.strength = rng:Range(0.6, 1)
			general = rng:Next() < CS.spread
			if opts.spread ~= nil then general = opts.spread end
		end
		if general then
			local tonic, clonic = rng:Next() < CS.tonicP, rng:Next() < CS.clonicP
			if not tonic and not clonic then clonic = true end
			if opts.tonic ~= nil then tonic = opts.tonic end
			if opts.clonic ~= nil then clonic = opts.clonic end
			if tonic then plan[#plan + 1] = { phase = "tonic", dur = Range(rng, CS.tonicTime) } end
			if clonic then plan[#plan + 1] = { phase = "clonic", dur = Range(rng, CS.clonicTime) } end
			sz.stops = WillStop(st, rng)
			if opts.status ~= nil then sz.stops = not opts.status end
			plan[#plan + 1] = { phase = "postictal", dur = Range(rng, CS.postictalTime) }
		else
			plan[#plan + 1] = { phase = "postictal", dur = Range(rng, CS.postictalTime) * 0.3 }
		end
		sz.todd = focal and rng:Next() < CS.toddP
		if opts.todd ~= nil then sz.todd = opts.todd end
	end
	for _, s in ipairs(plan) do
		if s.phase == "tonic" then sz.hasTonic = true elseif s.phase == "clonic" then sz.hasClonic = true end
	end
	st.sz = sz
	local names = {}
	for _, s in ipairs(plan) do names[#names + 1] = s.phase end
	if kind == "jerks" then
		NT.States.Push(st, ply, string.format("a few jerks as the brain loses its blood flow, %.0f s", plan[1].dur))
	else
		NT.States.Push(st, ply, string.format("seizure begins (%s): %s%s", kind, table.concat(names, ", "), sz.stops and "" or "; it will not stop by itself"))
	end
	Enter(ply, st, sz, now)
	hook.Run("NT_SeizureStart", ply, st, sz)
	return true
end

-- Stopped from outside (a drug): whatever phase it is in, the postictal state follows, the longer
-- the longer the seizure ran.
function SZ.Terminate(ply, st, now, why)
	local sz = st.sz
	if not sz or sz.phase == "postictal" or sz.kind == "jerks" then return false end
	local ran = now - (sz.convSince or sz.t0)
	local post = math.Clamp(CS.postictalTime[1] + ran * 0.5, CS.postictalTime[1], CS.postictalTime[2] * 2)
	sz.plan = { { phase = "postictal", dur = post } }
	sz.index = 1
	sz.stops = true
	NT.States.Push(st, ply, string.format("seizure stopped after %.0f s (%s)", ran, why or "treated"))
	Enter(ply, st, sz, now)
	return true
end

-- Called with every step of an injured brain, before its function is worked out.
function SZ.Update(ply, org, st, now, sdt)
	-- an impact convulsion that the injury event scheduled
	if st.convulsionFrom and now >= st.convulsionFrom then
		local dur = st.convulsionUntil - st.convulsionFrom
		st.convulsionFrom = nil
		SZ.Start(ply, st, now, "convulsion", st.fencingSeed, dur)
	end
	-- the jerks of a brain that has just lost its blood flow (sv_cardioresp.lua)
	if st.jerksFrom and now >= st.jerksFrom then
		st.jerksFrom = nil
		SZ.Start(ply, st, now, "jerks", nil, st.jerksDur)
	end
	local sz = st.sz
	if not sz then
		-- what the seizure left behind wears off
		if st.postictalUntil then
			if now >= st.postictalUntil then
				st.postictal, st.postictalSide, st.postictalUntil = 0, nil, nil
				Todd(st, 0)
			else
				st.postictal = (st.postictalFull or 0) * (st.postictalUntil - now) / (st.postictalUntil - st.postictalFrom)
				Todd(st, st.postictal)
			end
		end
		-- does one begin? Only in a brain that is injured, never in the first seconds, not twice in
		-- a row; a drug that raises the threshold makes it less likely
		if st.seizureRisk > 0.05 and now - st.born > 5 and now - (st.lastSeizureEnd or -1e9) > CS.refractory and not st.terminal then
			local hazard = st.seizureRisk * CS.hazardPerMinute * sdt / 60 * (1 - (st.seizureGuard or 0))
			if math.random() < hazard then SZ.Start(ply, st, now, "early") end
		end
		return
	end
	if now >= sz.tEnd then
		-- A seizure with no end of its own does not go on to the postictal state: it carries on,
		-- weaker, and after some minutes with little movement left [P], until the brain is exhausted.
		local nextStep = sz.plan[sz.index + 1]
		if not sz.stops and nextStep and nextStep.phase == "postictal" and sz.convSince then
			local ran = now - sz.convSince
			if ran >= CS.statusMax then
				sz.stops = true
				nextStep.dur = CS.postictalTime[2] * 2
				NT.States.Push(st, ply, string.format("the seizure burns out after %.0f s", ran))
			else
				local subtle = ran >= CS.subtleAfter
				table.insert(sz.plan, sz.index + 1, { phase = subtle and "subtle" or "clonic", dur = math.random(CS.statusBlock[1], CS.statusBlock[2]) })
				sz.weak = math.Clamp(ran / CS.subtleAfter, 0, 1)
			end
		end
		sz.index = sz.index + 1
		Enter(ply, st, sz, now)
		sz = st.sz
		if not sz then return end
	end
	-- what it takes from consciousness: a little while one limb jerks and the person looks on;
	-- most of it when awareness is lost but the person stays on the feet (Z-City drops a character
	-- below 0.4); all of it while the whole body is involved; after it, the first half of the
	-- postictal time unresponsive, then coming round
	if sz.phase == "focal" then
		st.ictal = 0.25
	elseif sz.phase == "impaired" then
		st.ictal = 0.52
	elseif sz.phase == "postictal" then
		local f = (now - sz.t0) / math.max(sz.tEnd - sz.t0, 0.1)
		st.ictal = f < 0.5 and 1 or (1 - (f - 0.5) * 2) * 0.55
		if st.postictalUntil then
			st.postictal = st.postictalFull or 0
			Todd(st, st.postictal)
		end
	else
		-- (jerks at an arrest: consciousness is already going for want of blood flow)
		st.ictal = (sz.kind == "jerks") and 0 or 1
	end
	-- Status: past the second time point the seizure itself injures the brain, the hippocampus
	-- first [S: Z8 for the time point; the structure and the rate are P]
	if sz.convSince and CONVULSIVE[sz.phase] then
		local ran = now - sz.convSince
		if ran >= CS.statusAfter and not sz.statusLogged then
			sz.statusLogged = true
			NT.States.Push(st, ply, string.format("status epilepticus: convulsing for %.0f s", ran))
		end
		if ran >= CS.harmAfter and now >= (sz.nextHarm or 0) then
			sz.nextHarm = now + 10
			for _, key in ipairs({ "L_hippocampus", "R_hippocampus" }) do NT.Anatomy.DamageRegion(st, A.regionOf[key], CS.harmPer10s) end
		end
	end
end

-- A seizure with a given course (developer commands and tests): plan = { { phase, dur }, ... }
function SZ.Force(ply, st, now, plan, side, todd, status)
	if st.sz then st.sz = nil end
	local sz = { plan = {}, index = 1, side = side or 1, strength = 1, kind = "forced", todd = todd, stops = not status }
	for _, s in ipairs(plan) do sz.plan[#sz.plan + 1] = { phase = s[1], dur = s[2] } end
	for _, s in ipairs(sz.plan) do
		if s.phase == "tonic" then sz.hasTonic = true elseif s.phase == "clonic" then sz.hasClonic = true end
	end
	st.sz = sz
	NT.States.Push(st, ply, "seizure begins (forced)" .. (status and "; it will not stop by itself" or ""))
	Enter(ply, st, sz, now)
end
