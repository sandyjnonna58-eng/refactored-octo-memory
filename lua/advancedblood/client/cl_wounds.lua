-- Wound records: the central wound model on the client.
-- Every projectile hit the server reports (abl_hit, sh_wound.lua) becomes one record. It holds what
-- is known about the event (projectile class, range, what was crossed, entry / exit relation) and
-- what ABL derives from it (tissue damage, hidden temporary-cavity factor, how the wound opens, what
-- is left on the skin around it), and it ties together everything that follows from the event:
--   * the marks on the body (cl_woundfx.lua: entry, exit or graze, drawn from the record),
--   * the wounds Z-City bleeds through (cl_emission.lua: its entry / exit / arterial records are
--     matched to the record, bleed from the visible openings and take their character from it),
--   * the first release of blood (E.OnHit),
--   * the wound's surface state over time: wet, clotting, drying (WS.Think).
-- Z-City remains the authority for anatomy, blood volume, pulse and death. Nothing here feeds back
-- into gameplay: it is a physically informed approximation that drives what is seen.

ABL.NoJIT()
ABL.Wounds = ABL.Wounds or {}
local WS = ABL.Wounds
local C, WD, BM = ABL.Config, ABL.Wound, ABL.BodyMesh
local WC = C.Wound
local F = WD.F
local sqrt, min, max, abs, exp = math.sqrt, math.min, math.max, math.abs, math.exp
local band = bit.band
local Clamp = math.Clamp

WS.list = WS.list or {}      -- all records, oldest first
WS.stats = WS.stats or { created = 0, linked = 0 }

-- Body regions by bone name (first match wins).
local REGIONS = {
	{ "Head", "HEAD" }, { "Neck", "NECK" },
	{ "Spine4", "UPPER CHEST" }, { "Spine2", "UPPER CHEST" }, { "Clavicle", "UPPER CHEST" },
	{ "Spine1", "LOWER CHEST" }, { "Spine", "ABDOMEN" }, { "Pelvis", "PELVIS" },
	{ "UpperArm", "UPPER ARM" }, { "Forearm", "FOREARM" }, { "Hand", "HAND" }, { "Finger", "HAND" },
	{ "Thigh", "THIGH" }, { "Calf", "LOWER LEG" }, { "Foot", "FOOT" }, { "Toe", "FOOT" },
}
local regionOf = {}
function WS.Region(boneName)
	if not boneName then return "?" end
	local r = regionOf[boneName]
	if r then return r end
	r = "TORSO"
	for _, e in ipairs(REGIONS) do
		if string.find(boneName, e[1], 1, true) then r = e[2] break end
	end
	regionOf[boneName] = r
	return r
end

-- How much muscle lies under the skin of a region (0 thin, 1 thick): movement works a wound in
-- muscle open, and a deep muscle wound holds more blood back at first.
local MUSCLE = { ["THIGH"] = 1, ["UPPER ARM"] = 0.7, ["LOWER LEG"] = 0.6, ["FOREARM"] = 0.45, ["PELVIS"] = 0.8,
	["UPPER CHEST"] = 0.55, ["LOWER CHEST"] = 0.4, ["ABDOMEN"] = 0.5, ["NECK"] = 0.4, ["HEAD"] = 0.1, ["HAND"] = 0.15, ["FOOT"] = 0.15 }

------------------------------------------------------------------------------------------
-- Creation
------------------------------------------------------------------------------------------
local function Has(r, flag) return band(r.flags, flag) ~= 0 end
WS.Has = Has

-- Everything that follows from what the projectile was and what it crossed (again when a
-- continuation of the same bullet adds to the list).
local function Derive(r)
	-- temporary cavity: hidden. High-velocity, high-energy projectiles stretch the tissue around
	-- their track far beyond the track itself; bone on the path adds secondary fragments
	local cav = (WC.cavityEnergy[r.energy] or 0.25) * (WC.cavityVelocity[r.velocity] or 1)
	if Has(r, F.BONE) then cav = cav * 1.2 end
	if not r.bullet then cav = 0 end
	r.cavity = Clamp(cav, 0, 1)

	-- tissue
	r.muscle = MUSCLE[r.region] or 0.4
	r.boneHit = Has(r, F.BONE)
	r.skull = Has(r, F.SKULL)
	r.organ = Has(r, F.BRAIN + F.LUNG + F.HEART + F.ABDOMEN)
	r.softDamage = Clamp(0.2 + 0.55 * r.cavity + (r.pen == WD.PEN_THROUGH and 0.1 or 0) + (r.boneHit and 0.15 or 0), 0, 1)
	-- blood kept inside: organs and cavities bleed into the body, and a retained projectile leaves
	-- one small opening for it
	local internal = 0
	if Has(r, F.HEART) then internal = 1 elseif Has(r, F.ABDOMEN) then internal = 0.75 elseif Has(r, F.LUNG) then internal = 0.65
	elseif Has(r, F.BRAIN) then internal = 0.5 elseif Has(r, F.ARTERY) then internal = 0.3 end
	if r.pen == WD.PEN_RETAINED then internal = min(1, internal + 0.2) end
	r.internal = internal
	-- the share of the blood lost through this wound that reaches the outside. The rest stays in
	-- the body: in a cavity (chest, abdomen, skull) or in the muscle around the track
	r.external = Clamp((1 - WC.internalShare * internal) * (1 - WC.muscleShare * r.muscle), 0.25, 1)
end

-- A record from a hit event. entry: world position; rng: seeded from the event (every client
-- derives the same wound).
function WS.Create(src, body, ev, rng)
	local N = ABL.Net
	local boneName = body:GetBoneName(ev.bone) or ""
	local bullet = ev.class == N.DMG_BULLET or ev.class == N.DMG_BUCKSHOT
	local r = {
		id = ev.seed or 0, src = src, t0 = CurTime(), bullet = bullet,
		bone = ev.bone, boneName = boneName, region = WS.Region(boneName),
		class = ev.class, pen = ev.pen or WD.PEN_SOFT, energy = ev.energy or 0, velocity = ev.velocity or 0,
		range = ev.range or WD.RANGE_DISTANT, flags = ev.flags or 0,
		diameter = ev.diameter or 0,
		damage = ev.damage or 25, bleed = ev.bleed or 0,
		lentry = ev.lpos, lexit = ev.exitLocal,
		wds = {},            -- Z-City wounds bleeding through this record's openings
		age = 0, wet = 1, clot = 0, dry = 0, bruise = 0, flow = 0,
		released = 0,        -- ml that left this wound so far (burst + bleeding)
		forLooks = ev.forLooks or nil,   -- (abl_wound_test: a wound made to be looked at, which never bleeds)
	}
	if ev.replay then
		-- A wound this client is told of after the fact (cl_events.lua): as old as the server says.
		-- Its bruise has come up by now; how wet or set its surface is depends on whether anything
		-- flows through it still, which is known a moment from now (WS.Think).
		local age = math.max(tonumber(ev.age) or 0, 0)
		r.replayed = true
		r.t0 = r.t0 - age
		r.age = age
		r.bruise = min(1, age / math.max(WC.bruiseTime, 1))
		r.settle = CurTime() + 1
	end
	-- projectile diameter in units (1 unit = 19.05 mm); without data, from the class
	local mm = WD.DiameterMM(ev.diameter)
	if not mm then mm = (ev.class == N.DMG_BUCKSHOT) and 8.4 or (r.energy >= 4 and 6.5 or 9) end
	r.caliberMM = mm
	r.caliber = mm / 19.05
	Derive(r)

	-- direction of the bullet in the wound bone's space (the body moves on). By the bone's
	-- rotation alone: the matrix of a destroyed part (a head Z-City has scaled away) has no inverse
	local M = body:GetBoneMatrix(ev.bone)
	if M then r.ldir = WorldToLocal(ev.dir, angle_zero, vector_origin, M:GetAngles()) end

	-- what is left on the skin around the entry, by range. Soot and powder reach further from a
	-- more powerful cartridge; a projectile that came through something else first carries neither
	local reachK = 0.8 + 0.12 * r.energy
	r.soot, r.stipple, r.burn, r.imprint = 0, 0, 0, 0
	if bullet and not Has(r, F.INTERMEDIATE) then
		if r.range == WD.RANGE_CONTACT then
			r.soot, r.burn, r.imprint, r.stipple = 1, rng:Range(0.5, 1), rng:Range(0.4, 1), 0
		elseif r.range == WD.RANGE_NEAR then
			r.soot, r.stipple, r.burn = rng:Range(0.45, 0.9), rng:Range(0.6, 1), rng:Range(0, 0.3)
		elseif r.range == WD.RANGE_MEDIUM then
			r.stipple = rng:Range(0.3, 0.7)
		end
	end
	r.reachK = reachK
	-- bullet wipe: the grime a bullet carries is wiped off on the first thing it passes through
	r.wipe = (bullet and not Has(r, F.INTERMEDIATE + F.ARMOR)) and rng:Range(0.35, 0.9) or 0
	-- abrasion collar: the skin is scraped as it is pushed in around the projectile
	r.collar = bullet and rng:Range(0.6, 1) or 0

	-- wound openings (units). Skin is elastic: the entry defect is usually a little smaller than
	-- the projectile. A contact shot over bone is torn open by the gas (stellate)
	local elastic = rng:Range(0.72, 0.98)
	r.opening = r.caliber * 0.5 * elastic
	r.stellate = (r.range == WD.RANGE_CONTACT and (r.skull or r.boneHit)) and rng:Range(0.6, 1) or 0
	-- an exit is torn from inside: more irregular, often larger, but not always
	local exitK = 1 + 1.6 * r.cavity * rng:Range(0.4, 1) + (r.boneHit and rng:Range(0.3, 1.1) or 0)
	if rng:Next() < 0.18 then exitK = rng:Range(0.9, 1.15) end -- (a supported exit can be as small as the entry)
	r.exitOpening = r.caliber * 0.5 * exitK

	r.seedF = rng:Next()
	local list = WS.list
	list[#list + 1] = r
	src.wrecs = src.wrecs or {}
	src.wrecs[#src.wrecs + 1] = r
	WS.stats.created = WS.stats.created + 1
	-- cap: the oldest record that has dried goes first, else the oldest
	if #list > WC.maxRecords then
		local drop = 1
		for i = 1, #list do
			if list[i].dry >= 1 then drop = i break end
		end
		WS.Remove(list[drop])
	end
	return r
end

-- The same bullet struck the same character again (the body became a ragdoll in its path, see
-- sv_main.lua): what it crossed there belongs to this wound.
function WS.Extend(r, ev)
	r.flags = bit.bor(r.flags, band(ev.flags or 0, bit.bnot(F.INTERMEDIATE)))
	-- flesh only so far, and now it met tissue: the track goes on
	if r.pen == WD.PEN_SOFT and ev.pen and ev.pen ~= WD.PEN_SOFT and ev.pen ~= WD.PEN_ARMOR then r.pen = ev.pen end
	r.bleed = r.bleed + (ev.bleed or 0)
	Derive(r)
end

function WS.Remove(r)
	if r.gone then return end
	r.gone = true
	for i = 1, #WS.list do
		if WS.list[i] == r then table.remove(WS.list, i) break end
	end
	local sl = r.src and r.src.wrecs
	if sl then
		for i = 1, #sl do
			if sl[i] == r then table.remove(sl, i) break end
		end
	end
	for _, wd in ipairs(r.wds) do wd.rec = nil end
end

function WS.ForgetSource(src)
	local sl = src.wrecs
	if not sl then return end
	for i = #sl, 1, -1 do WS.Remove(sl[i]) end
	src.wrecs = nil
end

-- Hand a body's records over to another source (player -> corpse).
function WS.Move(from, to)
	local sl = from.wrecs
	if not sl then return end
	to.wrecs = to.wrecs or {}
	for _, r in ipairs(sl) do
		r.src = to
		to.wrecs[#to.wrecs + 1] = r
	end
	from.wrecs = nil
end

function WS.Clear()
	for i = #WS.list, 1, -1 do WS.list[i].gone = true WS.list[i] = nil end
	for _, src in ipairs(ABL.Sources.list) do src.wrecs = nil end
end

------------------------------------------------------------------------------------------
-- Linking Z-City's wounds to a record
------------------------------------------------------------------------------------------
-- A wound of Z-City's (cl_emission wound `wd`) belongs to record r in role "entry" / "exit" /
-- "artery". It bleeds from the record's visible opening and takes its character from the record.
function WS.Link(r, wd, role, mark)
	wd.rec, wd.role = r, role
	if mark then
		-- (from that opening, and from nowhere beside it: cl_emission.lua, E.WoundFrame)
		if wd.mark ~= mark then wd.tri, wd.anchorTried = nil, false end
		wd.mark = mark
	end
	r.wds[#r.wds + 1] = wd
	if role == "artery" then r.arterial = wd end
	WS.stats.linked = WS.stats.linked + 1
end

-- The record an arterial wound of Z-City's came from: the newest hit on this body that crossed an
-- artery (Z-City opens the artery inside the same damage call).
function WS.FindArterial(src, boneName)
	local sl = src.wrecs
	if not sl then return nil end
	local now = CurTime()
	for i = #sl, 1, -1 do
		local r = sl[i]
		if now - r.t0 > 4 then break end
		if Has(r, F.ARTERY) and not r.arterial then return r end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Circulation
------------------------------------------------------------------------------------------
-- Pressure left in the circulation (0..1) from the blood volume and pulse Z-City replicates.
-- Bleeding lowers the volume, and with it how far and how hard blood leaves a wound.
function WS.Pressure(src)
	if not src.alive then return 0 end
	local blood = src.blood or 5000
	local k = Clamp((blood - WC.pressureLow) / (WC.pressureFull - WC.pressureLow), WC.pressureMin, 1)
	local pulse = src.pulse or 70
	-- a failing heart: below ~40 bpm the pressure drops with the rate
	if pulse < 40 then k = k * Clamp(pulse / 40, 0.2, 1) end
	return k
end

-- Coarse physiological state from the same numbers (shown in the debug overlay).
function WS.State(src)
	if not src.alive then return "dead" end
	local blood = src.blood or 5000
	if blood < 2600 then return "critical" end
	if blood < 3300 then return "hemodynamic compromise" end
	if blood < 4000 then return "severe injury" end
	if #src.woundList > 0 then return "injured" end
	return "stable"
end

------------------------------------------------------------------------------------------
-- Blood volume ledger (per source). Where the blood that left the wounds is now, for the debug
-- overlay and for checking that nothing is created out of nowhere. The reservoir itself is
-- Z-City's (org.blood).
------------------------------------------------------------------------------------------
local LEDGER_KEYS = { "burst", "bleed", "onBody", "offBody", "airborne", "ground", "wall", "pool", "character", "particles" }
WS.LEDGER_KEYS = LEDGER_KEYS
function WS.Ledger(src, key, vol)
	if not src or vol ~= vol then return end
	local l = src.ledger
	if not l then
		l = {}
		for i = 1, #LEDGER_KEYS do l[LEDGER_KEYS[i]] = 0 end
		src.ledger = l
	end
	l[key] = (l[key] or 0) + vol
end

-- The ledger as text: what the circulation lost against what was shown leaving the wounds, and
-- where that went.
function WS.LedgerLines(src)
	local l = src.ledger
	local out = l and (l.burst + l.bleed) or 0
	local lost = src.lost or 0
	-- (a slow ooze never shows in the reservoir: Z-City makes it good as fast as it is lost)
	local balance = lost >= out and string.format("= %.0f %% of the loss, %.1f ml kept inside", lost > 0.01 and out / lost * 100 or 0, lost - out)
		or string.format("(%.1f ml of it made good by the circulation)", out - lost)
	local lines = {
		string.format("reservoir %.0f ml (lost %.0f ml)  released %.1f ml %s  |  pressure %.2f  governor %.2f  %s",
			src.blood or 0, lost, out, balance, WS.Pressure(src), src.gov or 1, WS.State(src)),
	}
	if l then
		lines[2] = string.format("left the wounds: burst %.2f + bleeding %.1f ml  ->  onto the body %.1f (%.1f dripped off again), through the air %.1f  ->  landed: ground %.1f  wall %.1f  pool %.1f  characters %.1f",
			l.burst, l.bleed, l.onBody, l.offBody, l.airborne, l.ground, l.wall, l.pool, l.character)
	end
	return lines
end

------------------------------------------------------------------------------------------
-- Conservation
-- Z-City's reservoir (org.blood, replicated about once a second) is the only blood there is. ABL
-- watches it fall and lets no more leave the wounds than it lost: each source has a bank of blood
-- that may still be shown. What the reservoir lost, less the share that stays inside the body,
-- is paid in; every drop that leaves a wound draws on it; and the bleed rate of all wounds is
-- scaled by how full the bank is (the governor). Until the first report arrives the rate Z-City
-- itself applies to a freshly hit, adrenaline-flooded body is assumed, and settled afterwards.
------------------------------------------------------------------------------------------
-- Called when the replicated reservoir value was read (cl_sources, about three times a second).
function WS.Reservoir(src, blood, now)
	local pb = src.bloodSeen
	if pb and blood < pb then
		local d = pb - blood
		src.lost = (src.lost or 0) + d
		-- (what was paid in advance, on the assumed rate, is settled against the first reports)
		local adv = src.advance or 0
		local settle = min(adv, d)
		src.advance = adv - settle
		src.owed = (src.owed or 0) + d - settle
		local dt = now - (src.lossT or now)
		if dt > 0.2 and dt < 6 then src.lossRate = d / dt end
		src.lossT = now
	end
	src.bloodSeen = blood
end

-- Once per emission step of a living source: pay into the bank, return the governor.
-- nominal: what the wounds would release ungoverned (ml/s); share: how much of the loss is external.
-- Three regimes:
--   measured  the reservoir has been seen to fall lately: what it lost is paid in, over about the
--             second that lies between two reports;
--   assumed   the body has only just begun to bleed (or to bleed much harder) and no report has
--             come since: the assumed rate, settled against the first reports;
--   unseen    the body bleeds but the reservoir does not fall (Z-City makes a slow loss good as
--             fast as it happens, or the organism does not reach this client): a small fixed
--             allowance, and no more.
-- full: what the wounds would ask for with their flow established (a wound that has just opened
-- asks for little yet: cl_emission.lua, Respond).
function WS.Govern(src, nominal, share, dt, now, full)
	-- (numbers only: one that is none would stay in the bank for good)
	if not (nominal >= 0 and nominal < 1e6) then nominal = 0 end
	if not (share > 0 and share <= 1) then share = 1 end
	if not (full and full >= nominal and full < 1e6) then full = nominal end
	if src.bank ~= nil and not (src.bank >= 0 and src.bank < 1e6) then src.bank = WC.credit end
	if nominal > 0.01 then
		-- (bleeding begins, or a new wound has raised it sharply)
		if not src.bleedT0 or full > (src.nominalSeen or 0) * 1.5 + 0.5 then src.bleedT0 = now end
	else
		src.bleedT0 = nil
	end
	src.nominalSeen = full
	local free = min(nominal * WC.govPrior, WC.govFree) * dt
	local pay
	if src.lossT and now - src.lossT < 4.5 then
		local owed = src.owed or 0
		local p = owed * min(1, dt / 0.8)
		src.owed = owed - p
		pay = max(p * share, free)
	elseif src.bleedT0 and now - src.bleedT0 < 3 and not (src.lossT and src.lossT > src.bleedT0) then
		pay = max(nominal * WC.govStart * dt, free)
		src.advance = min((src.advance or 0) + pay / max(share, 0.25), 60)
	else
		pay = free
	end
	local bank = min((src.bank or WC.credit) + pay, WC.credit + nominal * 2)
	src.bank = bank
	-- (the governor never holds the flow above what is being paid in: when nothing but the small
	-- allowance comes in, it closes further than govMin)
	local floor = min(WC.govMin, pay / max(dt, 1e-4) / max(nominal, 0.01))
	local gov = bank / (nominal * 1.5 + 5)
	-- The bank alone would let a heavy wound spend the whole credit in its first second and hold
	-- it to half that rate afterwards: a surge, then a drop. So what goes out is also bounded by
	-- what comes in: the share of the asked rate that is being paid in (evened out over a second,
	-- reports come in steps), plus the bank spread over creditTime. A small wound never meets
	-- this bound while its credit lasts; a heavy one comes up to its level from below.
	if nominal > 0.01 and dt > 0 then
		local ratio = min(pay / dt / nominal, 4)
		local ps = src.payShare
		if not ps or src.payFor ~= src.bleedT0 then
			src.payFor = src.bleedT0
			-- (a wound that asks for little yet is paid the small allowance in full; that is not
			-- the share it will be paid once it asks for its rate)
			ps = min(ratio, WC.govStart)
		end
		ps = ps + (ratio - ps) * min(1, dt / WC.govTau)
		src.payShare = ps
		-- (the credit by the rate the wounds will ask for once established: else a wound that has
		-- only just opened, asking for little yet, would be let through in full for that moment)
		local byRate = ps + bank / (WC.creditTime * max(full, nominal))
		if byRate < gov then gov = byRate end
	end
	gov = Clamp(gov, floor, 1)
	src.gov = gov
	return gov
end

function WS.Withdraw(src, vol)
	if not (vol > 0 and vol < 1e6) then return end
	src.bank = max((src.bank or WC.credit) - vol, 0)
end

------------------------------------------------------------------------------------------
-- Surface state over time
-- A wound's surface is wet while it bleeds. Once the flow through it has fallen away the blood on
-- it thickens (clot), then dries from its thin edge inward; a wound that starts bleeding again
-- (movement, pressure) is wet again. All continuous: marks read r.wet / r.clot / r.dry / r.bruise.
------------------------------------------------------------------------------------------
local nextThink = 0
function WS.Think()
	local now = CurTime()
	if now < nextThink then return end
	local dt = 0.25
	nextThink = now + dt
	local list = WS.list
	if #list == 0 then return end
	local dryScale = C.sv.drying:GetFloat()
	local clotT, dryT, bruiseT = WC.clotTime * dryScale, WC.dryTime * dryScale, WC.bruiseTime
	for i = 1, #list do
		local r = list[i]
		r.age = now - r.t0
		-- flow through the record's openings right now (ml/s)
		local flow = 0
		local wds = r.wds
		for k = #wds, 1, -1 do
			local wd = wds[k]
			if wd.src == nil or wd.sev <= 0 or wd.removed then
				table.remove(wds, k)
			else
				flow = flow + (wd.flow or 0)
			end
		end
		r.flow = flow
		-- (a wound told of after the fact, once: where nothing flows through it any more its
		-- surface is as set and as dry as a wound of its age that has been still; one that bleeds
		-- is wet, as it is)
		if r.settle and now >= r.settle then
			r.settle = nil
			if flow < 0.02 then
				local t = max(r.age - 3, 0)
				local step = max(dt, t / 300)
				local wet, clot, dry = 1, 0, 0
				for _ = 1, math.floor(t / step) do
					wet = max(0, wet - step / (clotT * 0.8))
					local still = 1 - wet
					if still > 0.15 then
						clot = min(1, clot + step / clotT * still)
						if clot > 0.5 then dry = min(1, dry + step / dryT * still) end
					end
				end
				r.wet, r.clot, r.dry = wet, clot, dry
			end
		end
		-- wetness follows the flow; with no flow it decays as the blood on the wound sets
		local target = Clamp(flow / 0.6, 0, 1)
		if r.age < 3 then target = 1 end
		if target > r.wet then
			r.wet = min(1, r.wet + dt / 1.5)
			-- fresh blood over a clot: it softens
			r.clot = max(0, r.clot - dt / 20 * target)
			r.dry = max(0, r.dry - dt / 30 * target)
		else
			r.wet = max(target, r.wet - dt / (clotT * 0.8))
		end
		local still = 1 - r.wet
		if still > 0.15 then
			r.clot = min(1, r.clot + dt / clotT * still)
			if r.clot > 0.5 then r.dry = min(1, r.dry + dt / dryT * still) end
		end
		-- the bruise around a wound comes up over the first minute (alive only: it needs circulation)
		if r.bruise < 1 and (r.src == nil or r.src.alive) then r.bruise = min(1, r.bruise + dt / bruiseT) end
		-- continuous stage 0..6: extremely fresh, active, slowing, clotting, partially dried, dry, old
		r.stage = (r.age < 2 and r.age / 2) or (1 + (1 - r.wet) + r.clot + r.dry * 2 + Clamp((r.age - 600) / 600, 0, 1))
	end
end

------------------------------------------------------------------------------------------
-- Text (debug overlay, harness log)
------------------------------------------------------------------------------------------

function WS.Vascular(r)
	if r.arterial and r.arterial.src then return "arterial" end
	if #r.wds == 0 then return "none linked" end
	if r.graze or (r.flow or 0) < 0.25 then return "capillary" end
	return "venous"
end

function WS.Describe(r)
	local N = ABL.Net
	return {
		string.format("WOUND %d  %s  %s", r.id, r.region, r.graze and "graze" or WD.PenNames[r.pen] or "?"),
		string.format("projectile: %s energy, %.1f mm, velocity class %d, %s range", WD.EnergyNames[r.energy] or "?", r.caliberMM, r.velocity, WD.RangeNames[r.range] or "?"),
		string.format("crossed: %s", WD.FlagText(r.flags)),
		string.format("cavity %.2f  soft tissue %.2f  internal %.2f (%.0f %% reaches the outside)  track %s", r.cavity, r.softDamage, r.internal, r.external * 100, r.trackLen and string.format("%.1f u", r.trackLen) or "?"),
		string.format("entry %s (opening %.2f u)  exit %s", r.entryMark and "marked" or "no mark", r.opening, r.exitMark and string.format("marked (%.2f u)", r.exitOpening) or (r.pen == WD.PEN_THROUGH and "not found" or "none")),
		string.format("bleeding: %s  %.2f ml/s  released %.1f ml  linked wounds %d", WS.Vascular(r), r.flow or 0, r.released, #r.wds),
		string.format("age %.0f s  stage %.1f  wet %.2f  clot %.2f  dry %.2f  bruise %.2f", r.age, r.stage or 0, r.wet, r.clot, r.dry, r.bruise),
	}
end
