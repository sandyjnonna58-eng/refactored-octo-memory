-- Droplet impacts.
-- Outcome is driven by physically motivated quantities rather than fixed effects:
--   * splash parameter K = sqrt(We) * Re^(1/4) from the normal impact speed and drop size
--     (below ~57 a smooth deposit, above ~160 spines + satellites, above ~420 airborne
--     secondary droplets), scaled by the substrate's splash tendency,
--   * impact angle: stain width/length ~ sin(angle), tail and satellites downstream,
--   * spread factor ~ Re^(1/4) for the final stain diameter,
--   * wet surfaces absorb the drop into the existing pool (smaller splash, pool growth),
--   * substrate: absorbent surfaces soak (fuzzy, no runoff), hard ones keep crisp drops and
--     allow runoff; walls/slopes feed runoff, ceilings form hanging drops.
-- These relationships are used as guidance, not as exact forensic equations.

ABL.NoJIT()
ABL.Impacts = ABL.Impacts or {}
local I = ABL.Impacts
local C, S, L = ABL.Config, ABL.Stains, ABL.LOD
local IC = C.Impact
local sqrt, min, max, abs, floor = math.sqrt, math.min, math.max, math.abs, math.floor

I.recent = {} -- ring of recent impacts for the debug overlay
local recentIdx = 0

local function Remember(x, y, z, nx, ny, nz, K, kind)
	if C.cl.debug:GetInt() == 0 then return end
	recentIdx = recentIdx % 64 + 1
	local r = I.recent[recentIdx] or {}
	r.x, r.y, r.z, r.nx, r.ny, r.nz, r.K, r.kind, r.t = x, y, z, nx, ny, nz, K, kind, CurTime()
	I.recent[recentIdx] = r
end

------------------------------------------------------------------------------------------
-- Sounds (rate limited, Z-City's drip sounds when available, HL2 drips otherwise)
------------------------------------------------------------------------------------------
local dripSounds
local nextSound = 0
local function DripSound(x, y, z, vol, metal)
	if not C.cl.sounds:GetBool() then return end
	local now = RealTime()
	if now < nextSound then return end
	local dx, dy, dz = x - L.eyeX, y - L.eyeY, z - L.eyeZ
	if dx * dx + dy * dy + dz * dz > 450 * 450 then return end
	nextSound = now + 0.07
	if not dripSounds then
		dripSounds = {}
		for i = 1, 4 do
			if file.Exists("sound/homigrad/blooddrip" .. i .. ".wav", "GAME") then dripSounds[#dripSounds + 1] = "homigrad/blooddrip" .. i .. ".wav" end
		end
		if #dripSounds == 0 then dripSounds = { "ambient/water/drip1.wav", "ambient/water/drip2.wav", "ambient/water/drip3.wav", "ambient/water/drip4.wav" } end
	end
	local snd = dripSounds[math.random(#dripSounds)]
	local level = math.Clamp(45 + vol * 150, 45, 70)
	sound.Play(snd, Vector(x, y, z), level, math.Clamp((metal and 115 or 100) - vol * 60 + math.random(-8, 8), 70, 140), math.Clamp(0.25 + vol * 3, 0.2, 0.9))
end

------------------------------------------------------------------------------------------
-- Main entry
------------------------------------------------------------------------------------------
function I.Handle(d, tr)
	local hp, n = tr.HitPos, tr.HitNormal
	local x, y, z = hp.x, hp.y, hp.z
	local nx, ny, nz = n.x, n.y, n.z
	-- (no surface there: the trace began inside something. The caller drops the drop: its blood is
	-- written off, not left booked as flying)
	if nx == 0 and ny == 0 and nz == 0 then
		ABL.FlowCore.Move("airborne", "lost", d.vol)
		return
	end
	local surf = ABL.Surface.FromTrace(tr)
	local ent = tr.Entity
	if not IsValid(ent) then ent = nil end

	local vol = d.vol
	local vx, vy, vz = d.vx, d.vy, d.vz
	local sp = sqrt(vx * vx + vy * vy + vz * vz)
	local vdot = vx * nx + vy * ny + vz * nz
	local vn = max(-vdot, 0)                             -- normal impact speed
	local tx, ty, tz = vx - nx * vdot, vy - ny * vdot, vz - nz * vdot
	local vt = sqrt(tx * tx + ty * ty + tz * tz)          -- tangential speed
	local sinA = sp > 1e-3 and vn / sp or 1
	if vt > 1e-3 then tx, ty, tz = tx / vt, ty / vt, tz / vt else tx, ty, tz = nil, nil, nil end

	-- dimensionless impact numbers (SI)
	local dmm = ABL.DropDiameterMM(vol)
	local Dm = dmm / 1000
	local vms = vn * 0.0254
	local We = IC.rho * vms * vms * Dm / IC.sigma
	local Re = IC.rho * vms * Dm / IC.mu
	local K = sqrt(We) * (max(Re, 1) ^ 0.25) * surf.splash

	local gx, gy, gz, gmag = ABL.Gravity()
	local up = -(nx * gx + ny * gy + nz * gz) / gmag      -- 1 floor, 0 wall, -1 ceiling
	local rng = d.src and d.src.rng or ABL.RNG(floor(x * 13 + y * 7 + z * 3 + CurTime() * 100))
	local tierSec, tierSat = 1, 1
	if d.src and C.LODTiers[d.src.lod] then
		tierSec, tierSat = C.LODTiers[d.src.lod].secondary, C.LODTiers[d.src.lod].satellites
	elseif (d.hz or 60) < 80 then
		tierSec, tierSat = 0, 0.4
	end

	-- landing in existing blood
	local wetVol = ABL.Surface.WetGet(x, y, z)
	local pool = up > 0.6 and ABL.Pools.Find(x, y, z, nx, ny, nz, 1.5) or nil
	if pool then
		local fed = vol
		if K > IC.kCrown and d.gen < IC.maxGeneration and tierSec > 0 then
			-- crown splash from the pool surface (what it throws up does not stay in the pool)
			local nsec = min(IC.maxSecondary, 1 + floor((K - IC.kCrown) / IC.kCrown))
			for _ = 1, nsec do
				local ex, ey, ez = ABL.Emission.Cone(rng, nx, ny, nz, 0.9)
				local s = vn * rng:Range(0.1, 0.25)
				local sv = vol * rng:Range(0.02, 0.06)
				fed = fed - sv
				ABL.Drops.Spawn(x + nx * 0.4, y + ny * 0.4, z + nz * 0.4, ex * s + (tx or 0) * vt * 0.2, ey * s + (ty or 0) * vt * 0.2, ez * s + (tz or 0) * vt * 0.2, sv, d.src, d.gen + 1, 3, "air", d.owner)
			end
		end
		ABL.FlowCore.Move("airborne", "pool", fed)
		ABL.Pools.Feed(pool, fed, x, y, z, "impact", tx, ty, tz, K)
		DripSound(x, y, z, vol * 0.7, false)
		Remember(x, y, z, nx, ny, nz, K, "pool")
		if d.src then ABL.Wounds.Ledger(d.src, "pool", vol) end
		return
	end
	local wet = wetVol > 0.08

	-- secondary droplets (splash break-up); their volume leaves the stain
	local stainVol = vol
	if K > IC.kBreakup and d.gen < IC.maxGeneration and tierSec > 0 and not surf.soak then
		local nsec = min(IC.maxSecondary, 1 + floor((K - IC.kBreakup) / IC.kBreakup * 3))
		nsec = floor(nsec * tierSec * (wet and 0.5 or 1) + 0.5)
		for _ = 1, nsec do
			local sv = vol * rng:Range(0.025, 0.09)
			stainVol = stainVol - sv
			-- glancing impacts throw secondaries forward, perpendicular ones form a crown
			local fx, fy, fz
			if tx and sinA < 0.8 then
				fx, fy, fz = ABL.Emission.Cone(rng, tx + nx * 0.35, ty + ny * 0.35, tz + nz * 0.35, 0.5)
			else
				fx, fy, fz = ABL.Emission.Cone(rng, nx, ny, nz, 1.25)
			end
			local s = (vt * rng:Range(0.25, 0.6) + vn * rng:Range(0.1, 0.3))
			ABL.Drops.Spawn(x + nx * 0.3, y + ny * 0.3, z + nz * 0.3, fx * s, fy * s, fz * s, sv, d.src, d.gen + 1, 3, "air", d.owner)
		end
	end

	-- very glancing, fast impacts: the drop skims the surface, lays down a long tail, and part of it
	-- lifts off the far end and carries on downstream (wave cast-off / skipping drop)
	if tx and sinA < 0.4 and vt > 70 and vol > 0.004 and d.gen < IC.maxGeneration and tierSec > 0 and not surf.soak then
		local sv = vol * rng:Range(0.2, 0.35) * (1 - sinA / 0.4)
		stainVol = stainVol - sv
		local s = vt * rng:Range(0.45, 0.65)
		local lift = vn * 0.08 + 6
		ABL.Drops.Spawn(x + nx * 0.4 + tx * 0.8, y + ny * 0.4 + ty * 0.8, z + nz * 0.4 + tz * 0.8,
			tx * s + nx * lift, ty * s + ny * lift, tz * s + nz * lift, sv, d.src, d.gen + 1, 3, "air", d.owner)
	end

	-- stain geometry
	local spread = max(1.25, 0.5 * (max(Re, 1) ^ 0.25)) * surf.spread * (wet and 1.15 or 1)
	local stainD = dmm * spread / 25.4 * 1.25            -- world units
	stainD = math.Clamp(stainD, 0.18, 9)
	local col = C.Colors.decal
	local tint = surf.tint
	local dc = { col[1] * tint[1], col[2] * tint[2], col[3] * tint[3] }
	local alpha = math.Clamp(235 * surf.alpha * (0.7 + 0.3 * min(vol / 0.05, 1)), 90, 255)
	local wetT = C.Stain.dryBase * ((vol / 0.05) ^ 0.35) / surf.dry

	local FC = ABL.FlowCore
	-- (phase 21, C.P21.handover: on a floor, where the blood goes is settled first, so that the drop's
	-- stain can be told which pool holds its blood, or which drops collecting toward one. The stain
	-- carries the drop's liquid as before until that pool's layer covers it, and then gives it up: the
	-- pool shows it from then on, cl_pools.lua HandoverThink.)
	local hand = up > 0.64 and C.P21On ~= nil and C.P21On("handover")
	local into, seed
	if hand then
		FC.Move("airborne", "pool", stainVol)
		into, seed = ABL.Pools.Deposit(x, y, z, n, stainVol, surf, ent, "drip", tx, ty, tz, K, d.owner)
	end

	local kind
	if not ent then
		-- the world (floor, wall, ceiling): ABL's own capped stains, with the liquid's body on them.
		-- (Until phase 36 walls and ceilings had engine decals: a grey film without a body.)
		kind = up > 0.64 and "ground" or "wall"
		local hd = ABL.Ground.Impact(x, y, z, nx, ny, nz, vol, stainD, sinA, tx, ty, tz, K, surf, rng, wetT, stainVol, d.owner)
		if hd and into then ABL.Pools.PoolStain(into, hd) elseif hd and seed then ABL.Pools.SeedStain(seed, hd) end
	else
		if L.PointImportance(x, y, z) < 0.05 then wetT = 0 end
		kind = I.WallStain(surf, x, y, z, nx, ny, nz, tx, ty, tz, stainD, sinA, K, vol, dc, alpha, ent, wetT, rng, tierSat)
	end

	-- where the deposited blood goes next
	local tau = C.Stain.dryBase * 2 / surf.dry
	ABL.Surface.WetAdd(x, y, z, stainVol, tau)
	if up > 0.64 then
		-- (the stain is the picture; the blood is in the pool, or in what will be one)
		if not hand then
			FC.Move("airborne", "pool", stainVol)
			ABL.Pools.Deposit(x, y, z, n, stainVol, surf, ent, "drip", tx, ty, tz, K, d.owner)
		end
	elseif up < -0.4 then
		if not surf.soak and ABL.Runoff.Pendant(x, y, z, nx, ny, nz, stainVol, surf, ent, d.owner) then
			FC.Move("airborne", "surface", stainVol)
		else
			FC.Land(stainVol, surf.soak and surf.absorb or 0)
		end
	else
		-- on a wall it is a wet stain; a rivulet takes its blood out of the stains when one forms
		FC.Land(stainVol, surf.soak and surf.absorb or 0)
		if not surf.soak and surf.runoff > 0.15 then ABL.Runoff.Deposit(x, y, z, nx, ny, nz, stainVol, surf, ent, d.owner) end
	end

	DripSound(x, y, z, vol, surf.name == "metal")
	Remember(x, y, z, nx, ny, nz, K, kind)
	if d.src then ABL.Wounds.Ledger(d.src, kind == "ground" and "ground" or "wall", stainVol) end
end

-- Engine-decal stain for what is not the world (props, bodies that are no characters). Returns the kind.
function I.WallStain(surf, x, y, z, nx, ny, nz, tx, ty, tz, stainD, sinA, K, vol, dc, alpha, ent, wetT, rng, tierSat)
	local IC = C.Impact
	local kind
	if surf.soak then
		kind = "soak"
		local w = stainD * 1.35 / 0.62
		S.Place("soak", ABL.Mat.Random("soak", rng), x, y, z, nx, ny, nz, tx, ty, tz, w, w, dc, alpha * 0.85, ent, wetT * 0.6, rng)
	elseif sinA < 0.82 and tx then
		kind = "elong"
		-- width/length = sin(angle); the texture's main ellipse is ~2.1:1 across 21% of its width
		local elong = math.Clamp(1 / max(sinA, 0.2), 1, 5)
		local across = stainD * 0.9
		local h = across / 0.42
		local w = h * max(1, elong / 2.1)
		S.Place("elong", ABL.Mat.Random("elong", rng), x, y, z, nx, ny, nz, tx, ty, tz, w, h, dc, alpha, ent, wetT, rng)
	elseif K > IC.kCrown then
		kind = "splat"
		local w = stainD / 0.37
		S.Place("splat", ABL.Mat.Random("splat", rng), x, y, z, nx, ny, nz, tx, ty, tz, w, w, dc, alpha, ent, wetT, rng)
	else
		kind = "drop"
		local w = stainD / 0.64
		S.Place("drop", ABL.Mat.Random("drop", rng), x, y, z, nx, ny, nz, nil, nil, nil, w, w, dc, alpha, ent, wetT, rng)
	end

	-- satellite droplets around energetic impacts (downstream on oblique impacts)
	if K > IC.kDeposit * 1.4 and not surf.soak and tierSat > 0 and rng:Next() < tierSat * min(1, (K - IC.kDeposit) / IC.kCrown) then
		local w = stainD * rng:Range(2.6, 4.2)
		S.Place("sat", ABL.Mat.Random("sat", rng), x, y, z, nx, ny, nz, tx, ty, tz, w, w, dc, alpha * 0.9, ent, 0, rng)
	end
	return kind
end
