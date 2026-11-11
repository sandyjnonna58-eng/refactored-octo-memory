-- The anatomy of one injured brain: which regions and tracts are damaged, which are only switched
-- off for now, and what the brain can therefore still do (the channels of sh_atlas.lua).
--
-- It lives inside the neurological record (st.an), is sparse (only what is not healthy is stored)
-- and is worked out when something changes, never per tick: an injury, a vessel, a lesion that
-- has grown, the flow of blood. The result is a flat table of channel values that the rest of
-- the module reads (sv_brain.lua, Derive).
--
--   damage        permanent within a round: bruising under a blow, the track of a bullet, an infarct
--   suppression   reversible: too little blood, a lesion pressing on it, the minutes after a seizure
--
-- A structure works as (1 - damage) x (1 - suppression).

local NT = NeuroTrauma
NT.Anatomy = NT.Anatomy or {}
local AN = NT.Anatomy
local A, C, E = NT.Atlas, NT.Config, NT.E
local CA = C.Anatomy
local exp, max, min, sqrt, Clamp = math.exp, math.max, math.min, math.sqrt, math.Clamp

------------------------------------------------------------------------------------------
-- Channel definitions resolved to ids, once for each language-dominant hemisphere (sh_atlas.lua)
------------------------------------------------------------------------------------------
local compiled = A.compiled
AN.compiled = compiled

-- the brainstem levels that carry arousal (sh_atlas.lua, A.arousal)
local STEM = {}
for i, key in ipairs(A.arousal.levels) do STEM[i] = { A.regionOf["L_" .. key], A.regionOf["R_" .. key] } end
local THAL = { A.regionOf.L_thal_paramedian, A.regionOf.R_thal_paramedian }
local MED = { A.regionOf.L_medulla_teg, A.regionOf.R_medulla_teg }

------------------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------------------
-- seed: the character's own (one life). Decides the language-dominant hemisphere [S: N16] and how
-- good the collateral vessels are [P; N7 on what they decide].
function AN.New(st, seed)
	local rng = NT.RNG(seed)
	local D = A.dominance
	local rightHanded = rng:Next() < D.rightHanded
	local domRight = rng:Next() < (rightHanded and D.rightDominantIfRight or D.rightDominantIfLeft)
	local forced = C.sv.dominance and C.sv.dominance:GetString() or "auto"
	if forced == "left" then domRight = false elseif forced == "right" then domRight = true end
	local an = {
		d = {}, td = {},                    -- damage: region id / tract id -> 0..1
		src = {}, tsrc = {},                -- suppression by source: name -> { id -> 0..1 }
		rs = {}, ts = {},                   -- suppression, all sources together
		ch = {}, why = {},                  -- channel values and the stage that limits each
		stg = {},                           -- stage by stage: channel key -> { what each stage still carries }
		dom = domRight and "R" or "L", handed = rightHanded and "R" or "L",
		dirty = true, diffuseAt = 0, version = 0,
		lesionL = 0, lesionR = 0, stemArousal = 0, medulla = 1,
		rng = rng,
	}
	st.an = an
	if NT.Vascular then NT.Vascular.New(st, an, rng) end
	AN.Compute(st)
	return an
end

local function Touch(an) an.dirty = true end
AN.Touch = Touch

------------------------------------------------------------------------------------------
-- Writing damage
------------------------------------------------------------------------------------------
function AN.DamageRegion(st, id, amount)
	if amount <= 0 or not id then return 0 end
	local an = st.an
	local was = an.d[id] or 0
	local now = min(was + amount * (1 - was * 0.5), 1)
	an.d[id] = now
	an.dirty = true
	return now - was
end

function AN.DamageTract(st, id, amount)
	if amount <= 0 or not id then return 0 end
	local an = st.an
	local was = an.td[id] or 0
	local now = min(was + amount, 1)
	an.td[id] = now
	an.dirty = true
	return now - was
end

function AN.SetRegion(st, id, value)
	st.an.d[id] = value > 0 and min(value, 1) or nil
	st.an.dirty = true
end
function AN.SetTract(st, id, value)
	st.an.td[id] = value > 0 and min(value, 1) or nil
	st.an.dirty = true
end

-- A source of suppression replaces its own earlier map (nil clears it).
function AN.Suppress(st, name, regions, tracts)
	local an = st.an
	an.src[name] = regions
	an.tsrc[name] = tracts
	an.dirty = true
end

-- A bruise: cortex around a point of the surface, most at the point [S: C11 N84; the shape is G].
-- x, y, z in the atlas frame (x > 0 is the left side). deep: how much of it reaches the deep grey.
function AN.Contusion(st, x, y, z, amount, sigma, deep)
	local hit = {}
	sigma = sigma or CA.contusionSigma
	for id, r in ipairs(A.regions) do
		if r.kind == "C" or (deep and deep > 0 and r.kind == "D") then
			local dx, dy, dz = r.x - x, r.y - y, r.z - z
			local k = exp(-(dx * dx + dy * dy + dz * dz) / (sigma * sigma))
			if r.kind == "D" then k = k * deep end
			local add = amount * k
			if add > 0.02 then
				AN.DamageRegion(st, id, add)
				hit[#hit + 1] = { id, add }
			end
		end
	end
	return hit
end

-- The same value on the outer surface of one hemisphere around the central sulcus: what a
-- hemisphere-level number stands for when nothing says where the injury is (developer commands,
-- events without a point of impact).
function AN.Convexity(st, side, amount)
	local sx = side == "R" and -1 or 1
	return AN.Contusion(st, 0.75 * sx, 0.0, 0.55, amount, 0.5, 0)
end

-- A wound track: a straight line from a to b in the atlas frame. Everything within reach of the
-- line is destroyed in proportion to how close it lies; `reach` grows with the energy of the
-- projectile (the temporary cavity [P; research section 6]). Returns what was hit, for the log.
local function SegDist(px, py, pz, ax, ay, az, bx, by, bz)
	local vx, vy, vz = bx - ax, by - ay, bz - az
	local wx, wy, wz = px - ax, py - ay, pz - az
	local vv = vx * vx + vy * vy + vz * vz
	local t = vv > 1e-6 and Clamp((wx * vx + wy * vy + wz * vz) / vv, 0, 1) or 0
	local cx, cy, cz = ax + vx * t - px, ay + vy * t - py, az + vz * t - pz
	return sqrt(cx * cx + cy * cy + cz * cz), t
end
AN.SegDist = SegDist

function AN.Track(st, ax, ay, az, bx, by, bz, reach, strength)
	local regions, tracts, vessels = {}, {}, {}
	for id, r in ipairs(A.regions) do
		local dist = SegDist(r.x, r.y, r.z, ax, ay, az, bx, by, bz)
		local lim = r.radius + reach
		if dist < lim then
			local add = strength * (1 - dist / lim) ^ 0.7
			if add > 0.03 then
				AN.DamageRegion(st, id, add)
				regions[#regions + 1] = { id, add }
			end
		end
	end
	for id, t in ipairs(A.tracts) do
		local dist = SegDist(t.x, t.y, t.z, ax, ay, az, bx, by, bz)
		local lim = t.radius + reach
		if dist < lim then
			local add = strength * (1 - dist / lim) ^ 0.7
			if add > 0.03 then
				AN.DamageTract(st, id, add)
				tracts[#tracts + 1] = { id, add }
			end
		end
	end
	for id, v in ipairs(A.vessels) do
		local dist = SegDist(v.x, v.y, v.z, ax, ay, az, bx, by, bz)
		if dist < CA.vesselReach + reach * 0.5 then vessels[#vessels + 1] = id end
	end
	return regions, tracts, vessels
end

-- What kind of trajectory a straight track is, without touching anybody's brain: read in the
-- instant of the hit to decide what the injury is. The outcome of a gunshot wound of the head
-- goes with where the bullet went [S: G1 G2 G3 G4]: through one hemisphere or both, through the
-- deep middle and the ventricles, through the posterior fossa; and with how many lobes.
-- Returns:
--   hemiL, hemiR   how much of each hemisphere's cortex and deep grey lies on the track (a sum of
--                  what each structure would lose)
--   both           both hemispheres are crossed behind the frontal poles ("bifrontal" is not both
--                  in this sense: it goes with the one-sided tracks in outcome [S: G2])
--   central        the deep grey of the middle (thalamus, hypothalamus, caudate, pallidum) or a
--                  ventricle is on the track, 0..1
--   fossa          cerebellum or brainstem is on the track, 0..1
--   medulla        how much of the medullary tegmentum would be lost, the lesser side
--   stemLoad       the load on arousal the track itself puts on midbrain and pons (as AN.Compute)
--   lobes          how many lobes are touched (both sides counted apart)
local CENTRAL = { thal_anterior = true, thal_paramedian = true, thal_lateral = true, thal_posterior = true, hypothalamus = true, caudate = true, pallidum = true }
function AN.Survey(ax, ay, az, bx, by, bz, reach, strength)
	local s = { hemiL = 0, hemiR = 0, both = false, central = 0, fossa = 0, medulla = 0, stemLoad = 0, lobes = 0 }
	local lobes, loss = {}, {}
	local rearL, rearR = 0, 0
	for id, r in ipairs(A.regions) do
		local dist = SegDist(r.x, r.y, r.z, ax, ay, az, bx, by, bz)
		local lim = r.radius + reach
		if dist < lim then
			local add = min(strength * (1 - dist / lim) ^ 0.7, 1)
			if add > 0.03 then
				loss[id] = add
				if r.kind == "C" or r.kind == "D" then
					if r.side == "L" then s.hemiL = s.hemiL + add elseif r.side == "R" then s.hemiR = s.hemiR + add end
					if r.y < 0.5 then
						if r.side == "L" then rearL = rearL + add elseif r.side == "R" then rearR = rearR + add end
					end
					if add > 0.15 then lobes[r.side .. r.lobe] = true end
					if CENTRAL[r.base] then s.central = max(s.central, add) end
				else
					s.fossa = max(s.fossa, add)
				end
			end
		end
	end
	for _, vp in ipairs(C.Vascular.ventricles) do
		if SegDist(vp[1], vp[2], vp[3], ax, ay, az, bx, by, bz) < vp[4] then s.central = max(s.central, 0.6) s.ventricle = true break end
	end
	for _ in pairs(lobes) do s.lobes = s.lobes + 1 end
	s.both = rearL > 0.3 and rearR > 0.3
	s.medulla = min(loss[MED[1]] or 0, loss[MED[2]] or 0)
	local one = A.arousal.oneSide
	for i = 1, #STEM do
		local a, b = loss[STEM[i][1]] or 0, loss[STEM[i][2]] or 0
		s.stemLoad = max(s.stemLoad, one * max(a, b) + (1 - one) * min(a, b))
	end
	return s
end

-- The same for an event, with the reach its energy gives it (nil if the event has no track).
function AN.SurveyEvent(ev)
	if not ev.trackA or not ev.trackB then return nil end
	if ev.survey then return ev.survey end
	local a, b = ev.trackA, ev.trackB
	local e = Clamp((ev.energy or 0) / C.Load.energyRef, C.Load.energyMin, C.Load.energyMax)
	ev.survey = AN.Survey(a[1], a[2], a[3], b[1], b[2], b[3], CA.trackReach * (0.6 + 0.4 * e), min(0.75 + 0.25 * e, 1))
	ev.survey.e = e
	return ev.survey
end

------------------------------------------------------------------------------------------
-- Working it out
------------------------------------------------------------------------------------------
local function Merge(an)
	local rs, ts = {}, {}
	for _, map in pairs(an.src) do
		for id, s in pairs(map) do
			local was = rs[id]
			rs[id] = was and (1 - (1 - was) * (1 - s)) or s
		end
	end
	for _, map in pairs(an.tsrc) do
		for id, s in pairs(map) do
			local was = ts[id]
			ts[id] = was and (1 - (1 - was) * (1 - s)) or s
		end
	end
	an.rs, an.ts = rs, ts
end

function AN.Compute(st)
	local an = st.an
	Merge(an)
	local d, td, rs, ts = an.d, an.td, an.rs, an.ts
	local diffuse = min(st.diffuse or 0, 1)
	an.diffuseAt = diffuse
	local daiK = CA.daiTract * diffuse
	local tracts = A.tracts
	local comp = compiled[an.dom]
	local ch, why = an.ch, an.why
	for i = 1, #comp do
		local c = comp[i]
		local v, limit, limitName = 1, 1, nil
		local caps = an.stg[c.key]
		if not caps then caps = {} an.stg[c.key] = caps end
		local stages = c.stages
		for s = 1, #stages do
			local stg = stages[s]
			local items = stg.items
			local sum = 0
			for k = 1, #items do
				local it = items[k]
				local id = it[2]
				local f
				if it[1] then
					f = (1 - (td[id] or 0)) * (1 - (ts[id] or 0)) * (1 - tracts[id].dai * daiK)
				else
					f = (1 - (d[id] or 0)) * (1 - (rs[id] or 0))
				end
				sum = sum + it[3] * f
			end
			local cap = sum / (1 - stg.reserve)
			if cap > 1 then cap = 1 end
			if cap < limit then limit, limitName = cap, stg.name end
			caps[s] = cap
			v = v * cap
		end
		ch[c.key] = v
		why[c.key] = limitName
	end

	-- how much of each hemisphere's cortex works, and how much of it is destroyed
	for _, side in ipairs({ "L", "R" }) do
		local ids = A.cortexIds[side]
		local fn, lost = 0, 0
		for i = 1, #ids do
			local id = ids[i]
			local dm = d[id] or 0
			fn = fn + (1 - dm) * (1 - (rs[id] or 0))
			lost = lost + dm
		end
		ch["cortex" .. side] = fn / #ids
		an["lesion" .. side] = lost / #ids
	end

	-- neglect of one half of space, from the hemisphere opposite to it
	local nondom = an.dom == "L" and "R" or "L"
	for _, side in ipairs({ "L", "R" }) do
		local list = comp.neglect[side]
		local dm = 0
		for i = 1, #list do
			local id = list[i][1]
			dm = dm + list[i][2] * (1 - (1 - (d[id] or 0)) * (1 - (rs[id] or 0)))
		end
		local v = Clamp((dm - A.neglect.from) / (1 - A.neglect.from), 0, 1)
		if side ~= nondom then v = v * A.neglect.dominantShare end
		-- (a lesion of the right hemisphere neglects the left half of space)
		ch["neglect" .. (side == "L" and "R" or "L")] = v
	end

	-- the brainstem's load on arousal: both sides of a level count for far more than one [S: N14]
	-- Two readings each: what does not work now (damage and what is switched off), and what is
	-- destroyed. Only the second may count as a lasting injury of the brain: a brain without blood
	-- for a minute is switched off, not gone.
	local one = A.arousal.oneSide
	local function Level(pair)
		local da, db = d[pair[1]] or 0, d[pair[2]] or 0
		local a = 1 - (1 - da) * (1 - (rs[pair[1]] or 0))
		local b = 1 - (1 - db) * (1 - (rs[pair[2]] or 0))
		return one * max(a, b) + (1 - one) * min(a, b), one * max(da, db) + (1 - one) * min(da, db)
	end
	local load, loadD = 0, 0
	for i = 1, #STEM do
		local f, dm = Level(STEM[i])
		load, loadD = max(load, f), max(loadD, dm)
	end
	an.stemArousal, an.stemArousalD = load, loadD
	local _, thalD = Level(THAL)
	an.thalD = thalD
	-- how much of the medulla works (a posture is made below the lesion: it needs one)
	an.medulla = ((1 - (d[MED[1]] or 0)) * (1 - (rs[MED[1]] or 0)) + (1 - (d[MED[2]] or 0)) * (1 - (rs[MED[2]] or 0))) * 0.5
	an.dirty = false
	an.version = an.version + 1
end

-- Channel values, up to date.
function AN.Channels(st)
	local an = st.an
	if an.dirty or math.abs((st.diffuse or 0) - an.diffuseAt) > 0.03 then AN.Compute(st) end
	return an.ch, an.why
end

-- One channel stage by stage, for the trace: a list of { name of the stage, what the stage still
-- carries, what is left of the signal after it }, and the value of the channel.
function AN.Trace(st, key)
	local an = st.an
	AN.Channels(st)
	local comp = compiled[an.dom]
	for i = 1, #comp do
		local c = comp[i]
		if c.key == key then
			local caps = an.stg[key] or {}
			local out, signal = {}, 1
			for s, stg in ipairs(c.stages) do
				local cap = caps[s] or 1
				signal = signal * cap
				out[s] = { stg.name, cap, signal }
			end
			return out, an.ch[key]
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- An injury event writes itself into the anatomy (called from sv_brain.lua with the loads).
------------------------------------------------------------------------------------------
local function Site(ev)
	-- where on the head: the unit direction from the centre of the skull to the point of impact,
	-- in the head's own frame (left, front, up)
	local h = ev.hit
	if h then return h[1], h[2], h[3] end
	local R = E.Region
	local lat = ev.lat or 0
	local reg = ev.region
	if reg == R.FRONT then return lat * 0.5, 0.9, 0.2 end
	if reg == R.BACK then return lat * 0.5, -0.9, 0.1 end
	if reg == R.LEFT then return 0.95, 0, 0.2 end
	if reg == R.RIGHT then return -0.95, 0, 0.2 end
	if reg == R.TOP then return lat * 0.4, 0, 0.95 end
	if reg == R.BASE then return lat * 0.4, -0.3, -0.9 end
	if reg == R.FACE then return lat * 0.4, 0.85, -0.4 end
	return nil
end
AN.Site = Site

function AN.ApplyEvent(st, ev, L)
	local an = st.an
	local notes = {}
	local x, y, z = Site(ev)
	if ev.mech == E.Mech.PROJECTILE and ev.trackA and (ev.pen == E.Pen.PENETRATING or ev.pen == E.Pen.PERFORATING) then
		local a, b = ev.trackA, ev.trackB
		local e = Clamp((ev.energy or 0) / C.Load.energyRef, C.Load.energyMin, C.Load.energyMax)
		local reach = CA.trackReach * (0.6 + 0.4 * e)
		local regions, tracts, vessels = AN.Track(st, a[1], a[2], a[3], b[1], b[2], b[3], reach, min(0.75 + 0.25 * e, 1))
		table.sort(regions, function(p, q) return p[2] > q[2] end)
		local names = {}
		for i = 1, min(#regions, 5) do names[#names + 1] = A.regions[regions[i][1]].name end
		for i = 1, min(#tracts, 3) do names[#names + 1] = A.tracts[tracts[i][1]].name end
		if #names > 0 then notes[#notes + 1] = "track through " .. table.concat(names, ", ") end
		if NT.Vascular then
			local vn = NT.Vascular.TrackVessels(st, vessels, ev.seed)
			if vn then notes[#notes + 1] = vn end
		end
	else
		-- a bruise under the blow and a smaller one opposite it; the loads are those of the
		-- hemisphere model (sv_biomech.lua), the anatomy says where they sit
		for _, side in ipairs({ "L", "R" }) do
			local amount = side == "L" and L.focalL or L.focalR
			if amount > 0.03 then
				local sx = side == "L" and 1 or -1
				if x then
					local sameSide = (x * sx) > 0.15
					local midline = math.abs(x) <= 0.15
					if sameSide or midline then
						AN.Contusion(st, sx * max(math.abs(x), 0.3), y, z, amount, nil, amount > 0.6 and 0.3 or 0)
						if midline then AN.Contusion(st, sx * 0.35, -y, -z * 0.4, amount * CA.contrecoup, nil, 0) end
					else
						-- the far hemisphere: struck against the inside of the skull opposite the blow
						AN.Contusion(st, sx * max(math.abs(x), 0.3), -y, -z * 0.4, amount, nil, 0)
					end
				else
					AN.Convexity(st, side, amount)
				end
				-- the frontal and temporal poles ride over the rough floor of the skull [P]
				if amount > CA.poleFrom then
					local pa = (amount - CA.poleFrom) * CA.poleShare
					for _, key in ipairs({ "frontalpole", "lateralorbitofrontal", "medialorbitofrontal", "temporalpole" }) do
						AN.DamageRegion(st, A.regionOf[side .. "_" .. key], pa)
					end
				end
			end
		end
	end
	an.dirty = true
	return notes
end

------------------------------------------------------------------------------------------
-- Readout
------------------------------------------------------------------------------------------
-- The damaged structures, worst first (for the panel, the log and the developer's drawing).
function AN.Lesions(st, limit)
	local an = st.an
	local list = {}
	for id, v in pairs(an.d) do if v > 0.02 then list[#list + 1] = { A.regions[id].name, v, false } end end
	for id, v in pairs(an.td) do if v > 0.02 then list[#list + 1] = { A.tracts[id].name, v, true } end end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	while limit and #list > limit do table.remove(list) end
	return list
end

function AN.Describe(st, limit)
	local parts = {}
	for _, l in ipairs(AN.Lesions(st, limit or 6)) do parts[#parts + 1] = string.format("%s %.2f", l[1], l[2]) end
	return #parts > 0 and table.concat(parts, ", ") or "none"
end
