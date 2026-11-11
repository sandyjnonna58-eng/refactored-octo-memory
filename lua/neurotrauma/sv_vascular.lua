-- Blood for the brain: which vessels are open, what reaches each region, and what a shortage does.
--
--   a vessel      is open (1), narrowed, or shut (0). Blood reaches a branch through its parent;
--                 the stems are joined by the circle of Willis, so a shut carotid can be made up
--                 for through the communicating arteries, as far as this person's are any good
--                 [S: N33 N7]. Cortical branches get a further share over the surface from the
--                 neighbouring territory; perforators get none: they are end arteries [S: N40].
--   a region      gets the weighted flow of its supplying branches (sh_atlas.lua) times what the
--                 circulation as a whole delivers: Z-City's blood pressure, less what the pressure
--                 inside the skull takes from it (perfusion pressure = arterial - intracranial
--                 [S: K13]), with a plateau for autoregulation [S: K12].
--   too little    function stops first (reversible), tissue dies when it lasts [concept: N8;
--                 thresholds G]. A focal infarct matures on the compressed clock (hours in life
--                 [S: N9]); with no circulation at all the whole brain is injured within minutes of
--                 real time, the susceptible structures first [S: K2 K11].
--
-- Nothing here runs unless a vessel is not fully open or the circulation is failing: a record with
-- healthy vessels costs one comparison per step.

local NT = NeuroTrauma
NT.Vascular = NT.Vascular or {}
local VA = NT.Vascular
local A, C, E = NT.Atlas, NT.Config, NT.E
local CV = C.Vascular
local max, min, Clamp = math.max, math.min, math.Clamp

------------------------------------------------------------------------------------------
-- The circle of Willis, resolved to vessel ids for both sides (static)
------------------------------------------------------------------------------------------
local willis, isWillis = {}, {}
for _, side in ipairs({ "L", "R" }) do
	local other = side == "L" and "R" or "L"
	for _, def in ipairs(A.willis) do
		local node = A.vesselOf[side .. "_" .. def[1]]
		local rules = {}
		for i, r in ipairs(def[2]) do
			local from = r[1]
			if from == "SRC" then
				rules[i] = { src = true, cap = r[2], spread = r[3] }
			elseif string.sub(from, -1) == "*" then
				rules[i] = { from = A.vesselOf[other .. "_" .. string.sub(from, 1, -2)], cap = r[2], spread = r[3] }
			else
				rules[i] = { from = A.vesselOf[side .. "_" .. from], cap = r[2], spread = r[3] }
			end
		end
		willis[#willis + 1] = { node = node, rules = rules, via = def.via and A.vesselOf[side .. "_" .. def.via] or nil }
		isWillis[node] = true
	end
end

-- the stem that stands for each territory when its neighbour needs surface collaterals
local leptoRep = {}
for _, side in ipairs({ "L", "R" }) do
	leptoRep[side] = {
		aca = A.vesselOf[side .. "_aca_a3"], mca = A.vesselOf[side .. "_mca_m1"],
		pca = A.vesselOf[side .. "_pca_p2"], vb = A.vesselOf[side .. "_basilar_half"],
	}
end
local LEPTO = { aca = { "mca", "pca" }, mca = { "aca", "pca" }, pca = { "mca", "aca" }, vb = { "vb" }, ica = {} }

------------------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------------------
function VA.New(st, an, rng)
	an.pat = {}                 -- vessel id -> patency, only when not 1
	an.deliv = {}               -- vessel id -> what reaches it (0..1)
	an.wcap = {}                -- capacities of the collateral routes, this person's
	for i, w in ipairs(willis) do
		local caps = {}
		for k, r in ipairs(w.rules) do
			caps[k] = Clamp(r.cap + (rng:Next() * 2 - 1) * r.spread, 0, 1)
		end
		an.wcap[i] = caps
	end
	an.lepto = rng:Range(CV.leptoQuality[1], CV.leptoQuality[2])
	an.perf, an.tperf = {}, {}  -- region / tract id -> flow, only when below 1
	an.isch = {}                -- region id -> damage that ischaemia has done there
	an.sah, an.ivh = 0, 0
	an.sys = 1
	an.flowDirty = false
	an.vascActive = false
	an.infarct = 0
end

local function Flow(an)
	local deliv, pat = an.deliv, an.pat
	local vessels = A.vessels
	for id = 1, #vessels do deliv[id] = 0 end
	for _ = 1, 4 do
		for i = 1, #willis do
			local w = willis[i]
			local caps = an.wcap[i]
			local best = 0
			local rules = w.rules
			for k = 1, #rules do
				local r = rules[k]
				local v = r.src and 1 or deliv[r.from]
				local c = min(v, caps[k])
				if c > best then best = c end
			end
			deliv[w.node] = best * (pat[w.node] or 1) * (w.via and (pat[w.via] or 1) or 1)
		end
	end
	for id = 1, #vessels do
		local v = vessels[id]
		if not isWillis[id] and v.parentId then deliv[id] = deliv[v.parentId] * (pat[id] or 1) end
	end
	-- surface collaterals for cortical branches whose own feeder is short
	for id = 1, #vessels do
		local v = vessels[id]
		if v.kind == "C" and deliv[id] < 0.99 and (pat[id] or 1) > 0 then
			local rep = leptoRep[v.side]
			local best = 0
			for _, m in ipairs(LEPTO[v.major] or {}) do
				local r = rep[m]
				if r and r ~= id and deliv[r] > best then best = deliv[r] end
			end
			local col = best * A.leptoShare * an.lepto
			if col > deliv[id] then deliv[id] = col end
		end
	end
	an.flowDirty = false
end
VA.Flow = Flow

function VA.SetPatency(st, key, patency, why)
	local an = st.an
	local id = isnumber(key) and key or A.vesselOf[key]
	if not id then return false end
	patency = Clamp(patency, 0, 1)
	an.pat[id] = patency < 1 and patency or nil
	an.flowDirty = true
	an.vascActive = true
	an.dirty = true
	if why then an.vesselNote = why end
	return true
end

function VA.Patency(st, key)
	local id = isnumber(key) and key or A.vesselOf[key]
	return id and (st.an.pat[id] or 1) or nil
end

------------------------------------------------------------------------------------------
-- What the circulation as a whole delivers (0..1)
------------------------------------------------------------------------------------------
function VA.Systemic(org, st)
	local pressure = tonumber(org.pulse) or 70          -- Z-City: "that's the blood pressure", 70 at rest
	local icp = min(st.pressure or 0, 1.2)
	local flow = Clamp((pressure - CV.icpWeight * icp) / CV.plateau, 0, 1)
	if org.heartstop == true then
		-- A heart that has stopped delivers nothing by itself. Z-City's pressure value rests a
		-- little above zero when the heart is stopped: that is not flow. Two things remain:
		--   the oxygen the brain still holds, which lets it go on for some seconds [S: R5; the
		--   length is G]: read as a flow that runs down from the moment of the arrest;
		--   compressions: Z-City's lift its pressure value in steps, up to normal. What stands
		--   above the resting value of a stopped heart is taken as their work, capped: a chest
		--   compressed by hand does not perfuse a brain like a beating heart [P; the cap is G].
		--   (Z-City's value also takes about twenty seconds to sink after the heart has stopped:
		--   for that long it counts like compressions, a short grace before injury begins.)
		local since = st.arrestSince and (CurTime() - st.arrestSince) or 0
		local reserve = Clamp(1 - since / CV.arrestReserve, 0, 1)
		local cpr = Clamp((pressure - CV.stoppedPulse) / CV.plateau, 0, CV.cprFlow)
		flow = max(min(flow, reserve), cpr)
	end
	return flow
end

------------------------------------------------------------------------------------------
-- One step (called with every step of the record; does its work once a second, and only when
-- there is something to work out)
------------------------------------------------------------------------------------------
function VA.Step(ply, org, st, now, dt, sdt)
	local an = st.an
	local sys = VA.Systemic(org, st)
	local sysQ = math.floor(sys * 20 + 0.5) / 20
	if sysQ < 1 then an.vascActive = true end
	if not an.vascActive then return end
	if not an.flowDirty and sysQ == an.sys and now < (an.nextVasc or 0) then return end
	local step = an.lastVasc and (now - an.lastVasc) or 0
	an.lastVasc = now
	an.nextVasc = now + 1
	an.sys = sysQ
	if an.flowDirty or not an.deliv[1] then Flow(an) end

	local deliv = an.deliv
	local perf, tperf = {}, {}
	local sup, tsup = {}, {}
	local span = CV.thrFunction - CV.thrCore
	local sstep = step * C.sv.timescale:GetFloat()
	-- (a heart that has stopped: the real-time clock, whatever compressions deliver. They slow the
	-- injury by what they deliver, they do not move it onto the clock of hours)
	local arrest = sys < CV.arrestBelow or org.heartstop == true
	-- (the first half minute without a heartbeat injures nothing [G]: a heart that is restarted
	-- at once leaves a brain as it was)
	local spared = org.heartstop == true and st.arrestSince ~= nil and (now - st.arrestSince) < CV.arrestGrace
	local any, infarct, total = false, 0, 0
	local changed = false
	for id, r in ipairs(A.regions) do
		local list = r.supplyIds
		local p = 0
		for i = 1, #list do p = p + list[i][2] * deliv[list[i][1]] end
		p = p * sys
		if r.watershed and sys < 1 then p = p * (1 - CV.watershed * (1 - sys)) end
		if p < 0.999 then
			perf[id] = p
			any = true
			if p < CV.thrFunction then
				sup[id] = Clamp((CV.thrFunction - p) / span, 0, 1)
				if p < CV.thrCore and step > 0 then
					local lack = 1 - p / CV.thrCore
					local add
					if arrest then
						add = spared and 0 or r.hypoxia * lack * step / CV.arrestSeconds
					else
						add = (0.5 + 0.5 * r.hypoxia) * lack * sstep / (CV.coreHours * 3600)
					end
					if add > 0 and (an.d[id] or 0) < 1 then
						local got = NT.Anatomy.DamageRegion(st, id, add)
						an.isch[id] = (an.isch[id] or 0) + got
						changed = true
					end
				end
			end
		end
		infarct = infarct + (an.isch[id] or 0)
		total = total + 1
	end
	for id, t in ipairs(A.tracts) do
		local list = t.supplyIds
		-- (no vessel of the atlas feeds it, as with the spinal cord: the circulation as a whole does)
		local p = #list == 0 and 1 or 0
		for i = 1, #list do p = p + list[i][2] * deliv[list[i][1]] end
		p = p * sys
		if p < 0.999 then
			tperf[id] = p
			any = true
			if p < CV.thrFunction then
				tsup[id] = Clamp((CV.thrFunction - p) / span, 0, 1)
				if p < CV.thrCore and step > 0 and not arrest then
					local add = 0.5 * (1 - p / CV.thrCore) * sstep / (CV.coreHours * 3600)
					if add > 0 then NT.Anatomy.DamageTract(st, id, add) changed = true end
				end
			end
		end
	end
	-- after the circulation has come back: the part of the injury that only follows then (sv_cardioresp.lua)
	local sh = an.secondHit
	if sh and step > 0 then
		local part = math.min(sstep / math.max(sh.left, 1), 1)
		for id, amt in pairs(sh.map) do
			local add = amt * part
			an.isch[id] = (an.isch[id] or 0) + NT.Anatomy.DamageRegion(st, id, add)
			sh.map[id] = amt - add
		end
		sh.left = sh.left - sstep
		if sh.left <= 0 then an.secondHit = nil end
		changed = true
	end
	an.perf, an.tperf = perf, tperf
	an.infarct = infarct / total
	-- (the map of what is switched off is replaced only when it differs: a new map means a new
	-- working-out of every channel)
	local key = 0
	for id, s in pairs(sup) do key = key + id * math.floor(s * 10 + 0.5) end
	for id, s in pairs(tsup) do key = key + (id + 500) * math.floor(s * 10 + 0.5) end
	if key ~= an.supKey or changed then
		an.supKey = key
		NT.Anatomy.Suppress(st, "perfusion", next(sup) and sup or nil, next(tsup) and tsup or nil)
	end
	-- nothing short of blood any more and every vessel open: the layer goes back to sleep
	if not any and next(an.pat) == nil and not an.secondHit then
		an.vascActive = false
		if an.src.perfusion or an.tsrc.perfusion then NT.Anatomy.Suppress(st, "perfusion", nil, nil) end
	end
end

------------------------------------------------------------------------------------------
-- Vessels opened by a wound track: an artery that is cut delivers nothing beyond the cut and
-- bleeds into the space around the brain [S: N51 N52; amounts G].
------------------------------------------------------------------------------------------
function VA.TrackVessels(st, ids, seed)
	local an = st.an
	if #ids == 0 then return nil end
	local names, large = {}, false
	for _, id in ipairs(ids) do
		local v = A.vessels[id]
		VA.SetPatency(st, id, 0)
		if v.kind == "C" or v.kind == "P" then
			an.sah = min(an.sah + CV.sahSmall, 1)
		else
			an.sah = min(an.sah + CV.sahLarge, 1)
			large = true
		end
		if #names < 4 then names[#names + 1] = v.name end
	end
	an.cutLarge = an.cutLarge or large
	return "cut: " .. table.concat(names, ", ") .. (#ids > 4 and string.format(" and %d more", #ids - 4) or "")
end

-- A wound track or a fracture through the fluid spaces or a venous channel.
function VA.TrackSpaces(st, ax, ay, az, bx, by, bz)
	local an = st.an
	local out = {}
	for _, vp in ipairs(CV.ventricles) do
		if NT.Anatomy.SegDist(vp[1], vp[2], vp[3], ax, ay, az, bx, by, bz) < vp[4] then
			an.ivh = min(an.ivh + CV.ivhAdd, 1)
			out[#out + 1] = "blood in the ventricles"
			break
		end
	end
	for _, v in ipairs(A.venous) do
		if NT.Anatomy.SegDist(v[3], v[4], v[5], ax, ay, az, bx, by, bz) < v[6] then
			out[#out + 1] = v[2] .. " opened"
			an.sinus = true
		end
	end
	return #out > 0 and table.concat(out, "; ") or nil
end

------------------------------------------------------------------------------------------
-- Readout
------------------------------------------------------------------------------------------
function VA.Describe(st)
	local an = st.an
	local shut = {}
	for id, p in pairs(an.pat) do shut[#shut + 1] = string.format("%s %.0f%%", A.vessels[id].name, p * 100) end
	table.sort(shut)
	local low = {}
	for id, p in pairs(an.perf) do if p < CV.thrFunction then low[#low + 1] = { A.regions[id].name, p } end end
	table.sort(low, function(a, b) return a[2] < b[2] end)
	local lows = {}
	for i = 1, min(#low, 5) do lows[i] = string.format("%s %.2f", low[i][1], low[i][2]) end
	return string.format("vessels not open: %s | circulation delivers %.2f | short of blood: %s%s | infarcted %.1f%% | blood around the brain %.2f, in the ventricles %.2f",
		#shut > 0 and table.concat(shut, ", ") or "none", an.sys or 1, #lows > 0 and table.concat(lows, ", ") or "none",
		#low > 5 and string.format(" and %d more", #low - 5) or "", (an.infarct or 0) * 100, an.sah, an.ivh)
end
