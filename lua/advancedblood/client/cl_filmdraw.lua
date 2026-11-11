-- Film drawing: a body's blood film (cl_film.lua), painted into canvases and drawn by the body's
-- own model.
-- A canvas is two small render targets with the layout of one material's grid of cells
-- (cl_filmchart.lua), one texel a cell:
--   A  the blood's own colour and, in alpha, two outlines: where the alpha read between texels is
--      T1 the film ends, and where it is T2 the liquid that stands on it ends. A material cuts at
--      one of them per screen pixel, so each outline is one smooth line between the cells at any
--      magnification.
--   B  the liquid's surface: which way it faces from place to place (a normal map made of how deep
--      the blood stands, of the streaks its flow has drawn and of the waves that run down it), and
--      in alpha how much it shines.
-- (Phase 19, C.V19 and abl_liquid_v19: with split a third target, L, holds the liquid's outline in
-- its own alpha and A only the film's, each cut at a half; with b2 the materials read B from B2, a
-- picture of twice its size made from it as A2 is from A; with lerp the films nearest the eye move
-- from one painting to the next in every frame, on the graphics card. Below, D.Finer to LerpPass.
-- In the painter: the liquid's surface made from its depth with a low rim where it ends (surface:
-- Look's vH and vt, PaintMap, Encode, which the waves write B by too), colour, shine and surface
-- coming as the outline does (ease: EaseStep), the colour by the liquid's own depth (depthTone), the
-- film thinning out at its outline (feather: Edge, Feather), waves carried by the liquid (WaveTb) and
-- the film swollen where blood waits to drop (pendPaint: Pend). In the materials: no relief under the
-- stain that the cloth does not have (clothRelief: Real, D.Dress).)
-- What a texel holds is not its cell's state alone but that of the cells round it too, weighted, and
-- it comes to that over a moment (PaintMap): the outlines run in curves through the grid and not
-- along it, and they move as the blood spreads instead of jumping from cell to cell.
--
-- The body is drawn again with these in place of its materials' textures, each material through a
-- texture transform that lays its part of its texture over the canvas. The engine skins those
-- passes exactly as it skinned the body and lights them as it lit the body. There is no geometry
-- of the film's own to place, to keep on the skin, to light or to sort.
-- Blood is drawn as what it is at each place, in two layers:
--   * The stain: all of the film, drawn as blood in the surface it lies on. It has the blood's
--     colour, deeper where more blood is, the surface's own relief (the body's own normal map: a
--     shirt's folds go on through it, and it takes the light as the cloth round it does) and the
--     surface's own texture showing in it (the weave, a pattern, the pores: darker where the
--     cloth is dark). Its colour follows the flow: what differs from place to place is drawn out
--     along the way the blood runs (streaks).
--   * The liquid: wet blood that stands on the surface. It has an outline of its own inside the
--     stain's and a surface of its own: a rounded rim, the low ridges of its streaks, and while it
--     runs, low waves that travel down it. What is drawn of it over the stain is what a wet
--     surface adds to what lies under it: the light's highlight and the sky's sheen, by that
--     surface. When it has come to rest it is still, and as it dries it draws back from its rims:
--     the stain is what is left.
-- Far away, and with abl_film_gloss 0, there is one pass: the stain without relief. With
-- abl_film_layers 0 the film is drawn as it was before it had two layers (one layer of one kind,
-- cut at the film's outline), for seeing the two side by side.
--
-- What this build of the game does, as measured in it (scenes of sv_filmtest.lua):
--   * render.MaterialOverrideByIndex does not replace a material the entity has a sub-material
--     for (Z-City's clothes are sub-materials): a pass is drawn with the entity's own
--     sub-materials set for its duration and put back after.
--   * VertexLitGeneric with $alphatest, $phong and a $bumpmap, all three on render targets and
--     through $basetexturetransform, draws on a skinned model as it does with textures from a
--     file: the cut follows A's alpha.
--   * What is drawn with a relief of the film's own is not lit as the body is. On a white sweater
--     in the body's own shade, blood drawn with the canvas's relief was 0.4 times as bright as
--     blood drawn beside it with the sweater's own, by the highlight's shader and by the plain one
--     alike, and 0.8 times in the sun; on a black suit there was no such difference (scenes
--     film_liquid, film_bump). A liquid with a colour of its own over the stain was a dark shape
--     with a bright line round it on the one and not on the other. So the film's colour is drawn
--     once, with the body's relief, and the liquid's surface carries only what is added to it.
--   * A pass that is added ($additive) with $phong and a $color2 of nothing draws the highlight
--     and the rim light alone (scene film_liquid).
--   * $detail works with a $bumpmap, with and without $phong, in its mode 0 (base x detail x 2) and
--     from the mesh's own texture coordinates whatever $basetexturetransform is: the body's own
--     texture can be laid into the film. Mode 8 has no shader here (the whole body is drawn white).
--   * A translucent pass with $distancealpha and $softedges under the stain, to smooth its rim by
--     a pixel, did not keep to the width it was told: no rim at all on a white sweater, whatever
--     the width, and a red glow a texel wide round blood on a black suit (scenes film_rim,
--     film_pairs). It is not drawn (K.softPx 0); the stain's outline is its own cut.
--   * Drawn unlit and blended over a filter pass (the first way this film was drawn), blood was a
--     pale red veil with a soft rim round it; a cubemap mirrored in it, however faintly, is a milky
--     patch (scenes film_look, film_try). Neither is here.
--   * The engine's highlight ($phong) with a wide lobe lies over wet blood in the sun as a pale
--     pink smear, and over blood-soaked cloth as a pink haze. With a narrow one a level sheet of
--     liquid still mirrors the sun as one soft pale glow: the liquid shines in full only where its
--     surface turns (PaintMap), and what is left is a small glint on a rim, a ridge or a wave
--     (scene film_shine).
--   * The surroundings mirrored in the liquid by the highlight's own pass ($envmap env_cubemap with
--     $envmapfresnel in the pass that is added, which this shader lays on by the same number as
--     the highlight, B's alpha): a pale lilac veil over all of a run at a tint of 0.3 and a white
--     sheet at 0.8, on a white sweater and on a black suit alike, in the sun and in shade. What
--     carries the highlight's number on running liquid (its waves, its ridges) covers it whole.
--     Not drawn. (Scene cont_look of sv_conttest.lua, run fl2_first, 2026-10-13.)
--   * A texel is written with the alpha and at the place it is given; its colour goes through the
--     engine's gamma on the way in (D.Cell undoes that).
--   * A character Z-City draws itself (a ragdoll) is posed inside its renderer: the passes have to
--     be drawn from there (PostDrawAppearance); drawn later they do not lie on the body.
--   * A painting costs about half a millisecond whatever it paints, and some five microseconds a
--     texel it looks at: films are painted a few times a second and one in a frame (D.Paint), and
--     only what has visibly changed is asked for (cl_film.lua).

ABL.NoJIT()
ABL.FilmDraw = ABL.FilmDraw or {}
local D = ABL.FilmDraw
local C, CH, FM = ABL.Config, ABL.FilmChart, ABL.Film
local K, KF = C.Film, C.Flow
local S, G = K.canvas, K.border
local floor, min, max, sqrt, exp, abs, sin = math.floor, math.min, math.max, math.sqrt, math.exp, math.abs, math.sin

-- (clamp s/t, no mips, no LOD: as the pools' pages)
local RT_FLAGS = bit.bor(4, 8, 256, 512)

D.cvGloss = CreateClientConVar("abl_film_gloss", "1", true, false, "Blood on bodies near the eye in full: the liquid as a layer of its own with the light's highlight, the stain with the cloth's relief (1), or everywhere as it is drawn far away (0).", 0, 1)
D.cvLayers = CreateClientConVar("abl_film_layers", "1", true, false, "Blood on bodies as a stain in the surface with the liquid as a layer of its own on it, its detail following the flow (1), or as one layer of one kind, the way it was drawn before (0).", 0, 1)
D.cvFull = CreateClientConVar("abl_film_full_near", "1", true, false, "The films of the bodies nearest the eye (K.fullCount of them within K.fullDist units) are drawn and painted in full whatever the performance governor's scale is (1), or, as before, by distances the governor shortens while the addon is over its budget (0).", 0, 1)
-- (for comparison in development; not kept between sessions)
D.cvBones =CreateClientConVar("abl_film_bones", "1", false, false, "Bones that Z-City sets by hand before it draws a body (1): the blood film is drawn with the bones the body itself was drawn with, and the simulation reads a head that is only hidden for the camera at its size. 0: as before, the film on whatever the engine sets up for the second drawing (on Z-City: another head), the hidden head a point at the neck.", 0, 1)
-- (two layers or one: the configuration's word and the console's. Looked up once a frame, in
-- D.Paint; a canvas holds other things for the one than for the other, so every film is painted
-- anew when it changes.)
local layeredNow = K.material ~= 0 and D.cvLayers:GetBool()
function D.Layered() return layeredNow end
D.canvases = D.canvases or {}
local canvases = D.canvases
D.stats = D.stats or { passes = 0, texels = 0, paints = 0, ms = 0 }
-- (per frame and since the last asking: texels whose share of blood rose past the outline's value,
-- texels where it fell back under it, and the most any texel's share changed in one painting. An
-- outline that spreads gains texels and loses none; one that flickers does both.)
D.stats.enter, D.stats.leave, D.stats.jump = D.stats.enter or 0, D.stats.leave or 0, D.stats.jump or 0
-- (and of the waves: paintings, texels written, milliseconds; and with D.measure set, by the tests:
-- texel steps looked at, the sum of the changes of their slope, the square of the largest, and
-- the steps that went the other way from the step before)
D.stats.ripples, D.stats.ripTexels, D.stats.ripMs = D.stats.ripples or 0, D.stats.ripTexels or 0, D.stats.ripMs or 0
D.stats.ripN, D.stats.ripSum, D.stats.ripMost, D.stats.ripBack = D.stats.ripN or 0, D.stats.ripSum or 0, D.stats.ripMost or 0, D.stats.ripBack or 0
-- (phase 19: the same three of the liquid's own outline, its share crossing the outline's value,
-- counted by the painter; and the finer pictures the lerp made anew, LerpPass)
D.stats.enterL, D.stats.leaveL, D.stats.jumpL = D.stats.enterL or 0, D.stats.leaveL or 0, D.stats.jumpL or 0
D.stats.lerps = D.stats.lerps or 0

-- Phase 19 (C.V19, sh_config.lua): which of its parts are on, read once a frame at the start of
-- D.Paint and kept here for all that paints or draws in that frame (the painter reads D.v19 once a
-- painting). With abl_liquid_v19 0 every one of them is false and all is drawn as before.
D.v19 = D.v19 or {}
local V19 = D.v19
local function V19On(name) return C.V19On ~= nil and C.V19On(name) or false end
-- (all but the last decide what the canvases hold or what their materials are made of: when one of
-- them changes, D.Paint makes the materials anew and paints every film anew. The lerp only moves
-- what is there. clothRelief: which relief the stain is drawn with, D.Dress: the canvases are dressed
-- anew with it.)
local V19PARTS = { "split", "b2", "surface", "ease", "depthTone", "feather", "waves", "pendPaint", "fade", "clothRelief", "dye", "lerp" }
local function V19Read()
	V19.on = C.cl ~= nil and C.cl.v19 ~= nil and C.cl.v19:GetBool()
	local sig = 0
	for i = 1, #V19PARTS do
		local name = V19PARTS[i]
		local on = V19On(name)
		-- (b2 stays off for the session when the game's probe found that B2 is not B's byte mean: D.ProbeB2)
		if name == "b2" and D.b2Bad then on = false end
		V19[name] = on
		if on and i < #V19PARTS then sig = sig + 2 ^ i end
	end
	-- (and with them, not in the signature: how the waves' crests lie across a run (WaveTb), and how
	-- often the waves of a film near the eye are painted (D.Paint). The waves are painted again and
	-- again; nothing has to be made anew when these change.)
	V19.waveAcross = V19.waves and V19On("waveAcross")
	V19.rippleNear = V19.waves and V19On("rippleNear")
	return sig
end
local v19sig = V19Read()
-- (this file loaded again while canvases made by its earlier loading are there: they are made anew
-- at the next frame, as for a change of the switches)
if canvases[1] and V19.on then v19sig = -1 end
-- (made below: the targets, the smoothing, the lerp and the fade of phase 19; Gain sets the fade again)
local Targets, SmoothOf, LerpFinish, LerpDrop, Fade
-- (and the painter's: every cell of a map asked for again, and a map painted anew because the colour
-- its film thins out to has changed, phase 19's feather: Gain asks for it)
local QueueMap, Refeather

------------------------------------------------------------------------------------------
-- Canvases
------------------------------------------------------------------------------------------
local OUT = 0.5               -- the share of a texel's surroundings that holds blood at the film's outline
local T1, T2 = 0.375, 0.75    -- alpha of canvas A at the film's outline, and at the outline of the liquid on it
-- (for the bench and the tests: where the outlines are cut; with split each is cut at 0.5 of its own target)
D.T1, D.T2, D.OUT = T1, T2, OUT
local matNone
local xform = Matrix()
local xScale, xMove = Vector(1, 1, 1), Vector(0, 0, 0)
-- (materials are made once under their names and kept by the engine: another name when what they
-- are made of changes)
local VER = "10"

-- (a relief that is none and a detail that changes nothing: for a surface that has none of its own)
local flatTex, greyTex
local function Blanks()
	if flatTex then return end
	local function Make(name, r, g, b)
		local t = GetRenderTargetEx(name, 4, 4, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		render.PushRenderTarget(t)
		render.Clear(r, g, b, 255, false, false)
		render.PopRenderTarget()
		return t
	end
	flatTex, greyTex = Make("abl_film_flat", 128, 128, 255), Make("abl_film_grey", 128, 128, 128)
end

-- (pe, pb: the highlight's lobe and brightness, K's when not given; StainKV's cut: T1 when not given)
local function LitKV(a, b, cut, pe, pb)
	return { ["$basetexture"] = a, ["$bumpmap"] = b, ["$model"] = 1,
		["$alphatest"] = 1, ["$alphatestreference"] = cut, ["$allowalphatocoverage"] = 1,
		["$phong"] = 1, ["$phongexponent"] = pe or K.phongExp, ["$phongboost"] = pb or K.phongBoost, ["$phongfresnelranges"] = "[0.25 0.55 1]" }
end
local function StainKV(a, cut)
	return { ["$basetexture"] = a, ["$model"] = 1, ["$halflambert"] = 1,
		["$alphatest"] = 1, ["$alphatestreference"] = cut or T1, ["$allowalphatocoverage"] = 1 }
end
-- (the body's own texture laid into the film: base x detail x 2, as much of it as f)
local function Show(kv, tex, f)
	kv["$detail"], kv["$detailscale"], kv["$detailblendmode"], kv["$detailblendfactor"] = tex, 1, 0, f
	return kv
end

-- (phase 19, split: the passes that draw the liquid read its own outline from L; the others A)
local LFAM = { deep = true, liq = true, lit = true, shine = true }

local function Materials(c)
	Blanks()
	-- (phase 19: a set of materials of their own for each way they can be made, each made once and
	-- kept under its own name: split, each outline in the alpha of a target of its own and cut at a
	-- half, with no alpha-to-coverage (a ramp a texel wide would be a dithered band on screen); and
	-- surface, the highlight's numbers from C.V19. With neither, the names and numbers of before.)
	local split = V19.split and c.l ~= nil
	local surf = V19.surface
	local id = VER .. (split and "s" or "") .. (surf and "p" or "") .. "_" .. c.id
	-- (the film's outlines are read from A2 where it is there: D.Smooth; the liquid's surface from B2
	-- where that is: SmoothOf)
	local a, b = (c.a2 or c.a):GetName(), (c.b2 or c.b):GetName()
	-- (a set made earlier under the same name keeps the relief it was last given, B2 or B: D.Finer
	-- gives it the one of now)
	local l = split and (c.l2 or c.l):GetName() or a
	local t1, t2 = split and 0.5 or T1, split and 0.5 or T2
	local pe, pb, rim = K.phongExp, K.phongBoost, K.rim
	if surf then pe, pb, rim = C.V19.phongExp or pe, C.V19.phongBoost or pb, C.V19.rim or rim end
	local flat, grey = flatTex:GetName(), greyTex:GetName()
	c.mats, c.names, c.onCanvas = {}, {}, {}
	-- (which of them read L, for D.Finer; where the stain is cut, for its rim pass in D.Source)
	c.famL, c.cutF = split and {} or nil, split and t1 or nil
	local function Make(name, kv)
		if split then kv["$allowalphatocoverage"] = nil end
		c[name] = CreateMaterial("abl_film_" .. name .. id, "VertexLitGeneric", kv)
		c.mats[#c.mats + 1] = c[name]
		c.onCanvas[#c.mats] = kv["$bumpmap"] == b
		c.names[name] = "!abl_film_" .. name .. id
		if split and LFAM[name] then c.famL[#c.mats] = true end
	end
	-- The stain: the blood's colour under the engine's light, cut at the film's outline, with the
	-- relief and the texture of what it lies in (D.Dress gives it those of the body's own material).
	-- All of the film is drawn by it, the liquid's part too.
	local kv = Show(StainKV(a, t1), grey, K.clothShow)
	kv["$bumpmap"] = flat
	Make("stain", kv)
	-- The liquid on it, what is added: the highlight of the lamps that light it and the sky's sheen
	-- at a flat angle (the engine's rim light, a little of it), cut at the liquid's own outline, by
	-- its own surface (B: which way it faces; B's alpha: how bright the highlight is there). A pass
	-- that is added and has no colour of its own. Nothing is mirrored in it: a sky laid over dark
	-- red is a pale veil, which no blood has.
	kv = LitKV(l, b, t2, pe, pb)
	kv["$additive"] = 1
	kv["$color2"] = "[0 0 0]"
	kv["$rimlight"], kv["$rimlightexponent"], kv["$rimlightboost"] = 1, 3, rim
	Make("shine", kv)
	-- The liquid's own colour, by the stain's kind of material and with the body's relief as the
	-- stain has it, cut at the liquid's outline and with as little of the cloth showing as the
	-- whole film used to have: a layer of liquid hides the weave it stands on, the stain round it
	-- is cloth with blood in it. (Not the pass "liq" below, which is drawn with the liquid's own
	-- surface for relief and is lit otherwise than the stain beside it on some clothes.)
	kv = Show(StainKV(l, t1), grey, K.clothShowWas or K.clothShow)
	kv["$alphatestreference"] = t2
	kv["$bumpmap"] = flat
	Make("deep", kv)
	-- (K.liquidPasses 2: the liquid's colour too, by the stain's kind of material with the liquid's
	-- own surface for relief, under the highlight. On some clothes it is lit quite otherwise than
	-- the stain beside it: see the head of this file.)
	kv = Show({ ["$basetexture"] = l, ["$bumpmap"] = b, ["$model"] = 1, ["$halflambert"] = 1,
		["$alphatest"] = 1, ["$alphatestreference"] = t2, ["$allowalphatocoverage"] = 1 }, grey, K.liquidShow)
	kv["$color2"] = string.format("[%.3f %.3f %.3f]", K.liquidTint, K.liquidTint, K.liquidTint)
	Make("liq", kv)
	-- (K.liquidPasses 3: colour and highlight in one pass, by the shader that has the highlight)
	kv = Show(LitKV(l, b, t2, pe, pb), grey, K.liquidShow)
	kv["$halflambert"] = 1
	kv["$color2"] = string.format("[%.3f %.3f %.3f]", K.liquidTint, K.liquidTint, K.liquidTint)
	kv["$rimlight"], kv["$rimlightexponent"], kv["$rimlightboost"] = 1, 3, rim
	Make("lit", kv)
	-- (K.softPx above 0: the stain's rim, what lies just outside its outline, fading out; D.Source
	-- sets over how much. Not used: see the head of this file.)
	Make("soft", Show({ ["$basetexture"] = a, ["$model"] = 1, ["$halflambert"] = 1, ["$translucent"] = 1,
		["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = t1, ["$edgesoftnessend"] = t1 - 0.1 }, grey, K.clothShow))
	-- (far away, and with abl_film_gloss 0: the stain alone, without relief)
	Make("plain", Show(StainKV(a, t1), grey, K.clothShow))
	-- (as the film was drawn before it had two layers: abl_film_layers 0, to see the two side by side)
	Make("old", LitKV(a, b, t1))
end

-- The material's own texture coordinates onto the canvas of map c.mp: cell x of the grid is texel
-- x + G. (The materials whose relief is the canvas's B have it laid the same way; the others keep
-- the body's own relief where the body has it.)
local function Lay(c)
	local mp = c.mp
	xScale:SetUnpacked(1 / (mp.cu * S), 1 / (mp.cv * S), 1)
	xMove:SetUnpacked((G - mp.u0 / mp.cu) / S, (G - mp.v0 / mp.cv) / S, 0)
	xform:Identity()
	xform:SetScale(xScale)
	xform:SetTranslation(xMove)
	for i = 1, #c.mats do
		c.mats[i]:SetMatrix("$basetexturetransform", xform)
		if c.onCanvas[i] then c.mats[i]:SetMatrix("$bumptransform", xform) end
	end
end

-- The texture and the relief of the material the body itself has (a piece of clothing is a
-- sub-material), by its name. false: none to be had. (bumpReal: whether that relief is the
-- material's own, Real.)
local cloths = {}
-- (Phase 19, clothRelief) Whether texture t is one the material has. For a parameter a material does
-- not set, GetTexture gives the engine's "error" texture: a texture that loaded, so ITexture:IsError
-- is false for it (IsErrorTexture, where the game has it, is true, and its name is "error"). The white
-- sweater (models/humans/*/group01/sweater) has no $bumpmap, nor have nine of the face textures, and
-- their stain was drawn with the error texture's checks for a relief: in the game the same blood on
-- the sweater was 114 red with it and 81 with a flat relief in the same frame (scene film_bump, run
-- bumpA), lit brighter than the white cloth beside it in the body's own shade, round a liquid that
-- was lit as it should be: a glowing red band with a dark stripe down it.
local function Real(t)
	if not t or t:IsError() then return false end
	if t.IsErrorTexture ~= nil and t:IsErrorTexture() then return false end
	return t:GetName() ~= "error"
end
local function ClothOf(name)
	local e = cloths[name]
	if e == nil then
		e = false
		local m = Material(name)
		if m and not m:IsError() then
			local base, bump = m:GetTexture("$basetexture"), m:GetTexture("$bumpmap")
			if base and not base:IsError() then
				e = { base = base, bump = (bump and not bump:IsError()) and bump or nil, bumpReal = Real(bump) }
			end
		end
		cloths[name] = e
	end
	return e
end

-- How much of the surface's own texture shows in the stain of canvas c, and how bright the stain is
-- drawn for it. The texture is laid in as base x (1 - f + 2 f t): with more of it (f) the weave, the
-- pattern and the pores show more, and on a light cloth all of the blood is brighter with it, by
-- (1 - f + 2 f m) for a cloth of mean brightness m. (At f = 0.5 blood in white cloth was half again
-- as bright as its colour, a red of paint; so f stood at 0.2, and blood lay on a sweater as on a
-- sheet of plastic: nothing of the knit showed in it. Measured: scene cont_stand, run fl1_diag.) So
-- the stain is drawn darker by as much as the texture makes it brighter on average: its brightness
-- stays what it was at K.clothShowWas, and only what differs from place to place in the cloth
-- shows more. On a dark cloth more of the texture would make the blood darker and it would have to
-- be drawn brighter than its colour: there f stays what it was.
local gainV, deepV = Vector(1, 1, 1), Vector(1, 1, 1)

-- (Phase 19, feather) The colour a thin film of blood leaves on canvas c's surface, as a colour of
-- the canvas (0..255, c.edge): what, under the stain's detail (base x (1 - f + 2 f m), channel by
-- channel) and its brightness (g: Gain), shows the surface's own mean colour (c.meanRGB, Measure)
-- times C.V19.featherTint. The painter turns the film's colour toward it at its outline. Not known
-- (and no feather) until the surface's colour is; when it changes by more than two steps, the map is
-- painted anew (Refeather: its texels hold the colour they were painted with).
local FTINT = { 0.92, 0.40, 0.38 }
local function Edge(c, f, g)
	local mm = c.meanRGB
	if not mm then
		if c.edge then
			c.edge = nil
			if Refeather then Refeather(c) end
		end
		return
	end
	local tint = C.V19.featherTint or FTINT
	local m0 = c.mean or 0.5
	local e = c.edgeV
	if not e then
		e = { 0, 0, 0 }
		c.edgeV = e
	end
	local moved = c.edge == nil
	local r, gg, b
	for i = 1, 3 do
		local m = mm[i] or m0
		local d = (1 - f + 2 * f * m) * g
		local v = d > 0 and 255 * m * (tint[i] or 1) / d or 0
		if v < 0 then v = 0 elseif v > 255 then v = 255 end
		if abs(v - e[i]) > 2 then moved = true end
		if i == 1 then r = v elseif i == 2 then gg = v else b = v end
	end
	if moved then
		e[1], e[2], e[3] = r, gg, b
		c.edge = e
		if Refeather then Refeather(c) end
	end
end

local function Gain(c)
	local f0 = K.clothShowWas or K.clothShow
	local m = c.mean or 0.5
	local k = (m - 0.3) / 0.3
	k = k < 0 and 0 or (k > 1 and 1 or k)
	-- (Phase 19, dye: blood in cloth is a dye in it. The light yarn of a pattern takes it as a red, the
	-- dark yarn as a darker red, and the knit and the pattern stay as plain in it as round it. With 0.6
	-- of the white sweater's texture in its stain and 0.2 in the liquid on it, its knit showed as faint
	-- streaks and its pattern not at all: a red of one value from rim to rim, laid over the cloth like
	-- tape, run p19f, 2026-10-17. On the same brightness as before: only what differs from place to
	-- place shows more, as clothShow's own note says.)
	local dye = V19.dye
	local fs = dye and (C.V19.dyeShow or 1) or K.clothShow
	local f = f0 + (fs - f0) * k
	local g = (1 - f0 + 2 * f0 * m) / (1 - f + 2 * f * m)
	if g > 1 then g = 1 end
	-- (the engine takes a material's colour for a display value)
	local v = g ^ (1 / 2.2)
	gainV:SetUnpacked(v, v, v)
	for _, name in ipairs({ "stain", "plain", "soft" }) do
		c[name]:SetFloat("$detailblendfactor", f)
		c[name]:SetVector("$color2", gainV)
	end
	-- (the liquid standing on it: as bright as the stain was at clothShowWas, times K.deepTint; with
	-- dye, a thin layer of it shows the cloth under it too, less than the stain does, as bright)
	local fd, gd = f0, 1
	if dye then
		fd = f0 + ((C.V19.dyeLiquid or 0.6) - f0) * k
		gd = (1 - f0 + 2 * f0 * m) / (1 - fd + 2 * fd * m)
		if gd > 1 then gd = 1 end
	end
	c.deepF, c.deepT = fd, (K.deepTint or 1) * gd
	c.deep:SetFloat("$detailblendfactor", fd)
	local dt = c.deepT ^ (1 / 2.2)
	deepV:SetUnpacked(dt, dt, dt)
	c.deep:SetVector("$color2", deepV)
	c.showF, c.gain = f, g
	-- (phase 19, fade: what the liquid's passes show at the canvas's distance is set again at once from
	-- these, at the fade it has (Fade). D.Overlay dresses a canvas after D.Source has faded it, and
	-- deep was then drawn in that frame with the faded detail but the unfaded colour.)
	local ff = c.fadeF
	if ff and V19.fade then Fade(c, ff) elseif ff then c.fadeF = nil end
	-- (phase 19, feather: the colour its film thins out to, by these)
	if V19.feather then Edge(c, f, g) elseif c.edge then c.edge = nil end
end

-- The mean brightness (0 .. 1, as the texture's own numbers) of the part of the surface's texture
-- that canvas c's map lies on: the texture is drawn small, the way the map lies in it, and read at
-- the places that are places of the body. Inside a render hook, outside the 3D view. Once for a map
-- and a texture. (And its mean red, green and blue, 0 .. 1 each: phase 19's feather, c.meanRGB.)
local meanRT
local meanN = 0
local MEAN = 32
local function Measure(c, e)
	local mp = c.mp
	if not mp or not mp.tri then return 0.5 end
	if not meanRT then
		meanRT = GetRenderTargetEx("abl_film_mean", MEAN, MEAN, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	end
	-- (A material of the texture's own, made with it: the engine turns the coordinates it is given by
	-- half a texel of the texture a material was made with, whatever texture it is given later. One
	-- material made with a small white texture and pointed at each cloth's in turn read a pair of
	-- dark jeans as 0.72 bright, and their blood was drawn a quarter darker for it: run fl3_second.)
	local mat = e.meanMat
	if not mat then
		meanN = meanN + 1
		mat = CreateMaterial("abl_film_mean" .. VER .. "_" .. meanN, "UnlitGeneric", { ["$basetexture"] = e.base:GetName(), ["$ignorez"] = 1, ["$nocull"] = 1 })
		e.meanMat = mat
	end
	local tw, th = e.base:Width(), e.base:Height()
	local function U(u) return (u - 0.5 / tw) / (1 - 1 / tw) end
	local function V(v) return (v - 0.5 / th) / (1 - 1 / th) end
	render.PushRenderTarget(meanRT)
	render.Clear(128, 128, 128, 255, false, false)
	cam.Start2D()
	surface.SetMaterial(mat)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRectUV(0, 0, MEAN, MEAN, U(mp.u0), V(mp.v0), U(mp.u0 + mp.W * mp.cu), V(mp.v0 + mp.H * mp.cv))
	cam.End2D()
	render.CapturePixels()
	local W, H, tri = mp.W, mp.H, mp.tri
	local sum, n = 0, 0
	local sr, sg, sb = 0, 0, 0
	for y = 0, MEAN - 1 do
		local cy = floor((y + 0.5) / MEAN * H)
		for x = 0, MEAN - 1 do
			local cx = floor((x + 0.5) / MEAN * W)
			if tri[cy * W + cx + 1] > 0 then
				local r, g, b = render.ReadPixel(x, y)
				if r then
					sum = sum + 0.3 * r + 0.59 * g + 0.11 * b
					sr, sg, sb = sr + r, sg + g, sb + b
					n = n + 1
				end
			end
		end
	end
	render.PopRenderTarget()
	if n <= 0 then return 0.5, 0.5, 0.5, 0.5 end
	return sum / n / 255, sr / n / 255, sg / n / 255, sb / n / 255
end

-- (canvases whose surface's brightness has not been read yet: read in D.Paint, where targets may be set)
local unread = {}

-- Canvas c lies on a surface whose own material is `name`: the stain takes that material's relief,
-- and its texture shows in the film.
function D.Dress(c, name)
	c.cloth = name or false
	local e = name and ClothOf(name)
	local base, bump = e and e.base or greyTex, e and e.bump or flatTex
	-- (phase 19, clothRelief: a relief the cloth does not have, the engine's error texture, is not laid
	-- under the stain nor under the liquid's colour by the body's relief (deep): the body's own normal
	-- there, flat, as for a surface with no relief at all. Rebuild dresses every canvas anew when the
	-- part is turned on or off.)
	if e and e.bump and V19.clothRelief and not e.bumpReal then bump = flatTex end
	c.stain:SetTexture("$bumpmap", bump)
	c.stain:SetTexture("$detail", base)
	c.deep:SetTexture("$bumpmap", bump)
	c.deep:SetTexture("$detail", base)
	c.lit:SetTexture("$detail", base)
	c.liq:SetTexture("$detail", base)
	c.soft:SetTexture("$detail", base)
	c.plain:SetTexture("$detail", base)
	-- (how bright that texture is where the map lies: known from an earlier time, or read at the
	-- next painting; until then as for a cloth of middling brightness)
	local mp = c.mp
	local known = e and mp and mp.means and mp.means[name]
	c.mean = known or 0.5
	-- (phase 19, feather: and its colour, known with its brightness; none until it is read)
	local rgb = e and mp and mp.meansRGB and mp.meansRGB[name] or nil
	c.meanRGB = rgb
	if e and mp and (not known or (V19.feather and not rgb)) then unread[#unread + 1] = { c = c, e = e, name = name, mp = mp } end
	Gain(c)
end

local function ReadMeans()
	for i = #unread, 1, -1 do
		local u = unread[i]
		unread[i] = nil
		local c, mp = u.c, u.mp
		mp.means = mp.means or {}
		-- (phase 19: the colour is kept with the brightness, by map and texture: c.meanRGB)
		mp.meansRGB = mp.meansRGB or {}
		local m = mp.means[u.name]
		if not m or not mp.meansRGB[u.name] then
			-- (the map as it lies in the texture is the chart's, whichever canvas it is painted in)
			local was = c.mp
			c.mp = mp
			local mr, mg, mb
			m, mr, mg, mb = Measure(c, u.e)
			c.mp = was
			mp.means[u.name] = m
			mp.meansRGB[u.name] = { mr or m, mg or m, mb or m }
		end
		if not c.free and c.mp == mp and c.cloth == u.name then
			c.mean = m
			c.meanRGB = mp.meansRGB[u.name]
			Gain(c)
		end
	end
end

local function Wipe(c)
	-- (the colour of blood where there is none yet, so that what is read between a texel of the film
	-- and one beside it is blood's colour and not a darker one: no dark seam along a smoothed rim)
	local p = K.palette.wetBody
	render.PushRenderTarget(c.a)
	render.Clear(p[1], p[2], p[3], 0, false, false)
	render.PopRenderTarget()
	if c.a2 then
		render.PushRenderTarget(c.a2)
		render.Clear(p[1], p[2], p[3], 0, false, false)
		render.PopRenderTarget()
	end
	-- (no relief, no shine: a texel beside the liquid takes part in what is read at its rim)
	render.PushRenderTarget(c.b)
	render.Clear(128, 128, 255, 0, false, false)
	render.PopRenderTarget()
	-- (phase 19: the liquid's outline and its finer picture as A's, and B's finer picture as B)
	if c.l and V19.split then
		render.PushRenderTarget(c.l)
		render.Clear(p[1], p[2], p[3], 0, false, false)
		render.PopRenderTarget()
	end
	if c.l2 then
		render.PushRenderTarget(c.l2)
		render.Clear(p[1], p[2], p[3], 0, false, false)
		render.PopRenderTarget()
	end
	if c.b2 then
		render.PushRenderTarget(c.b2)
		render.Clear(128, 128, 255, 0, false, false)
		render.PopRenderTarget()
	end
end

-- Canvases there may be at the most (two render targets of S x S each: they are never freed).
-- (Phase 19: a canvas has L, L2 and B2 besides while split and b2 are on, 3.75 MB in all where it
-- had 1.5; and C.V19.lerpPool sets of three S x S targets are kept for the lerp, 0.75 MB a set, with
-- three more it mixes in, Blend8.)
function D.Limit()
	return 10 + 6 * C.cl.quality:GetInt()
end

-- Canvases in use, and canvases made.
function D.Usage()
	local used = 0
	for i = 1, #canvases do
		if not canvases[i].free then used = used + 1 end
	end
	return used, #canvases
end

-- A canvas for map mp (cl_filmchart.lua) of a body, cleared. Only inside a render hook. nil: none
-- left. owner: the film it is for (D.Steal may take it back for a film nearer the eye).
function D.Take(mp, owner)
	local c
	for i = 1, #canvases do
		if canvases[i].free then c = canvases[i] break end
	end
	if not c then
		if #canvases >= D.Limit() then return nil end
		local id = #canvases + 1
		c = { id = id }
		for _, p in ipairs({ "a", "b" }) do
			c[p] = GetRenderTargetEx("abl_film_" .. p .. id, S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		end
		-- (phase 19: L and B2 while split and b2 are on)
		if V19.split or V19.b2 then Targets(c) end
		if D.Smoothed() then D.Finer(c, true) end
		Materials(c)
		-- (phase 19: the materials just made are told their textures once more. A set the engine still
		-- holds under these names, from a load of this file before, keeps what it was last given.)
		if V19.on then D.Finer(c, D.Smoothed()) end
		canvases[id] = c
	end
	c.free = false
	c.mp = mp
	c.owner = owner
	c.painted = false
	-- (whose surface it lies on is found when it is first drawn)
	c.cloth, c.softW = nil, nil
	-- (phase 19, feather: and that surface's colour, and what the film thins out to on it, with it)
	c.meanRGB, c.edge = nil, nil
	-- (phase 19: nothing of an earlier owner's interpolations, nor of its fade)
	if c.lset or c.lrOpen then LerpDrop(c) end
	if c.fadeF then c.fadeF = nil end
	Wipe(c)
	Lay(c)
	return c
end

function D.Give(c)
	if c then
		c.free, c.mp, c.owner, c.painted = true, nil, nil, false
		-- (phase 19, lerp: its interpolations go, and its set of earlier pictures goes back)
		if c.lset or c.lrOpen then LerpDrop(c) end
	end
end

-- A film that goes gives its canvases back.
function D.Release(s)
	local cv = s.cv
	if not cv then return end
	for _, c in pairs(cv) do D.Give(c) end
	s.cv, s.layers, s.tx, s.animN = nil, nil, nil, 0
	-- (phase 19, ease: of those texels on their way, the ones whose colour, shine or surface only were)
	if s.easeN then s.easeN = nil end
end

-- Nothing of film s waits to be painted any more (its canvases went: all of it is asked for again
-- when it has some).
local function Unqueue(s)
	local q, uq, dq, inq = s.queue, s.uq, s.dq, s.inq
	for i = 1, s.qn do
		dq[q[i]] = 0
		inq[q[i]] = nil
		q[i] = nil
	end
	for i = 1, s.un do
		dq[uq[i]] = 0
		uq[i] = nil
	end
	s.qn, s.un = 0, 0
end

-- How long a film's map that got no canvas waits before it asks again (s).
local STARVE = 2

-- No canvas is left for film s. A film that is not being drawn gives up the ones it has (the one
-- that has not been drawn for longest); when all are, the film farthest from the eye, if it is a
-- good deal farther away than s: what is near is seen, and there are only so many canvases.
-- Returns true when one did.
function D.Steal(s)
	local dist = s.src.dist or 0
	local rt = RealTime()
	local far, fd, idle, it
	for i = 1, #canvases do
		local c = canvases[i]
		local o = c.owner
		if o and o ~= s and not c.free then
			local unseen = o.drawT and rt - o.drawT or 1e9
			if unseen > K.idleFree and (not it or unseen > it) then idle, it = o, unseen end
			local d = o.src.dist or 0
			if d > dist * 1.25 + 40 and (not fd or d > fd) then far, fd = o, d end
		end
	end
	far = idle or far
	if not far then return false end
	local wait = RealTime() + STARVE
	far.starve = far.starve or {}
	for k in pairs(far.cv) do far.starve[k] = wait end
	D.Release(far)
	Unqueue(far)
	D.stats.stolen = (D.stats.stolen or 0) + 1
	return true
end

------------------------------------------------------------------------------------------
-- Writing texels (inside a render hook, outside the 3D view)
------------------------------------------------------------------------------------------
-- Begin writing texels of one of a canvas's targets ("a", "b"). What is written replaces what was
-- there, colour and alpha as they are given.
function D.Begin(c, which)
	render.PushRenderTarget(c[which])
	cam.Start2D()
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideColorWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	draw.NoTexture()
end

local SetCol, Rect = surface.SetDrawColor, surface.DrawRect
-- A colour written into a render target does not arrive as it was given: the engine takes it for
-- a display value, turns it into linear light by a power of 2.2 and stores that by the sRGB curve
-- (measured: 10 arrives as 3, 30 as 24, 200 as 201). The curves differ most where blood's green
-- and blue are, at the dark end. SRGB[v] is what has to be given for v to be stored.
local SRGB = {}
for v = 0, 255 do
	local c = v / 255
	local lin = c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
	SRGB[v] = floor(255 * lin ^ (1 / 2.2) + 0.5)
end
D.SRGB = SRGB
-- Cell (x, y) of the grid (from 0): the values the texture is to hold there (r, g, b, a: 0..255,
-- whole numbers).
function D.Cell(x, y, r, g, b, a)
	SetCol(SRGB[r], SRGB[g], SRGB[b], a)
	Rect(x + G, y + G, 1, 1)
end

function D.End()
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
	cam.End2D()
	render.PopRenderTarget()
end

------------------------------------------------------------------------------------------
-- Smooth outlines
------------------------------------------------------------------------------------------
-- A material cuts A's alpha where it reads T1 or T2 between A's texels, and between four texels
-- the engine reads along straight lines: the outline of blood on a body was a row of short
-- straight pieces with a corner at every cell, plain to see from close by, however even the
-- field it is cut from. So the body's materials do not read A itself but a second target, A2, of
-- twice A's size, and each texel of A2 is the mean of A read at four places round its own place
-- (as far either way as stands for the width of a texel of A: a third of one, nearly). Read
-- between the texels of A2 that is A read by a curve where it was read by straight lines: the
-- outline bends evenly through the cells, and nothing of it is blurred away or made wider (the
-- field is the same field, read better). The graphics card does it, four quads over the part
-- of the canvas that changed; no texel is worked out in Lua for it. abl_film_smooth 0: A itself
-- is read, as before.
D.cvSmooth = CreateClientConVar("abl_film_smooth", "1", true, false, "Blood on bodies: its outlines read from a second, finer picture that bends evenly through the cells (1), or cut straight from the cells' own picture with a corner at every cell, as before (0).", 0, 1)
local S2 = S * 2
local TAP = 0.5 / sqrt(3)
local smoothNow = K.smooth ~= 0 and D.cvSmooth:GetBool()
function D.Smoothed() return smoothNow end
-- (the weight of one of four, as the engine has to be given it: a colour is taken for a display
-- value and turned into light by a power of 2.2; alpha goes in as it is)
local UP_C, UP_A = floor(255 * 0.25 ^ (1 / 2.2) + 0.5), 64

-- Canvas c reads its outlines from a finer target of its own (on), or from A itself.
function D.Finer(c, on)
	if on then
		if not c.a2 then
			-- (render targets are never freed: one that was made is kept for when it is wanted again)
			c.a2kept = c.a2kept or GetRenderTargetEx("abl_film_f" .. c.id, S2, S2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
			c.a2 = c.a2kept
		end
	else
		c.a2 = nil
	end
	-- (phase 19, split: the liquid's outline is read from a finer picture of L, made the same way, while
	-- A's is; the materials that draw the liquid read that (c.famL, Materials), the others A's)
	if on and V19.split and c.l then
		c.l2kept = c.l2kept or GetRenderTargetEx("abl_film_lf" .. c.id, S2, S2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		c.l2 = c.l2kept
	else
		c.l2 = nil
	end
	local tex = c.a2 or c.a
	local famL = c.famL
	local ltex = famL and (c.l2 or c.l)
	local mats = c.mats
	for i = 1, mats and #mats or 0 do mats[i]:SetTexture("$basetexture", (famL and famL[i]) and ltex or tex) end
	-- (phase 19, b2: the materials whose relief is the canvas's own read it from B2, made from B, and
	-- from B again once b2 has gone. Set whenever the canvas has materials: b2 is not in a set's name,
	-- and a set kept from before holds whichever it was last given. D.Finer runs for a new canvas,
	-- Rebuild and SmoothSwitch, never in a frame of its own.)
	if mats then
		local bt = c.b2 or c.b
		local onC = c.onCanvas
		for i = 1, #mats do
			if onC[i] then mats[i]:SetTexture("$bumpmap", bt) end
		end
	end
end

-- (the console's word has changed: every canvas reads the other way from now on. In D.Paint.)
local function SmoothSwitch()
	local sm = K.smooth ~= 0 and D.cvSmooth:GetBool()
	if sm == smoothNow then return end
	smoothNow = sm
	for i = 1, #canvases do
		local c = canvases[i]
		-- (phase 19, lerp: an interpolation ends where it is, before the finer pictures change)
		if c.lrOpen then LerpFinish(c) end
		D.Finer(c, sm)
		if sm and not c.free then
			D.Smooth(c, 0, 0, S, S)
			-- (phase 19, split: and L's)
			if c.l2 then SmoothOf(c, "l", 0, 0, S, S) end
		end
	end
end

-- The part of A2 that lies over texels (x0, y0) .. (x1, y1) of A (target coordinates), made anew
-- from A. Inside a render hook, outside the 3D view.
function D.Smooth(c, x0, y0, x1, y1)
	local a2 = c.a2
	if not a2 then return end
	-- (A material of the canvas's own, made with A as its texture: the engine turns what it is told of
	-- a texture's coordinates by the size of the texture the material was made with, whatever it
	-- is given later. With one material for all canvases, made with a small white texture, the
	-- second picture lay 1.6 texels of A up and to the left of the first: measured, run bo3.)
	local up = c.up
	if not up then
		up = CreateMaterial("abl_film_up" .. VER .. "_" .. c.id, "UnlitGeneric", { ["$basetexture"] = c.a:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1 })
		c.up = up
	end
	-- (what is read at a place reaches a texel and a half of A either way)
	x0, y0, x1, y1 = (x0 - 2) * 2, (y0 - 2) * 2, (x1 + 3) * 2, (y1 + 3) * 2
	if x0 < 0 then x0 = 0 end
	if y0 < 0 then y0 = 0 end
	if x1 > S2 then x1 = S2 end
	if y1 > S2 then y1 = S2 end
	render.PushRenderTarget(a2)
	cam.Start2D()
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideColorWriteEnable(true, true)
	render.SetScissorRect(x0, y0, x1, y1, true)
	surface.SetMaterial(up)
	surface.SetDrawColor(UP_C, UP_C, UP_C, UP_A)
	-- (the engine lays a texture's first and last texel's middles on a rectangle's edges, not the
	-- texture's own edges: what it is told is turned so that the edges come to lie on the edges.
	-- K.smoothOff: by how many texels of A the picture is moved besides, as measured in the game.)
	local du = 0.5 / S
	local k = 1 / (1 - 2 * du)
	local off = (K.smoothOff or 0) / S
	for t = 1, 4 do
		render.OverrideBlend(true, BLEND_ONE, t == 1 and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD, BLEND_ONE, t == 1 and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD)
		local ox = (t % 2 == 1 and -TAP or TAP) / S + off
		local oy = (t <= 2 and -TAP or TAP) / S + off
		surface.DrawTexturedRectUV(0, 0, S2, S2, (ox - du) * k, (oy - du) * k, (1 + ox - du) * k, (1 + oy - du) * k)
	end
	render.SetScissorRect(0, 0, 0, 0, false)
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
	cam.End2D()
	render.PopRenderTarget()
	D.stats.smooths = (D.stats.smooths or 0) + 1
end

------------------------------------------------------------------------------------------
-- Phase 19: the liquid's outline (L), its surface read finer (B2), and the films nearest the eye
-- moving in every frame between their paintings (lerp)
------------------------------------------------------------------------------------------
-- Every step here runs only for a canvas that has the target it works on (c.a2, c.l2, c.b2, a set
-- of earlier pictures): the bench's canvases are tables and have none, and take the painter's path.

-- The finer picture of target `which` of canvas c ("a": A2, "l": L2, "b": B2), nil while there is none.
local function FinerOf(c, which)
	if which == "a" then return c.a2 elseif which == "l" then return c.l2 end
	return c.b2
end

-- The material that reads target `which` of canvas c, made with that target as its texture (the
-- engine turns coordinates by the size of the texture a material was made with: D.Smooth). B's
-- numbers are a normal map, which the bump sampler reads as they are: what is made of them is the
-- mean of the bytes, not of the light they would stand for, so B's material reads and writes them
-- as they are ($gammacolorread, $linearwrite: the SDK's UnlitGeneric has them; this game's own
-- documentation does not say, and D.ProbeB2 finds out).
local function UpOf(c, which)
	if which == "a" then
		-- (the same material as D.Smooth's)
		local up = c.up
		if not up then
			up = CreateMaterial("abl_film_up" .. VER .. "_" .. c.id, "UnlitGeneric", { ["$basetexture"] = c.a:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1 })
			c.up = up
		end
		return up
	elseif which == "l" then
		local up = c.upl
		if not up then
			up = CreateMaterial("abl_film_upl" .. VER .. "_" .. c.id, "UnlitGeneric", { ["$basetexture"] = c.l:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1 })
			c.upl = up
		end
		return up
	end
	local up = c.upb
	if not up then
		up = CreateMaterial("abl_film_upb" .. VER .. "_" .. c.id, "UnlitGeneric", { ["$basetexture"] = c.b:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1,
			["$gammacolorread"] = 1, ["$linearwrite"] = 1 })
		c.upb = up
	end
	return up
end

-- (D.Smooth's box: texels (x0, y0) .. (x1, y1) of the canvas as the finer picture's, with what is
-- read at a place reaching a texel and a half either way)
local function Box2(x0, y0, x1, y1)
	x0, y0, x1, y1 = (x0 - 2) * 2, (y0 - 2) * 2, (x1 + 3) * 2, (y1 + 3) * 2
	if x0 < 0 then x0 = 0 end
	if y0 < 0 then y0 = 0 end
	if x1 > S2 then x1 = S2 end
	if y1 > S2 then y1 = S2 end
	return x0, y0, x1, y1
end

local function Open2(t, x0, y0, x1, y1)
	render.PushRenderTarget(t)
	cam.Start2D()
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideColorWriteEnable(true, true)
	render.SetScissorRect(x0, y0, x1, y1, true)
end

local function Close2()
	render.SetScissorRect(0, 0, 0, 0, false)
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
	cam.End2D()
	render.PopRenderTarget()
end

-- (the t-th of D.Smooth's four places, with its edges and K.smoothOff; first: it replaces what is
-- there, the others are added to it)
local function Tap(t, first)
	render.OverrideBlend(true, BLEND_ONE, first and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD, BLEND_ONE, first and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD)
	local du = 0.5 / S
	local k = 1 / (1 - 2 * du)
	local off = (K.smoothOff or 0) / S
	local ox = (t % 2 == 1 and -TAP or TAP) / S + off
	local oy = (t <= 2 and -TAP or TAP) / S + off
	surface.DrawTexturedRectUV(0, 0, S2, S2, (ox - du) * k, (oy - du) * k, (1 + ox - du) * k, (1 + oy - du) * k)
end

-- (B's four weights, as bytes that are not converted: they sum to 255)
local UPB = { 64, 64, 64, 63 }

-- (D.Smooth's four places of the picture material `up` reads (an S x S picture, the material made
-- with it), into finer picture t over texels (x0, y0) .. (x1, y1) of the target: by light (A's,
-- L's) or by bytes (lin: B's))
local function Taps(t, up, lin, x0, y0, x1, y1)
	x0, y0, x1, y1 = Box2(x0, y0, x1, y1)
	Open2(t, x0, y0, x1, y1)
	surface.SetMaterial(up)
	if not lin then surface.SetDrawColor(UP_C, UP_C, UP_C, UP_A) end
	for i = 1, 4 do
		if lin then
			local w = UPB[i]
			surface.SetDrawColor(w, w, w, w)
		end
		Tap(i, i == 1)
	end
	Close2()
end

-- The part of the finer picture of target `which` ("l": L2 of L, "b": B2 of B; "a" is D.Smooth's)
-- that lies over texels (x0, y0) .. (x1, y1) of the target (target coordinates), made anew from it:
-- D.Smooth's four places, weights, edges and box, L's by its light as A's, B's by its bytes. Inside a
-- render hook, outside the 3D view.
function SmoothOf(c, which, x0, y0, x1, y1)
	if which == "a" then return D.Smooth(c, x0, y0, x1, y1) end
	local t = FinerOf(c, which)
	if not t then return end
	Taps(t, UpOf(c, which), which == "b", x0, y0, x1, y1)
	D.stats.smooths = (D.stats.smooths or 0) + 1
end
D.SmoothOf = SmoothOf

-- Does this build make B2 as the mean of B's bytes? Into B of canvas c go a 62 beside a 193 (their
-- mean 127.5) and an even patch of 128, four texels tall; B2 is made from them and read back between
-- the two and in the patch. Returns whether both came back within 3 of that, and what was read (the
-- pair's red and green, the patch's red). What c's B and B2 held is lost (D.Take wipes them after).
-- Inside a render hook, outside the 3D view.
function D.ProbeB2(c)
	if not c or not c.b2 then return false end
	local X0, Y0, X1 = 8, 8, 20
	D.Begin(c, "b")
	for y = Y0 - 1, Y0 + 2 do
		D.Cell(X0 - 1, y, 128, 128, 255, 255)
		D.Cell(X0, y, 62, 62, 255, 255)
		D.Cell(X0 + 1, y, 193, 193, 255, 255)
		D.Cell(X0 + 2, y, 128, 128, 255, 255)
		for x = X1 - 1, X1 + 2 do D.Cell(x, y, 128, 128, 255, 255) end
	end
	D.End()
	SmoothOf(c, "b", X0 - 1 + G, Y0 - 1 + G, X1 + 2 + G, Y0 + 2 + G)
	-- (the two texels of B2 either side of the line between the 62 and the 193, and one in the patch)
	local row = 2 * (Y0 + G) + 1
	render.PushRenderTarget(c.b2)
	render.CapturePixels()
	local ra, ga = render.ReadPixel(2 * (X0 + G) + 1, row)
	local rb, gb = render.ReadPixel(2 * (X0 + G) + 2, row)
	local rf = render.ReadPixel(2 * (X1 + G) + 1, row)
	render.PopRenderTarget()
	if not (ra and ga and rb and gb and rf) then return false end
	local mr, mg = (ra + rb) / 2, (ga + gb) / 2
	return abs(mr - 127.5) <= 3 and abs(mg - 127.5) <= 3 and abs(rf - 128) <= 3, mr, mg, rf
end

-- The targets canvas c has besides A, B and A2, while the parts of phase 19 that use them are on: L
-- (split) and B2 (b2), made once and kept (render targets are never freed). L2 comes and goes with
-- A2 (D.Finer). The first B2 made in the game is probed (D.ProbeB2): where it is not B's byte mean,
-- b2 is off for the session and B is read as before.
function Targets(c)
	if V19.split and not c.l then
		c.l = GetRenderTargetEx("abl_film_l" .. c.id, S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	end
	if not V19.b2 then
		c.b2 = nil
		return
	end
	c.b2kept = c.b2kept or GetRenderTargetEx("abl_film_bf" .. c.id, S2, S2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
	c.b2 = c.b2kept
	if D.b2Probed then return end
	D.b2Probed = true
	local ok, mr, mg, rf = D.ProbeB2(c)
	if not ok then
		-- (the next D.Paint finds the part's switch changed: every canvas is made anew without B2)
		D.b2Bad, V19.b2, c.b2 = true, false, nil
		ABL.Print("film: B2 is not the mean of B's bytes in this build (read %s, %s and %s where 127.5, 127.5 and 128 were due): the liquid's surface is read from B, as before", tostring(mr), tostring(mg), tostring(rf))
	end
end

-- The earlier pictures the lerp moves from: sets of three S x S targets (A, L and B as they were
-- before a painting's step), lent to the canvases that are moved and given back when they no longer
-- are. C.V19.lerpPool sets at the most, each target made when it is first wanted and kept.
local lerpSets = {}
-- (a set is lent out: the per-frame pass looks at the canvases until all are back)
local lerpLive = false
local function SetTake()
	for i = 1, #lerpSets do
		local set = lerpSets[i]
		if not set.busy then return set end
	end
	if #lerpSets >= (C.V19.lerpPool or 12) then return nil end
	local set = { id = #lerpSets + 1 }
	lerpSets[set.id] = set
	return set
end
local function PrevOf(set, which)
	local t = set[which]
	if not t then
		t = GetRenderTargetEx("abl_film_p" .. which .. set.id, S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		set[which] = t
	end
	return t
end
-- (and the material that reads each, made with it, as UpOf's are)
local UPKEY = { a = "ua", l = "ul", b = "ub" }
local function PrevUp(set, which)
	local key = UPKEY[which]
	local up = set[key]
	if not up then
		local kv = { ["$basetexture"] = PrevOf(set, which):GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1 }
		if which == "b" then kv["$gammacolorread"], kv["$linearwrite"] = 1, 1 end
		up = CreateMaterial("abl_film_upp" .. VER .. which .. "_" .. set.id, "UnlitGeneric", kv)
		set[key] = up
	end
	return up
end

-- Target `which` of canvas c as it is, into dst (same size and format). render.CopyTexture where the
-- game has it (no sampling, no gamma); else drawn 1:1 with the target's own material, its edges on
-- the target's edges and nothing moved (D.Smooth's correction, no tap, no K.smoothOff).
local function Copy(c, which, dst)
	local src = c[which]
	if render.CopyTexture then
		render.CopyTexture(src, dst)
		return
	end
	local du = 0.5 / S
	local k = 1 / (1 - 2 * du)
	render.PushRenderTarget(dst)
	cam.Start2D()
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideColorWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	surface.SetMaterial(UpOf(c, which))
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawTexturedRectUV(0, 0, S, S, -du * k, -du * k, (1 - du) * k, (1 - du) * k)
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
	cam.End2D()
	render.PopRenderTarget()
end

-- (the picture the lerp mixes the two in, one S x S target for each kind of target ("a", "l", "b"),
-- shared by all canvases (one is made at a time), with a material made with it: D.Smooth's half
-- texel. B's reads and writes its bytes as they are, as UpOf's does.)
local mixT, mixUp = {}, {}
local function MixOf(which)
	local t = mixT[which]
	if not t then
		t = GetRenderTargetEx("abl_film_mx" .. which, S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		local kv = { ["$basetexture"] = t:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1 }
		if which == "b" then kv["$gammacolorread"], kv["$linearwrite"] = 1, 1 end
		mixUp[which] = CreateMaterial("abl_film_upm" .. VER .. which, "UnlitGeneric", kv)
		mixT[which] = t
	end
	return t, mixUp[which]
end

-- The finer picture of target `which` of canvas c over box (x0, y0) .. (x1, y1), made anew from the
-- target as it was before the step (its set's copy, weight 1 - f) and as it is (f): the two are mixed
-- texel by texel first (MixOf, 1:1 as Copy draws), and the mix is smoothed by D.Smooth's four places
-- (Taps). B's weights are bytes, p and 255 - p: what a texel of B was and is, mixed so, is rounded
-- once, and where it has not changed it comes back as it was, to the byte. A's and L's are light,
-- given as display values, that sum to 1 in light to within a step; their alphas p and 255 - p.
-- (Each picture's four places, eight quads added up, were each rounded on their own:
-- up to 4 steps off in every channel, by an amount that changed with f from frame to frame, a
-- shimmer over all of the box and a highlight that tilted on and off.)
local function Blend8(c, which, f, x0, y0, x1, y1)
	local t, set = FinerOf(c, which), c.lset
	if not t or not set then return end
	local mt, mup = MixOf(which)
	-- (the mix over the box, with as much round it as the four places read: a texel and a half and
	-- more, K.smoothOff)
	local mx0, my0, mx1, my1 = x0 - 6, y0 - 6, x1 + 7, y1 + 7
	if mx0 < 0 then mx0 = 0 end
	if my0 < 0 then my0 = 0 end
	if mx1 > S then mx1 = S end
	if my1 > S then my1 = S end
	local lin = which == "b"
	local p = floor(255 * (1 - f) + 0.5)
	local pc, cc = p, 255 - p
	if not lin then
		pc = floor(255 * (1 - f) ^ (1 / 2.2) + 0.5)
		local rest = 1 - (pc / 255) ^ 2.2
		cc = rest > 0 and floor(255 * rest ^ (1 / 2.2) + 0.5) or 0
	end
	local du = 0.5 / S
	local k = 1 / (1 - 2 * du)
	local u0, u1 = -du * k, (1 - du) * k
	Open2(mt, mx0, my0, mx1, my1)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	surface.SetMaterial(PrevUp(set, which))
	surface.SetDrawColor(pc, pc, pc, p)
	surface.DrawTexturedRectUV(0, 0, S, S, u0, u0, u1, u1)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetMaterial(UpOf(c, which))
	surface.SetDrawColor(cc, cc, cc, 255 - p)
	surface.DrawTexturedRectUV(0, 0, S, S, u0, u0, u1, u1)
	Close2()
	Taps(t, mup, lin, x0, y0, x1, y1)
end

-- (at f: from 1 on what D.Smooth makes, at 0 or before what is there already)
local function LerpBuild(c, which, f, x0, y0, x1, y1)
	if f >= 1 then
		SmoothOf(c, which, x0, y0, x1, y1)
	elseif f > 0 then
		Blend8(c, which, f, x0, y0, x1, y1)
	end
end

-- A canvas's interpolations, one a target: open, the step it was opened at, the box written since
-- (target coordinates), and whether it went without its rebuild in a frame (it then ends at its next).
local FAMS = { "a", "l", "b" }
local function Records(c)
	local lr = c.lr
	if not lr then
		lr = { a = { open = false, step = 0 }, l = { open = false, step = 0 }, b = { open = false, step = 0 } }
		c.lr = lr
	end
	return lr
end

-- Every interpolation of canvas c ends where it is going: its finer pictures are made anew from
-- what the targets hold (f = 1, the smoothing there is without the lerp).
function LerpFinish(c)
	local lr = c.lr
	if lr then
		for i = 1, 3 do
			local w = FAMS[i]
			local rec = lr[w]
			if rec.open then
				rec.open = false
				SmoothOf(c, w, rec.x0, rec.y0, rec.x1, rec.y1)
			end
		end
	end
	c.lrOpen = false
end

-- Canvas c is moved no more and is painted anew or given back: its interpolations go without
-- anything being drawn, and its set of earlier pictures goes back.
function LerpDrop(c)
	local lr = c.lr
	if lr then lr.a.open, lr.l.open, lr.b.open = false, false, false end
	c.lrOpen, c.lstep, c.lrLast = false, nil, nil
	local set = c.lset
	if set then set.busy, c.lset = nil, nil end
end

-- Is canvas cv of film s moved in every frame? Only the films D.FullLook names (s.lerpOK), only a
-- canvas that has finer pictures to make, and only while a set of earlier pictures is to be had for
-- it (lent here and kept while it is moved). The painter may ask before it works out a painting's
-- texels (D.Lerped): a canvas that is moved takes its colour, shine and slope at once, the lerp
-- carries them from one painting to the next.
local function LerpOn(s, cv)
	if not (V19.lerp and s.lerpOK) or not (cv.a2 or cv.l2 or cv.b2) then return false end
	if not cv.lset then
		local set = SetTake()
		if not set then return false end
		set.busy, cv.lset = cv, set
		lerpLive = true
	end
	return true
end
D.Lerped = LerpOn

-- A painting of canvas cv of film s is about to write (PaintMap). At a step of its texels (move) an
-- interpolation still open is ended first (a snap painting ends them and smooths at once, as
-- before); then, for a canvas that is moved, the step opens new ones: each target is kept as it was
-- before its first write (Write), and what is written comes into its finer picture over the time
-- to the next step instead of at once (dur: the time between this canvas's steps, an EMA).
local function LerpBegin(s, cv, move, snap, rt)
	cv.lstep = nil
	if not move then return end
	if cv.lrOpen then LerpFinish(cv) end
	if snap or not LerpOn(s, cv) then return end
	local last = cv.lrLast
	local dur = cv.lrDur or s.paintEv or K.paintEvery
	if last and rt - last < 0.5 then dur = dur + (rt - last - dur) * 0.3 end
	if dur < 1 / 120 then dur = 1 / 120 elseif dur > 0.16 then dur = 0.16 end
	cv.lrLast, cv.lrDur, cv.lrT0 = rt, dur, rt
	cv.lrN = (cv.lrN or 0) + 1
	cv.lstep = true
	Records(cv)
end

-- (in a step that LerpBegin opened: target `which` of canvas cv as it was, into its earlier picture,
-- before the step's first write to it)
local function LerpCopy(cv, which)
	if not FinerOf(cv, which) then return end
	local rec = cv.lr[which]
	if rec.step == cv.lrN then return end
	Copy(cv, which, PrevOf(cv.lset, which))
	rec.step, rec.open, rec.skip = cv.lrN, true, false
	rec.x0, rec.y0, rec.x1, rec.y1 = 1e9, 1e9, -1e9, -1e9
	cv.lrOpen = true
end

-- (after a write to target `which` of canvas cv over box (x0, y0) .. (x1, y1): true when an
-- interpolation of it is open and takes the box in, false when it is to be smoothed at once. A write
-- outside the step that opened it, the waves' (Ripple writes B in place), is made anew at once at
-- the interpolation's own f, which it neither ends nor begins again.)
local function LerpWrote(cv, which, x0, y0, x1, y1)
	local rec = cv.lr and cv.lr[which]
	if not (rec and rec.open) then return false end
	if not (cv.lstep and rec.step == cv.lrN) then LerpBuild(cv, which, (RealTime() - cv.lrT0) / cv.lrDur, x0, y0, x1, y1) end
	if x0 < rec.x0 then rec.x0 = x0 end
	if y0 < rec.y0 then rec.y0 = y0 end
	if x1 > rec.x1 then rec.x1 = x1 end
	if y1 > rec.y1 then rec.y1 = y1 end
	return true
end

-- The highlight's numbers of canvas c from where Materials takes them (C.V19's while the liquid's
-- surface follows its depth, else K's), times how far it has faded at the canvas's distance (fade,
-- 1 where that is not known); its next drawing sets the fade anew (D.Source).
local function Boosts(c)
	local f = V19.fade and c.fadeF or 1
	local surf = V19.surface
	local pb = (surf and C.V19.phongBoost or K.phongBoost) * f
	local rim = (surf and C.V19.rim or K.rim) * f
	c.shine:SetFloat("$phongboost", pb)
	c.shine:SetFloat("$rimlightboost", rim)
	c.lit:SetFloat("$phongboost", pb)
	c.lit:SetFloat("$rimlightboost", rim)
	c.fadeF = nil
end

-- Fade f (0 .. 1) of the near look on canvas c: the highlight and the sky's sheen by f, and the
-- liquid's colour pass by the body's relief (deep) by 1 - f toward the stain's look, how much of the
-- cloth shows and how bright (c.showF, c.gain: Gain), so that where f is 0 it looks as the stain does.
-- (Set by SetFloat and SetVector, no Recompute: the shader reads these at every drawing.)
local fadeV = Vector(1, 1, 1)
function Fade(c, f)
	local surf = V19.surface
	local pb = (surf and C.V19.phongBoost or K.phongBoost) * f
	local rim = (surf and C.V19.rim or K.rim) * f
	c.shine:SetFloat("$phongboost", pb)
	c.shine:SetFloat("$rimlightboost", rim)
	c.lit:SetFloat("$phongboost", pb)
	c.lit:SetFloat("$rimlightboost", rim)
	local d0, e = c.deepF or K.clothShowWas or K.clothShow, 1 - f
	c.deep:SetFloat("$detailblendfactor", d0 + ((c.showF or d0) - d0) * e)
	local dt = (c.deepT or K.deepTint or 1) ^ (1 / 2.2)
	local v = dt + ((c.gain or 1) ^ (1 / 2.2) - dt) * e
	fadeV:SetUnpacked(v, v, v)
	c.deep:SetVector("$color2", fadeV)
	c.fadeF = f
end

-- Whether film s (of source src) is drawn with its near look, with hysteresis: it comes near below
-- C.V19.nearIn of the near distance G and goes above G. And there: how much of its highlight shows
-- (f: 0 where it comes near and where it goes, 1 from C.V19.fadeFrom of G in), and whether its
-- liquid's colour is drawn with the liquid's own surface (liq: below fadeFrom x G, with the same
-- hysteresis) or with the body's (deep, which toward G turns into the stain's look: Fade). G follows
-- the governor's scale eased over about a second, toward 1 for the films nearest the eye (the scale
-- moves by a sixth every half second, and a film at the edge flipped with it). The waves (s.rip)
-- come and go with the same hysteresis at K.rippleDist.
local function Near(s, src, rt)
	local target = s.fullLook and 1 or (ABL.LOD.scale or 1)
	local sc = s.v19scale or target
	local dt = rt - (s.v19scaleT or rt)
	if dt > 0 then sc = sc + (target - sc) * (1 - exp(-dt)) end
	s.v19scale, s.v19scaleT = sc, rt
	local nin, ff = C.V19.nearIn or 0.9, C.V19.fadeFrom or 0.75
	local d = src.dist
	local g = K.glossDist * ABL.LOD.QualityScale() * sc
	local near = D.cvGloss:GetBool() and d < (s.v19near and g or nin * g)
	s.v19near = near
	local r = K.rippleDist * sc
	s.rip = near and d < (s.rip and r or nin * r)
	if not near then
		s.v19liq = false
		return false, 0, false
	end
	local lq = ff * g
	local liq = d < (s.v19liq and lq or nin * lq)
	s.v19liq = liq
	local t = (d - nin * g) / (lq - nin * g)
	t = t < 0 and 0 or (t > 1 and 1 or t)
	return true, t * t * (3 - 2 * t), liq
end

-- What the canvases' materials are made of has changed (a part in D.v19's signature: D.Paint): every
-- canvas gets the targets and the materials of the new state, laid, read finer, dressed and with
-- its highlight's numbers as before (D.Repaint then paints every film anew: the canvases hold
-- another encoding).
local function Rebuild()
	for i = 1, #canvases do
		local c = canvases[i]
		if c.lset or c.lrOpen then LerpDrop(c) end
		Targets(c)
		Materials(c)
		D.Finer(c, smoothNow)
		if c.mp then Lay(c) end
		if not c.free and c.cloth ~= nil then D.Dress(c, c.cloth or nil) end
		Boosts(c)
	end
end

------------------------------------------------------------------------------------------
-- What a cell looks like
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

-- What differs from place to place, drawn out along the flow: the mean of the cell's own number and
-- those of two cells up the flow and two cells down it (the way (ux, uy) of its grid). -1 .. 1.
-- A flow that turns takes this round with it by little: the cells the mean is taken over change
-- one at a time. (Nothing is laid along a direction as a texture would be: where the flow turns
-- there is nothing to rotate.)
local function Streak(s, c, ux, uy)
	local rn = s.rn
	local ax, ay = ux < 0 and -ux or ux, uy < 0 and -uy or uy
	local fwd, back, sideF, sideB, slope
	if ax >= ay then
		if ux > 0 then fwd, back = s.nb2, s.nb1 else fwd, back = s.nb1, s.nb2 end
		if uy > 0 then sideF, sideB = s.nb4, s.nb3 else sideF, sideB = s.nb3, s.nb4 end
		slope = ay / ax
	else
		if uy > 0 then fwd, back = s.nb4, s.nb3 else fwd, back = s.nb3, s.nb4 end
		if ux > 0 then sideF, sideB = s.nb2, s.nb1 else sideF, sideB = s.nb1, s.nb2 end
		slope = ax / ay
	end
	local sum, ws = rn[c] * 0.3, 0.3
	for dir = 1, 2 do
		local along, side = fwd, sideF
		if dir == 2 then along, side = back, sideB end
		local j, e = c, 0
		for k = 1, 2 do
			local n = along[j]
			if n <= 0 then break end
			e = e + slope
			if e >= 0.5 then
				local n2 = side[n]
				if n2 > 0 then n = n2 end
				e = e - 1
			end
			j = n
			local w = k == 1 and 0.22 or 0.13
			sum, ws = sum + rn[j] * w, ws + w
		end
	end
	-- (a mean of five keeps to the middle: spread out again)
	local v = (sum / ws - 0.5) * 3.2
	return v < -1 and -1 or (v > 1 and 1 or v)
end

-- The waves on running liquid. A layer that runs carries low waves that travel the way it runs:
-- at every place its surface tilts along the flow, forward and back as a wave passes. Their
-- phase is how far the blood there has run since it left the wound (s.ds: it grows down the flow
-- whichever way that goes on the body, round every bend and across every seam), less how far the
-- waves have travelled since; their fronts are not ruled lines (every patch of the body is a
-- little out of step with the next); and there are two trains of them, a long slow one and a
-- shorter faster one that counts for more the faster the layer is.
-- Returns the slope the waves give the surface of cell c at time now, along its grid's x and y,
-- and how steep they are there at the most (0, 0, 0: no waves there).
local TWO_PI = 2 * math.pi
local cos = math.cos

-- (Phase 19, waves) The waves carried by the liquid itself. Their phase is the time the blood at the
-- place left the vessel (s.tb: the film's own transfers carry it, weighted by how much of each blood
-- there is), so a crest is a line of liquid that moves as the liquid does and stops where it stops,
-- and neighbours keep in step: the phase a cell summed up from its own speed (wp) went out of step
-- with the cell beside it by a wave and more in a minute. C.V19.waveHz crests a second of each train
-- pass a place where the liquid runs; a little of the cloth's patches (mt) keeps the fronts from being
-- ruled lines. A train whose crests lie closer than C.V19.waveMinCells cells (1 / (waveHz x the
-- steepest change of tb to a wet neighbour)) is not on the grid and fades out: where fresh blood runs
-- into older, tb changes by many seconds from one cell to the next, and the train there was noise
-- from cell to cell. As steep as C.V19.waveTilt at the most. (The arguments as Wave has them.)
-- (C.V19.waveAcross: a crest is one line across a run. Its phase is the time of the youngest liquid
-- that runs beside the cell across the flow, the cell's own included (the run's core, which leads),
-- and what fades a train is how tb changes along the flow alone. Across a run its core and its flanks
-- differ in tb by 0.2 to 0.7 s (a chest at 2 ml/s): every crest of a train faster than about 0.3 Hz
-- broke into one a column, and the gate, the steepest change of tb to any wet neighbour, turned it
-- off on most cells. At 0.14 and 0.24 crests a second, which the gate let through, the crests lay 210
-- to 450 rows apart on a run 55 rows long, and the whole run tilted at once. Measured on the bench,
-- the liquid's shading 8 rows apart correlated in time (male_06, 2 ml/s): 0.79 at once and 0.80 four
-- frames later, before; with waveAcross and 1.0 and 1.6 crests a second, 0.19 at once and 0.69 four
-- frames later, 60 rows a second, the liquid's own speed (female_03: 0.31 and 0.77; at 0.5 ml/s 0.54
-- twelve frames later, 20 rows a second); the same crests without waveAcross 0.07, and 0.12 at best:
-- noise. 2026-10-17.)
local WAVEHZ = { 1.0, 1.6 }
-- (waveAcross for this painting: PaintMap and Ripple set it from D.v19)
local waveAcross = false
-- (the larger of g and how far tb of cell n is from t0, where n is a cell that holds liquid: a dry
-- one's tb is the time of no blood that is there)
local function TbStep(s, n, t0, g)
	if n and n > 0 and s.h[n] + s.k[n] > 0 then
		local e = s.tb[n] - t0
		if e < 0 then e = -e end
		if e > g then return e end
	end
	return g
end
local function WaveTb(s, c, v, ux, uy, ul, dw)
	local kw = (C.V19.waveTilt or 0.10) * (v >= K.rippleFull and 1 or v / K.rippleFull) * (dw >= 0.012 and 1 or dw / 0.012)
	if kw <= 0 then return 0, 0, 0 end
	local hz = C.V19.waveHz or WAVEHZ
	local t0 = s.tb[c]
	local g
	if waveAcross then
		-- (across the flow: the grid's y where it runs more along x, else x; along it the other two)
		local hh, kk, tb, sp = s.h, s.k, s.tb, s.sp
		local ax, ay = ux < 0 and -ux or ux, uy < 0 and -uy or uy
		local n1, n2, f1, f2
		if ax >= ay then n1, n2, f1, f2 = s.nb3[c], s.nb4[c], s.nb1[c], s.nb2[c] else n1, n2, f1, f2 = s.nb1[c], s.nb2[c], s.nb3[c], s.nb4[c] end
		local tp = t0
		if n1 and n1 > 0 and hh[n1] + kk[n1] > 0 and sp[n1] > 0 and tb[n1] > tp then tp = tb[n1] end
		if n2 and n2 > 0 and hh[n2] + kk[n2] > 0 and sp[n2] > 0 and tb[n2] > tp then tp = tb[n2] end
		g = TbStep(s, f1, t0, 0)
		g = TbStep(s, f2, t0, g)
		t0 = tp
	else
		g = TbStep(s, s.nb1[c], t0, 0)
		g = TbStep(s, s.nb2[c], t0, g)
		g = TbStep(s, s.nb3[c], t0, g)
		g = TbStep(s, s.nb4[c], t0, g)
	end
	local f = v / (K.rippleFull * 2)
	if f > 1 then f = 1 end
	local a1, a2 = 0.7 - 0.3 * f, 0.3 + 0.3 * f
	if g > 0 then
		local least = C.V19.waveMinCells or 4
		local e1 = (1 / (hz[1] * g) - least) / 3
		local e2 = (1 / (hz[2] * g) - least) / 3
		a1 = a1 * (e1 < 0 and 0 or (e1 > 1 and 1 or e1))
		a2 = a2 * (e2 < 0 and 0 or (e2 > 1 and 1 or e2))
	end
	local p = 0.27 * (s.mt[c] or 0.5)
	local t = kw * (a1 * cos(TWO_PI * (hz[1] * t0 + p)) + a2 * cos(TWO_PI * (hz[2] * t0 + p) + 2.1)) / sqrt(ul)
	return t * ux, t * uy, kw
end

local function Wave(s, c, now)
	local v = s.sp[c]
	if v <= 0 then return 0, 0, 0 end
	local ux, uy = s.dx[c], s.dy[c]
	local ul = ux * ux + uy * uy
	if ul < 0.04 then return 0, 0, 0 end
	-- (as steep as the layer is fast, and no steeper than it is deep)
	local dw = s.h[c] + s.k[c]
	-- (phase 19: carried by the liquid, WaveTb)
	if V19.waves then return WaveTb(s, c, v, ux, uy, ul, dw) end
	local kw = K.rippleTilt * (v >= K.rippleFull and 1 or v / K.rippleFull) * (dw >= 0.012 and 1 or dw / 0.012)
	if kw <= 0 then return 0, 0, 0 end
	local d = s.ds[c] + 2.4 * s.mt[c]
	local L, R = K.rippleLen, K.rippleRun
	local f = v / (K.rippleFull * 2)
	if f > 1 then f = 1 end
	-- How far the waves have travelled: by how far the liquid there has run, at a pace of their own
	-- relative to it (K.rippleWith: waves on a running layer travel a little faster than the layer).
	-- They ran on a clock at one and 1.8 cells a second whatever the liquid did: on a slow run they
	-- slid down it faster than the blood went, and they stood still on none. Now a layer that
	-- slows takes its waves down with it, and where it stops they stop. (K.rippleWith nil or
	-- false: by the clock, as before.)
	local rw = K.rippleWith
	local p1, p2
	if rw then
		local wp = s.wp[c] or 0
		p1, p2 = wp * rw[1], wp * rw[2]
	else
		p1, p2 = now * R[1], now * R[2]
	end
	local t = kw * ((0.7 - 0.3 * f) * cos(TWO_PI * (d - p1) / L[1]) + (0.3 + 0.3 * f) * cos(TWO_PI * (d - p2) / L[2] + 2.1)) / sqrt(ul)
	return t * ux, t * uy, kw
end

-- (kept in a table of their own, s.look: the film has arrays of its own by some of these names.
-- The last three are phase 19's, Look says what they are.)
local LOOKS = { "va", "vw", "vh", "vr", "vg", "vb", "vl", "wx", "wy", "vk", "vH", "vt", "vp" }

-- (phase 19: what the painter asks Look for in this painting, set by PaintMap from D.v19: the
-- liquid's height and share for its surface and its feather (vH, vt), its colour by its own depth
-- (depthTone) and the film swollen where blood waits to drop (vp, pendPaint))
local lookH, lookTone, lookPend = false, false, false
local ML = C.ML_PER_CU
-- (Phase 19, pendPaint) How much higher the film stands at cell c for the blood that waits there to
-- drop (s.out, ml), units, C.V19.pendMaxDepth at the most. It is not on the film's books as a layer
-- (it has left its cells): drawn only.
local function Pend(s, c)
	local o = s.out[c]
	if not o or o <= 0 then return 0 end
	local d = o / (ML * s.ar[c])
	local most = C.V19.pendMaxDepth or 0.04
	return d < most and d or most
end
-- (the liquid's height on cell n as the film holds it right now, with that swelling: 0 where there is
-- no cell, where the liquid ends)
local function HeightAt(s, n)
	if not n or n <= 0 then return 0 end
	local d = s.h[n] + s.k[n]
	if lookPend then d = d + Pend(s, n) end
	return d
end

-- What cell c of film s looks like at time now, kept with the cell (its texel and the texels round
-- it are made of it, PaintMap):
--   va  whether blood lies there (0 .. 1)
--   vl  how much of a layer of blood stands on the place (0 .. 1): the liquid's own outline
--   vr, vg, vb  its colour (0..255, before light): by how much blood is at the place, from a film's
--       over a layer's to the deepest, fresh and dried, mixed by how wet it still is; by the patch
--       of the body it lies on; drawn out along the flow where blood has run; and darker the longer
--       the blood has been out of the vessel
--   vw  how much it shines: liquid standing on it in full, cloth full of fresh blood less, dried
--       blood hardly
--   vh  how high its surface stands (units): the liquid on it, what has dried there, a little for
--       cloth swollen with blood, and the ridges of its streaks
--   wx, wy  the slope its waves give its surface right now (vk: how steep they are at the most)
-- Phase 19 (only while the painter asks for them: lookH, lookPend):
--   vH  how high the liquid's surface stands (units): its depth, smoothed with the four cells beside
--       it as the film holds them right now (half its own, an eighth each), 0 where there is no cell
--   vt  how much of a layer of liquid stands on the place, without what an opening counts for more
--       (vl is that times K.openCover there): the surface's rim follows the liquid, not the opening
--   vp  how much higher the film stands for the blood that waits there to drop (Pend)
local function Look(s, c, now)
	local cov, sat, dw, dd, wet = FM.Look(s, c, now)
	local lk = s.look
	-- A place blood comes out at (a wound's opening: cl_film.lua, Inflow) counts for more than its
	-- share: the film's outline lies round all of the opening, a little way out, and not through
	-- the middle of it. What is seen in the wound is then its own blood (cl_woundfx.lua), with no
	-- dry sliver of skin between the hole and the blood below it.
	local oc = cov > 0 and s.opn[c] and K.openCover or 1
	cov = cov * oc
	lk.va[c] = cov
	if cov <= 0 then
		lk.vw[c], lk.vh[c], lk.vl[c], lk.wx[c], lk.wy[c], lk.vk[c] = 0, 0, 0, 0, 0, 0
		if lookH then lk.vH[c], lk.vt[c] = 0, 0 end
		if lookPend then lk.vp[c] = 0 end
		return
	end
	-- (phase 19, pendPaint: blood that waits at the place to drop swells the film there: its colour,
	-- its liquid's outline and its surface count it, its shine does not. The books are the film's.)
	local dwc = dw
	if lookPend then
		local pe = Pend(s, c)
		lk.vp[c] = pe
		dwc = dw + pe
	end
	local soak = s.ab[c]
	local layered = layeredNow
	-- (cloth that is full of blood is as dark with it as a layer of blood is: only where it has taken
	-- up little, at the rim of a stain, is it the lighter red of a thin film. Counted for less, the
	-- way one layer was drawn, all soaked cloth was that lighter red, and round a run of liquid it
	-- was a bright band: an outline.)
	local deep
	if layered then
		if lookTone then
			-- (Phase 19, depthTone) What the place's own blood gives (in the cloth and dried there) is
			-- darkened by the liquid that stands on it, by its own depth and ever less for each more of
			-- it: 1 - e^(-depth / C.V19.deepScale) of the way to the deepest colour. As the sum of the
			-- two, clamped, liquid on soaked cloth was the deepest colour all over from 0.7 mm on, and
			-- how deep a run stood did not show in it.
			local dS = (0.6 * dd + K.soakDeep * soak) / K.deepRef
			if dS > 1 then dS = 1 end
			deep = 1 - (1 - dS) * exp(-dwc / (C.V19.deepScale or 0.02))
		else
			deep = dwc / K.deepLiquid + (0.6 * dd + K.soakDeep * soak) / K.deepRef
		end
	else
		deep = (dwc + 0.6 * dd + 0.45 * soak) / K.deepRef
	end
	if deep > 1 then deep = 1 end
	local wr, wg, wb = Mix3(P.wetThin, P.wetBody, layered and P.wetDeep or (P.wetDeepOld or P.wetDeep), deep)
	local dr, dg, db = Mix3(P.dryThin, P.dryBody, P.dryDeep, deep)
	local m = 1 + K.mottle * (2 * (s.mt[c] or 0.5) - 1)
	local h0 = dw + 0.5 * dd + 0.15 * soak
	local top = 0
	if layered then
		-- How much of a layer of liquid the place counts for: nothing below a trace, and from there
		-- the more the deeper the layer stands. The liquid's outline lies where half of a texel's
		-- surroundings are liquid, so it lies further out round deep blood than round a thin run:
		-- a trickle is a narrow bead and a full run a broad one, its width follows its depth from
		-- place to place and not the grid's cells, and a layer that drains draws in.
		if dwc > K.topLo then
			if dwc < K.topHi then
				local t = (dwc - K.topLo) / (K.topHi - K.topLo)
				top = K.liqThin * t * t * (3 - 2 * t)
			else
				local t = (dwc - K.topHi) / (K.liqDeep - K.topHi)
				top = K.liqThin + (K.liqFull - K.liqThin) * (t > 1 and 1 or t)
			end
		end
		-- (phase 19, depthTone: the cloth's patches show in the stain, less of them through a layer of
		-- liquid that stands on it: it hides the cloth it lies on, and its depth is what shows there)
		if lookTone then
			local w = top / K.liqThin
			m = m - K.mottle * (C.V19.mottleLiquid or 0.6) * (w > 1 and 1 or w) * (2 * (s.mt[c] or 0.5) - 1)
		end
		local ux, uy = s.dx[c], s.dy[c]
		if ux * ux + uy * uy > 0.04 then
			local st = Streak(s, c, ux, uy)
			local on = dw + dd
			on = on >= 0.012 and 1 or on / 0.012
			m = m + K.streak * st * on
			h0 = h0 + K.streakH * st * on
		end
		if dw > 0 then
			local age = (now - s.tb[c]) / (KF.clotTime * C.sv.drying:GetFloat())
			m = m * (1 - K.ageTone * (age < 0 and 0 or (age > 1 and 1 or age)))
		end
	end
	lk.vr[c], lk.vg[c], lk.vb[c] = (dr + (wr - dr) * wet) * m, (dg + (wg - dg) * wet) * m, (db + (wb - db) * wet) * m
	local shine = dw / K.wetRef
	if shine > 1 then shine = 1 end
	shine = shine * (0.35 + 0.65 * wet)
	local ss = K.soakShine * sat * wet
	if ss > shine then shine = ss end
	lk.vw[c] = shine > K.dryShine and shine or K.dryShine
	lk.vl[c] = top * oc
	lk.vh[c] = h0
	if layered and s.rip then
		lk.wx[c], lk.wy[c], lk.vk[c] = Wave(s, c, now)
	else
		lk.wx[c], lk.wy[c], lk.vk[c] = 0, 0, 0
	end
	-- (phase 19: the liquid's height, smoothed with its four neighbours as they are now, and its share
	-- without the opening's: vH, vt)
	if lookH then
		lk.vH[c] = 0.5 * dwc + 0.125 * (HeightAt(s, s.nb1[c]) + HeightAt(s, s.nb2[c]) + HeightAt(s, s.nb3[c]) + HeightAt(s, s.nb4[c]))
		lk.vt[c] = top
	end
end

------------------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------------------
-- A texel is the weighted mean of its own cell and the eight round it (4 : 2 : 1 over 16).
local BX = { 0, -1, 1, 0, 0, -1, 1, -1, 1 }
local BY = { 0, 0, 0, -1, 1, -1, -1, 1, 1 }
local BW = { 4, 2, 2, 2, 2, 1, 1, 1, 1 }
-- (how its surface rises along the grid's x and y there, by the same nine: a Sobel gradient)
local GXW = { 0, -2, 2, 0, 0, -1, 1, -1, 1 }
local GYW = { 0, 0, 0, -2, 2, -1, -1, 1, 1 }
-- (how much more than its share a cell with blood counts toward the cover of the texels round it:
-- with 1, a row of cells one cell wide would only just reach the outline's value in its own texels)
local GAIN = 1.5
-- scratch: the texels written in one go, to A (x, y, r, g, b, a) and to B (x, y, nx, ny, nz, w)
local WA = { {}, {}, {}, {}, {}, {} }
local WB = { {}, {}, {}, {}, {}, {} }
-- (phase 19, split: and to L (x, y, r, g, b, a: the liquid's own outline in its alpha), written after A's)
local WL = { {}, {}, {}, {}, {}, {} }
local mark, mlist = {}, {}
local byMap = {}

-- Does cell q of map mp (its index, from 0) lie at the rim of the map: is one of the eight places
-- round it no place of the body? (Asked once per cell.)
local function AtRim(mp, q)
	local e = mp.rim
	if not e then
		e = {}
		mp.rim = e
	end
	local v = e[q]
	if v ~= nil then return v end
	local W, H, tri = mp.W, mp.H, mp.tri
	local x = q % W
	local y = (q - x) / W
	v = false
	for t = 2, 9 do
		local xx, yy = x + BX[t], y + BY[t]
		if xx < 0 or yy < 0 or xx >= W or yy >= H or tri[yy * W + xx + 1] == 0 then v = true break end
	end
	e[q] = v
	return v
end

-- What is shown of one map of a film, texel by texel (by the cell's index): what each texel is to
-- show (what its cells are: g..), how much of it is blood (sc) and how much liquid on that (sl)
-- right now on their way there, what was last written of it (k1, k2), the lumps of its surface (lx,
-- ly: fixed to the place), the slope of the liquid's body there (bx, by) and the slope its waves give
-- it right now (wx, wy), the texels that have not arrived yet, and how many texels lie inside the
-- liquid's outline (liq).
-- (gen: a number of its own, for what has been painted into it: PaintMap, K.paintSkip)
local texGen = 0
local function NewTexels()
	texGen = texGen + 1
	return { sc = {}, sl = {}, gsc = {}, gsl = {}, gw = {}, gr = {}, gg = {}, gb = {}, gsx = {}, gsy = {}, lx = {}, ly = {}, bx = {}, by = {}, en = {}, el = {},
		wx = {}, wy = {}, k1 = {}, k2 = {}, an = {}, ain = {}, na = 0, liq = 0, t = nil, snap = true, gen = texGen }
end

-- The film's cell across the rim of map mp from cell (x, y), one cell further along (dx, dy): where
-- the surface goes on there (cl_filmchart.lua, CH.Link). false: it goes on, and the film has no
-- cell there; nil: it ends.
local function Across(s, mp, x, y, dx, dy)
	local mp2, x2, y2 = CH.Link(s.ch, mp, x, y, dx, dy)
	if not mp2 then return nil end
	return s.lut[mp2.k][y2 * mp2.W + x2] or false
end

-- (a number of its own for every texel of every map, 0 .. 1: what is fixed to a place of the body
-- and to nothing else)
local function Fixed(q, k, n)
	local v = sin(q * 12.9898 + k * 78.233 + n * 37.719) * 43758.5453
	return v - floor(v)
end

-- (the same, even from one texel to the next and different from one handful of texels to the next:
-- the lumps of a wet surface, not its grain)
local function Lumpy(x, y, k, n)
	local fx, fy = x / 3, y / 3
	local ix, iy = floor(fx), floor(fy)
	fx, fy = fx - ix, fy - iy
	fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	local a, b = Fixed(ix + iy * 911, k, n), Fixed(ix + 1 + iy * 911, k, n)
	local c, d = Fixed(ix + (iy + 1) * 911, k, n), Fixed(ix + 1 + (iy + 1) * 911, k, n)
	return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
end

-- What B is to hold for a surface of slope (ax, ay) that shines w: its normal (along the texture's
-- x and y, and out of it) and its shine, as bytes, and the number that stands for all four.
-- (A level sheet of liquid mirrors a lamp as one pale patch: what shows the lamp on blood is where
-- its surface turns, at its rims, its ridges, its lumps and its waves.)
local shineRef, flatRef = 0.1, 0.1
local function Surface(ax, ay, w)
	local nl = 1 / sqrt(1 + ax * ax + ay * ay)
	local nx8, ny8, nz8 = floor(127.5 - 127 * ax * nl + 0.5), floor(127.5 - 127 * ay * nl + 0.5), floor(127.5 + 127 * nl + 0.5)
	local turn = (ax * ax + ay * ay) / (shineRef * shineRef)
	if turn < 1 then w = w * (flatRef + (1 - flatRef) * turn) end
	local w8 = floor(w * 255 + 0.5)
	if w8 > 255 then w8 = 255 end
	return nx8, ny8, nz8, w8, (floor(nx8 / 2) * 128 + floor(ny8 / 2)) * 32 + floor(w8 / 8)
end

-- (Phase 19, surface) What B is to hold for a texel that shows a surface of slope (sx, sy) and shines
-- w, with waves (wx, wy) on it right now: the one rule by which the painter (PaintMap) and the waves
-- (Ripple) both write B, so that the one does not undo what the other wrote. The slope is saturated
-- softly at C.V19.slopeSoft (s / sqrt(1 + (|s| / slopeSoft)^2): no plateau, no crease where a clamp
-- began). How much it shines goes by the surface without its waves, from C.V19.flatShine where it is
-- level to all of it at K.shineSlope (smoothly): the waves bend the highlight, they do not switch it
-- on and off. Returns what Surface returns (its shine in the number to four steps).
local encK, encFlat, encRef = 1 / 0.36, 0.04, 0.35
local function EncodeSet()
	local soft = C.V19.slopeSoft or 0.6
	encK = 1 / (soft * soft)
	encFlat = C.V19.flatShine or K.flatShine
	encRef = K.shineSlope
end
local function Encode(sx, sy, wx, wy, w)
	local l2 = sx * sx + sy * sy
	local t = sqrt(l2 / (1 + l2 * encK)) / encRef
	if t < 1 then w = w * (encFlat + (1 - encFlat) * t * t * (3 - 2 * t)) end
	local ax, ay = sx + wx, sy + wy
	local k = 1 / sqrt(1 + (ax * ax + ay * ay) * encK)
	ax, ay = ax * k, ay * k
	local nl = 1 / sqrt(1 + ax * ax + ay * ay)
	local nx8, ny8, nz8 = floor(127.5 - 127 * ax * nl + 0.5), floor(127.5 - 127 * ay * nl + 0.5), floor(127.5 + 127 * nl + 0.5)
	local w8 = floor(w * 255 + 0.5)
	if w8 > 255 then w8 = 255 elseif w8 < 0 then w8 = 0 end
	return nx8, ny8, nz8, w8, (floor(nx8 / 2) * 128 + floor(ny8 / 2)) * 64 + floor(w8 / 4)
end

-- (Phase 19, ease) Texel q of tx shows the colour (tx.cr, cg, cb), the shine (cw) and the surface's
-- slope (csx, csy) it last did: each comes a step ek toward its target (gr .. sy) when its target
-- is further from it than shows (0.6 of a step of colour, 0.008 of shine, 0.004 of slope), and is
-- there once it is as near as 0.75, 0.01 and 0.01. Returns what it shows now, and whether any of it
-- is still on its way. (They were written at once, at 8 to 15 paintings a second, while the outline
-- came over a moment: colour, highlight and rim jumped while the outline moved.)
local function EaseStep(tx, q, gr, gg, gb, gw, sx, sy, ek)
	local far = false
	local pr, pg, pb = tx.cr[q], tx.cg[q], tx.cb[q]
	if pr and pg and pb then
		local dr, dg, db = gr - pr, gg - pg, gb - pb
		if abs(dr) > 0.6 or abs(dg) > 0.6 or abs(db) > 0.6 then
			local r1, g1, b1 = pr + dr * ek, pg + dg * ek, pb + db * ek
			if abs(gr - r1) > 0.75 or abs(gg - g1) > 0.75 or abs(gb - b1) > 0.75 then gr, gg, gb, far = r1, g1, b1, true end
		end
	end
	local pw = tx.cw[q]
	if pw then
		local dw = gw - pw
		if abs(dw) > 0.008 then
			local w1 = pw + dw * ek
			if abs(gw - w1) > 0.01 then gw, far = w1, true end
		end
	end
	local px, py = tx.csx[q], tx.csy[q]
	if px and py then
		local dx, dy = sx - px, sy - py
		if abs(dx) > 0.004 or abs(dy) > 0.004 then
			local x1, y1 = px + dx * ek, py + dy * ek
			if abs(sx - x1) > 0.01 or abs(sy - y1) > 0.01 then sx, sy, far = x1, y1, true end
		end
	end
	return gr, gg, gb, gw, sx, sy, far
end

-- (Phase 19, feather) The colour (r, g, b) of a texel whose film's share is v, where blood stands d
-- deep on average round it, turned toward e (the canvas's c.edge: Edge) at the film's outline: by
-- C.V19.featherAmt x (1 - s)^1.5 with s = smoothstep(OUT, OUT + featherW, v), nothing inside the
-- film, and less the deeper the blood stands there (none from K.topHi on): a run of liquid on skin
-- keeps its own colour to its cut, the thin margin of a stain thins out to the colour of what it lies
-- on. (A film of one colour up to an alpha-tested cut was a painted outline.)
local function Feather(e, v, d, r, g, b)
	local t = (v - OUT) / (C.V19.featherW or 0.25)
	if t >= 1 then return r, g, b end
	local k = d / K.topHi
	if k >= 1 then return r, g, b end
	if k < 0 then k = 0 end
	if t < 0 then t = 0 end
	t = 1 - t * t * (3 - 2 * t)
	k = (C.V19.featherAmt or 0.85) * (1 - k) * t * sqrt(t)
	if k > 1 then k = 1 end
	return r + (e[1] - r) * k, g + (e[2] - g) * k, b + (e[3] - b) * k
end

-- (the texels in WA or WB, n of them, into target `which` of canvas cv. B's numbers are no colour,
-- but they go the same way in as A's: D.Cell sees to it that what is stored is what was given.
-- Phase 19: WL into "l", where the canvas has an L.)
local function Write(cv, which, W6, n)
	if which == "l" and not cv.l then return end
	-- (phase 19, lerp: at a step of a canvas that is moved, the target is kept as it was before it is written)
	if cv.lstep then LerpCopy(cv, which) end
	local Cell = D.Cell
	local X, Y, R, Gr, B, A = W6[1], W6[2], W6[3], W6[4], W6[5], W6[6]
	D.Begin(cv, which)
	for i = 1, n do Cell(X[i], Y[i], R[i], Gr[i], B[i], A[i]) end
	D.End()
	-- (what the body's materials read of A is made anew where A has changed: D.Smooth. Phase 19: L2 of
	-- L and B2 of B the same way (SmoothOf), and on a canvas that is moved, over the time to its next
	-- step: LerpWrote)
	if (which == "a" and cv.a2) or (which == "l" and cv.l2) or (which == "b" and cv.b2) then
		local x0, x1, y0, y1 = X[1], X[1], Y[1], Y[1]
		for i = 2, n do
			local x, y = X[i], Y[i]
			if x < x0 then x0 = x elseif x > x1 then x1 = x end
			if y < y0 then y0 = y elseif y > y1 then y1 = y end
		end
		if not (cv.lrOpen and LerpWrote(cv, which, x0 + G, y0 + G, x1 + G, y1 + G)) then
			if which == "a" then D.Smooth(cv, x0 + G, y0 + G, x1 + G, y1 + G) else SmoothOf(cv, which, x0 + G, y0 + G, x1 + G, y1 + G) end
		end
	end
end

-- (phase 19, ease: how many more texels may be on their way for their colour, shine or surface alone
-- in this painting of one film, C.V19.easeMax: PaintFilm sets it, PaintMap counts it down)
local easeLeft = 0

-- Map mp of film s into canvas cv: the texels of the cells in list (cells whose state has changed)
-- and round them, and the texels still on their way to what their cells have become. Returns the
-- texels looked at.
local function PaintMap(s, mp, cv, tx, list, n, now, rt)
	local W, H, tri = mp.W, mp.H, mp.tri
	local mk = mp.k
	local lut = s.lut[mk]
	local ci = s.ci
	local lk = s.look
	local va, vw, vh, vr, vg, vb, vl, vwx, vwy, vk = lk.va, lk.vw, lk.vh, lk.vr, lk.vg, lk.vb, lk.vl, lk.wx, lk.wy, lk.vk
	local twx, twy = tx.wx, tx.wy
	local tsc, tsl, k1, k2, an = tx.sc, tx.sl, tx.k1, tx.k2, tx.an
	local qsc, qsl, qw, qr, qg, qb, qsx, qsy = tx.gsc, tx.gsl, tx.gw, tx.gr, tx.gg, tx.gb, tx.gsx, tx.gsy
	local tlx, tly, tbx, tby = tx.lx, tx.ly, tx.bx, tx.by
	local ten, tel = tx.en, tx.el
	local layered = layeredNow
	-- (from what tilt on a place shines in full, and how much a level one does: as one layer, the way
	-- it was, from a slight tilt, and a tenth)
	shineRef, flatRef = layered and K.shineSlope or 0.1, layered and K.flatShine or 0.1
	-- (phase 19, D.v19: its parts that paint, as they are this frame. surf: the liquid's surface from
	-- its depth; feath: the film thins out at its outline; both read the liquid's height (vH); eOn:
	-- colour, shine and surface ease; splitW: A holds the film's outline alone, and L (written where
	-- the canvas has it, as two layers) the liquid's)
	local v19 = V19
	local surf = v19.surface and layered
	local feath = v19.feather and layered
	local useH = surf or feath
	local eOn = v19.ease
	local splitW = v19.split and cv.l ~= nil
	local splitL = splitW and layered
	lookH, lookTone, lookPend = useH, v19.depthTone and layered, v19.pendPaint
	-- (and how the waves' crests lie across a run, WaveTb)
	waveAcross = v19.waveAcross
	local vHa, vta, vpa = lk.vH, lk.vt, lk.vp
	-- (pendPaint: the texels round a cell whose blood has just dropped take what it shows at once, as
	-- the drop is gone at once; set here, taken in the step that writes them)
	local qk = tx.qk
	if lookPend and not qk then
		qk = {}
		tx.qk = qk
	end
	if surf then EncodeSet() end
	-- (1: its cells have changed, what it is to show is made anew; 2: only on its way)
	local mn = 0
	-- (what each cell was last painted with into this canvas, K.paintSkip: tx.gen)
	local pg = lk.pg
	if not pg then pg = {} lk.pg = pg end
	local gen = tx.gen
	local skip = (K.paintSkip or 0) ~= 0
	for i = 1, n do
		local c = list[i]
		local a0, h0, l0 = va[c] or 0, vh[c] or 0, vl[c] or 0
		local r0, g0, b0, w0, x0, y0 = vr[c], vg[c], vb[c], vw[c], vwx[c], vwy[c]
		-- (phase 19: its liquid's height and share as they were, and what waited there to drop)
		local H0, t0, p0 = 0, 0, nil
		if useH then H0, t0 = vHa[c] or 0, vta[c] or 0 end
		if lookPend then p0 = vpa[c] end
		Look(s, c, now)
		-- (pendPaint: less waits there than when it was last looked at: a drop has left)
		local dropped = p0 ~= nil and (vpa[c] or 0) < p0 - 1e-5
		local q0 = ci[c]
		local x = q0 % W
		local y = (q0 - x) / W
		-- A cell asked to be painted again whose look has not changed, by less than a step of colour
		-- or of its outline, and that was painted into this canvas with what it shows now: its nine
		-- texels are what they would be made anew. A cell where blood runs, soaks or dries is asked
		-- for every second or so whether anything shows of it or not, and in a film that had bled
		-- for two minutes most of them changed by nothing that shows: their texels cost three
		-- milliseconds a painting (nine looked at a cell, nine taps each). (K.paintSkip 0: all of
		-- them, as before.)
		local same = skip and pg[c] == gen and r0 ~= nil
			and abs(va[c] - a0) < 0.004 and abs(vl[c] - l0) < 0.01 and abs(vh[c] - h0) < 0.0003
			and abs(vr[c] - r0) < 0.6 and abs(vg[c] - g0) < 0.6 and abs(vb[c] - b0) < 0.6 and abs(vw[c] - w0) < 0.008
			and abs((vwx[c] or 0) - (x0 or 0)) < 0.004 and abs((vwy[c] or 0) - (y0 or 0)) < 0.004
			-- (phase 19: and its liquid's height and share, as the surface and the feather read them)
			and (not useH or (abs(vHa[c] - H0) < 0.0003 and abs(vta[c] - t0) < 0.01))
		if same then
			-- (what it was painted with stays what it is measured against: drift by small steps adds up)
			va[c], vh[c], vl[c], vr[c], vg[c], vb[c], vw[c], vwx[c], vwy[c] = a0, h0, l0, r0, g0, b0, w0, x0, y0
			if useH then vHa[c], vta[c] = H0, t0 end
			if lookPend then vpa[c] = p0 end
			D.stats.skipped = (D.stats.skipped or 0) + 1
		else
			pg[c] = gen
		end
		-- (a cell at the rim of its map that has changed: the texels across the seam are made of it too)
		local over = not same and AtRim(mp, q0) and (abs(va[c] - a0) > 0.02 or abs(vh[c] - h0) > 0.002 or abs(vl[c] - l0) > 0.05)
		for t = 1, (same and 0 or 9) do
			local xx, yy = x + BX[t], y + BY[t]
			local q = (xx >= 0 and yy >= 0 and xx < W and yy < H) and yy * W + xx or -1
			if q >= 0 and tri[q + 1] > 0 then
				if not mark[q] then
					mark[q] = 1
					mn = mn + 1
					mlist[mn] = q
				end
				if dropped then qk[q] = true end
			elseif over then
				local c2 = Across(s, mp, x, y, BX[t], BY[t])
				if c2 then FM.Touch(s, c2) end
			end
		end
	end
	-- The texels on their way come a step nearer every K.paintEvery seconds, not at every painting
	-- (a film with much to paint is painted at every frame): between two such steps, texels whose
	-- cells have changed are only told what they are to become.
	local snap = tx.snap
	local ain = tx.ain
	local na0 = tx.na
	local move = snap or not tx.t or rt - tx.t >= (s.paintEv or K.paintEvery) - 0.004
	local ek = 1
	if move then
		for i = 1, na0 do
			local q = an[i]
			an[i], ain[q] = nil, nil
			if not mark[q] then
				mark[q] = 2
				mn = mn + 1
				mlist[mn] = q
			end
		end
		-- How far a texel comes in this step: all the way while the canvas is new (a body that
		-- comes into view is there as it is), else by the time that has passed since the last one.
		-- (no further in one step than in a sixth of a second, however long the film waited: an
		-- outline that has stood still sets out, it does not leap)
		local dt = tx.t and rt - tx.t or 0
		tx.t = rt
		if dt > 0.16 then dt = 0.16 end
		if not snap then ek = 1 - exp(-dt / K.ease) end
	end
	-- (as two layers the liquid's body is drawn by its own rule, below: what its depth adds to that
	-- from place to place counts for less than where the depth was all there was)
	local kRel = (layered and K.reliefLiquid or K.relief) / mp.cell / 8
	local relMax = K.reliefMax
	local kBead, beadMax = layered and K.bead / 8 or 0, K.beadMax
	local rimGrow, rimMax = layered and (K.rimGrow or 0) or 0, K.rimMax or 1
	local edgeN, glint, grainTone = K.edgeNoise, K.glint, K.grainTone
	local stats = D.stats
	local AX, AY, AR, AG, AB, AA = WA[1], WA[2], WA[3], WA[4], WA[5], WA[6]
	local PX, PY, PR, PG, PB, PA = WB[1], WB[2], WB[3], WB[4], WB[5], WB[6]
	local ma, mb, na = 0, 0, move and 0 or na0
	-- (phase 19, split: the texels for L, in WL)
	local ml = 0
	local LX, LY, LR, LG, LB, LA = WL[1], WL[2], WL[3], WL[4], WL[5], WL[6]
	local k3 = tx.k3
	if splitL and not k3 then
		k3 = {}
		tx.k3 = k3
	end
	-- (phase 19, surface: how steep the liquid's depth makes its surface, per unit of height across a
	-- cell, and the share of the lumps it keeps)
	local kH = surf and (C.V19.depthGain or 1.5) / (8 * mp.cell) or 0
	local rimK, lumpK = C.V19.rimK or 0.7, glint * (C.V19.lumps or 0.4)
	-- (and the share the rim is made of: the liquid's, as a part of K.liqThin, 1 from there on)
	local rimT = surf and 1 / K.liqThin or 0
	-- (phase 19, feather: how deep the blood stands round each texel, and the colour it thins out to)
	local gd = tx.gd
	if feath and not gd then
		gd = {}
		tx.gd = gd
	end
	local fe = feath and cv.edge or nil
	-- (phase 19, ease: what each texel shows, and how many on their way for that alone in this step.
	-- Not in a painting that snaps, and not on a canvas the lerp moves from one painting to the next
	-- (D.Lerped): that carries colour, shine and surface itself, they are taken at once there.)
	local tcr, tcg, tcb, tcw, tcsx, tcsy, ne = nil, nil, nil, nil, nil, nil, 0
	local eAct = false
	if eOn then
		if not tx.cr then tx.cr, tx.cg, tx.cb, tx.cw, tx.csx, tx.csy = {}, {}, {}, {}, {}, {} end
		tcr, tcg, tcb, tcw, tcsx, tcsy = tx.cr, tx.cg, tx.cb, tx.cw, tx.csx, tx.csy
		eAct = move and not snap and not LerpOn(s, cv)
	end
	for i = 1, mn do
		local q = mlist[i]
		local kind = mark[q]
		mark[q] = nil
		local x = q % W
		local y = (q - x) / W
		local had = tsc[q]
		local sc, sl, gw, gr, gg, gb, sx, sy
		if kind == 1 then
			-- what it is to show: how much of its surroundings holds blood and how much of them
			-- liquid on it, and of that blood the colour, the shine and the slope of its surface
			local own = lut[q]
			local c0, w0, h0, l0 = 0, 0, 0, 0
			-- (phase 19: the liquid's height and share, vH and vt, by the same nine; hH: their weighted sum)
			local oH, oT, hH = 0, 0, 0
			if own then
				c0, w0, h0, l0 = va[own] or 0, vw[own] or 0, vh[own] or 0, vl[own] or 0
				if useH then oH, oT = vHa[own] or 0, vta[own] or 0 end
			end
			local ws, sw, cr, cg, cb, gx, gy, lgx, lgy, wvx, wvy, wvw, hm = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
			sc, sl = 0, 0
			for t = 1, 9 do
				local xx, yy = x + BX[t], y + BY[t]
				local cc = own          -- (where the body's surface ends: as the cell itself)
				local cv2, wv, hv, lv = c0, w0, h0, l0
				local Hv, tv = oH, oT
				local q2 = (xx >= 0 and yy >= 0 and xx < W and yy < H) and yy * W + xx or -1
				if q2 >= 0 and tri[q2 + 1] > 0 then
					cc = lut[q2]
					if cc then cv2, wv, hv, lv = va[cc] or 0, vw[cc] or 0, vh[cc] or 0, vl[cc] or 0 else cv2, wv, hv, lv = 0, 0, 0, 0 end
					if useH then
						if cc then Hv, tv = vHa[cc] or 0, vta[cc] or 0 else Hv, tv = 0, 0 end
					end
				else
					-- beyond the rim of the map the surface may go on, on another island of the texture
					-- or another piece of the mesh: the texel is made of what lies there, so that the
					-- film is one across a seam
					local c2 = Across(s, mp, x, y, BX[t], BY[t])
					if c2 then
						cc = c2
						cv2, wv, hv, lv = va[c2] or 0, vw[c2] or 0, vh[c2] or 0, vl[c2] or 0
						if useH then Hv, tv = vHa[c2] or 0, vta[c2] or 0 end
					elseif c2 == false then
						cc = nil
						cv2, wv, hv, lv = 0, 0, 0, 0
						Hv, tv = 0, 0
					end
				end
				local wt = BW[t]
				sc, sl = sc + wt * cv2, sl + wt * lv
				if surf then
					-- (phase 19, surface: the slope of the liquid's own height, and the rim by its share up
					-- to K.liqThin, which it reaches where the liquid has risen at its outer edge: a deeper
					-- channel inside a thin sheet has no rim of its own, its height's slope is all it has)
					gx, gy = gx + GXW[t] * Hv, gy + GYW[t] * Hv
					local tr = tv * rimT
					if tr > 1 then tr = 1 end
					lgx, lgy = lgx + GXW[t] * tr, lgy + GYW[t] * tr
				else
					gx, gy = gx + GXW[t] * hv, gy + GYW[t] * hv
					lgx, lgy = lgx + GXW[t] * lv, lgy + GYW[t] * lv
					hm = hm + wt * hv
				end
				if useH then hH = hH + wt * Hv end
				if cv2 > 0 then
					local wc = wt * cv2
					ws, sw = ws + wc, sw + wc * wv
					cr, cg, cb = cr + wc * vr[cc], cg + wc * vg[cc], cb + wc * vb[cc]
					if (vk[cc] or 0) > 0 then wvx, wvy, wvw = wvx + wt * vwx[cc], wvy + wt * vwy[cc], wvw + wt end
				end
			end
			sc, sl = sc * GAIN / 16, sl * GAIN / 16
			if ws > 0 then
				-- (its colour, a shade of its own: no two places of a stain are one colour)
				local tone = (1 + grainTone * (2 * Fixed(q, mk, 4) - 1)) / ws
				gr, gg, gb, gw = cr * tone, cg * tone, cb * tone, sw / ws
				-- (the outlines stray a little from the even line between the cells, the same way at
				-- the same place for good: by a number that is nearly the same from one texel to the next
				-- and another a few texels on, so that an outline wanders as a curve does. With a number
				-- of its own for every texel the outline was moved a millimetre one way at one cell and
				-- a millimetre the other way at the next: a line with a kink at every cell.)
				if sc < 1 or (sl > 0 and sl < 1) then
					local en = ten[q]
					if not en then
						en = 2 * Lumpy(x, y, mk, 1) - 1
						ten[q] = en
						tel[q] = 2 * Lumpy(x, y, mk, 5) - 1
					end
					if sc < 1 then sc = sc + edgeN * en * (sc < 0.25 and sc * 4 or 1) end
					if sl > 0 and sl < 1 then sl = sl + edgeN * 0.35 * tel[q] * (sl < 0.25 and sl * 4 or 1) end
				end
			elseif had then
				gr, gg, gb, gw = qr[q], qg[q], qb[q], 0
			end
			if sc > 1 then sc = 1 elseif sc < 0 then sc = 0 end
			if sl > 1 then sl = 1 elseif sl < 0 then sl = 0 end
			if gw then
				-- the slope of the blood's surface, and what no wet surface is without: it is not even
				-- (its lumps are the place's own, the same for good)
				local lx, ly = tlx[q], tly[q]
				if not lx then
					lx, ly = 2 * Lumpy(x, y, mk, 2) - 1, 2 * Lumpy(x, y, mk, 3) - 1
					tlx[q], tly[q] = lx, ly
				end
				if surf then
					-- (Phase 19, surface) The liquid's surface as its depth makes it: the slope of its
					-- height (vH, the depth smoothed by its neighbours) as steep as it is across a cell,
					-- times C.V19.depthGain; a rim where the liquid ends, rising inward along the slope of
					-- its share (vt, as a part of K.liqThin and no more: only where the liquid rises at
					-- its outer edge) and as high as the root of how deep it stands round the place against
					-- K.beadDeep (0.3 to 1.5 of that), C.V19.rimK of that slope; and its lumps. A broad run
					-- is level on top, a narrow one a low bead, a thin film has a low rim. (A rim by the
					-- slope of the share with its opening, on a depth drawn four times as steep as it
					-- stands, made every run a tube: steep flanks four or five times steeper than the
					-- liquid's, a pale line along each and a dark core between. By all of the share, a deep
					-- channel inside a thin wet sheet had a rim on both its sides: a ridge down the middle
					-- of the run.) Kept as it is: Encode saturates it softly, with the waves.
					local df = sqrt(hH / 16 / K.beadDeep)
					if df < 0.3 then df = 0.3 elseif df > 1.5 then df = 1.5 end
					local rk = rimK * df / 8
					local bx, by = lgx * rk, lgy * rk
					tbx[q], tby[q] = bx, by
					local lg = lumpK * gw
					sx, sy = gx * kH + bx + lg * lx, gy * kH + by + lg * ly
				else
					sx, sy = gx * kRel + glint * gw * lx, gy * kRel + glint * gw * ly
					local l2 = sx * sx + sy * sy
					if l2 > relMax * relMax then
						l2 = relMax / sqrt(l2)
						sx, sy = sx * l2, sy * l2
					end
					-- The liquid's body. A layer of liquid stands on a surface with a rounded rim: steep
					-- where it ends, level where it is broad, and a run a finger wide is all rim, a bead.
					-- Its slope is that of the field its outline is cut from, so the rim lies along the
					-- outline wherever that runs. What its depth, its streaks, its lumps and its waves add
					-- (above) lies on that.
					-- (As high as the liquid there is deep: a film that only just stands on the cloth has a
					-- low rim. Drawn with the rim of a deep run it was a dark line round a patch of the
					-- stain's own colour: an outline.)
					local body = hm / (16 * K.beadDeep)
					if body < 1 then
						if body < 0.2 then body = 0.2 end
						lgx, lgy = lgx * body, lgy * body
					elseif rimGrow > 0 then
						-- (deeper than that: a fuller rim, K.rimGrow)
						local k = 1 + rimGrow * (body - 1)
						if k > rimMax then k = rimMax end
						lgx, lgy = lgx * k, lgy * k
					end
					local bx, by = lgx * kBead, lgy * kBead
					tbx[q], tby[q] = bx, by
					sx, sy = sx + bx, sy + by
					l2 = sx * sx + sy * sy
					if l2 > beadMax * beadMax then
						l2 = beadMax / sqrt(l2)
						sx, sy = sx * l2, sy * l2
					end
				end
				-- (phase 19, feather: how deep the blood stands round it, on average over the nine)
				if feath then gd[q] = hH / 16 end
				qsc[q], qsl[q], qw[q], qr[q], qg[q], qb[q], qsx[q], qsy[q] = sc, sl, gw, gr, gg, gb, sx, sy
				-- (and what its waves add right now: the mean of those of the places round it that have
				-- any, so that a run one place wide is not left with a fraction of its waves)
				if wvw > 0 then twx[q], twy[q] = wvx / wvw, wvy / wvw else twx[q], twy[q] = 0, 0 end
			end
		else
			sc, sl, gw, gr, gg, gb, sx, sy = qsc[q], qsl[q], qw[q], qr[q], qg[q], qb[q], qsx[q], qsy[q]
		end
		if gw and not move then
			-- (told what it is to become: it sets out with the next step)
			if not ain[q] then
				ain[q] = true
				na = na + 1
				an[na] = q
			end
		elseif gw then
			-- What it shows now. How much of it is blood, and how much liquid, come to what its cells
			-- are over a moment: that is where the outlines lie, and an outline is to move, not to
			-- jump. Its colour, its shine and its surface are what the blood there has: they change
			-- by little, and a texel new to the film has them at once and comes in from nothing.
			local was, wasl = had or 0, tsl[q] or 0
			local v = snap and sc or was + (sc - was) * ek
			local u = snap and sl or wasl + (sl - wasl) * ek
			-- (phase 19, pendPaint: a drop has just left a cell round it: the colour and the surface its
			-- swelling gave it go with it at once, as the pendant that hung there does. Its outlines come
			-- as they do: at the tip of a run drops leave several times a second, and taken at once there
			-- the tip's outline jumped at every one.)
			local quick = false
			if qk and qk[q] then
				qk[q] = nil
				quick = true
			end
			local there = true
			if abs(sc - v) < 0.004 then v = sc else there = false end
			if abs(sl - u) < 0.004 then u = sl else there = false end
			-- (phase 19, ease: its colour, shine and surface come as its outline does, EaseStep. A texel
			-- that is on its way for that alone (its outline is there) counts toward C.V19.easeMax of
			-- them in this painting; past that it takes its targets at once.)
			local sr, sg, sb, sw, ssx, ssy = gr, gg, gb, gw, sx, sy
			if eOn then
				local pr = tcr[q]
				-- (most of the texels looked at show what they are to already: nothing to do for them)
				if pr ~= gr or tcg[q] ~= gg or tcb[q] ~= gb or tcw[q] ~= gw or tcsx[q] ~= sx or tcsy[q] ~= sy then
					if eAct and not quick and had ~= nil and pr ~= nil then
						local far
						sr, sg, sb, sw, ssx, ssy, far = EaseStep(tx, q, gr, gg, gb, gw, sx, sy, ek)
						if far and there then
							if easeLeft > 0 then
								easeLeft, ne, there = easeLeft - 1, ne + 1, false
							else
								sr, sg, sb, sw, ssx, ssy = gr, gg, gb, gw, sx, sy
							end
						end
					end
					tcr[q], tcg[q], tcb[q], tcw[q], tcsx[q], tcsy[q] = sr, sg, sb, sw, ssx, ssy
				end
			end
			if not there then
				ain[q] = true
				na = na + 1
				an[na] = q
			end
			-- (how the film's outline moved here: what the film's tests ask about)
			if was < OUT and v >= OUT then stats.enter = stats.enter + 1 elseif was >= OUT and v < OUT then stats.leave = stats.leave + 1 end
			if not snap and abs(v - was) > stats.jump then stats.jump = abs(v - was) end
			-- (and the liquid's: is any of it there to draw)
			if (wasl >= OUT) ~= (u >= OUT) then
				tx.liq = tx.liq + (u >= OUT and 1 or -1)
				-- (phase 19: how the liquid's own outline moved, as the film's: what the tests ask about)
				if u >= OUT then stats.enterL = (stats.enterL or 0) + 1 else stats.leaveL = (stats.leaveL or 0) + 1 end
			end
			if not snap and abs(u - wasl) > (stats.jumpL or 0) then stats.jumpL = abs(u - wasl) end
			tsc[q], tsl[q] = v, u
			-- (phase 19, feather: toward the colour of a thin film on what it lies on, at its outline)
			if fe then
				local d = gd[q]
				if d then sr, sg, sb = Feather(fe, v, d, sr, sg, sb) end
			end
			local r8, g8, b8 = floor(sr + 0.5), floor(sg + 0.5), floor(sb + 0.5)
			local a8, al8
			if splitW then
				-- (Phase 19, split) A's alpha is the film's share and L's the liquid's (inside the film's
				-- at the most), each 0.5 + C.V19.alphaK x (share - OUT): with alphaK 1 the share itself,
				-- linear wherever a texel beside an outline is, so each outline is cut where its own share
				-- is a half, exactly where it lay before. Every step counts: the materials cut both at a
				-- half, and nothing ties the liquid's outline to a margin inside the film's.
				local aK = C.V19.alphaK or 1
				local aF = 0.5 + aK * (v - OUT)
				if aF < 0 then aF = 0 elseif aF > 1 then aF = 1 end
				a8 = floor(aF * 255 + 0.5)
				if splitL then
					local aL = 0.5 + aK * (u - OUT)
					if aL > aF then aL = aF elseif aL < 0 then aL = 0 end
					al8 = floor(aL * 255 + 0.5)
				end
			else
				-- A's alpha. Its lower half is the film: T1 where half of the texel's surroundings hold
				-- blood, and a half from a little way inside the film on. Its upper half is the liquid on
				-- it, which counts only inside the film: T2 where half of the surroundings hold liquid.
				local a = v * 1.5
				if a > 1 then a = 1 end
				a = a * 0.5
				if layered and u > 0 and v > OUT then
					local inside = (v - OUT) * 6
					a = a + 0.5 * (inside >= 1 and u or u * inside)
				end
				a8 = floor(a * 255 + 0.5)
				-- (an outline lies where the alpha read between two texels is 96 or 191: what a texel holds
				-- matters to the last step near those values, and less the further from them)
				if a8 < 72 or (a8 > 120 and a8 < 167) or a8 > 215 then a8 = a8 >= 248 and 255 or floor(a8 / 8) * 8 end
			end
			if r8 > 255 then r8 = 255 end
			if g8 > 255 then g8 = 255 end
			if b8 > 255 then b8 = 255 end
			-- B: the surface (with its waves) and its shine (as one layer the shine fades toward the
			-- film's outline). (Phase 19, surface: by Encode, as the waves write it.)
			local nx8, ny8, nz8, w8, kb
			if surf then
				nx8, ny8, nz8, w8, kb = Encode(ssx, ssy, twx[q] or 0, twy[q] or 0, sw)
			else
				local ax, ay = ssx + (twx[q] or 0), ssy + (twy[q] or 0)
				local a2 = ax * ax + ay * ay
				if a2 > beadMax * beadMax then
					a2 = beadMax / sqrt(a2)
					ax, ay = ax * a2, ay * a2
				end
				nx8, ny8, nz8, w8, kb = Surface(ax, ay, layered and sw or sw * (v < 0.5 and v * 2 or 1))
			end
			-- (a texel that would be what it is, or as good as, is not written again: where the outlines
			-- lie to the last step of the alpha, its colour to two steps, its surface and its shine
			-- to two and eight; a film that dries or runs changes most of its texels by less than that
			-- from one look to the next)
			-- (Phase 19: its colour to the last step while it eases or A and L are split: the green and
			-- blue of blood are 6 to 20 steps, and taken by fours an eased colour came in steps of a
			-- quarter of itself. L by a number of its own: kl.)
			local ka, kl
			if splitW or eOn then
				local kc = (floor(r8 / 2) * 256 + g8) * 256 + b8
				ka = kc * 256 + a8
				if splitL then kl = kc * 256 + al8 end
			else
				ka = ((floor(r8 / 2) * 64 + floor(g8 / 4)) * 64 + floor(b8 / 4)) * 256 + a8
			end
			local da, db = k1[q] ~= ka, k2[q] ~= kb
			local dl = splitL and k3[q] ~= kl
			-- (Phase 19, split: L's colour counts only where L's alpha round it is above nothing, which
			-- takes liquid among the cells round it. A texel with none, now or on its way, that was last
			-- written to L with no alpha and gets none now is not written to L for its colour alone; its
			-- key stays what was written, so it is written once its alpha changes.)
			if dl and u == 0 and sl == 0 and al8 == 0 then
				local kp = k3[q]
				if kp and kp % 256 == 0 then dl = false end
			end
			if da or db or dl then
				k1[q], k2[q] = ka, kb
				if da then
					ma = ma + 1
					AX[ma], AY[ma], AR[ma], AG[ma], AB[ma], AA[ma] = x, y, r8, g8, b8, a8
				end
				if dl then
					k3[q] = kl
					ml = ml + 1
					LX[ml], LY[ml], LR[ml], LG[ml], LB[ml], LA[ml] = x, y, r8, g8, b8, al8
				end
				if db then
					mb = mb + 1
					PX[mb], PY[mb], PR[mb], PG[mb], PB[mb], PA[mb] = x, y, nx8, ny8, nz8, w8
				end
				-- The texels beyond the rim of the map that belong to no place of the body take what
				-- this one has, so that the film reaches the rim and meets what lies across a seam.
				if AtRim(mp, q) then
					for t = 2, 9 do
						local xx, yy = x + BX[t], y + BY[t]
						if xx < 0 or yy < 0 or xx >= W or yy >= H or tri[yy * W + xx + 1] == 0 then
							if da then
								ma = ma + 1
								AX[ma], AY[ma], AR[ma], AG[ma], AB[ma], AA[ma] = xx, yy, r8, g8, b8, a8
							end
							if dl then
								ml = ml + 1
								LX[ml], LY[ml], LR[ml], LG[ml], LB[ml], LA[ml] = xx, yy, r8, g8, b8, al8
							end
							if db then
								mb = mb + 1
								PX[mb], PY[mb], PR[mb], PG[mb], PB[mb], PA[mb] = xx, yy, nx8, ny8, nz8, w8
							end
						end
					end
				end
			end
		end
	end
	s.animN = (s.animN or 0) - na0 + na
	tx.na = na
	-- (phase 19, ease: of those on their way, the ones whose colour, shine or surface only are: they
	-- are painted for, but the film's outline is not moving for them, D.Paint)
	if eOn then
		local ne0 = tx.ne or 0
		if not move then ne = ne0 end
		s.easeN = (s.easeN or 0) - ne0 + ne
		tx.ne = ne
	end
	-- (phase 19, lerp: a step of a canvas that is moved keeps its targets as they were: Write)
	if V19.lerp or cv.lrOpen then LerpBegin(s, cv, move, snap, rt) end
	if ma > 0 then
		Write(cv, "a", WA, ma)
		cv.painted = true
	end
	-- (phase 19, split: the liquid's own outline)
	if ml > 0 then
		Write(cv, "l", WL, ml)
		cv.painted = true
	end
	if mb > 0 then Write(cv, "b", WB, mb) end
	if cv.lstep then cv.lstep = nil end
	stats.texels = stats.texels + ma + mb + ml
	return mn
end

-- The waves on the liquid of film s, moved on to time now: the places where blood runs get the
-- slope their waves give them now (as many of them as K.rippleCells in one go, in turns: on a film
-- with more, a place's turn comes every second or third time), and the texels of the liquid round
-- those places the mean of that. Only B is written, and only where the liquid is drawn. (The
-- texels at the rim of a map are left as their cells were last painted: what lies across a seam
-- is not asked here.) Returns the texels written.
local rcell = {}
local function Ripple(s, now)
	local lk, cvs, txs = s.look, s.cv, s.tx
	local act, na = s.act, s.na
	if not lk or not cvs or not txs or na == 0 then return 0 end
	local vwx, vwy, vk = lk.wx, lk.wy, lk.vk
	local mkA, ci = s.mk, s.ci
	local most = K.rippleCells
	local at = (s.ripAt or 0) % na
	-- (phase 19: how the crests lie across a run in this painting, WaveTb)
	waveAcross = V19.waveAcross
	local n = 0
	for i = 1, na < most and na or most do
		at = at % na + 1
		local c = act[at]
		-- (a place that has not been looked at yet is not on a canvas yet)
		local was = vk[c]
		if was then
			local wx, wy, kw = Wave(s, c, now)
			if kw > 0 or was > 0 then
				vwx[c], vwy[c], vk[c] = wx, wy, kw
				n = n + 1
				rcell[n] = c
			end
		end
	end
	s.ripAt = at
	if n == 0 then return 0 end
	-- (phase 19: B is written by the painter's own rule (surface: Encode, whose gate is not K's), of
	-- what each texel shows (ease: its eased surface and shine, not its targets): the waves only add
	-- theirs. Written by another rule, the shine and the rim strobed between the two at the waves'
	-- pace, and every painting of the waves undid the ease.)
	local surf, eOn = V19.surface, V19.ease
	if surf then EncodeSet() else shineRef, flatRef = K.shineSlope, K.flatShine end
	local beadMax = K.beadMax
	local PX, PY, PR, PG, PB, PA = WB[1], WB[2], WB[3], WB[4], WB[5], WB[6]
	local measure, st = D.measure, D.stats
	local wrote = 0
	for k, cv in pairs(cvs) do
		local tx = txs[k]
		if tx and tx.liq > 0 then
			local mp = s.ch.mats[k]
			local W, H = mp.W, mp.H
			local lut = s.lut[k]
			local tsl, qw, qsx, qsy, twx, twy, k2 = tx.sl, tx.gw, tx.gsx, tx.gsy, tx.wx, tx.wy, tx.k2
			-- (phase 19, ease: what it shows; a texel that shows none yet is left as it is)
			if eOn then qsx, qsy, qw = tx.csx, tx.csy, tx.cw end
			if measure and not tx.px then tx.px, tx.py = {}, {} end
			-- the texels of the liquid round those places
			local mn = 0
			for i = 1, n do
				local c = rcell[i]
				if mkA[c] == k then
					local q0 = ci[c]
					local x0 = q0 % W
					local y0 = (q0 - x0) / W
					for t = 1, 9 do
						local x, y = x0 + BX[t], y0 + BY[t]
						if x >= 1 and y >= 1 and x < W - 1 and y < H - 1 then
							local q = y * W + x
							if not mark[q] and (tsl[q] or 0) > 0.3 and qsx and qsx[q] then
								mark[q] = 3
								mn = mn + 1
								mlist[mn] = q
							end
						end
					end
				end
			end
			local mb = 0
			for i = 1, mn do
				local q = mlist[i]
				mark[q] = nil
				if not AtRim(mp, q) then
					local wx, wy, ww = 0, 0, 0
					for t = 1, 9 do
						local cc = lut[q + BY[t] * W + BX[t]]
						if cc and (vk[cc] or 0) > 0 then wx, wy, ww = wx + BW[t] * vwx[cc], wy + BW[t] * vwy[cc], ww + BW[t] end
					end
					if ww > 0 then wx, wy = wx / ww, wy / ww end
					if measure then
						-- (by how much the surface's slope there changed since its last step, and whether
						-- that is the other way from the step before: a wave that passes turns round twice
						-- in its period, a surface that flickers at every step)
						local ex, ey = wx - (twx[q] or 0), wy - (twy[q] or 0)
						local e2 = ex * ex + ey * ey
						st.ripN, st.ripSum = st.ripN + 1, st.ripSum + sqrt(e2)
						if e2 > st.ripMost then st.ripMost = e2 end
						local ox = tx.px[q]
						if ox and ox * ex + tx.py[q] * ey < 0 then st.ripBack = st.ripBack + 1 end
						tx.px[q], tx.py[q] = ex, ey
					end
					twx[q], twy[q] = wx, wy
					local nx8, ny8, nz8, w8, kb
					if surf then
						nx8, ny8, nz8, w8, kb = Encode(qsx[q], qsy[q], wx, wy, qw[q] or 0)
					else
						local sx, sy = qsx[q] + wx, qsy[q] + wy
						local l2 = sx * sx + sy * sy
						if l2 > beadMax * beadMax then
							l2 = beadMax / sqrt(l2)
							sx, sy = sx * l2, sy * l2
						end
						nx8, ny8, nz8, w8, kb = Surface(sx, sy, qw[q])
					end
					if k2[q] ~= kb then
						k2[q] = kb
						mb = mb + 1
						PX[mb], PY[mb], PR[mb], PG[mb], PB[mb], PA[mb] = q % W, floor(q / W), nx8, ny8, nz8, w8
					end
				end
			end
			if mb > 0 then
				Write(cv, "b", WB, mb)
				wrote = wrote + mb
			end
		end
	end
	return wrote
end
-- Every cell of map k of film s that holds blood is painted again (its canvas is new). Returns how
-- many cells that is (phase 19's snap counts them down: PaintFilm), and marks each in `mark` when
-- given (only for a canvas just taken: the snap counts those cells and no others).
function QueueMap(s, k, mark)
	local mk, w = s.mk, s.w
	local n = 0
	for c = 1, s.n do
		if mk[c] == k and w[c] ~= 0 then
			FM.Touch(s, c)
			if mark then mark[c] = true end
			n = n + 1
		end
	end
	return n
end

-- (Phase 19, feather) The colour canvas c's film thins out to at its outline has changed (Edge): its
-- map is painted anew, every cell of it, and none of them is passed over as painted already
-- (K.paintSkip: a new number for what is painted into it, tx.gen).
function Refeather(c)
	local s, mp = c.owner, c.mp
	if c.free or not s or not mp or not s.cv or s.cv[mp.k] ~= c then return end
	QueueMap(s, mp.k)
	local tx = s.tx and s.tx[mp.k]
	if tx then
		texGen = texGen + 1
		tx.gen = texGen
	end
end

-- Cells of film s that wait to be painted, as many as make up to `most` texels, and its texels
-- that are still on their way. Returns the texels looked at.
local function PaintFilm(s, most, now, rt)
	-- (a map that got no canvas asks again after a while, with everything it holds)
	local starve = s.starve
	if starve then
		for k, t in pairs(starve) do
			if rt > t then
				starve[k] = nil
				QueueMap(s, k)
			end
		end
		if next(starve) == nil then
			starve = nil
			s.starve = nil
		end
	end
	local q, qn = s.queue, s.qn
	local uq, un = s.uq, s.un
	if qn + un == 0 and (s.animN or 0) == 0 then return 0 end
	-- (a cell's change is nine texels' at the most; those of cells side by side are shared)
	local cap = max(1, floor(most / 3))
	local ch = s.ch
	local mk, dq = s.mk, s.dq
	if not s.look then
		s.look = {}
		for i = 1, #LOOKS do s.look[LOOKS[i]] = {} end
	end
	-- (phase 19: looks made by an earlier loading of this file, without all of LOOKS)
	local lk = s.look
	if not lk.vp then
		for i = 1, #LOOKS do lk[LOOKS[i]] = lk[LOOKS[i]] or {} end
	end
	-- (phase 19, ease: C.V19.easeMax texels of this film's painting may be on their way for their
	-- colour, shine or surface alone; snap: a new canvas's first painting ends when what QueueMap
	-- asked for has been painted, or half a second after the canvas was taken, whichever is first)
	easeLeft = C.V19.easeMax or 200
	local snap19 = V19.on and (C.V19.snap or 1) ~= 0
	s.tx = s.tx or {}
	s.cv = s.cv or {}
	for k in pairs(byMap) do byMap[k].n = 0 end
	-- First the cells where the outline changes (blood has only just come, or has gone), then the
	-- others in the order they asked. (A cell may stand in a list it no longer waits in: it was
	-- painted from the other one since. It is passed over.)
	-- (Those that wait their turn get theirs: while some do, the first take three quarters of a
	-- painting at the most. A film whose outline moved somewhere at every painting never came to
	-- them otherwise.)
	local taken = 0
	local inq = s.inq
	local capFirst = qn > 0 and max(1, floor(cap * 0.75)) or cap
	for pass = 2, 1, -1 do
		local list, ln = q, qn
		local most2 = cap
		if pass == 2 then list, ln, most2 = uq, un, capFirst end
		local i = 0
		while i < ln and taken < most2 do
			i = i + 1
			local c = list[i]
			-- (it leaves the list: it may be put on it again, Touch)
			if pass == 1 then inq[c] = nil end
			if dq[c] == pass then
				dq[c] = 0
				taken = taken + 1
				local k = mk[c]
				local e = byMap[k]
				if not e then
					e = { n = 0 }
					byMap[k] = e
				end
				e.n = e.n + 1
				e[e.n] = c
			end
		end
		-- (the rest moves up)
		if i > 0 then
			local rest = ln - i
			for j = 1, rest do list[j] = list[i + j] end
			for j = rest + 1, ln do list[j] = nil end
			if pass == 2 then s.un = rest else s.qn = rest end
		end
	end
	local done = 0
	for k = 1, #ch.mats do
		local e = byMap[k]
		local en = e and e.n or 0
		local tx = s.tx[k]
		if en > 0 or (tx and tx.na > 0) then
			local mp = ch.mats[k]
			local cv = s.cv[k]
			local fresh = false
			if not cv and en > 0 and mp.ok and mp.slot and not (starve and starve[k]) then
				cv = D.Take(mp, s)
				if not cv and D.Steal(s) then cv = D.Take(mp, s) end
				if cv then
					s.cv[k] = cv
					s.layers = nil
					tx = NewTexels()
					s.tx[k] = tx
					-- (its other cells were painted into a canvas it no longer has, or never: all again. Phase
					-- 19, snap: those cells are marked, q0, and counted down as they are painted)
					local q0 = snap19 and {} or nil
					local nq = QueueMap(s, k, q0)
					if snap19 then tx.snapN, tx.snapT, tx.snapQ, fresh = nq, rt, q0, true end
				else
					-- (none to be had: these cells are not painted, and the map asks again later)
					starve = starve or {}
					s.starve = starve
					starve[k] = rt + STARVE
					D.stats.starved = (D.stats.starved or 0) + 1
				end
			end
			if cv and tx then
				done = done + PaintMap(s, mp, cv, tx, e, en, now, rt)
				-- (phase 19, snap: the cells QueueMap marked, counted down as each is painted the first time;
				-- cells asked for since (the spreading front, Refeather, the SIM) are not counted. The cells
				-- painted just now with a new canvas are asked for again with the rest, and counted then.)
				local q0 = tx.snapQ
				if q0 and not fresh then
					for i = 1, en do
						local c = e[i]
						if q0[c] then
							q0[c] = nil
							tx.snapN = tx.snapN - 1
						end
					end
				end
			end
		end
	end
	-- (everything a new canvas was asked for is on it: from here on its texels move. Until then the
	-- film is painted at every frame: a body that comes into view has its blood at once.)
	-- (Phase 19, snap: for each canvas by itself, when the cells asked for with it have been painted
	-- or half a second after it was taken. While all of the film's waiting cells were waited for, a
	-- film whose cells were asked for again at every step of its blood was in its first painting for
	-- good: its outlines jumped, and it was painted at every frame. What was asked for with the
	-- canvas is still painted at every frame till it is on it, two seconds at the most: past half a
	-- second it comes in over a moment, as everything else does.)
	local filling = false
	local busy = s.qn + s.un > 0
	for _, tx in pairs(s.tx) do
		if not busy then
			tx.snap = false
		elseif tx.snap and snap19 and tx.snapT and ((tx.snapN or 0) <= 0 or rt - tx.snapT >= 0.5) then
			tx.snap = false
		end
		if tx.snap or (busy and snap19 and tx.snapT and (tx.snapN or 0) > 0 and rt - tx.snapT < 2) then filling = true end
		-- (its window is over: its marks go, and a later spell of work does not open it again)
		if tx.snapT and (not busy or (tx.snapN or 0) <= 0 or rt - tx.snapT >= 2) then
			if tx.snapQ then tx.snapQ = nil end
			if tx.snapN and tx.snapN ~= 0 then tx.snapN = 0 end
		end
	end
	s.filling = filling
	return done
end

-- Which films are drawn and painted in full whatever the governor's scale says (s.fullLook): the
-- K.fullCount nearest the eye within K.fullDist units. The governor's scale stood at its floor in
-- nearly every recorded scene, single bodies included, because the films nearest the eye cost what
-- they cost: it then took from those same films the liquid's own colour (a body 120 units away had
-- none), its highlight beyond 105 units and its waves beyond 65, and painted them in every third
-- frame. None of that made the near films cheaper. Further away it is the governor's to cut.
-- (abl_film_full_near 0: as it was.)
-- (Phase 19, fade: a film stays one of them while it is among the K.fullCount + 1 nearest and within
-- C.V19.fullKeep units more: one at the edge flipped in and out of its full look from frame to
-- frame. Lerp: the K.fullCount nearest within K.fullDist, none kept by that, are moved in every
-- frame (s.lerpOK) while the governor's scale is 0.5 or more and they were drawn in the last 0.1 s.)
local fullFrame, fullList = -1, {}
local function NearDist(a, b) return a.dist < b.dist end
function D.FullLook()
	local f = FrameNumber()
	if f == fullFrame then return end
	fullFrame = f
	local list = ABL.Sources.list
	local on = D.cvFull:GetBool()
	local lim = (K.fullDist or 300) * ABL.LOD.QualityScale()
	local fade, lerp = V19.fade, V19.lerp or lerpLive
	local keep = fade and lim + (C.V19.fullKeep or 40) or lim
	local n = 0
	for i = 1, #list do
		local src = list[i]
		local s = src.film
		if s then
			if fade then s.fullWas = s.fullLook end
			if lerp then s.lerpOK = false end
			s.fullLook = false
			if on and (src.dist or 1e9) < keep then
				n = n + 1
				fullList[n] = src
			end
		end
	end
	for i = n + 1, #fullList do fullList[i] = nil end
	if n > 1 then table.sort(fullList, NearDist) end
	local fc = K.fullCount or 3
	if fade then
		for i = 1, n do
			local src = fullList[i]
			local s = src.film
			s.fullLook = (i <= fc and src.dist < lim) or (s.fullWas and i <= fc + 1) or false
		end
	else
		for i = 1, math.min(n, fc) do fullList[i].film.fullLook = true end
	end
	if V19.lerp then
		local rt = RealTime()
		local ok = (ABL.LOD.scale or 1) >= 0.5
		for i = 1, math.min(n, fc) do
			local src = fullList[i]
			local s = src.film
			s.lerpOK = ok and src.dist < lim and s.drawT ~= nil and rt - s.drawT < 0.1
		end
	end
end

-- Phase 19, lerp: once a frame, before anything is painted, the finer pictures of the canvases that
-- are moved are made anew where their interpolation stands, f = (now - t0) / dur, the two pictures
-- mixed and smoothed, six quads each (Blend8): C.V19.lerpMax of them at the most, the nearest film's first; one that gets none in a
-- frame ends at its next. Canvases whose film is moved no more (not among the K.fullCount nearest,
-- not drawn in the last 0.1 s, the governor's scale under 0.5, lerp or phase 19 turned off) end
-- theirs at once (f = 1) and give their set of earlier pictures back.
local function LerpPass(rt)
	local t0 = SysTime()
	local done, held = 0, false
	for i = 1, #canvases do
		local c = canvases[i]
		if c.lset or c.lrOpen then
			local o = c.owner
			if c.free or not o or not o.lerpOK or not V19.lerp then
				if c.free then
					LerpDrop(c)
				else
					if c.lrOpen then
						LerpFinish(c)
						done = done + 1
					end
					local set = c.lset
					if set then set.busy, c.lset = nil, nil end
				end
			else
				held = true
			end
		end
	end
	lerpLive = held
	if held then
		local most = C.V19.lerpMax or 4
		for i = 1, #fullList do
			local s = fullList[i].film
			if s and s.lerpOK and s.cv then
				for _, c in pairs(s.cv) do
					if c.lrOpen then
						local f = (rt - c.lrT0) / c.lrDur
						local lr, open = c.lr, false
						for j = 1, 3 do
							local w = FAMS[j]
							local rec = lr[w]
							if rec.open then
								if f <= 0 then
									open = true
								elseif most <= 0 then
									rec.skip, open = true, true
								else
									local g = rec.skip and 1 or f
									LerpBuild(c, w, g, rec.x0, rec.y0, rec.x1, rec.y1)
									most, done = most - 1, done + 1
									rec.skip = false
									if g >= 1 then rec.open = false else open = true end
								end
							end
						end
						c.lrOpen = open
					end
				end
			end
		end
	end
	if done > 0 then
		D.stats.lerps = D.stats.lerps + done
		local Prof = ABL.Prof
		if Prof and Prof.Add then Prof.Add("draw.filmpaint.lerp", SysTime() - t0) end
	end
end

-- (Phase 19: its switches for this frame. When one that decides what the canvases hold or what their
-- materials are made of has changed, every canvas is made anew and every film painted anew.)
local function V19Frame()
	local sig = V19Read()
	if sig ~= v19sig then
		v19sig = sig
		Rebuild()
		D.Repaint()
	end
end

-- All films, once per frame before the frame is rendered: the cells that changed, within a budget.
-- A body that has not been drawn for a while gives its canvases back (they are painted again when
-- it is seen).
function D.Paint()
	if D.tryPending then D.TryNow() end
	if unread[1] then ReadMeans() end
	local two = K.material ~= 0 and D.cvLayers:GetBool()
	if two ~= layeredNow then
		layeredNow = two
		D.Repaint()
	end
	V19Frame()
	SmoothSwitch()
	local list = ABL.Sources.list
	local n = #list
	if n == 0 then return end
	local now, rt = CurTime(), RealTime()
	local left = K.paintTexels
	local t0 = SysTime()
	-- (while the addon is over its budget, the governor's scale is below 1: films are then painted
	-- in every second or third frame only. Their outlines still move, in larger steps.)
	local scale = ABL.LOD.scale or 1
	local rare = scale < 0.75 and FrameNumber() % (scale < 0.4 and 3 or 2) ~= 0
	D.FullLook()
	-- (phase 19, lerp: the films nearest the eye between their paintings, before anything is painted)
	if V19.lerp or lerpLive then LerpPass(rt) end
	-- (canvases that are still to be had: counted when first asked for, below)
	local spare
	-- (another film first at every frame: when there is more to paint than a frame affords, they take turns)
	D.turn = (D.turn or 0) % n + 1
	for i = 0, n - 1 do
		local src = list[(D.turn + i - 1) % n + 1]
		local s = src.film
		if s then
			local seen = s.drawT and rt - s.drawT < 0.5
			if seen then
				-- A painting has its price whatever it paints (the targets are set up for it), and a
				-- texel comes to what its cells are over a moment either way. So a film is painted
				-- no more often than every K.paintEvery seconds, one in a frame (under load they
				-- take turns), and a film whose outline is at rest and that has little to paint
				-- less often still. A body that has only just come into view is painted at once,
				-- until all of its blood is on it.
				-- (phase 19, ease: texels on their way for their colour, shine or surface alone are work,
				-- but the film's outline does not move for them: s.easeN)
				local moving = (s.animN or 0) - (s.easeN or 0) > 0 or s.un > 0
				local work = s.qn + s.un + (s.animN or 0)
				local since = rt - (s.paintT or 0)
				local fill = s.filling or s.unpaintedOnce
				-- (near the eye as often as the film is stepped: its outline moves with every step of
				-- the blood and not in larger ones)
				local every = (src.dist or 1e9) < K.paintNearDist and K.paintNear or K.paintEvery
				s.paintEv = every
				if (work > 0 or s.starve) and left > 0 and IsValid(src.body)
					and (fill or ((not rare or s.fullLook) and since >= every - 0.004 and (moving or work >= K.paintWork or since >= K.paintCalm))) then
					if not s.ch.slotCount or s.ch.slotFor ~= src.body:GetModel() then
						D.Slots(src.body, s.ch)
						s.ch.slotFor = src.body:GetModel()
					end
					s.paintT, s.unpaintedOnce = rt, nil
					left = left - PaintFilm(s, fill and left * 2 or left, now, rt)
					if not fill then left = 0 end
				end
			elseif s.cv and (not s.drawT or rt - s.drawT > K.idleFree) then
				-- A body that is not drawn gives its canvases back when they are wanted: when few are
				-- left to be had, or when it has not been drawn for a long while. (It gave them back
				-- after K.idleFree seconds whatever else there was, and a body one had looked away
				-- from for that long had no blood on it in the first frames it was seen again; its
				-- film was then painted again from nothing, over a few frames. Measured: scene
				-- cont_away.) What changes on it meanwhile waits, and is painted when it is seen.
				if not spare then
					local used = D.Usage()
					spare = D.Limit() - used
				end
				if not s.drawT or rt - s.drawT > K.idleLong or spare < K.idleSpare then
					D.Release(s)
					-- (nothing waits for a canvas that is not there; all of it is asked for again then)
					Unqueue(s)
					s.starve = nil
					s.unpainted = true
					spare = nil
				end
			end
		end
	end
	if left < K.paintTexels then
		D.stats.paints = D.stats.paints + 1
		D.stats.ms = D.stats.ms + (SysTime() - t0) * 1000
		return
	end
	-- The waves on running liquid, in a frame in which nothing else is painted: of one film, the
	-- one whose turn it is among those near the eye (D.Source says which are: s.rip).
	if not layeredNow then return end
	-- (phase 19, rippleNear: the waves of a film nearer the eye than K.paintNearDist every
	-- C.V19.rippleNear seconds, as often as that film is painted (K.paintNear), with the painter's
	-- slack of a few milliseconds for the frame it falls in; others every K.rippleEvery. On the bench,
	-- with 1.0 and 1.6 crests a second, a texel's tilt changed by 1.96 degrees on average from one
	-- painting of the waves to the next, and the other way from the step before at 40 % of them,
	-- painted every 0.13 s; by 1.12 degrees and at 21 % every 0.067 s: male_06, 2 ml/s, 20 s.)
	local rNear = V19.rippleNear and C.V19.rippleNear or nil
	D.ripTurn = (D.ripTurn or 0) % n + 1
	for i = 0, n - 1 do
		local src = list[(D.ripTurn + i - 1) % n + 1]
		local s = src.film
		local every = K.rippleEvery
		if rNear and (src.dist or 1e9) < K.paintNearDist then every = rNear - 0.004 end
		if s and s.rip and (not rare or s.fullLook) and s.cv and s.na > 0 and s.drawT and rt - s.drawT < 0.5 and rt - (s.ripT or 0) >= every then
			s.ripT = rt
			local st = D.stats
			st.ripTexels = st.ripTexels + Ripple(s, now)
			st.ripples = st.ripples + 1
			st.ripMs = st.ripMs + (SysTime() - t0) * 1000
			break
		end
	end
end

-- Developer: every film is painted anew (its look has been changed: cl_filmtest.lua).
function D.Repaint()
	for i = 1, #canvases do
		local c = canvases[i]
		-- (how much of the cloth shows in the stain, and how bright the stain is drawn for it, is set
		-- anew when the canvas is laid on its surface again: D.Dress)
		c.deep:SetFloat("$detailblendfactor", c.deepF or K.clothShowWas or K.clothShow)
		local dt = (c.deepT or K.deepTint or 1) ^ (1 / 2.2)
		c.deep:SetVector("$color2", Vector(dt, dt, dt))
		c.lit:SetFloat("$detailblendfactor", K.liquidShow)
		c.lit:SetFloat("$rimlightboost", K.rim)
		c.lit:SetVector("$color2", Vector(K.liquidTint, K.liquidTint, K.liquidTint))
		c.liq:SetFloat("$detailblendfactor", K.liquidShow)
		c.liq:SetVector("$color2", Vector(K.liquidTint, K.liquidTint, K.liquidTint))
		c.shine:SetFloat("$rimlightboost", K.rim)
		-- (phase 19: the highlight's numbers from where Materials takes them, times the canvas's fade,
		-- set anew at its next drawing; the lerp's interpolations go, everything is painted anew)
		if V19.surface or V19.fade then Boosts(c) end
		if c.lset or c.lrOpen then LerpDrop(c) end
	end
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s and s.cv then
			D.Release(s)
			Unqueue(s)
			s.starve = nil
			s.unpainted = true
		end
	end
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
-- The material slot (from 0, as the engine counts them) of each of a chart's maps on entity ent.
function D.Slots(ent, ch)
	local list = ent:GetMaterials() or {}
	local n = 0
	for k = 1, #ch.mats do
		local mp = ch.mats[k]
		mp.slot = nil
		local path = string.gsub(mp.path, "\\", "/")
		for i = 1, #list do
			if string.gsub(string.lower(list[i]), "\\", "/") == path then mp.slot = i - 1 break end
		end
		if not mp.slot then
			for i = 1, #list do
				if string.match(string.lower(list[i]), "([^/\\]+)$") == mp.name then mp.slot = i - 1 break end
			end
		end
		if mp.slot then n = n + 1 end
	end
	ch.slots, ch.slotCount, ch.own = n, #list, list
	return n
end

local function None()
	if not matNone then
		matNone = CreateMaterial("abl_film_none", "UnlitGeneric", { ["$basetexture"] = "vgui/white", ["$model"] = 1, ["$translucent"] = 1, ["$alpha"] = 0, ["$no_draw"] = 1 })
	end
	return matNone
end

local saved = {}
-- (the passes that draw the liquid: only on the maps that have some)
local LIQUID = { lit = true, liq = true, shine = true, deep = true }

-- The bones a body was drawn with, for the film that is drawn over it.
-- Z-City sets bone matrices by hand before it draws a body (DrawPlayerRagdoll: the head's at
-- every drawing, scaled to a hundredth for the body the camera is in so that the view out of it
-- is free; the arms' with a weapon in them; every bone while a body gets up). The engine sets a
-- model's bones up again, from its animation alone, when the model is drawn the next time, and
-- that is the film's first pass: the film then lay on another head than the one that had been
-- drawn. On other players the two were a hair's breadth apart and fought for the depth buffer,
-- and the blood on a head came and went in shards from one frame to the next; on one's own
-- body the head was hidden and its film was not, and hung in the air round the camera.
-- (Measured: scenes head_fix and head_models of server/sv_headtest.lua, in bursts of pictures
-- with tools/harness/redflicker.ps1: the red on a head changed by 20 % from one picture to the
-- next, by 0.6 to 2 % with this. Setting the matrices again without setting the bones up first
-- changes nothing.) So: read them, set the bones up, set them again, which is what Z-City does
-- itself before it draws.
-- They are read at the moment Z-City is about to draw the body (its hook "CoolPostDrawAppearance":
-- its own work on the bones is done, the model is drawn next), for the bodies that carry a film.
-- A body whose bones were not read then in this frame (drawn some other way) has them read as
-- its film is drawn.
local held = setmetatable({}, { __mode = "k" })
hook.Add("CoolPostDrawAppearance", "ABL_FilmBones", function(ent)
	if not IsValid(ent) or not D.cvBones:GetBool() then return end
	local src = ABL.Sources.byBody and ABL.Sources.byBody[ent]
	if not src or src.body ~= ent or not src.film or not src.film.cv then return end
	local n = ent:GetBoneCount() or 0
	if n <= 0 then return end
	local h = held[ent]
	if not h then h = {} held[ent] = h end
	for i = 0, n - 1 do h[i] = ent:GetBoneMatrix(i) end
	h.n, h.frame = n, FrameNumber()
end)

local keep = {}
local function KeepBones(ent)
	local n = ent:GetBoneCount() or 0
	if n <= 0 then return end
	local t0 = SysTime()
	local h = held[ent]
	if h and h.frame == FrameNumber() and h.n == n then
		D.stats.keptHook = (D.stats.keptHook or 0) + 1
	else
		h = keep
		for i = 0, n - 1 do h[i] = ent:GetBoneMatrix(i) end
	end
	ent:SetupBones()
	for i = 0, n - 1 do
		local m = h[i]
		if m then ent:SetBoneMatrix(i, m) end
	end
	if h == keep then
		for i = 0, n - 1 do keep[i] = nil end
	end
	D.stats.kept = (D.stats.kept or 0) + 1
	ABL.Prof.Add("sub.body.film.bones", SysTime() - t0)
end

-- The film over the body just drawn (ent: the entity that was drawn; ch: its chart; layers:
-- { { mp = map, canvas = c, k = the map's number }, ... }; passes[1 .. np]: which of the canvases'
-- materials, in the order they are drawn: "soft", "stain", "lit" or "liq" and "shine", "plain",
-- "old"; txs: the film's texels by map (the liquid is drawn only on the maps that have some)).
-- Every slot of the body gets a material that draws nothing, the layers' slots their canvas's
-- material; the body is drawn once more for each pass, and its own sub-materials are put back.
-- hand: the body has just been drawn by Z-City's renderer, with bones set by hand (KeepBones).
function D.Overlay(ent, ch, layers, passes, np, txs, hand)
	if not ch.slotCount or ch.slotFor ~= ent:GetModel() then
		D.Slots(ent, ch)
		ch.slotFor = ent:GetModel()
	end
	None()
	if hand and D.cvBones:GetBool() then KeepBones(ent) end
	local n = ch.slotCount
	local cr, cg, cb = render.GetColorModulation()
	local blend = render.GetBlend()
	render.SetBlend(ABL.Config.BloodMarkOpacity)
	for i = 0, n - 1 do
		saved[i] = ent:GetSubMaterial(i)
		ent:SetSubMaterial(i, "!abl_film_none")
	end
	-- (what each canvas lies on: the body's own material at that slot, which may have changed)
	local own = ch.own
	for l = 1, #layers do
		local ly = layers[l]
		local slot = ly.mp.slot
		if slot then
			local name = saved[slot]
			if not name or name == "" then name = own and own[slot + 1] end
			if ly.canvas.cloth ~= (name or false) then D.Dress(ly.canvas, name) end
		end
	end
	render.SetColorModulation(1, 1, 1)
	for p = 1, np do
		local which = passes[p]
		local any = false
		for l = 1, #layers do
			local ly = layers[l]
			local slot = ly.mp.slot
			if slot then
				local name = ly.canvas.names[which]
				if LIQUID[which] and txs then
					local tx = txs[ly.k]
					if not tx or tx.liq <= 0 then name = nil end
				end
				ent:SetSubMaterial(slot, name or "!abl_film_none")
				if name then any = true end
			end
		end
		if any then
			ent:DrawModel()
			D.stats.passes = D.stats.passes + 1
		end
	end
	for i = 0, n - 1 do
		local name = saved[i]
		ent:SetSubMaterial(i, (name and name ~= "") and name or nil)
	end
	render.SetColorModulation(cr, cg, cb)
	render.SetBlend(blend)
end

-- (how many units of the world one screen pixel is wide a unit away from the eye: once a frame)
local pxFrame, pxUnit = -1, 0.0015
local function PixelUnit()
	local f = FrameNumber()
	if f ~= pxFrame then
		pxFrame = f
		local vs = render.GetViewSetup()
		local fov = vs and vs.fov or 75
		pxUnit = 2 * math.tan(math.rad(fov) * 0.5) / math.max(ScrW(), 1)
	end
	return pxUnit
end

local PASS = {}
local eyeV = Vector(0, 0, 0)

-- The film of one character over its body, which has just been drawn (from ABL.Flow.DrawSource).
-- hand: drawn by Z-City's renderer in this very call (not the fallback of the main render hook).
function D.Source(src, body, hand)
	local s = src.film
	if not s then return end
	local rt = RealTime()
	-- (seen again after a while, with its canvases kept: what changed on it meanwhile is painted at
	-- once, as a film's is that has only just come into view)
	if s.cv and s.drawT and rt - s.drawT > 0.5 and s.qn + s.un > 0 then s.unpaintedOnce = true end
	s.drawT = rt
	-- (seen again after its canvases went: everything it holds is painted anew)
	if s.unpainted then
		s.unpainted = nil
		s.unpaintedOnce = true
		for k = 1, #s.ch.mats do QueueMap(s, k) end
	end
	local cv = s.cv
	if not cv or src.dist > K.drawDist then return end
	local layers = s.layers
	if not layers then
		layers = {}
		for k, c in pairs(cv) do layers[#layers + 1] = { mp = s.ch.mats[k], canvas = c, k = k } end
		s.layers = layers
	end
	local any = false
	for i = 1, #layers do
		if layers[i].canvas.painted then any = true break end
	end
	if not any then return end
	local scale = ABL.LOD.scale or 1
	-- (one of the films nearest the eye: in full, D.FullLook)
	D.FullLook()
	if s.fullLook then scale = 1 end
	local layered = layeredNow
	-- (phase 19, fade: the near look comes and goes over a band of distance, with hysteresis: Near.
	-- fadeF: how much of it shows, liqHere: the liquid's colour by its own surface)
	local near, fadeF, liqHere
	if V19.fade and layered then
		near, fadeF, liqHere = Near(s, src, rt)
	else
		near = D.cvGloss:GetBool() and src.dist < K.glossDist * ABL.LOD.QualityScale() * scale
		-- (the waves on its liquid are painted while it is near: D.Paint)
		s.rip = layered and near and src.dist < K.rippleDist * scale
	end
	local np = 0
	if layers[1].canvas.names.try then
		-- (developer: a recipe of D.Try)
		if layers[1].canvas.names.tryUnder then
			np = np + 1
			PASS[np] = "tryUnder"
		end
		np = np + 1
		PASS[np] = "try"
	elseif not layered then
		np = 1
		PASS[1] = near and "old" or "plain"
	elseif near then
		-- (not while the addon is over its budget: it is a pass over the body)
		if K.softPx > 0 and src.dist < K.softDist and scale > 0.6 then
			-- The stain's rim is smoothed over so many screen pixels: over that much of the field
			-- between two texels (across a sharp outline the field falls by 0.22 from one texel to
			-- the next), and never over less than K.softMin. A pixel's size on the film goes by how
			-- far the eye is from the near side of the body, not from its middle: from close by
			-- the middle is twice as far as the blood, and the rim would be twice as wide.
			eyeV:SetUnpacked(ABL.LOD.eyeX, ABL.LOD.eyeY, ABL.LOD.eyeZ)
			local d = eyeV:Distance(body:NearestPoint(eyeV))
			local px = PixelUnit() * (d > 4 and d or 4)
			for i = 1, #layers do
				local ly = layers[i]
				local c = ly.canvas
				-- (phase 19, split: the stain is cut where its own alpha is a half: c.cutF)
				local t1 = c.cutF or T1
				local w = 0.22 * K.softPx * px / ly.mp.cell + K.softMin
				if w > t1 - 0.06 then w = t1 - 0.06 end
				if not c.softW or abs(c.softW - w) > 0.004 then
					c.softW = w
					c.soft:SetFloat("$edgesoftnessend", t1 - w)
				end
			end
			np = np + 1
			PASS[np] = "soft"
		end
		np = np + 1
		PASS[np] = "stain"
		local lp = K.liquidPasses
		if fadeF then
			-- (phase 19, fade: the liquid's colour by its own surface (liq) nearer than C.V19.fadeFrom of
			-- the near distance, by the body's (deep) from there on, turning into the stain's look (Fade);
			-- deep is not drawn under liq, which covers every pixel of it. With K.liquidPasses 1, deep
			-- as before. No test of the governor's scale: the band does what it did.)
			if lp == 1 or not liqHere then
				if lp ~= 1 or (K.deepPass or 0) ~= 0 then
					np = np + 1
					PASS[np] = "deep"
				end
			end
			if lp == 3 and liqHere then
				np = np + 1
				PASS[np] = "lit"
			else
				if lp == 2 and liqHere then
					np = np + 1
					PASS[np] = "liq"
				end
				np = np + 1
				PASS[np] = "shine"
			end
			-- (set only when it has changed by more than a little, and at its ends exactly)
			for i = 1, #layers do
				local c = layers[i].canvas
				local was = c.fadeF
				if was == nil or abs(was - fadeF) > 0.01 or (was ~= fadeF and (fadeF == 0 or fadeF == 1)) then Fade(c, fadeF) end
			end
		else
			-- (the liquid's own colour over the stain's: the weave shows in the stain, not through a
			-- layer of liquid. Not while the addon is over its budget: it is a pass over the body.)
			if (K.deepPass or 0) ~= 0 and scale > 0.5 then
				np = np + 1
				PASS[np] = "deep"
			end
			-- (the liquid over it: K.liquidPasses)
			if lp == 3 then
				np = np + 1
				PASS[np] = "lit"
			else
				if lp == 2 then
					np = np + 1
					PASS[np] = "liq"
				end
				np = np + 1
				PASS[np] = "shine"
			end
		end
	else
		-- (phase 19, fade: far away the stain as it is near, with the body's relief: only the liquid's
		-- own passes come and go, where they show nothing any more)
		np = 1
		PASS[1] = fadeF and "stain" or "plain"
	end
	D.Overlay(body, s.ch, layers, PASS, np, s.tx, hand)
end

function D.Clear()
	for i = 1, #canvases do canvases[i].free, canvases[i].mp, canvases[i].owner, canvases[i].painted = true, nil, nil, false end
	-- (phase 19, lerp: no interpolation and no set of earlier pictures is kept for them)
	for i = 1, #canvases do
		local c = canvases[i]
		if c.lset or c.lrOpen then LerpDrop(c) end
	end
end

------------------------------------------------------------------------------------------
-- Developer: what this build of the game makes of a material (cl_filmtest.lua, scene film_try)
------------------------------------------------------------------------------------------
-- The material the body itself has at a slot (a piece of clothing is a sub-material), and that
-- material's own texture and relief, and whether that relief is its own (false: the engine's error
-- texture, which phase 19's clothRelief does not draw the stain with: Real, D.Dress).
function D.Cloth(ent, slot)
	local name = ent:GetSubMaterial(slot)
	if not name or name == "" then name = (ent:GetMaterials() or {})[slot + 1] end
	if not name then return nil end
	local m = Material(name)
	local e = ClothOf(name)
	return name, e and e.base or nil, e and e.bump or nil, m, (e and e.bumpReal) or false
end

-- (for the developer's log: the relief bump by its name, and so when it is the engine's error texture
-- and not the cloth's own, with what the film's own stain is drawn with then)
function D.ReliefName(bump, real)
	if not bump then return "none" end
	if real then return bump:GetName() end
	return bump:GetName() .. " (the engine's error texture, not the cloth's own: the film's stain is drawn "
		.. (V19.clothRelief and "with the body's own normal, flat" or "with it, clothRelief off") .. ")"
end

-- (recipes: a(lpha and colour), b (relief and shine), the body's own texture, its own relief)
local TRY = {}
TRY.lit = function(a, b) return LitKV(a, b, T1) end
TRY.lit_detail = function(a, b, base) return Show(LitKV(a, b, T1), base, 0.6) end
TRY.lit_detail8 = function(a, b, base)
	local kv = Show(LitKV(a, b, T1), base, 0.6)
	kv["$detailblendmode"] = 8
	return kv
end
TRY.lit_env = function(a, b)
	local kv = LitKV(a, b, T1)
	kv["$envmap"], kv["$envmaptint"], kv["$envmapfresnel"], kv["$normalmapalphaenvmapmask"] = "env_cubemap", "[0.06 0.06 0.06]", 1, 1
	return kv
end
TRY.lit_rim = function(a, b)
	local kv = LitKV(a, b, T1)
	kv["$rimlight"], kv["$rimlightexponent"], kv["$rimlightboost"] = 1, 3, 0.6
	return kv
end
TRY.stain_bump = function(a, b, base, bump)
	local kv = Show(StainKV(a), base, 0.6)
	kv["$bumpmap"] = bump
	return kv
end
TRY.stain_bump_nodetail = function(a, b, base, bump)
	local kv = StainKV(a)
	kv["$bumpmap"] = bump
	return kv
end
-- (the stain's kind of material with a relief that is none, with the canvas's own, and with no
-- relief at all: what the body's own relief does to how bright the film is)
TRY.stain_flat = function(a)
	local kv = StainKV(a)
	kv["$bumpmap"] = flatTex:GetName()
	return kv
end
TRY.stain_b = function(a, b)
	local kv = StainKV(a)
	kv["$bumpmap"] = b
	return kv
end
TRY.stain_nobump = function(a) return StainKV(a) end
TRY.stain_plain = function(a, b, base) return Show(StainKV(a), base, 0.6) end
TRY.stain_phong = function(a, b, base, bump)
	local kv = Show(StainKV(a), base, 0.6)
	kv["$bumpmap"] = bump
	kv["$phong"], kv["$phongexponent"], kv["$phongboost"], kv["$phongfresnelranges"] = 1, 12, 0.25, "[0.1 0.3 0.8]"
	return kv
end
TRY.fringe = function(a, b, base)
	return Show({ ["$basetexture"] = a, ["$model"] = 1, ["$halflambert"] = 1, ["$translucent"] = 1,
		["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = T1, ["$edgesoftnessend"] = T1 - 0.15 }, base, 0.6)
end

local tryN = 0
-- Every canvas in use gets a material of recipe `preset` (and one of `under` for a pass under it)
-- in place of the film's own passes, or those again (preset nil). Inside a render hook. Returns
-- lines for the log.
local function Try(preset, under)
	local out = {}
	tryN = tryN + 1
	Blanks()
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s and s.cv and IsValid(src.body) then
			for k, c in pairs(s.cv) do
				local mp = s.ch.mats[k]
				Materials(c)
				c.cloth = nil
				if preset and TRY[preset] and mp.slot then
					local name, base, bump, m, real = D.Cloth(src.body, mp.slot)
					-- (phase 19, split: the recipes read the outlines as the film's own materials do, from the
					-- finer picture, so that what is compared is the material and not the outline: HT-8)
					local a, b = (V19.split and (c.a2 or c.a) or c.a):GetName(), (c.b2 or c.b):GetName()
					local function Make(which, recipe)
						local kv = TRY[recipe](a, b, (base or greyTex):GetName(), (bump or flatTex):GetName())
						local mname = "abl_film_try" .. tryN .. which .. c.id
						c.mats[#c.mats + 1] = CreateMaterial(mname, "VertexLitGeneric", kv)
						c.onCanvas[#c.mats] = kv["$bumpmap"] == b
						c.names[which] = "!" .. mname
					end
					Make("try", preset)
					if under and TRY[under] then Make("tryUnder", under) end
					-- (the recipes are given the relief as the material has it, the error texture too: what it
					-- does is what they are there to show; the log says when it is that one)
					out[#out + 1] = string.format("%s map %s slot %d: the body's material %s (%s), texture %s %s, relief %s | recipe %s%s",
						tostring(src.body), mp.name, mp.slot, tostring(name), (m and not m:IsError()) and m:GetShader() or "?",
						base and base:GetName() or "none", base and (base:Width() .. "x" .. base:Height()) or "", D.ReliefName(bump, real),
						preset, under and (" over " .. under) or "")
				end
				Lay(c)
			end
		end
	end
	return out
end

function D.Try(preset, under, log)
	D.tryPending = { preset, under, log }
end

function D.TryNow()
	local p = D.tryPending
	if not p then return end
	D.tryPending = nil
	local out = Try(p[1], p[2])
	if p[3] then
		for i = 1, #out do p[3](out[i]) end
	end
end
