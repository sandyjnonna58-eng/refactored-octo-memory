-- Impact stains on the world: floors, and since phase 36 walls and ceilings too (the name is
-- from when it was floors only).
-- A droplet that lands on a world surface leaves a stain drawn by ABL itself (not an engine
-- decal), so the number of these stains is strictly capped and the oldest are removed.
-- The stain comes from the impact:
--   * class from drop size, splash parameter K and impact angle: tiny spot, normal drop (smoother
--     to more scalloped as K rises), large impact with spines and satellites, elongated glancing
--     stain along the direction of travel, or a soaked stain on absorbent floors,
--   * size from the physical stain diameter (drop volume and spread at that impact speed),
--   * orientation: along the travel direction for glancing impacts, random otherwise.
-- Each stain lies in the surface plane at the impact point, a hair above it. Its footprint is
-- checked against the floor with short traces (no hanging over ledges, no floating over bumps);
-- if it does not fit it is shrunk. Variant, size, rotation, mirroring, opacity and tone vary per
-- stain, and variants are drawn from shuffled bags, so neighbouring stains never repeat.
-- Stains are batched into a few static meshes per area. Their colour ages from fresh and wet
-- (with a view-dependent reflection) to dried brown. Nothing here creates entities.
--
-- The body (phase 36). A stain is what a drop left, and the drop's blood is still there: it
-- stands on the stain's foot as a small volume of liquid. Its height is its volume over its
-- foot, and it meets the floor at its contact angle: a drop set down gently is a cap 0.6 of
-- its radius high, a drop that hit hard was spread wide and is a flat layer with a rounded
-- edge, no higher than blood stands (3.8 mm: more lies wider, flat on top). That volume is
-- drawn: a low dome of a few dozen triangles over the stain's main body,
-- in the blood's own colour under the light of the place, opaque where the layer is deep and
-- letting the stained floor through where it thins out at the edge (the painted outline cuts
-- it: the dome has the stain's irregular foot). As it dries it sinks to a fifth and darkens.
-- Thickness is geometry and volume, not a texture.
--
-- The mirror. Wet blood mirrors what is around it: as much of it as Fresnel's reflectance at
-- the angle of view (2 % from above, more the lower the eye), in the place of that much of the
-- blood's own colour. What is mirrored is the map's own cubemap of the place, looked up by the
-- way the floor faces: a pale even tone of the sky over the stain, stronger the lower the eye.
-- (A drop in the air mirrors the same cubemap by the way each place of its own surface faces:
-- cl_droplets.lua.) A stain loses its mirror as it dries. On a map without cubemaps: a faint
-- pattern sheen instead.
--
-- The highlight. The key light (the sun where it reaches the place, else the light from above)
-- is not in a cubemap. The bodies get it from the engine's own lit material: a highlight worked
-- out for every pixel from the way the surface faces there. A cap carries it as a patch, a
-- flat layer on its top when the eye is near the light's mirror angle and otherwise along the
-- part of its rounded edge that faces between eye and light. A body sets from its edge
-- inward, and the highlight goes with the liquid: it draws back to the middle and is gone
-- when the body has set. A film too thin for a body has the same highlight on its level top.
--
-- What it costs. A chunk's stains are two meshes of quads (the filter, and the mirror of what
-- is wet: level, a body's own slopes are too low to change what so faint a mirror shows). The
-- bodies and their highlight are kept apart from it in batches of about twelve drops, two
-- small meshes each: a new drop, or the stains' drying, builds a batch again (a thousand
-- vertices), not the chunk's; one batch in a frame, seldom two, and fewer while the load
-- governor has the effects scaled down (the stains right at the eye are not kept waiting).
-- Bodies are built for chunks near the eye only, the smallest for the nearest only.

ABL.NoJIT()
ABL.Ground = ABL.Ground or {}
local G = ABL.Ground
local C, L, M = ABL.Config, ABL.LOD, ABL.Mat
local GC = C.Ground
local sqrt, min, max, abs, floor, cos, sin = math.sqrt, math.min, math.max, math.abs, math.floor, math.cos, math.sin

------------------------------------------------------------------------------------------
-- Atlas (tools/texgen: 8x4 cells of 256 px with a 6 px margin, 2048x1024)
------------------------------------------------------------------------------------------
local function CellUV(i)
	local cx, cy = i % 8, floor(i / 8)
	local mu, mv = 6 / 2048, 6 / 1024
	return cx / 8 + mu, cy / 4 + mv, (cx + 1) / 8 - mu, (cy + 1) / 4 - mv
end

-- frac: radius of the main stain in cell half-widths (elongated: half-width of the main ellipse);
-- reach: how far (in half-widths) its satellites / tail extend, for the footprint check
local FAM = {
	tiny   = { first = 0, n = 8, frac = 0.30, reach = 0.45 },
	drop   = { first = 8, n = 8, frac = 0.53, reach = 0.62 },
	splat  = { first = 16, n = 8, frac = 0.34, reach = 0.8 },
	elong  = { first = 24, n = 3, frac = 0.40 / 1.85, ratio = 1.85, reach = 0.8, shift = 0.28 },
	elong2 = { first = 27, n = 2, frac = 0.40 / 3.0, ratio = 3.0, reach = 0.8, shift = 0.28 },
	soak   = { first = 29, n = 3, frac = 0.52, reach = 0.6 },
}

-- Shuffled bag per family: every variant is used once before any repeats, never twice in a row.
local bags = {}
local function Variant(name, rng, lo, hi)
	local f = FAM[name]
	lo, hi = lo or 0, hi or (f.n - 1)
	local key = name .. lo .. ":" .. hi
	local bag = bags[key]
	if not bag or #bag.list == 0 then
		local list = {}
		for i = lo, hi do list[#list + 1] = i end
		for i = #list, 2, -1 do
			local j = 1 + floor(rng:Next() * i)
			list[i], list[j] = list[j], list[i]
		end
		if bag and #list > 1 and list[#list] == bag.last then list[1], list[#list] = list[#list], list[1] end
		bag = { list = list, last = bag and bag.last }
		bags[key] = bag
	end
	local v = table.remove(bag.list)
	bag.last = v
	return f.first + v
end

------------------------------------------------------------------------------------------
-- Stains, chunks, cap
------------------------------------------------------------------------------------------
-- How high the liquid of a stain stands on a foot with half-axes ba, bl (units), and how flat
-- its top is (p: 2 a cap, more a mesa). vol in ml.
local function BodyHeight(vol, ba, bl)
	local V = vol / C.ML_PER_CU
	local a = min(ba, bl)
	local mean = V / (3.14159 * ba * bl)    -- its height if it lay level
	-- The profile 1 - r^p holds p / (p + 2) of its height times its foot, and its slope at the
	-- edge is p times its height over its radius. With the edge at the contact angle: little
	-- blood on a wide foot is a flat layer with a rounded edge (p large), more is a cap (p = 2).
	local p = math.Clamp(GC.contactTan * a / mean - 2, 2, GC.edgeMax)
	local hc = mean * (p + 2) / p
	local top = min(GC.capAspect * a, GC.capHigh)
	if hc > top then
		-- more than a cap on that foot holds: as high as blood stands, and flat on top
		local fill = min(mean / top, 0.75)
		hc = top
		p = max(2, 2 * fill / (1 - fill))
	end
	return hc, p
end

local chunks = {}          -- all chunks (draw order)
local open = {}            -- spatial key -> chunk that still accepts stains
local count = 0            -- live stains
local fifo, head, tail = {}, 1, 0
local crowd = {}           -- 2.5-unit cell -> { n, last, t } (many drops on one spot)
local CHUNK_SIZE, CHUNK_MAX = 192, 96
G.stats = { placed = 0, removed = 0, shrunk = 0, merged = 0, skipped = 0, capped = 0 }

-- Stains by the character whose blood they are (phase 46). One character's blood keeps no more
-- than abl_max_ground_stains_per_body stains: over it its own oldest go first. So a body that
-- bleeds hard does not use up the cap of all and wipe out the stains of everybody else.
local owned = setmetatable({}, { __mode = "k" })   -- character -> { n = its live stains, list, head, tail }

function G.Count() return count end
function G.CountFor(who) local o = owned[who] return o and o.n or 0 end

-- (developer, the tests) The stains within r units of a place: how many, how many of them still carry
-- a body of liquid, what those bodies hold (ml), and how many of those bodies `inside(x, y, z)` says
-- lie where something else shows that liquid too (a pool over them).
function G.BodiesNear(x, y, z, r, inside)
	local n, nb, vol, under = 0, 0, 0, 0
	for _, c in ipairs(chunks) do
		for _, s in ipairs(c.items) do
			if not s.dead and (s.x - x) ^ 2 + (s.y - y) ^ 2 + (s.z - z) ^ 2 < r * r then
				n = n + 1
				if s.hc and (s.bvol or 0) > 0 then
					nb, vol = nb + 1, vol + s.bvol
					if inside and inside(s.bx or s.x, s.by or s.y, s.bz or s.z) then under = under + 1 end
				end
			end
		end
	end
	return n, nb, vol, under
end

-- (a chunk holds stains of one place that face one way: its mirror and its highlight are worked
-- out for the way the chunk faces, and a floor and the wall beside it face differently)
local function Chunk(x, y, z, nx, ny, nz)
	local ax, ay, az = abs(nx), abs(ny), abs(nz)
	local face = (az >= ax and az >= ay) and (nz > 0 and 0 or 1) or ((ax >= ay) and (nx > 0 and 2 or 3) or (ny > 0 and 4 or 5))
	local key = ABL.CellKey(x, y, z, CHUNK_SIZE) * 8 + face
	local c = open[key]
	if not c or #c.items >= CHUNK_MAX then
		c = { key = key, items = {}, live = 0, mesh = nil, sheen = nil, rel = {}, withBody = false, withSmall = false, dirty = true,
			nextBuild = 0, nextAge = 0, keyT = 0, x = x, y = y, z = z, rad = 1, nx = 0, ny = 0, nz = 1, youngest = 0 }
		open[key] = c
		chunks[#chunks + 1] = c
	end
	return c
end

-- Batches of relief: the bodies of a few stains of a chunk (their own colour, their mirror, their
-- highlight) as three small meshes. A stain is in one batch from its placing to its end.
local function FreeBatch(b)
	if b.body then b.body:Destroy() b.body = nil end
	if b.gloss then b.gloss:Destroy() b.gloss = nil end
end
-- The rings of a stain's liquid around its middle (a film: one, a wide film two; a body: two,
-- a large one three), and its quads (the middle as a fan of quads, a band a ring more).
local function Rings(s)
	if s.thin then return s.wide and 2 or 1 end
	return s.bn == 14 and 3 or 2
end
local function BodyQuads(s) return s.bn / 2 + s.bn * (Rings(s) - 1) end

local function Attach(c, s)
	-- (what it weighs: its quads; a film has the highlight's only)
	local w = BodyQuads(s) * (s.thin and 1 or 2)
	local b = c.relOpen
	if not b or b.w + w > GC.reliefLoad or #b.items >= GC.reliefMost then
		b = { items = {}, w = 0, dirty = true, nextAge = 0 }
		c.rel[#c.rel + 1] = b
		c.relOpen = b
	end
	b.items[#b.items + 1] = s
	b.w = b.w + w
	b.dirty = true
	s.rb, s.rbw = b, w
end
local function Detach(s)
	local b = s.rb
	if not b then return end
	s.rb = nil
	local items = b.items
	for i = 1, #items do
		if items[i] == s then table.remove(items, i) break end
	end
	b.w = b.w - s.rbw
	b.dirty = true
	if #items == 0 then
		FreeBatch(b)
		local c = s.chunk
		for i = 1, #c.rel do
			if c.rel[i] == b then table.remove(c.rel, i) break end
		end
		if c.relOpen == b then c.relOpen = nil end
	end
end

local function Kill(s)
	if s.dead then return end
	s.dead = true
	count = count - 1
	local c = s.chunk
	c.live = c.live - 1
	c.dirty = true
	Detach(s)
	local o = s.owner ~= nil and owned[s.owner]
	if o then o.n = o.n - 1 end
	G.stats.removed = G.stats.removed + 1
end

-- Over the cap: remove the oldest, preferring one that is out of view among the oldest few.
local function RemoveOldest()
	while head <= tail and (fifo[head] == nil or fifo[head].dead) do fifo[head] = nil head = head + 1 end
	local pick, seen = nil, 0
	for i = head, tail do
		local s = fifo[i]
		if s and not s.dead then
			seen = seen + 1
			pick = pick or s
			local _, vis = L.View(s.x, s.y, s.z, s.h)
			if not vis then pick = s break end
			if seen >= 10 then break end
		end
	end
	if pick then Kill(pick) end
end

-- The oldest stain of one character's blood, by the same rule.
local function OwnOldest(o)
	local list = o.list
	while o.head <= o.tail and (list[o.head] == nil or list[o.head].dead) do list[o.head] = nil o.head = o.head + 1 end
	local pick, seen = nil, 0
	for i = o.head, o.tail do
		local s = list[i]
		if s and not s.dead then
			seen = seen + 1
			pick = pick or s
			local _, vis = L.View(s.x, s.y, s.z, s.h)
			if not vis then pick = s break end
			if seen >= 10 then break end
		end
	end
	return pick
end

-- A character's stains are another's from now on (a player's body became a corpse).
function G.MoveOwner(from, to)
	local o = owned[from]
	if not o or from == to or to == nil then return end
	owned[from] = nil
	local t = owned[to]
	for i = o.head, o.tail do
		local s = o.list[i]
		if s and not s.dead then
			if not t then
				t = { n = 0, list = {}, head = 1, tail = 0 }
				owned[to] = t
			end
			s.owner = to
			t.n = t.n + 1
			t.tail = t.tail + 1
			t.list[t.tail] = s
		end
	end
end

local function Add(s)
	local c = Chunk(s.x, s.y, s.z, s.nx, s.ny, s.nz)
	s.chunk = c
	c.items[#c.items + 1] = s
	c.live = c.live + 1
	c.dirty = true
	if s.hc then Attach(c, s) end
	count = count + 1
	tail = tail + 1
	fifo[tail] = s
	G.stats.placed = G.stats.placed + 1
	local who = s.owner
	if who ~= nil then
		local o = owned[who]
		if not o then
			o = { n = 0, list = {}, head = 1, tail = 0 }
			owned[who] = o
		end
		o.n = o.n + 1
		o.tail = o.tail + 1
		o.list[o.tail] = s
		local most = L.Cap(C.cl.maxGroundBody)
		while o.n > most do
			local old = OwnOldest(o)
			if not old then break end
			Kill(old)
			G.stats.capped = G.stats.capped + 1
		end
	end
	local cap = L.Cap(C.cl.maxGround)
	while count > cap do RemoveOldest() end
end

------------------------------------------------------------------------------------------
-- Footprint check: the stain must lie on the floor it landed on
------------------------------------------------------------------------------------------
local trOut = {}
local tr = { mask = MASK_SOLID, output = trOut, filter = ABL.Surface.ProbeFilter }
local vA, vB = Vector(), Vector()

-- Probes the surface at four points around the stain. Returns ok, highest bump (units above the
-- plane) or nil when out of trace budget.
local function Fits(x, y, z, nx, ny, nz, ux, uy, uz, vx, vy, vz, r)
	local up = 0
	for k = 1, 4 do
		if not L.TakeTrace() then return nil end
		local a = (k == 1 and r) or (k == 2 and -r) or 0
		local b = (k == 3 and r) or (k == 4 and -r) or 0
		local px, py, pz = x + ux * a + vx * b, y + uy * a + vy * b, z + uz * a + vz * b
		vA:SetUnpacked(px + nx, py + ny, pz + nz)
		vB:SetUnpacked(px - nx * 1.2, py - ny * 1.2, pz - nz * 1.2)
		tr.start, tr.endpos = vA, vB
		util.TraceLine(tr)
		if not trOut.Hit or trOut.StartSolid then return false end
		local hn, hp = trOut.HitNormal, trOut.HitPos
		if hn.x * nx + hn.y * ny + hn.z * nz < 0.85 then return false end
		local dev = (hp.x - x) * nx + (hp.y - y) * ny + (hp.z - z) * nz
		if dev > 0.3 or dev < -0.3 then return false end
		if dev > up then up = dev end
	end
	return true, up
end

------------------------------------------------------------------------------------------
-- Placement
------------------------------------------------------------------------------------------
local pending = {}         -- impacts waiting for trace budget
local tokens, lastRefill = 0, 0

local function Place(q)
	local nx, ny, nz = q.nx, q.ny, q.nz
	local f = FAM[q.fam]
	local h, hu = q.h, q.hu
	local ux, uy, uz, vx, vy, vz = q.ux, q.uy, q.uz, q.vx, q.vy, q.vz
	-- centre of the quad (an elongated stain's body sits on the impact point, its tail ahead)
	local shift = (f.shift or 0) * hu
	local cx, cy, cz = q.x + ux * shift, q.y + uy * shift, q.z + uz * shift
	local up = 0
	local reach = max(h * f.frac * 1.1, hu * f.reach)
	if reach > 0.45 then
		local ok, bump = Fits(cx, cy, cz, nx, ny, nz, ux, uy, uz, vx, vy, vz, reach)
		if ok == nil then return false end
		if not ok then
			-- does not fit (a ledge, a step, a bump): a smaller stain around the impact point
			local s = 0.55
			h, hu, reach, shift = h * s, hu * s, reach * s, shift * s
			cx, cy, cz = q.x + ux * shift, q.y + uy * shift, q.z + uz * shift
			G.stats.shrunk = G.stats.shrunk + 1
			if reach > 0.45 then
				ok, bump = Fits(cx, cy, cz, nx, ny, nz, ux, uy, uz, vx, vy, vz, reach)
				if ok == nil then return false end
				if not ok then
					-- right on an edge: only a small spot around the impact point itself
					local k = 0.4 / reach
					h, hu, shift = h * k, hu * k, shift * k
					cx, cy, cz = q.x + ux * shift, q.y + uy * shift, q.z + uz * shift
					bump = 0
					G.stats.skipped = G.stats.skipped + 1
				end
			end
		end
		up = bump or 0
	end
	local u0, v0, u1, v1 = CellUV(q.cell)
	if q.flip then v0, v1 = v1, v0 end
	local off = GC.offset + up + q.jit
	local s = {
		x = cx + nx * off, y = cy + ny * off, z = cz + nz * off, nx = nx, ny = ny, nz = nz,
		ux = ux * hu, uy = uy * hu, uz = uz * hu, vx = vx * h, vy = vy * h, vz = vz * h, h = max(h, hu), h0 = h,
		u0 = u0, v0 = v0, u1 = u1, v1 = v1,
		alpha = q.alpha, tone = q.tone, tg = q.tg, born = CurTime(), dryT = q.dryT, owner = q.owner,
	}
	-- the liquid on its main part (none on a floor that takes the blood up): a body where it
	-- stands high enough, else a film (thin: it has a highlight, no body)
	if q.fam ~= "soak" and (q.vol or 0) > 0 then
		local ba = h * f.frac
		local bl = f.ratio and hu * f.frac * f.ratio or ba
		s.ba, s.bl, s.bvol = ba, bl, q.vol
		s.hc, s.bp = BodyHeight(q.vol, ba, bl)
		s.thin = s.hc < GC.bodyMin
		s.small = max(ba, bl) < GC.bodySmall
		-- (its middle: the impact point, which lies off the quad's middle in a stain with a tail)
		s.bx, s.by, s.bz = s.x - ux * shift, s.y - uy * shift, s.z - uz * shift
		s.bax = -(f.shift or 0)
		s.bhu, s.bhv = hu, h
		-- (more triangles for one that can be seen from close)
		s.wide = max(ba, bl) >= GC.filmWide
		s.bn = s.small and 8 or (((s.thin and s.wide) or (not s.thin and max(ba, bl) >= 0.17)) and 14 or 10)
	end
	Add(s)
	if q.crowd then q.crowd.last = s end
	-- (phase 21: the stain the drop's handle names, G.Impact)
	q.s = s
	return true
end

-- Blood that lands on a spot already covered by several stains adds to them instead of piling
-- up more quads: the newest one there grows a little and is wet again.
local function Crowded(x, y, z, vol)
	local k = ABL.CellKey(x, y, z, 2.5)
	local now = CurTime()
	local e = crowd[k]
	if not e or now - e.t > 30 then
		e = { n = 0, t = now }
		crowd[k] = e
	end
	e.t = now
	if e.n >= GC.cellCap and e.last and not e.last.dead then
		local s = e.last
		local g = min(1.06, s.h0 * 1.5 / s.h)
		if g > 1.001 then
			s.ux, s.uy, s.uz, s.vx, s.vy, s.vz = s.ux * g, s.uy * g, s.uz * g, s.vx * g, s.vy * g, s.vz * g
			s.h = s.h * g
			if s.hc then s.ba, s.bl, s.bhu, s.bhv = s.ba * g, s.bl * g, s.bhu * g, s.bhv * g end
		end
		if s.hc and vol then
			s.bvol = s.bvol + vol
			s.hc, s.bp = BodyHeight(s.bvol, s.ba, s.bl)
			s.thin = s.hc < GC.bodyMin
		end
		if s.rb then s.rb.dirty = true end
		s.born = now
		s.alpha = min(255, s.alpha * 1.04)
		s.chunk.dirty = true
		G.stats.merged = G.stats.merged + 1
		return true, e
	end
	e.n = e.n + 1
	return false, e
end

local function Queue(q)
	if not Place(q) then
		if #pending >= 48 then table.remove(pending, 1) end
		pending[#pending + 1] = q
	end
end

-- A droplet hit a floor-like world surface.
--   vol: ml, stainD: stain diameter (units) for this drop at this impact speed, sinA: impact
--   angle sine, tx..: downstream direction in the surface plane (nil for a vertical impact),
--   K: splash parameter, surf: surface category, rng: seeded RNG, wetT: seconds to dry.
--   bodyVol: what of it stays in the stain (the rest left as secondary drops); vol when not given.
--   owner: the character whose blood it is (an entity), or nil.
function G.Impact(x, y, z, nx, ny, nz, vol, stainD, sinA, tx, ty, tz, K, surf, rng, wetT, bodyVol, owner)
	if owner ~= nil and not IsValid(owner) then owner = nil end
	-- rate limit: a burst of spatter places at most `rate` stains per second
	local rt = RealTime()
	tokens = min(GC.rate * 0.5, tokens + (rt - lastRefill) * GC.rate)
	lastRefill = rt
	if tokens < 1 then return end
	tokens = tokens - 1

	local IC = C.Impact
	local fam, cell
	local R = stainD * 0.5 * rng:Range(0.9, 1.12)
	local elong = 1
	if surf.soak then
		fam = "soak"
	elseif stainD < GC.tinyD or vol < 0.004 then
		fam = "tiny"
	elseif tx and sinA < 0.82 then
		elong = math.Clamp(1 / max(sinA, 0.2), 1.2, 4)
		fam = elong > 2.4 and "elong2" or "elong"
	elseif K > IC.kCrown then
		-- (by how hard it landed alone. Until phase 36 a drop above 0.15 ml got the splash outlines
		-- whatever its speed: half a millilitre set down from a finger's width had spines.)
		fam = "splat"
	else
		fam = "drop"
	end
	if fam == "drop" then
		-- a harder landing crenates the edge: pick among the rougher variants as K rises
		local t = math.Clamp((K - IC.kDeposit) / (IC.kCrown - IC.kDeposit), 0, 1)
		local lo = min(5, floor(t * 5))
		cell = Variant("drop", rng, lo, min(7, lo + 3))
	else
		cell = Variant(fam, rng)
	end

	local crowded, ce = Crowded(x, y, z, bodyVol or vol)
	-- (phase 21: what took this drop's blood on a crowded spot, as its handle, G.Handover)
	if crowded then return { s = ce.last } end

	local f = FAM[fam]
	R = max(R, fam == "tiny" and 0.06 or 0.12)
	local h = R / f.frac
	local hu = h
	if f.ratio then
		-- the texture carries the elongation; a slight stretch matches the exact angle
		hu = h * math.Clamp(elong / f.ratio, 0.87, 1.15)
	end
	if h > GC.maxHalf then hu = hu * GC.maxHalf / h h = GC.maxHalf end

	-- in-plane axes: +u along travel (or at a random angle), +v across; mirrored at random
	local ux, uy, uz
	if f.ratio then
		local a = rng:Range(-0.07, 0.07)
		local px, py, pz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
		ux, uy, uz = ABL.Norm(tx * cos(a) + px * sin(a), ty * cos(a) + py * sin(a), tz * cos(a) + pz * sin(a))
	else
		local sx, sy, sz = ABL.Perp(nx, ny, nz)
		local qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
		local a = rng:Next() * 6.2831853
		ux, uy, uz = sx * cos(a) + qx * sin(a), sy * cos(a) + qy * sin(a), sz * cos(a) + qz * sin(a)
	end
	local vx, vy, vz = ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux

	local q = {
		x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, ux = ux, uy = uy, uz = uz, vx = vx, vy = vy, vz = vz,
		fam = fam, cell = cell, h = h, hu = hu, flip = rng:Next() < 0.5, vol = bodyVol or vol,
		-- a fresh film of whole blood is nearly opaque; the texture keeps the thin rim translucent
		alpha = 255 * C.BloodMarkOpacity * (0.6 + 0.4 * (surf.alpha or 1)) * rng:Range(0.92, 1) * (fam == "tiny" and 0.94 or 1),
		-- per-stain variation of the filter: darker (venous) to brighter red, a little more or less
		-- saturated, so neighbouring stains never share one colour
		tone = rng:Range(C.ToneRange[1], 1), tg = rng:Range(0.9, 1.1), jit = rng:Next() * 0.02,
		dryT = max(8, (wetT or 60) * 2 * C.sv.drying:GetFloat()), crowd = ce, owner = owner,
	}
	Queue(q)
	-- (the drop's handle: q.s is its stain once it is placed; G.Handover)
	return q
end

-- (phase 21, C.P21.handover) The blood of these drops (handles from G.Impact) is in a pool's liquid
-- now: `delay` seconds from now, when the pool shows it, their stains give up their bodies of liquid.
-- The stain itself stays: it is what the floor shows where the drop struck. (A stain not yet placed
-- is placed without a body.) Nothing is booked: a stain's body is a picture of blood booked elsewhere.
local handList = {}
function G.Handover(list, delay)
	local t = CurTime() + (delay or 0)
	for i = 1, #list do
		local h = list[i]
		if not h.handT then
			h.handT = t
			handList[#handList + 1] = h
		end
	end
end

local function HandoverThink(now)
	local n = #handList
	if n == 0 then return end
	local j = 0
	for i = 1, n do
		local h = handList[i]
		if now >= h.handT then
			local s = h.s
			if s then
				if not s.dead and s.hc then
					Detach(s)
					s.hc, s.bvol, s.thin = nil, 0, nil
					s.chunk.dirty = true
					G.stats.handed = (G.stats.handed or 0) + 1
				end
			else
				h.vol = 0
			end
		else
			j = j + 1
			handList[j] = h
		end
	end
	for i = j + 1, n do handList[i] = nil end
end

-- Fallback particles that land on a floor leave a tiny spot (no footprint check needed).
function G.Tiny(x, y, z, nx, ny, nz, vol, rng)
	rng = rng or ABL.RNG(floor(abs(x * 7 + y * 13 + z * 3)) + 1)
	G.Impact(x, y, z, nx, ny, nz, vol or 0.003, 0.16, 1, nil, nil, nil, 30, C.Surfaces.default, rng, 20)
end

-- Deferred placements (trace budget) and crowd bookkeeping.
local nextGC = 0
function G.Think()
	local i = 1
	while i <= #pending do
		if Place(pending[i]) then table.remove(pending, i) else break end
	end
	local now = CurTime()
	HandoverThink(now)
	if now > nextGC then
		nextGC = now + 10
		for k, e in pairs(crowd) do
			if now - e.t > 30 then crowd[k] = nil end
		end
		-- (a character none of whose stains is left has no record)
		for who, o in pairs(owned) do
			if o.n <= 0 then owned[who] = nil end
		end
	end
end

------------------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------------------
local vec = Vector()
local function V(x, y, z, u, v, r, g, b, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

local function Quad(s, r, g, b, a)
	local x, y, z = s.x, s.y, s.z
	local ux, uy, uz, vx, vy, vz = s.ux, s.uy, s.uz, s.vx, s.vy, s.vz
	V(x - ux - vx, y - uy - vy, z - uz - vz, s.u0, s.v0, r, g, b, a)
	V(x + ux - vx, y + uy - vy, z + uz - vz, s.u1, s.v0, r, g, b, a)
	V(x + ux + vx, y + uy + vy, z + uz + vz, s.u1, s.v1, r, g, b, a)
	V(x - ux + vx, y - uy + vy, z - uz + vz, s.u0, s.v1, r, g, b, a)
end

-- The blood's own colour at age fraction k (0 fresh and wet .. 1 dried), 0..255 before light.
local function BodyColor(k)
	local Cc = C.Colors
	local a, b, t
	if k < GC.agingK then a, b, t = Cc.wet, Cc.aging, k / GC.agingK else a, b, t = Cc.aging, Cc.dried, (k - GC.agingK) / (1 - GC.agingK) end
	return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

-- The body of a stain as quads: its middle, and rings out to its foot. Height by its profile,
-- colour by the light on each facet's slope and by how deep the layer is there (thin: red,
-- deep: dark), opacity by depth too. The same vertices again for the highlight's mesh, with
-- the way each place faces: the part of the body that is still liquid.
local mPos, mTex, mCol, mAdv, mNrm = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex, mesh.Normal
local vSet = FindMetaTable("Vector").SetUnpacked
local ringCos, ringSin = {}, {}
for _, n in ipairs({ 8, 10, 14 }) do
	ringCos[n], ringSin[n] = {}, {}
	for i = 0, n do ringCos[n][i], ringSin[n][i] = cos(i / n * 6.2831853), sin(i / n * 6.2831853) end
end
-- The vertices of the stains of the batch being built, 64 places a stain: 0 the middle,
-- r * 16 + i ring r. From 4096 on: the same for a part that has drawn back.
local BX, BY, BZ, BU, BV, BR, BG, BB, BA = {}, {}, {}, {}, {}, {}, {}, {}, {}
local NX, NY, NZ = {}, {}, {}
local nrm = Vector()
local function BodyVert(i)
	mPos(BX[i], BY[i], BZ[i])
	mTex(0, BU[i], BV[i])
	mCol(BR[i], BG[i], BB[i], BA[i])
	mAdv()
end
local function GlossVert(i)
	mPos(BX[i], BY[i], BZ[i])
	vSet(nrm, NX[i], NY[i], NZ[i])
	mNrm(nrm)
	mTex(0, BU[i], BV[i])
	mAdv()
end

-- How far out from its middle a body is still liquid on top at age fraction k: it sets from its
-- edge inward.
local function WetPart(k)
	if k <= 0.2 then return 1 end
	if k >= 0.62 then return 0 end
	return ((0.62 - k) / 0.42) ^ 0.7
end

-- The vertices of the body of s into the arrays from place `off` on. whole: with colours and
-- the way each place faces (for the body's mesh, and the highlight's while all of it is
-- liquid); else the part out to rw of its radius with the way it faces alone (the highlight's
-- mesh of a body that is setting, and of a film). Returns the number of rings.
local function BodyFill(s, k, off, whole, rw, lr, lg, lb, kx, ky, kz, kv)
	local n = s.bn
	local nr = Rings(s)
	local cs, sn = ringCos[n], ringSin[n]
	local ba, bl, p = s.ba, s.bl, s.bp
	-- (a film's one ring lies around its round foot, not inside it: the painted outline cuts it)
	if nr == 1 and rw > 0.999 then rw = 1 / cos(3.14159265 / n) end
	-- (the rings: the foot; where the edge begins to fall; in a large body one more inside)
	local rb = 2.2 / p
	if rb > 0.38 then rb = 0.38 elseif rb < 0.12 then rb = 0.12 end
	local r1, r2 = 1 - rb, 1
	if nr == 3 then r1, r2 = (1 - rb) * 0.6, 1 - rb elseif s.thin then r1 = 0.7 end
	-- (it sinks as it dries; what it lets through is by the blood that is there, wet or dry)
	local sink = 1 - (1 - GC.bodyDry) * min(k / 0.6, 1)
	local hw, h = s.hc, s.hc * sink
	local nx, ny, nz = s.nx, s.ny, s.nz
	local hu, hv = s.bhu, s.bhv
	local ux, uy, uz, vx, vy, vz = s.ux / hu, s.uy / hu, s.uz / hu, s.vx / hv, s.vy / hv, s.vz / hv
	local x0, y0, z0 = s.bx, s.by, s.bz
	local um, vm, us, vs = (s.u0 + s.u1) * 0.5, (s.v0 + s.v1) * 0.5, (s.u1 - s.u0) * 0.5, (s.v1 - s.v0) * 0.5
	local a0 = s.bax
	local crown, rim = GC.crownTan, GC.rimTan
	local exp = math.exp
	local cr, cg, cb, kOp, kDeep, dark, aMax
	-- the middle
	BX[off], BY[off], BZ[off] = x0 + nx * h, y0 + ny * h, z0 + nz * h
	BU[off], BV[off] = um + us * a0, vm
	NX[off], NY[off], NZ[off] = nx, ny, nz
	if whole then
		cr, cg, cb = BodyColor(k)
		cr = cr * s.tone
		kOp, kDeep, dark, aMax = 1 / GC.bodyOpaque, 1 / GC.bodyDeep, GC.deepDark, s.alpha
		local kn = kx * nx + ky * ny + kz * nz
		local sh = (0.5 + 0.3 + 0.45 * (kn > 0 and kn or 0) * kv) * (1 - dark * (1 - exp(-hw * kDeep)))
		BR[off], BG[off], BB[off] = min(255, cr * sh * lr), min(255, cg * sh * lg), min(255, cb * sh * lb)
		BA[off] = aMax * (1 - exp(-hw * kOp))
	end
	for r = 1, nr do
		local rho = r == nr and 1 or (r == 1 and r1 or r2)
		if not whole then rho = rho * rw end
		local rp = rho ^ (p - 1)
		local zf = 1 - rp * rho
		-- (the profile's slope, and the lean of a top that is never quite level; at the last ring
		-- the surface rounds over to the floor)
		local slope = h * p * rp + crown * rho
		if r == nr and slope < rim then slope = rim end
		local op, dk
		if whole then
			op = aMax * (1 - exp(-hw * zf * kOp))
			dk = 1 - dark * (1 - exp(-hw * zf * kDeep))
		end
		local base = off + r * 16
		for i = 0, n - 1 do
			local c, sI = cs[i], sn[i]
			local lx, ly = rho * bl * c, rho * ba * sI
			local id = base + i
			BX[id] = x0 + ux * lx + vx * ly + nx * h * zf
			BY[id] = y0 + uy * lx + vy * ly + ny * h * zf
			BZ[id] = z0 + uz * lx + vz * ly + nz * h * zf
			BU[id], BV[id] = um + us * (a0 + lx / hu), vm + vs * (ly / hv)
			-- the facet's normal: the slope, outward
			local gx, gy = slope * c / bl, slope * sI / ba
			local gl = 1 / sqrt(gx * gx + gy * gy + 1)
			local fx, fy, fz = (ux * gx + vx * gy + nx) * gl, (uy * gx + vy * gy + ny) * gl, (uz * gx + vz * gy + nz) * gl
			NX[id], NY[id], NZ[id] = fx, fy, fz
			if whole then
				local key = fx * kx + fy * ky + fz * kz
				local shd = (0.5 + 0.3 * gl + 0.45 * (key > 0 and key or 0) * kv) * dk
				BR[id], BG[id], BB[id], BA[id] = min(255, cr * shd * lr), min(255, cg * shd * lg), min(255, cb * shd * lb), op
			end
		end
	end
	return nr
end

-- (the middle as quads of two triangles each; then the bands between the rings)
local function BodyEmit(o, n, nr)
	for i = 0, n - 2, 2 do
		BodyVert(o) BodyVert(o + 16 + i) BodyVert(o + 16 + i + 1) BodyVert(o + 16 + (i + 2) % n)
	end
	for r = 1, nr - 1 do
		local b1, b2 = o + r * 16, o + (r + 1) * 16
		for i = 0, n - 1 do
			local j = (i + 1) % n
			BodyVert(b1 + i) BodyVert(b2 + i) BodyVert(b2 + j) BodyVert(b1 + j)
		end
	end
end
local function GlossEmit(o, n, nr)
	for i = 0, n - 2, 2 do
		GlossVert(o) GlossVert(o + 16 + i) GlossVert(o + 16 + i + 1) GlossVert(o + 16 + (i + 2) % n)
	end
	for r = 1, nr - 1 do
		local b1, b2 = o + r * 16, o + (r + 1) * 16
		for i = 0, n - 1 do
			local j = (i + 1) % n
			GlossVert(b1 + i) GlossVert(b2 + i) GlossVert(b2 + j) GlossVert(b1 + j)
		end
	end
end
-- (the mirror of a wet stain: its quad, facing as the floor does; a: how much of a mirror it still is, 0..255)
local function MirrorQuad(s, a)
	local x, y, z = s.x, s.y, s.z
	local ux, uy, uz, vx, vy, vz = s.ux, s.uy, s.uz, s.vx, s.vy, s.vz
	vSet(nrm, s.nx, s.ny, s.nz)
	mPos(x - ux - vx, y - uy - vy, z - uz - vz) mNrm(nrm) mTex(0, s.u0, s.v0) mCol(255, 255, 255, a) mAdv()
	mPos(x + ux - vx, y + uy - vy, z + uz - vz) mNrm(nrm) mTex(0, s.u1, s.v0) mCol(255, 255, 255, a) mAdv()
	mPos(x + ux + vx, y + uy + vy, z + uz + vz) mNrm(nrm) mTex(0, s.u1, s.v1) mCol(255, 255, 255, a) mAdv()
	mPos(x - ux + vx, y - uy + vy, z - uz + vz) mNrm(nrm) mTex(0, s.u0, s.v1) mCol(255, 255, 255, a) mAdv()
end

-- fresh (wet) -> drying -> dried: filter multipliers (linear), wetness (0..1) and age fraction
local function Age(s, now)
	local k = math.Clamp((now - s.born) / s.dryT, 0, 1)
	local mr, mg, mb = ABL.Render.FilterAge(k, GC.agingK)
	-- (fresh blood lets next to no green or blue through; as it dries it turns to the brown the filter has)
	local gb = GC.filmGB + (1 - GC.filmGB) * k
	return mr * s.tone, mg * (s.tg or 1) * gb, mb * gb, math.Clamp(1 - k / 0.5, 0, 1), k
end

-- Is the liquid of s drawn in relief in chunk c now? (Near enough, and for its size.)
local function Relief(c, s)
	return s.hc and c.withBody and (c.withSmall or not s.small)
end

-- The chunk's mirror: the quads of its wet stains. How much of a mirror a stain still is rides
-- in the vertices; how much the angle of view makes of it is set at each draw.
local function BuildMirror(c, rt)
	if c.sheen then c.sheen:Destroy() c.sheen = nil end
	c.mirDirty = false
	c.mirT = rt + GC.mirrorWait
	local items = c.items
	local n = 0
	for i = 1, #items do
		local s = items[i]
		if not s.dead and (s.wet or 0) > 0 then n = n + 1 end
	end
	if n == 0 then return end
	local mm = Mesh()
	mesh.Begin(mm, MATERIAL_QUADS, n)
	for i = 1, #items do
		local s = items[i]
		if not s.dead and (s.wet or 0) > 0 then MirrorQuad(s, s.wet * s.alpha) end
	end
	mesh.End()
	c.sheen = mm
end

-- The chunk's filter: all its stains. (Its mirror follows when it is due: BuildMirror.)
local function Build(c, now)
	if c.mesh then c.mesh:Destroy() c.mesh = nil end
	c.dirty = false
	c.mirDirty = true
	-- compact
	local items, j = c.items, 0
	for i = 1, #items do
		local s = items[i]
		if not s.dead then j = j + 1 items[j] = s end
	end
	for i = j + 1, #items do items[i] = nil end
	if j == 0 then
		if c.sheen then c.sheen:Destroy() c.sheen = nil end
		return
	end
	local R = ABL.Render
	local sx, sy, sz, anx, any, anz, young, wet = 0, 0, 0, 0, 0, 0, 0, 0
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, j)
	for i = 1, j do
		local s = items[i]
		-- a filter needs no lighting: the floor under it is already lit
		local mr, mg, mb, w, k = Age(s, now)
		Quad(s, R.FilterColor(mr, mg, mb, s.alpha / 255 * (1 - 0.06 * k)))
		s.wet = w
		s.k = k
		if w > 0 then wet = wet + 1 end
		sx, sy, sz = sx + s.x, sy + s.y, sz + s.z
		anx, any, anz = anx + s.nx, any + s.ny, anz + s.nz
		if s.born > young then young = s.born end
	end
	mesh.End()
	c.mesh = m
	c.x, c.y, c.z = sx / j, sy / j, sz / j
	c.nx, c.ny, c.nz = ABL.Norm(anx, any, anz)
	local rad = 0
	for i = 1, j do
		local s = items[i]
		local d = sqrt((s.x - c.x) ^ 2 + (s.y - c.y) ^ 2 + (s.z - c.z) ^ 2) + s.h * 1.42
		if d > rad then rad = d end
	end
	c.rad = rad
	c.youngest = young
	c.wetCount = wet
	c.lr = nil
end

-- The key light of chunk c: the sun where it reaches the place, else the light from above (the
-- open sky in a shadow, the lamps of a room), which makes less of a highlight.
local sunOut = {}
local sunTr = { mask = MASK_OPAQUE, output = sunOut }
local function KeyLight(c)
	local R = ABL.Render
	local lr, lg, lb = R.Light(c.x + c.nx * 2, c.y + c.ny * 2, c.z + c.nz * 2)
	c.kr, c.kg, c.kb = min(lr, 1.2), min(lg, 1.2), min(lb, 1.2)
	local kx, ky, kz = R.SunDir()
	if kx then
		vA:SetUnpacked(c.x + c.nx * 3, c.y + c.ny * 3, c.z + c.nz * 3)
		vB:SetUnpacked(c.x + kx * 8000, c.y + ky * 8000, c.z + kz * 8000)
		sunTr.start, sunTr.endpos = vA, vB
		util.TraceLine(sunTr)
		if sunOut.HitSky or not sunOut.Hit then
			c.kx, c.ky, c.kz, c.kk = kx, ky, kz, 1
			return
		end
	end
	local gx, gy, gz, gmag = ABL.Gravity()
	c.kx, c.ky, c.kz, c.kk = -gx / gmag, -gy / gmag, -gz / gmag, GC.glossShade
end

-- The two meshes of batch b of chunk c: the bodies' own colour under the light of the place, and
-- the highlight's (what is still liquid on top, of bodies and of films). Every stain's vertices
-- are worked out once. Returns the quads built.
local function BuildRelief(c, b, now)
	FreeBatch(b)
	b.dirty = false
	local items = b.items
	local n = #items
	local nb, ng = 0, 0
	local fastest, setting = math.huge, false
	for i = 1, n do
		local s = items[i]
		local k = math.Clamp((now - s.born) / s.dryT, 0, 1)
		if k < 1 and s.dryT < fastest then fastest = s.dryT end
		if k > 0.18 and k < 0.64 then setting = true end
		local rel = Relief(c, s)
		-- (The key light's highlight is the mirror of a smooth liquid surface. Blood too shallow to
		-- hide the roughness of what it lies on has none, and a shallow layer has it on its deeper
		-- middle alone: fine spatter was a scatter of silver seeds from the light's mirror side.)
		s.rk, s.rw = k, rel and WetPart(k) * math.Clamp((s.hc - GC.glossMin) / (GC.glossFull - GC.glossMin), 0, 1) or 0
		s.rbody = rel and not s.thin
		if s.rbody then nb = nb + BodyQuads(s) end
		if s.rw > 0.02 then ng = ng + BodyQuads(s) end
	end
	-- (when it is to be built again for its stains' drying: never, once all of them have dried)
	b.settled = fastest == math.huge
	b.step = math.Clamp(fastest * (setting and GC.glossStep or GC.reliefStep), 0.25, 4)
	if nb + ng == 0 then return 0 end
	local lr, lg, lb = ABL.Render.Light(c.x + c.nx * 2, c.y + c.ny * 2, c.z + c.nz * 2)
	local kx, ky, kz, kv = c.kx, c.ky, c.kz, c.kk >= 1 and 1 or 0.35
	for i = 1, n do
		local s = items[i]
		local off = (i - 1) * 64
		if s.rbody then s.rn = BodyFill(s, s.rk, off, true, 1, lr, lg, lb, kx, ky, kz, kv) end
		-- (the highlight's own vertices where the liquid has drawn back from the edge, and of a film)
		s.roff = off
		if s.rw > 0.02 and (s.rw < 0.999 or not s.rbody) then
			s.roff = 4096 + off
			s.rn = BodyFill(s, s.rk, s.roff, false, s.rw)
		end
	end
	if nb > 0 then
		local bm = Mesh()
		mesh.Begin(bm, MATERIAL_QUADS, nb)
		for i = 1, n do
			local s = items[i]
			if s.rbody then BodyEmit((i - 1) * 64, s.bn, s.rn) end
		end
		mesh.End()
		b.body = bm
	end
	if ng > 0 then
		local gm = Mesh()
		mesh.Begin(gm, MATERIAL_QUADS, ng)
		for i = 1, n do
			local s = items[i]
			if s.rw > 0.02 then GlossEmit(s.roff, s.bn, s.rn) end
		end
		mesh.End()
		b.gloss = gm
	end
	return nb + ng
end

-- The material that mirrors one of the map's cubemaps over the stain atlas (its coverage cuts the
-- mirror to the stain's outline). One per cubemap; made while the map loads, a late one on use.
local envMats, envCount = {}, 0
local function EnvMat(path)
	local m = envMats[path]
	if m then return m end
	envCount = envCount + 1
	m = CreateMaterial("abl_ground_env" .. envCount, "UnlitGeneric", {
		["$basetexture"] = "advancedblood/ground/stainatlas", ["$additive"] = 1,
		["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
		["$color"] = "[0 0 0]", ["$envmap"] = path, ["$envmaptint"] = "[1 1 1]",
		["$envmapsaturation"] = C.Pool.envSaturation,
	})
	envMats[path] = m
	return m
end
G.EnvMat = EnvMat
hook.Add("InitPostEntity", "ABL_GroundEnv", function()
	local list = ABL.Render.CubemapPaths()
	if #list <= 64 then
		for _, path in ipairs(list) do EnvMat(path) end
	end
end)
-- A place of the atlas that is covered all over (for what is drawn with that material and is no stain).
function G.OpaqueUV()
	local u0, v0, u1, v1 = CellUV(8)
	return (u0 + u1) * 0.5, (v0 + v1) * 0.5
end

local sheenOff, sheenCol = Vector(), Vector()
local sheenMat = Matrix()
local bodyList, mirList, mirOf, glossList, glossOf = {}, {}, {}, {}, {}
local keyDir, keyCol, keyAt = Vector(), Vector(), Vector()
local keyLight = { { type = MATERIAL_LIGHT_DIRECTIONAL, color = keyCol, dir = keyDir } }
local cvDebug = CreateClientConVar("abl_ground_debug", "0", false, false, "Ground stain debugging bitmask (1 no mirror and no highlights, 2 no filter, 4 no bodies of liquid).")
G.reliefBuilt = 0
local relCredit = 0

function G.Draw()
	local now, rt = CurTime(), RealTime()
	local maxD = min(C.cl.drawDist:GetFloat(), GC.drawDist)
	local builds, relBuilds, relNear, set = 0, 0, 1, false
	relCredit = min(relCredit + GC.reliefRate * (L.scale or 1), GC.reliefRate)
	local tChunk, tMirror, tRelief = 0, 0, 0
	local nb, nm, ng = 0, 0, 0
	local dbg = cvDebug:GetInt()
	local noGloss, noFilter, noBody = bit.band(dbg, 1) ~= 0, bit.band(dbg, 2) ~= 0, bit.band(dbg, 4) ~= 0
	local bodyD2, glossD, smallD = GC.bodyDist ^ 2, GC.glossDist, GC.smallDist
	local relWait = GC.reliefWait / max(L.scale or 1, 0.33)
	for i = #chunks, 1, -1 do
		local c = chunks[i]
		if c.live <= 0 then
			if c.mesh then c.mesh:Destroy() end
			if c.sheen then c.sheen:Destroy() end
			for bi = 1, #c.rel do FreeBatch(c.rel[bi]) end
			if open[c.key] == c then open[c.key] = nil end
			table.remove(chunks, i)
		else
			-- colours keep ageing while any stain in the chunk is still drying
			if rt > c.nextAge then
				c.nextAge = rt + 2 + math.random()
				if now - c.youngest < GC.maxDry * C.sv.drying:GetFloat() then c.dirty = true end
			end
			if (c.dirty or not c.mesh) and builds < 4 and rt > c.nextBuild then
				local t0 = SysTime()
				Build(c, now)
				tChunk = tChunk + SysTime() - t0
				builds = builds + 1
				c.nextBuild = rt + 0.12
			end
			if c.mirDirty and rt > (c.mirT or 0) then
				local t0 = SysTime()
				BuildMirror(c, rt)
				tMirror = tMirror + SysTime() - t0
			end
			if c.mesh then
				local d2, vis = L.View(c.x, c.y, c.z, c.rad)
				local rel = c.rel
				-- (relief for what is near: built when the eye comes near, dropped when it has gone; the
				-- smallest bodies for what is nearest)
				local near = d2 < (c.withBody and bodyD2 * 1.96 or bodyD2) and not noBody
				local small = near and d2 < (smallD * (c.withSmall and 1.35 or 1) + c.rad) ^ 2
				if near ~= c.withBody or small ~= c.withSmall then
					c.withBody, c.withSmall, c.dirty = near, small, true
					for bi = 1, #rel do
						local b = rel[bi]
						b.dirty = true
						if not near then FreeBatch(b) end
					end
				end
				if near and #rel > 0 then
					if rt > c.keyT then
						c.keyT = rt + 4 + math.random() * 2
						KeyLight(c)
					end
					for bi = 1, #rel do
						local b = rel[bi]
						if ((b.dirty and rt > (b.nextBuild or 0)) or (not b.settled and rt > b.nextAge)) and (relCredit > 0 or (small and relNear > 0)) then
							local t0 = SysTime()
							relCredit = relCredit - BuildRelief(c, b, now)
							if small then relNear = relNear - 1 end
							tRelief = tRelief + SysTime() - t0
							b.nextAge = rt + b.step * (0.9 + 0.2 * math.random())
							b.nextBuild = rt + relWait
							relBuilds = relBuilds + 1
						end
					end
				end
				if vis and d2 < (maxD + c.rad) ^ 2 then
					if not noFilter then
						ABL.Render.FilterDraw(M.groundFilter, c.mesh)
						set = true
					end
					local mir = d2 < 1100 * 1100 and not noGloss
					if c.sheen and mir then nm = nm + 1 mirList[nm], mirOf[nm] = c.sheen, c end
					if near then
						local gl = d2 < glossD * glossD and not noGloss
						c.gd = d2
						for bi = 1, #rel do
							local b = rel[bi]
							if b.body then nb = nb + 1 bodyList[nb] = b.body end
							if b.gloss and gl then ng = ng + 1 glossList[ng], glossOf[ng] = b.gloss, c end
						end
					end
				end
			end
		end
	end
	G.reliefBuilt = G.reliefBuilt + relBuilds
	-- (what the building cost, and how much was drawn: for the profiler)
	local P = ABL.Prof
	P.Add("sub.ground.chunks", tChunk)
	P.Add("sub.ground.mirror", tMirror)
	P.Add("sub.ground.relief", tRelief)
	P.Count("ground: chunks built", builds)
	P.Count("ground: batches built", relBuilds)
	P.Count("ground: meshes drawn", nb + nm + ng)
	if set then ABL.Render.EndFilter() end
	-- the bodies of liquid: the blood's own colour over the stained floor
	if nb > 0 then
		render.SetMaterial(M.ground)
		for i = 1, nb do
			bodyList[i]:Draw()
			bodyList[i] = nil
		end
	end
	-- the mirror: the surroundings in the place of as much of the blood as the angle of view makes
	-- a mirror of it (Fresnel at the chunk; no more than mirrorMax)
	if nm > 0 then
		local R = ABL.Render
		local useEnv = ABL.PoolCanvas.useEnv:GetBool() and not G.noEnv
		local e = C.Pool.envStrength
		local blend, slid, last = false, false, nil
		for i = 1, nm do
			local c = mirOf[i]
			if c ~= last then
				last = c
				local dx, dy, dz = c.x - L.eyeX, c.y - L.eyeY, c.z - L.eyeZ
				local d = max(sqrt(dx * dx + dy * dy + dz * dz), 1)
				local F = R.Fresnel(abs(dx * c.nx + dy * c.ny + dz * c.nz) / d)
				if useEnv and c.envPath == nil then
					c.envPath = R.Cubemap(c.x + c.nx * 8, c.y + c.ny * 8, c.z + c.nz * 8) or false
				end
				if useEnv and c.envPath then
					local em = EnvMat(c.envPath)
					local k = min(F, GC.mirrorMax)
					c.kNow = k
					sheenCol:SetUnpacked(e, e, e)
					em:SetVector("$envmaptint", sheenCol)
					em:SetFloat("$alpha", k)
					render.SetMaterial(em)
					render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
					blend = true
				else
					-- no cubemap here: a sheen pattern that slides with the view, added to the picture
					if blend then render.OverrideBlend(false) blend = false end
					local sm = M.groundSheen
					if not slid then
						slid = true
						sheenOff:SetUnpacked((L.eyeX + L.eyeY) / 90 % 1, (L.eyeY - L.eyeZ) / 90 % 1, 0)
						sheenMat:SetTranslation(sheenOff)
						sm:SetMatrix("$detailtexturetransform", sheenMat)
					end
					local k = min(GC.sheen * F, 0.45)
					c.kNow = k
					if not c.lr then c.lr, c.lg, c.lb = R.Light(c.x + c.nx * 2, c.y + c.ny * 2, c.z + c.nz * 2) end
					sheenCol:SetUnpacked(k * min(c.lr, 1.1), k * min(c.lg, 1.1), k * min(c.lb, 1.1))
					sm:SetVector("$color", sheenCol)
					render.SetMaterial(sm)
				end
			end
			mirList[i]:Draw()
			mirList[i], mirOf[i] = nil, nil
		end
		if blend then render.OverrideBlend(false) end
	end
	-- the key light's highlight on the liquid: the lit material under one light, the chunk's own
	if ng > 0 then
		render.SuppressEngineLighting(true)
		render.ResetModelLighting(0, 0, 0)
		local pm = M.groundPhong
		local last
		for i = 1, ng do
			local c = glossOf[i]
			if c ~= last then
				last = c
				-- (fading out with distance: a highlight a pixel wide flickers)
				local f = (glossD - sqrt(c.gd)) / (glossD * 0.33)
				if f > 1 then f = 1 end
				f = f * c.kk
				keyAt:SetUnpacked(c.x, c.y, c.z)
				keyDir:SetUnpacked(-c.kx, -c.ky, -c.kz)
				keyCol:SetUnpacked(c.kr * f, c.kg * f, c.kb * f)
				render.SetLightingOrigin(keyAt)
				render.SetLocalModelLights(keyLight)
				render.SetMaterial(pm)
			end
			glossList[i]:Draw()
			glossList[i], glossOf[i] = nil, nil
		end
		render.SetLocalModelLights()
		render.SuppressEngineLighting(false)
	end
end

-- Developer (self-test): every chunk's stains, how many are wet, how much of a mirror the view
-- makes of them and what they mirror, its batches of relief.
function G.SheenInfo()
	local t = {}
	for i = 1, #chunks do
		local c = chunks[i]
		local nbody, ngloss, nst = 0, 0, 0
		for _, b in ipairs(c.rel) do
			nst = nst + #b.items
			if b.body then nbody = nbody + 1 end
			if b.gloss then ngloss = ngloss + 1 end
		end
		t[#t + 1] = string.format("%d stains, %d wet, mirror %.3f of %s, relief %s small %s: %d batches of %d stains, %d with bodies, %d with highlights (key light %.2f), normal %.2f %.2f %.2f",
			#c.items, c.wetCount or 0, c.kNow or -1, tostring(c.envPath), tostring(c.withBody), tostring(c.withSmall), #c.rel, nst, nbody, ngloss, c.kk or -1,
			c.nx, c.ny, c.nz)
	end
	return table.concat(t, " | ") .. " | mirror materials " .. envCount .. " | batches built " .. G.reliefBuilt
end

function G.Clear()
	for i = #chunks, 1, -1 do
		local c = chunks[i]
		if c.mesh then c.mesh:Destroy() end
		if c.sheen then c.sheen:Destroy() end
		for bi = 1, #c.rel do FreeBatch(c.rel[bi]) end
		chunks[i] = nil
	end
	for k in pairs(open) do open[k] = nil end
	for k in pairs(crowd) do crowd[k] = nil end
	for k in pairs(owned) do owned[k] = nil end
	for i = #pending, 1, -1 do pending[i] = nil end
	fifo, head, tail, count = {}, 1, 0, 0
end
