-- Server: where a record of a bone comes from. Z-City decides how badly a region of a character
-- is hurt and everything that follows from it in play; the brain module decides what a blow to the
-- head does. This file watches both and says which bone it was. It writes nothing to either and
-- returns nothing from their hooks.
--
-- Z-City keeps one number for each of eleven regions (0 intact .. 1 broken: lleg rleg larm rarm
-- spine1 spine2 spine3 skull jaw chest pelvis), five dislocation flags and five amputation flags,
-- and traces a bullet, a blade or a club through boxes that stand for those regions:
--   * while it traces (its hook PreTraceOrganBulletDamage, once for each box entered), the path is
--     put to the registry's bones of that region (SK.Trace): the bone the path crosses, or failing
--     that the nearest, is remembered as where this hit landed;
--   * a moment later the region's number is looked at again. Only if Z-City has raised it is there
--     an injury, and it is booked on that bone, as bad as Z-City's own number says and no worse;
--   * a number that rises with no hit to place it (a blast, a fall, the admin menu) is kept as the
--     region's, with no bone named; one that heals takes the records made from it back with it.
-- The brain module tells of a skull fracture itself (its hook NT_Injured): the bone is the one the
-- blow's direction meets on the skull.

local SK = HemoSkeleton
local C, I, RC = SK.Config, SK.Injury, SK.Records
local S, FL, CZ = C.State, C.Flag, C.ZCity
SK.ZC = SK.ZC or {}
local Z = SK.ZC

local function Log(...) if ABL and ABL.TestLog then ABL.TestLog(...) end end

------------------------------------------------------------------------------------------
-- Z-City's boxes as bones of the registry
------------------------------------------------------------------------------------------
local function List(prefix, from, to, suffix)
	local out = {}
	for n = from, to do out[#out + 1] = prefix .. n .. (suffix or "") end
	return out
end
local function Join(...)
	local out = {}
	for _, l in ipairs({ ... }) do for _, id in ipairs(l) do out[#out + 1] = id end end
	return out
end
local skull = {}
for id in pairs(SK.Proxy.shellBones) do skull[#skull + 1] = id end
table.sort(skull)

-- box name -> the region's number in the organism, the bones it stands for
Z.BOX = {
	skull = { field = "skull", bones = skull },
	jaw = { field = "jaw", bones = { "mandible" } },
	spine3 = { field = "spine3", bones = List("c", 1, 7) },
	spine2 = { field = "spine2", bones = List("t", 1, 12) },
	spine1 = { field = "spine1", bones = List("l", 1, 5) },
	chest = { field = "chest", bones = Join(List("rib", 1, 12, "_l"), List("rib", 1, 12, "_r"), { "sternum" }) },
	pelvis = { field = "pelvis", bones = { "hip_l", "hip_r", "sacrum", "coccyx" } },
}
for _, s in ipairs({ "l", "r" }) do
	Z.BOX[s .. "armup"] = { field = s .. "arm", bones = { "humerus_" .. s } }
	Z.BOX[s .. "armdown"] = { field = s .. "arm", bones = { "radius_" .. s, "ulna_" .. s } }
	Z.BOX[s .. "legup"] = { field = s .. "leg", bones = { "femur_" .. s, "patella_" .. s } }
	Z.BOX[s .. "legdown"] = { field = s .. "leg", bones = { "tibia_" .. s, "fibula_" .. s, "patella_" .. s } }
end
Z.FIELDS = { "lleg", "rleg", "larm", "rarm", "spine1", "spine2", "spine3", "skull", "jaw", "chest", "pelvis" }
-- a dislocation flag as a joint (Z-City does not say which; the one its own words name first)
Z.DISLOCATION = { llegdislocation = "knee_l", rlegdislocation = "knee_r", larmdislocation = "glenohumeral_l", rarmdislocation = "glenohumeral_r", jawdislocation = { "tmj_l", "tmj_r" } }
-- an amputation flag as the bones that are gone (Z-City shows it by scaling the forearm, the calf
-- or the head bone to nothing: what hangs on that and beyond)
Z.AMPUTATION = {}
for _, s in ipairs({ "l", "r" }) do
	Z.AMPUTATION[s .. "armamputated"] = Join({ "radius_" .. s, "ulna_" .. s }, SK.BonesOf("hand_" .. s))
	Z.AMPUTATION[s .. "legamputated"] = Join({ "tibia_" .. s, "fibula_" .. s }, SK.BonesOf("foot_" .. s))
end
Z.AMPUTATION.headamputated = SK.BonesOf("skull")

function Z.Present() return istable(hg) and istable(hg.organism) end

-- Z-City's number as a state.
function Z.StateFor(v)
	if v >= CZ.fractureAt then return S.FRACTURE end
	if v >= CZ.fissureAt then return S.FISSURE end
	if v >= CZ.bruiseAt then return S.BRUISED end
	return S.INTACT
end

------------------------------------------------------------------------------------------
-- A hit that Z-City is tracing
------------------------------------------------------------------------------------------
local hitEnt = setmetatable({}, { __mode = "k" })     -- organism -> the entity being hit, this damage call
local pending = setmetatable({}, { __mode = "k" })    -- organism -> { [field] = { bone, approx, pre, t, site, at } }
local warned = false
Z.stats = { located = 0, crossed = 0, nearest = 0, booked = 0, unbooked = 0, regions = 0 }

hook.Add("PreHomigradDamage", "SK_ZCity", function(ply, dmgInfo, hitgroup, ent)
	local org = IsValid(ent) and ent.organism
	if istable(org) then hitEnt[org] = { ent = ent, rt = SysTime() } end
end)

-- Where along a bone's long axis a place is (0..1 as the data has the axis), for a record.
local function SiteOn(pose, id, wx, wy, wz)
	local st = SK.Stock.bones[id]
	local inv = st.ax and pose:BoneInv(id)
	if not inv then return nil end
	local x, y, z = SK.M.Xf(inv, wx, wy, wz)
	local d = (x - st.c[1]) * st.ax[1] + (y - st.c[2]) * st.ax[2] + (z - st.c[3]) * st.ax[3]
	return math.Clamp(0.5 + d / (2 * math.max(st.len, 0.01)), 0, 1)
end

local function Located(org, organ, box, dir, hit)
	local def = Z.BOX[organ[1]]
	if not def then return end
	-- the entity: the one Z-City is hitting now, else the organism's owner's body
	local he = hitEnt[org]
	local ent = he and SysTime() - he.rt < 0.05 and he.ent or nil
	if not IsValid(ent) then ent = IsValid(org.owner) and SK.BodyOf(org.owner) or nil end
	if not IsValid(ent) then return end
	local pose = SK.PoseOf(ent)
	if not pose then return end
	-- the path through this box: from where the ray meets it (the hook's own point is where this
	-- step of Z-City's trace began, not where the box was entered), as far as the box is long
	local d = Vector(dir)
	if d:LengthSqr() < 1e-8 then return end
	d:Normalize()
	local entry = util.IntersectRayWithOBB(hit, d * 400, box[1], box[2], box[3], box[4]) or hit
	local reach = (box[4] - box[3]):Length()
	local a, b = entry - d * 0.3, entry + d * reach
	Z.stats.located = Z.stats.located + 1
	local hits = SK.Trace(pose, a, b, { bones = def.bones })
	local h = hits and hits[1]
	local id, approx = h and h.id, false
	if id then
		Z.stats.crossed = Z.stats.crossed + 1
	else
		id = SK.Nearest(pose, a, b, def.bones)
		-- (the skull has no solids: a path that passes it by takes the bone its direction from the brain's centre meets)
		if not id and def.field == "skull" then
			local inv = pose:Skin("head") and SK.M.Inv(pose:Skin("head"))
			if inv then
				local x, y, z = SK.M.Xf(inv, entry.x, entry.y, entry.z)
				id = SK.Cranial.FromDir(SK.Cranial.ToHead(x, y, z))
			end
		end
		approx = true
		if id then Z.stats.nearest = Z.stats.nearest + 1 end
	end
	if not id then return end
	local at = h and (a + (b - a) * h.tIn) or entry
	local p = pending[org]
	if not p then p = {} pending[org] = p end
	-- (one bullet may enter several boxes of one region: the first bone met stands)
	if not p[def.field] or (p[def.field].approx and not approx) then
		p[def.field] = { bone = id, approx = approx, pre = tonumber(org[def.field]) or 0, t = CurTime(), site = SiteOn(pose, id, at.x, at.y, at.z), box = organ[1], ent = ent }
	end
end

hook.Add("PreTraceOrganBulletDamage", "SK_ZCity", function(org, boneMul, dmg, dmgInfo, box, dir, hit, ricochet, organ)
	if not C.sv.zcity:GetBool() or not SK.Enabled() then return end
	if not istable(org) or not istable(organ) or not istable(box) or not isvector(dir) or not isvector(hit) then return end
	if not isstring(organ[1]) or not Z.BOX[organ[1]] then return end
	-- (an error here would stop Z-City's own damage call half way: nothing of this may reach it)
	local ok, err = pcall(Located, org, organ, box, dir, hit)
	if not ok and not warned then
		warned = true
		SK.Print("could not place a hit: %s", tostring(err))
	end
end)

------------------------------------------------------------------------------------------
-- What Z-City's numbers say now, against what they said
------------------------------------------------------------------------------------------
local last = setmetatable({}, { __mode = "k" })       -- organism -> { [field or flag] = value, t }

local function Owner(org)
	local o = org.owner
	if not IsValid(o) then return nil end
	return o
end

-- The records made from a region's number never say more than that number does, and go when it
-- has healed.
local function Reconcile(char, field, v)
	local rec = RC.byChar[char]
	if not rec then return end
	local cap = Z.StateFor(v)
	for idx, e in pairs(rec.bones) do
		if e.src == "zcity" and e.cause and e.cause.field == field and e.state ~= S.LOST and e.state > cap then
			local id = SK.BoneByIdx[idx].id
			if cap == S.INTACT then I.Clear(char, id, "zcity")
			else I.Set(char, id, { state = cap, site = e.site, flags = e.flags, cause = e.cause }, "zcity") end
		end
	end
end

local function Look(org)
	local owner = Owner(org)
	if not owner then return end
	local body = owner:IsPlayer() and SK.BodyOf(owner) or owner
	local char = RC.CharOf(body)
	if not char then return end
	local was = last[org]
	if not was then was = {} last[org] = was end
	local p = pending[org]
	local now = CurTime()
	for _, field in ipairs(Z.FIELDS) do
		local v = tonumber(org[field]) or 0
		local pe = p and p[field]
		-- (against what it was when the hit was placed, when one was; else against the last look)
		local old = pe and math.min(pe.pre, was[field] or pe.pre) or (was[field] or 0)
		if v ~= old or v ~= (was[field] or 0) then
			was[field] = v
			if v > old + 1e-6 then
				if pe and now - pe.t <= CZ.pendingFor + 1 then
					-- an injury Z-City has booked, at the place the hit was found to land
					local state = Z.StateFor(v)
					if state > S.INTACT then
						local e = I.Of(char, pe.bone)
						if not e or e.state <= state then
							I.Set(char, pe.bone, { state = state, site = pe.site, flags = pe.approx and FL.APPROX or 0,
								cause = { kind = "hit", field = field, box = pe.box, value = v } }, "zcity")
							Z.stats.booked = Z.stats.booked + 1
							Log("  skeleton: %s of %s: %s (Z-City's %s %.2f -> %.2f%s)", pe.bone, tostring(char), C.StateName[state], field, old, v, pe.approx and ", nearest bone" or "")
						end
					end
				else
					-- no hit to place it: the region's own number, no bone named
					Z.stats.regions = Z.stats.regions + 1
				end
			end
			if p then p[field] = nil end
			-- (what is left of the region's number that no record of a bone accounts for)
			I.SetRegion(char, field, v >= CZ.bruiseAt and v or nil)
			if v < old then Reconcile(char, field, v) end
		elseif pe and now - pe.t > CZ.pendingFor then
			-- the hit was placed, but Z-City booked nothing for it: no injury
			p[field] = nil
			Z.stats.unbooked = Z.stats.unbooked + 1
		end
	end
	for flag, joint in pairs(Z.DISLOCATION) do
		local v = org[flag] and true or false
		if v ~= (was[flag] or false) then
			was[flag] = v
			for _, j in ipairs(istable(joint) and joint or { joint }) do
				I.SetJoint(char, j, v and C.JointState.DISLOCATED or C.JointState.SOUND, "zcity")
			end
		end
	end
	for flag, bones in pairs(Z.AMPUTATION) do
		local v = org[flag] and true or false
		if v ~= (was[flag] or false) then
			was[flag] = v
			if v then
				local rec = RC.byChar[char]
				for _, id in ipairs(bones) do
					-- (within what one character may carry: the long bones first, they come first in the list)
					if not rec or rec.n < C.Records.perChar then I.Set(char, id, { state = S.LOST, integrity = 0, cause = { kind = "amputation", flag = flag } }, "zcity") end
					rec = RC.byChar[char]
				end
			end
		end
	end
end

-- Z-City thinks for every organism every tick; a look at its numbers is taken a few times a
-- second, and at once when a hit is waiting to be booked.
local nextLook = setmetatable({}, { __mode = "k" })
hook.Add("Org Think", "SK_ZCity", function(owner, org)
	if not istable(org) or not C.sv.zcity:GetBool() or not SK.Enabled() then return end
	local now = CurTime()
	if (nextLook[org] or 0) > now and not pending[org] then return end
	nextLook[org] = now + CZ.watch
	local ok, err = pcall(Look, org)
	if not ok and not warned then
		warned = true
		SK.Print("could not read Z-City's numbers: %s", tostring(err))
	end
	local p = pending[org]
	if p and next(p) == nil then pending[org] = nil end
end)
Z.Look = Look

------------------------------------------------------------------------------------------
-- The brain module: a skull fracture gets a place
------------------------------------------------------------------------------------------
-- The place of a head injury on the skull, from one of the brain module's events: the direction of
-- the blow from the brain's centre (its head frame, which the skull's regions are laid out in), or
-- for a bullet where its track begins. Returns bone id, side, face, up; or nil.
function Z.SkullSite(ev)
	local CR = SK.Cranial
	if istable(ev.hit) then return CR.FromDir(ev.hit[1], ev.hit[2], ev.hit[3]) end
	if istable(ev.trackA) and istable(NeuroTrauma) then
		local A = NeuroTrauma.Config.Anatomy
		return CR.FromDir(ev.trackA[1] * A.headX, ev.trackA[2] * A.headY, ev.trackA[3] * A.headZ)
	end
	return nil
end

hook.Add("NT_Injured", "SK_Skull", function(ply, org, st, ev, L)
	if not SK.Enabled() or not istable(L) or not istable(ev) then return end
	local f = tonumber(L.fracture) or 0
	if f <= 0 or not IsValid(ply) then return end
	local ok, err = pcall(function()
		local id, sx, sy, sz = Z.SkullSite(ev)
		if not id then return end
		local state = f >= 0.95 and S.COMMINUTED or (f >= 0.5 and S.FRACTURE or S.FISSURE)
		local was = I.Of(ply, id)
		if was and was.state > state then return end
		I.Set(ply, id, { state = state, integrity = math.floor(255 * (1 - f * 0.8)), at = { sx, sy, sz },
			cause = { kind = "brain", event = ev.id, seed = ev.seed, fracture = f } }, "brain")
		Log("  skeleton: skull fracture %.2f of %s on the %s at side %.1f face %.1f up %.1f (the brain module's event #%s)", f, tostring(ply), id, sx, sy, sz, tostring(ev.id))
	end)
	if not ok and not warned then
		warned = true
		SK.Print("could not place a skull fracture: %s", tostring(err))
	end
end)

-- Where a character's skull is broken, for the brain module or anything else that asks: the worst
-- record among the skull's bones as { bone, state, at = { side, face, up } }, or nil.
function SK.Skull(who)
	local rec = I.Get(who)
	if not rec then return nil end
	local best
	for _, id in ipairs(SK.BonesOf("skull")) do
		local e = rec.bones[SK.Bones[id].idx]
		if e and e.state ~= S.LOST and (not best or e.state > best.state) then best = { bone = id, state = e.state, at = e.at, t = e.t } end
	end
	return best
end

-- The highest vertebra with a record, and how bad: what a cord injury would be read from. Returns
-- id, state, the level (cervical, thoracic, lumbar); or nil.
function SK.SpineLevel(who)
	local rec = I.Get(who)
	if not rec then return nil end
	for _, id in ipairs(SK.BonesOf("column")) do
		local e = rec.bones[SK.Bones[id].idx]
		if e and e.state >= S.FISSURE then return id, e.state, SK.Bones[id].group end
	end
	return nil
end
