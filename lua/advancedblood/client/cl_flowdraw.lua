-- Flow drawing: the channels of the flow core (cl_flowcore.lua) as liquid on the body.
-- Nothing here decides where blood is or how much: every width, depth, highlight and colour is
-- read from the simulated state of the nodes, between the last two steps. There is no picture of a
-- stream: the textures are lookups (tools/texgen, "flow core") with u across the stream and v a
-- state, so what changes along a stream on screen is what changes in the liquid.
--   stain  what the stream has left on the surface: film, dried blood, blood in the cloth, clots.
--          As wide as the stream has ever been there; its density from how much lies there, its
--          colour from how long ago blood last ran there.
--   wet    the liquid itself: as wide as the rivulet is now, a rounded cross-section whose colour
--          comes from its depth by absorption (thin: a light translucent red, deep: dark crimson),
--          ending in the head, a bead a little wider than the stream.
--   body   the liquid's own colour over that: blood scatters light back, so where it stands deep
--          enough it is red on any cloth (as a filter alone it would be black on dark or green).
--   sheen  the surroundings mirrored in the wet surface (Fresnel of the view angle).
--   spec   the key light's highlight: a line along the stream, lying where the rounded surface
--          mirrors the light toward the eye, so it slides across the stream as the view changes; on
--          the head, a glint.
-- All are filter / additive passes over the lit body (cl_render.lua), built as triangle strips
-- through cross-sections at the nodes: a centre on the skin and a side vector across the stream.
-- Developer views (abl_flow_view) replace the layers by one false-colour ribbon of a state.

ABL.NoJIT()
ABL.FlowDraw = ABL.FlowDraw or {}
local FD = ABL.FlowDraw
local FC, F = ABL.FlowCore, ABL.Flow
local C, L, R = ABL.Config, ABL.LOD, ABL.Render
local K = C.Flow
local ML = C.ML_PER_CU
local sqrt, min, max, abs, exp = math.sqrt, math.min, math.max, math.abs, math.exp

FD.cvView = CreateClientConVar("abl_flow_view", "0", false, false,
	"Developer view of the blood flow: 0 off, 1 thickness, 2 velocity, 3 wetness, 4 age (clotting), 5 driving pressure, 6 mass, 7 surface normal, 8 flow path, 9 source.", 0, 9)
FD.VIEWS = { "thickness", "velocity", "wetness", "age / clotting", "driving pressure", "mass", "surface normal", "flow path", "source" }
FD.cvDebug = CreateClientConVar("abl_flow_debug", "0", false, false,
	"Developer switches of the stream drawing, added up: 1 no static strips (every channel from its nodes at every frame), 2 vertex positions through a Vector, 4 the soft pieces of still channels from their nodes. For comparing pictures: none is to change one.", 0, 7)

local mats
local function Mats()
	if mats then return mats end
	local function Unlit(name, tex, additive)
		local kv = { ["$basetexture"] = "advancedblood/sprites/" .. tex, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1 }
		if additive then kv["$additive"] = 1 else kv["$translucent"] = 1 end
		return CreateMaterial(name, "UnlitGeneric", kv)
	end
	mats = {
		lut = Unlit("abl_flowlut", "flowlut"), stain = Unlit("abl_flowstain", "flowstain"), body = Unlit("abl_flowbody", "flowbody"),
		sheen = Unlit("abl_flowsheen", "flowsheen", true), spec = Unlit("abl_flowspec", "flowspec", true),
		-- developer views: plain vertex colours, both faces
		plain = CreateMaterial("abl_flowplain", "UnlitGeneric", { ["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1 }),
	}
	return mats
end

local vec = Vector()
-- (a vertex of a strip is written out where it is made: the calls into the engine by their own
-- names, not looked up in `mesh` and in the vector at every vertex)
local mPos, mTex, mCol, mAdv = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex
local vSet = FindMetaTable("Vector").SetUnpacked
local matSet = FindMetaTable("VMatrix").SetUnpacked      -- (nil on a build that has none)
local POS3      -- whether this build takes a position as three numbers (asked at the first strip)
local VEC_POS = false   -- abl_flow_debug 2: positions through a Vector all the same
local function V(x, y, z, u, v, r, g, b, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

-- Cross-sections of everything drawn for one character this frame (flat scratch arrays, reused).
-- (LuaJIT allows a function 60 upvalues: the arrays live in one table, FD.Source takes them as locals)
local N = 0
local A = {}
for _, k in ipairs({ "PX", "PY", "PZ", "SX", "SY", "SZ", "BRK",
	"SON", "SH", "SV", "SR", "SG", "SB", "SA",      -- stain: on, half-width, depth row, filter colour
	"HON", "HH", "HV",                              -- the band of cloth soaked around it: on, half-width, depth row
	"WON", "WH", "WV", "WR", "WG", "WB", "WA",      -- wet
	"WD", "BR", "BG", "BB",                         -- its depth (units), and its own colour on the world (C.P21.streamLiquid)
	"GON", "GH", "GV", "GL",                        -- sheen: on, half-width, wetness row, strength 0..255
	"PON", "PU", "PL",                              -- highlight line: on, where across, strength 0..255
	"QON", "QU", "QL",                              -- the same for the sky straight above
	"DR", "DG", "DB",                               -- developer view colour
	"WX", "WY", "WZ", "WNX", "WNY", "WNZ", "VIS",   -- the nodes of the channel being drawn, in this pose
	"PH", "PHX", "PHY", "PHZ", "GLT" }) do A[k] = {} end
local SAFE = {}     -- Bake: the bone a section lies rigidly on, or false
local PX, PY, PZ, SX, SY, SZ, BRK = A.PX, A.PY, A.PZ, A.SX, A.SY, A.SZ, A.BRK
local SON, WON, GON, PON, QON, DR, DG, DB = A.SON, A.WON, A.GON, A.PON, A.QON, A.DR, A.DG, A.DB
local HON = A.HON
local RS, RE = {}, {}
-- the texture's stream is narrower than the texture (a margin for its soft edge)
local MARGIN = 1 / 0.84

-- Triangle strip through the sections that are `on`, in runs that end at breaks.
--   mode 1 filter (colours c1..c4, row vv)   2 sheen (strength c4 times the light, row vv)
--   mode 3 plain colour (developer views)     4 highlight line (strength c4, slid across by uc)
--   mode 5 one colour lr, lg, lb (0..255) for all, row vv times uc (a number, 1 when not given)
--   im: into this static mesh; lo, hi: of sections lo..hi only (all of them when not given)
local function Strip(on, hw, vv, mode, c1, c2, c3, c4, lr, lg, lb, uc, im, lo, hi)
	local runs, verts, start = 0, 0, 0
	lo, hi = lo or 1, hi or N
	for i = lo, hi + 1 do
		local o = i <= hi and on[i]
		if not (o and start > 0 and not BRK[i]) then
			if start > 0 and i - start >= 2 then
				runs = runs + 1
				RS[runs], RE[runs] = start, i - 1
				verts = verts + 2 * (i - start) + (runs > 1 and 2 or 0)
			end
			start = o and i or 0
		end
	end
	if runs == 0 then return 0 end
	local wide = mode == 4 and 1 or MARGIN
	if im then mesh.Begin(im, MATERIAL_TRIANGLE_STRIP, verts - 2) else mesh.Begin(MATERIAL_TRIANGLE_STRIP, verts - 2) end
	-- (an older build wants a Vector and says so; the position set here is written over by the
	-- first vertex)
	if POS3 == nil then POS3 = pcall(mPos, 0, 0, 0) and true or false end
	local pos3 = POS3 and not VEC_POS
	for k = 1, runs do
		local a, b = RS[k], RE[k]
		for i = a, b do
			local h = hw[i] * wide
			local x, y, z = PX[i], PY[i], PZ[i]
			local sx, sy, sz = SX[i] * h, SY[i] * h, SZ[i] * h
			local r, g, bl, al, u0, u1, tv
			if mode == 1 then
				r, g, bl, al, u0, u1, tv = c1[i], c2[i], c3[i], c4[i], 0, 1, vv[i]
			elseif mode == 2 then
				local e = c4[i]
				r, g, bl, al, u0, u1, tv = min(255, e * lr), min(255, e * lg), min(255, e * lb), 255, 0, 1, vv[i]
			elseif mode == 4 then
				local e = c4[i]
				r, g, bl, al, tv = min(255, e * lr), min(255, e * lg), min(255, e * lb), 255, vv[i]
				u0, u1 = uc[i] - 0.25, uc[i] + 0.25
			elseif mode == 5 then
				r, g, bl, al, u0, u1, tv = lr, lg, lb, 255, 0, 1, vv[i] * (uc or 1)
			else
				r, g, bl, al, u0, u1, tv = c1[i], c2[i], c3[i], 255, 0, 1, 0.5
			end
			-- (joining two runs: the last vertex of the one and the first of the other, twice)
			if pos3 then
				if i == a and k > 1 then
					local p = RE[k - 1]
					local ph = hw[p] * wide
					mPos(PX[p] + SX[p] * ph, PY[p] + SY[p] * ph, PZ[p] + SZ[p] * ph) mTex(0, u1, tv) mCol(0, 0, 0, 0) mAdv()
					mPos(x - sx, y - sy, z - sz) mTex(0, u0, tv) mCol(0, 0, 0, 0) mAdv()
				end
				mPos(x - sx, y - sy, z - sz) mTex(0, u0, tv) mCol(r, g, bl, al) mAdv()
				mPos(x + sx, y + sy, z + sz) mTex(0, u1, tv) mCol(r, g, bl, al) mAdv()
			else
				if i == a and k > 1 then
					local p = RE[k - 1]
					local ph = hw[p] * wide
					vSet(vec, PX[p] + SX[p] * ph, PY[p] + SY[p] * ph, PZ[p] + SZ[p] * ph) mPos(vec) mTex(0, u1, tv) mCol(0, 0, 0, 0) mAdv()
					vSet(vec, x - sx, y - sy, z - sz) mPos(vec) mTex(0, u0, tv) mCol(0, 0, 0, 0) mAdv()
				end
				vSet(vec, x - sx, y - sy, z - sz) mPos(vec) mTex(0, u0, tv) mCol(r, g, bl, al) mAdv()
				vSet(vec, x + sx, y + sy, z + sz) mPos(vec) mTex(0, u1, tv) mCol(r, g, bl, al) mAdv()
			end
		end
	end
	mesh.End()
	return verts
end

-- blue -> cyan -> green -> yellow -> red
local function Ramp(t)
	if t <= 0 then return 40, 70, 255 end
	if t >= 1 then return 255, 30, 20 end
	if t < 0.25 then local k = t * 4 return 40 - 20 * k, 70 + 180 * k, 255 end
	if t < 0.5 then local k = (t - 0.25) * 4 return 20, 250, 255 - 235 * k end
	if t < 0.75 then local k = (t - 0.5) * 4 return 20 + 235 * k, 250 - 20 * k, 20 end
	local k = (t - 0.75) * 4
	return 255, 230 - 200 * k, 20
end

local function HueOf(id)
	local h = (id * 0.61803398875) % 1
	local r, g, b = abs(h * 6 - 3) - 1, 2 - abs(h * 6 - 2), 2 - abs(h * 6 - 4)
	return 255 * math.Clamp(r, 0.15, 1), 255 * math.Clamp(g, 0.15, 1), 255 * math.Clamp(b, 0.15, 1)
end

-- Row of the depth lookups for a layer `h` units deep (tools/texgen Gen.FlowDepth, inverted).
local LUT_REF = K.lutRef
local function Row(h)
	local d = h / LUT_REF - 0.015
	if d <= 0 then return 0.02 end
	local v = sqrt(d / 1.2)
	return v > 0.98 and 0.98 or (v < 0.02 and 0.02 or v)
end

-- Drawn width of a rivulet of simulated width w.
local Wide = FC.Wide

-- (phase 21, C.P21.streamLiquid) The liquid of a stream on the world in the pools' colours: by its
-- depth (units), from the colour of a thin film over the body's to the deep's, by the pools' own rule
-- (cl_poolcanvas.lua, Cell: d = 1 - exp(-depth / C.V19.poolDeepScale), the body's colour at a half),
-- on the palette the pools take for that floor (a smooth floor's thin film, as cl_pools.lua takes it),
-- in the light a pool there is lit with (cl_flowworld.lua, FW.Draw). It is the vertex colour of the
-- body lookup, whose every texel is LIQ_T1..3: the colour over that.
-- (In FD, not locals of this file: FD.Source would take them as upvalues, of which LuaJIT allows a
-- function 60, as A above.)
local LIQ_T1, LIQ_T2, LIQ_T3 = 124, 18, 24     -- (materials/advancedblood/sprites/flowbody.vtf, every texel)
local SMOOTH = { tile = true, metal = true, glass = true, plastic = true }     -- (cl_pools.lua's)
local LQ = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }      -- thin, body, deep as vertex colours in this light
local lqR, lqG, lqB, lqInv, lqSmooth = 1, 1, 1, 12.5, nil
-- The light of the source being drawn (display values).
function FD.LiquidLight(r, g, b)
	lqR, lqG, lqB, lqSmooth = r, g, b, nil
	local ds = C.V19 and C.V19.poolDeepScale or 0.08
	lqInv = 1 / (ds > 1e-3 and ds or 0.08)
end
-- The palette for a channel on surface surf (made again when the kind of floor differs from the last).
function FD.LiquidFor(surf)
	local smooth = SMOOTH[surf and surf.name or ""] or false
	if smooth == lqSmooth then return end
	lqSmooth = smooth
	local pal = C.Pool.palette
	local w = smooth and pal.thin or pal.wetFresh
	local a, b, c = w.rim, w.body, pal.wetDeep
	LQ[1], LQ[2], LQ[3] = 255 * lqR * a[1] / LIQ_T1, 255 * lqG * a[2] / LIQ_T2, 255 * lqB * a[3] / LIQ_T3
	LQ[4], LQ[5], LQ[6] = 255 * lqR * b[1] / LIQ_T1, 255 * lqG * b[2] / LIQ_T2, 255 * lqB * b[3] / LIQ_T3
	LQ[7], LQ[8], LQ[9] = 255 * lqR * c[1] / LIQ_T1, 255 * lqG * c[2] / LIQ_T2, 255 * lqB * c[3] / LIQ_T3
end
-- The colours of sections a..b that hold liquid, by their depths (WD).
function FD.LiquidFill(a, b)
	local WD, BR, BG, BB = A.WD, A.BR, A.BG, A.BB
	for k = a, b do
		if WON[k] then
			local d = 1 - exp(-WD[k] * lqInv)
			local r, g, bl
			if d < 0.5 then
				local t = d * 2
				r, g, bl = LQ[1] + (LQ[4] - LQ[1]) * t, LQ[2] + (LQ[5] - LQ[2]) * t, LQ[3] + (LQ[6] - LQ[3]) * t
			else
				local t = d * 2 - 1
				r, g, bl = LQ[4] + (LQ[7] - LQ[4]) * t, LQ[5] + (LQ[8] - LQ[5]) * t, LQ[6] + (LQ[9] - LQ[6]) * t
			end
			BR[k], BG[k], BB[k] = r > 255 and 255 or r, g > 255 and 255 or g, bl > 255 and 255 or bl
		end
	end
end

-- Row of the stain lookup: what lies on a surface is thin, but dense in pigment.
local STAIN_REF = K.stainRef
local function RowS(h)
	local d = h / STAIN_REF - 0.015
	if d <= 0 then return 0.02 end
	local v = sqrt(d / 1.2)
	return v > 0.98 and 0.98 or (v < 0.02 and 0.02 or v)
end

-- One more cross-section: centre p on the skin (lifted by off), normal n, side s (unit, across).
local function Section(px, py, pz, nx, ny, nz, sx, sy, sz, off, brk)
	N = N + 1
	local i = N
	PX[i], PY[i], PZ[i] = px + nx * off, py + ny * off, pz + nz * off
	SX[i], SY[i], SZ[i] = sx, sy, sz
	BRK[i] = brk
	SON[i], WON[i], GON[i], PON[i], QON[i], HON[i] = false, false, false, false, false, false
	DR[i], DG[i], DB[i] = 90, 90, 90
	return i
end

-- How uneven a stream's margin is at node i of channel ch (a factor on its width): skin is not
-- flat and cloth wicks along its weave, so what a stream leaves has no ruled edges. Fixed to the
-- place (it does not run along the stream) and slow enough to survive Even.
local RAG_SKIN, RAG_CLOTH, DULL = K.ragSkin, K.ragCloth, K.clothDull
local sin = math.sin
local function Rag(ch, i)
	local ab = ch.ab[i] or 0
	local k = ab >= DULL and 1 or ab / DULL
	local id = ch.id
	return 1 + (RAG_SKIN + (RAG_CLOTH - RAG_SKIN) * k) * (sin(i * 0.83 + id * 2.7) * 0.6 + sin(i * 0.31 + id * 1.3) * 0.4)
end

-- What lies at node i of channel ch, as the stain of section k: the track the blood ran in, and in
-- cloth the band it has soaked around it (wider, lighter, soft at its margin). left: only what the
-- stream has left there (its liquid is drawn as liquid over it: C.P21.streamLiquid).
local STAIN_MAX, SOAK_DEPTH = K.stainMax, K.soakDepth
local mDk, mTone, mR, mG, mB, mA = -1, -1, 0, 0, 0, 0     -- the stain colour last worked out (StainAt)
local GAMMA = 1 / 2.2                                     -- as in ABL.Render.FilterColor
local SH, SV, SR, SG, SB, SA, HH, HV = A.SH, A.SV, A.SR, A.SG, A.SB, A.SA, A.HH, A.HV
local function StainAt(ch, i, k, now, dryT, tone, minW, haloRow, left)
	local lc = ch.Lc[i]
	local content = (ch.D[i] + ch.F[i] + ch.Cv[i] + (left and 0 or ch.V[i])) / (lc * ML)
	local ws = ch.S[i] / (SOAK_DEPTH * lc * ML)
	if content > 1e-7 or ws > 1e-4 then
		-- (in cloth the weave under the track is full of blood)
		local wT = Wide(ch.wmax[i]) + minW
		if wT < 1e-3 then wT = 1e-3 end
		local depth = content / wT + (ws > 1e-4 and STAIN_MAX * 0.55 or 0)
		if depth > STAIN_MAX then depth = STAIN_MAX end
		local dk = (now - ch.fed[i]) / dryT
		if not (dk > 0) then dk = 0 elseif dk > 1 then dk = 1 end
		-- (the colour of a stain of that age: most nodes of a stream are of one age, running or
		-- long dry, and the colour is worked out when the age is another, not at every node)
		if dk ~= mDk or tone ~= mTone then
			local mr, mg, mb = R.FilterAge(dk, 0.5)
			mR, mG, mB, mA = R.FilterColor(mr * tone, mg, mb, 1 - 0.2 * dk)
			mDk, mTone = dk, tone
		end
		SR[k], SG[k], SB[k], SA[k] = mR, mG, mB, mA
		-- (fixed to the node: worked out once, not at every frame)
		local rg = ch.rg
		if not rg then rg = {} ch.rg = rg end
		local rag = rg[i]
		if not rag then rag = Rag(ch, i) rg[i] = rag end
		SH[k], SV[k], SON[k] = wT * 0.5 * rag, RowS(depth), true
		if ws > wT * 1.05 then HH[k], HV[k], HON[k] = ws * 0.5 * (2 * rag - 1), haloRow, true end
	end
end

-- The path through sections a..b is rounded off: a node is where the mesh put it, and a stream
-- drawn from node to node in straight pieces has corners no liquid has. Not across a break.
function FD.Round(a, b)
	if b - a < 2 then return end
	local px, py, pz = PX[a], PY[a], PZ[a]
	for k = a + 1, b - 1 do
		local cx, cy, cz = PX[k], PY[k], PZ[k]
		if not BRK[k] and not BRK[k + 1] then
			PX[k], PY[k], PZ[k] = 0.25 * px + 0.5 * cx + 0.25 * PX[k + 1], 0.25 * py + 0.5 * cy + 0.25 * PY[k + 1], 0.25 * pz + 0.5 * cz + 0.25 * PZ[k + 1]
		end
		px, py, pz = cx, cy, cz
	end
end

-- Drawn widths are evened out along a stream (sections a..b): no node stands out from its neighbours.
local function Even(a, b, hw, on)
	if b - a < 2 then return end
	local p = hw[a]
	for k = a + 1, b - 1 do
		local c = hw[k]
		if on[k - 1] and on[k] and on[k + 1] then hw[k] = 0.25 * p + 0.5 * c + 0.25 * hw[k + 1] end
		p = c
	end
end

------------------------------------------------------------------------------------------
-- Static meshes. Per stretch of a channel that hangs on one bone: strips in that bone's space,
-- built from the pose the body has at that moment and drawn with the bone's matrix, so they cost a
-- draw call per frame and no work per node. Skin that bends between bones moves under such a
-- strip: one of its points is watched, and the strip is built again when it has moved.
--   A channel in which nothing moves any more is drawn that way as a whole.
--   A channel that still runs is drawn that way up to the node it had when the strips were built
--   (they are built again once or twice a second), and live from there on: the newest stretch and
--   the head. Only where no reflection has to follow the view: near the camera a running stream
--   is drawn live from end to end.
------------------------------------------------------------------------------------------
local BX, BY, BZ, BNX, BNY, BNZ = {}, {}, {}, {}, {}, {}
local boneMat = Matrix()
local OFF_BAKED = 0.06
local bakeFrame, bakesLeft = -1, 0
local waitBar, waitMax = 0, 0     -- the longest a channel waited for new strips last frame, and this one
local SHEEN_OFF = 0.02 / 0.6      -- wetness below which a stretch without liquid shows no reflection (FD.Source)
-- (why a channel's strips are built, and why they would have been had the frame had a bake left)
local WHY, WHY_NOT = {}, {}
for i, name in ipairs({ "first", "mesh", "skin moved", "time", "open", "halo", "wet", "grown", "distance" }) do
	WHY[i], WHY_NOT[i] = "bake: " .. name, "no bake: " .. name
end
FD.bakes = FD.bakes or 0     -- channels that hold strips (the memory test reads it)
FD.wQuick, FD.wFull, FD.tWatch = 0, 0, 0

local function FreeBake(ch)
	local b = ch.bake
	if not b then return end
	for i = 1, #b.runs do
		local r = b.runs[i]
		if r.mesh then r.mesh:Destroy() end
		if r.halo then r.halo:Destroy() end
		if r.wet then r.wet:Destroy() end
		if r.body then r.body:Destroy() end
		if r.sbody then r.sbody:Destroy() end
	end
	ch.bake = nil
	FD.bakes = FD.bakes - 1
end
FD.FreeBake = FreeBake

-- What the strips of a channel are built with this frame (set by FD.Source for the character drawn).
--   off: offset from the skin of a running channel's strips (the same as its live stretch)
--   part: running channels may be baked too; wet: with the liquid as it is now; halo: with the soaked band
--   br, bg, bb: the liquid's own colour under the light there (0..255); sr, sg, sb: the stain's
local Q = { off = 0.06, part = false, wet = false, halo = true, tClot = 60, br = 200, bg = 200, bb = 200, sr = 100, sg = 100, sb = 100 }

-- The sections of nodes ca..cb of channel ch, added to the scratch arrays as the live pass makes
-- them (FD.Source: the same directions from node to node, the same rule at a fold), every node
-- counted as seen: what lies there as a stain and, withWet, the liquid. jx, jy, jz: where the
-- channel's last node runs on to (the stream it joined), or nil. Returns the first and the last
-- section.
local function Sections(ch, pose, ca, cb, jx, jy, jz, off, now, dryT, tone, minW, haloRow, withWet)
	local n, an, gap = ch.n, ch.an, ch.gap
	local WX, WY, WZ, WNX, WNY, WNZ = A.WX, A.WY, A.WZ, A.WNX, A.WNY, A.WNZ
	local WH, WV, WR, WG, WB, WA, WD = A.WH, A.WV, A.WR, A.WG, A.WB, A.WA, A.WD
	local tClot, Ff = Q.tClot, C.Filter.fresh
	local Vv, hh, ww, age = ch.V, ch.h, ch.w, ch.age
	local left = withWet and Q.liquid
	for i = (ca > 1 and ca - 1 or 1), (cb < n and cb + 1 or cb) do WX[i], WY[i], WZ[i], WNX[i], WNY[i], WNZ[i] = pose:SkinPoint(an[i]) end
	local first = N + 1
	local ltx, lty, ltz = 0, 0, 0
	local lsx, lsy, lsz, lnx, lny, lnz
	for i = ca, cb do
		local x, y, z, nx, ny, nz = WX[i], WY[i], WZ[i], WNX[i], WNY[i], WNZ[i]
		local x1, y1, z1, x2, y2, z2 = x, y, z, x, y, z
		if i > 1 and not gap[i - 1] then x1, y1, z1 = WX[i - 1], WY[i - 1], WZ[i - 1] end
		if i < n and not gap[i] then
			x2, y2, z2 = WX[i + 1], WY[i + 1], WZ[i + 1]
		elseif i == n and jx then
			x2, y2, z2 = jx, jy, jz
		end
		local tx, ty, tz = x2 - x1, y2 - y1, z2 - z1
		local tl = sqrt(tx * tx + ty * ty + tz * tz)
		if tl > 1e-5 then tx, ty, tz = tx / tl, ty / tl, tz / tl else tx, ty, tz = ltx, lty, ltz end
		ltx, lty, ltz = tx, ty, tz
		local sx, sy, sz = ty * nz - tz * ny, tz * nx - tx * nz, tx * ny - ty * nx
		local sl = sqrt(sx * sx + sy * sy + sz * sz)
		if sl < 1e-6 then
			sx, sy, sz = ABL.Perp(nx, ny, nz)
		else
			sx, sy, sz = sx / sl, sy / sl, sz / sl
		end
		-- (no twist and no strip across a fold: as in the live stretch)
		local fold = false
		if lsx and i > ca and not gap[i - 1] then
			if sx * lsx + sy * lsy + sz * lsz < 0 then sx, sy, sz = -sx, -sy, -sz end
			fold = nx * lnx + ny * lny + nz * lnz < 0.15
		end
		lsx, lsy, lsz, lnx, lny, lnz = sx, sy, sz, nx, ny, nz
		local k = Section(x, y, z, nx, ny, nz, sx, sy, sz, off, i == ca or gap[i - 1] or fold)
		StainAt(ch, i, k, now, dryT, tone, minW, haloRow, left)
		if withWet and Vv[i] > 1e-6 and hh[i] > 1e-5 then
			local cl = min(age[i] / tClot, 1)
			WR[k], WG[k], WB[k], WA[k] = R.FilterColor(Ff[1] * tone * (1 - 0.3 * cl), Ff[2], Ff[3], 1)
			WH[k], WV[k], WON[k], WD[k] = (Wide(ww[i]) + minW) * 0.5, Row(hh[i]), true, hh[i]
		end
	end
	return first, N
end

-- Whether node a hangs on bone alone.
local function RigidOn(a, bone)
	return a.b1 == bone and a.rigid == bone and (a.w1 or 1) >= 0.999
end

-- The static strips of a channel. open: the channel still runs; its last node is no end (it goes
-- on live from there).
-- The sections of the whole channel are made as the live pass makes them (Sections; then the same
-- rounding and evening along the whole channel and the same points at its ends). What the strips
-- show is what the live pass shows at that moment, so a channel can go from the one to the other
-- at any frame and nothing is seen of it. (Until phase 35 each stretch on a bone was rounded,
-- evened and given its directions by itself: at every joint two stretches met at an angle, and a
-- channel that went over to strips changed its outline there.)
-- The sections are then sorted into two kinds.
--   Rigid: the section's node and the nodes before and after it hang on one bone alone. Where
--     such a section is, and which way it lies, cannot change in that bone's space, whatever
--     the body does. Runs of them are strips in the bone's space that need no watching.
--   Soft: all others (skin shared between bones, the stretch across a joint, the end in another
--     stream), in pieces that reach to the rigid section on either side. They are strips too,
--     in the space of one of their bones, and they are watched (Watch): when the skin has moved
--     under them they are drawn from their nodes (LiveSoft) and the rigid strips stay.
-- (Until phase 35 a strip took in every node of a bone and the first node of the next bone, and
-- one of its nodes was watched: a strip across a bending knee stood off the leg until it was
-- its channel's turn to be built again, two channels a frame.)
local function Bake(ch, src, pose, m, now, dryT, tone, minW, haloRow, open)
	FreeBake(ch)
	local n, an, gap = ch.n, ch.an, ch.gap
	local WX, WY, WZ = A.WX, A.WY, A.WZ
	local WH, WV, WR, WG, WB, WA = A.WH, A.WV, A.WR, A.WG, A.WB, A.WA
	local withWet, withHalo = open and Q.wet, Q.halo
	-- (near the camera at the height the live strips have: nothing shifts when a channel goes over)
	local offB = (open or not Q.part) and Q.off or OFF_BAKED
	local jx, jy, jz
	local och = ch.joinCh
	if not open and och and not och.dead and och.an[ch.joinIdx][4] == m then jx, jy, jz = pose:SkinPoint(och.an[ch.joinIdx]) end
	N = 0
	Sections(ch, pose, 1, n, jx, jy, jz, offB, now, dryT, tone, minW, haloRow, withWet)
	FD.Round(1, n)
	Even(1, n, SH, SON)
	Even(1, n, WH, WON)
	Even(1, n, HH, HON)
	-- into the stream it joined: narrowing, it disappears into the bigger one
	local joinSec = false
	if jx then
		local k = Section(jx, jy, jz, A.WNX[n], A.WNY[n], A.WNZ[n], SX[n], SY[n], SZ[n], offB, false)
		if SON[n] then
			SH[k], SV[k], SON[k] = SH[n] * 0.6, SV[n], true
			SR[k], SG[k], SB[k], SA[k] = SR[n], SG[n], SB[n], SA[n]
		end
		joinSec = true
	end
	-- (a stream starts and ends in a point, not in a cut; where it still runs its last node is no end)
	if SON[1] then SH[1] = SH[1] * 0.5 end
	if WON[1] then WH[1] = WH[1] * 0.6 end
	if not open and not jx and SON[n] then SH[n] = SH[n] * 0.35 end
	-- (C.P21.streamLiquid: the liquid's own colour by its depth, FD.LiquidFor)
	local liquid = withWet and Q.liquid
	if liquid then
		FD.LiquidFor(ch.surf)
		FD.LiquidFill(1, N)
	end
	-- Where the sections are in the world is kept; each strip is written back in its bone's space.
	local NS = N
	for k = 1, NS do BX[k], BY[k], BZ[k], BNX[k], BNY[k], BNZ[k] = PX[k], PY[k], PZ[k], SX[k], SY[k], SZ[k] end
	-- rigid sections (SAFE[k]: the bone, or false)
	for k = 1, n do
		local bone = an[k].b1
		local ok = RigidOn(an[k], bone)
		if ok and k > 1 and not gap[k - 1] then ok = RigidOn(an[k - 1], bone) end
		if ok and k < n and not gap[k] then ok = RigidOn(an[k + 1], bone) end
		if ok and k == n and jx then ok = false end
		SAFE[k] = ok and bone or false
	end
	-- (one alone is no strip)
	for k = 1, n do
		local s = SAFE[k]
		if s and not (k > 1 and not gap[k - 1] and SAFE[k - 1] == s) and not (k < n and not gap[k] and SAFE[k + 1] == s) then SAFE[k] = false end
	end
	local runs, soft = {}, nil
	local softCost = 0
	-- (the bones the watched nodes hang on, each once)
	local wb, wbIn
	local k = 1
	while k <= n do
		local s = SAFE[k]
		local j = k
		local bone, sa, sb, watch
		if s then
			while j < n and not gap[j] and SAFE[j + 1] == s do j = j + 1 end
			bone, sa, sb = s, k, j
		else
			while j < n and not SAFE[j + 1] do j = j + 1 end
			-- (with the rigid section on either side: there it meets the rigid strips)
			sa = k > 1 and k - 1 or k
			local eb = j < n and j + 1 or j
			sb = (eb == n and joinSec) and n + 1 or eb
			bone = an[k].b1
			soft = soft or {}
			soft[#soft + 1], soft[#soft + 2] = sa, eb
			-- (what the piece costs from its nodes: its sections and one more on either side)
			softCost = softCost + eb - sa + 3
			watch = { sa, 0, 0, 0, math.floor((sa + eb) / 2), 0, 0, 0, eb, 0, 0, 0 }
		end
		local inv = pose:BoneInv(bone)
		if inv and sb > sa then
			for q = sa, sb do
				local x, y, z, sx, sy, sz = BX[q], BY[q], BZ[q], BNX[q], BNY[q], BNZ[q]
				PX[q] = inv[1] * x + inv[2] * y + inv[3] * z + inv[4]
				PY[q] = inv[5] * x + inv[6] * y + inv[7] * z + inv[8]
				PZ[q] = inv[9] * x + inv[10] * y + inv[11] * z + inv[12]
				SX[q] = inv[1] * sx + inv[2] * sy + inv[3] * sz
				SY[q] = inv[5] * sx + inv[6] * sy + inv[7] * sz
				SZ[q] = inv[9] * sx + inv[10] * sy + inv[11] * sz
			end
			local run = { bone = bone, soft = watch ~= nil }
			if watch then
				-- The places watched for skin that moves under a soft strip: its first, middle and
				-- last node, where they are, not where the rounded path runs. (Until phase 35 the
				-- middle node of a stretch, compared with the rounded path: a stream with a bend
				-- there counted as moved at every frame. Its strips were built anew at every
				-- frame, both bakes of every frame went to two such channels, and the channels
				-- after them never got strips: they were drawn from their nodes for good.)
				wb, wbIn = wb or {}, wbIn or {}
				if not wbIn[bone] then wbIn[bone] = true wb[#wb + 1] = bone end
				for q = 1, 9, 4 do
					local id = watch[q]
					local tri = an[id][1]
					if m.t1 and m.b1 then
						for c = 1, 3 do
							local vid = (c == 1 and m.t1[tri]) or (c == 2 and m.t2[tri]) or m.t3[tri]
							for w = 1, 3 do
								local bb = vid and ((w == 1 and m.b1[vid]) or (w == 2 and m.b2[vid]) or m.b3[vid])
								if bb and bb >= 0 and not wbIn[bb] then wbIn[bb] = true wb[#wb + 1] = bb end
							end
						end
					end
					local x, y, z = WX[id], WY[id], WZ[id]
					watch[q + 1] = inv[1] * x + inv[2] * y + inv[3] * z + inv[4]
					watch[q + 2] = inv[5] * x + inv[6] * y + inv[7] * z + inv[8]
					watch[q + 3] = inv[9] * x + inv[10] * y + inv[11] * z + inv[12]
				end
				run.w = watch
			end
			if withHalo then
				local hm = Mesh()
				if Strip(HON, HH, HV, 1, SR, SG, SB, SA, nil, nil, nil, nil, hm, sa, sb) > 0 then run.halo = hm else hm:Destroy() end
			end
			local sm = Mesh()
			if Strip(SON, SH, SV, 1, SR, SG, SB, SA, nil, nil, nil, nil, sm, sa, sb) > 0 then run.mesh = sm else sm:Destroy() end
			if run.mesh then
				local bm = Mesh()
				Strip(SON, SH, SV, 5, nil, nil, nil, nil, Q.sr, Q.sg, Q.sb, K.stainRow, bm, sa, sb)
				run.sbody = bm
			end
			if withWet then
				local wm = Mesh()
				if Strip(WON, WH, WV, 1, WR, WG, WB, WA, nil, nil, nil, nil, wm, sa, sb) > 0 then run.wet = wm else wm:Destroy() end
				if run.wet then
					local bm = Mesh()
					if liquid then
						Strip(WON, WH, WV, 1, A.BR, A.BG, A.BB, WA, nil, nil, nil, nil, bm, sa, sb)
					else
						Strip(WON, WH, WV, 5, nil, nil, nil, nil, Q.br, Q.bg, Q.bb, nil, bm, sa, sb)
					end
					run.body = bm
				end
			end
			if run.mesh or run.halo then runs[#runs + 1] = run end
		end
		k = j + 1
	end
	-- colours keep ageing while it dries: until then it is built again now and then
	local newest = 0
	for q = 1, n do if ch.fed[q] > newest then newest = ch.fed[q] end end
	local rt = RealTime()
	-- (where the pose's count of moved bones stands with all of those bones read)
	local pv
	if wb and pose.Bone then
		-- (the pose keeps the bones that any of its channels' soft pieces hang on: they are read
		-- once a frame for all of them, Watch)
		local wl, ws = pose.wlist, pose.wset
		if not wl then
			wl, ws = {}, {}
			pose.wlist, pose.wset = wl, ws
		end
		for q = 1, #wb do
			local bb = wb[q]
			if not ws[bb] then
				ws[bb] = true
				wl[#wl + 1] = bb
			end
			pose:Bone(bb)
		end
		pv = pose.ver
	end
	ch.bake = { runs = runs, m = m, dist = src.dist, n = n, open = open, wet = withWet, halo = withHalo, t = rt, wb = wb, pv = pv,
		soft = soft, off = offB, softShare = softCost / max(n, 1),
		nextT = (open and rt + (withWet and 0.5 or 1)) or (not ch.done and rt + 3) or (now - newest < dryT and rt + 8) or math.huge }
	N = 0
	FD.bakes = FD.bakes + 1
	ABL.Prof.Count("flow bakes", 1)
end

-- A soft piece of a still channel from its nodes: sections ra..rb, as Bake makes them (the
-- sections before and after are made with them for the rounding and the evening, and left out:
-- they belong to the strips on either side). Added to what the live pass draws. Returns the
-- number of nodes worked out.
local function LiveSoft(ch, pose, m, ra, rb, off, now, dryT, tone, minW, haloRow)
	local n = ch.n
	if rb > n then rb = n end
	if ra > rb then return 0 end
	local ca, cb = ra > 1 and ra - 1 or ra, rb < n and rb + 1 or rb
	local jx, jy, jz
	if rb == n then
		local och = ch.joinCh
		if och and not och.dead and och.an[ch.joinIdx][4] == m then jx, jy, jz = pose:SkinPoint(och.an[ch.joinIdx]) end
	end
	local first, last = Sections(ch, pose, ca, cb, jx, jy, jz, off, now, dryT, tone, minW, haloRow, false)
	FD.Round(first, last)
	Even(first, last, SH, SON)
	Even(first, last, HH, HON)
	local fa, fb = first + (ra - ca), last - (cb - rb)
	if ca < ra then SON[first], HON[first] = false, false end
	if cb > rb then SON[last], HON[last] = false, false end
	if jx then
		local k = Section(jx, jy, jz, A.WNX[n], A.WNY[n], A.WNZ[n], SX[fb], SY[fb], SZ[fb], off, false)
		if SON[fb] then
			SH[k], SV[k], SON[k] = SH[fb] * 0.6, SV[fb], true
			SR[k], SG[k], SB[k], SA[k] = SR[fb], SG[fb], SB[fb], SA[fb]
		end
	end
	if ra == 1 and SON[fa] then SH[fa] = SH[fa] * 0.5 end
	if rb == n and not jx and SON[fb] then SH[fb] = SH[fb] * 0.35 end
	return cb - ca + 1
end

-- Whether the skin still lies under the strips of bake b: the watched nodes within tol of where
-- they were, in each bone's space.
local function Watch(ch, b, pose, tol)
	local runs, an = b.runs, ch.an
	-- A body of whose bones none has moved since these strips were last looked at (a body that
	-- lies still): the skin is where it was. The bones are read (once a frame each, whoever
	-- asks) and the pose's count of moved bones compared; no node is worked out.
	local wb = b.wb
	if not wb then return true end
	if b.pv then
		if pose.wF ~= pose.frame then
			local wl = pose.wlist
			if wl then
				for q = 1, #wl do pose:Bone(wl[q]) end
			end
			pose.wF = pose.frame
		end
		if pose.ver == b.pv then FD.wQuick = FD.wQuick + 1 return true end
	end
	FD.wFull = FD.wFull + 1
	for r = 1, #runs do
		local w = runs[r].w
		if w then
			local inv = pose:BoneInv(runs[r].bone)
			if inv then
				for q = 1, 12, 4 do
					local x, y, z = pose:SkinPoint(an[w[q]])
					if abs(inv[1] * x + inv[2] * y + inv[3] * z + inv[4] - w[q + 1]) + abs(inv[5] * x + inv[6] * y + inv[7] * z + inv[8] - w[q + 2])
						+ abs(inv[9] * x + inv[10] * y + inv[11] * z + inv[12] - w[q + 3]) > tol then return false end
				end
			end
		end
	end
	if b.pv then b.pv = pose.ver end
	return true
end

-- The filter strips are drawn with the filter's blend and the strips of the blood's own colour
-- without it, as the live pass draws them. (Until phase 35 the blend stayed on from the first
-- filter strip: the colour strips were multiplied into the picture instead of laid on it, so a
-- stream turned a shade darker and browner at the moment it went over to strips, and whatever
-- was drawn after the last strip of a frame was drawn with that blend too.)
-- softLive: the soft strips are left out (they are drawn from their nodes this frame).
local function DrawBaked(ch, body, pose, softLive)
	local runs = ch.bake.runs
	local M = Mats()
	local stain, lut, bodyMat = M.stain, M.lut, M.body
	FD.nRuns = (FD.nRuns or 0) + #runs
	for r = 1, #runs do
		local run = runs[r]
		if softLive and run.soft then
			-- (from its nodes)
		elseif not body then
			-- (a channel on the world: its strips are where they are)
			if run.halo then R.FilterDraw(stain, run.halo) end
			if run.mesh then R.FilterDraw(stain, run.mesh) end
			if run.sbody then
				R.EndFilter()
				render.SetMaterial(bodyMat)
				run.sbody:Draw()
			end
			if run.wet then R.FilterDraw(lut, run.wet) end
			if run.body then
				R.EndFilter()
				render.SetMaterial(bodyMat)
				run.body:Draw()
			end
		else
			-- (the bone's matrix as the pose has it for this frame: asked for once a bone, and
			-- no new matrix object a strip a frame)
			local mat
			local e = matSet and pose:Bone(run.bone)
			if e then
				matSet(boneMat, e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], e[11], e[12], 0, 0, 0, 1)
				mat = boneMat
			else
				mat = ABL.ZC.BoneMatrix(body, run.bone)
			end
			if mat then
				cam.PushModelMatrix(mat)
				if run.halo then R.FilterDraw(stain, run.halo) end
				if run.mesh then R.FilterDraw(stain, run.mesh) end
				if run.sbody then
					R.EndFilter()
					render.SetMaterial(bodyMat)
					run.sbody:Draw()
				end
				if run.wet then R.FilterDraw(lut, run.wet) end
				if run.body then
					R.EndFilter()
					render.SetMaterial(bodyMat)
					run.body:Draw()
				end
				cam.PopModelMatrix()
			end
		end
	end
	R.EndFilter()
end

-- Draws what a channel has baked, building its strips first where they are due (two channels a
-- frame at most). A channel in which nothing moves any more is baked as a whole: always once it is
-- dry, and farther from the camera as soon as it has stopped (near the camera the film on it is
-- still seen drying). A channel that runs is baked up to its newest node where Q.part allows.
-- Returns the node from which the channel is still to be drawn live (1: all of it, n + 1: nothing).
local function Baked(ch, src, pose, m, now, dryT, tone, minW, haloRow)
	local n = ch.n
	-- Still: nothing runs in it any more and nothing on it shines, so what is seen of it is its
	-- stain, the same from every side and at every frame. Always once it is dry. Before that
	-- when nothing has moved in it for a while and it is far, or drawn without reflections, or
	-- its wetness has gone (until phase 35 a channel near the camera was drawn from its nodes at
	-- every frame until the last of its film had dried, minutes after it had stopped).
	local still = ch.done or (ch.idleT > 4 and (src.dist > K.bakeDist or Q.part or (ch.wetMax or 1) <= SHEEN_OFF))
	local open = ch.head ~= nil or (ch.mobile or 0) > 1e-5 or not still
	if Q.nobake or (open and not (Q.part and n >= 6)) then
		if ch.bake then FreeBake(ch) end
		ABL.Prof.Count(Q.part and "flow ch short" or "flow ch near", 1)
		return 1
	end
	local body = src.body
	if src.world then body = nil elseif not IsValid(body) then return 1 end
	local b = ch.bake
	local fn = FrameNumber()
	local rt = RealTime()
	if bakeFrame ~= fn then bakeFrame, bakesLeft, waitBar, waitMax = fn, 2, waitMax, 0 end
	-- Skin that has moved under a soft strip (by more than about half a pixel): it is no strip of
	-- this channel any more, and nothing is drawn from a strip that lies beside the skin. Of a
	-- still channel the soft pieces are drawn from their nodes and the rigid strips stay; a
	-- channel that runs, or is soft for the most part, is drawn from its nodes as a whole. Strips that lasted are built again at
	-- once. Strips that did not last a second lie on skin that moves (a character who walks,
	-- breathes hard, is carried): the next are not tried at once but after a wait, twice as long
	-- each time, eight seconds at most.
	-- (Until phase 35 such strips were built again at every frame, two channels a frame, and the
	-- others were drawn from strips that had moved until their turn came, or never had any.)
	if b and b.m == m and not b.softOff then
		local tw = SysTime()
		local lies = Watch(ch, b, pose, min(0.07, 0.6 * src.dist / (L.pxK or 960)))
		FD.tWatch = FD.tWatch + SysTime() - tw
		if not lies then
			if rt - (b.t or 0) < 1 then
				ch.bakeBack = min((ch.bakeBack or 0.25) * 2, 8)
				ch.bakeHold = rt + ch.bakeBack
			else
				ch.bakeBack = nil
			end
			ABL.Prof.Count("flow ch moved", 1)
			-- (a channel that is soft for the most part, as on a trunk, is cheaper from its nodes
			-- as a whole than in pieces between a few rigid strips: measured, six swaying
			-- characters, 2.6 ms in pieces against 1.9 as wholes)
			if b.open or (b.softShare or 1) > 0.6 then
				FreeBake(ch)
				b = nil
			else
				b.softOff = true
			end
		end
	end
	local held = rt < (ch.bakeHold or 0)
	local why = (not b and 1) or (b.m ~= m and 2) or (b.softOff and 3) or (rt > b.nextT and 4) or (b.open ~= open and 5) or (b.halo ~= Q.halo and 6)
		or (open and b.wet ~= Q.wet and 7) or (open and n - b.n > 8 and 8) or (abs(src.dist - b.dist) > 0.35 * b.dist + 15 and 9)
	if why and not (held and (why == 3 or not b)) then
		-- Two bakes a frame, as before. A channel that has no strips comes before one whose strips
		-- are to be built again (those get the first of the two only), and of the channels that
		-- wait for that, the one that has waited longest: none is passed over for good.
		local first = why <= 2
		local wait = 0
		if not first then
			if not ch.wantT then ch.wantT = rt end
			wait = rt - ch.wantT
		end
		if bakesLeft > (first and 0 or 1) and (first or wait >= waitBar * 0.9) then
			bakesLeft = bakesLeft - 1
			ch.wantT = nil
			ABL.Prof.Count(WHY[why], 1)
			local PF = ABL.Prof
			if PF.heapOn then PF.Heap("flow.live") end
			local tb = SysTime()
			Bake(ch, src, pose, m, now, dryT, tone, minW, haloRow, open)
			FD.tBake = (FD.tBake or 0) + SysTime() - tb
			if PF.heapOn then PF.Heap("flow.bake") end
			b = ch.bake
		else
			if wait > waitMax then waitMax = wait end
			ABL.Prof.Count(WHY_NOT[why], 1)
		end
	end
	if not b or b.m ~= m then
		ABL.Prof.Count(held and "flow ch restless" or "flow ch unbaked", 1)
		return 1
	end
	local softLive = (b.softOff or Q.softdbg) and not b.open and b.soft ~= nil
	ABL.Prof.Count(softLive and "flow ch baked, soft pieces live" or "flow ch baked", 1)
	local td = SysTime()
	DrawBaked(ch, body, pose, softLive)
	FD.tBaked = (FD.tBaked or 0) + SysTime() - td
	if ABL.Prof.heapOn then ABL.Prof.Heap("flow.baked") end
	if softLive then ch.liveSoft, ch.liveOff = b.soft, b.off end
	if open then return b.n < n and b.n or n end
	return n + 1
end

-- All channels of one character. Called from ABL.Flow.DrawSource (same pass as the body).
function FD.Source(src, pose, m, near, gloss, off, now, dryT)
	local s = src.fc
	if not s or #s.chans == 0 then return end
	local t0 = SysTime()
	local WH, WV, WR, WG, WB, WA, WD = A.WH, A.WV, A.WR, A.WG, A.WB, A.WA, A.WD
	local GH, GV, GL, PU, PL, QU, QL = A.GH, A.GV, A.GL, A.PU, A.PL, A.QU, A.QL
	local WX, WY, WZ, WNX, WNY, WNZ, VIS = A.WX, A.WY, A.WZ, A.WNX, A.WNY, A.WNZ, A.VIS
	local PH, PHX, PHY, PHZ, GLT = A.PH, A.PHX, A.PHY, A.PHZ, A.GLT
	local GLN = 0
	local VW = F.VW
	local ex, ey, ez = L.eyeX, L.eyeY, L.eyeZ
	local Sim = ABL.Sim
	local view = FD.cvView:GetInt()
	local tone = src.tone or 1
	-- (a stream is kept a pixel or so wide however far away it is)
	local minW = src.dist * K.minWidth
	local Ff = C.Filter.fresh
	local tClot = K.clotTime * C.sv.drying:GetFloat()
	-- key light (the sun, or the sky above) and up, for the reflections
	local lx, ly, lz, lk = VW.sx, VW.sy, VW.sz, VW.sk
	local ux, uy, uz = VW.ux, VW.uy, VW.uz
	local specSlope, sheenK, specK, skyK = K.specSlope, K.sheenK, K.specK, K.skyK
	local DULL = K.clothDull
	-- (the soaked band is drawn at one depth, about a third of the deepest stain)
	local haloRow = RowS(K.stainMax * 0.32)
	-- Detail by distance, as the governor has scaled distances: far away (or under load) a stream is
	-- its stain alone, then the liquid on it, the reflections, the highlight lines.
	local eff = (src.dist or 0) / max(L.scale, 0.25)
	if eff > C.Body.nearDist then near = false end
	if not near or eff > C.Body.glossDist then gloss = false end
	local lines = gloss and eff < K.lineDist
	local halo = eff < K.haloDist
	-- (phase 21, C.P21.streamLiquid) A stream on the world in the pools' colours and light, over what it
	-- has left (where its liquid is drawn), mirroring as a pool does: FD.LiquidFor, cl_flowworld.lua
	local liquid = src.world == true and C.P21On("streamLiquid")
	local left = liquid and near
	if liquid then
		sheenK = C.P21.streamSheen or sheenK
		FD.LiquidLight(VW.mr or VW.lr, VW.mg or VW.lg, VW.mb or VW.lb)
	end
	N = 0
	local nPend = 0
	local nodes = 0
	local tSkin = 0
	local chans = s.chans
	-- first what is baked (see above); what is left of each channel is drawn live below
	-- the liquid's own colour under the light on this body
	local bodyR, bodyG, bodyB = min(255, 255 * VW.lr * K.bodyK), min(255, 255 * VW.lg * K.bodyK), min(255, 255 * VW.lb * K.bodyK)
	Q.off, Q.part, Q.wet, Q.halo, Q.tClot, Q.liquid = off, not gloss, near, halo, tClot, liquid
	local wetG, wetB = 255 * min(Ff[2], 1) ^ GAMMA, 255 * min(Ff[3], 1) ^ GAMMA
	mDk = -1
	local dbg = FD.cvDebug:GetInt()
	Q.nobake, VEC_POS, Q.softdbg = dbg % 2 == 1, dbg % 4 >= 2, dbg >= 4
	Q.br, Q.bg, Q.bb = bodyR, bodyG, bodyB
	-- ... and of what it has left: dried blood and blood in the cloth are darker and browner. Not a
	-- dye either: on dark or coloured cloth a stain is a dark red-brown, not black.
	local sk = K.stainBody / K.bodyK
	local stR, stG, stB = bodyR * sk, min(255, bodyG * sk * 2.2), min(255, bodyB * sk * 1.6)
	Q.sr, Q.sg, Q.sb = stR, stG, stB
	for c = 1, #chans do
		local ch = chans[c]
		local from = 1
		ch.liveSoft = nil
		if view == 0 and not ch.dead and ch.n >= 1 and ch.an[1][4] == m then
			from = Baked(ch, src, pose, m, now, dryT, tone, minW, haloRow)
		end
		ch.liveFrom = from
	end
	N = 0
	for c = 1, #chans do
		local ch = chans[c]
		local n = ch.n
		local an = ch.an
		local i0 = ch.liveFrom or 1
		if not ch.dead and n >= 1 and an[1][4] == m and i0 <= n then
			nodes = nodes + n - i0 + 1
			local al = Sim.Alpha(ch.lt, ch.sd)
			local hh, ww, ph, pw, wmax = ch.h, ch.w, ch.ph, ch.pw, ch.wmax
			local Vv, Fm, wet, age, gap = ch.V, ch.F, ch.wet, ch.age, ch.gap
			-- where the nodes are in this pose, and which of them face the camera
			local tk = SysTime()
			for i = (i0 > 1 and i0 - 1 or 1), n do
				local x, y, z, nx, ny, nz = pose:SkinPoint(an[i])
				WX[i], WY[i], WZ[i], WNX[i], WNY[i], WNZ[i] = x, y, z, nx, ny, nz
				local vx, vy, vz = ex - x, ey - y, ez - z
				VIS[i] = nx * vx + ny * vy + nz * vz > -0.25 * (abs(vx) + abs(vy) + abs(vz))
			end
			tSkin = tSkin + SysTime() - tk
			-- the end of the stream: its head, the stream it joined, or nothing
			local hd = ch.head
			local hx, hy, hz, hnx, hny, hnz
			if hd and hd.placed and hd.tri <= m.nt then
				if pose.HeadPoint then
					hx, hy, hz, hnx, hny, hnz = pose:HeadPoint(hd)
				else
					hx, hy, hz, hnx, hny, hnz = F.BeadPoint(pose, hd, m)
				end
			end
			local jx, jy, jz
			local och = ch.joinCh
			if och and not och.dead and och.an[ch.joinIdx][4] == m then
				jx, jy, jz = pose:SkinPoint(och.an[ch.joinIdx])
			end
			local first = N + 1
			local hue1, hue2, hue3 = 255, 255, 255
			local chId = ch.id
			-- (how dull the cloth makes a node's shine and how uneven its highlight line is: fixed
			-- to the node, worked out once)
			local dl, rp = ch.dl, ch.rp
			if not dl then dl, rp = {}, {} ch.dl, ch.rp = dl, rp end
			if view == 8 then hue1, hue2, hue3 = HueOf(ch.id) elseif view == 9 then hue1, hue2, hue3 = HueOf(ch.wd and ABL.Hash(tostring(ch.wd.id)) % 97 or 0) end
			local ltx, lty, ltz = 0, 0, 0
			-- (the side and the normal of the section before: no twist, no strip across a fold)
			local lsx, lsy, lsz, lnx, lny, lnz
			for i = i0, n do
				local x, y, z, nx, ny, nz = WX[i], WY[i], WZ[i], WNX[i], WNY[i], WNZ[i]
				-- run direction from the neighbours (not across a gap between mesh pieces)
				local x1, y1, z1, x2, y2, z2 = x, y, z, x, y, z
				if i > 1 and not gap[i - 1] then x1, y1, z1 = WX[i - 1], WY[i - 1], WZ[i - 1] end
				if i < n and not gap[i] then
					x2, y2, z2 = WX[i + 1], WY[i + 1], WZ[i + 1]
				elseif i == n then
					if hx then x2, y2, z2 = hx, hy, hz elseif jx then x2, y2, z2 = jx, jy, jz end
				end
				local tx, ty, tz = x2 - x1, y2 - y1, z2 - z1
				local tl = sqrt(tx * tx + ty * ty + tz * tz)
				if tl > 1e-5 then tx, ty, tz = tx / tl, ty / tl, tz / tl else tx, ty, tz = ltx, lty, ltz end
				ltx, lty, ltz = tx, ty, tz
				local sx, sy, sz = ty * nz - tz * ny, tz * nx - tx * nz, tx * ny - ty * nx
				local sl = sqrt(sx * sx + sy * sy + sz * sz)
				if sl < 1e-6 then
					sx, sy, sz = ABL.Perp(nx, ny, nz)
				else
					sx, sy, sz = sx / sl, sy / sl, sz / sl
				end
				local vis = VIS[i]
				-- A strip whose side turns over between two sections is two triangles crossed (a
				-- shard), and one across a fold of the skin (into a mouth, round an ear) stands in
				-- the air: the side is kept the way it was, and the strip ends at a fold.
				local fold = false
				if lsx and i > i0 and not gap[i - 1] then
					if sx * lsx + sy * lsy + sz * lsz < 0 then sx, sy, sz = -sx, -sy, -sz end
					fold = nx * lnx + ny * lny + nz * lnz < 0.15
				end
				lsx, lsy, lsz, lnx, lny, lnz = sx, sy, sz, nx, ny, nz
				local k = Section(x, y, z, nx, ny, nz, sx, sy, sz, off, i == i0 or gap[i - 1] or not vis or fold)
				if vis then
					local v = Vv[i]
					local h = ph[i] + (hh[i] - ph[i]) * al
					local w = pw[i] + (ww[i] - pw[i]) * al
					-- stain: everything that lies here, spread over the widest the stream has been (and,
					-- in cloth, over the band it has soaked)
					StainAt(ch, i, k, now, dryT, tone, minW, haloRow, left)
					-- wet: the rivulet as it is now
					local wetOn = v > 1e-6 and h > 1e-5
					if wetOn then
						local cl = min(age[i] / tClot, 1)
						-- (R.FilterColor written out for a full filter: its green and blue are the
						-- same for every node)
						WR[k], WG[k], WB[k], WA[k] = 255 * min(Ff[1] * tone * (1 - 0.3 * cl), 1) ^ GAMMA, wetG, wetB, 255
						WH[k], WV[k], WON[k], WD[k] = (Wide(w) + minW) * 0.5, Row(h), true, h
					end
					-- reflections where it is wet (a film that is drying mirrors less and less)
					if gloss then
						local wt = wetOn and 1 or wet[i] * 0.6
						-- (blood that is in the cloth does not shine as blood that stands on skin does)
						local dull = dl[i]
						if not dull then
							local abi = ch.ab[i] or 0
							dull = abi >= DULL and 0.15 or 1 - 0.85 * abi / DULL
							dl[i] = dull
						end
						if wt > 0.02 and (wetOn or SON[k]) then
							local vx, vy, vz = ex - x, ey - y, ez - z
							local vl = sqrt(vx * vx + vy * vy + vz * vz)
							if vl < 1e-4 then vl = 1e-4 end
							vx, vy, vz = vx / vl, vy / vl, vz / vl
							local ndv = nx * vx + ny * vy + nz * vz
							if ndv < 0 then ndv = 0 end
							local q = 1 - ndv
							local fres = 0.022 + 0.978 * q * q * q * q * q
							local rup = (2 * ndv * nx - vx) * ux + (2 * ndv * ny - vy) * uy + (2 * ndv * nz - vz) * uz
							local sky = rup > 0 and 0.45 + 0.9 * min(rup * 1.6, 1) or 0.15
							GH[k], GV[k], GON[k] = wetOn and WH[k] or SH[k] * 0.8, wt, true
							GL[k] = min(fres * sky * sheenK, 0.6) * 255 * wt * (0.4 + 0.6 * dull)
							-- Highlights: where across the rounded stream its surface mirrors a light to the
							-- eye. The stream's surface tilts sideways by up to its edge slope, so the line
							-- lies where the half vector between eye and light, seen across the stream,
							-- has that tilt; none when it would lie beyond the edge.
							if wetOn and lines then
								-- (the surface of a stream is not even: where it runs over the weave or a fold
								-- the line is brighter or gone. Fixed to the place, it does not run along.)
								-- (in stretches: squared, so that most of a stream has none)
								local ripple = rp[i]
								if not ripple then
									ripple = 0.5 + 0.5 * sin(i * 0.9 + chId * 2.3) * sin(i * 0.23 + chId * 1.3)
									ripple = ripple * ripple * dull
									rp[i] = ripple
								end
								local hx2, hy2, hz2 = vx + lx, vy + ly, vz + lz
								local hn = hx2 * nx + hy2 * ny + hz2 * nz
								if hn > 0.2 then
									local at = (hx2 * sx + hy2 * sy + hz2 * sz) / hn * specSlope
									local ht = (hx2 * tx + hy2 * ty + hz2 * tz) / hn
									local e = lk * exp(-ht * ht * 3) * specK * ripple
									if at > 0.8 or at < -0.8 then e = e * max(0, 1 - (abs(at) - 0.8) / 0.25) end
									if e > 0.02 then PU[k], PL[k], PON[k] = 0.5 - 0.25 * at, min(e, 1) * 255, true end
								end
								-- (the sky straight above: broader and dimmer, there in any light)
								hx2, hy2, hz2 = vx + ux, vy + uy, vz + uz
								hn = hx2 * nx + hy2 * ny + hz2 * nz
								if hn > 0.2 then
									local at = (hx2 * sx + hy2 * sy + hz2 * sz) / hn * specSlope
									local ht = (hx2 * tx + hy2 * ty + hz2 * tz) / hn
									local e = exp(-ht * ht * 0.6) * skyK * ripple
									if at > 0.8 or at < -0.8 then e = e * max(0, 1 - (abs(at) - 0.8) / 0.25) end
									if e > 0.02 then QU[k], QL[k], QON[k] = 0.5 - 0.25 * at, min(e, 1) * 255, true end
								end
							end
						end
					end
					if view > 0 then
						local t = 0
						if view == 1 then t = h / K.hMax
						elseif view == 2 then t = abs(ch.qv[i]) / K.viewSpeed
						elseif view == 3 then t = v > 1e-6 and 1 or wet[i] * 0.8
						elseif view == 4 then t = v > 1e-6 and age[i] / tClot or 0
						elseif view == 5 then t = 0.5 + 0.5 * ch.dr[i]
						elseif view == 6 then t = (v + Fm[i]) / K.viewMass end
						if view == 7 then
							DR[k], DG[k], DB[k] = 127 + 127 * nx, 127 + 127 * ny, 127 + 127 * nz
						elseif view >= 8 then
							DR[k], DG[k], DB[k] = hue1, hue2, hue3
						else
							DR[k], DG[k], DB[k] = Ramp(t)
						end
					end
				end
			end
			local last = N
			FD.Round(first, last)
			Even(first, last, SH, SON)
			Even(first, last, WH, WON)
			Even(first, last, HH, HON)
			-- the head: a bead a little wider than the stream, a dome that is rounded off in front
			if hx then
				local qx, qy, qz = WX[n], WY[n], WZ[n]
				local tx, ty, tz = hx - qx, hy - qy, hz - qz
				local tl = sqrt(tx * tx + ty * ty + tz * tz)
				local tl0 = tl
				-- (a head that has outrun its channel: nothing is drawn across the stretch between)
				local far = tl > 2
				if tl < 0.02 then
					-- (still on its last node: it points where it is going, or down the skin)
					tx, ty, tz = hd.vx, hd.vy, hd.vz
					tl = sqrt(tx * tx + ty * ty + tz * tz)
					if tl < 1e-3 then
						local gn = hd.ix * hnx + hd.iy * hny + hd.iz * hnz
						tx, ty, tz = hd.ix - hnx * gn, hd.iy - hny * gn, hd.iz - hnz * gn
						tl = sqrt(tx * tx + ty * ty + tz * tz)
					end
				end
				if tl < 1e-6 then
					tx, ty, tz = ABL.Perp(hnx, hny, hnz)
					tl = 1
				end
				tx, ty, tz = tx / tl, ty / tl, tz / tl
				local sx, sy, sz = ty * hnz - tz * hny, tz * hnx - tx * hnz, tx * hny - ty * hnx
				local sl = sqrt(sx * sx + sy * sy + sz * sz)
				if sl < 1e-6 then sl = 1 end
				sx, sy, sz = sx / sl, sy / sl, sz / sl
				local vx, vy, vz = ex - hx, ey - hy, ez - hz
				local vis = hnx * vx + hny * vy + hnz * vz > -0.25 * (abs(vx) + abs(vy) + abs(vz))
				local vol = max(hd.vol, 0)
				local hang = hd.hangK > 0.25 and vol > 0.008
				if hang and near then
					nPend = nPend + 1
					PH[nPend], PHX[nPend], PHY[nPend], PHZ[nPend] = hd, hx + hnx * off, hy + hny * off, hz + hnz * off
				end
				local cut = ch.cut
				if cut and vis and vol > 0.0004 and not hd.moving and not pose.HeadPoint then
					-- a small wound in its first seconds: beads along the cut (cl_flowcore.lua, MakeCut)
					local ax, ay, az, bx, by, bz = pose:Tri(hd.tri)
					local e1, e2, e3 = ABL.Norm(bx - ax, by - ay, bz - az)
					local q1, q2, q3 = hny * e3 - hnz * e2, hnz * e1 - hnx * e3, hnx * e2 - hny * e1
					local ca, sa = math.cos(cut.ang), math.sin(cut.ang)
					local d1, d2, d3 = e1 * ca + q1 * sa, e2 * ca + q2 * sa, e3 * ca + q3 * sa
					local cl = min(hd.bage / tClot, 1)
					local fr, fg, fb, fa = R.FilterColor(Ff[1] * tone * (1 - 0.3 * cl), Ff[2], Ff[3], 1)
					for j = 1, cut.n do
						local a = (cut.share[j] * vol / ML / 1.28) ^ 0.3333
						local o = cut.off[j]
						local cx, cy, cz = hx + d1 * o, hy + d2 * o, hz + d3 * o
						local gl = gloss and min(F.Reflect(hnx, hny, hnz, cx, cy, cz, 1) * sheenK * 0.6, 0.4) * 255
						for q = 1, 7 do
							local xk = (q == 1 and -1) or (q == 2 and -0.8) or (q == 3 and -0.45) or (q == 4 and 0) or (q == 5 and 0.45) or (q == 6 and 0.8) or 1
							local prof = sqrt(max(0, 1 - xk * xk))
							local k = Section(cx + tx * xk * a, cy + ty * xk * a, cz + tz * xk * a, hnx, hny, hnz, sx, sy, sz, off, q == 1)
							local hwk = (a * K.headGain + minW * 0.5) * max(prof, 0.12)
							local dk = 0.7 * a * max(prof, 0.08)
							WH[k], WV[k], WON[k], WD[k] = hwk, Row(dk), true, dk
							WR[k], WG[k], WB[k], WA[k] = fr, fg, fb, fa
							SH[k], SV[k], SON[k] = hwk, 0.3, true
							SR[k], SG[k], SB[k], SA[k] = fr, fg, fb, fa
							if gl then GH[k], GV[k], GON[k], GL[k] = hwk, 1, true, gl end
							DR[k], DG[k], DB[k] = hue1, hue2, hue3
						end
					end
				elseif vis and vol > 0.002 then
					-- (a hanging drop is drawn as a body of its own: on the skin under it only the wet patch)
					local flat = hang and near
					-- contact radius of a sessile bead of that volume (its visible size saturates: more
					-- blood shows as stream, not as a bigger bead)
					local a = (min(vol, K.headShow) / ML / 1.28) ^ 0.3333
					local streamH = last >= first and WON[last] and WH[last] or 0
					local hw = max(a * K.headGain + minW * 0.5, streamH * 1.1)
					local cl = min(hd.bage / tClot, 1)
					local fr, fg, fb, fa = R.FilterColor(Ff[1] * tone * (1 - 0.3 * cl), Ff[2], Ff[3], 1)
					local depth = 0.7 * a
					-- (resting on level skin it is no bead: a lens as wide as that much blood spreads)
					local lens = not hd.moving and hd.gt < 0.35 and hd.stuckT > 0.3 and vol > 0.03
					if lens then
						a = min(F.PuddleRadius(vol) * 1.1 + 0.04, 1.2)
						hw = a
						depth = C.Body.film
						tl0 = a * 2
					end
					-- from its back (the stream runs into it) over its middle to the tip: a dome. Its back
					-- reaches no further than the node the stream comes from.
					local back = (lens and 0.9) or (hd.atEdge and 0) or min(0.85, max(hd.travel > 0.02 and (tl0 - 0.04) / a or 0, 0))
					-- (a bead that has not run yet is round: a whole drop sitting where it formed)
					local round = not lens and not hd.atEdge and hd.travel <= 0.02
					local q0 = (lens or round or back > 0.2) and 1 or 3
					for q = q0, lens and 9 or 7 do
						local xk
						if lens then
							xk = -1 + (q - 1) * 0.25
						elseif round then
							xk = (q == 1 and -1) or (q == 2 and -0.8) or (q == 3 and -0.45) or (q == 4 and 0) or (q == 5 and 0.45) or (q == 6 and 0.8) or 1
						else
							xk = (q == 1 and -back) or (q == 2 and -back * 0.5) or (q == 3 and 0) or (q == 4 and 0.35) or (q == 5 and 0.65) or (q == 6 and 0.88) or 1
						end
						local prof = sqrt(max(0, 1 - xk * xk))
						-- (the back narrows only to the stream it is fed by)
						local wk = ((lens or round) and max(prof, 0.1)) or (xk < 0 and max(prof, min(1, streamH / hw))) or max(prof, 0.1)
						local k = Section(hx + tx * xk * a, hy + ty * xk * a, hz + tz * xk * a, hnx, hny, hnz, sx, sy, sz, off, (lens and q == 1) or (far and q == q0))
						if not flat then
							local dk = depth * max(prof, lens and 0.5 or 0.08)
							WH[k], WV[k], WON[k], WD[k] = hw * wk, Row(dk), true, dk
							WR[k], WG[k], WB[k], WA[k] = fr, fg, fb, fa
						end
						-- (its own film is the stain under it)
						SH[k], SV[k], SON[k] = hw * wk, 0.3, true
						SR[k], SG[k], SB[k], SA[k] = fr, fg, fb, fa
						if gloss and not flat then
							GH[k], GV[k], GON[k] = hw * wk, 1, true
							GL[k] = min(F.Reflect(hnx, hny, hnz, hx, hy, hz, 1) * sheenK * 0.6, 0.4) * 255
						end
						DR[k], DG[k], DB[k] = hue1, hue2, hue3
					end
					-- the glint of the key light on the bead: where its dome mirrors the light to the eye
					if gloss and not flat then
						local vl = sqrt(vx * vx + vy * vy + vz * vz)
						if vl < 1e-4 then vl = 1e-4 end
						local h1, h2, h3 = vx / vl + lx, vy / vl + ly, vz / vl + lz
						local hl = sqrt(h1 * h1 + h2 * h2 + h3 * h3)
						if hl > 1e-4 then
							h1, h2, h3 = h1 / hl, h2 / hl, h3 / hl
							local hn = h1 * hnx + h2 * hny + h3 * hnz
							-- (a cap of height 0.7 a: the sphere it is part of has radius 1.064 a)
							if hn > 0.36 then
								local rs = 1.064 * a
								local sink = 0.364 * a - off
								local o = GLN * 11
								GLN = GLN + 1
								GLT[o + 1] = hx + h1 * rs - hnx * sink
								GLT[o + 2] = hy + h2 * rs - hny * sink
								GLT[o + 3] = hz + h3 * rs - hnz * sink
								GLT[o + 4], GLT[o + 5], GLT[o + 6] = sx, sy, sz
								GLT[o + 7] = max(a * 0.3, minW * 0.6)
								GLT[o + 8] = min(lk * 1.3, 1) * 255
								GLT[o + 9], GLT[o + 10], GLT[o + 11] = tx, ty, tz
							end
						end
					end
					-- the stream runs into the bead: the node before it is wet up to the head
					if not flat and last >= first and VIS[n] and not WON[last] and (Vv[n] > 1e-6 or hd.moving) then
						-- (row 0.25: a layer 0.0027 units deep, Row)
						WH[last], WV[last], WON[last], WD[last] = max((Wide(ww[n]) + minW) * 0.5, hw * 0.4), 0.25, true, 0.0027
						WR[last], WG[last], WB[last], WA[last] = fr, fg, fb, fa
					end
				end
			elseif jx and last >= first and VIS[n] then
				-- into the stream it joined: narrowing, it disappears into the bigger one
				local k = Section(jx, jy, jz, WNX[n], WNY[n], WNZ[n], SX[last], SY[last], SZ[last], off, false)
				if SON[last] then
					SH[k], SV[k], SON[k] = SH[last] * 0.6, SV[last], true
					SR[k], SG[k], SB[k], SA[k] = SR[last], SG[last], SB[last], SA[last]
				end
				if WON[last] then
					WH[k], WV[k], WON[k], WD[k] = WH[last] * 0.6, WV[last], true, WD[last]
					WR[k], WG[k], WB[k], WA[k] = WR[last], WG[last], WB[last], WA[last]
				end
				if GON[last] then GH[k], GV[k], GON[k], GL[k] = GH[last] * 0.6, GV[last], true, GL[last] end
				DR[k], DG[k], DB[k] = DR[last], DG[last], DB[last]
			end
			-- a stream starts and ends in a point, not in a cut
			if last >= first then
				-- (not where the live stretch only continues a baked one)
				if i0 == 1 then
					if SON[first] then SH[first] = SH[first] * 0.5 end
					if WON[first] then WH[first] = WH[first] * 0.6 end
				end
				if not hx and not jx then
					if SON[last] then SH[last] = SH[last] * 0.35 end
					if WON[last] then WH[last] = WH[last] * 0.35 end
				end
			end
			-- (C.P21.streamLiquid: the liquid's own colour, its head's too, by depth)
			if liquid and near then
				FD.LiquidFor(ch.surf)
				FD.LiquidFill(first, N)
			end
		end
	end
	-- the soft pieces of still channels under which the skin has moved (Bake), from their nodes
	if view == 0 then
		local nSoft = 0
		for c = 1, #chans do
			local ch = chans[c]
			local soft = ch.liveSoft
			if soft and not ch.dead then
				local tk = SysTime()
				for q = 1, #soft, 2 do nSoft = nSoft + LiveSoft(ch, pose, m, soft[q], soft[q + 1], ch.liveOff or off, now, dryT, tone, minW, haloRow) end
				tSkin = tSkin + SysTime() - tk
			end
		end
		nodes = nodes + nSoft
		ABL.Prof.Count("flow soft nodes", nSoft)
	end
	-- beads that have set where they came to rest (cl_flowcore.lua): clots, dark and no longer wet
	if view == 0 then
		for c = 1, #chans do
			local cb = chans[c].clotBead
			if cb and cb[4] == m and not chans[c].dead then
				local x, y, z, nx, ny, nz = pose:SkinPoint(cb)
				local vx, vy, vz = ex - x, ey - y, ez - z
				if nx * vx + ny * vy + nz * vz > -0.25 * (abs(vx) + abs(vy) + abs(vz)) then
					local tx, ty, tz = ABL.Perp(nx, ny, nz)
					local sx, sy, sz = ty * nz - tz * ny, tz * nx - tx * nz, tx * ny - ty * nx
					local a = cb.r + minW * 0.5
					local fr, fg, fb, fa = R.FilterColor(Ff[1] * tone * 0.6, Ff[2], Ff[3], 1)
					for q = 1, 7 do
						local xk = (q == 1 and -1) or (q == 2 and -0.8) or (q == 3 and -0.45) or (q == 4 and 0) or (q == 5 and 0.45) or (q == 6 and 0.8) or 1
						local k = Section(x + tx * xk * a, y + ty * xk * a, z + tz * xk * a, nx, ny, nz, sx, sy, sz, off, q == 1)
						SH[k], SV[k], SON[k] = a * max(sqrt(max(0, 1 - xk * xk)), 0.12), 0.95, true
						SR[k], SG[k], SB[k], SA[k] = fr, fg, fb, fa
					end
				end
			end
		end
	end
	local tStrip = SysTime()
	if N >= 2 then
		local verts = 0
		if view > 0 then
			-- one opaque ribbon of the chosen state, wide enough to read
			for i = 1, N do
				local h = max(SON[i] and SH[i] or 0, WON[i] and WH[i] or 0, 0.06 + minW)
				SON[i] = SON[i] or WON[i]
				SH[i] = h
			end
			render.SetMaterial(Mats().plain)
			verts = Strip(SON, SH, nil, 3, DR, DG, DB)
		else
			local M = Mats()
			if halo then
				render.SetMaterial(M.stain)
				R.BeginFilter()
				verts = Strip(HON, HH, HV, 1, SR, SG, SB, SA)
			end
			render.SetMaterial(M.stain)
			R.BeginFilter()
			verts = verts + Strip(SON, SH, SV, 1, SR, SG, SB, SA)
			R.EndFilter()
			-- (the stain's own colour over the filter, then the liquid on top of both)
			render.SetMaterial(M.body)
			verts = verts + Strip(SON, SH, SV, 5, nil, nil, nil, nil, stR, stG, stB, K.stainRow)
			if near then
				render.SetMaterial(M.lut)
				R.BeginFilter()
				verts = verts + Strip(WON, WH, WV, 1, WR, WG, WB, WA)
				R.EndFilter()
			end
			-- the liquid's own colour over what shows through it
			if near then
				render.SetMaterial(M.body)
				if liquid then
					verts = verts + Strip(WON, WH, WV, 1, A.BR, A.BG, A.BB, WA)
				else
					verts = verts + Strip(WON, WH, WV, 5, nil, nil, nil, nil, bodyR, bodyG, bodyB)
				end
			end
			if gloss then
				render.SetMaterial(M.sheen)
				verts = verts + Strip(GON, GH, GV, 2, nil, nil, nil, GL, VW.lr, VW.lg, VW.lb)
				if lines then
					render.SetMaterial(M.spec)
					verts = verts + Strip(PON, GH, GV, 4, nil, nil, nil, PL, VW.lr, VW.lg, VW.lb, PU)
					-- (the sky's line is broader: the lower rows of the same lookup)
					for i = 1, N do if QON[i] then GV[i] = GV[i] * 0.7 end end
					render.SetMaterial(M.spec)
					verts = verts + Strip(QON, GH, GV, 4, nil, nil, nil, QL, VW.lr, VW.lg, VW.lb, QU)
				end
				-- glints on the heads: small quads lying on the beads
				if GLN > 0 then
					render.SetMaterial(ABL.Mat.glint)
					mesh.Begin(MATERIAL_QUADS, GLN)
					for g = 0, GLN - 1 do
						local o = g * 11
						local x, y, z, r, e = GLT[o + 1], GLT[o + 2], GLT[o + 3], GLT[o + 7], GLT[o + 8]
						local ax, ay, az = GLT[o + 4] * r, GLT[o + 5] * r, GLT[o + 6] * r
						local bx, by, bz = GLT[o + 9] * r, GLT[o + 10] * r, GLT[o + 11] * r
						local cr, cg, cb = min(255, e * VW.lr), min(255, e * VW.lg), min(255, e * VW.lb)
						V(x - ax - bx, y - ay - by, z - az - bz, 0, 0, cr, cg, cb, 255)
						V(x + ax - bx, y + ay - by, z + az - bz, 1, 0, cr, cg, cb, 255)
						V(x + ax + bx, y + ay + by, z + az + bz, 1, 1, cr, cg, cb, 255)
						V(x - ax + bx, y - ay + by, z - az + bz, 0, 1, cr, cg, cb, 255)
					end
					mesh.End()
				end
			end
		end
		ABL.Prof.Count("flow verts", verts)
	end
	ABL.Prof.Add("sub.flow.strips", SysTime() - tStrip)
	ABL.Prof.Add("sub.flow.skin", tSkin)
	ABL.Prof.Add("sub.flow.watch", FD.tWatch)
	ABL.Prof.Count("watch: body at rest", FD.wQuick) ABL.Prof.Count("watch: nodes", FD.wFull)
	FD.wQuick, FD.wFull, FD.tWatch = 0, 0, 0
	-- hanging drops: 3D teardrops along gravity, all in one triangle strip
	if nPend > 0 and view == 0 then
		local gx, gy, gz, gmag = ABL.Gravity()
		local fresh = C.Colors.fresh
		render.SetColorMaterial()
		mesh.Begin(MATERIAL_TRIANGLE_STRIP, nPend * (F.PEND_VERTS + 2) - 4)
		for i = 1, nPend do
			local hd = PH[i]
			local k = min(hd.hangK, 1.3)
			local rad = 0.12 + 0.3 * (min(hd.vol, 0.15) ^ 0.3333) * (0.75 + 0.3 * k)
			local len = rad * (1.3 + 1.5 * k)
			F.Pendant(PHX[i], PHY[i], PHZ[i], gx / gmag, gy / gmag, gz / gmag, rad, len, fresh[1] * tone, fresh[2], fresh[3], 245, i > 1, i < nPend, 0.4)
			PH[i] = nil
		end
		mesh.End()
	end
	ABL.Prof.Count("flow nodes", nodes)
	ABL.Prof.Add("sub.body.flow", SysTime() - t0)
	ABL.Prof.Add("sub.flow.bake", FD.tBake or 0) ABL.Prof.Add("sub.flow.baked", FD.tBaked or 0)
	ABL.Prof.Count("flow runs drawn", FD.nRuns or 0)
	FD.tBake, FD.tBaked, FD.nRuns = 0, 0, 0
	if ABL.Prof.heapOn then ABL.Prof.Heap("flow.live") end
	-- (developer: the test harness reads the sections just drawn, cl_p21test.lua)
	if FD.tap then FD.tap(src, A, N, near, gloss, lines, halo) end
end

-- The name of the developer view on screen, with what the colours mean.
hook.Add("HUDPaint", "ABL_FlowView", function()
	local view = FD.cvView:GetInt()
	if view == 0 then return end
	local scale = {
		string.format("blue 0 .. red %.2f mm", K.hMax * 25.4),
		string.format("blue 0 .. red %.0f units/s", K.viewSpeed),
		"blue dry .. red wet",
		"blue fresh .. red set (clotted)",
		"blue: driven back up the channel, green: level, red: driven down it",
		string.format("blue 0 .. red %.3f ml per node", K.viewMass),
		"surface normal as colour",
		"one colour per channel",
		"one colour per wound",
	}
	draw.SimpleTextOutlined("blood flow view " .. view .. ": " .. FD.VIEWS[view] .. "   (" .. scale[view] .. ")", "DermaDefault", ScrW() * 0.5, 40, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
end)
