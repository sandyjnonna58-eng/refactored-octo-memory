-- |Z-CITY| GORE arteries (client)
--
-- Draws the artery bundle that holds a severed piece to its stump (3 thin arteries for a limb / the head,
-- 5 for the chest of a cut torso), what happens when they are stretched and torn, and the arterial spray.
--
--   * each artery is a real lit 3D tube (not a flat beam): pulsing with the heartbeat, wet highlight,
--     darker edges, slack ones droop and bow, taut ones straighten
--   * a stretched artery thins out in the middle, blanches pale and quivers just before it rips
--   * strands rip one at a time (server decides, see StepArteryTear in sv_gore.lua): each rip is a
--     burst of blood from both ends, then the torn ends stay behind as limp ragged stubs with a hanging
--     bead of blood that keeps dripping for a while
--   * the last rip lets the piece fall free
--
-- Textures (every one is optional, a missing file falls back to procedural drawing, see MATERIALS_TO_MAKE.md):
--   materials/zcity_gore/artery_vessel.vmt      skin of the tubes
--   materials/zcity_gore/artery_tear_tip.vmt    ragged torn end sprite
--   materials/zcity_gore/blood_mist.vmt         soft blood mist particle
--   materials/zcity_gore/blood_spatter.vmt      radial spatter flash at every rip
--   materials/zcity_gore/blood_drip.vmt         hanging thread + teardrop on torn ends
--   materials/zcity_gore/blood_blob.vmt         glossy pool where an artery enters the flesh
--
-- Client convars:
--   zcity_gore_quality (0-3, default 2)  0 = simple (old look), 1 = low, 2 = normal, 3 = high
--   zcity_gore_jets    (0/1, default 1)  visible arterial blood streams
--   zcity_gore_max_detailed (default 6)  how many nearest pieces get full detail, the rest a minimal tube (0 = all)
--   zcity_gore_draw_distance (default 1500)  max distance at which arteries are drawn
--   zcity_gore_particle_budget (default 160)  max artery spray particles per second, shared by all pieces (0 = unlimited)

ZCityGore = ZCityGore or {}

local UP = Vector(0, 0, 1)
local SPRAY_DISTANCE_SQR = 900 * 900
local SIDES, STEPS = 6, 12
local TAU = math.pi * 2
local LIGHT_DIR = Vector(0.35, 0.25, 0.9)
LIGHT_DIR:Normalize()

local colBlob = Color(92, 3, 8)
local colBead = Color(112, 3, 8)
local colBeadShine = Color(225, 70, 66)
local colFray = Color(228, 134, 130)

-- lower halves of cut torsos (filled by cl_torso.lua)
ZCityGore.ClientLowers = ZCityGore.ClientLowers or {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function validVec(v)
	return v ~= nil and v.x == v.x and v.y == v.y and v.z == v.z
end

local function smooth01(x)
	x = math.Clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- deterministic 0..1 noise so every strand keeps its own look
local function hash(a, b)
	local x = math.sin(a * 12.9898 + b * 78.233) * 43758.5453
	return x - math.floor(x)
end

local function bezier(a, b, c, t)
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

-- ---------------------------------------------------------------------------
-- Materials
-- ---------------------------------------------------------------------------
local cvQuality = CreateClientConVar("zcity_gore_quality", "2", true, false,
	"Artery / blood visual quality: 0 = simple, 1 = low, 2 = normal, 3 = high", 0, 3)
-- remorse: кровь как в Z-City - капли и пятна Z-City (hg.addBloodPart), без всплеска и капель HL2 (bloodspray,
-- effects/blood + декаль Blood); 1 - как было в аддоне
local cvHL2Blood = CreateClientConVar("zcity_gore_hl2_blood", "0", true, false, "Artery gore also uses Half-Life 2 blood (spray effect and drops)", 0, 1)
local cvJets = CreateClientConVar("zcity_gore_jets", "1", true, false,
	"Draw visible arterial blood streams (0 = particles only)", 0, 1)
local cvMaxDetailed = CreateClientConVar("zcity_gore_max_detailed", "6", true, false,
	"How many of the nearest severed pieces are drawn in full detail (0 = all)", 0, 64)
local cvDrawDist = CreateClientConVar("zcity_gore_draw_distance", "1500", true, false,
	"Max distance at which severed pieces draw their arteries", 200, 6000)
local cvBudget = CreateClientConVar("zcity_gore_particle_budget", "160", true, false,
	"Max artery spray particles per second shared by all severed pieces (0 = unlimited)", 0, 2000)

-- cached lookup of an optional texture: the Material, or false when the file is not installed
local texCache = {}
local function texMat(name)
	local m = texCache[name]
	if m == nil then
		if file.Exists("materials/zcity_gore/" .. name .. ".vmt", "GAME") then
			m = Material("zcity_gore/" .. name)
		else
			m = false
		end
		texCache[name] = m
	end
	return m
end

local matTube
local tubeTextured = false

local function tubeMat()
	if matTube then return matTube end
	local m = texMat("artery_vessel")
	if m then
		matTube = m
		tubeTextured = true
	else
		matTube = CreateMaterial("zcity_gore_tube_v1", "UnlitGeneric", {
			["$basetexture"] = "color/white",
			["$vertexcolor"] = 1,
			["$vertexalpha"] = 1,
			["$nocull"] = 1,
		})
	end
	return matTube
end

local function tipMat()
	return texMat("artery_tear_tip")
end

-- hanging drip sprite (only at quality >= 1); handleSpray keeps the old particle drips when it is missing
local function dripMat()
	if cvQuality:GetInt() < 1 then return false end
	return texMat("blood_drip")
end

-- ---------------------------------------------------------------------------
-- Blood: soft mist + streaking droplets that leave a decal where they land
-- ---------------------------------------------------------------------------
local MAT_DROP = "effects/blood"

local function mistName()
	if texMat("blood_mist") then return "zcity_gore/blood_mist" end
	return "effects/blood_core"
end
local decalBudget, decalReset = 0, 0

local function decalAllowed()
	local ct = CurTime()
	if ct > decalReset then
		decalReset = ct + 1
		decalBudget = 24
	end
	if decalBudget <= 0 then return false end
	decalBudget = decalBudget - 1
	return true
end

-- Spray budget: Z-City blood parts / mist / drops are the expensive part when many pieces bleed at once.
-- All artery spray shares this many particles per second; the budget is handed out round-robin.
local pBudget, pReset = 0, 0
local function particlesAllowed(n)
	local cap = cvBudget:GetInt()
	if cap <= 0 then return true end
	local ct = CurTime()
	if ct > pReset or ct < pReset - 1 then
		pReset = ct + 1
		pBudget = cap
	end
	if pBudget < n then return false end
	pBudget = pBudget - n
	return true
end

-- `em` (optional): an emitter the caller already owns, so one effect burst does not create/destroy
-- a new ParticleEmitter for every single call
function ZCityGore.BloodMist(pos, dir, speed, count, size, em)
	local own = em == nil
	if own then em = ParticleEmitter(pos) end
	if not em then return end
	local mat = mistName()
	for _ = 1, count do
		local p = em:Add(mat, pos + VectorRand() * 0.5)
		if p then
			p:SetVelocity(dir * speed * math.Rand(0.45, 1.05) + VectorRand() * speed * 0.2)
			p:SetDieTime(math.Rand(0.35, 0.75))
			p:SetStartAlpha(math.Rand(120, 190))
			p:SetEndAlpha(0)
			p:SetStartSize(size * math.Rand(0.45, 0.8))
			p:SetEndSize(size * math.Rand(2.0, 3.4))
			p:SetRoll(math.Rand(0, 360))
			p:SetRollDelta(math.Rand(-2, 2))
			p:SetColor(125, 4, 6)
			p:SetGravity(Vector(0, 0, -160))
			p:SetAirResistance(80)
		end
	end
	if own then em:Finish() end
end

local DROP_GRAVITY = Vector(0, 0, -620)

local function dropHit(part, hitpos, normal)
	if decalAllowed() then util.Decal("Blood", hitpos + normal, hitpos - normal) end
	part:SetDieTime(part:GetLifeTime() + 0.02)
end

function ZCityGore.BloodDrops(pos, dir, speed, count, size, em)
	-- remorse: капли Z-City вместо частиц HL2 (они сами оставляют пятна Z-City, где упадут)
	if not cvHL2Blood:GetBool() and hg and hg.addBloodPart then
		for _ = 1, count do
			local sz = size * math.Rand(0.7, 1.2)
			hg.addBloodPart(pos + VectorRand() * 0.4, dir * speed * math.Rand(0.5, 1.15) + VectorRand() * speed * 0.28, nil, sz, sz)
		end
		return
	end
	local own = em == nil
	if own then em = ParticleEmitter(pos) end
	if not em then return end
	for _ = 1, count do
		local p = em:Add(MAT_DROP, pos + VectorRand() * 0.4)
		if p then
			local sz = size * math.Rand(0.7, 1.2)
			p:SetVelocity(dir * speed * math.Rand(0.5, 1.15) + VectorRand() * speed * 0.28)
			p:SetDieTime(math.Rand(0.9, 1.6))
			p:SetStartAlpha(255)
			p:SetEndAlpha(255)
			p:SetStartSize(sz)
			p:SetEndSize(sz * 0.8)
			p:SetStartLength(sz * 3)
			p:SetEndLength(sz * 1.2)
			p:SetColor(115, 3, 5)
			p:SetGravity(DROP_GRAVITY)
			p:SetCollide(true)
			p:SetBounce(0)
			p:SetCollideCallback(dropHit)
		end
	end
	if own then em:Finish() end
end

-- strength 1 = one ripped artery, ~2 = a whole limb torn off
function ZCityGore.TearBurst(pos, dir, strength, ent)
	strength = strength or 1
	dir = dir or UP
	ent = IsValid(ent) and ent or nil
	-- under heavy load (several limbs torn off at once) every burst gets smaller instead of all of them full size
	if not particlesAllowed(math.floor(14 * strength)) then strength = strength * 0.4 end
	if hg and hg.addBloodPart then
		for _ = 1, math.floor(6 * strength) do
			local vel = dir * math.Rand(130, 340) + VectorRand(-70, 70)
			vel.z = vel.z + math.Rand(10, 60)
			local size = math.Rand(1.4, 3.2)
			hg.addBloodPart(pos + VectorRand(-0.8, 0.8), vel, nil, size, size, true, math.random() < 0.5 or nil, ent)
		end
	end

	local em = ParticleEmitter(pos)
	ZCityGore.BloodMist(pos, dir, 190, 2 + math.floor(2 * strength), 3.5 + 1.5 * strength, em)
	ZCityGore.BloodDrops(pos, dir, 260, 4 + math.floor(4 * strength), 1.6, em)

	-- quick radial spatter flash right at the wound
	if em and cvQuality:GetInt() >= 1 and texMat("blood_spatter") then
		local p = em:Add("zcity_gore/blood_spatter", pos + dir * 0.6)
		if p then
			p:SetVelocity(dir * 25)
			p:SetDieTime(math.Rand(0.16, 0.26))
			p:SetStartAlpha(235)
			p:SetEndAlpha(0)
			p:SetStartSize(1.5 * strength)
			p:SetEndSize(7 + 5 * strength)
			p:SetRoll(math.Rand(0, 360))
			p:SetColor(215, 190, 190)
		end
	end
	if em then em:Finish() end

	if not cvHL2Blood:GetBool() then return end -- remorse: всплеск HL2 только по zcity_gore_hl2_blood 1
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetNormal(dir)
	ed:SetScale(3 + strength * 2)
	ed:SetFlags(3)
	ed:SetColor(0)
	util.Effect("bloodspray", ed)
end

-- ---------------------------------------------------------------------------
-- Where the bundle sits: both ends, which way each cut face looks, strand layout
-- ---------------------------------------------------------------------------
-- Returns a table describing the bundle of a hanging piece (severed limb / head or lower half of a cut
-- torso), or nil when it cannot be placed right now.
function ZCityGore.BundleFor(ent)
	if not IsValid(ent) then return end

	if ent:GetNWBool("IsSeveredLimb") then
		local limb = ent:GetNWString("SeveredLimb", "")
		local owner = ent:GetNWEntity("SeveredBody")
		local body
		if IsValid(owner) and owner:IsPlayer() and owner:GetNWInt("ZCGoreLife", 0) ~= ent:GetNWInt("SeveredLife", 0) then
			-- the player respawned: this piece (and its torn stubs) belongs to the corpse of the previous life,
			-- never to the new body
			body = ent:GetNWEntity("SeveredCorpse")
			-- the link may not have reached us (yet): fall back to the body this piece hung from before the respawn
			if not IsValid(body) then body = ent.zgLastBody end
		else
			body = ZCityGore.ResolveBody(owner)
			-- remember it, so the arteries stay on the corpse after the respawn even if the server link is late
			if IsValid(body) and body ~= owner then ent.zgLastBody = body end
		end
		if not IsValid(body) or body:IsDormant() then return end
		local a, aAng = ZCityGore.ArteryPos(body, limb)
		local b, bAng = ZCityGore.ArteryPos(ent, limb)
		if not validVec(a) or not validVec(b) or not aAng or not bAng then return end
		local isHead = limb == "head"
		return {
			ent = ent,
			torso = false,
			anchor = a, cut = b,
			outA = aAng:Forward(),
			outB = isHead and Vector(0, 0, -1) or -bAng:Forward(),
			axisFallback = aAng:Forward(),
			len = ent:GetNWFloat("SeveredTetherLen", ZCityGore.TetherLength and ZCityGore.TetherLength[limb] or 12),
			snapMul = ZCityGore.TetherSnapMul or 2.5,
			defs = ZCityGore.LimbArteries,
			spread = ZCityGore.LimbArterySpread or 1.1,
			mask = ent:GetNWInt("ZCArteryTorn", 0),
			tethered = ent:GetNWBool("SeveredTethered"),
			tearTime = ent:GetNWFloat("ZCArteryTearTime", 0),
			bleedUntil = ent:GetNWFloat("SeverBleedUntil", 0),
			bleedTotal = isHead and 18 or 8,
			seed = ent:EntIndex(),
		}
	end

	if ent:GetNWBool("ZCityTorsoLowerPart") then
		local upperCap = ent:GetNWEntity("ZCTorsoUpperCap")
		local lowerCap = ent:GetNWEntity("ZCTorsoLowerCap")
		if not IsValid(upperCap) or not IsValid(lowerCap) then return end
		local a, b = upperCap:GetPos(), lowerCap:GetPos()
		if not validVec(a) or not validVec(b) then return end
		local d = b - a
		local dist = d:Length()
		local dn = dist > 0.01 and d / dist or Vector(0, 0, -1)
		return {
			ent = ent,
			torso = true,
			-- start a little outside both cut faces so the strands are not buried in the caps
			anchor = a + dn * 2, cut = b - dn * 2,
			outA = dn, outB = -dn,
			axisFallback = Vector(0, 0, -1),
			len = ent:GetNWFloat("ZCTorsoTetherLen", 26),
			snapMul = ZCityGore.TorsoTetherSnapMul or 2.6,
			defs = ZCityGore.TorsoArteries,
			spread = ZCityGore.TorsoArterySpread or 3.2,
			mask = ent:GetNWInt("ZCArteryTorn", 0),
			tethered = ent:GetNWBool("ZCTorsoTethered"),
			tearTime = ent:GetNWFloat("ZCArteryTearTime", 0),
			bleedUntil = ent:GetNWFloat("ZCTorsoBleedUntil", 0),
			bleedTotal = 25,
			seed = ent:EntIndex(),
		}
	end
end

-- Axis from stump to piece plus two perpendicular axes. A piece that sits right at the stump has no usable
-- direction, so the limb's own axis takes over smoothly.
local function bundleBasis(o)
	local delta = o.cut - o.anchor
	local dist = delta:Length()
	local axis = o.axisFallback or UP
	if dist > 0.01 then
		axis = LerpVector(smooth01(dist / 6), axis, delta / dist)
	end
	if axis:LengthSqr() < 1e-4 then axis = UP end
	axis = axis:GetNormalized()
	local side = axis:Cross(UP)
	if side:LengthSqr() < 1e-4 then side = Vector(1, 0, 0) end
	side:Normalize()
	local up2 = side:Cross(axis)
	up2:Normalize()
	return axis, side, up2, dist
end

-- Where strand i leaves the cut face on the stump side (A) and on the piece side (B). The bundle twists a
-- little on its way, so the strands wind around each other instead of running parallel.
local function strandOffsets(o, i, side, up2)
	local def = o.defs[i]
	local ang = math.rad(def.ang)
	local twist = (i % 2 == 0 and 1 or -1) * (0.7 + 0.3 * hash(o.seed, i))
	local rr = (0.7 + 0.3 * hash(i, 3)) * o.spread
	local offA = (side * math.cos(ang) + up2 * math.sin(ang)) * rr
	local offB = (side * math.cos(ang + twist) + up2 * math.sin(ang + twist)) * rr
	return offA, offB
end

local function isTorn(o, i)
	return bit.band(o.mask, bit.lshift(1, i - 1)) ~= 0
end

local function stubSeed(o, i, sideB)
	return o.seed * 7 + i + (sideB and 100 or 0)
end

local function stubLen(def, seed)
	return def.stub * (0.8 + 0.4 * hash(seed, def.ang))
end

-- Where the loose end of a torn artery ends up (it lies out of the wound and droops)
local function stubTip(root, out, L)
	return root + out * (L * 0.55) - UP * (L * 0.72)
end

-- ---------------------------------------------------------------------------
-- Tube mesh: rings of vertices along a curve, lit by hand (ambient light at the point + a fake sky light
-- + a wet specular highlight + darker silhouette edges), so a 0.2 unit artery still reads as a round,
-- glistening vessel.
--
-- Everything here runs for every artery of every hanging piece, every frame, so it is written without
-- per-frame allocations: scratch tables are reused, the maths is done on plain numbers and the vertex
-- Vectors come from a pool.
--
-- Black-line fix: the old version could light a ring almost to black (light probe sampled inside the
-- floor / the body, very dark strand colours multiplied by the shadow side). Now the probe is lifted off
-- the surface, ambient has a high floor, and no vertex may get darker than a fraction of its own colour
-- or below a minimum dark blood red.
-- ---------------------------------------------------------------------------
local MIN_R, MIN_G, MIN_B = 82, 5, 9   -- darkest a vertex may be (before the vessel texture), still clearly red
local COLOR_FLOOR = 0.62               -- ... and never darker than this fraction of the strand's own colour
local LDx, LDy, LDz = LIGHT_DIR.x, LIGHT_DIR.y, LIGHT_DIR.z

local vpool = {}                       -- Vector pool for ring vertices
local vcR, vcG, vcB = {}, {}, {}       -- vertex colours (index = ring * (sides + 1) + side + 1)
local tX, tY, tZ = {}, {}, {}          -- tangents
local lumA = {}                        -- light level per ring
local vCoord = {}                      -- texture v per ring
local trigCos, trigSin = {}, {}        -- per side count: cos / sin of each side angle
local probe = Vector()

local function trigFor(sides)
	local c = trigCos[sides]
	if not c then
		c, trigCos[sides] = {}, nil
		local s = {}
		for i = 0, sides do
			local a = (i % sides) / sides * TAU
			c[i], s[i] = math.cos(a), math.sin(a)
		end
		trigCos[sides], trigSin[sides] = c, s
	end
	return trigCos[sides], trigSin[sides]
end

-- one ambient light sample, lifted off whatever the vessel is lying on
local function sampleLum(p)
	probe:SetUnpacked(p.x, p.y, p.z + 3)
	local lc = render.GetLightColor(probe)
	local m = lc.x
	if lc.y > m then m = lc.y end
	if lc.z > m then m = lc.z end
	m = m * 1.25
	return m > 1 and 1 or m
end

-- shared scratch arrays for the strands (filled by the callers, read by drawTube)
local S_pts, S_rad, S_r, S_g, S_b = {}, {}, {}, {}, {}
for k = 0, 24 do S_pts[k] = Vector() end

-- pts[0..n] (Vectors), radii[0..n], cr/cg/cb[0..n] = strand colour per ring
local function drawTube(pts, n, radii, cr, cg, cb, eye, sides, lightStride)
	sides = sides or SIDES
	tubeMat() -- makes sure tubeTextured is known before the first vertex is lit
	local gain = tubeTextured and 1.22 or 1   -- the vessel texture is light grey (~0.8), win the brightness back
	local cosT, sinT = trigFor(sides)
	local stride1 = sides + 1
	local ex, ey, ez = eye.x, eye.y, eye.z

	-- tangents
	for k = 0, n do
		local a = pts[k > 0 and k - 1 or 0]
		local b = pts[k < n and k + 1 or n]
		local x, y, z = b.x - a.x, b.y - a.y, b.z - a.z
		local l2 = x * x + y * y + z * z
		if l2 < 1e-6 then
			if k > 0 then x, y, z = tX[k - 1], tY[k - 1], tZ[k - 1] else x, y, z = 0, 0, 1 end
		else
			local il = 1 / math.sqrt(l2)
			x, y, z = x * il, y * il, z * il
		end
		tX[k], tY[k], tZ[k] = x, y, z
	end

	-- light level per ring: sampled every `lightStride` rings and interpolated in between
	lightStride = lightStride or 3
	lumA[0] = sampleLum(pts[0])
	local last = 0
	for k = 1, n do
		if k % lightStride == 0 or k == n then
			lumA[k] = sampleLum(pts[k])
			local span = k - last
			for j = last + 1, k - 1 do
				lumA[j] = lumA[last] + (lumA[k] - lumA[last]) * (j - last) / span
			end
			last = k
		end
	end

	-- first normal: tangent x UP (or x X when the tube is vertical)
	local tx, ty, tz = tX[0], tY[0], tZ[0]
	local Nx, Ny, Nz = ty, -tx, 0
	if Nx * Nx + Ny * Ny + Nz * Nz < 1e-4 then Nx, Ny, Nz = 0, tz, -ty end
	do
		local il = 1 / math.sqrt(Nx * Nx + Ny * Ny + Nz * Nz)
		Nx, Ny, Nz = Nx * il, Ny * il, Nz * il
	end

	local vAcc = 0
	local px0, py0, pz0
	for k = 0, n do
		tx, ty, tz = tX[k], tY[k], tZ[k]
		if k > 0 then
			-- parallel transport: no twisting of the tube from frame to frame
			local d = Nx * tx + Ny * ty + Nz * tz
			Nx, Ny, Nz = Nx - tx * d, Ny - ty * d, Nz - tz * d
			if Nx * Nx + Ny * Ny + Nz * Nz < 1e-6 then
				Nx, Ny, Nz = ty, -tx, 0
				if Nx * Nx + Ny * Ny < 1e-6 then Nx, Ny, Nz = 0, tz, -ty end
			end
			local il = 1 / math.sqrt(Nx * Nx + Ny * Ny + Nz * Nz)
			Nx, Ny, Nz = Nx * il, Ny * il, Nz * il
		end
		-- B = T x N
		local Bx, By, Bz = ty * Nz - tz * Ny, tz * Nx - tx * Nz, tx * Ny - ty * Nx

		local p = pts[k]
		local px, py, pz = p.x, p.y, p.z
		local rad = radii[k]
		local c1, c2, c3 = cr[k], cg[k], cb[k]

		local lscale = 0.55 + 0.45 * lumA[k]     -- was 0.32 + 0.68 * lum: far too dark in shade
		local vx, vy, vz = ex - px, ey - py, ez - pz
		local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
		if vl > 1e-4 then vx, vy, vz = vx / vl, vy / vl, vz / vl else vx, vy, vz = 0, 0, 1 end
		local hx, hy, hz = LDx + vx, LDy + vy, LDz + vz
		local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
		if hl > 1e-4 then hx, hy, hz = hx / hl, hy / hl, hz / hl end

		local specScale = 0.35 + 0.65 * lscale
		local f1, f2, f3 = c1 * COLOR_FLOOR * gain, c2 * COLOR_FLOOR * gain, c3 * COLOR_FLOOR * gain
		if f1 < MIN_R then f1 = MIN_R end
		if f2 < MIN_G then f2 = MIN_G end
		if f3 < MIN_B then f3 = MIN_B end
		local base = k * stride1
		for s = 0, sides do
			local cs, sn = cosT[s], sinT[s]
			local nx, ny, nz = Nx * cs + Bx * sn, Ny * cs + By * sn, Nz * cs + Bz * sn
			local nh = nx * hx + ny * hy + nz * hz
			if nh < 0 then nh = 0 end
			local ndl = nx * LDx + ny * LDy + nz * LDz
			if ndl < 0 then ndl = 0 end
			local nv = nx * vx + ny * vy + nz * vz
			if nv < 0 then nv = 0 end
			-- tight wet highlight (nh^22) + a broad soft sheen (nh^5), both scaled by the light at the vessel
			local nh2 = nh * nh
			local nh4 = nh2 * nh2
			local nh8 = nh4 * nh4
			local spec = (nh8 * nh8 * nh4 * nh2 * 0.9 + nh4 * nh * 0.10) * specScale
			local rim = 1 - nv
			local rim2 = rim * rim
			local diff = (0.6 + 0.4 * ndl) * lscale * (1 - 0.25 * rim2)
			-- thin wet film catches a little warm light at the silhouette (cheap translucency)
			local sss = 0.10 * rim2 * lscale

			local r = c1 * diff * gain + 255 * spec + 60 * sss
			local g = c2 * diff * gain + 235 * spec + 8 * sss
			local b = c3 * diff * gain + 230 * spec + 6 * sss
			if r < f1 then r = f1 elseif r > 255 then r = 255 end
			if g < f2 then g = f2 elseif g > 255 then g = 255 end
			if b < f3 then b = f3 elseif b > 255 then b = 255 end

			local idx = base + s + 1
			local v = vpool[idx]
			if not v then v = Vector() vpool[idx] = v end
			v:SetUnpacked(px + nx * rad, py + ny * rad, pz + nz * rad)
			vcR[idx], vcG[idx], vcB[idx] = r, g, b
		end

		if k > 0 then
			local dx, dy, dz = px - px0, py - py0, pz - pz0
			vAcc = vAcc + math.sqrt(dx * dx + dy * dy + dz * dz)
		end
		px0, py0, pz0 = px, py, pz
		vCoord[k] = vAcc * 0.35
	end

	render.SetMaterial(tubeMat())
	mesh.Begin(MATERIAL_QUADS, n * sides)
	for k = 0, n - 1 do
		local o1, o2 = k * stride1, (k + 1) * stride1
		local v1, v2 = vCoord[k], vCoord[k + 1]
		for s = 0, sides - 1 do
			local i1, i2 = o1 + s + 1, o2 + s + 1
			local u0, u1 = s / sides, (s + 1) / sides
			mesh.Position(vpool[i1]); mesh.Color(vcR[i1], vcG[i1], vcB[i1], 255); mesh.TexCoord(0, u0, v1); mesh.AdvanceVertex()
			mesh.Position(vpool[i1 + 1]); mesh.Color(vcR[i1 + 1], vcG[i1 + 1], vcB[i1 + 1], 255); mesh.TexCoord(0, u1, v1); mesh.AdvanceVertex()
			mesh.Position(vpool[i2 + 1]); mesh.Color(vcR[i2 + 1], vcG[i2 + 1], vcB[i2 + 1], 255); mesh.TexCoord(0, u1, v2); mesh.AdvanceVertex()
			mesh.Position(vpool[i2]); mesh.Color(vcR[i2], vcG[i2], vcB[i2], 255); mesh.TexCoord(0, u0, v2); mesh.AdvanceVertex()
		end
	end
	mesh.End()
end

-- ---------------------------------------------------------------------------
-- A ripped artery: a short limp stub with a ragged, pale end and a bead of blood hanging from it
-- ---------------------------------------------------------------------------
-- Quad that always faces the viewer around the vertical axis and hangs down from `top` (drips, threads).
-- The texture's top edge is pinned to `top`.
local function drawHanging(mat, top, w, h, col, eye)
	local right = (top - eye):Cross(UP)
	if right:LengthSqr() < 1e-6 then right = Vector(1, 0, 0) end
	right:Normalize()
	right = right * (w * 0.5)
	local bot = top - UP * h
	local r, g, b, a = col.r, col.g, col.b, col.a
	render.SetMaterial(mat)
	mesh.Begin(MATERIAL_QUADS, 1)
	mesh.Position(top - right); mesh.Color(r, g, b, a); mesh.TexCoord(0, 0, 0); mesh.AdvanceVertex()
	mesh.Position(top + right); mesh.Color(r, g, b, a); mesh.TexCoord(0, 1, 0); mesh.AdvanceVertex()
	mesh.Position(bot + right); mesh.Color(r, g, b, a); mesh.TexCoord(0, 1, 1); mesh.AdvanceVertex()
	mesh.Position(bot - right); mesh.Color(r, g, b, a); mesh.TexCoord(0, 0, 1); mesh.AdvanceVertex()
	mesh.End()
end

-- last drip cycle seen per stub, so a falling drop is spawned exactly when the hanging one lets go
local dripCycle = {}
local dripCycleN = 0

-- sides: tube detail, age: seconds since the rip (nil = old), q: quality (-1 = minimal: tube only)
local function drawStub(root, out, def, L, seed, ct, eye, age, sides, q)
	local lateral = out:Cross(UP)
	if lateral:LengthSqr() < 1e-4 then lateral = Vector(1, 0, 0) end
	lateral:Normalize()

	local n = 4
	local sway = math.sin(ct * 1.9 + seed * 3.1) * 0.12
	local rx, ry, rz = root.x, root.y, root.z
	local a1 = L * 0.55
	local a2 = L * 0.72
	local a3 = L * sway
	local dc = def.col
	for k = 0, n do
		local t = k / n
		local t2 = t * t
		S_pts[k]:SetUnpacked(
			rx + out.x * (a1 * t) + lateral.x * (a3 * t2),
			ry + out.y * (a1 * t) + lateral.y * (a3 * t2),
			rz + out.z * (a1 * t) - a2 * t2 + lateral.z * (a3 * t2))
		S_rad[k] = def.r * Lerp(t, 1.15, 0.5)
		-- bloody and dark at the root, pale torn tissue at the end
		local m = t2 * 0.6
		S_r[k] = Lerp(m, dc[1] * 0.75, 235)
		S_g[k] = Lerp(m, dc[2] * 0.75, 150)
		S_b[k] = Lerp(m, dc[3] * 0.75, 140)
	end
	drawTube(S_pts, n, S_rad, S_r, S_g, S_b, eye, sides, 4)
	if q < 0 then return end

	local tip = S_pts[n]
	local tr = S_rad[n]

	-- loose fibres swaying at the torn end (always drawn, the sprite below adds the dense tuft)
	local tm = q >= 1 and tipMat()
	render.SetColorMaterial()
	local nf = tm and 2 or 4
	for j = 1, nf do
		local a = hash(seed, j + def.ang) * TAU
		local sw = math.sin(ct * 1.7 + seed * 1.3 + j * 2.1) * 0.22
		local d = out * 0.5 + (lateral * (math.cos(a) + sw) + UP * math.sin(a)) * 0.7 - UP * 0.5
		d:Normalize()
		local fl = L * (tm and 0.20 or 0.12) * (0.8 + 0.5 * hash(j, seed))
		render.DrawBeam(tip, tip + d * fl, tr * (tm and 0.32 or 0.55), 0, 1, colFray)
	end
	if tm then
		render.SetMaterial(tm)
		render.DrawSprite(tip, tr * 9, tr * 9, color_white)
	end

	local dm = dripMat()
	if dm then
		-- the drop swells at the end, pulls out into a thread and lets go; a real falling drop spawns at that moment
		local thick = math.sqrt(def.r / 0.2)
		local active = age ~= nil and age < 40
		local period = 1.3 + math.min(age or 40, 40) * 0.07
		local x = (ct + seed * 0.37) / period
		local ph = active and (x - math.floor(x)) or 0.4
		local grow = ph * ph
		local w = tr * 3.0 * (0.75 + 0.45 * ph)
		local h = w * (1.15 + 3.4 * grow * ph)
		if active then
			local cyc = math.floor(x)
			local last = dripCycle[seed]
			if last == nil or cyc < last then
				if last == nil then dripCycleN = dripCycleN + 1 end
				dripCycle[seed] = cyc
			elseif cyc > last then
				dripCycle[seed] = cyc
				if particlesAllowed(1) then
					ZCityGore.BloodDrops(tip - UP * h, -UP, 6, 1, 1.4 * thick)
				end
			end
		end
		drawHanging(dm, tip + UP * (tr * 0.4), w, h + tr * 0.4, color_white, eye)
	else
		-- no drip texture: the old swelling bead
		local swell = 0.5 + 0.5 * math.sin(ct * 2.2 + seed)
		local br = tr * (1.3 + 0.5 * swell)
		local bp = tip - UP * (br * 0.4)
		render.SetColorMaterial()
		render.DrawSphere(bp, br, 6, 6, colBead)
		render.DrawSphere(bp + Vector(0, 0, br * 0.35), br * 0.4, 5, 5, colBeadShine)
	end
end

-- ---------------------------------------------------------------------------
-- The bundle
-- ---------------------------------------------------------------------------
-- blood pooling where a vessel enters the flesh: glossy sprite, or the old sphere without the texture
local function drawEntryPool(pos, out, def, pulse, q)
	if q < 0 then return end
	local bm = q >= 1 and texMat("blood_blob")
	if bm then
		local sz = def.r * 5.2 * (1 + 0.10 * pulse)
		render.SetMaterial(bm)
		render.DrawSprite(pos + out * (def.r * 0.6), sz, sz * 1.1, color_white)
	else
		render.SetColorMaterial()
		render.DrawSphere(pos, def.r * 1.7, 6, 6, colBlob)
	end
end

-- low = true: cheap version for bundles beyond the detail budget (see the draw hook)
function ZCityGore.DrawArteryBundle(o, low)
	local defs = o.defs
	local n = #defs
	local a, b = o.anchor, o.cut
	local ct, eye = CurTime(), EyePos()
	local _, side, up2, dist = bundleBasis(o)
	local len = o.len
	local ratio = dist / math.max(len, 0.01)
	local slack = math.max(0, len - dist)
	local mid = (a + b) * 0.5

	-- level of detail: fewer sides / steps when far away or on a lower quality setting
	local q = cvQuality:GetInt()
	local d2 = eye:DistToSqr(mid)
	local sides, steps
	if low then
		q, sides, steps = -1, 4, 6
	elseif q <= 0 then
		sides, steps = 4, 8
	elseif q == 1 then
		sides, steps = (d2 < 250 * 250) and 6 or 4, 10
	elseif q == 2 then
		sides = (d2 < 250 * 250) and 8 or ((d2 < 700 * 700) and 6 or 4)
		steps = STEPS
	else
		sides = (d2 < 350 * 350) and 10 or ((d2 < 900 * 900) and 7 or 5)
		steps = 16
	end
	local lightStride = (q >= 3 and d2 < 350 * 350) and 1 or ((q >= 2 and d2 < 250 * 250) and 2 or 4)
	local tearAge = o.tearTime > 0 and (ct - o.tearTime) or nil
	local pr, pg, pb2 = S_r, S_g, S_b

	for i = 1, n do
		local def = defs[i]
		local offA, offB = strandOffsets(o, i, side, up2)
		local pa, pb = a + offA, b + offB

		if isTorn(o, i) then
			local sA, sB = stubSeed(o, i, false), stubSeed(o, i, true)
			drawStub(pa, o.outA, def, stubLen(def, sA), sA, ct, eye, tearAge, sides, q)
			drawStub(pb, o.outB, def, stubLen(def, sB), sB, ct, eye, tearAge, sides, q)
		elseif o.tethered then
			-- how close this strand is to ripping: it thins, blanches and quivers
			local sTear = ZCityGore.TearRatio(def, o.snapMul)
			local strain = math.Clamp((ratio - 1) / math.max(sTear - 1, 0.01), 0, 1)
			local neck = strain * strain

			local bow = side * (math.sin(o.seed * 1.7 + i * 2.3) * slack * 0.25)
			local ctrl = mid + (offA + offB) * 0.35 + bow - UP * (slack * 1.2 * def.droop)

			local mix = neck * 0.55
			local dc = def.col
			local c1, c2, c3 = Lerp(mix, dc[1], 238), Lerp(mix, dc[2], 150), Lerp(mix, dc[3], 140)

			local radiusMul = Lerp(neck, 1, 0.4)
			local pax, pay, paz = pa.x, pa.y, pa.z
			local cx, cy, cz = ctrl.x, ctrl.y, ctrl.z
			local bx, by, bz = pb.x, pb.y, pb.z
			for k = 0, steps do
				local t = k / steps
				local u = 1 - t
				local w0, w1, w2 = u * u, 2 * u * t, t * t
				local x, y, z = pax * w0 + cx * w1 + bx * w2, pay * w0 + cy * w1 + by * w2, paz * w0 + cz * w1 + bz * w2
				if neck > 0.05 then
					local j = neck * 0.10 * math.sin(math.pi * t)
					x, y, z = x + (math.random() * 2 - 1) * j, y + (math.random() * 2 - 1) * j, z + (math.random() * 2 - 1) * j
				end
				S_pts[k]:SetUnpacked(x, y, z)

				-- pressure wave travelling along the artery with the heartbeat: it swells AND flushes brighter
				local pw = math.max(0, math.sin(ct * 11 - t * 5 + i))
				local r = def.r * radiusMul * (1 + 0.14 * pw * (1 - neck))
				r = r * (1 - 0.34 * neck * math.sin(math.pi * t))
				-- slightly wider where it enters the flesh
				r = r * (1 + 0.3 * (1 - smooth01(t / 0.1)) + 0.3 * (1 - smooth01((1 - t) / 0.1)))
				S_rad[k] = r
				local boost = 1 + 0.18 * pw * (1 - neck)
				pr[k] = math.min(255, c1 * boost)
				pg[k] = c2 * boost
				pb2[k] = c3 * boost
			end
			drawTube(S_pts, steps, S_rad, pr, pg, pb2, eye, sides, lightStride)

			-- (the tiny side vessels that used to sprout from the main artery are gone: they were sub-pixel
			-- thin and showed up as the stray black lines on the arteries, and cost a whole extra tube each)

			-- about to rip: loose fibres peel away from the thinnest point
			if q >= 1 and neck > 0.45 then
				local mp = S_pts[math.floor(steps / 2)]
				local rmid = S_rad[math.floor(steps / 2)]
				local axisN = (pb - pa):GetNormalized()
				render.SetColorMaterial()
				for j = 1, 3 do
					local ang = hash(o.seed + j, i) * TAU
					local dd = side * math.cos(ang) + up2 * math.sin(ang)
					local fl = (0.35 + 0.9 * neck) * (0.6 + 0.4 * hash(j, i))
					local s0 = mp + dd * (rmid * 0.8)
					local s1 = mp + dd * (rmid + fl * 0.6) + axisN * (fl * 0.6 * (j - 2))
					render.DrawBeam(s0, s1, 0.03 + 0.04 * neck, 0, 1, colFray)
				end
			end

			-- blood pooling where the vessel enters the flesh at both ends
			if q >= 0 then
				local pulse = math.max(0, math.sin(ct * 11 + i))
				drawEntryPool(pa, o.outA, def, pulse, q)
				drawEntryPool(pb, o.outB, def, pulse, q)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Arterial jets: a visible stream of blood on a ballistic arc, pulsing with the heartbeat.
-- Drawn as a tapered ribbon that is cut short where it hits the world.
--
-- The world traces are the expensive part (7 per jet per frame before), so where a jet ends is cached
-- per jet and only re-traced ~10 times a second; far jets use fewer segments.
-- ---------------------------------------------------------------------------
local JET_GRAVITY = 620
local colJet = Color(122, 4, 8, 255)
local colJetHi = Color(238, 98, 90, 255)
local JET_MAX = 7
local jetPts = {}
for k = 0, JET_MAX do jetPts[k] = Vector() end
local jetCache, jetCacheN = {}, 0
local trStart, trEnd, trOut = Vector(), Vector(), {}
local trData = {start = trStart, endpos = trEnd, mask = MASK_SOLID_BRUSHONLY, output = trOut}

local function drawJet(key, p0, dir, speed, width, ct, phase, d2)
	if speed < 25 then return end
	local x0, y0, z0 = p0.x, p0.y, p0.z
	local vx, vy, vz = dir.x * speed, dir.y * speed, dir.z * speed
	local tmax = 0.30 + speed / 900
	local segs = d2 < 500 * 500 and JET_MAX or 4

	local c = jetCache[key]
	if not c then
		if jetCacheN > 400 then jetCache, jetCacheN = {}, 0 end
		c = {t = -1, segs = segs, cnt = segs, frac = 1, hit = false}
		jetCache[key] = c
		jetCacheN = jetCacheN + 1
	end

	if c.t < ct or c.segs ~= segs then
		c.t = ct + 0.09 + (key % 5) * 0.012
		c.segs, c.cnt, c.frac, c.hit = segs, segs, 1, false
		local px, py, pz = x0, y0, z0
		for cnt = 1, segs do
			local t = tmax * cnt / segs
			local x, y, z = x0 + vx * t, y0 + vy * t, z0 + vz * t - 0.5 * JET_GRAVITY * t * t
			trStart:SetUnpacked(px, py, pz)
			trEnd:SetUnpacked(x, y, z)
			util.TraceLine(trData)
			if trOut.Hit then
				c.cnt, c.frac, c.hit = cnt, trOut.Fraction, true
				break
			end
			px, py, pz = x, y, z
		end
	end

	local cnt = c.cnt
	-- rebuild the arc from the current start point, cut where the cached trace hit the world
	jetPts[0]:SetUnpacked(x0, y0, z0)
	for k = 1, cnt do
		local t = tmax * k / segs
		local x, y, z = x0 + vx * t, y0 + vy * t, z0 + vz * t - 0.5 * JET_GRAVITY * t * t
		if k == cnt and c.hit then
			local pp = jetPts[k - 1]
			local f = c.frac
			x, y, z = pp.x + (x - pp.x) * f, pp.y + (y - pp.y) * f, pp.z + (z - pp.z) * f
		end
		jetPts[k]:SetUnpacked(x, y, z)
	end
	if cnt < 1 then return end

	render.SetColorMaterial()
	render.StartBeam(cnt + 1)
	for k = 0, cnt do
		local u = k / cnt
		-- spurts travel along the stream; the far end thins out
		local w = width * (1 - 0.55 * u) * (0.65 + 0.35 * math.sin(ct * 38 - u * 9 + phase))
		render.AddBeam(jetPts[k], w, u, colJet)
	end
	render.EndBeam()

	-- wet glint along the top of the stream (skipped when far away, nobody sees it)
	if d2 < 600 * 600 then
		render.StartBeam(cnt + 1)
		for k = 0, cnt do
			local u = k / cnt
			local pt = jetPts[k]
			probe:SetUnpacked(pt.x, pt.y, pt.z + width * 0.18)
			render.AddBeam(probe, width * 0.28 * (1 - 0.7 * u), u, colJetHi)
		end
		render.EndBeam()
	end
end

function ZCityGore.DrawJets(o)
	local ct = CurTime()
	local bleeding = o.bleedUntil > ct
	local tearAge = o.tearTime > 0 and (ct - o.tearTime) or 1e9
	local pumping = o.mask ~= 0 and tearAge < 12
	if not bleeding and not pumping then return end

	local _, side, up2 = bundleBasis(o)
	local left = bleeding and math.Clamp((o.bleedUntil - ct) / o.bleedTotal, 0.25, 1) or 0.25
	local d2 = EyePos():DistToSqr(o.cut)
	local base = o.seed * 32

	for i = 1, #o.defs do
		local def = o.defs[i]
		local offA, offB = strandOffsets(o, i, side, up2)
		local pa, pb = o.anchor + offA, o.cut + offB
		local thick = math.sqrt(def.r / 0.2)
		local pulse = 0.5 + 0.5 * math.abs(math.sin(ct * 11 + i * 1.3))
		local torn = isTorn(o, i)

		if bleeding and not torn then
			local dir = o.outB + UP * 0.15
			dir:Normalize()
			drawJet(base + i * 4, pb, dir, (100 + 150 * pulse) * left, 0.34 * thick * (0.6 + 0.6 * pulse), ct, i, d2)
		end

		if torn and tearAge < 12 then
			local power = (1 - tearAge / 12) * (0.4 + 0.6 * pulse)
			local dirA = o.outA * 0.8 + UP * 0.25
			dirA:Normalize()
			local dirB = o.outB * 0.8 + UP * 0.25
			dirB:Normalize()
			local tipA = stubTip(pa, o.outA, stubLen(def, stubSeed(o, i, false)))
			local tipB = stubTip(pb, o.outB, stubLen(def, stubSeed(o, i, true)))
			drawJet(base + i * 4 + 1, tipA, dirA, 150 * power, 0.24 * thick * power, ct, i + 5, d2)
			drawJet(base + i * 4 + 2, tipB, dirB, 150 * power, 0.24 * thick * power, ct, i + 9, d2)
		end
	end
end

function ZCityGore.DrawBundleFor(ent, low)
	local o = ZCityGore.BundleFor(ent)
	if not o then return end
	if not low and cvJets:GetBool() and cvQuality:GetInt() >= 1 then ZCityGore.DrawJets(o) end
	if not o.tethered and o.mask == 0 then return end
	local dist = o.anchor:Distance(o.cut)
	if o.tethered and dist > o.len * (o.snapMul + 1.5) then return end
	ZCityGore.DrawArteryBundle(o, low)
end

-- Every hanging piece in range is drawn, nearest first. Only the nearest `zcity_gore_max_detailed` get the
-- full treatment (lighting, fibres, sprites, jets); the rest get a minimal tube, so a pile of dismembered
-- bodies costs a bounded amount per frame.
local drawEnts, drawDist = {}, {}
local function nearer(a, b) return drawDist[a] < drawDist[b] end

hook.Add("PostDrawOpaqueRenderables", "zcity_gore_artery_draw", function(bDepth, bSky, b3DSky)
	if bDepth or bSky or b3DSky then return end
	local eyePos = EyePos()
	local maxDist = cvDrawDist:GetFloat()
	maxDist = maxDist * maxDist

	local cnt = 0
	if hg and hg.clientSeveredLimbs then
		for ent in pairs(hg.clientSeveredLimbs) do
			if IsValid(ent) and not ent:IsDormant() then
				local d = ent:GetPos():DistToSqr(eyePos)
				if d <= maxDist then
					cnt = cnt + 1
					drawEnts[cnt], drawDist[ent] = ent, d
				end
			end
		end
	end

	for ent in pairs(ZCityGore.ClientLowers) do
		if not IsValid(ent) then
			ZCityGore.ClientLowers[ent] = nil
		elseif not ent:IsDormant() then
			local d = ent:GetPos():DistToSqr(eyePos)
			if d <= maxDist then
				cnt = cnt + 1
				drawEnts[cnt], drawDist[ent] = ent, d
			end
		end
	end

	for i = cnt + 1, #drawEnts do drawEnts[i] = nil end
	if cnt == 0 then return end
	if cnt > 1 then table.sort(drawEnts, nearer) end

	local full = cvMaxDetailed:GetInt()
	if full <= 0 then full = math.huge end
	for i = 1, cnt do
		ZCityGore.DrawBundleFor(drawEnts[i], i > full)
	end

	for k in pairs(drawDist) do drawDist[k] = nil end
end)

-- ---------------------------------------------------------------------------
-- Rip event from the server: blood bursts out of both torn ends
-- ---------------------------------------------------------------------------
net.Receive("zcity_gore_artery_tear", function()
	local idx = net.ReadUInt(16)
	local strand = net.ReadUInt(4)
	local final = net.ReadBool()
	local torso = net.ReadBool()

	local ent = Entity(idx)
	if not IsValid(ent) then return end
	local o = ZCityGore.BundleFor(ent)
	if not o or not o.defs[strand] then return end

	local _, side, up2 = bundleBasis(o)
	local offA, offB = strandOffsets(o, strand, side, up2)
	local pa, pb = o.anchor + offA, o.cut + offB

	local k = (final and 1.8 or 1.0) * (torso and 1.3 or 1)
	ZCityGore.TearBurst(pa, o.outA, k * 0.8, nil)
	ZCityGore.TearBurst(pb, o.outB, k, ent)
end)

-- ---------------------------------------------------------------------------
-- Arterial spray, mist and drips (per artery, each on its own beat)
-- ---------------------------------------------------------------------------
local sprayState = setmetatable({}, {__mode = "k"})
local sprayEm -- one emitter per handled piece instead of one per particle burst

local function sEm(pos)
	if not sprayEm then sprayEm = ParticleEmitter(pos) end
	return sprayEm
end

local function handleSpray(ent, ct, eye)
	local st = sprayState[ent]
	if st and st.idleUntil and st.idleUntil > ct then return end
	if ent:IsDormant() then return end
	local d2 = ent:GetPos():DistToSqr(eye)
	if d2 > SPRAY_DISTANCE_SQR then return end
	local o = ZCityGore.BundleFor(ent)
	if not o then return end

	local bleeding = o.bleedUntil > ct
	local tearAge = o.tearTime > 0 and (ct - o.tearTime) or 1e9
	local dripping = o.mask ~= 0 and tearAge < 40
	if not st then
		st = {next = {}, drip = {}}
		sprayState[ent] = st
	end
	if not bleeding and not dripping then
		st.idleUntil = ct + 0.25 -- nothing to spray: do not rebuild the bundle every tick
		return
	end
	st.idleUntil = nil

	-- distance level of detail: far pieces spray less often (and the budget below caps the rest)
	local lod = d2 < 300 * 300 and 1 or (d2 < 600 * 600 and 0.6 or 0.35)

	local _, side, up2, dist = bundleBasis(o)
	local left = bleeding and math.Clamp((o.bleedUntil - ct) / o.bleedTotal, 0.25, 1) or 0.25
	local center = o.cut

	for i = 1, #o.defs do
		local def = o.defs[i]
		local offA, offB = strandOffsets(o, i, side, up2)
		local pa, pb = o.anchor + offA, o.cut + offB
		local torn = isTorn(o, i)
		local thick = math.sqrt(def.r / 0.2)

		local pulse = 0.5 + 0.5 * math.abs(math.sin(ct * 11 + i * 1.3))
		local peak = pulse > 0.82

		if (st.next[i] or 0) <= ct and particlesAllowed(peak and 6 or 3) then
			st.next[i] = ct + (peak and 0.055 or math.Rand(0.10, 0.17)) / lod

			if bleeding then
				-- cut face of the piece: arterial spurt (Z-City's own blood particles, they leave decals)
				for _ = 1, peak and 2 or 1 do
					local vel = o.outB * ((100 + 150 * pulse) * left) + VectorRand(-18, 18)
					vel.z = vel.z + math.Rand(10, 40) * pulse
					local size = math.Rand(1.3, 2.3) * thick * (peak and 1.2 or 1)
					hg.addBloodPart(pb + VectorRand(-0.5, 0.5), vel, nil, size, size, true, true, ent)
				end
				if peak then ZCityGore.BloodMist(pb, o.outB, 90 * left, 1, 3 * thick, sEm(center)) end
			end

			if torn and tearAge < 12 then
				-- a ripped artery keeps pumping with the heartbeat and weakens as the victim bleeds out
				local power = (1 - tearAge / 12) * (peak and 1 or 0.55)
				local dirA = o.outA * 0.8 + UP * 0.25
				dirA:Normalize()
				local dirB = o.outB * 0.8 + UP * 0.25
				dirB:Normalize()
				local tipA = stubTip(pa, o.outA, stubLen(def, stubSeed(o, i, false)))
				local tipB = stubTip(pb, o.outB, stubLen(def, stubSeed(o, i, true)))
				local em = sEm(center)
				ZCityGore.BloodDrops(tipA, dirA, 150 * power, peak and 3 or 1, 1.3 * thick, em)
				ZCityGore.BloodDrops(tipB, dirB, 150 * power, peak and 3 or 1, 1.3 * thick, em)
				if peak then
					ZCityGore.BloodMist(tipA, dirA, 70 * power, 1, 3 * thick, em)
					ZCityGore.BloodMist(tipB, dirB, 70 * power, 1, 3 * thick, em)
				end
			end
		end

		-- slow drips from the loose ends
		-- (with the drip texture the hanging drops spawn their own falling drop, see drawStub)
		if torn and dripping and not dripMat() and (st.drip[i] or 0) <= ct and particlesAllowed(2) then
			st.drip[i] = ct + math.min(0.3 + tearAge * 0.03, 1.6) + math.Rand(0, 0.25)
			local tipA = stubTip(pa, o.outA, stubLen(def, stubSeed(o, i, false)))
			local tipB = stubTip(pb, o.outB, stubLen(def, stubSeed(o, i, true)))
			local em = sEm(center)
			ZCityGore.BloodDrops(tipA, -UP, 12, 1, 1.4 * thick, em)
			ZCityGore.BloodDrops(tipB, -UP, 12, 1, 1.4 * thick, em)
		end
	end

	-- blood runs down the slack bundle and drips off its lowest point
	if bleeding and o.tethered and (st.midDrip or 0) <= ct and particlesAllowed(1) then
		st.midDrip = ct + math.Rand(0.35, 0.6)
		local slack = math.max(0, o.len - dist)
		local low = (o.anchor + o.cut) * 0.5 - UP * (slack * 0.6)
		ZCityGore.BloodDrops(low, -UP, 10, 1, 1.6, sEm(center))
	end

	if sprayEm then
		sprayEm:Finish()
		sprayEm = nil
	end
end

local sprayList = {}
local sprayRot, nextSpray = 0, 0

hook.Add("Think", "zcity_gore_artery_spray", function()
	if not istable(hg) or not hg.addBloodPart then return end
	local ct = CurTime()
	-- the fastest per-strand timer is 0.055 s, running this every tick is wasted work
	if ct < nextSpray then return end
	nextSpray = ct + 0.03
	local eye = EyePos()

	local cnt = 0
	if hg.clientSeveredLimbs then
		for ent in pairs(hg.clientSeveredLimbs) do
			if IsValid(ent) then
				cnt = cnt + 1
				sprayList[cnt] = ent
			end
		end
	end
	for ent in pairs(ZCityGore.ClientLowers) do
		if IsValid(ent) then
			cnt = cnt + 1
			sprayList[cnt] = ent
		end
	end
	for i = cnt + 1, #sprayList do sprayList[i] = nil end
	if cnt == 0 then return end

	-- start at a different piece every time so the particle budget is shared fairly
	sprayRot = (sprayRot + 1) % cnt
	for j = 0, cnt - 1 do
		handleSpray(sprayList[(j + sprayRot) % cnt + 1], ct, eye)
	end
end)
