-- Pool canvases.
-- Every pool is drawn from its own slot in a shared render-target page instead of from a fixed
-- texture. The slot is repainted from the pool's field stamps whenever the pool changes, so a
-- ground pool is one continuous, growing mass rather than a decal.
--   page A (RGBA8): the pool's colour (rim and body bands times the stamps' interior detail, in
--     the palette of its outermost, first-drying region) and, in alpha, its field around the
--     outline, 0.95 + 16 (F - t). The pool material thresholds that alpha per screen pixel
--     ($distancealpha), so the outline stays crisp at any magnification.
--   page B (RGBA8, half resolution, same slot layout): the part that is still wet (wet palette,
--     alpha = wet mask), drawn over page A while a pool dries, and the mask of the reflection.
--   field (RGBA16F): the summed field F (alpha) and interior detail (rgb) of the pool being
--     painted. ramp (RGBA16F): thresholds and ramps computed from F.
-- F is the sum of the pool's stamps (atlas alpha = spreading potential, see texgen), plus a tiled
-- edge noise, times clip ramps at walls and ledges. The pool is where F exceeds
-- t = 0.5 + half the noise amplitude. A ramp clamp((F - lo) * s) is built in blend state as
-- "constant lo, subtract F, double k times", which is exact in the alpha channel, so no custom
-- shader is needed. Slots come from a buddy allocator (512 / 256 / 128 px by the pool's size on
-- screen); a pool keeps its old slot until the new one has been painted.
-- Render targets cannot be freed, so they are created once with fixed names and sizes.

ABL.NoJIT()
ABL.PoolCanvas = ABL.PoolCanvas or {}
local PCV = ABL.PoolCanvas
local C = ABL.Config
local PC = C.Pool
local min, max, floor, cos, sin, sqrt = math.min, math.max, math.floor, math.cos, math.sin, math.sqrt

local SCR = 512          -- field / ramp size = largest slot
PCV.page = PCV.page or nil
PCV.float = true
PCV.ready = false
PCV.stats = { paints = 0, ms = 0, slots = 0, used = 0 }

local B_ZERO, B_ONE, B_DC, B_DA, B_ODA, B_SA = BLEND_ZERO, BLEND_ONE, BLEND_DST_COLOR, BLEND_DST_ALPHA, BLEND_ONE_MINUS_DST_ALPHA, BLEND_SRC_ALPHA
local B_OSA, B_SC = BLEND_ONE_MINUS_SRC_ALPHA, BLEND_SRC_COLOR
local F_ADD, F_SUB = BLENDFUNC_ADD, BLENDFUNC_SUBTRACT

local pageA, pageB, pageC, field, ramp, oldB, patchRT, embRT
local matWhite, matAtlas, matNoise, matCracks, matField, matRamp, matPageB, matCrackMask, matOldB, matPatch, matEmb
local matPatchT, matPageAT
local PT = 128           -- the patch target's size

------------------------------------------------------------------------------------------
-- Resources
------------------------------------------------------------------------------------------
local RT_FLAGS = bit.bor(4, 8, 256, 512)   -- clamp s/t, no mips, no LOD

local function Unlit(name, tex, extra)
	local kv = { ["$basetexture"] = tex, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1 }
	for k, v in pairs(extra or {}) do kv[k] = v end
	return CreateMaterial(name, "UnlitGeneric", kv)
end

local function MakeScratch(float)
	local fmt = float and IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
	local sfx = float and "" or "8"
	field = GetRenderTargetEx("abl_poolfield" .. sfx, SCR, SCR, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, fmt)
	ramp = GetRenderTargetEx("abl_poolramp" .. sfx, SCR, SCR, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, fmt)
	matField = Unlit("abl_poolfield_mat" .. sfx, field:GetName(), { ["$ignorez"] = 1 })
	matRamp = Unlit("abl_poolramp_mat" .. sfx, ramp:GetName(), { ["$ignorez"] = 1 })
end

function PCV.Init()
	if PCV.page then return end
	-- the page size is chosen once per session (quality at the time of the first pool)
	local page = C.cl.quality:GetInt() >= 2 and 2048 or 1024
	PCV.page = page
	pageA = GetRenderTargetEx("abl_poolpage_" .. page, page, page, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	pageB = GetRenderTargetEx("abl_poolwet_" .. page / 2, page / 2, page / 2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	-- page C (the layout of page B): what the layer lets through, as a factor on the floor
	pageC = GetRenderTargetEx("abl_poolthru_" .. page / 2, page / 2, page / 2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	-- (nothing anywhere to begin with: its colour and its cover are both read at a slot's rim,
	-- where the neighbouring texel is another slot's, and a page that begins black and opaque
	-- drew a dark hairline along the rim of a pool's mesh)
	render.PushRenderTarget(pageC)
	render.Clear(0, 0, 0, 0, false, false)
	render.PopRenderTarget()
	MakeScratch(true)
	matWhite = Unlit("abl_pc_white", "vgui/white", { ["$ignorez"] = 1 })
	matAtlas = Unlit("abl_pc_atlas", "advancedblood/pools/poolatlas", { ["$ignorez"] = 1 })
	matNoise = Unlit("abl_pc_noise", "advancedblood/pools/noise", { ["$ignorez"] = 1 })
	matCracks = Unlit("abl_pc_cracks", "advancedblood/pools/cracks", { ["$ignorez"] = 1 })
	matPageB = Unlit("abl_pc_pageb", pageB:GetName(), { ["$ignorez"] = 1 })
	-- what a pool showed before its lattice changed, as patches of the potential (one pool at
	-- a time: PCV.MorphBegin)
	oldB = GetRenderTargetEx("abl_poolold_b", SCR / 2, SCR / 2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	matOldB = Unlit("abl_pc_oldb", oldB:GetName(), { ["$ignorez"] = 1 })
	-- the patch of the pool being painted (two texels a cell)
	patchRT = GetRenderTargetEx("abl_poolpatch", PT, PT, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	matPatch = Unlit("abl_pc_patch", patchRT:GetName(), { ["$ignorez"] = 1 })
	-- (the same colours times the filter's gain: what a layer of that colour lets through)
	local fg = PC.filterGain
	local fgs = string.format("[%.3f %.3f %.3f]", fg[1], fg[2], fg[3])
	matPatchT = Unlit("abl_pc_patcht", patchRT:GetName(), { ["$ignorez"] = 1, ["$color"] = fgs })
	matPageAT = Unlit("abl_pc_pageat", pageA:GetName(), { ["$ignorez"] = 1, ["$color"] = fgs })
	-- the slope of the layer at its edge (Meniscus)
	embRT = GetRenderTargetEx("abl_poolemb", SCR / 2, SCR / 2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	matEmb = Unlit("abl_pc_emb", embRT:GetName(), { ["$ignorez"] = 1 })
	matCrackMask = Unlit("abl_pc_crackmask", "advancedblood/pools/crackmask", { ["$ignorez"] = 1 })
	-- final materials. Pool: page A, outline thresholded per pixel ($distancealpha; sharp near, softer
	-- when the slot is minified). Page A's alpha is AE at the outline and rises past 1 across the rim
	-- band: the threshold cuts a crisp contact line where the output alpha jumps to about AE (the thin
	-- film at the rim is translucent), then it rises to opaque over the thick body.
	-- Reflection: page B's wet mask (rgb and alpha), additive, times a tiled pattern of mirrored
	-- surroundings slid with the view (detail stage). Glint: the same mask times the sun's reflection
	-- (a clamped highlight positioned per pool through the detail transform).
	local AE = PC.rimTranslucency
	PCV.alphaEdge = AE - 0.025
	-- A pool is drawn twice (cl_pools.lua, P.Draw). First as what the layer lets through: thin
	-- blood is a filter on the floor, red passes it, green and blue do not, so on a light floor it
	-- is scarlet and on a dark one it is barely there. That is page C: the cells' colours times
	-- filterGain, and how much of the floor they cover, from nothing at the outline to all of it
	-- a little way in (FilterPage). It needs no cut, so it has no hard edge. Then the pool's own
	-- colour over that, as opaque as page A's alpha says:
	-- a thin cell is half filter, a full layer is opaque. (Blended half and half with the bare
	-- floor, as it was before phase 33, a thin red film on a light floor was pink. Cut at the
	-- outline with an alpha test, as in phase 33, the filter had an edge of whole pixels under
	-- the colour's soft one: stair steps on a light floor, and an outline that moved in jerks.)
	local band = PC.rimBand
	PCV.matFilter = CreateMaterial("abl_pool_thru", "UnlitGeneric", {
		["$basetexture"] = pageC:GetName(), ["$translucent"] = 1, ["$nocull"] = 1,
	})
	PCV.matPool = Unlit("abl_pool_sharp", pageA:GetName(), {
		["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = AE + band, ["$edgesoftnessend"] = AE - 0.05,
	})
	PCV.matPoolSoft = Unlit("abl_pool_soft", pageA:GetName(), {
		["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = AE + 0.08 + band, ["$edgesoftnessend"] = AE - 0.2,
	})
	-- (phase 19: cl_pools.lua, P.Draw, sets these two materials' window and colour pool by pool as it
	-- draws them, and gives them back these windows and a white colour with abl_liquid_v19 0)
	PCV.edgeKeep = {
		[PCV.matPool] = { AE + band, AE - 0.05 },
		[PCV.matPoolSoft] = { AE + 0.08 + band, AE - 0.2 },
	}
	PCV.matSheen = CreateMaterial("abl_pool_reflect", "UnlitGeneric", {
		["$basetexture"] = pageB:GetName(), ["$additive"] = 1,
		["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
		["$detail"] = "advancedblood/sprites/sheen", ["$detailscale"] = 1, ["$detailblendmode"] = 0,
	})
	-- the map's cubemap mirrored about the pool's surface normal (mesh normals), masked by page B's
	-- wet alpha through the blend (SRC_ALPHA, ONE; the base colour is zeroed by $color)
	PCV.matEnv = CreateMaterial("abl_pool_env", "UnlitGeneric", {
		["$basetexture"] = pageB:GetName(), ["$additive"] = 1,
		["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
		["$color"] = "[0 0 0]", ["$envmap"] = "env_cubemap", ["$envmaptint"] = "[0.1 0.1 0.1]",
		["$envmapsaturation"] = PC.envSaturation,
	})
	PCV.matGlint = CreateMaterial("abl_pool_glint", "UnlitGeneric", {
		["$basetexture"] = pageB:GetName(), ["$additive"] = 1,
		["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
		["$detail"] = "advancedblood/sprites/glintdetail", ["$detailscale"] = 1, ["$detailblendmode"] = 0,
	})
	-- developer views of the pages (abl_pool_debug 8 / 16)
	PCV.viewA = CreateMaterial("abl_pool_viewa", "UnlitGeneric", { ["$basetexture"] = pageA:GetName(), ["$translucent"] = 1, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1 })
	PCV.viewB = CreateMaterial("abl_pool_viewb", "UnlitGeneric", { ["$basetexture"] = pageB:GetName(), ["$translucent"] = 1, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1 })
	PCV.InitSlots()
end

------------------------------------------------------------------------------------------
-- Slots: quadtree buddy allocator over the page (512, 256 and 128 px blocks)
------------------------------------------------------------------------------------------
local SIZES = { 512, 256, 128 }
local free = {}          -- size -> { key -> block }
local freeCount = {}

local function Key(x, y, s) return x * 65536 + y + s * 0.25 end

local function PutFree(x, y, s)
	free[s][Key(x, y, s)] = { x = x, y = y, size = s }
	freeCount[s] = freeCount[s] + 1
end

local function TakeFree(x, y, s)
	local k = Key(x, y, s)
	local b = free[s][k]
	if b then free[s][k] = nil freeCount[s] = freeCount[s] - 1 end
	return b
end

function PCV.InitSlots()
	for _, s in ipairs(SIZES) do free[s] = {} freeCount[s] = 0 end
	for y = 0, PCV.page - 512, 512 do
		for x = 0, PCV.page - 512, 512 do PutFree(x, y, 512) end
	end
	PCV.stats.used = 0
end

function PCV.Alloc(s)
	if freeCount[s] > 0 then
		local _, b = next(free[s])
		TakeFree(b.x, b.y, s)
		PCV.stats.used = PCV.stats.used + s * s
		return { x = b.x, y = b.y, size = s }
	end
	if s >= 512 then return nil end
	local parent = PCV.Alloc(s * 2)
	if not parent then return nil end
	PCV.stats.used = PCV.stats.used - parent.size * parent.size
	-- split: keep the first quarter, free the other three
	PutFree(parent.x + s, parent.y, s)
	PutFree(parent.x, parent.y + s, s)
	PutFree(parent.x + s, parent.y + s, s)
	PCV.stats.used = PCV.stats.used + s * s
	return { x = parent.x, y = parent.y, size = s }
end

function PCV.Free(slot)
	if not slot or slot.freed then return end
	slot.freed = true
	local x, y, s = slot.x, slot.y, slot.size
	PCV.stats.used = PCV.stats.used - s * s
	-- merge with the three siblings while they are all free
	while s < 512 do
		local px, py = x - x % (s * 2), y - y % (s * 2)
		local sib = {}
		for _, o in ipairs({ { 0, 0 }, { s, 0 }, { 0, s }, { s, s } }) do
			local bx, by = px + o[1], py + o[2]
			if bx ~= x or by ~= y then sib[#sib + 1] = { bx, by } end
		end
		local all = true
		for _, q in ipairs(sib) do if not free[s][Key(q[1], q[2], s)] then all = false break end end
		if not all then break end
		for _, q in ipairs(sib) do TakeFree(q[1], q[2], s) end
		x, y, s = px, py, s * 2
	end
	PutFree(x, y, s)
end

-- Fraction of the page in use (for the debug HUD).
function PCV.Usage() return PCV.page and PCV.stats.used / (PCV.page * PCV.page) or 0 end

------------------------------------------------------------------------------------------
-- Drawing helpers (inside cam.Start2D on a pushed render target, coordinates in pixels)
------------------------------------------------------------------------------------------
local pv = Vector()
local function V(x, y, u, v, r, g, b, a)
	pv:SetUnpacked(x, y, 0)
	mesh.Position(pv)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

local function Quad(mat, x, y, w, h, r, g, b, a, u0, v0, u1, v1)
	render.SetMaterial(mat)
	mesh.Begin(MATERIAL_QUADS, 1)
	V(x, y, u0 or 0, v0 or 0, r, g, b, a)
	V(x + w, y, u1 or 1, v0 or 0, r, g, b, a)
	V(x + w, y + h, u1 or 1, v1 or 1, r, g, b, a)
	V(x, y + h, u0 or 0, v1 or 1, r, g, b, a)
	mesh.End()
end

local function Blend(sc, dc, op, sa, da, opa) render.OverrideBlend(true, sc, dc, op, sa, da, opa) end
-- (The engine keeps the first value an override is switched on with: later calls with another
-- value change nothing until the override has been switched off. So within one paint the masks
-- are what its first call says, which has to be "both", and every pass names blend factors for
-- the channel it does not mean to write: zero for the source, one for the target.)
local function Writes(color, alpha)
	render.OverrideColorWriteEnable(true, color)
	render.OverrideAlphaWriteEnable(true, alpha)
end
local function A8(v) return floor(min(max(v, 0), 1) * 255 + 0.5) end

local depth = 0
local function Push(rt)
	render.PushRenderTarget(rt)
	cam.Start2D()
	depth = depth + 1
end
local function Pop()
	cam.End2D()
	render.PopRenderTarget()
	depth = depth - 1
end
local function Reset()
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
end

-- Ramp into the ramp target: alpha = (F - lo) * scale (clamped at 0 and 1 only on 8-bit targets).
local function Ramp(S, lo, scale)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, 0, 0, S, S, 255, 255, 255, A8(lo))
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_SUB)                -- src - dst: F - lo
	local uv = S / SCR
	Quad(matField, 0, 0, S, S, 255, 255, 255, 255, 0, 0, uv, uv)
	if scale < 0.999 then
		Blend(B_ZERO, B_ONE, F_ADD, B_ZERO, B_SA, F_ADD)            -- dst * src alpha
		Quad(matWhite, 0, 0, S, S, 255, 255, 255, A8(scale))
		return
	end
	Blend(B_ZERO, B_ONE, F_ADD, B_DA, B_ONE, F_ADD)                 -- dst * (1 + src alpha)
	while scale >= 1.999 do
		Quad(matWhite, 0, 0, S, S, 255, 255, 255, 255)
		scale = scale * 0.5
	end
	if scale > 1.004 then Quad(matWhite, 0, 0, S, S, 255, 255, 255, A8(scale - 1)) end
end

-- Copy the ramp's alpha into a page slot's alpha (clamped by the 8-bit target).
local function CopyAlpha(src, x, y, w, S)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ZERO, F_ADD)
	local uv = S / SCR
	Quad(src, x, y, w, w, 255, 255, 255, 255, 0, 0, uv, uv)
end

-- Blend a flat colour into a slot's rgb where the slot's own alpha (a mask copied there just
-- before) is set: rgb = rgb (1 - a) + colour a.
local function MaskedColour(x, y, w, col)
	Writes(true, false)
	Blend(B_DA, B_ODA, F_ADD, B_ZERO, B_ONE, F_ADD)
	Quad(matWhite, x, y, w, w, col[1], col[2], col[3], 255)
end

local function FillColour(x, y, w, col)
	Writes(true, false)
	Blend(B_ONE, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	Quad(matWhite, x, y, w, w, col[1], col[2], col[3], 255)
end

-- Page C for the slot at (bx, by), bw wide (see PCV.Init). Alpha: how much of the floor the
-- layer covers there, nothing at the outline and all of it a little way in (the floor outside
-- the contact line is dry: a band that began outside it was a red glow round the pool, and it
-- moved with the liquid's steps, not with what is shown). Colour: the quad of `mat` (the pool's
-- colours times the filter's gain; none when mat is nil) times that cover. Drawn as floor x (colour + 1 - alpha): where
-- the alpha is nothing the floor is exactly what it was, whatever the engine's exposure does to
-- what a material puts out. The field is the one of this paint.
local FILTER_GAIN = 7
local function FilterPage(S, t, bx, by, bw, mat, x, y, w, h, u0, v0, u1, v1)
	Push(ramp)
	-- (phase 22, C.P22.edgeFilter: all of the floor covered from a little outside the outline in,
	-- under the band where the colour is half there; before, a seventh of it at the outline and all of
	-- it an eighth of the potential inside: the edge was half red, half bare floor, a pink line)
	if C.P22On ~= nil and C.P22On("edgeFilter") then
		Ramp(S, t - 0.06, 25)
	else
		Ramp(S, t - 0.02, FILTER_GAIN)
	end
	Pop()
	Push(pageC)
	render.SetScissorRect(bx, by, bx + bw, by + bw, true)
	Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, bx, by, bw, bw, 0, 0, 0, 0)
	CopyAlpha(matRamp, bx, by, bw, S)
	if mat then
		Blend(B_DA, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
		Quad(mat, x, y, w, h, 255, 255, 255, 255, u0, v0, u1, v1)
	end
	render.SetScissorRect(0, 0, 0, 0, false)
	Pop()
end

local function MultiplyDetail(x, y, w, S)
	Writes(true, false)
	Blend(B_DC, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	local uv = S / SCR
	Quad(matField, x, y, w, w, 255, 255, 255, 255, 0, 0, uv, uv)
end

------------------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------------------
local cells = ABL.PoolAtlas.cells
local BLACK, WHITE = { 0, 0, 0 }, { 255, 255, 255 }

-- One stamp quad (pixel space of the canvas).
local function Stamp(b, ox, oy, k)
	local c = cells[b.cell]
	local cx, cy = (b.u - ox) * k, (b.v - oy) * k
	local h = b.hs * k
	local ca, sa = cos(b.rot), sin(b.rot)
	local ax, ay = ca * h * b.asp, sa * h * b.asp
	local fl = b.flip and -h or h
	local bx, by = -sa * fl, ca * fl
	local a = A8(b.w)
	V(cx - ax - bx, cy - ay - by, c.u0, c.v0, 255, 255, 255, a)
	V(cx + ax - bx, cy + ay - by, c.u1, c.v0, 255, 255, 255, a)
	V(cx + ax + bx, cy + ay + by, c.u1, c.v1, 255, 255, 255, a)
	V(cx - ax + bx, cy - ay + by, c.u0, c.v1, 255, 255, 255, a)
end

-- Tiled noise over the canvas at world scale, per-pool offset and rotation.
local function NoiseQuad(S, ox, oy, k, lk, r, g, b, a)
	local sc = 1 / PC.noiseWorld
	local cr, sr = cos(lk.noiseRot), sin(lk.noiseRot)
	local function UV(px, py)
		local u, v = ox + px / k, oy + py / k
		return (u * cr - v * sr) * sc + lk.noiseU, (u * sr + v * cr) * sc + lk.noiseV
	end
	render.SetMaterial(matNoise)
	mesh.Begin(MATERIAL_QUADS, 1)
	local u, v = UV(0, 0) V(0, 0, u, v, r, g, b, a)
	u, v = UV(S, 0) V(S, 0, u, v, r, g, b, a)
	u, v = UV(S, S) V(S, S, u, v, r, g, b, a)
	u, v = UV(0, S) V(0, S, u, v, r, g, b, a)
	mesh.End()
end

-- Craquelure of old dried blood: the tiled crack pattern multiplied into the colour,
-- rgb * lerp(1, crack, s) through the filter blend (premultiplied vertex colour).
local function CrackQuad(x0, y0, S, ox, oy, k, lk, s)
	local sc = 1 / PC.crackWorld
	local cr, sr = cos(lk.noiseRot + 1.3), sin(lk.noiseRot + 1.3)
	local function UV(px, py)
		local u, v = ox + px / k, oy + py / k
		return (u * cr - v * sr) * sc + lk.noiseV, (u * sr + v * cr) * sc + lk.noiseU
	end
	local c = floor(255 * s ^ (1 / 2.2) + 0.5)
	local a = A8(s)
	render.SetMaterial(matCracks)
	mesh.Begin(MATERIAL_QUADS, 1)
	local u, v = UV(0, 0) V(x0, y0, u, v, c, c, c, a)
	u, v = UV(S, 0) V(x0 + S, y0, u, v, c, c, c, a)
	u, v = UV(S, S) V(x0 + S, y0 + S, u, v, c, c, c, a)
	u, v = UV(0, S) V(x0, y0 + S, u, v, c, c, c, a)
	mesh.End()
end

-- Walls and ledges: the field is multiplied to zero beyond each clip line, with a 1.5 px ramp.
local function Clips(clips, S, ox, oy, k)
	if #clips == 0 then return end
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ZERO, B_SA, F_ADD)
	render.SetMaterial(matWhite)
	mesh.Begin(MATERIAL_QUADS, #clips * 2)
	local big = S * 3
	for _, c in ipairs(clips) do
		local qx, qy = (c.u - ox) * k, (c.v - oy) * k
		local mx, my = c.mu, c.mv
		local tx, ty = -my, mx
		local rx, ry = qx - mx * 1.5, qy - my * 1.5
		V(rx - tx * big, ry - ty * big, 0, 0, 255, 255, 255, 255)
		V(rx + tx * big, ry + ty * big, 0, 0, 255, 255, 255, 255)
		V(qx + tx * big, qy + ty * big, 0, 0, 255, 255, 255, 0)
		V(qx - tx * big, qy - ty * big, 0, 0, 255, 255, 255, 0)
		local fx, fy = qx + mx * big, qy + my * big
		V(qx - tx * big, qy - ty * big, 0, 0, 255, 255, 255, 0)
		V(qx + tx * big, qy + ty * big, 0, 0, 255, 255, 255, 0)
		V(fx + tx * big, fy + ty * big, 0, 0, 255, 255, 255, 0)
		V(fx - tx * big, fy - ty * big, 0, 0, 255, 255, 255, 0)
	end
	mesh.End()
end

local function PaintInner(p, slot)
	local S = slot.size
	local cv, lk = p.canvas, p.look
	local k = S / (2 * cv.H)
	local ox, oy = cv.cu - cv.H, cv.cv - cv.H
	local t = 0.5 + lk.amp * 0.5

	-- 1. field: stamps (alpha: sum of weighted potentials, rgb: product of detail), mottling,
	--    edge noise, clips
	Push(field)
	Writes(true, true)
	Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, 0, 0, S, S, 255, 255, 255, 0)
	if #p.blobs > 0 then
		Blend(B_DC, B_ZERO, F_ADD, B_ONE, B_ONE, F_ADD)
		render.SetMaterial(matAtlas)
		mesh.Begin(MATERIAL_QUADS, #p.blobs)
		for _, b in ipairs(p.blobs) do Stamp(b, ox, oy, k) end
		mesh.End()
	end
	Writes(true, false)
	Blend(B_DC, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	NoiseQuad(S, ox, oy, k, lk, 255, 255, 255, 255)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
	NoiseQuad(S, ox, oy, k, lk, 255, 255, 255, A8(lk.amp))
	Clips(p.clips, S, ox, oy, k)
	Pop()

	-- 2. colour bands of page A. Rim ramp (F - t) * 16: the rim colour at the outline, the body
	--    colour where the ramp is full. Page B (reflection mask, rgb and alpha) = that ramp while
	--    the whole pool is wet.
	local mode = lk.wetMode
	local ax, ay = slot.x, slot.y
	local bx, by, bw = slot.x / 2, slot.y / 2, S / 2
	Push(ramp)
	Ramp(S, t, 16)
	Pop()
	Push(pageA)
	FillColour(ax, ay, S, lk.rimA)
	CopyAlpha(matRamp, ax, ay, S, S)
	MaskedColour(ax, ay, S, lk.bodyA)
	Pop()
	if mode == "wet" then
		Push(pageB)
		FillColour(bx, by, bw, BLACK)
		CopyAlpha(matRamp, bx, by, bw, S)
		MaskedColour(bx, by, bw, WHITE)
		Pop()
	elseif mode == "mixed" then
		-- 3. drying: the thin margin has dried (page A's palette), the thick part is still wet: the wet
		--    body colour where the wet ramp is full, and the reflection only there
		Push(ramp)
		Ramp(S, min(t + lk.hw, 1), 1 / PC.wetRamp)
		Pop()
		Push(pageA)
		CopyAlpha(matRamp, ax, ay, S, S)
		MaskedColour(ax, ay, S, lk.bodyB)
		Pop()
		Push(pageB)
		FillColour(bx, by, bw, BLACK)
		CopyAlpha(matRamp, bx, by, bw, S)
		MaskedColour(bx, by, bw, WHITE)
		Pop()
	end
	Push(pageA)
	MultiplyDetail(ax, ay, S, S)
	-- old dried blood cracks
	if (lk.crack or 0) > 0.01 then
		Writes(true, false)
		Blend(B_DC, B_OSA, F_ADD, B_ZERO, B_ONE, F_ADD)
		CrackQuad(ax, ay, S, ox, oy, k, lk, lk.crack)
	end
	Pop()

	-- (what the layer lets through: page A's colours times the filter's gain)
	local PG = PCV.page
	FilterPage(S, t, bx, by, bw, matPageAT, bx, by, bw, bw, ax / PG, ay / PG, (ax + S) / PG, (ay + S) / PG)

	-- 4. outline alpha AE + 16 (F - t) into page A (the ramp target was used for page C: rebuilt)
	local ae = PCV.alphaEdge
	Push(ramp)
	Ramp(S, t - ae / 16, 16)
	Pop()
	Push(pageA)
	CopyAlpha(matRamp, ax, ay, S, S)
	Pop()
end

------------------------------------------------------------------------------------------
-- Painting a liquid pool (cl_poolsim.lua) from its cells.
-- Every cell that holds blood gets, from what is on it:
--   * a potential: with T the whole layer (liquid, set, dried, absorbed),
--     F = t (1.7 + 1.3 (T / film)^(1/3)). Whatever blood stains a cell keeps it well inside the
--     outline (F = t): a pool dries where it lay, and a streak one cell wide survives the
--     smoothing below. A dry cell beside wet blood gets up to 0.6 t as the head beside it nears
--     what the cell holds back, so the outline leans out over it before the cell is taken;
--   * a colour: by depth from the clear red of a thin film over the deep burgundy of a film's
--     depth to near black, toward the aged palette as it sets, and toward the brown of dried
--     blood by the share of the cell that has dried (thin: light, a crust: dark; browner with
--     the time since);
--   * a gloss: what is liquid mirrors, set blood less, dried blood not at all;
--   * a crack strength: a thick layer that has been dry for a while breaks into plates, and the
--     floor shows through the cracks between them.
-- Colour and half the potential are drawn as triangle strips, one vertex a cell, into a small
-- patch (two texels a cell) in the pool's own slot of page B, which is the last thing painted.
-- From there the potential is enlarged into the field through 25 taps over two cells' width
-- (Taps: what a lattice would show at the scale of its cells is taken out, as surface tension
-- rounds an edge), and
-- the colours are enlarged into page A. The rest is the pipeline of the stamps: edge noise,
-- clip lines, the rim ramp, the outline alpha. The rim ramp's gain is low here: a lattice's
-- potential rises by a whole film within one cell, so the band over which the film at the
-- outline becomes the opaque body is as wide as the layer takes to build up.
------------------------------------------------------------------------------------------
local exp = math.exp
local GM = 2             -- texels of margin around the patch
local st = {}            -- the lattice being painted and the constants of this paint
local AN = {}            -- colour anchors of this paint: wet thin, body, deep; set thin, body; dry thin, body, deep; old shift
local pt = { r = {}, g = {}, b = {}, a = {}, w = {}, c = {} }     -- the patch, one entry a cell

-- (x^(1/3) and 1 - exp(-2.2 x) for a layer of x films, in steps of 1/32 up to 4)
local LUT_V, LUT_K = {}, {}
for q = 0, 128 do
	LUT_V[q] = (q / 32) ^ (1 / 3)
	LUT_K[q] = 1 - exp(-2.2 * q / 32)
end
-- (phase 19, poolDepthColour: 1 - exp(-u) for a layer u times C.V19.poolDeepScale deep, in steps of
-- 1/64 up to 8)
local LUT_D = {}
for q = 0, 512 do LUT_D[q] = 1 - exp(-q / 64) end
local BODY = ABL.PoolSim and ABL.PoolSim.BODY or 4     -- (a lattice's cell under a lying body)
-- (is phase 19's part `name` on: sh_config.lua, C.V19On)
local function V19(name) return C.V19On ~= nil and C.V19On(name) end

local function Heat(x)
	if x < 0 then x = 0 elseif x > 1 then x = 1 end
	if x < 0.5 then return 0, 510 * x, 255 * (1 - 2 * x) end
	return 510 * (x - 0.5), 255 * (2 - 2 * x), 0
end

-- Developer view 7: which cells hang together (a number for every connected region of cells
-- that hold blood, in st.lab).
local labStack = {}
local function Label(g)
	local lab = st.lab or {}
	st.lab = lab
	local n = g.n
	local h, k, s, ab = g.h, g.k, g.s, g.ab
	for c = 1, n * n do lab[c] = 0 end
	local id = 0
	for j = g.by0, g.by1 do
		for i = g.bx0, g.bx1 do
			local c0 = j * n + i + 1
			if lab[c0] == 0 and h[c0] + k[c0] + s[c0] + ab[c0] > 0 then
				id = id + 1
				local sp = 1
				labStack[1] = c0
				lab[c0] = id
				while sp > 0 do
					local q = labStack[sp]
					sp = sp - 1
					local qi = (q - 1) % n
					for d = 1, 4 do
						local r = (d == 1 and qi > 0 and q - 1) or (d == 2 and qi < n - 1 and q + 1) or (d == 3 and q > n and q - n) or (d == 4 and q <= n * (n - 1) and q + n) or nil
						if r and lab[r] == 0 and h[r] + k[r] + s[r] + ab[r] > 0 then
							lab[r] = id
							sp = sp + 1
							labStack[sp] = r
						end
					end
				end
			end
		end
	end
end

-- Developer views (abl_pool_view): what a cell holds, as a colour.
local function ViewColour(c, view, hh, kk, ss, aa)
	local g = st.g
	if view == 7 then return Heat((st.lab[c] * 0.37) % 1) end
	if view == 1 then return Heat((hh + kk + ss + aa) * st.invFilm / 3) end
	if view == 2 then return Heat(g.sh[c] * hh / 3 / 2) end
	if view == 3 then
		-- (the state most of the cell's blood is in)
		if hh >= kk and hh >= ss and hh >= aa then return 235, 30, 30 end
		if kk >= ss and kk >= aa then return 200, 40, 200 end
		if ss >= aa then return 150, 110, 40 end
		return 120, 120, 120
	end
	if view == 4 then return Heat(hh > 0 and (st.now - g.tb[c]) / st.clotT or 1) end
	if view == 5 then return Heat((g.hc[c] / g.film - 1) / max(g.amp, 0.01)) end
	local i, j = (c - 1) % g.n, floor((c - 1) / g.n)
	local on = (i + j) % 2 == 0 and 255 or 150
	return on, on, (i >= g.ax0 and i <= g.ax1 and j >= g.ay0 and j <= g.ay1) and 0 or on
end

-- (phase 22, C.P22.depthTone) How full each cell of the patch stands for its colour, in films: its own
-- and its wet neighbours' wet layer (weights 4 for itself, 2 a side, 1 a corner). The colour of a
-- lattice is drawn cell by cell, and where the depth changes across a few cells (a thin reach beside
-- the body, the floor's rises) the cells step from thin to full: by each cell's own depth, a comb of
-- lighter teeth along the step, a cell apart (run p22_f, the 80 s pictures at three times their
-- size). A dry neighbour is left out: counted as empty it would lighten every edge by a band a cell
-- wide, an outline. Kept from paint to paint (nothing is allocated); BuildPatch writes the patch's
-- cells, and Cell reads only those (every cell that has held anything lies inside the patch).
local xsT = {}
local function SmoothFull(g, x0, y0, nx, ny)
	local n, h, k, blk = g.n, g.h, g.k, g.blk
	local inv = 1 / g.film
	for j = max(y0, 0), min(y0 + ny - 1, n - 1) do
		for i = max(x0, 0), min(x0 + nx - 1, n - 1) do
			local c = j * n + i + 1
			if blk[c] == 0 and h[c] + k[c] > 0 then
				local sw, sx = 4, 4 * (h[c] + k[c])
				for dj = -1, 1 do
					local jj = j + dj
					if jj >= 0 and jj < n then
						for di = -1, 1 do
							local ii = i + di
							if (di ~= 0 or dj ~= 0) and ii >= 0 and ii < n then
								local q = jj * n + ii + 1
								local wq = h[q] + k[q]
								if blk[q] == 0 and wq > 0 then
									local wt = (di == 0 or dj == 0) and 2 or 1
									sw, sx = sw + wt, sx + wt * wq
								end
							end
						end
					end
				end
				xsT[c] = sx / sw * inv
			else
				xsT[c] = nil
			end
		end
	end
end

-- Colour (0..255), half the potential (alpha byte), gloss (alpha byte) and crack strength
-- (0..1) of cell c, or nil when it holds nothing.
local function Cell(c)
	local hh, kk, ss, aa = st.h[c], st.k[c], st.s[c], st.ab[c]
	local wet = hh + kk
	local all = wet + ss + aa
	if all < 1e-6 then return nil end
	local x = all * st.invFilm
	local xi = x >= 4 and 128 or floor(x * 32 + 0.5)
	local f = st.kf * (0.85 + 0.65 * LUT_V[xi])
	if f > 255 then f = 255 end
	local om = wet / all
	local gl = om * 1.25
	if gl > 1 then gl = 1 end
	if kk > 0 then gl = gl * (1 - 0.3 * kk / wet) end
	-- how well the layer mirrors goes by how deep the wet blood stands: a thin film follows the
	-- floor's grain and mirrors dully, a full layer lies level, the deeper blood where it arrives
	-- stands proud and smooth
	-- (a layer of six tenths of a film and more has buried the grain: its free surface is flat
	-- and it mirrors as a liquid does. Only what is thinner, the film a pool leaves where it has
	-- run off, is dull. With the full mirror kept for blood deeper than a film and a half, as it
	-- was, a pool at rest, which is level at one film, mirrored half of what it should: matt.)
	local xw = wet * st.invFilm
	local tf = 1
	if xw < 0.6 then
		tf = xw / 0.6
		tf = 0.05 + 0.95 * tf * tf
	end
	gl = gl * tf
	if st.view ~= 0 then
		local r, g, b = ViewColour(c, st.view, hh, kk, ss, aa)
		return r, g, b, f, gl * 255, 0, x
	end
	local an = AN
	local kT = LUT_K[xi]
	local r, g, b
	if st.toneD then
		-- (phase 22, C.P22.depthTone) The wet layer's colour by how full it stands, in films of its
		-- surface: the thin film's colour up to toneThin, the body's at toneBody, the deep colour from
		-- toneDeep on, eased between. The floor's own unevenness (C.P22.relief) has the liquid stand
		-- deeper in its hollows and thinner on its rises: so much darker and lighter, where it lies.
		-- (By the phase-19 rule in units, 1 - exp(-depth / 0.08), a pool at rest 1.6 to 2.7 mm deep on
		-- concrete was one colour.) How full: the cell's with its neighbours' (SmoothFull).
		local xt = xsT[c] or xw
		local ts
		if xt <= st.toneT then
			r, g, b = an[1], an[2], an[3]
			ts = 0
		elseif xt < st.toneB then
			local x = (xt - st.toneT) / (st.toneB - st.toneT)
			x = x * x * (3 - 2 * x)
			r, g, b = an[1] + (an[4] - an[1]) * x, an[2] + (an[5] - an[2]) * x, an[3] + (an[6] - an[3]) * x
			ts = x
		else
			local x = (xt - st.toneB) / (st.toneD - st.toneB)
			if x > 1 then x = 1 end
			x = x * x * (3 - 2 * x)
			r, g, b = an[4] + (st.deepR - an[4]) * x, an[5] + (st.deepG - an[5]) * x, an[6] + (st.deepB - an[6]) * x
			ts = 1
		end
		-- (blood that has set: the aged palette's thin film over its body, by the same share)
		if kk > 0 then
			local gf = kk / wet * 0.85
			r, g, b = r + (an[10] + (an[13] - an[10]) * ts - r) * gf, g + (an[11] + (an[14] - an[11]) * ts - g) * gf, b + (an[12] + (an[15] - an[12]) * ts - b) * gf
		end
	elseif st.depthC then
		-- (phase 19, poolDepthColour) The wet layer's colour by how deep it stands, in units, by the
		-- film's own rule (cl_filmdraw.lua, Look): 1 - exp(-depth / poolDeepScale) from the thin film's
		-- colour (0) over the body's (a half) to the deep's (1). A pool at rest, 0.085 units deep, is
		-- two thirds of the way, its thin rim a fifth: the run that feeds a pool and the pool are one
		-- liquid, the deeper the darker. (By films of the floor, as before, a pool at rest was its
		-- body colour, lighter than the 0.045-unit run on the body beside it.) The film's own scale
		-- (0.02) would make every pool its deepest colour all over: pools have a scale of their own.
		local u = wet * st.invDeep
		local dL = LUT_D[u >= 8 and 512 or (u > 0 and floor(u * 64 + 0.5) or 0)]
		local ts
		if dL < 0.5 then
			ts = dL * 2
			r, g, b = an[1] + (an[4] - an[1]) * ts, an[2] + (an[5] - an[2]) * ts, an[3] + (an[6] - an[3]) * ts
		else
			local td = dL * 2 - 1
			r, g, b = an[4] + (an[7] - an[4]) * td, an[5] + (an[8] - an[5]) * td, an[6] + (an[9] - an[6]) * td
			ts = 1
		end
		-- (blood that has set: the aged palette's thin film over its body, by the same share)
		if kk > 0 then
			local gf = kk / wet * 0.85
			r, g, b = r + (an[10] + (an[13] - an[10]) * ts - r) * gf, g + (an[11] + (an[14] - an[11]) * ts - g) * gf, b + (an[12] + (an[15] - an[12]) * ts - b) * gf
		end
	else
		r, g, b = an[1] + (an[4] - an[1]) * kT, an[2] + (an[5] - an[2]) * kT, an[3] + (an[6] - an[3]) * kT
		if x > 1.5 then
			local dk = (x - 1.5) / 1.5
			if dk > 1 then dk = 1 end
			r, g, b = r + (an[7] - r) * dk, g + (an[8] - g) * dk, b + (an[9] - b) * dk
		end
		if kk > 0 then
			local gf = kk / wet * 0.85
			r, g, b = r + (an[10] + (an[13] - an[10]) * kT - r) * gf, g + (an[11] + (an[14] - an[11]) * kT - g) * gf, b + (an[12] + (an[15] - an[12]) * kT - b) * gf
		end
	end
	local crack = 0
	if om < 0.999 then
		local dr, dg, db = an[16] + (an[19] - an[16]) * kT, an[17] + (an[20] - an[17]) * kT, an[18] + (an[21] - an[18]) * kT
		if x > 1.5 then
			local dk = (x - 1.5) / 1.5
			if dk > 1 then dk = 1 end
			dr, dg, db = dr + (an[22] - dr) * dk, dg + (an[23] - dg) * dk, db + (an[24] - db) * dk
		end
		local td = st.td[c]
		if td ~= 0 then
			local age = st.now - td
			local old = age / 400
			if old > 1 then old = 1 end
			dr, dg, db = dr + an[25] * old, dg + an[26] * old, db + an[27] * old
			local thick = (ss * st.invFilm - st.crackFrom) / st.crackSpan
			if thick > 0 and age > 30 then
				if thick > 1 then thick = 1 end
				crack = thick * min((age - 30) / 240, 1) * st.crackMax
			end
		end
		local m = sqrt(om)
		-- What the floor has drunk is not dried blood: it is wet blood in the floor's pores, as red
		-- as a thin film, and turns brown in the time a stain takes to dry. (Shown as dried at
		-- once, the thin margin of a pool seconds old was tan.)
		if aa > 0 then
			local wk = 1 - (st.now - st.tb[c]) / st.soakDry
			if wk > 0 then m = m + (1 - m) * wk * aa / (aa + ss) end
		end
		r, g, b = dr + (r - dr) * m, dg + (g - dg) * m, db + (b - db) * m
	end
	return r, g, b, f, gl * 255, crack, x
end

-- How far the meniscus leans out over cell c from the wet cells beside it: the head beside it
-- against what the cell holds back, from 0 (nothing near) to 0.5 (about to cross).
local function Lean(c, i, j)
	local g = st.g
	local n, h, k, blk, zf = g.n, g.h, g.k, g.blk, g.zf
	local zc, thr = zf[c], g.w[c] ~= 0 and g.hc[c] * g.memK or g.hc[c]
	if thr <= 0 then return 0 end
	local b = 0
	local q
	if i > 0 then
		q = c - 1
		if h[q] + k[q] > 0 and blk[q] == 0 then b = max(b, zf[q] + h[q] - zc) end
	end
	if i < n - 1 then
		q = c + 1
		if h[q] + k[q] > 0 and blk[q] == 0 then b = max(b, zf[q] + h[q] - zc) end
	end
	if j > 0 then
		q = c - n
		if h[q] + k[q] > 0 and blk[q] == 0 then b = max(b, zf[q] + h[q] - zc) end
	end
	if j < n - 1 then
		q = c + n
		if h[q] + k[q] > 0 and blk[q] == 0 then b = max(b, zf[q] + h[q] - zc) end
	end
	return min(b / thr, 1) - 0.5
end

-- How much of each cell is shown as covered (0..1; g.dv, one entry a cell, kept beside the
-- lattice). A cell the blood has only just reached holds a trace of it, and a coarse cell at
-- the pool's edge is partly empty: neither is drawn as a full cell. What is shown follows what
-- the cell holds over a moment (BuildPatch), and what has been shown stays shown while the cell
-- holds blood. When the lattice has another window or coarser cells, what was shown is carried
-- to where it now lies. Returns the array, and whether it is new (nothing shown before).
local function Cover(g, p, now)
	local n = g.n
	local dv = g.dv
	if dv and g.dvN == n and g.dvI == g.i0 and g.dvJ == g.j0 and g.dvA == g.a then return dv, false end
	-- (dvS: when the cell was first seen with blood; dvR: the pace it fills in at, per second)
	-- (two sets of arrays in turn: the window of a growing pool is laid anew every cell or two of
	-- its growth, and three new arrays each time were garbage)
	local sp = g.dvSpare
	local new, seen, pace
	if sp then new, seen, pace = sp[1], sp[2], sp[3] else new, seen, pace = {}, {}, {} end
	local nn = n * n
	for c = 1, nn do new[c], seen[c], pace[c] = 0, 0, 0 end
	for c = #new, nn + 1, -1 do new[c], seen[c], pace[c] = nil, nil, nil end
	local oldS, oldR = g.dvS, g.dvR
	g.dvS, g.dvR = seen, pace
	local fresh = dv == nil
	if dv then
		local on, oi, oj = g.dvN, g.dvI, g.dvJ
		local sc = max(floor(g.a / g.dvA + 0.5), 1)
		local share = 1 / (sc * sc)
		-- (the same cells in another window: when each was first seen and the pace it fills in
		-- at go with it. A growing pool's window is laid anew every cell or two of its growth;
		-- with the paces forgotten then, as until phase 34, every cell that was filling in went
		-- on at the fastest pace from that frame on: the front moved in jerks, three a second.)
		local same = sc == 1 and oldS ~= nil
		for j = 0, on - 1 do
			local J = floor((oj + j) / sc) - g.j0
			if J >= 0 and J < n then
				for i = 0, on - 1 do
					local o = j * on + i + 1
					local v = dv[o]
					local I = floor((oi + i) / sc) - g.i0
					if I >= 0 and I < n then
						local q = J * n + I + 1
						if same then
							new[q], seen[q], pace[q] = v, oldS[o], oldR[o]
						elseif v > 0 then
							v = new[q] + v * share
							new[q] = v > 1 and 1 or v
							seen[q] = now - 0.5
						end
					end
				end
			end
		end
	end
	if dv and oldS then
		sp = sp or {}
		sp[1], sp[2], sp[3] = dv, oldS, oldR
		g.dvSpare = sp
	else
		g.dvSpare = nil
	end
	g.dv, g.dvN, g.dvI, g.dvJ, g.dvA = new, n, g.i0, g.j0, g.a
	return new, fresh
end
PCV.Cover = Cover

-- Cover that arrives with another pool's blood (cl_pools.lua, SimMerge): amt more of cell c.
function PCV.CoverAdd(g, c, amt)
	local dv = g.dv
	if not dv then return end
	local v = (dv[c] or 0) + amt
	dv[c] = v > 1 and 1 or v
	if g.dvS[c] == 0 then g.dvS[c] = CurTime() - 0.5 end
end

-- What stands beside open cell c: whether a side of it is dry (the cell is at the pool's
-- edge), the most blood on a side (units), when the side that has been wet the longest was
-- first seen wet, and the most that is shown of a side.
local function Beside(c, i, j, now)
	local g = st.g
	local n, blk, h, k, s, ab = g.n, g.blk, g.h, g.k, g.s, g.ab
	local dv, seen = g.dv, g.dvS
	local edge, xn, told, dn = false, 0, now, 0
	for side = 1, 4 do
		local q
		if side == 1 then
			if i > 0 then q = c - 1 end
		elseif side == 2 then
			if i < n - 1 then q = c + 1 end
		elseif side == 3 then
			if j > 0 then q = c - n end
		elseif j < n - 1 then
			q = c + n
		end
		if not q then
			edge = true
		elseif blk[q] == 0 then
			local v = h[q] + k[q] + s[q] + ab[q]
			if v > 1e-6 then
				if v > xn then xn = v end
				local tq = seen[q]
				if tq > 0 and tq < told then told = tq end
				if dv[q] > dn then dn = dv[q] end
			else
				edge = true
			end
		end
	end
	return edge, xn, told, dn
end

-- (phase 19, poolBodyFill) Where a body lies in its pool. A hitbox is wider than the body where the
-- body curves up from the floor, and the cells it closes showed the blood beside them one cell deep
-- (BuildPatch): a sliver of bare floor between the flank and the pool (PHASE18, run p18a). So the
-- body's cells take the colour and the potential of the blood beside them up to fill cells deep,
-- shaded where the body and the floor meet: the body hides it where it lies on the floor, and
-- where its flank curves away the pool comes up to it. Drawn only: the lattice is not touched.
-- A body's cell beside an open one that holds blood shows the fullest such (as a closed cell always
-- did), and the body's cells behind it, straight on from there, show the same, fill cells deep at
-- the most. (Spread to every side, the blood ran on along the body's edge past where it lies.)
-- fillS[c]: the cell whose colour and potential c shows (nil: none); fillR[c]: the step straight
-- on. Kept in these tables from paint to paint (nothing is allocated). Returns the patch's
-- rectangle grown to the cells so shown, while the patch keeps two texels a cell (PaintSim), else
-- the rectangle as it was (what lies outside it is not drawn).
local fillQ, fillS, fillD, fillV, fillR = {}, {}, {}, {}, {}
local fillN = 0
local function BodyFill(g, x0, y0, nx, ny, fill)
	for q = 1, fillN do
		local c = fillQ[q]
		fillS[c], fillD[c], fillV[c], fillR[c], fillQ[q] = nil, nil, nil, nil, nil
	end
	fillN = 0
	local n, blk, h, k, s, ab = g.n, g.blk, g.h, g.k, g.s, g.ab
	local ia, ib = max(x0, 0), min(x0 + nx - 1, n - 1)
	local ja, jb = max(y0, 0), min(y0 + ny - 1, n - 1)
	local fi0, fi1, fj0, fj1 = x0, x0 + nx - 1, y0, y0 + ny - 1
	for j = ja, jb do
		local row = j * n
		for i = ia, ib do
			local c = row + i + 1
			if blk[c] == BODY then
				local best, bv = nil, 1e-6
				local q = c - 1
				if i > 0 and blk[q] == 0 then
					local v = h[q] + k[q] + s[q] + ab[q]
					if v > bv then best, bv = q, v end
				end
				q = c + 1
				if i < n - 1 and blk[q] == 0 then
					local v = h[q] + k[q] + s[q] + ab[q]
					if v > bv then best, bv = q, v end
				end
				q = c - n
				if j > 0 and blk[q] == 0 then
					local v = h[q] + k[q] + s[q] + ab[q]
					if v > bv then best, bv = q, v end
				end
				q = c + n
				if j < n - 1 and blk[q] == 0 then
					local v = h[q] + k[q] + s[q] + ab[q]
					if v > bv then best, bv = q, v end
				end
				if best then
					fillN = fillN + 1
					fillQ[fillN] = c
					fillS[c], fillD[c], fillV[c], fillR[c] = best, 1, bv, c - best
				end
			end
		end
	end
	-- (the queue holds each layer after the one before: every cell's next one straight on is added
	-- behind it; where two such lines meet in a cell, the fuller blood shows)
	local q = 1
	while q <= fillN do
		local c = fillQ[q]
		local d = fillD[c]
		if d < fill then
			local dir = fillR[c]
			local o
			if dir == 1 then
				if (c - 1) % n < n - 1 then o = c + 1 end
			elseif dir == -1 then
				if (c - 1) % n > 0 then o = c - 1 end
			elseif dir == n then
				if c + n <= n * n then o = c + n end
			elseif c - n >= 1 then
				o = c - n
			end
			if o and blk[o] == BODY then
				local od = fillD[o]
				if od == nil then
					fillN = fillN + 1
					fillQ[fillN] = o
					fillS[o], fillD[o], fillV[o], fillR[o] = fillS[c], d + 1, fillV[c], dir
					local i = (o - 1) % n
					local j = (o - 1 - i) / n
					if i < fi0 then fi0 = i elseif i > fi1 then fi1 = i end
					if j < fj0 then fj0 = j elseif j > fj1 then fj1 = j end
				elseif od == d + 1 and fillV[c] > fillV[o] then
					fillS[o], fillV[o], fillR[o] = fillS[c], fillV[c], dir
				end
			end
		end
		q = q + 1
	end
	local nx2, ny2 = fi1 - fi0 + 1, fj1 - fj0 + 1
	if nx2 * 2 + GM * 2 + 4 > PT or ny2 * 2 + GM * 2 + 4 > PT then return x0, y0, nx, ny end
	return fi0, fj0, nx2, ny2
end

-- The patch: every cell of the wet rectangle and a ring around it. Returns its size in cells,
-- whether any cell mirrors, whether all of them do fully, whether any is cracked, and whether
-- what is shown is still catching up with the liquid (the pool is to be painted again soon).
local function BuildPatch(p, g, t, now)
	local lk, pal = p.look, PC.palette
	local n = g.n
	local x0, y0 = g.bx0 - 1, g.by0 - 1
	local nx, ny = g.bx1 - g.bx0 + 3, g.by1 - g.by0 + 3
	st.g, st.h, st.k, st.s, st.ab, st.td, st.tb = g, g.h, g.k, g.s, g.ab, g.td, g.tb
	st.soakDry = C.Flow.stainDry * C.sv.drying:GetFloat()
	st.invFilm, st.kf, st.now = 1 / g.film, 255 * t, now
	st.view, st.clotT = PCV.view:GetInt(), C.Flow.clotTime * C.sv.drying:GetFloat()
	if st.view == 7 then Label(g) end
	st.crackFrom, st.crackSpan, st.crackMax = PC.sim.crackFrom, PC.sim.crackSpan, PC.sim.crackMax
	local wetPal = lk.smooth and pal.thin or pal.wetFresh
	local an = AN
	an[1], an[2], an[3] = wetPal.rim[1], wetPal.rim[2], wetPal.rim[3]
	an[4], an[5], an[6] = wetPal.body[1], wetPal.body[2], wetPal.body[3]
	an[7], an[8], an[9] = pal.wetDeep[1], pal.wetDeep[2], pal.wetDeep[3]
	an[10], an[11], an[12] = pal.wetAged.rim[1], pal.wetAged.rim[2], pal.wetAged.rim[3]
	an[13], an[14], an[15] = pal.wetAged.body[1], pal.wetAged.body[2], pal.wetAged.body[3]
	an[16], an[17], an[18] = pal.dryThin[1], pal.dryThin[2], pal.dryThin[3]
	an[19], an[20], an[21] = pal.dryBody[1], pal.dryBody[2], pal.dryBody[3]
	an[22], an[23], an[24] = pal.dryDeep[1], pal.dryDeep[2], pal.dryDeep[3]
	an[25], an[26], an[27] = pal.dryOld.body[1] - pal.dryFresh.body[1], pal.dryOld.body[2] - pal.dryFresh.body[2], pal.dryOld.body[3] - pal.dryFresh.body[3]
	-- (phase 23, C.P23.tone: the wet thin film's and body's colours lifted; before the colour of an empty
	-- cell is taken from the thin film's, below)
	local K23 = C.P23
	local tone23 = K23 ~= nil and C.P23On ~= nil and C.P23On("tone")
	local lift23 = tone23 and (K23.lift or 1) or 1
	if lift23 ~= 1 then
		for i = 1, 6 do an[i] = min(an[i] * lift23, 255) end
	end
	-- a cell that holds nothing takes the colour of a thin film in the pool's state: the
	-- outline lies between it and its neighbour, and must not shade toward anything else
	local m = sqrt(min(max(p.wet, 0), 1))
	local er, eg, eb = floor(an[16] + (an[1] - an[16]) * m), floor(an[17] + (an[2] - an[17]) * m), floor(an[18] + (an[3] - an[18]) * m)
	if st.view ~= 0 then er, eg, eb = 128, 128, 128 end
	st.er, st.eg, st.eb = er, eg, eb
	local blk, h, k, s, ab = g.blk, g.h, g.k, g.s, g.ab
	-- (phase 19: the wet layer's colour by its depth in units (Cell); the blood beside a lying body
	-- shown under its outline (BodyFill). The patch's corner, in cells, is st.x0, st.y0:
	-- the wet rectangle's ring, unless the patch has grown toward a body)
	local KV = C.V19
	st.depthC = V19("poolDepthColour")
	if st.depthC then
		local ds = KV.poolDeepScale or 0.08
		st.invDeep = 1 / (ds > 1e-4 and ds or 0.08)
	end
	-- (phase 22, C.P22.depthTone: Cell)
	local K22 = C.P22
	st.toneD = (K22 and C.P22On and C.P22On("depthTone")) and math.max(K22.toneDeep or 1.35, 0.1) or nil
	if st.toneD then
		-- (phase 23, C.P23.tone: its own stops and deep colour)
		local K = tone23 and K23 or K22
		st.toneD = math.max(K.toneDeep or 1.35, 0.1)
		st.toneT = K.toneThin or 0.35
		st.toneB = math.Clamp(K.toneBody or 0.85, st.toneT + 0.02, st.toneD - 0.02)
		local dc = K.deepColour or pal.wetDeep
		st.deepR, st.deepG, st.deepB = min(dc[1] * lift23, 255), min(dc[2] * lift23, 255), min(dc[3] * lift23, 255)
	end
	local fill, shade = 0, 1
	if (g.bodyN or 0) > 0 and V19("poolBodyFill") then
		fill = floor(KV.poolBodyFill or 0)
		if fill > 8 then fill = 8 end
		shade = min(max(KV.poolFillShade or 0.75, 0), 1)
		if st.view ~= 0 then shade = 1 end
		if fill > 0 then x0, y0, nx, ny = BodyFill(g, x0, y0, nx, ny, fill) end
	end
	st.x0, st.y0 = x0, y0
	if st.toneD then SmoothFull(g, x0, y0, nx, ny) end
	local invFilm = st.invFilm
	local lean = 255 * t * 0.6
	local pr, pg, pb, pa, pw, pc = pt.r, pt.g, pt.b, pt.a, pt.w, pt.c
	local anyWet, allWet, anyCrack = false, true, false
	-- how far what is shown catches up in this paint (all of the way for a pool that is shown
	-- for the first time long after it formed)
	local dv, snap = Cover(g, p, now)
	if snap and p.born and now - p.born < 1.5 then snap = false end
	local dtp = now - (g.dvT or now)
	g.dvT = now
	local tau, tauMax, tauB = PC.sim.ease * (g.a / 0.4) ^ 0.7, PC.sim.easeMax, PC.sim.easeBirth
	local newborn = p.born ~= nil and now - p.born < 1.5
	local seen, pace = g.dvS, g.dvR
	local film = g.film
	-- (how much of the layer beside it a cell at the edge must hold to count as covered: half
	-- on the finest cells, where a cell is no wider than the meniscus; all of it on coarse ones)
	local covK = g.a < 0.41 and 2 or 1
	if dtp < 0 then dtp = 0 end
	local easing = false
	local q = 0
	for row = 0, ny - 1 do
		local j = y0 + row
		local inJ = j >= 0 and j < n
		for col = 0, nx - 1 do
			local i = x0 + col
			q = q + 1
			local r, gc, b, f, gl, cr
			local bulge = 0
			if inJ and i >= 0 and i < n then
				local c = j * n + i + 1
				if blk[c] == 0 then
					local x
					r, gc, b, f, gl, cr, x = Cell(c)
					if r then
						local d = dv[c]
						if d < 1 then
							-- not shown in full yet. Is it at the pool's edge, and what stands beside it?
							local edge, xn, told, dn = Beside(c, i, j, now)
							local cov = 1
							if edge and x < 1 then
								-- less than a film at the edge: the cell is covered as far as it is as full
								-- as the blood beside it (a thin sheet on a slope covers its cells)
								local xr = xn * invFilm
								if xr > 1 then xr = 1 elseif xr < 0.3 then xr = 0.3 end
								cov = x / xr * covK
								if cov > 1 then cov = 1 end
							end
							local rate = pace[c]
							if rate == 0 then
								if seen[c] == 0 then
									-- first seen: it fills in over as long as the edge took to come through
									-- the cell beside it (blood that landed here: over the time of a new pool)
									seen[c] = now
									-- (where blood lands on a dry floor, with nothing shown beside it and
									-- no more blood on any side: it starts just short of showing)
									if told >= now and dn <= 0 and x * film >= xn * 0.999 and not snap then
										d = 0.4
										dv[c] = d
									end
									local tc = told < now and (now - told) * 0.8 or tauB
									if tc < tau then tc = tau elseif tc > tauMax then tc = tauMax end
									if newborn and tc < tauB then tc = tauB end
									rate = 1 / tc
								else
									rate = 1 / tau
								end
								pace[c] = rate
							end
							if cov > d then
								local step = dtp * rate
								if d < 0.45 and dn < 0.45 and x * film < xn * 0.999 then
									-- (nothing beside it is shown yet and it is not where the blood stands
									-- highest: it waits for the cell the blood came from)
									step = step * 0.25
								elseif not edge and not newborn then
									-- (the edge has left the cell behind: it catches up, at twice its pace)
									step = step * 2
									if step < dtp * 1.6 then step = dtp * 1.6 end
								end
								if snap or cov - d <= step then
									d = cov
								else
									d = d + step
									easing = true
								end
								dv[c] = d
							end
							if d < 1 then
								f = f * d * sqrt(d)
								-- (the meniscus that leaned over the cell before the blood crossed is still there)
								local ln = lean * Lean(c, i, j)
								if ln > f then f = ln end
							end
						end
					else
						-- a dry cell beside wet blood: the meniscus leans out over it as the head
						-- beside it nears what the cell holds back (and goes back as the blood dries)
						if seen[c] ~= 0 then dv[c], seen[c], pace[c] = 0, 0, 0 end
						bulge = Lean(c, i, j)
					end
				elseif fill > 0 and blk[c] == BODY then
					-- (phase 19, poolBodyFill) a body's cell shows the blood beside the body, up to fill
					-- cells in, a shade darker (BodyFill)
					local src = fillS[c]
					if src then
						r, gc, b, f, gl = Cell(src)
						if r then
							cr = 0
							local d = dv[src]
							if d < 1 then f = f * d * sqrt(d) end
							r, gc, b = r * shade, gc * shade, b * shade
						end
					end
				else
					-- a closed cell shows what stands against it (the clip line cuts it straight). Only a
					-- cell that holds what Cell calls blood: one with a trace below that has no colour,
					-- and the paint of the whole pool failed on it, every time it was tried.
					local best, bv = nil, 1e-6
					if i > 0 and blk[c - 1] == 0 then
						local v = h[c - 1] + k[c - 1] + s[c - 1] + ab[c - 1]
						if v > bv then best, bv = c - 1, v end
					end
					if i < n - 1 and blk[c + 1] == 0 then
						local v = h[c + 1] + k[c + 1] + s[c + 1] + ab[c + 1]
						if v > bv then best, bv = c + 1, v end
					end
					if j > 0 and blk[c - n] == 0 then
						local v = h[c - n] + k[c - n] + s[c - n] + ab[c - n]
						if v > bv then best, bv = c - n, v end
					end
					if j < n - 1 and blk[c + n] == 0 then
						local v = h[c + n] + k[c + n] + s[c + n] + ab[c + n]
						if v > bv then best, bv = c + n, v end
					end
					if best then
						r, gc, b, f, gl = Cell(best)
						cr = 0
						local d = dv[best]
						if d < 1 then f = f * d * sqrt(d) end
					end
				end
			end
			if r then
				pr[q], pg[q], pb[q], pa[q], pw[q], pc[q] = floor(r + 0.5), floor(gc + 0.5), floor(b + 0.5), floor(f + 0.5), floor(gl), cr
				if gl > 12 then anyWet = true end
				if gl < 250 then allWet = false end
				if cr > 0.02 then anyCrack = true end
			elseif bulge > 0 then
				pr[q], pg[q], pb[q], pa[q], pw[q], pc[q] = er, eg, eb, floor(lean * bulge), 255, 0
			else
				pr[q], pg[q], pb[q], pa[q], pw[q], pc[q] = er, eg, eb, 0, 0, 0
			end
		end
	end
	return nx, ny, anyWet, allWet, anyCrack, easing
end

-- Developer: the patch of a lattice without a pool around it (half the potential as bytes, row by
-- row; see H.poollab in cl_selftest.lua).
function PCV.DevPatch(g, t)
	local nx, ny = BuildPatch({ look = { smooth = false }, wet = 1 }, g, t, 0)
	return nx, ny, pt.a
end

-- The patch as strips: one vertex a cell at (X + (col - 0.5) sx, Y + (row - 0.5) sy).
-- what: 1 colour and half the potential, 2 the gloss (alpha only), 3 the crack strength (alpha;
-- with the crack mask's texture coordinates, laid in the world).
local function PatchStrips(nx, ny, X, Y, sx, sy, what, uvf)
	local pr, pg, pb, pa, pw, pc = pt.r, pt.g, pt.b, pt.a, pt.w, pt.c
	for row = 0, ny - 2 do
		local q0 = row * nx
		local py = Y + (row + 0.5) * sy
		mesh.Begin(MATERIAL_TRIANGLE_STRIP, nx * 2 - 2)
		for col = 1, nx do
			local px = X + (col - 0.5) * sx
			for half = 0, 1 do
				local q = q0 + col + half * nx
				local y = py + half * sy
				pv:SetUnpacked(px, y, 0)
				mesh.Position(pv)
				if what == 1 then
					mesh.Color(pr[q], pg[q], pb[q], pa[q])
				elseif what == 2 then
					mesh.Color(255, 255, 255, pw[q])
				else
					mesh.TexCoord(0, uvf(px, y))
					mesh.Color(255, 255, 255, A8(pc[q]))
				end
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
	end
end

-- The meniscus. A pool's free surface is level, and at its edge it comes down to the floor over
-- a millimetre or two. Seen from one side, the level part mirrors little (Fresnel, by the view's
-- angle). The slope at the far edge faces away from the viewer: light from low behind the pool
-- meets it at a glancing angle and nearly all of it is mirrored, whatever the view's angle. The
-- slope at the near edge faces the viewer and mirrors next to nothing. That is what makes a
-- liquid's edge a liquid's: a thin light line along the far side, a dark one along the near
-- side, and neither on the sides between.
-- The slopes are found without a height map: the outline's field, as a soft step across the
-- edge, is compared with itself a little further from the viewer (where the step is higher
-- here than there the layer falls away from the viewer, and the other way round), times the
-- mirror's mask (page B: where the layer is wet). Slope leaves that in the slope target.
--   inward: the mask is read a few texels toward the viewer, which at the far edge is inside
--   the pool. Page B is laid by full paints only: at a front that is moving it ends a frame
--   or three behind the outline, and read at the place itself it kept the far line off the
--   newest strip of the pool until the next full paint (a line that moved in jerks).
local function Slope(p, slot, t, far, inward, du, dv)
	local S = slot.size
	local E = min(S, SCR / 2)
	local PB = PCV.page / 2
	local bx, by, bw = slot.x / 2, slot.y / 2, S / 2
	local k = S / (2 * p.canvas.H)
	local px = math.Clamp(PC.sim.rimReach * k, 1.5, 8)
	local sh = px / SCR
	-- (the way along which the slope is read: the viewer's across the pool, or du, dv: phase 22, SunRim)
	du, dv = du or p.vdu, dv or p.vdv
	local su, sv = du * sh, dv * sh
	local e = S / SCR
	local o1, o2 = far and 0 or 1, far and 1 or 0
	Push(ramp)
	Ramp(S, t, 4)
	Pop()
	Push(embRT)
	Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, 0, 0, E, E, 255, 255, 255, 0)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
	Quad(matRamp, 0, 0, E, E, 255, 255, 255, 255, su * o1, sv * o1, e + su * o1, e + sv * o1)
	render.OverrideBlend(true, B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, BLENDFUNC_REVERSE_SUBTRACT)
	Quad(matRamp, 0, 0, E, E, 255, 255, 255, 255, su * o2, sv * o2, e + su * o2, e + sv * o2)
	Blend(B_ZERO, B_ONE, F_ADD, B_ZERO, B_SA, F_ADD)
	local mu, mv = 0, 0
	if inward then mu, mv = -du * px * 1.5 / PB, -dv * px * 1.5 / PB end
	Quad(matPageB, 0, 0, E, E, 255, 255, 255, 255, bx / PB + mu, by / PB + mv, (bx + bw) / PB + mu, (by + bw) / PB + mv)
	Pop()
	return E / (SCR / 2)
end

-- The near slope, into the mirror's mask (page B's alpha: how much of the mirror each place
-- shows; full paints): it mirrors nearly nothing.
local function Rim(p, slot, t)
	local c = PC.sim.rimShade
	if not p.vdu or c <= 0 then return end
	local S = slot.size
	local bx, by, bw = slot.x / 2, slot.y / 2, S / 2
	local uv = Slope(p, slot, t, false)
	Push(pageB)
	render.SetScissorRect(bx, by, bx + bw, by + bw, true)
	render.OverrideBlend(true, B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, BLENDFUNC_REVERSE_SUBTRACT)
	Quad(matEmb, bx, by, bw, bw, 255, 255, 255, A8(c), 0, 0, uv, uv)
	render.SetScissorRect(0, 0, 0, 0, false)
	Pop()
end

-- The far slope's light (into page A's colour, which every paint lays anew, so the line moves
-- with the outline frame by frame): what the slope mirrors at its glancing angle does not go
-- by the view's angle on the level, so it is not in the mirror's pass. A thin line of the
-- light at that place, a little cool, where the layer is wet.
local function RimGlow(p, slot, t)
	-- (phase 23, C.P23.meniscus: restrained)
	local c = (C.P23On ~= nil and C.P23On("meniscus") and C.P23.rimGlow) or PC.sim.rimGlow
	if not p.vdu or c <= 0 then return end
	local S = slot.size
	local uv = Slope(p, slot, t, true, true)
	Push(pageA)
	render.SetScissorRect(slot.x, slot.y, slot.x + S, slot.y + S, true)
	Blend(B_SA, B_ONE, F_ADD, B_ZERO, B_ONE, F_ADD)
	Quad(matEmb, slot.x, slot.y, S, S, A8(c * 0.9), A8(c * 0.95), A8(c), 255, 0, 0, uv, uv)
	render.SetScissorRect(0, 0, 0, 0, false)
	Pop()
end

-- (phase 22, C.P22.sunRimBreak) Where along the edge the meniscus shows the sun, into the slope
-- target's colour (the line is drawn as its colour times its alpha). The contact line on a rough floor
-- is pinned grain by grain: its way turns back and forth by tens of degrees over a few millimetres,
-- finer than the lattice draws it, and the sun stands in the meniscus only where it turns to face it.
-- Short lights along the edge, not one line (the user's reference: its sunlit edge is lit in broken
-- streaks). The tiled noise's alpha (its colour is near white) laid in the world at sunRimWorld units a
-- tile, less sunRimBreak, times eight: dark below it, full an eighth above. (First a value per cell of
-- the lattice: a sunlit edge a few cells long stayed one line, run p22_g.) The noise is fixed to the
-- pool as its edge noise is (p.look).
local function SunRimBreak(p, S, E)
	local cv, lk = p.canvas, p.look
	local k = S / (2 * cv.H)
	local ox, oy = cv.cu - cv.H, cv.cv - cv.H
	local sc = 1 / max(C.P22.sunRimWorld or 5, 0.5)
	local cr, sr = cos(lk.noiseRot + 0.7), sin(lk.noiseRot + 0.7)
	local u0, v0, u1, v1 = ox, oy, ox + S / k, oy + S / k
	Push(embRT)
	Blend(B_SA, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	render.SetMaterial(matNoise)
	mesh.Begin(MATERIAL_QUADS, 1)
	V(0, 0, (u0 * cr - v0 * sr) * sc + lk.noiseV, (u0 * sr + v0 * cr) * sc + lk.noiseU, 255, 255, 255, 255)
	V(E, 0, (u1 * cr - v0 * sr) * sc + lk.noiseV, (u1 * sr + v0 * cr) * sc + lk.noiseU, 255, 255, 255, 255)
	V(E, E, (u1 * cr - v1 * sr) * sc + lk.noiseV, (u1 * sr + v1 * cr) * sc + lk.noiseU, 255, 255, 255, 255)
	V(0, E, (u0 * cr - v1 * sr) * sc + lk.noiseV, (u0 * sr + v1 * cr) * sc + lk.noiseU, 255, 255, 255, 255)
	mesh.End()
	local lo = A8(C.P22.sunRimBreak or 0)
	render.OverrideBlend(true, B_ONE, B_ONE, BLENDFUNC_REVERSE_SUBTRACT, B_ZERO, B_ONE, F_ADD)
	Quad(matWhite, 0, 0, E, E, lo, lo, lo, 255)
	Blend(B_DC, B_ONE, F_ADD, B_ZERO, B_ONE, F_ADD)
	for _ = 1, 3 do Quad(matWhite, 0, 0, E, E, 255, 255, 255, 255) end
	Pop()
end

-- (phase 22, C.P22.sunRim) The sun mirrored in the meniscus: the part of the curved edge whose slope
-- faces the half-way direction between the sun and the eye (p.sunU, p.sunV across the pool, p.sunK
-- how much: cl_pools.lua) shows the sun, a thin warm line, into page A's colour as the far slope's
-- light is (RimGlow), broken along the edge where the contact line turns away (SunRimBreak). Where
-- the half-way direction stands upright the level surface mirrors the sun instead (cl_pools.lua,
-- Glint), and no slope is lit here.
local function SunRim(p, slot, t)
	local c = p.sunK or 0
	if c <= 0.01 or not p.sunU then return end
	local S = slot.size
	local uv = Slope(p, slot, t, true, true, p.sunU, p.sunV)
	-- (only the stretch of the edge that faces the half-way direction closely: the slope's band answers
	-- every part of the edge by how squarely it faces that way, a third of the outline lit in one line.
	-- The band is at most px / w where it faces that way squarely: px the shift it is read over, w the
	-- width over which its ramp (gain 4) rises, about 0.375 of a cell on the canvas (the potential falls
	-- by one over about a cell and a half). Less sunRimCut of that, scaled back to 1: from a part that
	-- faces within about 35 degrees, tapering to nothing at its ends, as the sun's glint along a meniscus
	-- is. A cut of 0.8 of 1, as first, let nothing through at all: the band's peak is 0.6 on the finest
	-- cells and less on coarser ones, run p22_sun)
	local frac = math.Clamp(C.P22.sunRimCut or 0.8, 0, 0.95)
	if frac > 0 then
		local k = S / (2 * p.canvas.H)
		local px = math.Clamp(PC.sim.rimReach * k, 1.5, 8)
		local peak = math.Clamp(px / max(0.375 * p.sim.a * k, 0.1), 0.05, 1)
		local cut = frac * peak
		local E = min(S, SCR / 2)
		Push(embRT)
		render.OverrideBlend(true, B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, BLENDFUNC_REVERSE_SUBTRACT)
		Quad(matWhite, 0, 0, E, E, 255, 255, 255, A8(cut))
		Blend(B_ZERO, B_ONE, F_ADD, B_DA, B_ONE, F_ADD)
		local scale = min(1 / max(peak - cut, 0.01), 16)
		while scale >= 1.999 do
			Quad(matWhite, 0, 0, E, E, 255, 255, 255, 255)
			scale = scale * 0.5
		end
		if scale > 1.004 then Quad(matWhite, 0, 0, E, E, 255, 255, 255, A8(scale - 1)) end
		Pop()
	end
	-- (phase 23, C.P23.meniscus: a faint line is not broken by the noise)
	if (C.P22.sunRimBreak or 0) > 0 and not (C.P23On ~= nil and C.P23On("meniscus")) then SunRimBreak(p, S, min(S, SCR / 2)) end
	Push(pageA)
	render.SetScissorRect(slot.x, slot.y, slot.x + S, slot.y + S, true)
	Blend(B_SA, B_ONE, F_ADD, B_ZERO, B_ONE, F_ADD)
	Quad(matEmb, slot.x, slot.y, S, S, A8(c), A8(c * 0.97), A8(c * 0.9), 255, 0, 0, uv, uv)
	render.SetScissorRect(0, 0, 0, 0, false)
	Pop()
end

-- The potential's taps: the patch drawn 25 times, at every half cell from one cell before the
-- point to one cell after it, both ways, weighted 1 2 2 2 1 each way. A lattice says which cells
-- hold blood, not where in a cell the edge lies: an edge that runs with the lattice comes out
-- as a wave of one cell's length, one that runs askew as a stair of two or three cells a step.
-- This kernel lets nothing through of waves one and two cells long and three eighths of those
-- three cells long: what is left is the pool's own shape, as surface tension leaves it. (Four
-- taps 0.4 of a cell out, as until phase 34, kept four fifths of the first and a third of the
-- second: knobs and stairs a cell wide all round every pool.) A streak one cell wide keeps
-- half its potential and still stands where it is a film deep.
--   wt: the taps' weight together, in 64ths; unit: a cell in texture coordinates
local TW = { 1, 2, 2, 2, 1 }
local function Taps(mat, x, y, w, h, wt, unit, u0, v0, u1, v1)
	render.SetMaterial(mat)
	local left = 4 * wt
	mesh.Begin(MATERIAL_QUADS, 25)
	for jj = 1, 5 do
		local dv = (jj - 3) * 0.5 * unit
		for ii = 1, 5 do
			if ii ~= 3 or jj ~= 3 then
				local du = (ii - 3) * 0.5 * unit
				local al = floor(TW[ii] * TW[jj] * wt * 0.0625 + 0.5)
				left = left - al
				V(x, y, u0 + du, v0 + dv, 255, 255, 255, al)
				V(x + w, y, u1 + du, v0 + dv, 255, 255, 255, al)
				V(x + w, y + h, u1 + du, v1 + dv, 255, 255, 255, al)
				V(x, y + h, u0 + du, v1 + dv, 255, 255, 255, al)
			end
		end
	end
	-- (the middle one takes what rounding has left: the sum is exact)
	if left < 0 then left = 0 end
	V(x, y, u0, v0, 255, 255, 255, left)
	V(x + w, y, u1, v0, 255, 255, 255, left)
	V(x + w, y + h, u1, v1, 255, 255, 255, left)
	V(x, y + h, u0, v1, 255, 255, 255, left)
	mesh.End()
end

local function PaintSim(p, slot)
	local g = p.sim
	local S = slot.size
	local cv, lk = p.canvas, p.look
	local k = S / (2 * cv.H)
	local ox, oy = cv.cu - cv.H, cv.cv - cv.H
	local t = 0.5 + lk.amp * 0.5
	local ax, ay = slot.x, slot.y
	local bx, by, bw = slot.x / 2, slot.y / 2, S / 2
	local PB = PCV.page / 2
	local a = g.a
	local gain = math.Clamp(0.25 * a / PC.sim.rim, 0.75, 16)
	local view = PCV.view:GetInt()
	Writes(true, true)

	-- 1. the patch, in its own small target
	local empty = g.bx1 < g.bx0
	-- (a light paint: the outline and the colours only; page B keeps what the last full paint
	-- left in it. cl_pools.lua, P.Paint)
	local light = p.lightNext == true and not empty and bit.band(PCV.debug:GetInt(), 32) == 0
	local nx, ny, anyWet, allWet, anyCrack = 0, 0, false, false, false
	local ps, W, Hh, s, X0, Y0, u0, v0, u1, v1
	-- (the patch's first cell: the wet rectangle's ring, or further out toward a lying body: BuildPatch)
	local px0, py0 = g.bx0 - 1, g.by0 - 1
	p.easing = false
	if not empty then
		nx, ny, anyWet, allWet, anyCrack, p.easing = BuildPatch(p, g, t, CurTime())
		p.bgR, p.bgG, p.bgB = st.er, st.eg, st.eb
		px0, py0 = st.x0, st.y0
		-- (two texels a cell whatever the slot's size, as long as the patch has room: with one for
		-- small slots the potential between the cells was laid differently, and when a growing
		-- pool went over to a larger slot its whole outline moved a little in one frame)
		ps = 2
		if nx * ps + GM * 2 + 4 > PT or ny * ps + GM * 2 + 4 > PT then ps = 1 end
		W, Hh = nx * ps + GM * 2, ny * ps + GM * 2
		s = a * k / ps                               -- canvas pixels a patch texel
		X0, Y0 = ((g.i0 + px0) * a - ox) * k - GM * s, ((g.j0 + py0) * a - oy) * k - GM * s
		u0, v0, u1, v1 = 2 / PT, 2 / PT, (2 + W) / PT, (2 + Hh) / PT
		Push(patchRT)
		Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
		Quad(matWhite, 0, 0, W + 8, Hh + 8, st.er, st.eg, st.eb, 0)   -- (the taps reach two texels past the patch)
		render.SetMaterial(matWhite)
		PatchStrips(nx, ny, 2 + GM, 2 + GM, ps, ps, 1)
		Pop()
	end

	-- 2. field: the potential (Taps, then doubled: the patch carries half of it), spatter
	--    stamps, mottling, edge noise, clips
	-- (while the outline is turning from what the pool showed before its lattice changed: so
	-- much of the new potential, the rest of the old)
	local m, wNew = p.morph, 64
	if m then
		local w = (RealTime() - m.t0) / (PC.sim.morph / game.GetTimeScale())
		if w >= 1 or PCV.morphOwner ~= p then
			p.morph, m = nil, nil
			if PCV.morphOwner == p then PCV.morphOwner = nil end
		else
			wNew = floor(64 * w * w * (3 - 2 * w) + 0.5)
			p.easing = true
		end
	end
	Push(field)
	Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, 0, 0, S, S, 255, 255, 255, 0)
	if not empty then
		Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
		Taps(matPatch, X0, Y0, W * s, Hh * s, wNew, ps / PT, u0, v0, u1, v1)
	end
	if m then
		Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
		local OB = SCR / 2
		for _, it in ipairs(m.items) do
			local so = it.a * k / it.ps
			local Xo, Yo = (it.u - ox) * k - GM * so, (it.v - oy) * k - GM * so
			local a0, b0, a1, b1 = (it.rx + 1) / OB, (it.ry + 1) / OB, (it.rx + 1 + it.W) / OB, (it.ry + 1 + it.H) / OB
			Taps(matOldB, Xo, Yo, it.W * so, it.H * so, 64 - wNew, it.ps / OB, a0, b0, a1, b1)
		end
	end
	if not empty or m then
		Blend(B_ZERO, B_ONE, F_ADD, B_DA, B_ONE, F_ADD)
		Quad(matWhite, 0, 0, S, S, 255, 255, 255, 255)
	end
	if #p.blobs > 0 then
		Blend(B_DC, B_ZERO, F_ADD, B_ONE, B_ONE, F_ADD)
		render.SetMaterial(matAtlas)
		mesh.Begin(MATERIAL_QUADS, #p.blobs)
		for _, b in ipairs(p.blobs) do Stamp(b, ox, oy, k) end
		mesh.End()
	end
	Blend(B_DC, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	NoiseQuad(S, ox, oy, k, lk, 255, 255, 255, 255)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
	NoiseQuad(S, ox, oy, k, lk, 255, 255, 255, A8(lk.amp))
	Clips(p.clips, S, ox, oy, k)
	Pop()

	-- 3. page A's colour: the cells' colours, a shade darker in the rim band where the pool has
	--    dried (the drying ring), then the mottling and the cracks
	Push(ramp)
	Ramp(S, t, gain)
	Pop()
	Push(pageA)
	render.SetScissorRect(ax, ay, ax + S, ay + S, true)
	Blend(B_ONE, B_ZERO, F_ADD, B_ZERO, B_ONE, F_ADD)
	Quad(matWhite, ax, ay, S, S, st.er or 90, st.eg or 20, st.eb or 20, 255)
	if not empty then
		local dry = view == 0 and min(max((1 - p.wet) * 1.5, 0), 1) or 0
		local pal = PC.palette
		local rim, body = pal.dryFresh.rim, pal.dryFresh.body
		Quad(matPatch, ax + X0, ay + Y0, W * s, Hh * s, floor(255 - 255 * (1 - rim[1] / body[1]) * dry),
			floor(255 - 255 * (1 - rim[2] / body[2]) * dry), floor(255 - 255 * (1 - rim[3] / body[3]) * dry), 255, u0, v0, u1, v1)
	end
	CopyAlpha(matRamp, ax, ay, S, S)
	if not empty then
		Blend(B_DA, B_ODA, F_ADD, B_ZERO, B_ONE, F_ADD)
		Quad(matPatch, ax + X0, ay + Y0, W * s, Hh * s, 255, 255, 255, 255, u0, v0, u1, v1)
	end
	if view == 0 then MultiplyDetail(ax, ay, S, S) end
	render.SetScissorRect(0, 0, 0, 0, false)
	Pop()

	-- 3b. page C: what the layer lets through (every paint: it follows the outline)
	-- (no closure here: a paint allocates nothing, so that the collector never runs inside one)
	if empty then
		FilterPage(S, t, bx, by, bw)
	else
		FilterPage(S, t, bx, by, bw, matPatchT, bx + X0 * 0.5, by + Y0 * 0.5, W * s * 0.5, Hh * s * 0.5, u0, v0, u1, v1)
	end

	-- 4. page B: what is still wet mirrors, right up to the outline, the better the deeper it
	--    stands, less where the blood has set and not at all where it has dried
	if not light then
		if anyWet then
			Push(ramp)
			Ramp(S, t, 8)
			Pop()
		end
		Push(pageB)
		render.SetScissorRect(bx, by, bx + bw, by + bw, true)
		Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
		Quad(matWhite, bx, by, bw, bw, 0, 0, 0, 0)
		if anyWet then
			CopyAlpha(matRamp, bx, by, bw, S)
			if not allWet then
				Blend(B_ZERO, B_ONE, F_ADD, B_ZERO, B_SA, F_ADD)
				render.SetMaterial(matWhite)
				PatchStrips(nx, ny, bx + ((g.i0 + px0) * a - ox) * k * 0.5, by + ((g.j0 + py0) * a - oy) * k * 0.5, a * k * 0.5, a * k * 0.5, 2)
			end
		end
		render.SetScissorRect(0, 0, 0, 0, false)
		Pop()
		if anyWet then
			-- (the slope at the near edge mirrors nothing: Rim; then the mask as a colour too, for
			-- the sun's glint)
			Rim(p, slot, t)
			Push(pageB)
			render.SetScissorRect(bx, by, bx + bw, by + bw, true)
			MaskedColour(bx, by, bw, WHITE)
			render.SetScissorRect(0, 0, 0, 0, false)
			Pop()
		end
	end

	if anyWet and view == 0 then
		RimGlow(p, slot, t)
		-- (phase 22: the sun in the meniscus, where it is there: cl_pools.lua sets p.sunK only then)
		if p.sunK then SunRim(p, slot, t) end
	end

	-- 5. the outline alpha into page A
	local ae = PCV.alphaEdge
	Push(ramp)
	Ramp(S, t - ae / gain, gain)
	Pop()
	Push(pageA)
	CopyAlpha(matRamp, ax, ay, S, S)
	-- cracks: where a thick layer has been dry for long the crack network opens (the alpha falls
	-- below the outline's threshold along the cracks, so the floor shows; their edges darken)
	if anyCrack then
		local sc = 1 / PC.sim.crackWorld
		local cr, sr = cos(lk.noiseRot + 1.3), sin(lk.noiseRot + 1.3)
		render.SetScissorRect(ax, ay, ax + S, ay + S, true)
		Blend(B_ZERO, B_OSA, F_ADD, B_ZERO, B_OSA, F_ADD)
		render.SetMaterial(matCrackMask)
		PatchStrips(nx, ny, ax + ((g.i0 + px0) * a - ox) * k, ay + ((g.j0 + py0) * a - oy) * k, a * k, a * k, 3, function(px, py)
			local u, v = ox + (px - ax) / k, oy + (py - ay) / k
			return (u * cr - v * sr) * sc + lk.noiseV, (u * sr + v * cr) * sc + lk.noiseU
		end)
		render.SetScissorRect(0, 0, 0, 0, false)
	end
	Pop()
end

-- A pool's outline turns into the next one. When its lattice goes over to coarser cells, or
-- takes another pool's blood in, what the lattice then says is not quite what was on screen a
-- frame before (coarse cells cannot keep a narrow dry gap; the two pools' outlines become one).
-- So before the lattice changes, what the pool shows is kept as it is, cell by cell
-- (PCV.Snapshot: the halves of the potential, as BuildPatch lays them out), and for
-- PC.sim.morph seconds the field of every paint is so much of the new potential and the rest
-- of the old: the outline moves from the one to the other, a narrow join first where the two
-- potentials are lowest.
function PCV.Snapshot(p)
	local g = p.sim
	if not g or g.bx1 < g.bx0 then return nil end
	local t = 0.5 + p.look.amp * 0.5
	local nx, ny = BuildPatch(p, g, t, CurTime())
	local pa, src = {}, pt.a
	for q = 1, nx * ny do pa[q] = src[q] end
	-- (u, v: the corner of the patch's first cell in the pool's frame)
	return { nx = nx, ny = ny, a = g.a, u = (g.i0 + st.x0) * g.a, v = (g.j0 + st.y0) * g.a, t = t, pa = pa }
end

local function SnapStrips(sn, X, Y, ps, kt)
	local nx, ny, pa = sn.nx, sn.ny, sn.pa
	for row = 0, ny - 2 do
		local q0 = row * nx
		local py = Y + (row + 0.5) * ps
		mesh.Begin(MATERIAL_TRIANGLE_STRIP, nx * 2 - 2)
		for col = 1, nx do
			local px = X + (col - 0.5) * ps
			for half = 0, 1 do
				local a = floor(pa[q0 + col + half * nx] * kt + 0.5)
				pv:SetUnpacked(px, py + half * ps, 0)
				mesh.Position(pv)
				mesh.Color(255, 255, 255, a > 255 and 255 or a)
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
	end
end

-- The snapshots (up to four, each with u, v in pool p's frame) become the old patches of pool
-- p. Returns false when another pool's are in use (then the outline does not turn but jumps).
function PCV.MorphBegin(p, snaps)
	if not PCV.ready or #snaps == 0 then return false end
	local own = PCV.morphOwner
	if own and own ~= p and own.morph then return false end
	local t = 0.5 + p.look.amp * 0.5
	local items = {}
	local T = SCR / 4
	local ok, err = pcall(function()
		Writes(true, true)
		Push(oldB)
		Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
		Quad(matWhite, 0, 0, SCR / 2, SCR / 2, 0, 0, 0, 0)
		render.SetMaterial(matWhite)
		for q = 1, min(#snaps, 4) do
			local sn = snaps[q]
			local ps = (sn.nx * 2 + GM * 2 + 2 <= T and sn.ny * 2 + GM * 2 + 2 <= T) and 2 or 1
			local W, Hh = sn.nx * ps + GM * 2, sn.ny * ps + GM * 2
			if W + 2 <= T and Hh + 2 <= T then
				local rx, ry = ((q - 1) % 2) * T, floor((q - 1) / 2) * T
				SnapStrips(sn, rx + 1 + GM, ry + 1 + GM, ps, t / sn.t)
				items[#items + 1] = { u = sn.u, v = sn.v, a = sn.a, ps = ps, W = W, H = Hh, rx = rx, ry = ry }
			end
		end
		Pop()
	end)
	while depth > 0 do Pop() end
	Reset()
	if not ok then
		ABL.Print("pool canvas morph failed: %s", tostring(err))
		return false
	end
	if #items == 0 then return false end
	p.morph = { t0 = RealTime(), items = items }
	PCV.morphOwner = p
	return true
end

-- Paints pool p into `slot` (its current slot, or the one replacing it). Returns ok, ms; render
-- state is restored even when a pass fails.
function PCV.Paint(p, slot)
	if not PCV.ready then return false end
	local t0 = SysTime()
	local ok, err = pcall(p.sim and PaintSim or PaintInner, p, slot)
	while depth > 0 do Pop() end
	render.SetScissorRect(0, 0, 0, 0, false)
	Reset()
	if not ok then
		ABL.Print("pool canvas paint failed: %s", tostring(err))
		return false
	end
	local ms = (SysTime() - t0) * 1000
	PCV.stats.paints = PCV.stats.paints + 1
	PCV.stats.ms = PCV.stats.ms * 0.9 + ms * 0.1
	return true, ms
end

------------------------------------------------------------------------------------------
-- Start-up: float render targets must keep values above 1 through blending (the field of a
-- thick pool sums past 1). If they do not on this machine, fall back to 8-bit targets, where
-- every ramp clamps (the thickest cores then dry a little earlier).
------------------------------------------------------------------------------------------
local function CheckFloat()
	Push(field)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matWhite, 0, 0, 8, 8, 255, 255, 255, 204)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ONE, F_ADD)
	Quad(matWhite, 0, 0, 8, 8, 255, 255, 255, 204)
	Blend(B_ZERO, B_ONE, F_ADD, B_ZERO, B_SA, F_ADD)
	Quad(matWhite, 0, 0, 8, 8, 255, 255, 255, 128)
	Pop()
	Push(pageB)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ZERO, F_ADD)
	Quad(matField, 0, 0, 8, 8, 255, 255, 255, 255, 0, 0, 8 / SCR, 8 / SCR)
	render.CapturePixels()
	local _, _, _, a = render.ReadPixel(4, 4)
	Pop()
	Reset()
	return a, (a or 0) > 180
end

function PCV.Start()
	if PCV.ready then return true end
	PCV.Init()
	local ok, a, float = pcall(CheckFloat)
	while depth > 0 do Pop() end
	Reset()
	if not ok then
		ABL.Print("pool canvas self-check failed: %s", tostring(a))
		float = false
	end
	PCV.float = float and true or false
	if not PCV.float then MakeScratch(false) end
	PCV.checkAlpha = a
	PCV.ready = true
	ABL.Print("pool canvases: page %d, %s field (check %s)", PCV.page, PCV.float and "float" or "8-bit", tostring(a))
	return true
end

-- (phase 19, poolModelLight) Does the pools' unlit material take a $color above 1? A pool's light
-- past 1 comes back through it (cl_pools.lua: BuildMesh makes each vertex its light over the pool's
-- largest, k; P.Draw sets $color k). Two squares of one vertex colour drawn into the patch target
-- (a scratch target every paint lays anew) with $color 1 and 2, and read back: where the second is
-- no brighter, light is kept to 1 as it was (k = 1), not drawn darker by k. Once, from P.Paint
-- (where the canvases are painted), and only while that part is on. PCV.colourOK: the answer.
local matProbe
local probeCol = Vector()
function PCV.ProbeColour()
	if PCV.colourOK ~= nil or not PCV.ready then return PCV.colourOK end
	matProbe = matProbe or Unlit("abl_pc_colprobe", "vgui/white", { ["$ignorez"] = 1 })
	local ok, c1, c2 = pcall(function()
		Push(patchRT)
		Writes(true, true)
		Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
		probeCol:SetUnpacked(1, 1, 1)
		matProbe:SetVector("$color", probeCol)
		Quad(matProbe, 0, 0, 8, 8, 100, 100, 100, 255)
		probeCol:SetUnpacked(2, 2, 2)
		matProbe:SetVector("$color", probeCol)
		Quad(matProbe, 8, 0, 8, 8, 100, 100, 100, 255)
		render.CapturePixels()
		local r1 = render.ReadPixel(4, 4)
		local r2 = render.ReadPixel(12, 4)
		Pop()
		return r1, r2
	end)
	while depth > 0 do Pop() end
	Reset()
	probeCol:SetUnpacked(1, 1, 1)
	matProbe:SetVector("$color", probeCol)
	PCV.colourOK = (ok and isnumber(c1) and isnumber(c2) and c2 > c1 + 4) and true or false
	ABL.Print("pool colour probe: $color 1 draws %s, 2 draws %s: a pool's light past 1 is %s", tostring(c1), tostring(c2), PCV.colourOK and "carried" or "kept to 1")
	return PCV.colourOK
end

------------------------------------------------------------------------------------------
-- Per-draw material setup (texture transforms are per pool: world-scaled detail / reflection)
------------------------------------------------------------------------------------------
local mtx = Matrix()
-- page UV -> tile UV at `world` units per tile, rotated by rot, offset (ou, ov)
function PCV.TileTransform(p, world, rot, ou, ov)
	local slot, cv = p.slot, p.pcanvas or p.canvas
	local page = PCV.page
	local kk = page * 2 * cv.H / (slot.size * world)
	local cr, sr = cos(rot), sin(rot)
	local u0, v0 = slot.x / page, slot.y / page
	mtx:Identity()
	mtx:SetField(1, 1, kk * cr) mtx:SetField(1, 2, -kk * sr)
	mtx:SetField(2, 1, kk * sr) mtx:SetField(2, 2, kk * cr)
	mtx:SetField(1, 4, -(kk * cr * u0 - kk * sr * v0) + ou)
	mtx:SetField(2, 4, -(kk * sr * u0 + kk * cr * v0) + ov)
	return mtx
end

function PCV.Clear()
	if PCV.page then PCV.InitSlots() end
end

-- Developer: what it costs to bring a lattice of N x N values into a render target, as one
-- rectangle a cell (and whether the values arrive as written) and as one strip vertex a cell.
-- Uses the first 64 texels of page B: only while no pool has a slot.
local function BenchInner(N)
	local reps = 5
	Push(pageB)
	Writes(true, true)
	Blend(B_ONE, B_ZERO, F_ADD, B_ONE, B_ZERO, F_ADD)
	local t0 = SysTime()
	for _ = 1, reps do
		for j = 0, N - 1 do
			for i = 0, N - 1 do
				surface.SetDrawColor((i * 8) % 256, (j * 8) % 256, 128, (i * 7 + j * 3) % 256)
				surface.DrawRect(i, j, 1, 1)
			end
		end
	end
	local tRect = (SysTime() - t0) * 1e6 / reps
	render.CapturePixels()
	local got = {}
	for _, q in ipairs({ { 3, 5 }, { 17, 9 }, { 31, 31 }, { 0, 0 }, { 12, 20 } }) do
		local r, g, b, a = render.ReadPixel(q[1], q[2])
		got[#got + 1] = string.format("(%d,%d) wrote %d,%d,128,%d read %s,%s,%s,%s", q[1], q[2], (q[1] * 8) % 256, (q[2] * 8) % 256, (q[1] * 7 + q[2] * 3) % 256, tostring(r), tostring(g), tostring(b), tostring(a))
	end
	Quad(matWhite, 0, 0, N, N, 0, 0, 0, 0)
	Pop()
	Push(ramp)
	Writes(false, true)
	Blend(B_ZERO, B_ONE, F_ADD, B_ONE, B_ZERO, F_ADD)
	render.SetMaterial(matWhite)
	t0 = SysTime()
	for _ = 1, reps do
		for j = 0, N - 2 do
			mesh.Begin(MATERIAL_TRIANGLE_STRIP, N * 2 - 2)
			for i = 0, N - 1 do
				pv:SetUnpacked(i * 2 + 1, j * 2 + 1, 0)
				mesh.Position(pv)
				mesh.Color(255, 255, 255, (i * 7 + j * 3) % 256)
				mesh.AdvanceVertex()
				pv:SetUnpacked(i * 2 + 1, j * 2 + 3, 0)
				mesh.Position(pv)
				mesh.Color(255, 255, 255, (i * 7 + j * 3 + 3) % 256)
				mesh.AdvanceVertex()
			end
			mesh.End()
		end
	end
	local tStrip = (SysTime() - t0) * 1e6 / reps
	Pop()
	Reset()
	return string.format("pool canvas bench %dx%d: rectangles %.0f us (%.2f us a cell), strips %.0f us (%.2f us a cell) | %s",
		N, N, tRect, tRect / (N * N), tStrip, tStrip / (N * N), table.concat(got, "; "))
end

function PCV.Bench(N)
	if not PCV.Start() or PCV.stats.used > 0 then return "pool canvas bench: not now" end
	local ok, res = pcall(BenchInner, N)
	while depth > 0 do Pop() end
	Reset()
	return ok and res or ("pool canvas bench failed: " .. tostring(res))
end

------------------------------------------------------------------------------------------
-- Developer diagnostics
--   abl_pool_debug bits: 1 no reflection, 2 no filter, 4 soft outline only, 8 show page A,
--   16 show page B, 32 every paint a full one (no light paints)
--   (left: rgb x alpha over black, right: alpha as black on white)
------------------------------------------------------------------------------------------
-- Reflection material mirroring a specific cubemap of the map (one per cubemap, created on use).
local envMats = {}
function PCV.EnvMat(path)
	if not path then return PCV.matEnv end
	local m = envMats[path]
	if m then return m end
	m = CreateMaterial("abl_pool_env" .. table.Count(envMats), "UnlitGeneric", {
		["$basetexture"] = pageB:GetName(), ["$additive"] = 1,
		["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
		["$color"] = "[0 0 0]", ["$envmap"] = path, ["$envmaptint"] = "[0.1 0.1 0.1]",
		["$envmapsaturation"] = PC.envSaturation,
	})
	envMats[path] = m
	return m
end

PCV.useEnv = CreateClientConVar("abl_pool_envmap", "1", true, false, "Wet pools mirror the map's cubemap (1) or a generic sheen pattern (0).", 0, 1)
PCV.debug = CreateClientConVar("abl_pool_debug", "0", false, false, "Pool canvas debugging bitmask (1 no reflection, 2 no filter under the colour, 4 soft outline only, 8 show page A, 16 show page B, 32 every paint a full one).", 0, 255)
PCV.view = CreateClientConVar("abl_pool_view", "0", false, false, "What liquid pools show: 0 blood, 1 layer depth, 2 speed, 3 state (liquid / set / dried / absorbed), 4 age of the liquid, 5 pinning of the floor, 6 lattice cells, 7 connected regions.", 0, 7)

local function Panel(mat, x, y, s)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(x, y, s, s)
	surface.SetMaterial(mat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRect(x, y, s, s)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawRect(x + s + 8, y, s, s)
	surface.SetMaterial(mat)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawTexturedRect(x + s + 8, y, s, s)
end

hook.Add("HUDPaint", "ABL_PoolCanvasDebug", function()
	if not PCV.ready then return end
	local d = PCV.debug:GetInt()
	if bit.band(d, 8) ~= 0 then Panel(PCV.viewA, 10, 10, 512) end
	if bit.band(d, 16) ~= 0 then Panel(PCV.viewB, 10, 530, 512) end
end)

-- Reads back page A / page B texels at a slot's centre and around it (rgba 0..255).
function PCV.Readback(slot)
	if not PCV.ready or not slot then return "" end
	local out = {}
	local S = slot.size
	local pts = { { 0.5, 0.5 }, { 0.35, 0.5 }, { 0.65, 0.5 }, { 0.5, 0.3 }, { 0.5, 0.7 }, { 0.2, 0.2 } }
	render.PushRenderTarget(pageA)
	render.CapturePixels()
	for _, q in ipairs(pts) do
		local r, g, b, a = render.ReadPixel(floor(slot.x + S * q[1]), floor(slot.y + S * q[2]))
		out[#out + 1] = string.format("A(%.2f,%.2f)=%d,%d,%d,%s", q[1], q[2], r or -1, g or -1, b or -1, tostring(a))
	end
	render.PopRenderTarget()
	render.PushRenderTarget(pageB)
	render.CapturePixels()
	local r, g, b, a = render.ReadPixel(floor((slot.x + S * 0.5) / 2), floor((slot.y + S * 0.5) / 2))
	out[#out + 1] = string.format("B(c)=%d,%d,%d,%s", r or -1, g or -1, b or -1, tostring(a))
	render.PopRenderTarget()
	return table.concat(out, " ")
end
