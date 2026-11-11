-- Pendant drops (phase 19, C.V19.pendant): blood waiting at an edge of a body's film to drop
-- (cl_film.lua, s.out) is drawn as a drop that swells there and lets go.
-- Each cell that holds blood on its way off the body gets a small lit body of liquid at its place
-- on the skin: a low dome while little has gathered (a swelling of the film), a drop on a neck once
-- nearly enough for a drop has. It is a read-only view of s.out: nothing here changes how much
-- blood there is or where it is booked.
--   * Its size is true to the volume drawn (a sphere of that much blood), no larger than a drop of
--     K.dropVol x dropK: a body that lets go of larger drops (dropBig) shows that as drops that
--     come more often, not as a bulb that hangs 9 mm wide.
--   * What is drawn follows what waits over C.V19.pendTau of the game's time (what waits grows in
--     the film's steps, 20 a second); when the cell lets go, its pendant is gone in that frame and
--     its drop is there instead (FP.SpawnAt puts the drop where the bulb hung).
--   * Geometry: static shapes of a unit drop, one for each twentieth of the fill, built once and
--     drawn under a model matrix with one scale for all three axes (the normals stay normals).
--   * Light: as the body's own liquid is lit, by the engine's account of the place
--     (render.ComputeLighting for six faces, kept in colour) as the light from all round, and the
--     one light fitted from those six for the highlight; found once a body every 0.3 s and gone
--     over to from the last over that time, not in a step. Its colour is the film's liquid colour at
--     the cell, as the film's liquid pass draws it (cl_filmdraw.lua: the canvas's colour, the
--     liquid's tint and the share of the cloth's texture that shows in it).
-- Drawn from ABL.Flow.DrawSource right after the film (cl_bodyflow.lua), with the pose the body
-- was drawn in.

ABL.NoJIT()
ABL.FilmPendant = ABL.FilmPendant or {}
local FP = ABL.FilmPendant
local C, L = ABL.Config, ABL.LOD
local K = C.Film
local ML = C.ML_PER_CU
local sqrt, min, max, exp, cos, sin, abs, floor, pi = math.sqrt, math.min, math.max, math.exp, math.cos, math.sin, math.abs, math.floor, math.pi

-- (materials are made once under their names and kept by the engine: another name when what they
-- are made of changes; the shapes are made again when it changes)
local VER = "2"
-- what is counted, for the tests (cl_v19test.lua): bodies drawn with pendants, pendants drawn,
-- light fits, drops placed by SpawnAt and how many of them where a pendant had just been drawn
FP.stats = FP.stats or { bodies = 0, drawn = 0, fits = 0, spawns = 0, fresh = 0 }
local stats = FP.stats

------------------------------------------------------------------------------------------
-- The shapes
------------------------------------------------------------------------------------------
-- A unit drop along its axis z (out of the skin), in units of the bulb's radius: the profile of a
-- body of revolution, from inside the skin (z < 0) to the bulb's tip. At fill f the bulb's centre
-- stands zc(f) out: below the skin at small fill, where what shows is a low cap of it (a swelling
-- of the film), 1.4 radii out at fill 1. From a fill of about two thirds a neck grows between the
-- skin and the bulb, 0.3 radii wide at fill 1, with a foot that flares into the film. Under the
-- skin the shape closes on its axis (ZB): drawn at a slant to the skin (a drop on a side hangs
-- downhill), the part of it that comes up out of the skin on the uphill side is its own smooth
-- surface, and nothing open is seen.
-- (twenty fills, not ten: near a drop's release its bulb moves out by 0.3 radii between two tenths,
-- some 0.6 mm, a step of most of a pixel from 30 units away)
local NS, NR, NFILL = 12, 20, 20
local ZB = -0.8
local DENSE = 240
local SHAPES, ZC = FP.shapes or {}, FP.zc or {}
FP.shapes, FP.zc = SHAPES, ZC

local function Smooth01(a, b, x)
	local t = (x - a) / (b - a)
	if t <= 0 then return 0 elseif t >= 1 then return 1 end
	return t * t * (3 - 2 * t)
end

-- The profile's radius at height z: the larger of the bulb's and the neck's, joined smoothly.
local function Rho(z, zc, q, rn, rf, zj)
	local dz = z - zc
	local rs = 1 - dz * dz
	rs = rs > 0 and sqrt(rs) or 0
	local rk = 0
	if q > 0 then
		if z < 0 then
			rk = rf * (1 + 0.4 * (z < -0.5 and 0.5 or -z))
		else
			-- (from the foot to the neck as a smooth fillet, level at both ends)
			local u = z / zj
			rk = u >= 1 and rn or rn + (rf - rn) * (0.5 + 0.5 * cos(pi * u))
		end
		-- (the neck ends inside the bulb)
		rk = rk * q * (1 - Smooth01(zc - 0.6, zc, z))
	end
	local r = (rs ^ 6 + rk ^ 6) ^ (1 / 6)
	if z < 0 then
		local e = 1 - (z / ZB) ^ 2
		r = r * (e > 0 and sqrt(e) or 0)
	end
	return r
end

local pv, nv = Vector(), Vector()
local DR, DZ, DS = {}, {}, {}
local RR, RZ, RN, RZN = {}, {}, {}, {}

-- One shape (fill f): its static mesh and how far out its bulb's centre stands. (Made with no
-- material: the default vertex format holds the normal, the userdata tangent and the texcoord as
-- they are written below, as cl_woundfx.lua's lit forms are made. A VertexLitGeneric material's
-- format is a compressed one, which takes these written as plain floats for something else.)
local function BuildShape(f)
	local zc = -0.6 + 2 * f ^ 1.6
	local q = Smooth01(0.55, 1, f)
	local rn, rf = 0.15 + 0.35 * (1 - q), 0.5 + 0.3 * (1 - q)
	local zj = max(0.3, zc - 1)
	local ztop = zc + 1
	-- the profile, densely, and its length along the way (what lies under the skin counts for
	-- less: fewer rings are spent there)
	local acc = 0
	for i = 0, DENSE do
		local z = ZB + (ztop - ZB) * i / DENSE
		local r = (i == 0 or i == DENSE) and 0 or Rho(z, zc, q, rn, rf, zj)
		if i > 0 then
			local dr, dz = r - DR[i], z - DZ[i]
			acc = acc + sqrt(dr * dr + dz * dz) * (z > 0 and 1 or 0.35)
		end
		DR[i + 1], DZ[i + 1], DS[i + 1] = r, z, acc
	end
	-- NR rings, evenly along it, each with the way the surface faces there (square to the profile)
	local i = 1
	for j = 1, NR do
		local sj = acc * (j - 1) / (NR - 1)
		while i < DENSE and DS[i + 1] < sj do i = i + 1 end
		local s0, s1 = DS[i], DS[i + 1]
		local t = s1 > s0 and (sj - s0) / (s1 - s0) or 0
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
		RR[j] = DR[i] + (DR[i + 1] - DR[i]) * t
		RZ[j] = DZ[i] + (DZ[i + 1] - DZ[i]) * t
		local a, b = max(1, i - 1), min(DENSE + 1, i + 2)
		local tr, tz = DR[b] - DR[a], DZ[b] - DZ[a]
		local l = sqrt(tr * tr + tz * tz)
		if l < 1e-9 then RN[j], RZN[j] = 0, 1 else RN[j], RZN[j] = tz / l, -tr / l end
	end
	RR[1], RR[NR] = 0, 0
	RN[1], RZN[1], RN[NR], RZN[NR] = 0, -1, 0, 1
	local ms = Mesh()
	mesh.Begin(ms, MATERIAL_TRIANGLES, (NR - 1) * NS * 2)
	-- (a vertex: its normal, and the way its texture's u runs as its tangent, as cl_woundfx.lua
	-- gives its forms theirs: the lit shader's relief needs one)
	local function V(j, k)
		local a = k / NS * 2 * pi
		local ca, sa = cos(a), sin(a)
		pv:SetUnpacked(RR[j] * ca, RR[j] * sa, RZ[j])
		nv:SetUnpacked(RN[j] * ca, RN[j] * sa, RZN[j])
		mesh.Position(pv)
		mesh.Normal(nv)
		mesh.UserData(-sa, ca, 0, 1)
		mesh.TexCoord(0, k / NS, (j - 1) / (NR - 1))
		mesh.AdvanceVertex()
	end
	-- (rings from the bottom up, sides round the axis the right way: each face is clockwise as seen
	-- from outside, the side the engine keeps, as the drops' in cl_droplets.lua are)
	for j = 1, NR - 1 do
		for k = 0, NS - 1 do
			V(j, k) V(j + 1, k) V(j, k + 1)
			V(j, k + 1) V(j + 1, k) V(j + 1, k + 1)
		end
	end
	mesh.End()
	return ms, zc
end

-- Materials, the flat relief they share and the shapes: once, where render targets may be set
-- (a render hook outside the view), the first time a pendant is to be drawn.
local function Prepare()
	FP.want = false
	if FP.ready and FP.readyVer == VER then return end
	if not FP.flat then
		FP.flat = GetRenderTargetEx("abl_pend_flat", 4, 4, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)
	end
	render.PushRenderTarget(FP.flat)
	render.Clear(128, 128, 255, 255, false, false)
	render.PopRenderTarget()
	FP.flatAt = RealTime() + 8
	local flat = FP.flat:GetName()
	-- The colour: lit as a model is, by the light set when it is drawn (white times $color2, the
	-- film's liquid colour there). With a relief (a flat one) the shader lights it per pixel.
	FP.mCol = FP.mCol or CreateMaterial("abl_pend_col" .. VER, "VertexLitGeneric", {
		["$basetexture"] = "color/white", ["$bumpmap"] = flat, ["$halflambert"] = 1 })
	-- The highlight: added, with no colour of its own (cl_filmdraw.lua's shine pass, as a drop: a
	-- wider lobe than the film's, whose 130 is under a pixel on a drop of 2 mm and twinkles)
	local e = C.V19.pendExp or 30
	local name = "abl_pend_shine" .. VER .. "_" .. e
	if FP.mShineName ~= name or not FP.mShine then
		FP.mShine = CreateMaterial(name, "VertexLitGeneric", {
			["$basetexture"] = "color/white", ["$bumpmap"] = flat, ["$additive"] = 1, ["$color2"] = "[0 0 0]",
			["$phong"] = 1, ["$phongexponent"] = e, ["$phongboost"] = C.V19.pendBoost or 0.8, ["$phongfresnelranges"] = "[0.25 0.55 1]" })
		FP.mShineName = name
	end
	FP.shineBoost = nil
	for i = 1, NFILL do
		if SHAPES[i] and SHAPES[i].Destroy then SHAPES[i]:Destroy() end
		SHAPES[i], ZC[i] = BuildShape(i / NFILL)
	end
	FP.ready, FP.readyVer = true, VER
end
hook.Add("PreRender", "ABL_FilmPendant", function()
	-- (a render target does not outlive everything a game's window goes through: the flat relief is
	-- cleared again every 8 s while pendants are drawn, as cl_woundfx.lua's W.Prepare does its own)
	local now = RealTime()
	if FP.ready and FP.flat and FP.usedT and now - FP.usedT < 1 and now >= (FP.flatAt or 0) then
		FP.flatAt = now + 8
		render.PushRenderTarget(FP.flat)
		render.Clear(128, 128, 255, 255, false, false)
		render.PopRenderTarget()
	end
	if not FP.want then return end
	-- (what fails here fails for the session: one line, and no pendants)
	local ok, err = pcall(Prepare)
	if not ok then
		FP.want, FP.failed = false, true
		ABL.Print("pendant drops are not drawn: %s", tostring(err))
	end
end)

------------------------------------------------------------------------------------------
-- State per film (s.fpend) and per cell in it
------------------------------------------------------------------------------------------
-- vd: the volume drawn (ml); ot: the time the cell's blood began to wait, as cl_film.lua keeps it
-- (another one: it has let go and gathers anew); cr, cg, cb: the colour drawn (eased);
-- px, py, pz, pt: the attach point at its last measuring (CurTime), vx, vy, vz: its velocity;
-- dt: when the pendant was last drawn (CurTime), cx, cy, cz: its bulb's centre then, qx, qy, qz
-- and mx, my, mz: the attach point and the way the skin faced, ax, ay, az: the way it hung.
local CELLS = { "vd", "ot", "cr", "cg", "cb", "px", "py", "pz", "pt", "vx", "vy", "vz", "dt",
	"cx", "cy", "cz", "qx", "qy", "qz", "mx", "my", "mz", "ax", "ay", "az" }
-- Of the body: L, kx .. kb, the light found at the last fit (six faces in colour, the one light's
-- way and colour), and S, skx .. skb, the light drawn with, which goes over to that (shown: there
-- is a light drawn with); dlr, dlg, dlb: the light a drop that leaves starts with.
local function NewState()
	local pd = { litT = 0, lok = false, shown = false, L = {}, S = {}, kx = 0, ky = 0, kz = 1, kr = 0, kg = 0, kb = 0,
		skx = 0, sky = 0, skz = 1, skr = 0, skg = 0, skb = 0, dlr = 1, dlg = 1, dlb = 1 }
	for i = 1, #CELLS do pd[CELLS[i]] = {} end
	for i = 1, 18 do pd.L[i], pd.S[i] = 0, 0 end
	return pd
end
local function Forget(pd, c)
	for i = 1, #CELLS do pd[CELLS[i]][c] = nil end
end

-- The velocity of the place a pendant hangs from, as it was last drawn (units a second, in the
-- game's time); nil when it was not drawn in the last 0.2 s.
local FRESH = 0.2
function FP.Velocity(s, c)
	local pd = s and s.fpend
	local t = pd and pd.pt[c]
	if not t or CurTime() - t > FRESH then return nil end
	return pd.vx[c], pd.vy[c], pd.vz[c]
end

-- The light a drop that leaves cell c of film s starts with (as ABL.Render.Light gives it: display
-- values), when its pendant was drawn just now; nil otherwise (cl_droplets.lua, D.Link).
function FP.LightFor(s, c)
	local pd = istable(s) and s.fpend
	if not pd or not pd.lok then return nil end
	local t = pd.dt[c]
	if not t or CurTime() - t > FRESH then return nil end
	return pd.dlr, pd.dlg, pd.dlb
end

------------------------------------------------------------------------------------------
-- Which way it hangs, and how large it is
------------------------------------------------------------------------------------------
-- The way a pendant hangs from a place whose surface faces n, with gravity g (both unit), at fill f.
-- On a side: out of the skin and down it, along the way downhill there (t: g less what of it goes
-- along n), the more down it the fuller it is. Under a place that faces down (n . g over 0.3):
-- straight down. (Between n . g of 0.2 and 0.4 the one goes over to the other, so that a limb that
-- turns does not swing its drops round in a frame.) Where nothing is downhill (the place faces up
-- or down), along n.
local function Axis(nx, ny, nz, gx, gy, gz, f)
	local gn = gx * nx + gy * ny + gz * nz
	local tx, ty, tz = gx - gn * nx, gy - gn * ny, gz - gn * nz
	local tl = sqrt(tx * tx + ty * ty + tz * tz)
	local ax, ay, az
	if tl < 0.1 then
		ax, ay, az = nx, ny, nz
	else
		local k = (0.4 + 0.6 * f) / tl
		ax, ay, az = 0.6 * nx + tx * k, 0.6 * ny + ty * k, 0.6 * nz + tz * k
		local l = sqrt(ax * ax + ay * ay + az * az)
		ax, ay, az = ax / l, ay / l, az / l
	end
	local w = Smooth01(0.2, 0.4, gn)
	if w > 0 then
		ax, ay, az = ax + (gx - ax) * w, ay + (gy - ay) * w, az + (gz - az) * w
		local l = sqrt(ax * ax + ay * ay + az * az)
		if l < 1e-6 then return gx, gy, gz end
		ax, ay, az = ax / l, ay / l, az / l
	end
	return ax, ay, az
end

-- The radius (units) of a sphere of vol ml, at the size drops are drawn (abl_drop_size).
local function Radius(vol, scale)
	return (3 * vol / (4 * pi * ML)) ^ (1 / 3) * scale
end

------------------------------------------------------------------------------------------
-- Its colour
------------------------------------------------------------------------------------------
local P = K.palette
local function Mix3(a, b, c, t)
	if t < 0.5 then
		t = t * 2
		return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
	end
	t = t * 2 - 1
	return b[1] + (c[1] - b[1]) * t, b[2] + (c[2] - b[2]) * t, b[3] + (c[3] - b[3]) * t
end

local function Tap(va, vr, vg, vb, n, r, g, b, w)
	if n and n > 0 then
		local a, x = va[n], vr[n]
		if a and a > 0 and x then return r + 2 * x, g + 2 * vg[n], b + 2 * vb[n], w + 2 end
	end
	return r, g, b, w
end

-- The film's own colour at cell c (0..255, before light), as its texel there is made of it and the
-- four round it (cl_filmdraw.lua, Look and PaintMap). A film that has not been painted yet: the
-- liquid's colour for the depth that stands there.
local function CellColour(s, c)
	local lk = s.look
	local vr, va = lk and lk.vr, lk and lk.va
	if not vr or not va or not vr[c] then
		local dw = (s.h[c] or 0) + (s.k[c] or 0)
		local t = dw / (K.deepLiquid or 0.045)
		return Mix3(P.wetThin, P.wetBody, P.wetDeep, t > 1 and 1 or (t < 0 and 0 or t))
	end
	local vg, vb = lk.vg, lk.vb
	local r, g, b, w = vr[c] * 4, vg[c] * 4, vb[c] * 4, 4
	r, g, b, w = Tap(va, vr, vg, vb, s.nb1[c], r, g, b, w)
	r, g, b, w = Tap(va, vr, vg, vb, s.nb2[c], r, g, b, w)
	r, g, b, w = Tap(va, vr, vg, vb, s.nb3[c], r, g, b, w)
	r, g, b, w = Tap(va, vr, vg, vb, s.nb4[c], r, g, b, w)
	return r / w, g / w, b / w
end

-- A colour byte as the lit shader is to be given it in $color2 for it to be what the film's texel of
-- that byte is (cl_filmdraw.lua, D.SRGB: the canvas holds the byte by the sRGB curve, the
-- material's colour is taken for a display value of power 2.2), as a share (0..1).
local INV = 1 / 2.2
local function Col2(v)
	local c = v / 255
	if c <= 0 then return 0 elseif c > 1 then c = 1 end
	local lin = c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
	return lin ^ INV
end

-- How much brighter the film's liquid pass draws its colour for the cloth's texture that shows in
-- it (base x (1 - f + 2 f t), f = K.liquidShow, t the texture's mean colour where the map lies:
-- cl_filmdraw.lua, Show and Gain), per channel, as factors for $color2 (light: by the power 1/2.2,
-- as Gain gives the stain its own).
local function Detail(s, c)
	local cvs, mk = s.cv, s.mk
	local k = mk and mk[c]
	local cv = cvs and k and cvs[k]
	local f = K.liquidShow or 0.2
	local mr, mg, mb = 0.5, 0.5, 0.5
	if cv then
		local mm = cv.meanRGB
		local m0 = cv.mean or 0.5
		if istable(mm) then
			mr, mg, mb = mm[1] or mm.r or m0, mm[2] or mm.g or m0, mm[3] or mm.b or m0
		else
			mr, mg, mb = m0, m0, m0
		end
	end
	return (1 - f + 2 * f * mr) ^ INV, (1 - f + 2 * f * mg) ^ INV, (1 - f + 2 * f * mb) ^ INV
end

------------------------------------------------------------------------------------------
-- Its light
------------------------------------------------------------------------------------------
-- The six faces of the light from all round as the lit shader takes them (the ambient cube:
-- +x, -x, +y, -y, +z, -z), and the light the engine says falls on a face turned each of those ways.
local AX = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local BOXI = { BOX_FRONT or 0, BOX_BACK or 1, BOX_RIGHT or 2, BOX_LEFT or 3, BOX_TOP or 4, BOX_BOTTOM or 5 }
local fitAt, fitY = Vector(), {}

local function Display(v)
	if not (v > 0.0006) then v = 0.0006 end
	v = v ^ 0.4545
	return v > 1.25 and 1.25 or v
end

-- The light of the place at (x, y, z), into pd: the six faces in colour (what render.ComputeLighting
-- gives a model's surface turned that way there: the sun and the lamps it sees, and the light from
-- all round), and the one light in them, by the way W.FitLight finds it (cl_woundfx.lua: the six
-- differences of brightness are its direction and strength) and in colour (what of each colour's
-- own differences lies along that way). Also the light a drop that leaves here starts with.
-- Returns false where the engine says nothing of use.
local function Fit(pd, x, y, z)
	if not render.ComputeLighting then return false end
	local Lt = pd.L
	fitAt:SetUnpacked(x, y, z)
	for i = 1, 6 do
		local col = render.ComputeLighting(fitAt, AX[i])
		if not col then return false end
		local r, g, b = col.x, col.y, col.z
		if not (r >= 0 and r < 1e6 and g >= 0 and g < 1e6 and b >= 0 and b < 1e6) then return false end
		local o = i * 3 - 2
		Lt[o], Lt[o + 1], Lt[o + 2] = r, g, b
		fitY[i] = 0.299 * r + 0.587 * g + 0.114 * b
	end
	local dx, dy, dz = fitY[1] - fitY[2], fitY[3] - fitY[4], fitY[5] - fitY[6]
	local I = sqrt(dx * dx + dy * dy + dz * dz)
	local kx, ky, kz, kr, kg, kb = 0, 0, 1, 0, 0, 0
	if I > 1e-4 then
		kx, ky, kz = dx / I, dy / I, dz / I
		kr = max(0, (Lt[1] - Lt[4]) * kx + (Lt[7] - Lt[10]) * ky + (Lt[13] - Lt[16]) * kz)
		kg = max(0, (Lt[2] - Lt[5]) * kx + (Lt[8] - Lt[11]) * ky + (Lt[14] - Lt[17]) * kz)
		kb = max(0, (Lt[3] - Lt[6]) * kx + (Lt[9] - Lt[12]) * ky + (Lt[15] - Lt[18]) * kz)
	end
	pd.kx, pd.ky, pd.kz, pd.kr, pd.kg, pd.kb = kx, ky, kz, kr, kg, kb
	-- (what render.GetLightColor gives, about: the light from all round and the one light at full)
	local sa = abs(kx) + abs(ky) + abs(kz)
	local sr, sg, sb = 0, 0, 0
	for i = 1, 6 do
		local o = i * 3 - 2
		sr, sg, sb = sr + Lt[o], sg + Lt[o + 1], sb + Lt[o + 2]
	end
	pd.dlr = Display(max(0, (sr - kr * sa) / 6) + kr)
	pd.dlg = Display(max(0, (sg - kg * sa) / 6) + kg)
	pd.dlb = Display(max(0, (sb - kb * sa) / 6) + kb)
	return true
end

-- (where the engine says nothing: the light of the place as the drops have it, from all round alike)
local function FitPlain(pd, x, y, z)
	local lr, lg, lb = ABL.Render.Light(x, y, z)
	local Lt = pd.L
	local r, g, b = lr ^ 2.2, lg ^ 2.2, lb ^ 2.2
	for i = 1, 6 do
		local o = i * 3 - 2
		Lt[o], Lt[o + 1], Lt[o + 2] = r, g, b
	end
	pd.kr, pd.kg, pd.kb = 0, 0, 0
	pd.dlr, pd.dlg, pd.dlb = lr, lg, lb
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
local MAXP = 16
local LIT_EVERY = 0.3
local selC, selV = {}, {}
local slotM, slotI, slotR, slotG, slotB = {}, {}, {}, {}, {}
local slotX, slotY, slotZ = {}, {}, {}
for i = 1, MAXP do slotM[i] = Matrix() end
-- (a drop hangs against the body: the light from the ways that go into the body is the body's
-- shadow, not the sky's. Measured in the game, run p19a: a drop under a chin in its own shade was lit
-- by the sky above the head, four times as bright as the film it hung from. Each face of the light
-- from all round counts by how far it faces away from the skin, down to OCC for one that faces into it.)
local OCC = 0.12
local function Occ(dx, dy, dz, nx, ny, nz)
	local w = 0.5 + 0.5 * (dx * nx + dy * ny + dz * nz)
	return w < OCC and OCC or w
end
local colV = Vector()
local keyTab = { { type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(0, 0, 0), dir = Vector(0, 0, -1) } }

-- The pendants of one body (src), just drawn by its model with its film over it (body), in the pose
-- it was drawn in (pose: F.DrawSource has begun it for the drawing). Called only while
-- C.V19On("pendant").
function FP.Draw(src, body, pose)
	local s = src and src.film
	if not s or s.dead or not pose then return end
	local out, outT = s.out, s.outT
	local pd = s.fpend
	if not out or next(out) == nil then
		if pd and next(pd.vd) ~= nil then
			for c in pairs(pd.vd) do Forget(pd, c) end
		end
		return
	end
	local V = C.V19
	local dist = V.pendDist or 120
	if (src.dist or 0) > dist + 48 then return end
	local m = s.m
	if not m or pose.mesh ~= m then return end
	-- (the shapes and materials are made at the next frame's beginning)
	if FP.failed then return end
	if not (FP.ready and FP.readyVer == VER) then FP.want = true return end
	FP.usedT = RealTime()
	local t0 = SysTime()
	if not pd then pd = NewState() s.fpend = pd end
	local now, rt = CurTime(), RealTime()
	-- The volume drawn follows what waits, over pendTau of the game's time; the colour drawn
	-- follows the film's over K.ease (as its texels do).
	local dtc = now - (pd.t or now)
	pd.t = now
	local ke = dtc > 0 and 1 - exp(-dtc / (V.pendTau or 0.06)) or 0
	local drt = rt - (pd.rt or rt)
	pd.rt = rt
	local kc = drt > 0 and 1 - exp(-drt / (K.ease or 0.3)) or 0
	local vd, ot = pd.vd, pd.ot
	-- (a cell that has let go since the last drawing: its pendant is gone at once; its drop is there)
	for c in pairs(vd) do
		if not out[c] then Forget(pd, c) end
	end
	-- the fullest at most pendMax, of the cells whose blood gathers to drop (not those a blow flung
	-- off, which leave at once: cl_film.lua, FM.Shake)
	local nmax = min(V.pendMax or 6, MAXP)
	if nmax < 1 then return end
	local n = 0
	for c, v in pairs(out) do
		local o = outT[c]
		if o and o >= 0 then
			local w = vd[c]
			if w == nil then
				-- (first seen: as much as waits)
				w = v
			elseif ot[c] ~= o then
				-- (it let go and gathers anew)
				w = 0
			else
				w = w + (v - w) * ke
			end
			vd[c], ot[c] = w, o
			if n < nmax or v > selV[n] then
				local i = n < nmax and n + 1 or n
				n = i
				while i > 1 and selV[i - 1] < v do
					selC[i], selV[i] = selC[i - 1], selV[i - 1]
					i = i - 1
				end
				selC[i], selV[i] = c, v
			end
		end
	end
	if n == 0 then return end
	local ex, ey, ez = L.eyeX, L.eyeY, L.eyeZ
	local pxK = L.pxK or 960
	local d2max = dist * dist
	local scale = C.cl.dropScale:GetFloat()
	local cap = K.dropVol * (s.dropK or 1)
	local thr = cap * (s.dropBig or 1)
	local gx, gy, gz, gmag = ABL.Gravity()
	if not (gmag and gmag > 0) then return end
	gx, gy, gz = gx / gmag, gy / gmag, gz / gmag
	local tbone, tt, bu, bv = m.tb, s.tt, s.bu, s.bv
	local tint = K.liquidTint or 1
	local nd = 0
	local fx, fy, fz
	for i = 1, n do
		local c = selC[i]
		local w = vd[c]
		local t = tt[c]
		local b = t and tbone[t]
		-- (not on a bone that is drawn scaled away: the head Z-City hides for the camera in it, whose
		-- points are all at the neck)
		local e = b and b >= 0 and w and w > 0 and pose:Bone(b)
		if e and e[1] * e[1] + e[5] * e[5] + e[9] * e[9] >= 0.25 then
			local px, py, pz, nx, ny, nz = pose:Point(t, bu[c], bv[c])
			local dx, dy, dz = px - ex, py - ey, pz - ez
			local d2 = dx * dx + dy * dy + dz * dz
			local f = w / thr
			if f > 1 then f = 1 end
			local r = Radius(w < cap and w or cap, scale)
			-- (within pendDist, and a quarter of a pixel or more)
			if d2 < d2max and r * pxK * 4 > sqrt(d2) then
				nd = nd + 1
				if nd == 1 then fx, fy, fz = px + nx, py + ny, pz + nz end
				local ax, ay, az = Axis(nx, ny, nz, gx, gy, gz, f)
				-- (turned about its axis with the bone: the shape's sides stay where they are on the body)
				local ux, uy, uz = e[1], e[5], e[9]
				local k = ux * ax + uy * ay + uz * az
				ux, uy, uz = ux - k * ax, uy - k * ay, uz - k * az
				local ul = sqrt(ux * ux + uy * uy + uz * uz)
				if ul < 1e-4 then
					ux, uy, uz = ABL.Perp(ax, ay, az)
				else
					ux, uy, uz = ux / ul, uy / ul, uz / ul
				end
				local wx, wy, wz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
				-- (it begins a hundredth of a unit inside the skin)
				local ox, oy, oz = px - 0.01 * nx, py - 0.01 * ny, pz - 0.01 * nz
				-- (the shape of the nearest step of the fill)
				local si = floor(f * NFILL + 0.5)
				if si < 1 then si = 1 elseif si > NFILL then si = NFILL end
				slotM[nd]:SetUnpacked(
					ux * r, wx * r, ax * r, ox,
					uy * r, wy * r, ay * r, oy,
					uz * r, wz * r, az * r, oz,
					0, 0, 0, 1)
				slotI[nd] = si
				slotX[nd], slotY[nd], slotZ[nd] = nx, ny, nz
				-- its colour
				local tr, tg, tb = CellColour(s, c)
				local cr = pd.cr[c]
				if cr == nil then
					pd.cr[c], pd.cg[c], pd.cb[c] = tr, tg, tb
				else
					pd.cr[c] = cr + (tr - cr) * kc
					pd.cg[c] = pd.cg[c] + (tg - pd.cg[c]) * kc
					pd.cb[c] = pd.cb[c] + (tb - pd.cb[c]) * kc
				end
				local fr, fg, fb = Detail(s, c)
				slotR[nd] = Col2(pd.cr[c]) * tint * fr
				slotG[nd] = Col2(pd.cg[c]) * tint * fg
				slotB[nd] = Col2(pd.cb[c]) * tint * fb
				-- The velocity of the place it hangs from, in the game's time (as Pose:Bone measures a
				-- bone's): a sample far off the bone's own is a jump of the pose that was drawn (Z-City
				-- sets some bones by hand in some drawings), and the bone's is taken for it.
				local bvx, bvy, bvz = pose:BoneVel(b)
				local lt = pd.pt[c]
				if lt and now >= lt and now - lt <= FRESH then
					local dt = now - lt
					if dt > 0.0005 then
						local svx, svy, svz = (px - pd.px[c]) / dt, (py - pd.py[c]) / dt, (pz - pd.pz[c]) / dt
						local qx, qy, qz = svx - bvx, svy - bvy, svz - bvz
						if svx * svx + svy * svy + svz * svz > 4000 * 4000 or qx * qx + qy * qy + qz * qz > 300 * 300 then
							svx, svy, svz = bvx, bvy, bvz
						end
						local kv = min(1, dt / 0.06)
						pd.vx[c] = pd.vx[c] + (svx - pd.vx[c]) * kv
						pd.vy[c] = pd.vy[c] + (svy - pd.vy[c]) * kv
						pd.vz[c] = pd.vz[c] + (svz - pd.vz[c]) * kv
						pd.px[c], pd.py[c], pd.pz[c], pd.pt[c] = px, py, pz, now
					end
				else
					pd.vx[c], pd.vy[c], pd.vz[c] = bvx, bvy, bvz
					pd.px[c], pd.py[c], pd.pz[c], pd.pt[c] = px, py, pz, now
				end
				-- what FP.SpawnAt needs of it: where its bulb hung, from what, and which way
				local zc = ZC[si] * r
				pd.dt[c] = now
				pd.cx[c], pd.cy[c], pd.cz[c] = ox + ax * zc, oy + ay * zc, oz + az * zc
				pd.qx[c], pd.qy[c], pd.qz[c] = px, py, pz
				pd.mx[c], pd.my[c], pd.mz[c] = nx, ny, nz
				pd.ax[c], pd.ay[c], pd.az[c] = ax, ay, az
			end
		end
	end
	if nd == 0 then return end
	-- The light: found once for the body, at most every 0.3 s, at the fullest pendant's place, and
	-- gone over to from the light drawn with until then over as long (the first at once).
	if rt >= pd.litT then
		pd.litT = rt + LIT_EVERY
		pd.lok = true
		stats.fits = stats.fits + 1
		if not Fit(pd, fx, fy, fz) then FitPlain(pd, fx, fy, fz) end
	end
	local Lt = pd.S
	local kl = (pd.shown and drt > 0) and 1 - exp(-drt / LIT_EVERY) or 1
	pd.shown = true
	local Lf = pd.L
	for i = 1, 18 do Lt[i] = Lt[i] + (Lf[i] - Lt[i]) * kl end
	pd.skr, pd.skg, pd.skb = pd.skr + (pd.kr - pd.skr) * kl, pd.skg + (pd.kg - pd.skg) * kl, pd.skb + (pd.kb - pd.skb) * kl
	do
		local x, y, z = pd.skx + (pd.kx - pd.skx) * kl, pd.sky + (pd.ky - pd.sky) * kl, pd.skz + (pd.kz - pd.skz) * kl
		local l = sqrt(x * x + y * y + z * z)
		if l > 1e-6 then pd.skx, pd.sky, pd.skz = x / l, y / l, z / l else pd.skx, pd.sky, pd.skz = pd.kx, pd.ky, pd.kz end
	end
	-- 1. The colour, lit by the light from all round alone (the one light is in the six faces), each
	-- drop with the faces that go into the body it hangs from shaded by it (Occ).
	render.SuppressEngineLighting(true)
	render.SetLocalModelLights()
	local mc = FP.mCol
	for i = 1, nd do
		local msh = SHAPES[slotI[i]]
		if msh then
			local nx, ny, nz = slotX[i], slotY[i], slotZ[i]
			for j = 1, 6 do
				local o, a = j * 3 - 2, AX[j]
				local w = Occ(a.x, a.y, a.z, nx, ny, nz)
				render.SetModelLighting(BOXI[j], Lt[o] * w, Lt[o + 1] * w, Lt[o + 2] * w)
			end
			colV:SetUnpacked(slotR[i], slotG[i], slotB[i])
			mc:SetVector("$color2", colV)
			render.SetMaterial(mc)
			cam.PushModelMatrix(slotM[i])
			msh:Draw()
			cam.PopModelMatrix()
		end
	end
	-- 2. The highlight of the one light, added: that light alone, at its own strength.
	if pd.skr + pd.skg + pd.skb > 1e-5 then
		for i = 1, 6 do render.SetModelLighting(BOXI[i], 0, 0, 0) end
		local key = keyTab[1]
		-- (dir: the way the light travels)
		key.dir:SetUnpacked(-pd.skx, -pd.sky, -pd.skz)
		local ms = FP.mShine
		local boost = V.pendBoost or 0.8
		if FP.shineBoost ~= boost then
			FP.shineBoost = boost
			ms:SetFloat("$phongboost", boost)
		end
		render.SetMaterial(ms)
		for i = 1, nd do
			local msh = SHAPES[slotI[i]]
			if msh then
				-- (a light that comes from inside the body lights no drop on its far side)
				local w = Occ(pd.skx, pd.sky, pd.skz, slotX[i], slotY[i], slotZ[i])
				key.color:SetUnpacked(pd.skr * w, pd.skg * w, pd.skb * w)
				render.SetLocalModelLights(keyTab)
				cam.PushModelMatrix(slotM[i])
				msh:Draw()
				cam.PopModelMatrix()
			end
		end
	end
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
	stats.bodies = stats.bodies + 1
	stats.drawn = stats.drawn + nd
	ABL.Prof.Add("sub.body.pendant", SysTime() - t0)
end

------------------------------------------------------------------------------------------
-- Where a drop starts (cl_film.lua, Leave)
------------------------------------------------------------------------------------------
-- A drop of vol ml leaves cell c of film s, whose point is (px, py, pz) with the surface facing
-- (nx, ny, nz) in the simulation's pose, on a bone moving at (bvx, bvy, bvz). Where it starts and
-- how fast: where its pendant's bulb hung and with that place's velocity, plus pendKick along the
-- way it hung.
--   * Drawn in the last 0.2 s: the bulb's centre as it was drawn, moved on with its place's
--     velocity for the time since (Leave runs on the pose that was drawn last: the body has moved
--     on since by about a frame).
--   * Else: the bulb's centre at fill 1 for vol, from the point given, moved on by a frame's time
--     as Leave moves its drops on.
-- Either way at least the drop's radius and 0.02 units off the surface along its normal. nil when
-- C.V19.pendSpawn is off or nothing can be said: Leave keeps its own way.
function FP.SpawnAt(s, c, vol, px, py, pz, nx, ny, nz, bvx, bvy, bvz)
	local on = C.V19On
	if not (on and on("pendSpawn")) then return nil end
	if not (s and c and vol and vol > 0) then return nil end
	if not (ABL.Finite3(px, py, pz) and ABL.Finite3(nx, ny, nz)) then return nil end
	bvx, bvy, bvz = bvx or 0, bvy or 0, bvz or 0
	if not ABL.Finite3(bvx, bvy, bvz) then bvx, bvy, bvz = 0, 0, 0 end
	local gx, gy, gz, gmag = ABL.Gravity()
	if not (gmag and gmag > 0) then return nil end
	gx, gy, gz = gx / gmag, gy / gmag, gz / gmag
	local scale = C.cl.dropScale:GetFloat()
	local cap = K.dropVol * (s.dropK or 1)
	local now = CurTime()
	local pd = s.fpend
	local tD = pd and pd.dt[c]
	local x, y, z, vx, vy, vz, ax, ay, az, sx, sy, sz, mx, my, mz
	if tD and now >= tD and now - tD < FRESH and pd.cx[c] then
		local age = now - tD
		vx, vy, vz = pd.vx[c] or bvx, pd.vy[c] or bvy, pd.vz[c] or bvz
		ax, ay, az = pd.ax[c], pd.ay[c], pd.az[c]
		x, y, z = pd.cx[c] + vx * age, pd.cy[c] + vy * age, pd.cz[c] + vz * age
		sx, sy, sz = pd.qx[c] + vx * age, pd.qy[c] + vy * age, pd.qz[c] + vz * age
		mx, my, mz = pd.mx[c], pd.my[c], pd.mz[c]
		stats.fresh = stats.fresh + 1
	else
		vx, vy, vz = bvx, bvy, bvz
		ax, ay, az = Axis(nx, ny, nz, gx, gy, gz, 1)
		local k = 1.4 * Radius(vol < cap and vol or cap, scale)
		local lag = min(FrameTime(), 0.05)
		x, y, z = px - 0.01 * nx + ax * k + vx * lag, py - 0.01 * ny + ay * k + vy * lag, pz - 0.01 * nz + az * k + vz * lag
		sx, sy, sz = px + vx * lag, py + vy * lag, pz + vz * lag
		mx, my, mz = nx, ny, nz
	end
	-- (clear of the skin by the drop's own size: one larger than its pendant was drawn starts a
	-- little further out)
	local need = Radius(vol, scale) + 0.02
	local e = (x - sx) * mx + (y - sy) * my + (z - sz) * mz
	if e < need then
		local d = need - e
		x, y, z = x + mx * d, y + my * d, z + mz * d
	end
	local kick = C.V19.pendKick or 0.5
	vx, vy, vz = vx + ax * kick, vy + ay * kick, vz + az * kick
	if not (ABL.Finite3(x, y, z) and ABL.Finite3(vx, vy, vz)) then return nil end
	stats.spawns = stats.spawns + 1
	return x, y, z, vx, vy, vz
end
