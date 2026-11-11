-- The injury event: what happened to a head, measured where the engine can measure it.
--
--   ragdoll impact  the head of a ragdoll meets something: the collision gives the speed lost and
--                   the rotation before; the rotation after is followed for a short window
--   whiplash        the body lands and the head whips without touching anything
--   blunt           a blow to the head of a character with no physics to measure (standing): estimated
--   fall            a hard landing on the feet: the body's speed, estimated
--   projectile      a bullet through or along the head: energy and the track
--   blast           an explosion: its damage, estimated
--
-- A fall is described by how the head arrives, never by its height. Events are built here, valued
-- by sv_biomech.lua and handed to the trauma pipeline (sv_trauma.lua); this file changes nothing in
-- the game.

local NT = NeuroTrauma
NT.Injury = NT.Injury or {}
local I = NT.Injury
local C, Z, B, E = NT.Config, NT.ZC, NT.Biomech, NT.E
local CC = C.Capture
local M, RAD = C.M_PER_UNIT, C.RAD
local Mech = E.Mech

local queue = {}                                      -- contacts copied out of the physics callback
local windows = {}                                    -- bodies whose head rotation is being followed
local winOf = setmetatable({}, { __mode = "k" })      -- ragdoll -> its open window
local headOf = setmetatable({}, { __mode = "k" })     -- ragdoll -> head physics object (false: none)
local nextEvent = setmetatable({}, { __mode = "k" })  -- ragdoll -> time before which contacts are ignored
local history = setmetatable({}, { __mode = "k" })    -- organism -> its last events
local serial = 0
I.count = I.count or 0

local enabled = false
timer.Create("NT_InjuryEnabled", 1, 0, function() enabled = NT.Enabled() end)

function I.History(org) return history[org] end

------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------
local function New(ply, org, body, mech)
	serial = serial + 1
	return {
		id = serial, t = CurTime(), seed = math.random(1, 2147483646),
		ply = ply, org = org, body = body, mech = mech,
		measured = false, region = E.Region.NONE, lat = 0,
		dv = 0, dvn = 0, closing = 0, obliq = 0, stiff = 1, surface = "",
		dOmega = 0, sag = 0, cor = 0, ax = 0, alpha = 0, landing = 0,
		headFirst = false, contacts = 0, shield = 0, awake = 1,
		pen = E.Pen.NONE, zones = 0, energy = 0,
	}
end

local function Fmt(ev)
	local s = string.format("#%d %s %s %s | head %s lat %+.2f | dv %.1f m/s (normal %.1f) closing %.1f obliq %.0f on %s(%.2f) | dw %.1f rad/s (sag %.1f cor %.1f ax %.1f) alpha %.0f | landing %.1f m/s | %s, %d contacts | awake %.2f shield %.2f | rot %.1f contact %.1f protect %.2f",
		ev.id, IsValid(ev.ply) and ev.ply:Nick() or "?", Mech.names[ev.mech], ev.measured and "meas" or "est",
		E.Region.names[ev.region], ev.lat, ev.dv, ev.dvn, ev.closing, ev.obliq, ev.surface ~= "" and ev.surface or "-", ev.stiff,
		ev.dOmega, ev.sag, ev.cor, ev.ax, ev.alpha, ev.landing, ev.headFirst and "head first" or "body first", ev.contacts,
		ev.awake, ev.shield, ev.rot or 0, ev.contact or 0, ev.protect or 1)
	if ev.mech == Mech.PROJECTILE then
		s = s .. string.format(" | %s zones %s energy %.0f J track %.1f cm", E.Pen.names[ev.pen], E.ZoneText(ev.zones), ev.energy, ev.track or 0)
		local a, b = ev.trackA, ev.trackB
		if a and b then s = s .. string.format(" from (%+.2f %+.2f %+.2f) to (%+.2f %+.2f %+.2f)", a[1], a[2], a[3], b[1], b[2], b[3]) end
	elseif ev.mech == Mech.BLAST or ev.mech == Mech.BLUNT then
		s = s .. string.format(" | damage %.1f", ev.damage or 0)
	end
	return s
end
I.Describe = Fmt

-- An event made by hand (the API, developer commands, tests) carries only what its maker set: the
-- rest is filled in, so that it can be described like any other.
local DEFAULTS = {
	id = 0, measured = false, region = E.Region.NONE, lat = 0, dv = 0, dvn = 0, closing = 0, obliq = 0, stiff = 1, surface = "",
	dOmega = 0, sag = 0, cor = 0, ax = 0, alpha = 0, landing = 0, headFirst = false, contacts = 0, shield = 0, awake = 1,
	pen = E.Pen.NONE, zones = 0, energy = 0,
}
function I.Complete(ev)
	for k, v in pairs(DEFAULTS) do
		if ev[k] == nil then ev[k] = v end
	end
	return ev
end

-- Bookkeeping for an event that has been handed to the pipeline: the history of the character,
-- the count, the log line.
function I.Record(ev, dead)
	if not dead then
		local org = ev.org
		local h = history[org]
		if not h then h = {} history[org] = h end
		h[#h + 1] = ev
		if #h > CC.historyKept then table.remove(h, 1) end
	end
	I.count = I.count + 1
	if C.sv.log:GetBool() then NT.Print("%s%s", Fmt(ev), dead and " (the character is dead)" or "") end
	if NT.TestLog then NT.TestLog("  event %s%s", Fmt(ev), dead and " (the character is dead)" or "") end
end

-- An event is complete: it goes to the trauma pipeline (sv_trauma.lua), which is the only thing
-- that turns it into consequences.
function I.Emit(ev)
	return NT.ProcessTraumaEvent(ev.ply, ev)
end

------------------------------------------------------------------------------------------
-- Ragdolls: measured. The physics callback only copies; the work is done in Think.
------------------------------------------------------------------------------------------
hook.Add("Ragdoll Collide", "NT_Collide", function(rag, data)
	local speed = data.Speed
	if speed < CC.headMinSpeed or not enabled then return end
	local head = headOf[rag]
	if head == nil then
		head = Z.HeadPhys(rag) or false
		headOf[rag] = head
	end
	local phys = data.PhysObject
	local isHead = head and phys == head
	if not isHead and speed < CC.bodyMinSpeed then return end
	local n = #queue
	if n >= CC.queueMax then return end
	queue[n + 1] = {
		rag = rag, head = isHead, phys = phys, t = CurTime(),
		vOld = data.OurOldVelocity, vNew = data.OurNewVelocity,
		wOld = isHead and phys:LocalToWorldVector(data.OurOldAngularVelocity) or nil,
		normal = data.HitNormal, pos = data.HitPos, surf = data.TheirSurfaceProps,
		vOther = data.TheirOldVelocity,
	}
end)

local function Open(rag, c, now)
	if (nextEvent[rag] or 0) > now then return nil end
	local owner = Z.Owner(rag)
	if not owner then return nil end
	local org = Z.Org(owner)
	local head = headOf[rag]
	if not org or not head or not IsValid(head) then return nil end
	local centre, up, face, left = Z.HeadFrame(rag)
	if not centre then return nil end
	local w0 = c.head and c.wOld or head:LocalToWorldVector(head:GetAngleVelocity())
	local w = {
		rag = rag, ply = owner, org = org, phys = head, t0 = c.t,
		w0 = w0, lastW = w0, lastT = c.t, peak = Vector(0, 0, 0), peakLen = 0, alpha = 0,
		contacts = 0, first = c.head and "head" or "body",
		-- (the speed at which the body arrived: every part of it has about this speed before the first contact)
		landing = (c.vOld - (c.vOther or vector_origin)):Length(), core = 0,
		up = up, face = face, left = left, centre = centre,
		-- (how awake the character is as it lands: Z-City may knock it out for this very impact)
		awake = Z.Consciousness(org),
	}
	-- the trunk and the head as they still move (one tick after the first touch at most)
	local core = head:GetVelocity():Length()
	local root = rag:GetPhysicsObjectNum(0)
	if IsValid(root) then
		core = math.max(core, root:GetVelocity():Length())
		if c.phys == root then core = math.max(core, c.vOld:Length()) end
	end
	if c.head then core = math.max(core, c.vOld:Length()) end
	w.core = core
	winOf[rag] = w
	windows[#windows + 1] = w
	return w
end

local function Close(w)
	local rag = w.rag
	local now = CurTime()
	winOf[rag] = nil
	nextEvent[rag] = now + CC.debounce
	local ply, org = w.ply, w.org
	if not IsValid(ply) or not ply:Alive() then return end
	local h = w.hit
	if not h and w.peakLen * RAD < CC.whipMinOmega then return end
	local ev = New(ply, org, rag, h and Mech.RAGDOLL_IMPACT or Mech.WHIPLASH)
	ev.measured = true
	local up, face, left = w.up, w.face, w.left
	if h then
		local dvv = (h.vNew - h.vOld) * M
		local nrm = h.normal
		ev.dv = dvv:Length()
		ev.dvn = math.abs(dvv:Dot(nrm))
		local rel = h.vOld - (h.vOther or vector_origin)
		local rl = rel:Length()
		ev.closing = rl * M
		ev.obliq = rl > 1 and math.deg(math.acos(math.Clamp(math.abs(rel:Dot(nrm)) / rl, 0, 1))) or 0
		ev.stiff, ev.surface = Z.SurfaceStiffness(h.surf)
		local dir = h.pos - h.centre
		dir:Normalize()
		ev.region, ev.lat = B.Region(dir, h.up, h.face, h.left)
		ev.hit = { dir:Dot(h.left), dir:Dot(h.face), dir:Dot(h.up) }
		up, face, left = h.up, h.face, h.left
	end
	local dw = w.peak * RAD
	ev.dOmega = dw:Length()
	ev.sag, ev.cor, ev.ax = B.SplitRotation(dw, up, face, left)
	ev.alpha = w.alpha * RAD
	-- (a limb can whip into the ground far faster than the body arrives: the body's speed is what
	-- the trunk and the head still had when the first part touched)
	ev.landing = math.min(w.landing, w.core) * M
	ev.headFirst = w.first == "head"
	ev.contacts = w.contacts
	ev.shield = Z.HeadShield(ply)
	ev.awake = w.awake
	I.Emit(ev)
end

hook.Add("Think", "NT_Injury", function()
	local nq = #queue
	if nq == 0 and #windows == 0 then return end
	local now = CurTime()
	if nq > 0 then
		local q = queue
		queue = {}
		for i = 1, nq do
			local c = q[i]
			local rag = c.rag
			if IsValid(rag) then
				local w = winOf[rag] or Open(rag, c, now)
				if w then
					local dv = (c.vNew - c.vOld):Length()
					if c.head then
						w.contacts = w.contacts + 1
						-- the hardest head contact of the window describes the impact
						if not w.hit or dv > w.hitDv then
							local centre, up, face, left = Z.HeadFrame(rag)
							if centre then
								c.centre, c.up, c.face, c.left = centre, up, face, left
								w.hit, w.hitDv = c, dv
							end
						end
					end
				end
			end
		end
	end
	-- follow the head's rotation in every open window; close the ones that have run their time
	for i = #windows, 1, -1 do
		local w = windows[i]
		local phys = w.phys
		if not IsValid(w.rag) or not IsValid(phys) then
			table.remove(windows, i)
		else
			local wv = phys:LocalToWorldVector(phys:GetAngleVelocity())
			local d = wv - w.w0
			local dl = d:Length()
			if dl > w.peakLen then w.peak, w.peakLen = d, dl end
			local dt = now - w.lastT
			if dt > 0.004 then
				local a = (wv - w.lastW):Length() / dt
				if a > w.alpha then w.alpha = a end
				w.lastW, w.lastT = wv, now
			end
			if now - w.t0 >= CC.window then
				table.remove(windows, i)
				Close(w)
			end
		end
	end
end)

------------------------------------------------------------------------------------------
-- Bullets: the track through the head
------------------------------------------------------------------------------------------
local trails = setmetatable({}, { __mode = "k" })    -- organism -> head boxes the bullet crossed
local hitEnts = setmetatable({}, { __mode = "k" })   -- organism -> the entity Z-City is damaging
local pre = setmetatable({}, { __mode = "k" })       -- organism -> the hit as it arrived
local shots = setmetatable({}, { __mode = "k" })     -- organism -> the last bullet that met its brain (tick, values after it)
local blasts = setmetatable({}, { __mode = "k" })    -- organism -> the explosion of this tick (values after its first damage call)

-- Z-City works on the damage in place (by the time its damage hook runs, a blow of 25 reads 0.4):
-- the hit is copied here, before.
hook.Add("PreHomigradDamage", "NT_Trail", function(ply, dmgInfo, hitgroup, ent)
	local org = IsValid(ent) and ent.organism
	if org then
		trails[org] = nil
		hitEnts[org] = ent
		if enabled then
			pre[org] = { rt = SysTime(), damage = dmgInfo:GetDamage(), force = dmgInfo:GetDamageForce(), pos = dmgInfo:GetDamagePosition(), dtype = dmgInfo:GetDamageType(),
				brain = tonumber(org.brain), awake = Z.Consciousness(org) }
			-- (a blow of the free-hand module, lua/freehand/sv_impact.lua: see below)
			local inf = dmgInfo:GetInflictor()
			if IsValid(inf) and inf.FH_blow ~= nil then pre[org].freehand = true end
		end
	end
end)

-- Z-City traces a bullet through boxes that stand for organs and calls this for each one it meets.
-- Only the boxes of the head matter here; their place and size are read from the call.
hook.Add("PreTraceOrganBulletDamage", "NT_Trail", function(org, bone, dmg, dmgInfo, box, dir, hit, ricochet, organ)
	if not enabled or not istable(org) or not istable(organ) then return end
	local name = organ[1]
	if not isstring(name) then return end
	local kind
	if name == "brain" then kind = "brain"
	elseif name == "skull" then kind = "skull"
	elseif name == "jaw" then kind = "jaw"
	elseif string.find(name, "helmet", 1, true) or string.find(name, "mask", 1, true) then kind = "armor"
	else return end
	local now = SysTime()
	local tr = trails[org]
	-- (the whole damage call is synchronous: anything older belongs to an earlier bullet)
	if not tr or now - tr.rt > 0.05 then
		tr = { rt = now, brain = 0, skull = 0, jaw = 0, armor = 0, boxes = {} }
		trails[org] = tr
	end
	tr[kind] = tr[kind] + 1
	if kind == "brain" and isvector(organ[3]) and isvector(organ[5]) then
		tr.boxes[#tr.boxes + 1] = { c = organ[3], s = organ[5] }
	end
end)

-- Which zones of the head a straight track crosses. The brain boxes are Z-City's (read above); the
-- zones are a geometric abstraction [P]: left and right half, the deep middle, and the lower box.
local function Track(body, entry, dir, boxes)
	local b = body:LookupBone("ValveBiped.Bip01_Head1")
	if not b then return 0, 0 end
	local bpos, bang = body:GetBonePosition(b)
	if not bpos then return 0, 0 end
	local _, _, _, left = Z.HeadFrame(body)
	local leftSign = (left and left:Dot(bang:Up()) < 0) and -1 or 1
	local zones, inside = 0, 0
	local step = 0.4
	for s = 0, 12, step do
		local lp = WorldToLocal(entry + dir * s, angle_zero, bpos, bang)
		for _, bx in ipairs(boxes) do
			local c, h = bx.c, bx.s
			local dx, dy, dz = lp.x - c.x, lp.y - c.y, lp.z - c.z
			if math.abs(dx) <= h.x and math.abs(dy) <= h.y and math.abs(dz) <= h.z then
				inside = inside + 1
				if c.x < 3 then
					zones = bit.bor(zones, E.Zone.LOWER_REAR)
				else
					local l = lp.z * leftSign
					if l > 0.35 then zones = bit.bor(zones, E.Zone.LEFT) elseif l < -0.35 then zones = bit.bor(zones, E.Zone.RIGHT) end
					if math.abs(dz) < 0.9 and math.abs(dy) < 1.5 and math.abs(dx) < 1.2 then zones = bit.bor(zones, E.Zone.DEEP) end
				end
				break
			end
		end
	end
	return zones, inside * step * 2.54
end

hook.Add("PreHomigradDamageBulletBleedAdd", "NT_Projectile", function(ply, org, dmgInfo, hitgroup, harm, hitBoxs, inputHole, info)
	if not enabled or not istable(org) then return end
	-- One explosion is counted once. Z-City hands the same explosion to its organ inputs several
	-- times in one tick (the character, the ragdoll it has just been dropped into, and every target
	-- entity fastened to that ragdoll passes it on again), and each pass adds to the brain and the
	-- skull: a hand grenade two metres off summed to a brain value of 0.81 in seven passes, 0.03 in
	-- the first. With the takeover on, what the first pass wrote stands, Z-City's own rule for one
	-- explosion, including its death at 0.7; what the repeats add to brain and skull is taken back.
	if dmgInfo:IsDamageType(DMG_BLAST) then
		local owner = org.owner
		if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then return end
		if not Z.Takeover() or not NT.Enabled() or I.muted then return end
		local tick = engine.TickCount()
		local b = blasts[org]
		if b and b.tick == tick then
			b.n = b.n + 1
			b.undone = math.max(b.undone, (tonumber(org.brain) or 0) - (b.brain or 0))
			if b.brain then org.brain = b.brain end
			if b.skull then org.skull = b.skull end
		else
			blasts[org] = { tick = tick, n = 1, undone = 0, brain = tonumber(org.brain), skull = tonumber(org.skull) }
		end
		return
	end
	local tr = trails[org]
	trails[org] = nil
	if tr and SysTime() - tr.rt > 0.05 then tr = nil end
	local headHit = tr and (tr.brain + tr.skull + tr.jaw + tr.armor) > 0
	if not headHit and hitgroup ~= HITGROUP_HEAD then return end
	if not dmgInfo:IsDamageType(DMG_BULLET) and not dmgInfo:IsDamageType(DMG_BUCKSHOT) then return end
	local owner = org.owner
	if not IsValid(owner) or not owner:IsPlayer() then return end
	-- One bullet is counted once. Z-City sends a bullet on from where its trace through the body
	-- ended, which is inside the head; the character has just been dropped into a ragdoll at the
	-- same place, and the continuation meets the same head again in the same tick (before the
	-- takeover that second hit fell on a corpse). What it did to Z-City's brain and skull values
	-- is taken back; no second event is made of it.
	local tick = engine.TickCount()
	local first = shots[org]
	if first and first.tick == tick and first.brainHit and Z.Takeover() and owner:Alive() then
		if first.brain then org.brain = first.brain end
		if first.skull then org.skull = first.skull end
		if NT.TestLog then NT.TestLog("  the same bullet met %s again (Z-City's continuation): counted once", owner:Nick()) end
		return
	end
	local body = hitEnts[org]
	if not IsValid(body) then body = Z.Body(owner) end
	local centre, up, face, left = Z.HeadFrame(body)
	if not centre then return end

	local ev = New(owner, org, body, Mech.PROJECTILE)
	local holes = istable(info) and info.input_hole
	local entry = (istable(holes) and isvector(holes[1]) and holes[1]) or dmgInfo:GetDamagePosition()
	local out = istable(info) and info.output_hole
	local hasExit = istable(out) and isvector(out[1])
	ev.damage = dmgInfo:GetDamage()
	local speed, mass, _, _, _, src, bdir = Z.Projectile(dmgInfo)
	-- the way the bullet flew: from its own data, else from where it was fired, else from the push
	local dir = bdir
	if not dir and src and src:DistToSqr(entry) > 1 then dir = (entry - src):GetNormalized() end
	if not dir then
		local force = dmgInfo:GetDamageForce()
		dir = force:LengthSqr() > 1 and force:GetNormalized() or face * -1
	end
	if speed and mass then ev.energy = 0.5 * (mass / 1000) * speed * speed end
	ev.speed = speed or 0
	local rdir = entry - centre
	rdir:Normalize()
	ev.region, ev.lat = B.Region(rdir, up, face, left)
	ev.hit = { rdir:Dot(left), rdir:Dot(face), rdir:Dot(up) }
	ev.shield = Z.HeadShield(owner)
	ev.awake = Z.Consciousness(org)
	local brain = tr and tr.brain > 0
	if brain then
		ev.zones, ev.track = Track(body, entry, dir, tr.boxes)
		if ev.zones == 0 then
			-- (the straight line misses the boxes Z-City's trace met: take the side of the entry)
			ev.zones = ev.lat >= 0 and E.Zone.LEFT or E.Zone.RIGHT
		end
		ev.pen = hasExit and E.Pen.PERFORATING or E.Pen.PENETRATING
		-- the track in the frame of the atlas (sh_atlas.lua): from the entry along the flight of the
		-- bullet, as far as the line runs inside the boxes Z-City traced. (Z-City's "output hole" is
		-- the point where its trace met the last box, an inch behind the entry: not an exit.)
		local CA = C.Anatomy
		local function Atlas(p)
			local r = p - centre
			return { r:Dot(left) / CA.headX, r:Dot(face) / CA.headY, r:Dot(up) / CA.headZ }
		end
		-- (a bullet that stays inside stops somewhere on that line: where, Z-City does not say. Its
		-- trace met every box counted here, so the whole line is taken, as the zone model does)
		local far = entry + dir * ((ev.track or 0) / 2.54 + CA.trackSkin)
		ev.trackA, ev.trackB = Atlas(entry), Atlas(far)
	elseif tr and tr.skull > 0 then
		ev.pen = E.Pen.TANGENTIAL
	else
		ev.pen = E.Pen.GRAZE
	end
	ev.armorFirst = tr and tr.armor > 0 or false
	local was = pre[org]
	if was and SysTime() - was.rt < 0.05 and was.awake then ev.awake = was.awake end

	-- Who decides what a bullet in the brain does. Z-City's own input for its brain box has just
	-- run: it adds three times the damage to its brain value, which a pistol round takes to the top
	-- of the scale, and at the end of this same damage call its organism think kills at 0.7. Left
	-- alone, every bullet that meets the brain box is an instant death and nothing of this module is
	-- ever seen (docs/NEUROTRAUMA_TRAUMA_CHAIN.md). With the takeover on, the model decides instead:
	--   unsurvivable at once   Z-City's value stands and Z-City kills, as before
	--   anything else          Z-City's brain value is put back to what it was before this hit.
	--                          Everything else Z-City did stays (consciousness gone, shock, pain,
	--                          the attacker's harm, the blood): the character drops on the spot.
	--                          The event that follows raises the value again to what the injury is.
	--
	-- With neuro_headshot_rules on (the default) the decision is not the model's but a rule of the
	-- game, asked for as one:
	--   the first bullet in the brain of a life   is survived at first, whatever its track
	--   a second one                              is death, in this same call, with no arrest before it
	--   a rifle round (the explosive class)       is survived for a fall, then about four seconds of
	--                                             cardiac arrest, then death (sv_trauma.lua)
	-- Pellets and the continuation of one bullet arrive in one tick and are one wound (above).
	ev.dirWorld = dir
	if brain and was and was.brain and owner:Alive() and Z.Takeover() and NT.Enabled() and not I.muted then
		B.Evaluate(ev)
		ev.zcityBrain = tonumber(org.brain)
		if C.sv.headshot:GetBool() then
			local n = (owner.NT_headWounds or 0) + 1
			owner.NT_headWounds = n
			ev.headWound = n
			if n >= 2 then
				ev.fatal = string.format("rule: wound %d of the head in this life", n)
				-- (so that Z-City's own think kills in this call, whatever this bullet's damage was)
				org.brain = math.max(tonumber(org.brain) or 0, 1)
			else
				local sv = NT.Anatomy and NT.Anatomy.SurveyEvent(ev) or nil
				ev.terminal = sv ~= nil and sv.e >= C.Load.shotExplosive or nil
			end
		else
			ev.fatal = NT.Brain and NT.Brain.Triage and NT.Brain.Triage(org, ev) or nil
		end
		if not ev.fatal then
			org.brain = was.brain
			ev.restored = true
		end
		I.triaged = (I.triaged or 0) + 1
		shots[org] = { tick = tick, brainHit = true, brain = tonumber(org.brain), skull = tonumber(org.skull) }
		if NT.TestLog then
			NT.TestLog("  triage #%d %s: Z-City had written brain %.3f (before the hit %.3f) -> %s", ev.id, owner:Nick(), ev.zcityBrain or -1, was.brain,
				ev.fatal and ("left to stand: " .. ev.fatal) or (ev.terminal and "taken back; rule: a rifle round, a fall, an arrest, then death")
					or (ev.headWound and "taken back; rule: the first wound of the head is survived at first") or "taken back; the model decides")
		end
	end
	-- CTakeDamageInfo is only valid inside the hook; the event is complete, emit it next tick so
	-- that every listener of this damage call has run
	timer.Simple(0, function()
		if IsValid(owner) then I.Emit(ev) end
	end)
end)

-- (the count of head wounds is of one life. Z-City gets a player up from its ragdoll by spawning
-- them anew, with its hook "Fake Up" first, in the same call: that is the same life, and the count
-- stays.)
local gotUp = setmetatable({}, { __mode = "k" })
hook.Add("Fake Up", "NT_HeadWounds", function(ply) if IsValid(ply) then gotUp[ply] = engine.TickCount() end end)
hook.Add("PlayerSpawn", "NT_HeadWounds", function(ply)
	if gotUp[ply] and engine.TickCount() - gotUp[ply] <= 1 then return end
	ply.NT_headWounds = nil
end)

------------------------------------------------------------------------------------------
-- Blows, blasts: estimated from the damage Z-City books
------------------------------------------------------------------------------------------
local BLUNT = bit.bor(DMG_CLUB, DMG_CRUSH, DMG_VEHICLE)
local blastEvents = setmetatable({}, { __mode = "k" })   -- organism -> the event of the explosion of this tick

hook.Add("HomigradDamage", "NT_Damage", function(ply, dmgInfo, hitgroup, ent)
	if not enabled or not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	local org = ply.organism
	if not istable(org) then return end
	local hit = pre[org]
	pre[org] = nil
	if not hit or SysTime() - hit.rt > 0.05 then return end
	local dtype = hit.dtype
	local blast = bit.band(dtype, DMG_BLAST) ~= 0
	local blunt = bit.band(dtype, BLUNT) ~= 0
	if not blast and not (blunt and hitgroup == HITGROUP_HEAD) then return end
	local body = IsValid(ent) and ent or ply
	-- (a ragdoll struck by a physical object: the collision itself is measured above)
	if blunt and not blast and body ~= ply and bit.band(dtype, DMG_CLUB) == 0 then return end
	local centre, up, face, left = Z.HeadFrame(body)
	if not centre then return end
	local damage = hit.damage
	if damage <= 0 then return end
	local b = C.Biomech

	-- (the same explosion again, see above: one event, of the strongest pass)
	local tick = engine.TickCount()
	local seen = blast and blastEvents[org]
	if seen and seen.tick == tick then
		seen.n = seen.n + 1
		if damage > seen.ev.damage then
			seen.ev.damage = damage
			seen.ev.dist = (hit.pos - centre):Length() * M
		end
		return
	end

	local ev = New(ply, org, body, blast and Mech.BLAST or Mech.BLUNT)
	ev.damage = damage
	-- A blow of the free-hand module. Whether it shakes a player, puts them down or puts them
	-- out is decided there, from the blow's own impulse, and never by lot; here it leaves only
	-- what it does to the brain for good. So the event carries no knockout and no daze of its
	-- own (BR.Apply), and its seed is a fixed one: what is otherwise drawn (whether a bleed
	-- begins, how fast it grows) is then the same for the same blow, a line and not a chance.
	if hit.freehand then
		ev.owned = true
		ev.seed = 20241
	end
	ev.shield = Z.HeadShield(ply)
	ev.awake = Z.Consciousness(org)
	local force = hit.force
	local pos = hit.pos
	if blast then
		-- (the pressure wave has no point of impact; what the thrown body hits is measured later)
		ev.dist = (pos - centre):Length() * M
	else
		local fdir = force:LengthSqr() > 1 and force:GetNormalized() or nil
		local r = pos - centre
		local rl = r:Length()
		if fdir and rl > 0.01 then
			local rn = r / rl
			ev.region, ev.lat = B.Region(rn, up, face, left)
			ev.hit = { rn:Dot(left), rn:Dot(face), rn:Dot(up) }
			-- the part of the blow that goes through the centre stops against the skull; the rest
			-- turns the head about the neck
			local central = math.abs(fdir:Dot(rn))
			ev.dv = damage * b.bluntDvPerDamage
			ev.dvn = ev.dv * central
			ev.closing = ev.dv
			ev.obliq = math.deg(math.acos(math.Clamp(central, 0, 1)))
			local neck = body:GetBonePosition(body:LookupBone("ValveBiped.Bip01_Head1"))
			local arm = ((pos - neck) * M):Cross(fdir)
			local dw = arm * (ev.dv / (b.bluntLever * b.bluntLever))
			ev.dOmega = dw:Length()
			ev.sag, ev.cor, ev.ax = B.SplitRotation(dw, up, face, left)
		end
	end
	if blast then blastEvents[org] = { tick = tick, ev = ev, n = 1 } end
	timer.Simple(0, function()
		if blast then
			local seen, first = blastEvents[org], blasts[org]
			if seen and seen.ev == ev then
				ev.passes = seen.n
				blastEvents[org] = nil
			end
			if NT.TestLog and first and first.tick == tick then
				NT.TestLog("  one explosion reached %s as %d damage calls: counted once (Z-City's brain value %.3f after the first, what the repeats added was taken back, at most %.3f at a time)",
					IsValid(ply) and ply:Nick() or "?", first.n, first.brain or 0, first.undone)
			end
		end
		if IsValid(ply) then I.Emit(ev) end
	end)
end)

------------------------------------------------------------------------------------------
-- A hard landing on the feet: the body is stopped through the legs, the head is not struck.
-- (What happens once Z-City drops the character into a ragdoll is measured above.)
------------------------------------------------------------------------------------------
hook.Add("OnPlayerHitGround", "NT_Landing", function(ply, inWater, onFloater, speed)
	if not enabled or inWater or speed < 400 then return end
	local org = ply.organism
	if not istable(org) or not ply:Alive() then return end
	local ev = New(ply, org, ply, Mech.FALL)
	ev.landing = speed * M
	ev.awake = Z.Consciousness(org)
	ev.shield = Z.HeadShield(ply)
	I.Emit(ev)
end)
