-- Wound emission. Every wound is an independent emitter with its own seeded RNG, slow random
-- flow variation (Ornstein-Uhlenbeck), heartbeat phase with beat-to-beat jitter, and a profile
-- chosen from the estimated flow rate (MINOR .. HIGH-OUTPUT) or PULSED for arteries.
-- Output is split into: seep (feeds the body-surface bead), gush (low speed pour), jet (pulsed
-- arterial stream) and occasional spurts. Initial state always comes from the wound's real
-- world frame, surface normal and the body's velocity at that point.

ABL.NoJIT()
ABL.Emission = ABL.Emission or {}
local E = ABL.Emission
local C, Z, BM = ABL.Config, ABL.ZC, ABL.BodyMesh
local sqrt, exp, max, min, abs, cos, sin, pi = math.sqrt, math.exp, math.max, math.min, math.abs, math.cos, math.sin, math.pi
local Clamp = math.Clamp
local WD = ABL.Wound
local TR = ABL.Trace

------------------------------------------------------------------------------------------
-- Wound records
------------------------------------------------------------------------------------------
-- Which hit a wound of Z-City's came from. Its record lies where the hit said it would (the same
-- bone, the same coordinates give or take the unit Z-City moves it along the surface normal). The
-- wound then bleeds from that hit's visible opening and takes its character from the wound record.
-- Hit and wound arrive in either order (the hit is sent a tick after the damage, Z-City's venous
-- wounds a tenth of a second after it, its arterial wounds and a corpse's whole list at once), so
-- this runs both when a wound appears and when a hit does.
local function LinkWound(src, wd, now)
	local WS = ABL.Wounds
	if wd.arterial then
		-- an artery Z-City opened in a hit: it bleeds out through that hit's wound
		local r = WS.FindArterial(src)
		if not r then return false end
		WS.Link(r, wd, "artery", r.entryMark)
		TR.Event(src, wd, "bleeds through hit " .. tostring(r.id), r.entryMark and "an artery: from that hit's entry" or "an artery: that hit has no mark on the skin")
		-- cut through or only opened: a severed artery pours and sprays, an opened one sends a
		-- thin coherent jet
		wd.transect = wd.rng:Next() < 0.25 + 0.55 * r.cavity
		return true
	end
	local ph = src.pendingHits
	for i = #ph, 1, -1 do
		if now - ph[i].t > 4 then table.remove(ph, i) end
	end
	-- (the wound's place as Z-City has it: the place it is shown at may have been taken onto its
	-- bone, WoundFrame)
	local zx, zy, zz = wd.zx or wd.lx, wd.zy or wd.ly, wd.zz or wd.lz
	local bi, bd = nil, C.Wound.linkDist ^ 2
	for i = 1, #ph do
		local h = ph[i]
		if h.boneName == wd.boneName then
			local dx, dy, dz = h.lx - zx, h.ly - zy, h.lz - zz
			local d = dx * dx + dy * dy + dz * dz
			if d < bd then bi, bd = i, d end
		end
	end
	local across
	if not bi then
		-- A wound whose place is not on the bone it names. Z-City books a wound whose bone it does
		-- not know on a bone drawn at random, at the offset of the true place from that bone; the hit
		-- itself is told with the bone nearest to where it struck (server/sv_main.lua). So the two
		-- name different bones and the same place in the world: the wound is that hit's if, as the
		-- body stands now, it lies at the hit's place. (Only shortly after the hit: the body moves,
		-- and a place that hangs on the wrong bone moves away from the wound.)
		local body, pose = src.body, src.pose
		local bone = IsValid(body) and body:LookupBone(wd.boneName) or nil
		if bone and now - wd.born < 3 and BM.OffBone(body, bone, zx, zy, zz) > C.Wound.offBone then
			local b = pose:Bone(bone)
			if b then
				local wx = b[1] * zx + b[2] * zy + b[3] * zz + b[4]
				local wy = b[5] * zx + b[6] * zy + b[7] * zz + b[8]
				local wz = b[9] * zx + b[10] * zy + b[11] * zz + b[12]
				bd = (C.Wound.linkDist + 2) ^ 2
				for i = 1, #ph do
					local h = ph[i]
					local hb = h.boneName ~= wd.boneName and now - h.t < 3 and body:LookupBone(h.boneName) or nil
					local e = hb and pose:Bone(hb)
					if e then
						local dx = e[1] * h.lx + e[2] * h.ly + e[3] * h.lz + e[4] - wx
						local dy = e[5] * h.lx + e[6] * h.ly + e[7] * h.lz + e[8] - wy
						local dz = e[9] * h.lx + e[10] * h.ly + e[11] * h.lz + e[12] - wz
						local d = dx * dx + dy * dy + dz * dz
						if d < bd then bi, bd, across = i, d, true end
					end
				end
			end
		end
	end
	if not bi then return false end
	local h = table.remove(ph, bi)
	if across then
		TR.Event(src, wd, "is the wound of a hit on another bone", string.format("Z-City has it on %s at a place that is not on that part; the hit struck %s there", TR.Short(wd.boneName), TR.Short(h.boneName)))
	end
	local r = h.rec
	-- (it bleeds from that opening from now on, wherever on the skin it was taken to lie before: a
	-- wound that was there before its hit was told has a place of its own, near the opening and
	-- not in it)
	if h.mark and wd.mark ~= h.mark then wd.tri, wd.anchorTried = nil, false end
	wd.mark = h.mark
	if r and not r.gone then
		WS.Link(r, wd, h.role, h.mark)
		TR.Event(src, wd, "bleeds through hit " .. tostring(r.id), h.mark and ("from its " .. tostring(h.role) .. " opening") or "that hit has no mark on the skin")
		-- how long the wound pours before it settles to its steady rate: with the damage around
		-- the track, not at all for a graze
		local k = r.graze and 0 or Clamp(0.3 + 1.3 * r.cavity + (r.boneHit and 0.25 or 0), 0.3, 1.5)
		-- (not a wound this client is told of after the fact: that one poured when it was made)
		if not r.replayed then wd.fresh = now + C.FRESH_WOUND_TIME * k end
	else
		wd.fresh = now + C.FRESH_WOUND_TIME * Clamp(h.energy or 1, 0.4, 1.5)
	end
	return true
end

-- A hit has arrived (or a body's wounds and hits have come together in one source): wounds of
-- Z-City's that were there before it and belong to it. old: however long they have been there
-- (the hit is one this client is told of after the fact: its wounds may be minutes old).
local function LinkWaiting(src, now, old)
	local wl = src.woundList
	for i = 1, #wl do
		local wd = wl[i]
		if not wd.rec and (old or now - wd.born < 5) then LinkWound(src, wd, now) end
	end
end
E.LinkWaiting = LinkWaiting

function E.NewWound(src, id, arterial, w)
	local p = w[2]
	local wd = {
		id = id, src = src, arterial = arterial, boneName = w[4],
		-- (l: its place in the bone's space as it is shown; z: as Z-City has it)
		lx = p.x, ly = p.y, lz = p.z,
		zx = p.x, zy = p.y, zz = p.z,
		ldx = 1, ldy = 0, ldz = 0,
		sev = tonumber(w[1]) or 0, born = CurTime(), seen = CurTime(),
		noise = 0, phase = 0, beatLen = 1, beatAmp = 1,
		jetAcc = 0, gushAcc = 0, dripAcc = 0, deposit = 0,
		bone = nil, boneFor = -1, tri = nil, u = 0, v = 0, anchorTried = false,
		wx = nil, wy = 0, wz = 0, vx = 0, vy = 0, vz = 0,
		fresh = 0, wobP = 0, wobY = 0,
	}
	wd.rng = ABL.RNG(src.seed + ABL.Hash(id))
	wd.phase = wd.rng:Next()
	wd.dripTarget = wd.rng:Range(0.035, 0.07)
	LinkWound(src, wd, CurTime())
	return wd
end

-- World position, outward normal and smoothed velocity of a wound this frame.
-- Returns ok, x, y, z, nx, ny, nz
function E.WoundFrame(src, wd)
	local body = src.body
	if not IsValid(body) then return false end
	if wd.boneFor ~= src.bodyIdx then
		wd.bone = body:LookupBone(wd.boneName)
		wd.boneFor = src.bodyIdx
		wd.tri = nil
		wd.anchorTried = false
		wd.wx = nil
		-- Is its place on the part it names? One that is not (BM.OffBone: Z-City's wounds on a
		-- bone drawn at random) would let its blood out of the air beside the body, at a place
		-- that swings about as the body moves. It is taken to the nearest place on that part:
		-- a wound bleeds from the body it is on. (One that turns out to be the wound of a hit on
		-- another bone bleeds from that hit's opening: LinkWound.)
		if wd.bone and wd.zx then
			local off, cx, cy, cz = BM.OffBone(body, wd.bone, wd.zx, wd.zy, wd.zz)
			if off > C.Wound.offBone then
				wd.lx, wd.ly, wd.lz = cx, cy, cz
				if not wd.offSaid then
					wd.offSaid = true
					TR.Event(src, wd, "place not valid", string.format("Z-City has it %.0f units off the part it names: taken to the nearest place on that part", off))
				end
			else
				wd.lx, wd.ly, wd.lz = wd.zx, wd.zy, wd.zz
			end
		end
	end
	local bone = wd.bone
	if not bone then return false end
	local pose = src.pose
	-- a wound with a mark on the skin bleeds from exactly that opening
	local mk = wd.mark
	if mk and not wd.tri and src.mesh and mk.m == src.mesh then
		wd.tri, wd.u, wd.v = mk.tri, mk.u, mk.v
		wd.anchorTried = true
		TR.Event(src, wd, "held at its mark's opening")
	end
	if src.mesh and wd.tri then
		if wd.tri <= src.mesh.nt then
			local x, y, z, nx, ny, nz = pose:Point(wd.tri, wd.u, wd.v)
			return true, x, y, z, nx, ny, nz
		end
		-- (an anchor from another surface model: it is looked for again)
		wd.tri, wd.anchorTried = nil, false
	end
	local b = pose:Bone(bone)
	if not b then return false end
	local x = b[1] * wd.lx + b[2] * wd.ly + b[3] * wd.lz + b[4]
	local y = b[5] * wd.lx + b[6] * wd.ly + b[7] * wd.lz + b[8]
	local z = b[9] * wd.lx + b[10] * wd.ly + b[11] * wd.lz + b[12]
	-- outward direction: radial from the bone axis
	local fx, fy, fz = ABL.Norm(b[1], b[5], b[9])
	local rx, ry, rz = x - b[4], y - b[8], z - b[12]
	local along = rx * fx + ry * fy + rz * fz
	local nx, ny, nz = ABL.Norm(rx - fx * along, ry - fy * along, rz - fz * along)
	if nx == 0 and ny == 0 and nz == 0 then nx, ny, nz = 0, 0, 1 end
	if src.mesh and not wd.anchorTried then
		wd.anchorTried = true
		-- the outermost layer at the wound (jacket over shirt, outside of a collar), else the
		-- closest surface
		local tri, u, v = BM.AnchorOuter(pose, bone, x, y, z, nx, ny, nz, 5)
		local how = tri and "the outermost surface there" or nil
		if not tri then
			tri, u, v = BM.Anchor(pose, bone, x, y, z, 10)
			how = tri and "the closest surface"
		end
		if not tri then
			-- (nothing near: the nearest skin of its own bone, further off)
			tri, u, v = BM.Anchor(pose, bone, x, y, z, 24)
			how = tri and "the nearest skin of its bone, none being near"
		end
		if tri then
			wd.tri, wd.u, wd.v = tri, u, v
			local px, py, pz, pnx, pny, pnz = pose:Point(tri, u, v)
			TR.Event(src, wd, "held on the skin", string.format("%s, %.1f units from its place", how, sqrt((px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2)))
			return true, px, py, pz, pnx, pny, pnz
		end
		TR.Event(src, wd, "NOT held on the skin", "no skin of this body within 24 units of its place: it bleeds from that place in its bone's space")
	end
	return true, x, y, z, nx, ny, nz
end

local function UpdateVelocity(wd, x, y, z, dt)
	if not wd.wx then wd.wx, wd.wy, wd.wz = x, y, z return end
	local vx, vy, vz = (x - wd.wx) / dt, (y - wd.wy) / dt, (z - wd.wz) / dt
	wd.wx, wd.wy, wd.wz = x, y, z
	if vx * vx + vy * vy + vz * vz > 3000 * 3000 then return end -- teleport / respawn
	local k = min(1, dt / 0.07)
	wd.vx = wd.vx + (vx - wd.vx) * k
	wd.vy = wd.vy + (vy - wd.vy) * k
	wd.vz = wd.vz + (vz - wd.vz) * k
end

------------------------------------------------------------------------------------------
-- Flow model
------------------------------------------------------------------------------------------
-- Heartbeat waveform: systolic wave + dicrotic bump, mean-normalised to 1. The wave takes about a
-- sixth of the beat to rise and as long to fall: a pulse that swells, not one that snaps on.
local function BeatShape(ph)
	local a = (ph - 0.2) / 0.1
	local b = (ph - 0.48) / 0.12
	local c = (ph - 1.2) / 0.1 -- (the next beat's wave already rising at the end of this one)
	return (exp(-a * a) + 0.35 * exp(-b * b) + exp(-c * c)) / 0.2517
end
E.BeatShape = BeatShape

-- The response of a wound as a source: 0 when it opens, 1 once its flow is established, and back
-- to 0 when it has closed. It follows its target through two equal lags in a row (it leaves 0 with
-- no slope, rises, and comes in to 1 without a step), exactly for any length of step, so that a
-- wound builds up the same at every frame rate. How long that takes depends on the source: an
-- artery under pressure is there soonest, a small wound wells up slowly. These are times to look
-- right, not medical measurements (C.Wound.onset).
local function Respond(wd, dt)
	local target = wd.closing and 0 or 1
	local r, a = wd.resp or 0, wd.respA or 0
	local tau
	if target < r then
		tau = C.Wound.offset
	else
		local on = C.Wound.onset
		tau = wd.arterial and on.arterial or (wd.sev < on.smallSev and on.small or on.venous)
	end
	local x = dt / tau
	local e = exp(-x)
	wd.resp = target + (r - target) * e + (a - target) * x * e
	wd.respA = target + (a - target) * e
end

-- Returns the wound's rate as governed, the rate it asks for, and the governed rate it would have
-- with its flow established (ml/s).
function E.Rate(src, wd)
	local pulse = src.pulse or 70
	local base
	if wd.arterial then
		base = C.ARTERIAL_K * wd.sev * max(pulse, 20)
	else
		base = C.VENOUS_K * wd.sev * max(pulse, 20) / 70
	end
	if not src.alive then
		-- the heart stopped: arterial pressure is gone, gravity keeps draining open wounds
		local t = CurTime() - (src.deathTime or CurTime())
		local passive = C.VENOUS_K * wd.sev * (wd.arterial and 0.6 or 1)
		base = passive * C.POSTMORTEM_OOZE * exp(-t / C.POSTMORTEM_DECAY)
	end
	local now = CurTime()
	if wd.fresh > now then
		local k = (wd.fresh - now) / C.FRESH_WOUND_TIME
		base = base * (1 + C.Wound.surge * min(k, 1))
	end
	-- the wound it bleeds through: how much of the blood lost there reaches the outside
	local r = wd.rec
	if r then
		if r.graze then
			-- skin and the fat under it: it oozes, whatever volume the hit was booked with
			base = base * C.Wound.grazeBleed
		elseif wd.arterial then
			-- (an artery empties through the track; a track with one small opening holds some back)
			if r.pen == WD.PEN_RETAINED then base = base * 0.85 end
		else
			base = base * r.external
			if r.pen == WD.PEN_RETAINED and wd.role == "entry" then
				-- a retained projectile leaves one small opening: the track fills before blood
				-- finds its way out at the full rate
				base = base * (0.3 + 0.7 * Clamp((now - r.t0) / C.Wound.internalDelay, 0, 1))
			end
		end
	end
	-- (never a number that is none: a wound value Z-City sends, a pulse)
	if not (base >= 0 and base < 1e6) then base = 0 end
	local full = base * C.sv.volume:GetFloat()
	-- the source's response (Respond, above): a wound that has only just opened, or is closing
	local resp = wd.resp or 0
	if not (resp >= 0 and resp <= 1) then resp = resp ~= resp and 0 or Clamp(resp, 0, 1) end
	base = full * resp
	-- conservation: no more leaves the wounds than the circulation loses (ABL.Wounds.Govern).
	-- Second value: what the wound asks for before that (the governor works from it).
	if src.alive then
		local gov = src.gov or 1
		-- (what it gave with the heart beating: see below)
		wd.liveRate = full * gov
		return base * gov, base, full * gov, full
	end
	-- The pressure does not go in the frame the heart stops: what the wound gave while it beat
	-- falls away over a moment (C.Wound.deathFall) onto what gravity alone drains.
	local live = wd.liveRate
	if live and live > full then
		local x = (now - (src.deathTime or now)) / C.Wound.deathFall
		if x >= 0 and x < 12 then
			full = full + (live - full) * exp(-x)
			base = full * resp
		end
	end
	return base, base, full, full
end
E.Respond = Respond

-- The share of the reservoir's loss through this wound that is shown (E.Rate applies the same).
local function ExternalShare(wd)
	local r = wd.rec
	if not r then return 1 end
	if r.graze then return C.Wound.grazeBleed end
	if wd.arterial then return r.pen == WD.PEN_RETAINED and 0.85 or 1 end
	return r.external
end

-- How the blood leaves: by vessel class and flow.
--   capillary / superficial (a graze, or skin and fat only from a weak projectile): oozing beads
--     with clot cycles (MINOR, MODERATE at most);
--   venous: a steady flow, pouring when large (MODERATE .. HIGH-OUTPUT by rate);
--   arterial: pressure-driven and pulsed while the heart beats (PULSED).
function E.Profile(src, wd, rate)
	if wd.arterial and src.alive then return C.Profiles.pulsed end
	local r = wd.rec
	if r and (r.graze or (r.pen == WD.PEN_SOFT and r.energy <= 2 and not r.boneHit)) then
		return rate < C.ProfileRate.minor and C.Profiles.minor or C.Profiles.moderate
	end
	-- A fresh wound pours only where there is an opening for it: out of the exit of a wound with a
	-- wide track, or anywhere the flow itself is high. No gunshot wound gushes just for being new.
	if wd.fresh > CurTime() and rate > C.ProfileRate.moderate and (not r or (wd.role == "exit" and r.cavity > 0.5)) then return C.Profiles.high end
	if rate < C.ProfileRate.minor then return C.Profiles.minor end
	if rate < C.ProfileRate.moderate then return C.Profiles.moderate end
	if rate < C.ProfileRate.severe then return C.Profiles.severe end
	return C.Profiles.high
end

------------------------------------------------------------------------------------------
-- Per step
------------------------------------------------------------------------------------------
local Drops -- resolved lazily (loaded after this file)

-- random direction within a cone around (dx,dy,dz)
local function Cone(rng, dx, dy, dz, spread)
	local px, py, pz = ABL.Perp(dx, dy, dz)
	local qx, qy, qz = dy * pz - dz * py, dz * px - dx * pz, dx * py - dy * px
	local a = rng:Next() * 2 * pi
	local r = spread * sqrt(rng:Next())
	local ca, sa = cos(a) * r, sin(a) * r
	return ABL.Norm(dx + px * ca + qx * sa, dy + py * ca + qy * sa, dz + pz * ca + qz * sa)
end
E.Cone = Cone

-- Height of the character's heart along "up" (against gravity), for the posture term.
local function HeartHeight(src)
	local body = src.body
	if src.heartFor ~= src.bodyIdx then
		src.heartFor = src.bodyIdx
		src.heartBone = body:LookupBone(C.HEART_BONE) or body:LookupBone("ValveBiped.Bip01_Spine1")
	end
	local hb = src.heartBone
	if not hb then return nil end
	local b = src.pose:Bone(hb)
	if not b then return nil end
	local gx, gy, gz, gmag = ABL.Gravity()
	return -(b[4] * gx + b[8] * gy + b[12] * gz) / gmag
end

-- Returns the wound's rate as governed, and the rate it asked for (ml/s).
local function EmitWound(src, wd, dt, stepIdx, bodyflow, heartH)
	local press = src.press or 1
	local ok, x, y, z, nx, ny, nz = E.WoundFrame(src, wd)
	if not ok then return 0, 0 end
	-- the body pose (and so the wound position) changes once per rendered frame: the velocity is
	-- measured frame to frame, over the time of all ticks in between
	wd.velDt = (wd.velDt or 0) + dt
	local frame = FrameNumber()
	if wd.velFrame ~= frame then
		wd.velFrame = frame
		UpdateVelocity(wd, x, y, z, wd.velDt)
		wd.velDt = 0
	end
	local now = CurTime()
	if (wd.hidT or 0) < now then
		wd.hidT = now + 0.5
		local missing = Z.LimbMissing(src.body, Z.GetOrganism(src.body, src.owner), wd.boneName)
		local hidden = missing or (wd.bone and Z.BoneHidden(src.body, wd.bone)) or false
		if hidden ~= (wd.hidden or false) then
			TR.Event(src, wd, hidden and "hidden: lets nothing out" or "shown again", hidden and (missing and "the part it is on is gone (amputated, or the head destroyed)" or "its bone is scaled away") or nil)
		end
		wd.hidden = hidden
	end
	if wd.hidden then return 0, 0 end
	-- bone matrices read in Think are one frame old: predict the wound forward by one frame (an
	-- ordinary frame: after a hitch of seconds the body is not that far ahead of itself)
	local lag = min(FrameTime(), 0.05)
	x, y, z = x + wd.vx * lag, y + wd.vy * lag, z + wd.vz * lag

	local rng = wd.rng
	Respond(wd, dt)
	local rate, asked, full, askedFull = E.Rate(src, wd)
	local p = E.Profile(src, wd, rate)
	wd.profile = p
	-- How the blood leaves (seeping, pouring, in a jet) changes with the profile, and the profile
	-- with the rate: the shares follow it over a moment instead of switching.
	local ks = min(1, dt / C.Wound.shareTau)
	local kGush = (wd.kGush or 0) + (p.gush - (wd.kGush or 0)) * ks
	local kJet = (wd.kJet or 0) + (p.jet - (wd.kJet or 0)) * ks
	wd.kGush, wd.kJet = kGush, kJet
	-- what a jet or a pour leaves the wound with builds up with the source (and falls with it)
	local resp = wd.resp or 0
	local speedK = 0.4 + 0.6 * resp

	-- slow flow variation (OU process), multiplicative
	local tau = p.noiseTau
	wd.noise = wd.noise - wd.noise / tau * dt + p.noiseSigma * sqrt(2 * dt / tau) * rng:Normal()
	local mult = math.Clamp(1 + wd.noise, 0.15, 2.2)

	-- heartbeat
	local beatMul, beatShape = 1, 1
	if src.alive and (src.pulse or 0) > 5 then
		wd.phase = wd.phase + dt * (src.pulse / 60) / wd.beatLen
		if wd.phase >= 1 then
			wd.phase = wd.phase - 1
			wd.beatLen = 1 + rng:Normal() * 0.06        -- beat-to-beat interval jitter
			wd.beatAmp = math.Clamp(1 + rng:Normal() * 0.15, 0.6, 1.4)
		end
		beatShape = BeatShape(wd.phase) * wd.beatAmp
		-- (the pulse shows less in the flow as the pressure falls)
		local pb = p.beat * (0.3 + 0.7 * press)
		beatMul = (1 - pb) + pb * beatShape
	end

	-- posture: a wound below the heart bleeds harder, one held above it less (also post mortem:
	-- gravity drains the lowest wounds)
	local hydro = 1
	if heartH then
		local gx, gy, gz, gmag = ABL.Gravity()
		local dh = heartH + (x * gx + y * gy + z * gz) / gmag
		hydro = math.Clamp(1 + dh * (wd.arterial and C.HYDRO_ARTERIAL or C.HYDRO_VENOUS), C.HYDRO_MIN, C.HYDRO_MAX)
	end
	wd.hydro = hydro

	-- movement: the muscle pump and exertion push more blood out of venous wounds
	local pump = 1
	if src.alive and not wd.arterial then
		local ws = sqrt(wd.vx * wd.vx + wd.vy * wd.vy + wd.vz * wd.vz)
		pump = 1 + min(ws * C.MOVE_PUMP, C.MOVE_PUMP_MAX)
	end

	-- acceleration of the wound's bone: tears fresh clots open, squeezes out spurts
	local accel = 0
	if wd.bone and (p.spurtRate > 0 or p.clot) then
		local _, _, _, ax, ay, az = src.pose:BoneVel(wd.bone)
		accel = sqrt(ax * ax + ay * ay + az * az)
	end

	-- small wounds bleed irregularly: a clot forms, throttles the flow, and gives way again
	local clotMul = 1
	local cl = p.clot
	if cl and src.alive then
		if not wd.clotT then wd.clotT = rng:Range(cl.open[1], cl.open[2]) wd.clotK = 1 end
		wd.clotT = wd.clotT - dt
		if wd.clotted and accel > 1800 then wd.clotT = 0 end
		if wd.clotT <= 0 then
			wd.clotted = not wd.clotted
			if wd.clotted then
				wd.clotT = rng:Range(cl.shut[1], cl.shut[2])
			else
				wd.clotT = rng:Range(cl.open[1], cl.open[2])
				wd.surge = now + 0.7
			end
		end
		local target = wd.clotted and cl.level or 1
		wd.clotK = wd.clotK + (target - wd.clotK) * min(1, dt / (wd.clotted and 1.2 or 0.25))
		clotMul = wd.clotK * ((wd.surge or 0) > now and 1.9 or 1)
	else
		wd.clotK, wd.clotted = 1, false
	end

	local shape = mult * beatMul * hydro * pump * clotMul
	local flow = rate * shape
	local vol = flow * dt
	-- (what it would give with its flow established: the flow core asks, cl_flowcore.lua)
	wd.flowFull = full * shape
	-- (nothing to release, or no number: nothing is booked and nothing leaves the wound)
	if not (vol > 0 and vol < 1e4) then
		wd.flow = 0
		return rate, asked, askedFull
	end
	wd.flow = flow
	local rec = wd.rec
	if rec then rec.released = rec.released + vol end
	-- (what has come out through its visible opening: the blood painted round that grows with it,
	-- and the blood standing in it rises with the flow: cl_woundfx.lua)
	local mk = wd.mark
	if mk then mk.fed = (mk.fed or 0) + vol end
	ABL.Wounds.Ledger(src, "bleed", vol)
	ABL.Wounds.Withdraw(src, vol)

	-- (where it goes is by the body's distance alone, cl_lod.lua: src.flowLod)
	local lod = src.flowLod or src.lod
	if lod <= C.LOD_LOW then
		-- far away: no per-drop simulation. Blood still accumulates where the body is.
		wd.deposit = wd.deposit + vol
		if lod >= C.LOD_LOW and rng:Next() < dt * min(flow, 8) * 0.6 then
			Drops.Particle(x + nx * 0.5, y + ny * 0.5, z + nz * 0.5, wd.vx + nx * 8, wd.vy + ny * 8, wd.vz + nz * 8, 0.06)
		end
		return rate, asked, askedFull
	end

	local wvx, wvy, wvz = wd.vx, wd.vy, wd.vz
	local ox, oy, oz = x + nx * 0.35, y + ny * 0.35, z + nz * 0.35

	-- clothes around the wound soak up blood: a skinned studio decal that grows in steps (a wound
	-- with a mark has its own soaked cloth around the hole, cl_woundfx.lua)
	wd.soakAcc = (wd.soakAcc or 0) + vol
	-- (not where the body's blood is a film or a stream: that soaks the cloth itself, cl_film.lua)
	if not wd.mark and wd.soakAcc >= (wd.soakNext or 0.5) and (wd.soakN or 0) < 5 and lod >= C.LOD_HIGH and not ABL.FlowCore.Uses(src) and not ABL.Film.Uses(src) then
		wd.soakN = (wd.soakN or 0) + 1
		wd.soakNext = (wd.soakNext or 0.5) * 2.5
		ABL.Stains.BodySoak(src.body, x, y, z, nx, ny, nz, 1.1 + wd.soakN * 0.6)
	end

	-- seep: onto the body surface (or direct drips when body flow is unavailable)
	local seep = vol * max(0, 1 - kGush - kJet)
	if seep > 0 then
		if bodyflow and wd.tri then
			ABL.Flow.Feed(src, wd, seep)
		else
			wd.dripAcc = wd.dripAcc + seep
		end
	end
	-- direct drips from the wound (no surface model yet, or the body-flow budget is full)
	if wd.dripAcc >= wd.dripTarget then
		if wd.dripAcc > 1.5 then wd.dripAcc = 1.5 end
		local dv = max(wd.dripTarget, wd.dripAcc * 0.2)
		wd.dripAcc = wd.dripAcc - dv
		wd.dripTarget = rng:Range(0.03, 0.075)
		Drops.Spawn(ox, oy, oz, wvx + nx * 4 + rng:Range(-2, 2), wvy + ny * 4 + rng:Range(-2, 2), wvz + nz * 4, dv, src, 0, 0)
	end

	-- what the wound's opening does not hold and the stream below it does not carry away
	-- (cl_flowcore.lua FC.Feed) pours off the wound: one stream of linked drops, not a spray of them
	if (wd.pourAcc or 0) > 0.04 and now >= (wd.pourT or 0) then
		wd.pourT = now + 0.05
		local dv = wd.pourAcc
		wd.pourAcc = 0
		local d = Drops.Spawn(ox, oy, oz, wvx + nx * 5 + rng:Range(-0.6, 0.6), wvy + ny * 5 + rng:Range(-0.6, 0.6), wvz + nz * 5, dv, src, 0, 0)
		Drops.Link(d, wd, "pour")
	end

	-- gush: low-speed pour from large wounds. Consecutive gush drops are linked, so a steady pour
	-- is drawn as one continuous stream (cl_droplets)
	wd.gushT = (wd.gushT or 0) + dt
	-- (a severed artery pours part of its output as a wide pulsing gush instead of one jet)
	local jetK = (wd.transect and kJet > 0) and 0.55 or 1
	local gushShare = kGush + kJet * (1 - jetK)
	if gushShare > 1e-4 then
		wd.gushAcc = wd.gushAcc + vol * gushShare
		if wd.gushAcc > 0.02 and wd.gushT >= 1 / 30 then
			wd.gushT = 0
			local dv = wd.gushAcc
			wd.gushAcc = 0
			-- a slowly wandering pour direction, not a random spray
			wd.gushA = (wd.gushA or rng:Next() * 6.28) + rng:Range(-0.5, 0.5)
			local px, py, pz = ABL.Perp(nx, ny, nz)
			local qx, qy, qz = ny * pz - nz * py, nz * px - nx * pz, nx * py - ny * px
			local ca, sa = cos(wd.gushA) * 0.3, sin(wd.gushA) * 0.3
			local dx, dy, dz = ABL.Norm(nx + px * ca + qx * sa, ny + py * ca + qy * sa, nz + pz * ca + qz * sa)
			-- the pour's speed drifts (a stream of drops at unrelated speeds would be pulled apart)
			local gk = (wd.gushK or 0.78) + (rng:Normal() * 0.04 - ((wd.gushK or 0.78) - 0.78) * 0.07)
			gk = gk < 0.55 and 0.55 or (gk > 1 and 1 or gk)
			wd.gushK = gk
			-- (the speed of the profile it is coming from or going to, when this one has no pour)
			local gs = p.gushSpeed or wd.gushSp or 30
			wd.gushSp = gs
			local sp = gs * gk * (0.5 + 0.5 * press) * speedK
			local d = Drops.Spawn(ox, oy, oz, wvx + dx * sp, wvy + dy * sp, wvz + dz * sp, dv, src, 0, 0)
			Drops.Link(d, wd, "gush")
		end
	end

	-- jet: pulsed arterial stream, coherent segments (at most C.JET_HZ per second), linked into
	-- one continuous stream
	wd.jetT = (wd.jetT or 0) + dt
	if kJet > 1e-4 then
		wd.jetAcc = wd.jetAcc + vol * kJet * jetK
		if wd.jetAcc > 0.008 and wd.jetT >= 1 / C.JET_HZ then
			wd.jetT = 0
			local b = src.pose:Bone(wd.bone)
			local jx, jy, jz = nx, ny, nz
			if b then
				-- Z-City stores the damage direction in bone space; blood exits against it
				local lx, ly, lz = wd.ldx, wd.ldy, wd.ldz
				local dx = -(b[1] * lx + b[2] * ly + b[3] * lz)
				local dy = -(b[5] * lx + b[6] * ly + b[7] * lz)
				local dz = -(b[9] * lx + b[10] * ly + b[11] * lz)
				dx, dy, dz = ABL.Norm(dx, dy, dz)
				-- a jet cannot point into the body
				local dn = dx * nx + dy * ny + dz * nz
				if dn < 0.2 then dx, dy, dz = dx - nx * (dn - 0.2), dy - ny * (dn - 0.2), dz - nz * (dn - 0.2) end
				jx, jy, jz = ABL.Norm(dx * 0.65 + nx * 0.35, dy * 0.65 + ny * 0.35, dz * 0.65 + nz * 0.35)
			end
			-- slow wobble of the stream (tissue movement)
			wd.wobP = wd.wobP + (rng:Normal() * 0.9 - wd.wobP * 1.5) * dt
			wd.wobY = wd.wobY + (rng:Normal() * 0.9 - wd.wobY * 1.5) * dt
			local px, py, pz = ABL.Perp(jx, jy, jz)
			local qx, qy, qz = jy * pz - jz * py, jz * px - jx * pz, jx * py - jy * px
			jx, jy, jz = ABL.Norm(jx + px * wd.wobP * 0.25 + qx * wd.wobY * 0.25, jy + py * wd.wobP * 0.25 + qy * wd.wobY * 0.25, jz + pz * wd.wobP * 0.25 + qz * wd.wobY * 0.25)
			local pressure = sqrt(max(src.pulse, 20) / 75) * math.Clamp((wd.sev / 10) ^ 0.3, 0.6, 1.3) * (0.3 + 0.7 * press)
			-- (speed follows the pulse smoothly, with a slow drift: neighbouring parts of the stream
			-- leave at nearly the same speed, so it stays one curve until the pulse stretches it)
			local sk = (wd.wobS or 0) + (rng:Normal() * 0.012 - (wd.wobS or 0) * 0.05)
			sk = sk < -0.06 and -0.06 or (sk > 0.06 and 0.06 or sk)
			wd.wobS = sk
			local js = p.jetSpeed or wd.jetSp or 120
			wd.jetSp = js
			local sp = js * pressure * (0.25 + 0.75 * min(beatShape, 2.2) / 2.2) * (1 + sk) * speedK
			local dv = wd.jetAcc
			wd.jetAcc = 0
			local d = Drops.Spawn(ox, oy, oz, wvx + jx * sp, wvy + jy * sp, wvz + jz * sp, dv, src, 0, 1)
			Drops.Link(d, wd, "jet")
		end
	end

	-- spurts: pressure fluctuations and sudden movement squeeze blood out of the wound
	if p.spurtRate > 0 then
		local chance = (p.spurtRate + accel / 4000) * dt
		if rng:Next() < chance then
			local n = 2 + math.floor(rng:Next() * 4)
			local total = min(0.25, rate * 0.4)
			for _ = 1, n do
				local dx, dy, dz = Cone(rng, nx, ny, nz, 0.6)
				local sp = p.spurtSpeed * rng:Range(0.5, 1.1) * (0.5 + 0.5 * press)
				Drops.Spawn(ox, oy, oz, wvx + dx * sp, wvy + dy * sp, wvz + dz * sp, total / n, src, 0, 0)
			end
		end
	end
	return rate, asked, askedFull
end

------------------------------------------------------------------------------------------
-- Blood from the mouth. Z-City makes a character with a lung or stomach wound, or bleeding inside,
-- cough or vomit blood (its "bloodsquirt2" event, cl_compat.lua). Here that is a few mouthfuls
-- welling out and falling with the head's movement: heaves, not a fountain. The reservoir has
-- already paid for it (Z-City takes the blood off at the event).
------------------------------------------------------------------------------------------
local spouts = {}

-- ent: the character (player or ragdoll); m: the head bone's matrix at the event; pos, dir: where
-- from and which way, in the world, at the event.
function E.Cough(ent, boneName, m, pos, dir)
	if not IsValid(ent) or #spouts >= 8 then return end
	local lpos, lang = WorldToLocal(pos, dir:Angle(), m:GetTranslation(), m:GetAngles())
	local rng = ABL.RNG(ent:EntIndex() * 131 + math.floor(CurTime() * 10))
	spouts[#spouts + 1] = {
		ent = ent, boneName = boneName, lpos = lpos, lang = lang, rng = rng,
		t = 0, dur = rng:Range(0.7, 1.1), vol = rng:Range(12, 30), heaves = 2 + math.floor(rng:Next() * 2),
		speed = Clamp(dir:Length() * 45, 30, 110), acc = 0, last = 0,
	}
	if ABL.TestLog then ABL.TestLog("   blood from the mouth of %s: %.0f ml in %d heaves over %.1f s", tostring(ent), spouts[#spouts].vol, spouts[#spouts].heaves, spouts[#spouts].dur) end
end

local function StepSpouts(h)
	for i = #spouts, 1, -1 do
		local sp = spouts[i]
		local ent = sp.ent
		local body = IsValid(ent) and (ent:IsPlayer() and Z.GetBody(ent) or ent) or nil
		local bone = IsValid(body) and body:LookupBone(sp.boneName) or nil
		local m = bone and body:GetBoneMatrix(bone) or nil
		sp.t = sp.t + h
		if not m or sp.t >= sp.dur then
			table.remove(spouts, i)
		else
			-- the flow comes in heaves
			local ph = sp.t / sp.dur
			local heave = math.sin(ph * pi * sp.heaves) ^ 2
			sp.acc = sp.acc + sp.vol / sp.dur * 2 * heave * h
			sp.last = sp.last + h
			if sp.acc > 0.06 and sp.last >= 1 / 30 then
				sp.last = 0
				local pos, ang = LocalToWorld(sp.lpos, sp.lang, m:GetTranslation(), m:GetAngles())
				local f = ang:Forward()
				local rng = sp.rng
				local dx, dy, dz = Cone(rng, f.x, f.y, f.z, 0.22)
				local v = sp.speed * (0.5 + 0.5 * heave) * rng:Range(0.85, 1.1)
				local bv = body:GetVelocity()
				local src = ABL.Sources.byBody[body]
				-- (it leaves a little in front of the lips, so that it does not land on the face it came from)
				local d = Drops.Spawn(pos.x + f.x * 1.5, pos.y + f.y * 1.5, pos.z + f.z * 1.5, bv.x + dx * v, bv.y + dy * v, bv.z + dz * v, sp.acc, src, 0, 0)
				Drops.Link(d, sp, "gush")
				if src then
					ABL.Wounds.Ledger(src, "bleed", sp.acc)
					ABL.Wounds.Withdraw(src, sp.acc)
				end
				sp.acc = 0
			end
		end
	end
end

local stepIdx = 0
function E.Step(h)
	Drops = Drops or ABL.Drops
	local Sim = ABL.Sim
	if #spouts > 0 then StepSpouts(h) end
	for _, src in ipairs(ABL.Sources.list) do
		if IsValid(src.body) and #src.woundList > 0 and src.lod > C.LOD_OFF then
			local tier = C.LODTiers[src.lod]
			-- each source steps at its tier's rate: every tick up close, every few ticks (with the
			-- accumulated, longer step: same volume) further away
			src.emitAcc = (src.emitAcc or (src.seed % 7) * 0.001) + h
			if src.emitAcc + 1e-6 >= Sim.Period(tier.hz) then
				local dt = src.emitAcc
				src.emitAcc = 0
				stepIdx = stepIdx + 1
				-- (onto the film or straight off the wound: by the body's distance alone, cl_lod.lua)
				local bodyflow = ABL.LOD.FlowOn(src) and src.mesh ~= nil
				local heartH = HeartHeight(src)
				-- what is left of the circulation's pressure (blood volume, pulse)
				src.press = ABL.Wounds.Pressure(src)
				-- the governor, from what the wounds asked for in the last step
				if src.alive then
					ABL.Wounds.Govern(src, src.flowNominal or 0, src.flowShare or 1, dt, CurTime(), src.flowFull)
				else
					src.gov = 1
				end
				-- What the wounds ask for is summed as asked, not worked back from what the governor let
				-- through: with the governor shut (an empty bank and nothing asked yet) that would be
				-- nought divided by nought, and the governor would never open again.
				local total, asked, lossSum, askedFull = 0, 0, 0, 0
				for _, wd in ipairs(src.woundList) do
					local rate, ask, askFull = EmitWound(src, wd, dt, stepIdx, bodyflow, heartH)
					total = total + rate
					asked = asked + ask
					askedFull = askedFull + (askFull or ask)
					lossSum = lossSum + ask / ExternalShare(wd)
				end
				src.flowRate = total
				src.flowNominal = asked
				src.flowFull = askedFull
				src.flowShare = lossSum > 0 and asked / lossSum or 1
			end
		elseif #src.woundList > 0 and src.lod == C.LOD_OFF then
			-- completely culled: keep coarse accounting (10 Hz) so pools still grow where the body lies
			src.emitAcc = (src.emitAcc or 0) + h
			if src.emitAcc >= 0.1 then
				local dt = src.emitAcc
				src.emitAcc = 0
				local total = 0
				for _, wd in ipairs(src.woundList) do
					Respond(wd, dt)
					local r = E.Rate(src, wd)
					wd.deposit = wd.deposit + r * dt
					total = total + r
				end
				src.flowRate = total
			end
		elseif #src.woundList == 0 and (src.flowRate or 0) ~= 0 then
			src.flowRate, src.flowNominal = 0, 0
		end
	end
end

-- Coarse deposition for sources without per-drop simulation (1 Hz, one trace per source).
local nextDeposit = 0
local depTrace = { mask = MASK_SOLID_BRUSHONLY, output = {} }
function E.DepositThink()
	local now = CurTime()
	if now < nextDeposit then return end
	nextDeposit = now + 1
	for _, src in ipairs(ABL.Sources.list) do
		local total = 0
		for _, wd in ipairs(src.woundList) do total = total + wd.deposit wd.deposit = 0 end
		if total > 0.05 and IsValid(src.body) then
			local c = src.body:WorldSpaceCenter()
			depTrace.start = c
			depTrace.endpos = c - Vector(0, 0, 90)
			depTrace.filter = src.filterAll
			local tr = util.TraceLine(depTrace)
			if tr.Hit and tr.HitNormal.z > 0.6 then
				local r = src.rng
				ABL.FlowCore.Release("pool", total)
				ABL.Pools.Deposit(tr.HitPos.x + r:Range(-6, 6), tr.HitPos.y + r:Range(-6, 6), tr.HitPos.z, tr.HitNormal, total, ABL.Surface.FromTrace(tr), tr.Entity, "seep", nil, nil, nil, nil, src.key)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- A hit (abl_hit): the wound record, its marks, and the first release of blood.
-- The burst comes out of the wound, not out of the hit: how much, how fast and in which direction
-- follows from what the projectile was and did. Back spatter leaves the entry against the bullet
-- (few, fine drops; more from a contact shot, whose gas blows back, and from a skull); forward
-- spatter leaves an exit, and only where the projectile really came out through the skin; a
-- retained projectile throws nothing forward; a graze casts a few drops along the skin.
-- Everything is drawn from the event's seed, so every client sees the same burst.
------------------------------------------------------------------------------------------
local function BoneWorld(body, bone, lp)
	local m = body:GetBoneMatrix(bone)
	if not m then return nil end
	return LocalToWorld(lp, angle_zero, m:GetTranslation(), m:GetAngles())
end

-- Spatter sizes are skewed: many fine droplets, few large ones. s = 0 finest .. 1 coarsest.
-- Fine droplets leave in a wider cone with more scattered speeds (and lose that speed quickly to
-- drag); large ones form a tight, fast core that carries far.
local function Spatter(rng, vmin, vmax)
	local s = rng:Next() ^ 1.7
	return vmin * (vmax / vmin) ^ s, s
end

-- speed scale of the burst by energy class (0 unknown .. 6 extreme). Blood thrown out of a wound
-- is not the projectile: its speeds are these few metres a second, whatever the bullet's was.
local ENERGY_SPEED = { [0] = 1, 0.7, 0.88, 1.0, 1.12, 1.22, 1.32 }

-- The source a hit on `body` belongs to: the living player the server names (the body may be a
-- fake ragdoll so new that nothing on the client links it to its player yet), else the source that
-- already has this body, else the body itself (a corpse).
local function HitSource(body, owner)
	local S = ABL.Sources
	if IsValid(owner) and owner:IsPlayer() and owner:Alive() then return S.Ensure(owner) end
	local src = S.byBody[body]
	if src and not src.removed then
		local to = src.migratedTo
		if IsValid(to) then src = S.Ensure(to) end
		return src
	end
	owner = Z.GetOwner(body)
	return S.Ensure((IsValid(owner) and owner:Alive()) and owner or body)
end

function E.OnHit(ev)
	Drops = Drops or ABL.Drops
	local body = ev.body
	if not IsValid(body) or body:IsDormant() then return end
	local src = HitSource(body, ev.owner)
	if not src then return end
	local entry = BoneWorld(body, ev.bone, ev.lpos)
	if not entry then return end
	local WS, N, F = ABL.Wounds, ABL.Net, WD.F
	local boneName = body:GetBoneName(ev.bone)
	if ev.replay then
		-- A wound this client is told of after the fact (cl_events.lua, abl_wrep). One it already
		-- has (it was there for the hit, or was told before) is not made again: the same hit by
		-- the server's own number for it, on the same bone, at the same place.
		local sl = src.wrecs
		if sl then
			local id = ev.seed or 0
			for i = 1, #sl do
				local r = sl[i]
				if r.id == id and r.boneName == boneName and r.lentry and r.lentry:DistToSqr(ev.lpos) < 0.02 then
					if ABL.WoundSync then ABL.WoundSync.stats.had = ABL.WoundSync.stats.had + 1 end
					TR.Event(src, nil, string.format("hit %d on %s told again: ignored", id, TR.Short(boneName)), "this client has that wound already")
					return
				end
			end
		end
	-- the engine's own splat decal at the hit gives way to the wound (cl_stains.lua)
	elseif (ev.class == ABL.Net.DMG_BULLET or ev.class == ABL.Net.DMG_BUCKSHOT) and ABL.Compat.Takeover() and not C.cl.fleshDecals:GetBool() then
		ABL.Stains.ClearEngineHitDecal(body)
	end
	local rng = ABL.RNG((ev.seed or 0) * 7919 + 104729)
	local cls = ev.class
	local bullet = cls == N.DMG_BULLET or cls == N.DMG_BUCKSHOT
	local now = CurTime()
	local ph = src.pendingHits
	local energy = Clamp(ev.damage / 30, 0.2, 4)

	if ev.continued then
		-- The same bullet again (the body it had just left became a ragdoll in its way): what it
		-- crossed there adds to the wound it had made, and the wounds Z-City books for it bleed
		-- through that wound's openings.
		local sl = src.wrecs
		local r = sl and sl[#sl]
		if r and r.bullet and now - r.t0 < 1.5 then
			WS.Extend(r, ev)
			local mk = r.exitMark or r.entryMark
			ph[#ph + 1] = { t = now, boneName = boneName, lx = ev.lpos.x, ly = ev.lpos.y, lz = ev.lpos.z, energy = energy, mark = mk, rec = r, role = "exit" }
			if ev.second then
				local le = ev.exitLocal or ev.lpos
				ph[#ph + 1] = { t = now, boneName = boneName, lx = le.x, ly = le.y, lz = le.z, energy = energy, mark = mk, rec = r, role = "exit" }
			end
			LinkWaiting(src, now)
			return
		end
		-- (the first hit never got here: an ordinary wound then)
	end

	-- the wound: record, marks on the body (cl_woundfx works out the surface geometry: angle of
	-- impact, track length, graze, where the projectile really left the skin)
	local rec = WS.Create(src, body, ev, rng)
	local exitPos = ev.exitLocal and BoneWorld(body, ev.bone, ev.exitLocal) or nil
	local mark, exitMark = ABL.WoundFX.OnHit(src, body, ev, rec, entry, exitPos, rng)
	rec.entryMark, rec.exitMark = mark, exitMark
	TR.Event(src, nil, string.format("hit %d on %s taken%s", rec.id, TR.Short(boneName), ev.replay and " (told after the fact)" or ""),
		mark and (exitMark and "entry and exit marked on the skin" or "entry marked on the skin") or (rec.pen == WD.PEN_ARMOR and "stopped by armour: no opening")
			or ((src.mesh and src.body == body) and "NO MARK: no place on the skin was found for it" or "its mark waits for the body's surface model"))
	-- a blunt blow that drew no blood: its bruise is there (cl_woundfx.lua); nothing bleeds,
	-- nothing is thrown, no wound of Z-City's is waited for
	if cls == N.DMG_CLUB and (ev.bleed or 0) <= 0 then
		rec.wet = 0
		return
	end

	-- Z-City's wounds for this hit: where they are (or will be, with its next netvar update)
	ph[#ph + 1] = { t = now, boneName = boneName, lx = ev.lpos.x, ly = ev.lpos.y, lz = ev.lpos.z, energy = energy, mark = mark, rec = rec, role = "entry" }
	if ev.second then
		-- its second record of the same shot: bleeds from the exit when there is one on the skin,
		-- else from the same opening
		local le = ev.exitLocal or ev.lpos
		ph[#ph + 1] = { t = now, boneName = boneName, lx = le.x, ly = le.y, lz = le.z, energy = energy, mark = exitMark or mark, rec = rec, role = "exit" }
	end
	LinkWaiting(src, now, ev.replay)
	-- (a wound told after the fact: what was thrown out of it was thrown then, and is not thrown again)
	if ev.replay then return end

	local _, near = ABL.LOD.PointImportance(entry.x, entry.y, entry.z)
	if near > C.cl.drawDist:GetFloat() then return end
	local dx, dy, dz = ev.dir.x, ev.dir.y, ev.dir.z
	local bv = body:GetVelocity()
	local released = 0

	if bullet then
		if rec.pen == WD.PEN_ARMOR then return end -- stopped by armour: no opening in the skin
		local pellet = cls == N.DMG_BUCKSHOT
		local eK = ENERGY_SPEED[rec.energy] or 1
		local cav = rec.cavity
		local skull = rec.skull or WS.Has(rec, F.BRAIN)
		-- where the blood leaves: the opening on the skin when it is known
		local ex0, ey0, ez0 = entry.x, entry.y, entry.z
		if mark and mark.hitPos then ex0, ey0, ez0 = mark.hitPos.x, mark.hitPos.y, mark.hitPos.z end

		if rec.graze then
			-- a graze: the projectile ploughs along the skin and casts a few drops on ahead of it
			local n = math.floor(2 + rng:Next() * 3 + 2 * cav)
			for _ = 1, n do
				local vol, s = Spatter(rng, 0.002, 0.02)
				local cx, cy, cz = Cone(rng, dx, dy, dz, 0.35 * (1.3 - 0.5 * s))
				local sp = rng:Range(40, 150) * eK * (1.1 - 0.3 * s)
				Drops.Spawn(ex0 + dx, ey0 + dy, ez0 + dz, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp, vol, src, 1, 2)
				released = released + vol
			end
		else
			-- back spatter: fine, few, against the bullet
			local back = (1.5 + 3.5 * cav + rng:Next() * 2.5) * (pellet and 0.5 or 1)
			if rec.range == WD.RANGE_CONTACT then back = back * 2.2 elseif rec.range == WD.RANGE_NEAR then back = back * 1.3 end
			if skull then back = back * 1.5 end
			local nBack = math.floor(back)
			for _ = 1, nBack do
				local vol, s = Spatter(rng, 0.0015, 0.012)
				local cx, cy, cz = Cone(rng, -dx, -dy, -dz, 0.75 * (1.25 - 0.5 * s))
				local sp = rng:Range(45, 150) * eK * (1.1 - 0.25 * s)
				Drops.Spawn(ex0 - dx, ey0 - dy, ez0 - dz, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp, vol, src, 1, 2)
				released = released + vol
			end
			-- mist only where there is the energy (or the gas, or the pressure of a skull) for it
			local mistBack = math.floor((cav * 4 + (rec.range == WD.RANGE_CONTACT and 2 or 0)) * (skull and 1.4 or 1))
			if mistBack > 0 then Drops.Mist(Vector(ex0 - dx * 2, ey0 - dy * 2, ez0 - dz * 2), -ev.dir * 40 + bv, mistBack, 5 + cav * 6) end

			-- forward spatter: out of the exit, with the projectile. More, larger and faster than
			-- back spatter, in a narrower cone; bone on the way adds to it
			local out = exitMark and exitMark.hitPos or ((rec.pen == WD.PEN_THROUGH and not src.mesh) and exitPos) or nil
			if out then
				local fwd = (3 + 11 * cav + rng:Next() * 6) * (pellet and 0.5 or 1) * (rec.boneHit and 1.3 or 1) * (skull and 1.3 or 1)
				local nFwd = math.floor(fwd)
				for _ = 1, nFwd do
					local vol, s = Spatter(rng, 0.004, skull and 0.06 or 0.05)
					local cx, cy, cz = Cone(rng, dx, dy, dz, 0.42 * (1.3 - 0.6 * s))
					local sp = rng:Range(100, 300) * eK * (1.1 - 0.2 * s)
					Drops.Spawn(out.x + dx, out.y + dy, out.z + dz, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp, vol, src, 1, 2)
					released = released + vol
				end
				local mistFwd = math.floor((1 + cav * 7) * (skull and 1.4 or 1))
				if mistFwd > 0 then Drops.Mist(out + ev.dir * 3, ev.dir * 90 + bv, mistFwd, 7 + cav * 7) end
			end
		end
	elseif cls == N.DMG_SLASH then
		-- cast-off along the cut, perpendicular-ish to the blade direction
		local n = math.floor(5 + energy * 5)
		for _ = 1, n do
			local vol, s = Spatter(rng, 0.01, 0.06)
			local cx, cy, cz = Cone(rng, dx, dy, dz, 0.6 * (1.25 - 0.5 * s))
			local sp = rng:Range(40, 160) * (1.1 - 0.2 * s)
			Drops.Spawn(entry.x, entry.y, entry.z, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp + 20, vol, src, 1, 0)
			released = released + vol
		end
	elseif cls == N.DMG_BLAST then
		local n = math.floor(14 + energy * 6)
		for _ = 1, n do
			local vol, s = Spatter(rng, 0.005, 0.08)
			local cx, cy, cz = ABL.Norm(rng:Normal(), rng:Normal(), rng:Normal() + 0.4)
			local sp = rng:Range(80, 300) * (1.15 - 0.3 * s)
			Drops.Spawn(entry.x, entry.y, entry.z, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp, vol, src, 1, 2)
			released = released + vol
		end
		Drops.Mist(entry, bv, 8, 16)
	else
		local n = math.floor(2 + energy * 3)
		for _ = 1, n do
			local vol, s = Spatter(rng, 0.005, 0.03)
			local cx, cy, cz = Cone(rng, -dx, -dy, -dz, 0.9 * (1.2 - 0.4 * s))
			local sp = rng:Range(20, 80)
			Drops.Spawn(entry.x, entry.y, entry.z, bv.x + cx * sp, bv.y + cy * sp, bv.z + cz * sp, vol, src, 1, 0)
			released = released + vol
		end
	end
	rec.released = rec.released + released
	rec.burst = released
	WS.Ledger(src, "burst", released)
	WS.Withdraw(src, released)
end

-- A strong jolt (ragdoll collision) squeezes extra blood out of wounds on/near the hit bone.
function E.Jolt(src, bone, speed, nx, ny, nz)
	Drops = Drops or ABL.Drops
	if not (speed > 0 and speed < 1e5 and ABL.Finite3(nx, ny, nz)) then return end
	for _, wd in ipairs(src.woundList) do
		if wd.bone then
			local ok, x, y, z, wnx, wny, wnz = E.WoundFrame(src, wd)
			if ok then
				local near = wd.bone == bone
				if not near then
					local b = src.pose:Bone(bone)
					if b then
						local dx, dy, dz = x - b[4], y - b[8], z - b[12]
						near = dx * dx + dy * dy + dz * dz < 20 * 20
					end
				end
				if near then
					local rng = wd.rng
					local amount = math.Clamp(speed / 500, 0.1, 1.2) * math.Clamp(E.Rate(src, wd), 0.2, 6) * 0.25
					local n = 2 + math.floor(rng:Next() * 4 + speed / 250)
					for _ = 1, n do
						-- blood is thrown sideways along the ground from the compressed wound
						local tx, ty, tz = Cone(rng, wnx - nx * 0.8, wny - ny * 0.8, wnz - nz * 0.8, 0.9)
						local sp = rng:Range(0.2, 0.5) * math.min(speed, 700)
						Drops.Spawn(x + wnx * 0.5, y + wny * 0.5, z + wnz * 0.5, tx * sp, ty * sp, tz * sp + 15, amount / n, src, 1, 0)
					end
				end
			end
		end
	end
end
