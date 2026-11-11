-- Wound marks on the body: the visible openings of a wound record (cl_wounds.lua).
--
-- Geometry. A projectile hit is placed on the character's own render mesh: the entry is the
-- outermost surface the bullet line meets, the exit the surface that same line leaves through (so
-- entry and exit belong to one track), and a flesh-only path that stays just under the skin is a
-- graze: one elongated mark along the path instead of two holes. A retained projectile has no exit.
-- The angle of impact, the length of the track and whether the surface is bare skin or cloth are
-- written back into the record.
--
-- Drawing. A mark is a patch of the mesh's own triangles around the wound, so it is part of the
-- surface: it follows every animation and ragdoll pose and cannot float or slide. The patch is a
-- static mesh in the space of the bone it sits on (re-baked when skin that bends between bones has
-- moved under it), drawn once per layer. Layers are textures from tools/texgen, each placed by its
-- own texture transform (size, stretch along the bullet's path, rotation, offset), so no two wounds
-- are the same picture:
--   on skin   bruise, soot, powder stippling (by range), abrasion collar (pushed towards the side the
--             bullet came from), the defect itself, wet blood, clot / crust;
--   on cloth  the hole in the fabric with its dark wipe ring, soot / stippling, torn threads at an
--             exit, and the blood soaking into the cloth around the hole as it comes.
-- What a layer shows changes continuously with the record's state: the bruise comes up, wet blood
-- loses its gloss, darkens and sets into a crust, edge first.
--
-- Depth (phase 43). The layers are paint on the surface: a painted hole has no inside, and from
-- the side it is a dark disc on the skin. A character's own mesh cannot be cut from Lua. So the
-- opening is cut out of the picture instead and something real is put behind it:
--   1. the opening is written into the stencil buffer, by drawing the patch (the skin's own
--      triangles) with the opening's outline as an alpha-tested texture, depth-tested, so that
--      it marks exactly the pixels in which that piece of skin is seen;
--   2. in those pixels the colour is set to the wound's dark ground and the depth to far;
--   3. the recess is drawn through them: a small mesh behind the skin, its mouth a little
--      wider than the opening (the skin's edge overhangs it), its walls leaning along the
--      projectile's path, its floor uneven, coloured by depth (the cut edge of the skin, fat
--      where the opening is wide enough to show it, muscle, and darker the deeper: light does
--      not get down a hole), with a surface of blood standing in it that follows the wound's
--      state (high and wet while it bleeds, sunk, dark and dull when it has set).
-- The recess is geometry in the space of the wound: it is seen in perspective, its near wall
-- hides its floor from the side and its far wall shows, and it goes with the bone like the patch.
-- abl_wound_3d 0, a mark further off than cavDist, or a mark without a patch: the painted
-- opening alone, as before.
--
-- Form (phase 47). That recess is a hole behind a flat picture: the skin round it lies as it
-- lay, and what is seen through the opening has colours of its own and is lit from nowhere.
-- With abl_wound_form 1 (the default) a wound that has an opening is one piece of geometry on
-- the body instead: the skin rises to a rim round the wound, turns in over a lip and goes down
-- a wall to a floor, with the blood that stands in it. Next to none of it has a colour of its
-- own: it is drawn as what it does to the picture that is there (the body as the engine lit
-- it, its cloth, the blood on them): light and shade over the outside, and in the opening
-- what is left of that picture's colour as it goes down into the hole. So a wound is of the
-- stuff it is in, under the light that is on it, and has no drawn edge. The opening's outline
-- is the geometry's own (an entry's uneven round, an exit's torn, a cut's pointed), not a
-- texture's. See "The form" and "The form, drawn" below. abl_wound_form 0: the recess of
-- phase 43 as it was, to compare with and to go back to.
-- A mark on skin that bends between bones (a chest that breathes, a trunk that turns) goes along
-- from frame to frame with what the skin under it does as one piece: see Follow.
--
-- Bleeding: Z-City's wounds linked to the record bleed from exactly these openings (cl_emission).
-- Other clients: a hit is told once, to those who have the body in sight then. The server keeps
-- what it told and tells it again to a client that gets the body in sight later, or joins
-- (server/sv_woundstore.lua, cl_events.lua). What is made here from that is the same wound: the
-- record comes of the same event with the same seed, the marks of the same place on the same bone.

ABL.NoJIT()
ABL.WoundFX = ABL.WoundFX or {}
local W = ABL.WoundFX
local C, BM, L, WD = ABL.Config, ABL.BodyMesh, ABL.LOD, ABL.Wound
local WC, WR = C.WoundFX, C.Wound
local KFM = C.Film
local sqrt, min, max, abs, cos, sin, exp = math.sqrt, math.min, math.max, math.abs, math.cos, math.sin, math.exp
local Clamp = math.Clamp

local PASS_FILTER, PASS_COLOUR, PASS_GLOSS = 1, 2, 3

------------------------------------------------------------------------------------------
-- Layer materials (one per texture and pass, shared by all marks: placed per draw)
------------------------------------------------------------------------------------------
local mats = {}
local function LayerMat(tex, pass)
	local key = tex .. ":" .. pass
	local mt = mats[key]
	if mt then return mt end
	local kv = { ["$basetexture"] = "advancedblood/" .. tex, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1 }
	if pass == PASS_GLOSS then kv["$additive"] = 1 else kv["$translucent"] = 1 end
	mt = CreateMaterial("abl_wl_" .. string.gsub(tex, "[^%w]", "_") .. "_" .. pass, "UnlitGeneric", kv)
	mats[key] = mt
	return mt
end

-- What a layer is (how its opacity, colour and size follow the wound's state).
--   FIXED   what the shot left for good: soot, stippling, abrasion, the defect itself
--   BRUISE  comes up over the first minute
--   BLOOD   the wet film around the wound: there within a second, darkens, gives way to the crust
--   CRUST   what the film sets into
--   GLOSS   reflection of the wet parts
--   SOAK    blood in the cloth around a hole: grows with what has come out of the wound
--   SOAKB   that blood's own colour over it (a soak-only mark: see PlaceSoak)
local K_FIXED, K_BRUISE, K_BLOOD, K_GLOSS, K_CRUST, K_SOAK, K_SOAKB = 1, 2, 3, 4, 5, 6, 7
--   FLUSH   reddening where a blunt blow fell: there at once, gives way as the bruise comes up
local K_FLUSH = 8

-- The kinds of mark there are (mk.kind), and what makes each (phase 44). A new kind is a branch
-- in BuildLayers (what is painted), a line here, and, if it has an opening, a profile for its
-- recess (CAV_PROFILE):
--   entry, exit, graze   a projectile: where it went in, where it came out, a furrow along the skin
--   cut                  an edged weapon along the skin: a gash with a trench behind it
--   stab                 an edged weapon into the body: a short slit, a deep narrow way in
--   blunt                a blunt weapon: a bruise, reddening, a scrape from a hard blow; no opening
--   soak                 no mark of its own: the cloth round a wound taking up blood
W.Kinds = { entry = true, exit = true, graze = true, cut = true, stab = true, blunt = true, soak = true }

-- variants per texture family (tools/texgen)
local NV = { bruise = 3, soot = 2, stipple = 3, collar = 3, wipe = 2, defect = 4, stellate = 2, tear = 4, blood = 4, crust = 3, furrow = 2, imprint = 2, clothhole = 3, clothtear = 3, soak = 2 }

local function Layer(layers, tex, pass, kind, half, st, rot, ox, oy, alpha, detail)
	local l = { mat = LayerMat("wounds/" .. tex, pass), tex = tex, pass = pass, kind = kind, half = half, half0 = half, st = st or 1, rot = rot or 0, ox = ox or 0, oy = oy or 0, a = alpha or 1, detail = detail or false }
	layers[#layers + 1] = l
	return l
end

-- The layer that is the wound's opening: the recess is cut where it is.
local function Hole(mk, l, name)
	mk.hole, mk.holeName = l, name
	return l
end

local function Pick(rng, family)
	return family .. (1 + math.floor(rng:Next() * NV[family]) % NV[family])
end

-- The layers of a mark, back to front, from its record. Returns the list and the half-size of
-- the patch that holds them all.
--   mk.skin    bare skin or cloth
--   mk.down    rotation that turns a layer's "down" towards where gravity pulled along the skin
--              when the wound was made (the film that welled out ran that way)
local function BuildLayers(mk, r, rng)
	local layers = {}
	local kind, skin = mk.kind, mk.skin
	local down = mk.down or 0
	local absorb = mk.absorb or 1
	-- an oblique path draws everything out along it
	local obl = Clamp(1 / (r.cosI or 1), 1, 2.4) ^ 0.7

	if kind == "soak" then
		-- No opening is drawn (a cut, a tear, a wound made by something other than a bullet): only
		-- the cloth round it taking blood up. As a filter it darkens the cloth; blood is not a dye,
		-- so its own colour lies over that (on dark or coloured cloth the patch is red-brown, not black).
		local sk = Pick(rng, "soak")
		local half, rot = mk.len or 1.6, rng:Range(-3, 3)
		Layer(layers, sk, PASS_FILTER, K_SOAK, half, 1, rot, 0, 0, absorb)
		Layer(layers, sk, PASS_COLOUR, K_SOAKB, half, 1, rot, 0, 0, 0.42 * absorb)
	elseif kind == "graze" then
		-- A furrow along the skin: as long as the path, a few projectile widths across
		local hy = Clamp(r.caliber * 2.6, 0.55, 1.3)
		local st = Clamp(((mk.len or 3) * 0.5 / 0.82) / hy, 1, 4.5)
		local rot = rng:Range(-0.05, 0.05)
		if skin then
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, hy * 1.5, st, rng:Range(-3, 3), 0, 0, 0.5, true)
			Layer(layers, Pick(rng, "blood"), PASS_COLOUR, K_BLOOD, hy * rng:Range(0.9, 1.3), 1, down, rng:Range(-0.3, 0.3) * hy * st, 0, 0.85)
			Layer(layers, Pick(rng, "crust"), PASS_COLOUR, K_CRUST, hy * 0.8, st * 0.8, rot, 0, 0, 0.9, true)
			local f = Pick(rng, "furrow")
			Hole(mk, Layer(layers, f, PASS_COLOUR, K_FIXED, hy, st, rot), f)
			Layer(layers, f .. "_g", PASS_GLOSS, K_GLOSS, hy, st, rot)
		else
			-- cloth torn open along the path, the furrow showing through it
			Layer(layers, Pick(rng, "soak"), PASS_FILTER, K_SOAK, hy * 1.7, st * 0.8, rng:Range(-3, 3), 0, 0, absorb)
			local f = Pick(rng, "furrow")
			-- (in the shade of the torn cloth, and soaked dark like it)
			Hole(mk, Layer(layers, f, PASS_COLOUR, K_FIXED, hy * 0.85, st, rot, 0, 0, 0.95), f).tint = 0.5
		end

	elseif kind == "blunt" then
		-- A blunt weapon: nothing is opened. On bare skin a bruise that comes up over the first
		-- minute, larger for a harder blow and a wider weapon; reddening that is there at once
		-- and gives way to it; and, from a hard blow, a scrape drawn along the way it went.
		-- Under cloth there is nothing to see: no mark.
		if skin then
			local dmg = r.damage or 10
			local wide = (r.diameter or 0) > 0 and r.diameter / 4 or 2
			-- (the damage of a blunt blow as it arrives is small: 1 to about 8. sh_config.lua, bluntMin)
			local size = Clamp(1.0 + dmg * 0.28 + wide * 0.14, 1.2, 3.2)
			local a = Clamp(0.5 + dmg * 0.07, 0.55, 0.95)
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, size, obl, rng:Range(-3, 3), 0, 0, a)
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, size * 0.55, obl, rng:Range(-3, 3), rng:Range(-0.2, 0.2) * size, rng:Range(-0.2, 0.2) * size, 0.75, true)
			local fl = Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_FLUSH, size * 0.7, obl, rng:Range(-3, 3), 0, 0, 0.6)
			fl.cr, fl.cg, fl.cb = 1.3, 0.62, 0.6
			if dmg >= 2 then
				local sc = Layer(layers, Pick(rng, "furrow"), PASS_COLOUR, K_FIXED, Clamp(0.5 + wide * 0.1, 0.5, 0.9), Clamp(1.2 + dmg * 0.12, 1.3, 2.4), rng:Range(-0.2, 0.2), 0, 0, 0.45, true)
				sc.tint = 0.8
			end
		end

	elseif kind == "stab" then
		-- An edged weapon into the body (phase 44): a short slit as long as the blade is wide,
		-- hardly gaping, and behind it a deep, narrow way in. The blade's width and how deep it
		-- goes are the weapon's own numbers (sv_main.lua); nothing else about it is known.
		local wide = (r.diameter or 0) > 0 and r.diameter / 4 or 1
		local hl = Clamp(0.22 + 0.2 * wide, 0.3, 0.9)
		local hw = Clamp(0.07 + 0.03 * wide, 0.08, 0.16)
		local half = hw / 0.246
		local st = hl / (half * 0.543)
		local rot = rng:Range(-0.1, 0.1)
		if skin then
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, Clamp(hl * 2.2, 0.9, 1.8), 1.3, rng:Range(-0.3, 0.3), 0, 0, 0.3, true)
			local b = Pick(rng, "blood")
			local hb = Clamp(hl * 2.0, 0.7, 1.6)
			Layer(layers, b, PASS_COLOUR, K_BLOOD, hb, 1, down)
			Layer(layers, Pick(rng, "crust"), PASS_COLOUR, K_CRUST, hb * 0.8, 1, down, 0, 0, 0.95, true)
			Hole(mk, Layer(layers, "tear1", PASS_COLOUR, K_FIXED, half, st, rot), "tear1")
			Layer(layers, b .. "_g", PASS_GLOSS, K_GLOSS, hb, 1, down, 0, 0, 0.7)
			Layer(layers, "tear1_g", PASS_GLOSS, K_GLOSS, half, st, rot)
		else
			Layer(layers, Pick(rng, "soak"), PASS_FILTER, K_SOAK, Clamp(hl * 2.6, 1.1, 2.2), 1, rng:Range(-3, 3), 0, 0, absorb)
			Hole(mk, Layer(layers, "tear1", PASS_COLOUR, K_FIXED, half, st, rot, 0, 0, 0.95), "tear1").tint = 0.55
		end

	elseif kind == "cut" then
		-- An edged weapon (phase 43): a gash, long and narrow, with clean edges and no collar.
		-- How long and how wide it gapes: by what the blow did (the damage Z-City booked for
		-- it; nothing else about the blade is known here). It lies along the way the blow went
		-- over the skin where it came at a slant; a blow straight in has no such way, and the
		-- gash then lies as the mark's own seed has it.
		local dmg = r.damage or 20
		local len = Clamp(1.3 + dmg * 0.045, 1.4, 4.2)
		local hw = Clamp(0.14 + dmg * 0.003, 0.15, 0.30)
		local half = hw / 0.246
		local st = (len * 0.5) / (half * 0.543)
		local rot = rng:Range(-0.1, 0.1)
		if skin then
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, Clamp(len * 0.55, 1.3, 2.6), 1.6, rng:Range(-0.3, 0.3), 0, 0, 0.35, true)
			local b = Pick(rng, "blood")
			local hb = Clamp(len * 0.5, 1.0, 2.4)
			Layer(layers, b, PASS_COLOUR, K_BLOOD, hb, 1, down)
			Layer(layers, Pick(rng, "crust"), PASS_COLOUR, K_CRUST, hb * 0.8, 1, down, 0, 0, 0.95, true)
			Hole(mk, Layer(layers, "tear1", PASS_COLOUR, K_FIXED, half, st, rot), "tear1")
			Layer(layers, b .. "_g", PASS_GLOSS, K_GLOSS, hb, 1, down, 0, 0, 0.7)
			Layer(layers, "tear1_g", PASS_GLOSS, K_GLOSS, half, st, rot)
		else
			-- through cloth: the cloth cut with the skin, taking up blood round the cut
			Layer(layers, Pick(rng, "soak"), PASS_FILTER, K_SOAK, Clamp(len * 0.7, 1.4, 3.4), 1, rng:Range(-3, 3), 0, 0, absorb)
			Hole(mk, Layer(layers, "tear1", PASS_COLOUR, K_FIXED, half, st, rot, 0, 0, 0.95), "tear1").tint = 0.55
		end

	elseif kind == "exit" then
		-- Torn open from inside: no abrasion, no soot, whatever the range
		local ro = r.exitOpening
		local big = ro > r.caliber * 0.85
		if skin then
			local tear = (r.boneHit and big) and (rng:Next() < 0.6 and "tear3" or "tear2") or (not big and (rng:Next() < 0.5 and "tear4" or "tear1")) or Pick(rng, "tear")
			local half = Clamp(ro / 0.36, 0.7, 3.2)
			local rot = rng:Range(-3.14, 3.14)
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, Clamp(half * 2.2, 1.8, 4), 1, rng:Range(-3, 3), 0, 0, 0.75, true)
			local b = Pick(rng, "blood")
			local hb = half * rng:Range(1.3, 1.9)
			Layer(layers, b, PASS_COLOUR, K_BLOOD, hb, 1, down)
			Layer(layers, Pick(rng, "crust"), PASS_COLOUR, K_CRUST, hb * 0.8, 1, down, 0, 0, 0.95, true)
			Hole(mk, Layer(layers, tear, PASS_COLOUR, K_FIXED, half, 1, rot), tear)
			Layer(layers, b .. "_g", PASS_GLOSS, K_GLOSS, hb, 1, down, 0, 0, 0.7)
			Layer(layers, tear .. "_g", PASS_GLOSS, K_GLOSS, half, 1, rot)
		else
			local half = Clamp(ro / 0.3, 0.8, 3.2)
			local rot = rng:Range(-3.14, 3.14)
			Layer(layers, Pick(rng, "soak"), PASS_FILTER, K_SOAK, Clamp(half * 1.9, 1.6, 4.2), 1, rng:Range(-3, 3), 0, 0, absorb)
			local t = Pick(rng, "clothtear")
			Hole(mk, Layer(layers, t, PASS_COLOUR, K_FIXED, half, 1, rot), t)
			Layer(layers, t .. "_g", PASS_GLOSS, K_GLOSS, half, 1, rot, 0, 0, 0.6)
		end

	else
		-- Entry. Around the defect lies what the shot left on the first surface it met, by range:
		-- soot (contact, near), powder stippling (near, medium), the muzzle's imprint (contact)
		local rd = r.opening
		local reach = r.reachK or 1
		local contact = r.range == WD.RANGE_CONTACT
		if r.soot > 0 then
			-- (pressed on: little escapes, a narrow dense ring. A hand away: wide and thin)
			local half = contact and Clamp(rd * 4.5 * reach, 0.9, 1.6) or Clamp(rd * 11 * reach, 2, 3.6)
			Layer(layers, Pick(rng, "soot"), PASS_COLOUR, K_FIXED, half, obl, rng:Range(-3, 3), half * 0.3 * (obl - 1), 0, (contact and 0.95 or 0.6) * r.soot)
		end
		if r.stipple > 0 then
			local half = Clamp(rd * (r.range == WD.RANGE_MEDIUM and 17 or 12) * reach, 2.4, 4.6)
			Layer(layers, Pick(rng, "stipple"), PASS_COLOUR, K_FIXED, half, obl, rng:Range(-3, 3), half * 0.25 * (obl - 1), 0, r.stipple * (skin and 1 or 0.4), true)
		end
		if skin then
			Layer(layers, Pick(rng, "bruise"), PASS_COLOUR, K_BRUISE, Clamp(rd * (6 + 9 * r.cavity), 1.5, 3.6), obl, rng:Range(-3, 3), 0, 0, 0.45 + 0.4 * r.cavity, true)
			if contact and r.imprint > 0.45 then
				Layer(layers, Pick(rng, "imprint"), PASS_COLOUR, K_FIXED, Clamp(rd * 3.6, 0.8, 1.3), 1, rng:Range(-3, 3), 0, 0, 0.85 * r.imprint, true)
			end
			-- abrasion collar: wider on the side the bullet came from
			local cr = rd * (1.35 + 0.5 * r.collar)
			Layer(layers, Pick(rng, "collar"), PASS_COLOUR, K_FIXED, cr / 0.72, obl ^ 1.25, rng:Range(-3, 3), -rd * 0.9 * (obl - 1), 0, 0.9)
			if r.wipe > 0 then
				Layer(layers, Pick(rng, "wipe"), PASS_COLOUR, K_FIXED, rd * 1.25 / 0.74, obl, 0, 0, 0, 0.55 * r.wipe, true)
			end
			local b = Pick(rng, "blood")
			local hb = Clamp(rd * rng:Range(3.6, 5.2), 0.8, 1.7)
			Layer(layers, b, PASS_COLOUR, K_BLOOD, hb, 1, down)
			Layer(layers, Pick(rng, "crust"), PASS_COLOUR, K_CRUST, hb * 0.8, 1, down, 0, 0, 0.95, true)
			local hole, half
			if r.stellate > 0 then
				-- a contact wound over bone, burst open by the gas
				hole, half = Pick(rng, "stellate"), rd * (3 + 2.2 * r.stellate)
			else
				hole, half = Pick(rng, "defect"), rd / 0.5
			end
			local rot = rng:Range(-0.15, 0.15) + (r.stellate > 0 and rng:Range(-3, 3) or 0)
			local st = r.stellate > 0 and 1 or obl
			Hole(mk, Layer(layers, hole, PASS_COLOUR, K_FIXED, half, st, rot), hole)
			Layer(layers, b .. "_g", PASS_GLOSS, K_GLOSS, hb, 1, down, 0, 0, 0.7)
			Layer(layers, hole .. "_g", PASS_GLOSS, K_GLOSS, half, st, rot)
		else
			-- through cloth: the hole in the weave (its dark rim is the bullet wipe), blood coming
			-- up into the cloth around it
			Layer(layers, Pick(rng, "soak"), PASS_FILTER, K_SOAK, Clamp(rd * 7, 1.3, 2.4), 1, rng:Range(-3, 3), 0, 0, absorb)
			local h = Pick(rng, "clothhole")
			local half = rd / 0.29
			Hole(mk, Layer(layers, h, PASS_COLOUR, K_FIXED, half, obl, rng:Range(-3, 3)), h)
			Layer(layers, h .. "_g", PASS_GLOSS, K_GLOSS, half, obl, 0, 0, 0, 0.5)
		end
	end

	local S = 0
	for i = 1, #layers do
		local l = layers[i]
		local ext = l.half * max(l.st, 1) + max(abs(l.ox), abs(l.oy))
		if ext > S then S = ext end
	end
	return layers, S
end

------------------------------------------------------------------------------------------
-- Creation
------------------------------------------------------------------------------------------
-- Tangent frame of the mark in bind space: normal n, +x (t) along `dir` projected onto the skin.
local function Frame(m, tri, bdx, bdy, bdz)
	local nx, ny, nz = BM.BindNormal(m, tri)
	local tx, ty, tz = 0, 0, 0
	if bdx then
		local dn = bdx * nx + bdy * ny + bdz * nz
		tx, ty, tz = bdx - nx * dn, bdy - ny * dn, bdz - nz * dn
	end
	local tl = sqrt(tx * tx + ty * ty + tz * tz)
	if tl < 0.15 then
		tx, ty, tz = ABL.Perp(nx, ny, nz)
	else
		tx, ty, tz = tx / tl, ty / tl, tz / tl
	end
	local bx, by, bz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
	return nx, ny, nz, tx, ty, tz, bx, by, bz
end

------------------------------------------------------------------------------------------
-- The recess: what is behind a wound's opening (see the head of this file).
-- Built once with the mark, in the wound's own space: x along the mark's tangent (the
-- projectile's direction along the skin), y across, z out of the skin, the origin on the skin
-- at the wound. Nothing in it is asked for again while the wound exists; where the wound's
-- space lies on its bone is worked out with the patch (Bake), and again when skin that bends
-- between bones has moved.
------------------------------------------------------------------------------------------
local CAV_N = 14            -- places round the wall
-- Down the wall: how deep (share of the depth) and how wide (share of the opening) each ring
-- is. An entry is a funnel: skin pushed in, narrowing to the track. An exit is undermined:
-- wider under the skin than at it, then closing. A graze is a shallow trench. The first ring
-- stands a little over the skin and wider than the opening, so that the skin's edge overhangs.
local CAV_PROFILE = {
	entry = { s = { 0, 0.10, 0.30, 0.58, 0.84, 1 }, rho = { 1.18, 1.05, 0.84, 0.62, 0.42, 0.20 } },
	exit  = { s = { 0, 0.12, 0.34, 0.62, 0.86, 1 }, rho = { 1.18, 1.28, 1.22, 0.98, 0.64, 0.28 } },
	graze = { s = { 0, 0.30, 0.70, 1 }, rho = { 1.14, 0.94, 0.64, 0.30 } },
	-- a cut: its two faces come together at the bottom
	cut   = { s = { 0, 0.22, 0.58, 1 }, rho = { 1.14, 0.80, 0.42, 0.10 } },
}
local function RhoAt(p, s)
	local S, R = p.s, p.rho
	for j = 2, #S do
		if s <= S[j] then
			local k = (s - S[j - 1]) / (S[j] - S[j - 1])
			return R[j - 1] + (R[j] - R[j - 1]) * k
		end
	end
	return R[#R]
end

-- The colour of the wall at a depth (0 at the skin, 1 at the floor), as it would be in full
-- light: the cut edge of the skin, fat under it where the opening is wide enough to show it,
-- muscle, and all of it darker the deeper it lies. Never black: a wound's inside is seen.
-- cloth: the first band is the edge of the cloth, not of skin. pale: a floor of bone.
local function WallColour(s, wide, cloth, pale, jit)
	local r, g, b
	if cloth and s < 0.06 then
		-- (the cloth's own thickness, dark with what it took up; under it the body's wound as
		-- on bare skin. All of the first band in the cloth's colour made a hole in cloth a
		-- black shape with nothing in it: run w3d3.)
		r, g, b = 0.22, 0.17, 0.16
	elseif s < 0.13 then
		local k = s / 0.13
		r, g, b = 0.55 - 0.10 * k, 0.25 - 0.08 * k, 0.23 - 0.07 * k
	elseif s < 0.33 and wide then
		local k = (s - 0.13) / 0.20
		-- (fat: pale and yellowish under the blood on it, never orange: run w3d4)
		r, g, b = 0.50 - 0.10 * k, 0.30 - 0.16 * k, 0.19 - 0.09 * k
	else
		local k = Clamp((s - 0.13) / 0.87, 0, 1)
		r, g, b = 0.50 - 0.24 * k, 0.085 - 0.04 * k, 0.085 - 0.04 * k
	end
	if pale and s > 0.8 then
		local k = (s - 0.8) / 0.2
		r, g, b = r + (0.62 - r) * k, g + (0.52 - g) * k, b + (0.42 - b) * k
	end
	local ao = (1 - 0.44 * s ^ 0.8) * (1 + jit)
	return r * ao, g * ao, b * ao
end

-- A place of the opening's layer (q: the layer's own -1..1) in the wound's space (units).
local function HoleToWound(l, qx, qy)
	local c, s = cos(l.rot), sin(l.rot)
	return l.ox + l.half * l.st * (c * qx + s * qy), l.oy + l.half * (-s * qx + c * qy)
end

local function BuildCavity(mk, r)
	local l, name = mk.hole, mk.holeName
	local ext = l and WC.open[name]
	if not ext then return end
	local kind = mk.kind
	local stellate = string.find(name, "stellate", 1, true) ~= nil
	local prof = CAV_PROFILE[(kind == "graze" and "graze") or (kind == "cut" and "cut") or ((kind == "exit" or stellate) and "exit") or "entry"]
	-- the opening's two half-widths in units, and its size
	local ru, rv = l.half * l.st * ext[1], l.half * ext[2]
	local R0 = sqrt(ru * rv)
	-- how deep: an entry is a narrow way in, deeper the more the tissue round the track was
	-- stretched; an exit is wide and shallower for its width; a wound burst open over bone is
	-- shallow with bone for a floor; a graze is a trench a projectile's width deep
	local D
	if kind == "graze" then D = Clamp(rv * 1.3, 0.10, 0.30)
	elseif kind == "cut" then D = Clamp(0.28 + (r.damage or 20) * 0.011, 0.3, 0.95)
	elseif kind == "stab" then D = Clamp(0.4 + ((r.energy or 0) * 1.5) * 0.085, 0.45, WC.cavMax)
	elseif stellate then D = Clamp(R0 * 0.8, WC.cavMin, 0.6)
	elseif kind == "exit" then D = Clamp(R0 * (1.3 + 0.9 * (r.cavity or 0)), WC.cavMin, WC.cavMax)
	else D = Clamp(R0 * (2.4 + 1.8 * (r.cavity or 0)), WC.cavMin, WC.cavMax) end
	if not mk.skin then D = D + 0.05 end
	-- which way it leans: along the projectile's path into the body (an entry: the way the
	-- projectile went; an exit: back the way it came)
	local kx, ky = 0, 0
	if mk.bdx and kind ~= "graze" then
		local dt = mk.bdx * mk.tx + mk.bdy * mk.ty + mk.bdz * mk.tz
		local db = mk.bdx * mk.bx + mk.bdy * mk.by + mk.bdz * mk.bz
		local dn = mk.bdx * mk.nx + mk.bdy * mk.ny + mk.bdz * mk.nz
		if kind == "exit" then dt, db, dn = -dt, -db, -dn end
		local inw = max(-dn, 0.45)
		kx, ky = dt / inw, db / inw
		local kl = sqrt(kx * kx + ky * ky)
		if kl > WC.cavLean then kx, ky = kx / kl * WC.cavLean, ky / kl * WC.cavLean end
	end
	local rng = ABL.RNG((r.id or 0) * 31 + (kind == "exit" and 7717 or 3301))
	local wide = R0 > 0.42 or (kind == "cut" and D > 0.5)
	local pale = stellate or (r.skull and kind ~= "graze") or false
	local S, RHO = prof.s, prof.rho
	local nr = #S
	-- rings: positions, colours, texture coordinates
	local px, py, pz, cr, cg, cb, tu, tv = {}, {}, {}, {}, {}, {}, {}, {}
	local n = 0
	-- (how far in or out each place round the wall stands: the same all the way down, with a
	-- little of its own at each ring, so that the wall has ridges and is no turned bowl)
	local ridge = {}
	for k = 1, CAV_N do ridge[k] = rng:Range(-0.13, 0.13) end
	local twist = rng:Range(0, 1)
	for j = 1, nr do
		local s = S[j]
		local z = (j == 1) and 0.07 or -D * s
		local sx, sy = (j == 1) and 0 or kx * D * s, (j == 1) and 0 or ky * D * s
		for k = 1, CAV_N do
			local th = (k - 1) / CAV_N * 6.2831853
			local rr = RHO[j] * ((j == 1) and 1 or (1 + ridge[k] + rng:Range(-0.07, 0.07)))
			local x, y = HoleToWound(l, ext[1] * cos(th) * rr, ext[2] * sin(th) * rr)
			n = n + 1
			px[n], py[n], pz[n] = x + sx, y + sy, z + ((j > 2) and rng:Range(-0.04, 0.04) * D or 0)
			cr[n], cg[n], cb[n] = WallColour(s, wide, not mk.skin, pale, rng:Range(-0.14, 0.14))
			tu[n], tv[n] = (k - 1) / CAV_N * 2 + twist, s * 1.3 + rng:Range(-0.03, 0.03)
		end
	end
	-- the floor's middle, a little deeper and off the middle
	local fx, fy = HoleToWound(l, ext[1] * rng:Range(-0.08, 0.08), ext[2] * rng:Range(-0.08, 0.08))
	n = n + 1
	px[n], py[n], pz[n] = fx + kx * D * 1.03, fy + ky * D * 1.03, -D * 1.05
	cr[n], cg[n], cb[n] = WallColour(1, wide, not mk.skin, pale, 0)
	tu[n], tv[n] = twist + 1, 1.45
	local ox, oy = HoleToWound(l, 0, 0)
	mk.cav = {
		prof = prof, D = D, kx = kx, ky = ky, R0 = R0, nr = nr, n = n, ox = ox, oy = oy,
		px = px, py = py, pz = pz, cr = cr, cg = cg, cb = cb, tu = tu, tv = tv,
		-- the outline at the opening itself, about its middle: the surface of the blood
		ex = ext[1], ey = ext[2],
		pale = pale, graze = kind == "graze",
	}
end

local cvec = Vector()
local function CV(c, i, mul)
	cvec:SetUnpacked(c.px[i], c.py[i], c.pz[i])
	mesh.Position(cvec)
	mesh.TexCoord(0, c.tu[i], c.tv[i])
	mesh.Color(min(255, c.cr[i] * 255 * mul), min(255, c.cg[i] * 255 * mul), min(255, c.cb[i] * 255 * mul), 255)
	mesh.AdvanceVertex()
end

-- The recess as two static meshes in the wound's space: the wall with its floor, and the
-- surface of the blood (a disc the size of the opening, about the opening's middle: it is put
-- at its depth, and made as wide as the wall is there, when it is drawn).
local function BakeCavity(mk)
	local c = mk.cav
	if not c or c.mesh then return end
	local N, nr = CAV_N, c.nr
	local ms = Mesh()
	mesh.Begin(ms, MATERIAL_TRIANGLES, (nr - 1) * N * 2 + N)
	for j = 1, nr - 1 do
		for k = 1, N do
			local k2 = k % N + 1
			local a, b = (j - 1) * N + k, (j - 1) * N + k2
			local d, e = j * N + k, j * N + k2
			-- (wound so that the side toward the middle is the front: the wall is seen from inside)
			CV(c, a, 1) CV(c, d, 1) CV(c, b, 1)
			CV(c, b, 1) CV(c, d, 1) CV(c, e, 1)
		end
	end
	local mid = c.n
	for k = 1, N do
		local k2 = k % N + 1
		CV(c, (nr - 1) * N + k, 1) CV(c, mid, 1) CV(c, (nr - 1) * N + k2, 1)
	end
	mesh.End()
	c.mesh = ms
	-- the blood: a fan about the middle
	local l = mk.hole
	local bs = Mesh()
	mesh.Begin(bs, MATERIAL_TRIANGLES, N)
	local function BV(x, y, u, v, lum)
		cvec:SetUnpacked(x, y, 0)
		mesh.Position(cvec)
		mesh.TexCoord(0, u, v)
		mesh.Color(255 * lum, 255 * lum, 255 * lum, 255)
		mesh.AdvanceVertex()
	end
	for k = 1, N do
		local t1, t2 = (k - 1) / N * 6.2831853, (k % N) / N * 6.2831853
		local x1, y1 = HoleToWound(l, c.ex * cos(t1), c.ey * sin(t1))
		local x2, y2 = HoleToWound(l, c.ex * cos(t2), c.ey * sin(t2))
		-- (darker toward the wall: the blood is shallower there and stands in its shade)
		BV(x1 - c.ox, y1 - c.oy, 0.5 + 0.5 * cos(t1), 0.5 + 0.5 * sin(t1), 0.62)
		BV(x2 - c.ox, y2 - c.oy, 0.5 + 0.5 * cos(t2), 0.5 + 0.5 * sin(t2), 0.62)
		BV(0, 0, 0.5, 0.5, 1)
	end
	mesh.End()
	c.blood = bs
end

local function FreeCavity(mk)
	local c = mk.cav
	if not c then return end
	if c.mesh then c.mesh:Destroy() c.mesh = nil end
	if c.blood then c.blood:Destroy() c.blood = nil end
	-- (and its form: "The form" below)
	if c.fout then c.fout:Destroy() c.fout = nil end
	if c.fin then c.fin:Destroy() c.fin = nil end
	if c.fcap then c.fcap:Destroy() c.fcap = nil end
	if c.fblood then c.fblood:Destroy() c.fblood = nil end
end

------------------------------------------------------------------------------------------
-- The form (phase 47): a wound as one piece of geometry on the body, lit.
-- The recess above is a hole behind a flat picture: the skin round it lies as it lay, the
-- opening is an outline cut into it, and what is seen through it is lit from nowhere. From an
-- arm's length that is a dark shape on the body (measured: scene wound3d, run wnd0). A wound
-- has a form: the skin stands up round it, turns in at its edge (an entry) or out (an exit),
-- and goes down into it, and light falls on all of that from one side.
--   * Geometry in the wound's own space: rings from the level skin a few widths out, up over
--     the rim and in over the lip (the outside), and from the lip down the wall to the floor
--     (the inside). It lies on the body's own surface: every place of it
--     is lifted by as much as the skin stands off the wound's plane there (a wound on an arm
--     goes round the arm). The opening's outline is the geometry's own, by what the wound is:
--     an entry's nearly round, an exit's torn further in a few places, a cut's two lips meeting
--     in a point at each end; it strays, and the rim is higher here than there. No two are the
--     same, and none is a circle. (The painted opening and its outline as a texture are not
--     drawn where a wound has its form: they are the recess's.)
--   * The outside reaches from the level skin over the rim and in over the lip, where the
--     wound's inside begins: all of that is the body's own surface, and so is drawn as light
--     and shade alone over what is there (see below). The opening proper is what lies within
--     the lip: skin, cloth and the blood on them are seen to turn into it.
--   * The inside (wall, floor, the blood that stands in it) is drawn through the opening (the
--     stencil buffer, as for the recess). Its faces are seen from inside only: the near wall
--     hides nothing, the far wall shows, as it is with a real hole. It is drawn twice: first
--     its depth alone (which face is the nearest in each place), then those nearest faces
--     multiplied over the picture that is in the opening: each leaves of it what the inside's
--     picture says for its depth (redder and darker the deeper) times the light it gets, as a
--     share of the light on the skin round the wound. So the inside is as dark as its
--     surroundings make it, under their light, and never the brightest thing there (with
--     colours of its own it was, on cloth dark with blood: run wf3). A little red of its own
--     is added by the light of the place (C.WoundFX.inOwn: what is seen of a wound in black
--     cloth), and where the blood in it is wet, the one light's highlight.
--   * The outside is drawn as light and shade alone over what is there (skin, cloth, the blood
--     that has run over them): W.DrawRelief, after the blood on the body. Twice: once
--     multiplied (white where the rim is lit as much as level skin or more, darker where it
--     turns from the light), once added on in proportion to what is there (black where it is
--     level, lighter where it turns to the light). White and black are the same however light
--     is counted, so where the form is level with the skin nothing changes and it has no edge.
--     (Run wf1 drew it once, multiplied by two over a middle grey. The engine blends in linear
--     light, where that grey is 0.22 and not a half: every wound sat in a dark disc.) Measured
--     in one frame, the picture read just before and just after (W.probe): level skin at a
--     form's outer end changes by 0 to 2 of 255. Where it is wet a rim gives the light back as
--     a soft sheen besides, on its slopes only (RAMP_GLINT).
--     It is not tested against the body's depth: a few hundredths of a unit over a skin that
--     bends cannot win that cleanly (run wf1: stripes, and on a thigh pieces of it standing in
--     the air). It is drawn where this wound's own patch of skin is seen, which the patch
--     itself writes into the stencil buffer.
-- No anatomy is drawn: the inside is what the wound is in, gone red and dark.
-- What the engine does with a mesh made here under a lit material was measured before (the
-- scene neuro_litprobe: a mesh drawn directly under lights set with render.SetLocalModelLights
-- is lit by them, vertex by vertex, and by nothing else).
------------------------------------------------------------------------------------------
local floor, ceil = math.floor, math.ceil
-- Round the opening, from the level skin inward:
--   out   { how far out from the opening's edge (in widths), how high (share of the rim's height) }
--   lip   where the skin, turned in over the edge, ends and the wound's inside begins:
--         { share of the opening, height (share of the rim's height) }
--   wall  down it: { share of the opening, share of the depth }
-- The skin from the level ground to the lip is the outside: it is the body's own surface, drawn
-- as light and shade over what is there, darker and darker as it turns into the hole. So the
-- opening has no drawn edge: skin, cloth or the blood on them go down into it. (Until run wf3
-- the outside ended at the opening's edge, and everything inside it had colours of its own: on
-- cloth dark with blood the inside was the brightest thing there, a red shape lying on the body.)
local FORM = {
	-- pushed in: the skin rises a little round the hole and rolls into it
	entry = {
		out = { { 2.6, 0 }, { 1.9, 0.08 }, { 1.35, 0.28 }, { 0.92, 0.6 }, { 0.58, 0.9 }, { 0.32, 1 }, { 0.15, 0.82 }, { 0.04, 0.38 } },
		lip = { 0.80, -1.0 },
		wall = { { 0.74, 0.16 }, { 0.62, 0.36 }, { 0.48, 0.60 }, { 0.34, 0.82 }, { 0.20, 0.96 } },
	},
	-- torn outward: the edge stands up, and the way in is wide. (Wider underneath than at the
	-- skin, as the recess has it, puts every wall under its own edge: none of them is lit, and
	-- the opening is a dark band round a pool. Run wf2.)
	exit = {
		out = { { 3.0, 0 }, { 2.2, 0.07 }, { 1.6, 0.25 }, { 1.1, 0.52 }, { 0.7, 0.82 }, { 0.38, 1 }, { 0.18, 0.96 }, { 0.05, 0.66 } },
		lip = { 0.88, -0.30 },
		wall = { { 0.84, 0.14 }, { 0.76, 0.34 }, { 0.62, 0.58 }, { 0.46, 0.80 }, { 0.28, 0.95 } },
	},
	-- a furrow: low banks along a shallow trench
	graze = {
		out = { { 1.9, 0 }, { 1.3, 0.16 }, { 0.8, 0.55 }, { 0.42, 1 }, { 0.16, 0.74 }, { 0.04, 0.3 } },
		lip = { 0.82, -0.6 },
		wall = { { 0.70, 0.35 }, { 0.48, 0.75 }, { 0.25, 0.97 } },
	},
	-- a cut or a thrust: two lips that hardly rise, their faces meeting below
	cut = {
		out = { { 1.7, 0 }, { 1.1, 0.2 }, { 0.6, 0.66 }, { 0.28, 1 }, { 0.1, 0.62 }, { 0.03, 0.22 } },
		lip = { 0.80, -0.5 },
		wall = { { 0.68, 0.22 }, { 0.40, 0.58 }, { 0.12, 0.92 } },
	},
}
local function FormOf(mk)
	local kind = mk.kind
	if kind == "graze" then return FORM.graze, WC.lipGraze end
	if kind == "cut" or kind == "stab" then return FORM.cut, WC.lipCut end
	if kind == "exit" or string.find(mk.holeName or "", "stellate", 1, true) then return FORM.exit, WC.lipExit end
	return FORM.entry, WC.lipEntry
end

-- The width the rim is measured in (units), and how far the form reaches from the wound's middle:
-- the patch has to hold all of it.
local function FormSize(mk)
	local l, ext = mk.hole, WC.open[mk.holeName]
	local ru, rv = l.half * l.st * ext[1], l.half * ext[2]
	local w = min(sqrt(ru * rv), 1.6 * min(ru, rv))
	local prof = FormOf(mk)
	return w, max(ru, rv) + prof.out[1][1] * w + max(abs(l.ox), abs(l.oy))
end

-- Its texture's v: 0.02 on the level skin, 0.24 on the rim's crest, 0.46 at the opening's edge,
-- 0.53 on the lip inside it, 0.56 to 0.94 down the wall, 0.97 on the floor. Three pictures are
-- read by it (W.Prepare makes them): the rim's (how much darker than the skin under it a place
-- is by its own shade, whatever the light: white, but from the edge to the lip, which stand in
-- the shade of the hole), the inside's (what a place leaves of the picture it is drawn over:
-- redder and darker the deeper) and the one that says where a wet rim has a sheen.
local V_EDGE, V_LIP, V_WALL, V_FLOOR = 0.46, 0.53, 0.56, 0.97

-- n values round a ring, even from one to the next: three waves of their own phase, h1, h2 and
-- h3 of them to a turn (slow ones where nothing is said).
local function Wavy(rng, n, amp, h1, h2, h3)
	h1, h2, h3 = h1 or 2, h2 or 3, h3 or 5
	local p1, p2, p3 = rng:Range(0, 6.2832), rng:Range(0, 6.2832), rng:Range(0, 6.2832)
	local w1, w2, w3 = rng:Range(0.5, 1), rng:Range(0.3, 0.8), rng:Range(0.2, 0.6)
	local s = amp / (w1 + w2 + w3)
	local a = {}
	for k = 1, n do
		local th = (k - 1) / n * 6.2831853
		a[k] = s * (w1 * sin(h1 * th + p1) + w2 * sin(h2 * th + p2) + w3 * sin(h3 * th + p3))
	end
	return a
end

-- How far the body's surface stands off the wound's own plane, from the patch's triangles (bind
-- pose): the triangles in the wound's space, each in the squares of a grid it reaches into (a
-- place is then asked of the few triangles of its own square, not of all of them: with all of
-- them a form on a head cost a frame of 45 ms, run wf1), and the height at (x, y) of it; nil
-- where the patch has no triangle.
local FIELD_N = 12
local function SurfaceField(mk, m, reach)
	local P = mk.patch
	if not P or P.n < 3 then return nil end
	local cx, cy, cz = BM.BindPoint(m, mk.tri, mk.u, mk.v)
	local nx, ny, nz, tx, ty, tz, bx, by, bz = mk.nx, mk.ny, mk.nz, mk.tx, mk.ty, mk.tz, mk.bx, mk.by, mk.bz
	local vx, vy, vz = m.vx, m.vy, m.vz
	local ids = P.ids
	local N = FIELD_N
	local inv = N / (2 * reach)
	local cells, count = {}, 0
	for c = 1, P.n - 2, 3 do
		local e = {}
		for k = 0, 2 do
			local id = ids[c + k]
			local dx, dy, dz = vx[id] - cx, vy[id] - cy, vz[id] - cz
			e[k * 3 + 1], e[k * 3 + 2], e[k * 3 + 3] = dx * tx + dy * ty + dz * tz, dx * bx + dy * by + dz * bz, dx * nx + dy * ny + dz * nz
		end
		local x1, y1, x2, y2, x3, y3 = e[1], e[2], e[4], e[5], e[7], e[8]
		local det = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
		if abs(det) > 1e-9 then
			e[10] = 1 / det
			local i0, i1 = max(0, floor((min(x1, x2, x3) + reach) * inv)), min(N - 1, floor((max(x1, x2, x3) + reach) * inv))
			local j0, j1 = max(0, floor((min(y1, y2, y3) + reach) * inv)), min(N - 1, floor((max(y1, y2, y3) + reach) * inv))
			for j = j0, j1 do
				for i = i0, i1 do
					local q = j * N + i + 1
					local list = cells[q]
					if not list then list = {} cells[q] = list end
					list[#list + 1] = e
				end
			end
			count = count + 1
		end
	end
	if count == 0 then return nil end
	return { cells = cells, reach = reach, inv = inv, n = count }
end
local function SurfaceZ(F, x, y)
	local N = FIELD_N
	local i, j = floor((x + F.reach) * F.inv), floor((y + F.reach) * F.inv)
	if i < 0 or j < 0 or i >= N or j >= N then return nil end
	local list = F.cells[j * N + i + 1]
	if not list then return nil end
	local best
	for n = 1, #list do
		local e = list[n]
		local x3, y3 = e[7], e[8]
		local a = ((e[5] - y3) * (x - x3) + (x3 - e[4]) * (y - y3)) * e[10]
		local b = ((y3 - e[2]) * (x - x3) + (e[1] - x3) * (y - y3)) * e[10]
		local c = 1 - a - b
		if a >= -0.002 and b >= -0.002 and c >= -0.002 then
			local z = a * e[3] + b * e[6] + c * e[9]
			-- (of surfaces that lie over one another: the one nearest the wound's own plane)
			if not best or abs(z) < abs(best) then best = z end
		end
	end
	return best
end

local fvec, fnrm = Vector(), Vector()
-- The form of a mark as static meshes in the wound's space: the outside (c.fout), the inside
-- (c.fin), the opening between them as a lid (c.fcap: it is what is written into the stencil
-- buffer) and the surface of the blood that stands in it (c.fblood). Needs the mark's patch (the
-- body's surface round the wound). Built once.
local function BakeForm(mk, m)
	local c = mk.cav
	if not c or c.fout or c.fbad then return end
	local l, ext = mk.hole, WC.open[mk.holeName]
	if not l or not ext then c.fbad = true return end
	local t0 = SysTime()
	local prof, lipK = FormOf(mk)
	local w, reach = FormSize(mk)
	local F = SurfaceField(mk, m, reach * 1.02)
	if not F then c.fbad = true return end
	local r = mk.rec
	local kind = mk.kind
	local exitLike, slit = prof == FORM.exit, prof == FORM.cut
	local NS = Clamp(floor(WC.formSegs * (exitLike and 1.3 or 1)), 12, 64)
	local rng = ABL.RNG((r.id or 0) * 131 + (kind == "exit" and 911 or 577))
	local D, kx, ky = c.D, c.kx, c.ky
	-- how high the rim stands: by the opening's width and what made it; lower in cloth
	local H = Clamp(lipK * w * (exitLike and (1 + 0.5 * (r.cavity or 0)) or (0.85 + 0.3 * (r.cavity or 0))), WC.lipMin, WC.lipMax)
	if not mk.skin then H = H * WC.lipCloth end
	-- No wound is turned on a lathe: its edge strays (ir) and its rim is higher here than there
	-- (ih), an exit's much more than an entry's; and what was torn open from inside, or burst
	-- open over bone, is torn further in a few places (tr: how much further, as a share)
	local ir = Wavy(rng, NS, exitLike and 0.10 or (slit and 0.03 or 0.085))
	-- (and a finer unevenness over that, fi: the edge of a hole in skin or in cloth is not a
	-- drawn line. An entry was a clean dark circle on white cloth without it: run wf3. It is the
	-- edge's own: the rim's rings are set out from the outline without it, and take it up only
	-- close to the edge. Set out from an outline that fine, they crossed one another further out.)
	local fi = Wavy(rng, NS, exitLike and 0.045 or (slit and 0.012 or (mk.skin and 0.03 or 0.045)), 7, 9, 11)
	local ih = Wavy(rng, NS, exitLike and 0.45 or 0.18)
	local tr, tmax = {}, 0
	for k = 1, NS do tr[k] = 0 end
	-- torn places: an exit has one to three, a wound burst open over bone three to five; and the
	-- skin round an entry may have given a little in a place or two, the more the more the
	-- tissue round the track was stretched
	local stell = string.find(mk.holeName, "stellate", 1, true) ~= nil
	local nT = 0
	if exitLike then
		nT = (stell and 3 or 1) + floor(rng:Next() * 2.99)
	elseif not slit and kind ~= "graze" then
		nT = floor(rng:Next() * (1.4 + 2.2 * (r.cavity or 0)))
	end
	if nT > 0 then
		local at = rng:Range(0, NS)
		for i = 1, nT do
			local kc = floor(at + (i - 1 + rng:Range(-0.22, 0.22)) / nT * NS) % NS
			local len = (not exitLike and rng:Range(0.10, 0.24)) or (stell and rng:Range(0.45, 0.9)) or rng:Range(0.2, 0.55)
			-- (half as wide as this, in places round the ring)
			local hw = ((not exitLike and rng:Range(0.24, 0.36)) or (stell and rng:Range(0.2, 0.3)) or rng:Range(0.26, 0.42)) / 6.2832 * NS
			for d = -ceil(hw), ceil(hw) do
				local t = abs(d) / hw
				if t < 1 then
					local k = (kc + d) % NS + 1
					local b = len * (0.5 + 0.5 * cos(3.14159 * t)) ^ 1.3
					if b > tr[k] then tr[k] = b end
				end
			end
			if len > tmax then tmax = len end
		end
	end
	-- (the opening's extents are those of all of it, its tears with it)
	local shrink = 1 / (1 + 0.6 * tmax)
	-- the opening's outline about its middle: even (e0), with its strays (s), and which way is
	-- out from that
	local e0x, e0y, sx, sy, qx, qy = {}, {}, {}, {}, {}, {}
	for k = 1, NS do
		local th = (k - 1) / NS * 6.2831853
		local cs, sn = cos(th), sin(th)
		-- (a cut's two lips meet in a point at each end)
		if slit then sn = sn * abs(sn) ^ 0.55 end
		local x, y = HoleToWound(l, ext[1] * cs * shrink, ext[2] * sn * shrink)
		e0x[k], e0y[k] = x - c.ox, y - c.oy
		sx[k], sy[k] = e0x[k] * (1 + ir[k]), e0y[k] * (1 + ir[k])
	end
	for k = 1, NS do
		local a, b = sx[k % NS + 1], sy[k % NS + 1]
		local p, q = sx[(k - 2) % NS + 1], sy[(k - 2) % NS + 1]
		local nx, ny = b - q, -(a - p)
		local nl = sqrt(nx * nx + ny * ny)
		if nl < 1e-6 then nx, ny, nl = sx[k], sy[k], sqrt(sx[k] * sx[k] + sy[k] * sy[k]) + 1e-6 end
		nx, ny = nx / nl, ny / nl
		if nx * sx[k] + ny * sy[k] < 0 then nx, ny = -nx, -ny end
		qx[k], qy[k] = nx, ny
	end
	local out, wall = prof.out, prof.wall
	local nOut, nWall = #out, #wall
	local NR = nOut + 1 + nWall
	local fMax = out[1][1]
	-- rings: places (x, y of the wound's space; zr: how high over the skin there), texture v
	local X, Y, ZR, VV = {}, {}, {}, {}
	local crest = 1
	for j = 1, nOut do
		if out[j][2] >= out[crest][2] then crest = j end
	end
	for j = 1, NR do
		local o = (j - 1) * NS
		for k = 1, NS do
			local x, y, zr, v
			if j <= nOut then
				local f, zf = out[j][1], out[j][2]
				-- (the strays even out with the distance from the edge, a tear sooner than the rest)
				local fade = 1 - f / fMax
				local s = 1 + ir[k] * fade + (fi[k] + tr[k]) * fade * fade
				x = e0x[k] * s + qx[k] * f * w
				y = e0y[k] * s + qy[k] * f * w
				zr = zf * H * (1 + ih[k] * zf)
				v = (j <= crest) and (0.02 + 0.22 * zf) or (0.24 + (V_EDGE - 0.24) * (j - crest) / max(nOut - crest, 1))
			elseif j == nOut + 1 then
				local s = prof.lip[1] * (1 + ir[k] + fi[k] + tr[k] * 0.92)
				x, y = e0x[k] * s, e0y[k] * s
				zr = prof.lip[2] * H
				v = V_LIP
			else
				local e = wall[j - nOut - 1]
				local ds = e[2]
				-- (a tear is a split in the skin: it closes with the depth)
				local s = e[1] * (1 + ir[k] + fi[k] * (1 - ds) + tr[k] * 0.8 * (1 - ds) ^ 2 + rng:Range(-0.05, 0.05))
				x, y = e0x[k] * s + kx * D * ds, e0y[k] * s + ky * D * ds
				zr = -D * ds * (1 + rng:Range(-0.04, 0.04))
				v = V_WALL + (0.94 - V_WALL) * ds + rng:Range(-0.02, 0.02)
			end
			local i = o + k
			X[i], Y[i], ZR[i], VV[i] = x + c.ox, y + c.oy, zr, v
		end
	end
	-- the floor's middle
	local mid = NR * NS + 1
	X[mid], Y[mid], ZR[mid], VV[mid] = c.ox + kx * D * 1.03, c.oy + ky * D * 1.03, -D * 1.04, V_FLOOR
	-- on the body: every place as much higher as the skin stands off the wound's plane there. The
	-- outside from the edge outward (a place the patch does not reach: as high as the last that
	-- it did); the inside hangs from the edge above it.
	local Z = {}
	local eo = (nOut - 1) * NS
	local zsum, missed = 0, 0
	for k = 1, NS do
		local last = 0
		for j = nOut, 1, -1 do
			local i = (j - 1) * NS + k
			local z = SurfaceZ(F, X[i], Y[i])
			if z then last = z else z = last missed = missed + 1 end
			Z[i] = ZR[i] + z
		end
		local edge = Z[eo + k] - ZR[eo + k]
		zsum = zsum + edge
		for j = nOut + 1, NR do
			local i = (j - 1) * NS + k
			Z[i] = ZR[i] + edge
		end
	end
	Z[mid] = ZR[mid] + zsum / NS
	c.fz0 = zsum / NS
	-- normals: of the form as it would lie on a level skin (its light and shade are the form's
	-- own: what the body's curve does to the light is in the picture already), and the way
	-- along each ring (the lit shader's highlight wants it)
	local NX, NY, NZ, TX, TY, TZ = {}, {}, {}, {}, {}, {}
	local gain = WC.rimGain
	for j = 1, NR do
		local o = (j - 1) * NS
		local up, dn = (j > 1) and (o - NS) or o, (j < NR) and (o + NS) or o
		for k = 1, NS do
			local a, b = o + k % NS + 1, o + (k - 2) % NS + 1
			local t1x, t1y, t1z = X[a] - X[b], Y[a] - Y[b], ZR[a] - ZR[b]
			local i1, i2 = dn + k, up + k
			local t2x, t2y, t2z
			if j == NR then
				t2x, t2y, t2z = X[mid] - X[i2], Y[mid] - Y[i2], ZR[mid] - ZR[i2]
			else
				t2x, t2y, t2z = X[i1] - X[i2], Y[i1] - Y[i2], ZR[i1] - ZR[i2]
			end
			local nx, ny, nz = t1y * t2z - t1z * t2y, t1z * t2x - t1x * t2z, t1x * t2y - t1y * t2x
			-- (the side that is seen: the one that is up on the level skin)
			if j == 1 and nz < 0 then nx, ny, nz = -nx, -ny, -nz end
			if j <= nOut then nx, ny = nx * gain, ny * gain end
			local nl = sqrt(nx * nx + ny * ny + nz * nz)
			if nl < 1e-9 then nx, ny, nz, nl = 0, 0, 1, 1 end
			-- (the outermost ring is the level skin itself: lit as level skin is, whatever the ring
			-- inside it does. With the slope to that ring in it, a form's outer end shaded bare skin
			-- by up to 6 of 255: run wf6.)
			if j == 1 then nx, ny, nz, nl = 0, 0, 1, 1 end
			NX[o + k], NY[o + k], NZ[o + k] = nx / nl, ny / nl, nz / nl
			local tl = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
			if tl < 1e-9 then t1x, t1y, t1z, tl = 1, 0, 0, 1 end
			TX[o + k], TY[o + k], TZ[o + k] = t1x / tl, t1y / tl, t1z / tl
		end
	end
	-- (one sense for the whole sheet: the first ring says which, and every ring keeps the sense of
	-- the ring outside it)
	for j = 2, NR do
		local o = (j - 1) * NS
		for k = 1, NS do
			local i, p = o + k, o - NS + k
			if NX[i] * NX[p] + NY[i] * NY[p] + NZ[i] * NZ[p] < 0 then NX[i], NY[i], NZ[i] = -NX[i], -NY[i], -NZ[i] end
		end
	end
	NX[mid], NY[mid], NZ[mid], TX[mid], TY[mid], TZ[mid] = 0, 0, 1, 1, 0, 0
	local function FV(i, u)
		fvec:SetUnpacked(X[i], Y[i], Z[i])
		fnrm:SetUnpacked(NX[i], NY[i], NZ[i])
		mesh.Position(fvec)
		mesh.Normal(fnrm)
		mesh.UserData(TX[i], TY[i], TZ[i], 1)
		mesh.TexCoord(0, u, VV[i])
		mesh.AdvanceVertex()
	end
	-- (wound so that the outside is seen from over the skin and the inside from within the hole,
	-- as the recess's wall is)
	local function Bands(j0, j1)
		for j = j0, j1 - 1 do
			local o = (j - 1) * NS
			for k = 1, NS do
				local k2 = k % NS + 1
				local a, b, d, e = o + k, o + k2, o + NS + k, o + NS + k2
				local u1, u2 = (k - 1) / NS * 3, k / NS * 3
				FV(a, u1) FV(d, u1) FV(b, u2)
				FV(b, u2) FV(d, u1) FV(e, u2)
			end
		end
	end
	local mo = Mesh()
	mesh.Begin(mo, MATERIAL_TRIANGLES, nOut * NS * 2)
	Bands(1, nOut + 1)
	mesh.End()
	local mi = Mesh()
	mesh.Begin(mi, MATERIAL_TRIANGLES, (NR - nOut - 1) * NS * 2 + NS)
	Bands(nOut + 1, NR)
	local o = (NR - 1) * NS
	for k = 1, NS do
		local k2 = k % NS + 1
		FV(o + k, (k - 1) / NS * 3) FV(mid, (k - 0.5) / NS * 3) FV(o + k2, k / NS * 3)
	end
	mesh.End()
	-- The opening: a lid over it that lies as the skin lies (the edge, a ring half way in, the
	-- middle, each at the skin's own height there), wound like the outside: seen from over the
	-- skin only. It is drawn without a test against depth; what hides the part of an opening
	-- that has gone round a limb out of sight is that the lid is turned from the eye there (a
	-- flat lid was not: run wf2, a wound on the side of an arm showed through the arm as an arch).
	-- (it lies on the lip: the ring after the edge's)
	local lo = eo + NS
	local cxm, cym = 0, 0
	for k = 1, NS do
		cxm, cym = cxm + X[lo + k], cym + Y[lo + k]
	end
	cxm, cym = cxm / NS, cym / NS
	local czm = (SurfaceZ(F, cxm, cym) or zsum / NS) + ZR[lo + 1]
	local hx, hy, hz = {}, {}, {}
	for k = 1, NS do
		local x, y = (X[lo + k] + cxm) * 0.5, (Y[lo + k] + cym) * 0.5
		hx[k], hy[k] = x, y
		hz[k] = (SurfaceZ(F, x, y) or (Z[lo + k] - ZR[lo + k])) + ZR[lo + k]
	end
	local function PV(x, y, z, nx, ny)
		fvec:SetUnpacked(x, y, z)
		local nl = sqrt(nx * nx + ny * ny + 1)
		fnrm:SetUnpacked(nx / nl, ny / nl, 1 / nl)
		mesh.Position(fvec)
		mesh.Normal(fnrm)
		mesh.UserData(1, 0, 0, 1)
		-- (the lid is drawn a second time, under the floor: there it is the deepest of the inside)
		mesh.TexCoord(0, 0.5, 0.99)
		mesh.AdvanceVertex()
	end
	local mc = Mesh()
	mesh.Begin(mc, MATERIAL_TRIANGLES, NS * 3)
	for k = 1, NS do
		local k2 = k % NS + 1
		local a, b = lo + k, lo + k2
		PV(X[a], Y[a], Z[a], 0, 0) PV(hx[k], hy[k], hz[k], 0, 0) PV(X[b], Y[b], Z[b], 0, 0)
		PV(X[b], Y[b], Z[b], 0, 0) PV(hx[k], hy[k], hz[k], 0, 0) PV(hx[k2], hy[k2], hz[k2], 0, 0)
		PV(hx[k], hy[k], hz[k], 0, 0) PV(cxm, cym, czm, 0, 0) PV(hx[k2], hy[k2], hz[k2], 0, 0)
	end
	mesh.End()
	-- the blood that stands in it: a fan about the middle, as wide as the opening (it is put at its
	-- depth, and made as wide as the wall is there, when it is drawn). A surface for the lit shader
	-- with a highlight: it climbs the wall a little all round, as a liquid does, so that one side
	-- of it or another gives the light back to wherever the eye is.
	local bs = Mesh()
	mesh.Begin(bs, MATERIAL_TRIANGLES, NS)
	local bxs, bys = {}, {}
	for k = 1, NS do
		local s = 1 + ir[k] + fi[k] * 0.6 + tr[k] * 0.4
		bxs[k], bys[k] = e0x[k] * s, e0y[k] * s
	end
	for k = 1, NS do
		local k2 = k % NS + 1
		local l1, l2 = sqrt(bxs[k] ^ 2 + bys[k] ^ 2) + 1e-6, sqrt(bxs[k2] ^ 2 + bys[k2] ^ 2) + 1e-6
		PV(bxs[k], bys[k], 0, -0.5 * bxs[k] / l1, -0.5 * bys[k] / l1) PV(bxs[k2], bys[k2], 0, -0.5 * bxs[k2] / l2, -0.5 * bys[k2] / l2) PV(0, 0, 0, 0, 0)
	end
	mesh.End()
	c.fout, c.fin, c.fcap, c.fblood = mo, mi, mc, bs
	-- (for a developer's probe, W.probe: six places each on the level skin at the form's outer
	-- end, on the ring next to it, and on the rim's crest)
	do
		local pr = {}
		for _, j in ipairs({ 1, 2, crest }) do
			local list = {}
			for g = 0, 5 do
				local i = (j - 1) * NS + floor(g * NS / 6) + 1
				list[#list + 1] = { X[i], Y[i], Z[i] }
			end
			pr[#pr + 1] = list
		end
		c.fprobe = pr
	end
	c.fprof, c.fH, c.fw, c.fNS, c.fmiss, c.ftears = prof, H, w, NS, missed, tmax
	c.fms = (SysTime() - t0) * 1000
	ABL.Prof.Count("wound forms", 1)
end

-- How wide the wall is (share of the opening) at a share s of the depth.
local function FormRho(prof, s)
	local ps, pr = 0, prof.lip[1]
	for i = 1, #prof.wall do
		local e = prof.wall[i]
		if s <= e[2] then return pr + (e[1] - pr) * (s - ps) / max(e[2] - ps, 1e-6) end
		ps, pr = e[2], e[1]
	end
	return pr
end

-- The pictures the form is drawn with, and its materials. The pictures are made outside the 3D
-- view (W.Prepare, before a frame is rendered) and again every few seconds: a render target does
-- not outlive everything a game's window goes through.
local FS = { ready = false, at = 0, want = false, n = 0, list = {}, on = 0, open = {} }
W.Form = FS
local function Ramp(rt, stops)
	local SRGB = ABL.FilmDraw.SRGB
	render.PushRenderTarget(rt)
	cam.Start2D()
	render.OverrideAlphaWriteEnable(true, true)
	render.OverrideColorWriteEnable(true, true)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	draw.NoTexture()
	local j = 1
	for y = 0, 63 do
		local v = (y + 0.5) / 64
		while j < #stops - 1 and v > stops[j + 1][1] do j = j + 1 end
		local a, b = stops[j], stops[j + 1]
		local t = Clamp((v - a[1]) / max(b[1] - a[1], 1e-6), 0, 1)
		surface.SetDrawColor(SRGB[floor(a[2] + (b[2] - a[2]) * t + 0.5)], SRGB[floor(a[3] + (b[3] - a[3]) * t + 0.5)], SRGB[floor(a[4] + (b[4] - a[4]) * t + 0.5)],
			floor((a[5] or 255) + ((b[5] or 255) - (a[5] or 255)) * t + 0.5))
		surface.DrawRect(0, y, 4, 1)
	end
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false, true)
	render.OverrideAlphaWriteEnable(false, true)
	cam.End2D()
	render.PopRenderTarget()
end
-- (v, then the colour as it is to be seen under full light, 0..255)
-- The rim's own shade: none (white: what is multiplied by it stays as it is) but where the skin
-- turns into the hole: at the opening's edge it stands in the shade of the hole (rimEdge of the
-- light, in linear light), at the lip, where the inside begins, deep in it (rimLip).
-- (and redder: the skin that turns in is raw. rimLipTint of its other colours are left at the lip.)
local function RampRim()
	local function D(x) return floor(255 * Clamp(x, 0.0005, 1) ^ (1 / 2.2) + 0.5) end
	local e, l, lt = D(WC.rimEdge), D(WC.rimLip), D(WC.rimLip * WC.rimLipTint)
	local et = D(WC.rimEdge * (1 + WC.rimLipTint) * 0.5)
	return { { 0, 255, 255, 255 }, { 0.25, 255, 255, 255 }, { V_EDGE, e, et, et }, { V_LIP, l, lt, lt }, { 1, l, lt, lt } }
end
-- Where a wet rim gives the light back: a level relief for the lit shader (its red, green and
-- blue), and in its fourth channel how much of the highlight a place has: none on the level skin
-- (level skin gives the light back too, and without this the whole of a form's ground had a pale
-- sheen with the form's own round outline: run wf4), all of it from where the rim has begun to rise.
local RAMP_GLINT = { { 0, 128, 128, 255, 0 }, { 0.05, 128, 128, 255, 0 }, { 0.17, 128, 128, 255, 255 }, { 1, 128, 128, 255, 255 } }
-- The inside, from the lip down: not colours of its own, but what is left of the colour of what
-- the wound is in (the skin or the cloth as the eye has it there, with the blood and the
-- bruise on it) as it goes down into the hole: redder and darker the deeper. The inside is
-- multiplied over the picture like the rim, so it is the darker the darker its surroundings
-- are, under whatever light they stand. (With colours of its own it was the brightest thing on
-- cloth dark with blood, a red shape lying on the body: run wf3.) The numbers are what the eye
-- sees of white under full light with so much left (v, then red, green, blue, 0..255).
local RAMP_IN = { { 0, 133, 52, 52 }, { V_LIP, 133, 52, 52 }, { V_WALL, 117, 34, 35 }, { 0.75, 81, 21, 23 }, { 0.94, 52, 13, 14 }, { 1, 43, 11, 11 } }
function W.Prepare()
	if not FS.want then return end
	local now = RealTime()
	if now < FS.at then return end
	FS.at = now + 8
	if not FS.rim then
		local flags = bit.bor(4, 8, 256, 512)
		local function RT(name, w, h) return GetRenderTargetEx(name, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888) end
		FS.rim, FS.inside, FS.flat, FS.gmask = RT("abl_wound_rim", 4, 64), RT("abl_wound_in", 4, 64), RT("abl_wound_flat", 4, 4), RT("abl_wound_gl", 4, 64)
	end
	Ramp(FS.rim, RampRim())
	Ramp(FS.inside, RAMP_IN)
	Ramp(FS.gmask, RAMP_GLINT)
	render.PushRenderTarget(FS.flat)
	render.Clear(128, 128, 255, 255, false, false)
	render.PopRenderTarget()
	if not FS.mats then
		local function Lit(name, tex, extra)
			local kv = { ["$basetexture"] = tex:GetName() }
			for k, v in pairs(extra or {}) do kv[k] = v end
			return CreateMaterial("abl_wform_" .. name, "VertexLitGeneric", kv)
		end
		local flat = FS.flat:GetName()
		FS.mats = {
			-- the rim's shade and its light (W.DrawRelief says how each is laid over the picture);
			-- not tested against depth: the stencil buffer says where it is drawn
			rim = Lit("rim", FS.rim, { ["$ignorez"] = 1 }),
			-- what the rim gives back of the light where it is wet: the highlight and nothing else
			glint = CreateMaterial("abl_wform_glint", "VertexLitGeneric", { ["$basetexture"] = "color/white", ["$bumpmap"] = FS.gmask:GetName(), ["$ignorez"] = 1, ["$additive"] = 1, ["$color2"] = "[0 0 0]",
				["$phong"] = 1, ["$phongexponent"] = 22, ["$phongboost"] = 1, ["$phongfresnelranges"] = "[0.25 0.6 1]" }),
			-- the inside (what it leaves of the picture: DrawForm), and the blood that stands in
			-- it (how much it leaves is set when it is drawn)
			inside = Lit("in", FS.inside),
			pool = CreateMaterial("abl_wform_pool", "VertexLitGeneric", { ["$basetexture"] = "color/white", ["$nocull"] = 1 }),
			-- (wet, that blood shows the light as a small bright point: the highlight and nothing else)
			blood = CreateMaterial("abl_wform_blood", "VertexLitGeneric", { ["$basetexture"] = "color/white", ["$bumpmap"] = flat, ["$nocull"] = 1, ["$additive"] = 1, ["$color2"] = "[0 0 0]",
				["$phong"] = 1, ["$phongexponent"] = 150, ["$phongboost"] = 1, ["$phongfresnelranges"] = "[0.3 0.6 1]" }),
			-- what writes a place into the stencil buffer and leaves the picture as it is: tested
			-- against depth (a patch of skin: where it is seen), and not (the opening's lid)
			mark = CreateMaterial("abl_wform_mark", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$nocull"] = 1 }),
			cap = CreateMaterial("abl_wform_cap", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$ignorez"] = 1 }),
		}
	end
	FS.ready = true
end
hook.Add("PreRender", "ABL_WoundForm", function() W.Prepare() end)
-- (the form's own makers, for the bench outside the game: tools/offline/formbench.lua)
W.Dev = { BuildCavity = BuildCavity, BakeForm = BakeForm, FormSize = FormSize, FormRho = FormRho, RampRim = RampRim, RAMP_IN = RAMP_IN, FORM = FORM }

-- The light of a place as the lit shader is given it: light from all round and one light from a side.
local keyTab = { { type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(0, 0, -1) } }
local keyAt = Vector()
local function LightsOn(ar, ag, ab, sr, sg, sb, kx, ky, kz, x, y, z)
	render.SuppressEngineLighting(true)
	render.ResetModelLighting(ar, ag, ab)
	keyAt:SetUnpacked(x, y, z)
	render.SetLightingOrigin(keyAt)
	keyTab[1].color:SetUnpacked(sr, sg, sb)
	-- (dir: the way the light travels)
	keyTab[1].dir:SetUnpacked(-kx, -ky, -kz)
	render.SetLocalModelLights(keyTab)
end
local function LightsOff()
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
end

-- Where the light of a place comes from, by what the engine itself says falls there on a face
-- turned each of six ways (render.ComputeLighting: the light a model standing there is lit with,
-- the sun and the lamps it sees among it). One light over light from all round gives a face
-- turned to +x more than one turned to -x by that light's strength times its direction's x: the
-- six differences are the light's direction and strength, and what is left over is the light
-- from all round. Returns the way to the light and how many times stronger it is than the light
-- from all round; nil where the engine says nothing of use.
local AX = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local fitAt, fitL = Vector(), {}
local function FitLight(x, y, z)
	if not render.ComputeLighting then return nil end
	fitAt:SetUnpacked(x, y, z)
	local sum = 0
	for i = 1, 6 do
		local col = render.ComputeLighting(fitAt, AX[i])
		if not col then return nil end
		local v = 0.299 * col.x + 0.587 * col.y + 0.114 * col.z
		if not (v >= 0 and v < 1e6) then return nil end
		fitL[i] = v
		sum = sum + v
	end
	local gx, gy, gz = fitL[1] - fitL[2], fitL[3] - fitL[4], fitL[5] - fitL[6]
	local I = sqrt(gx * gx + gy * gy + gz * gz)
	if not (I > 1e-4) then return nil end
	local kx, ky, kz = gx / I, gy / I, gz / I
	local all = (sum - I * (abs(kx) + abs(ky) + abs(kz))) / 6
	return kx, ky, kz, I / max(all, I * 0.04, 1e-4), fitL
end
W.FitLight = FitLight

------------------------------------------------------------------------------------------
-- Phase 19 (docs/blood_upgrade/PHASE19_PLAN.md, section 6): what it changes of a wound, each part
-- on while C.V19On says so. With abl_liquid_v19 0 every part is off and a wound is drawn as before.
-- Read once a frame, by the first of W.Draw, W.DrawOpenings and W.DrawRelief that runs in it.
--   v19Blot   the blot and soak round an opening fade where the film covers the wound (woundBlotFade)
--   v19Hole   the blood standing in a recess is as dark as C.V19.holeRed of its light (holeRed)
--   v19Fade   a mark's parts come and go over a band of distance, not in one frame (woundFade)
--   v19Light  the light on a mark and its one light follow the place's over a time (woundLightTau)
------------------------------------------------------------------------------------------
local v19Frame = -1
local v19Blot, v19Hole, v19Fade, v19Light = false, false, false, false
local v19HoleRed, v19Tau, v19Band = 0.22, 0.3, 0.14
local function V19Read()
	local fn = FrameNumber()
	if fn == v19Frame then return end
	v19Frame = fn
	local on, V = C.V19On, C.V19
	if not on or not V then
		v19Blot, v19Hole, v19Fade, v19Light = false, false, false, false
		return
	end
	v19Blot, v19Hole, v19Fade, v19Light = on("woundBlotFade"), on("holeRed"), on("woundFade"), on("woundLightTau")
	v19HoleRed = V.holeRed or 0.22
	v19Tau = max(V.woundLightTau or 0.3, 0.01)
	-- (the band's width as a share of the distance it ends at: 12 to 15 % of it)
	v19Band = Clamp(V.woundBand or 0.14, 0.02, 0.5)
end

local function Smooth(e0, e1, x)
	local t = Clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- How much of a part drawn nearer than D is there at distance d: all of it up to the band's width
-- short of D, none at D itself (where it is cut), and smoothly in between. So the cut is made where
-- nothing of it is left to see, and an eye or a body that sways about a threshold changes nothing.
local function Band(d, D)
	local w = D * v19Band
	if w <= 0 then return d < D and 1 or 0 end
	return 1 - Smooth(D - w, D, d)
end

-- The light on a mark (R.Light, display values), eased: R.Light is the light of a 24-unit cell
-- cached for 1.5 to 2 s, and stepped as the body went from one cell to the next or the cache was
-- read again. The first sample is taken as it is; one after a long gap too.
local function EaseLight(mk, lr, lg, lb, rt)
	local t0 = mk.elT
	mk.elT = rt
	if not t0 or not mk.elr then
		mk.elr, mk.elg, mk.elb = lr, lg, lb
		return lr, lg, lb
	end
	local dt = rt - t0
	if dt > 0 then
		local e = 1 - exp(-dt / v19Tau)
		mk.elr, mk.elg, mk.elb = mk.elr + (lr - mk.elr) * e, mk.elg + (lg - mk.elg) * e, mk.elb + (lb - mk.elb) * e
	end
	return mk.elr, mk.elg, mk.elb
end

-- The one light of a mark (mk.klx .. mk.klr), eased toward its latest sample (mk.ktx .. mk.ktr):
-- the direction turned toward it and kept of unit length, the ratio moved toward it. A sample that
-- is nearly the opposite way has no way between the two to go along: it is taken at once.
local function EaseKey(mk, rt)
	local tx, ty, tz, tr = mk.ktx, mk.kty, mk.ktz, mk.ktr
	if not tx then return end
	local t0 = mk.kEaseT
	mk.kEaseT = rt
	local kx, ky, kz, kr = mk.klx, mk.kly, mk.klz, mk.klr
	if not t0 or not kx or not kr then
		mk.klx, mk.kly, mk.klz, mk.klr = tx, ty, tz, tr
		return
	end
	local dt = rt - t0
	if not (dt > 0) then return end
	local e = 1 - exp(-dt / v19Tau)
	if kx * tx + ky * ty + kz * tz < -0.9 then
		kx, ky, kz = tx, ty, tz
	else
		local nx, ny, nz = ABL.Norm(kx + (tx - kx) * e, ky + (ty - ky) * e, kz + (tz - kz) * e)
		if nx ~= 0 or ny ~= 0 or nz ~= 0 then kx, ky, kz = nx, ny, nz else kx, ky, kz = tx, ty, tz end
	end
	mk.klx, mk.kly, mk.klz, mk.klr = kx, ky, kz, kr + (tr - kr) * e
end

-- Where the one light of a mark's place comes from (toward it), and how much stronger it is than
-- the light from all round. By the engine's own account of the place (FitLight); failing that,
-- the sun where it reaches the wound, else the light from above (the open sky in a shadow, the
-- lamps of a room). Looked up a few times a second.
local sunOut = {}
local sunTr = { mask = MASK_OPAQUE, output = sunOut }
local sunA, sunB = Vector(), Vector()
local function MarkLight(mk, body, ax, ay, az, nx, ny, nz, rt)
	-- (phase 19, woundLightTau: what is looked up a few times a second is where the light goes, and
	-- the light drawn goes there in every frame; it jumped there at each look)
	local ease = v19Light
	-- (while it is off, what was eased toward grows old: dropped, so that when it is on again the
	-- light waits for a new look and is taken from it, rather than going to where it once was)
	if not ease and mk.ktx then mk.ktx, mk.kEaseT = nil, nil end
	if mk.klT and rt < mk.klT then
		if ease then EaseKey(mk, rt) end
		return
	end
	mk.klT = rt + 0.3 + (mk.tone or 0.5) * 0.15
	local kx, ky, kz, ratio
	if WC.keyFit then
		kx, ky, kz, ratio = FitLight(ax + nx * 2, ay + ny * 2, az + nz * 2)
		if kx then ratio = Clamp(ratio, WC.rimShade * 0.5, WC.rimSun * 1.5) end
		mk.klFit = kx ~= nil
	end
	if not kx then
		local sx, sy, sz = ABL.Render.SunDir()
		if sx and nx * sx + ny * sy + nz * sz > 0.04 and L.TakeTrace() then
			sunA:SetUnpacked(ax + nx * 3, ay + ny * 3, az + nz * 3)
			sunB:SetUnpacked(ax + sx * 6000, ay + sy * 6000, az + sz * 6000)
			sunTr.start, sunTr.endpos, sunTr.filter = sunA, sunB, body
			util.TraceLine(sunTr)
			if sunOut.HitSky or not sunOut.Hit then kx, ky, kz, ratio = sx, sy, sz, WC.rimSun end
		end
		if not kx then
			local gx, gy, gz, gm = ABL.Gravity()
			kx, ky, kz, ratio = -gx / gm, -gy / gm, -gz / gm, WC.rimShade
		end
	end
	-- (a light behind the skin shows nothing of a form, and no place is lit from one side alone:
	-- such a light is taken to graze the skin, and to be no stronger than the light of a shadow)
	local c0 = nx * kx + ny * ky + nz * kz
	if ease then
		-- (the same, without a step: as c0 goes from 0.32 down to 0.1, a light that grazes the skin
		-- is taken ever more to be the light of a shadow, and is bent toward the normal ever more as
		-- it was. At c0 0.22 the ratio fell to rimShade's at once, and the form's light and shade
		-- jumped as the body turned through it.)
		local t = Smooth(0.1, 0.32, c0)
		if c0 < 0.22 then
			local bend = (0.22 - c0) * 1.1 * (1 - t)
			kx, ky, kz = ABL.Norm(kx + nx * bend, ky + ny * bend, kz + nz * bend)
		end
		local low = min(ratio, WC.rimShade)
		ratio = low + (ratio - low) * t
		mk.ktx, mk.kty, mk.ktz, mk.ktr = kx, ky, kz, ratio
		EaseKey(mk, rt)
		return
	end
	if c0 < 0.22 then
		kx, ky, kz = ABL.Norm(kx + nx * (0.22 - c0) * 1.1, ky + ny * (0.22 - c0) * 1.1, kz + nz * (0.22 - c0) * 1.1)
		ratio = min(ratio, WC.rimShade)
	end
	mk.klx, mk.kly, mk.klz, mk.klr = kx, ky, kz, ratio
end

-- Where the wound's space lies on its bone: a matrix from the wound's space to the bone's.
-- o: the wound's place, t, b, n: its axes, all in the bone's space.
local function SetFrame(mk, ox, oy, oz, tx, ty, tz, bx, by, bz, nx, ny, nz)
	local fm = mk.frame
	if not fm then fm = Matrix() mk.frame = fm end
	fm:SetUnpacked(tx, bx, nx, ox, ty, by, ny, oy, tz, bz, nz, oz, 0, 0, 0, 1)
end

local function AddMark(src, r, kind, tri, u, v, dx, dy, dz, rng, len)
	local m, pose = src.mesh, src.pose
	local bdx, bdy, bdz = BM.WorldDirToBind(pose, m.tb[tri], dx, dy, dz)
	local nx, ny, nz, tx, ty, tz, bx, by, bz = Frame(m, tri, bdx, bdy, bdz)
	local bone = m.tb[tri]
	local mk = {
		kind = kind, rec = r, m = m, tri = tri, u = u, v = v,
		anchor = { tri, u, v, m },
		nx = nx, ny = ny, nz = nz, tx = tx, ty = ty, tz = tz, bx = bx, by = by, bz = bz,
		-- (a wound this client was told of after the fact is as old as the server said: cl_wounds.lua)
		born = (r.replayed and r.t0) or CurTime(), tone = rng:Range(C.ToneRange[1], 1),
		bone = bone, len = len,
		absorb = (m.tabs and m.tabs[tri]) or 1,
		-- (the projectile's direction as the body stood, in the mesh's own space: the recess leans along it)
		bdx = bdx, bdy = bdy, bdz = bdz,
		-- (what has come out of this opening, ml: cl_emission.lua adds to it. A wound this client is
		-- told of after the fact has bled before; one made for looking at is shown as one that has.)
		fed = (r.replayed or r.forLooks) and WC.soakFull or 0,
	}
	-- bare skin or cloth: by the material where the model names its skin (a cap on a head is not
	-- skin), else by the body part
	if (m.nskin or 0) > 0 then
		mk.skin = m.tskin[tri] == true
	else
		mk.skin = ABL.Flow.SkinBone(src, bone) or false
	end
	-- which way is down along the skin, as the body stands now: the blood that wells out of the
	-- wound in the first moments runs that way (a layer's own "down" is its +v)
	local gx, gy, gz = ABL.Gravity()
	local ggx, ggy, ggz = BM.WorldDirToBind(pose, bone, gx, gy, gz)
	local gt, gb = 0, 0
	if ggx then gt, gb = ggx * tx + ggy * ty + ggz * tz, ggx * bx + ggy * by + ggz * bz end
	mk.down = (gt * gt + gb * gb > 0.04) and math.atan2(gt, gb) or rng:Range(-3.14, 3.14)
	mk.layers, mk.S = BuildLayers(mk, r, rng)
	-- (the recess behind the opening, if this mark has one: its own generator, so that the
	-- layers are what they were before there was a recess)
	if mk.hole then
		-- (the layers that paint the opening: they are the recess's, a form has its own)
		local gloss = mk.holeName .. "_g"
		for _, l in ipairs(mk.layers) do
			if l == mk.hole or l.tex == gloss then l.ofHole = true end
		end
		BuildCavity(mk, r)
	end
	-- (the reflection of the blood painted round the opening: it is as large as that blood is)
	for _, l in ipairs(mk.layers) do
		if l.kind == K_GLOSS and string.sub(l.tex, 1, 5) == "blood" then l.ofBlot = true end
	end
	if mk.cav then
		-- (its form reaches further over the skin than its layers may: the patch has to hold it)
		local _, reach = FormSize(mk)
		if reach * 1.08 > mk.S then mk.S = reach * 1.08 end
		FS.want = true
	end
	-- (nothing to show: a blunt blow on cloth. No mark.)
	if #mk.layers == 0 then return nil end
	mk.hitPos = Vector(pose:Point(tri, u, v))
	if C.cl.woundDebug:GetBool() then
		ABL.Print("wound mark: %s on bone %s (%s), %s, the blow %.0f degrees off the skin's normal, at (%.1f %.1f %.1f)%s", kind, tostring(src.body:GetBoneName(bone)), tostring(r.region),
			mk.skin and "bare skin" or "cloth", math.deg(math.acos(Clamp(r.cosI or 1, -1, 1))), mk.hitPos.x, mk.hitPos.y, mk.hitPos.z,
			mk.cav and string.format("; opening %.2f units, recess %.2f deep", mk.cav.R0, mk.cav.D) or "; no opening")
	end
	src.marks = src.marks or {}
	local marks = src.marks
	-- a new wound right on top of an older one replaces it
	local px, py, pz = BM.BindPoint(m, tri, u, v)
	for i = #marks, 1, -1 do
		local o = marks[i]
		if o.m == m and o.kind == kind then
			local ox2, oy2, oz2 = BM.BindPoint(m, o.tri, o.u, o.v)
			if (ox2 - px) ^ 2 + (oy2 - py) ^ 2 + (oz2 - pz) ^ 2 < 0.3 * 0.3 then o.gone = true W.FreeMark(o) table.remove(marks, i) end
		end
	end
	local most = Clamp(C.cl.woundMax:GetInt(), 2, 40)
	while #marks >= most do marks[1].gone = true W.FreeMark(marks[1]) table.remove(marks, 1) end
	marks[#marks + 1] = mk
	return mk
end

-- Place the wound of record r on the body mesh: bullet line through world point (x,y,z) near
-- `bone`, direction (dx,dy,dz). Fills in the record's surface geometry. Returns the entry (or
-- graze) mark and the exit mark; either may be nil.
function W.PlaceWound(src, r, bone, x, y, z, dx, dy, dz, rng)
	local m, pose = src.mesh, src.pose
	if not m then return nil end
	-- entry: the outermost surface the line meets (a wound belongs on the jacket, not the shirt)
	local tri, u, v = BM.AnchorOuter(pose, bone, x, y, z, -dx, -dy, -dz, 6)
	if not tri then tri, u, v = BM.Anchor(pose, bone, x, y, z, 6) end
	if not tri then return nil end
	local ex, ey, ez, nx, ny, nz = pose:Point(tri, u, v)
	local cosI = max(-(dx * nx + dy * ny + dz * nz), 0.12)
	r.cosI = cosI
	-- an edged weapon: one gash where the blow fell
	if r.cut then
		-- (into the body rather than along it: the weapon goes much deeper than it is wide, by
		-- its own numbers, and the blow did not come flat)
		local deepK, wideK = (r.energy or 0) * 1.5, (r.diameter or 0) / 4
		local stab = deepK > 0 and wideK > 0 and deepK / wideK >= WR.stabRatio and cosI >= WR.stabCos
		return AddMark(src, r, stab and "stab" or "cut", tri, u, v, dx, dy, dz, rng), nil
	end
	if r.blunt then return AddMark(src, r, "blunt", tri, u, v, dx, dy, dz, rng), nil end
	-- exit: the surface the same line leaves through, seen from beyond the far side. A retained
	-- projectile has none
	local xtri, xu, xv
	if r.pen ~= WD.PEN_RETAINED then
		xtri, xu, xv = BM.AnchorOuter(pose, bone, ex, ey, ez, dx, dy, dz, WC.exitReach)
		if xtri == tri then xtri = nil end
	end
	local len
	if xtri then
		local qx, qy, qz = pose:Point(xtri, xu, xv)
		len = sqrt((qx - ex) ^ 2 + (qy - ey) ^ 2 + (qz - ez) ^ 2)
		r.trackLen = len
		-- a graze: flesh only, and the path never gets deep under the skin
		if r.pen == WD.PEN_SOFT and len < 12 and 0.5 * len * cosI < WR.grazeDepth and cosI < WR.grazeCos then
			r.graze = true
			local mt, mu, mv = BM.Anchor(pose, bone, (ex + qx) * 0.5, (ey + qy) * 0.5, (ez + qz) * 0.5, 5)
			if not mt then mt, mu, mv = tri, u, v end
			return AddMark(src, r, "graze", mt, mu, mv, dx, dy, dz, rng, len), nil
		end
	end
	local mk = AddMark(src, r, "entry", tri, u, v, dx, dy, dz, rng)
	local mx = xtri and AddMark(src, r, "exit", xtri, xu, xv, dx, dy, dz, rng) or nil
	return mk, mx
end

-- The cloth round a wound that has no mark of its own soaking up blood (cl_flowcore.lua FC.Feed).
-- rec: the wound's stand-in for a record; rec.soak (0..1) says how full the cloth is, rec.fedT
-- when blood last came. half: half-size of the patch when it is full (units).
function W.PlaceSoak(src, wd, rec, half)
	local m = src.mesh
	if not m or not wd.tri or wd.tri > m.nt or not (half > 0 and half < 100) then return nil end
	local gx, gy, gz, gmag = ABL.Gravity()
	local mk = AddMark(src, rec, "soak", wd.tri, wd.u, wd.v, gx / gmag, gy / gmag, gz / gmag,
		ABL.RNG(ABL.Hash(tostring(wd.id)) + 977), Clamp(half * 1.25, 0.9, 2.8))
	return mk
end

-- A projectile hit (E.OnHit). entry: world position, ev.dir: bullet direction.
function W.OnHit(src, body, ev, r, entry, exitPos, rng)
	-- (a projectile, or an edged weapon: a blunt one opens nothing)
	r.cut = r.class == ABL.Net.DMG_SLASH
	r.blunt = r.class == ABL.Net.DMG_CLUB
	if not IsValid(body) or not (r.bullet or r.cut or r.blunt) or r.pen == WD.PEN_ARMOR then return nil end
	-- (the mesh is still being built, or the source has not taken up this body yet: a fake ragdoll
	-- that appeared in the tick of the hit)
	if not src.mesh or src.body ~= body then
		W.Pending(src, body, ev.bone, ev.lpos, ev.dir, r)
		return nil
	end
	local dir = ev.dir
	-- (its own generator, the same one a mark placed later gets: the event's generator then runs
	-- the same sequence on every client, whether its surface model was ready or not)
	return W.PlaceWound(src, r, ev.bone, entry.x, entry.y, entry.z, dir.x, dir.y, dir.z, ABL.RNG(r.id * 7919 + 31))
end

-- Marks placed after the hit was processed (the body mesh was still being built): hand them to
-- the record and to the wounds already bleeding through it.
local function Attach(r, mk, mx)
	r.entryMark, r.exitMark = mk, mx
	for _, wd in ipairs(r.wds) do
		local use = (wd.role == "exit") and (mx or mk) or mk
		if use then
			wd.mark = use
			wd.tri, wd.anchorTried = nil, false
		end
	end
	local sl = r.src and r.src.pendingHits
	if sl then
		for _, h in ipairs(sl) do
			if h.rec == r then h.mark = (h.role == "exit") and (mx or mk) or mk end
		end
	end
end

-- The body mesh is still being built: remember the hit in bone space (position and bullet
-- direction: the body may fall and turn before the mark can be placed) and place it once ready.
function W.Pending(src, body, bone, lpos, dir, r)
	local M = body:GetBoneMatrix(bone)
	if not M then return end
	local ldir = WorldToLocal(dir, angle_zero, vector_origin, M:GetAngles())
	src.pendingMarks = src.pendingMarks or {}
	local p = src.pendingMarks
	if #p >= 8 then table.remove(p, 1) end
	p[#p + 1] = { bone = bone, lpos = Vector(lpos), ldir = ldir, rec = r, t = CurTime() }
end

-- The body's surface model is another one (cl_sources.lua): the marks on the old one go, and each
-- wound is marked again on the new one from its record, which knows where the projectile struck
-- and which way it went in the space of the bone it struck (W.Think places it once the new surface
-- model is there). A bone of that name the new model must have; else the wound has no mark there.
-- Soaked patches come back by themselves as their wounds bleed on (cl_flowcore.lua FC.Feed).
function W.Remesh(src)
	local marks = src.marks
	if marks then
		local body = src.body
		local now = CurTime()
		local seen = {}
		for i = 1, #marks do
			local mk = marks[i]
			mk.gone = true
			W.FreeMark(mk)
			local r = mk.rec
			if r and not r.soakOnly and not r.gone and not seen[r] then
				seen[r] = true
				r.entryMark, r.exitMark = nil, nil
				local bone = IsValid(body) and r.boneName and body:LookupBone(r.boneName) or nil
				if bone and r.lentry and r.ldir then
					src.pendingMarks = src.pendingMarks or {}
					local p = src.pendingMarks
					if #p < WC.maxPerSource then p[#p + 1] = { bone = bone, lpos = Vector(r.lentry), ldir = r.ldir, rec = r, t = now } end
				end
			end
		end
		src.marks = nil
	end
	for _, wd in pairs(src.wounds) do
		if wd.mark and wd.mark.gone then wd.mark = nil end
		if wd.soakMark and wd.soakMark.gone then wd.soakMark = nil end
	end
	for _, h in ipairs(src.pendingHits or {}) do
		if h.mark and h.mark.gone then h.mark = nil end
	end
end

function W.Think(src)
	local p = src.pendingMarks
	if not p or #p == 0 or not src.mesh or not IsValid(src.body) then return end
	local now = CurTime()
	for i = #p, 1, -1 do
		local q = p[i]
		if now - q.t > 20 or q.rec.gone then
			ABL.Trace.Event(src, nil, string.format("the mark of hit %s given up", tostring(q.rec.id)), q.rec.gone and "its wound record is gone" or "its bone could not be read for 20 s")
			table.remove(p, i)
		else
			local b = src.pose:Bone(q.bone)
			if b then
				local lx, ly, lz = q.lpos.x, q.lpos.y, q.lpos.z
				local x = b[1] * lx + b[2] * ly + b[3] * lz + b[4]
				local y = b[5] * lx + b[6] * ly + b[7] * lz + b[8]
				local z = b[9] * lx + b[10] * ly + b[11] * lz + b[12]
				local l = q.ldir
				local dx, dy, dz = ABL.Norm(b[1] * l.x + b[2] * l.y + b[3] * l.z, b[5] * l.x + b[6] * l.y + b[7] * l.z, b[9] * l.x + b[10] * l.y + b[11] * l.z)
				local r = q.rec
				-- (no direction: the bone has been scaled away, a destroyed head carries no mark)
				if dx ~= 0 or dy ~= 0 or dz ~= 0 then
					local mk, mx = W.PlaceWound(src, r, q.bone, x, y, z, dx, dy, dz, ABL.RNG(r.id * 7919 + 31))
					Attach(r, mk, mx)
					ABL.Trace.Event(src, nil, string.format("the mark of hit %s placed late", tostring(r.id)), mk and "the body's surface model is there now" or "NO MARK: no place on the skin was found for it")
				else
					ABL.Trace.Event(src, nil, string.format("the mark of hit %s given up", tostring(r.id)), "its bone is scaled away")
				end
				table.remove(p, i)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Patch: the mesh triangles around the mark, with texture coordinates (bind space, built once).
-- The patch's own coordinates span the square of half-size mk.S around the wound along its
-- tangent (u) and bitangent (v); layers are placed inside it by their texture transforms.
------------------------------------------------------------------------------------------
-- Does triangle (u, v in half-units: the patch is the square -1..1) overlap that square?
local function TriHitsSquare(u1, v1, u2, v2, u3, v3)
	if min(u1, u2, u3) > 1 or max(u1, u2, u3) < -1 or min(v1, v2, v3) > 1 or max(v1, v2, v3) < -1 then return false end
	-- separating axes: the triangle's edge normals
	for e = 1, 3 do
		local ax, ay, bx, by
		if e == 1 then ax, ay, bx, by = u1, v1, u2, v2 elseif e == 2 then ax, ay, bx, by = u2, v2, u3, v3 else ax, ay, bx, by = u3, v3, u1, v1 end
		local nx, ny = by - ay, ax - bx
		local p1, p2, p3 = u1 * nx + v1 * ny, u2 * nx + v2 * ny, u3 * nx + v3 * ny
		local r = abs(nx) + abs(ny)
		if min(p1, p2, p3) > r or max(p1, p2, p3) < -r then return false end
	end
	return true
end

local function BuildPatch(mk, m)
	local cx, cy, cz = BM.BindPoint(m, mk.tri, mk.u, mk.v)
	local S = mk.S
	local nx, ny, nz, tx, ty, tz, bx, by, bz = mk.nx, mk.ny, mk.nz, mk.tx, mk.ty, mk.tz, mk.bx, mk.by, mk.bz
	local su = 1 / S
	local ids, us, vs, as = {}, {}, {}, {}
	local vnx, vny, vnz = m.nx, m.ny, m.nz
	local vx, vy, vz, t1, t2, t3 = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3
	local n = 0
	local lu, lv = {}, {}
	-- Every triangle that reaches into the square belongs to the patch, however large it is (coarse
	-- meshes have triangles bigger than a wound): the layers are transparent towards their borders
	-- and clamped beyond them, so the patch's own outline never shows.
	for _, t in ipairs(BM.TrisNear(m, cx, cy, cz, S * 1.5 + 6)) do
		-- only surface facing the same way (not the far side of the neck, not inside the mouth), and
		-- close to the wound's surface (not a collar standing off the neck); the surface may curve
		-- away from the wound's plane with distance
		local fx, fy, fz = BM.BindNormal(m, t)
		if t == mk.tri or fx * nx + fy * ny + fz * nz > 0.15 then
			local ok = true
			for k = 1, 3 do
				local id = (k == 1 and t1[t]) or (k == 2 and t2[t]) or t3[t]
				local dx, dy, dz = vx[id] - cx, vy[id] - cy, vz[id] - cz
				local h = dx * nx + dy * ny + dz * nz
				local pu, pv = dx * tx + dy * ty + dz * tz, dx * bx + dy * by + dz * bz
				local lat = sqrt(pu * pu + pv * pv)
				lu[k], lv[k] = pu * su, pv * su
				if t ~= mk.tri and (h > S * 0.37 + lat * 0.15 or h < -(S * 0.52 + lat * 0.8)) then ok = false break end
			end
			if ok and TriHitsSquare(lu[1], lv[1], lu[2], lv[2], lu[3], lv[3]) then
				for k = 1, 3 do
					n = n + 1
					ids[n] = (k == 1 and t1[t]) or (k == 2 and t2[t]) or t3[t]
					us[n] = 0.5 + 0.5 * lu[k]
					vs[n] = 0.5 + 0.5 * lv[k]
					-- Layers are laid on flat (projected along the wound's normal): where the surface turns
					-- away from it they would smear over the turned-away triangles, so they fade out there
					local id = ids[n]
					as[n] = Clamp(((vnx[id] * nx + vny[id] * ny + vnz[id] * nz) - 0.2) / 0.45, 0, 1)
				end
			end
		end
	end
	mk.patch = { n = n, ids = ids, u = us, v = vs, a = as }
	-- does the patch follow one bone rigidly? (corners out in the transparent border may bend with
	-- another bone: nothing of the wound is drawn there)
	local rigid = m.inv[mk.bone] ~= nil
	local b1, w1 = m.b1, m.w1
	local inner = 0.36 * max(1, 2.4 / S)
	for c = 1, n do
		local id = ids[c]
		if (b1[id] ~= mk.bone or w1[id] < 0.97) and abs(us[c] - 0.5) < inner and abs(vs[c] - 0.5) < inner then rigid = false break end
	end
	mk.rigid = rigid
end

------------------------------------------------------------------------------------------
-- The patch as a static mesh in the space of the mark's bone
------------------------------------------------------------------------------------------
local vec = Vector()
local function V(x, y, z, u, v, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.TexCoord(0, u, v)
	-- (opacity through colour and alpha both: right for the blended and for the multiplied layers)
	local c = 255 * a ^ (1 / 2.2)
	mesh.Color(c, c, c, 255 * a)
	mesh.AdvanceVertex()
end

local function FreePatch(mk)
	if mk.mesh then mk.mesh:Destroy() mk.mesh = nil end
end
-- (a mark that goes: its patch and its recess. A patch that is only baked again keeps the recess.)
local function FreeMark(mk)
	FreePatch(mk)
	FreeCavity(mk)
end
W.FreeMark = FreeMark

-- Three of a patch's corners that stand well apart round the wound: the ones furthest out along
-- three ways a third of a turn apart, of those inside the patch's own square if there are any
-- (a patch on a coarse mesh may have none: then the nearest outside it).
local function Spread(P)
	local us, vs = P.u, P.v
	local b1, b2, b3 = -1e9, -1e9, -1e9
	local p1, p2, p3 = 1, 1, 1
	for c = 1, P.n do
		local du, dv = us[c] - 0.5, vs[c] - 0.5
		local out = max(abs(du), abs(dv)) - 0.5
		local pen = out > 0 and out * 3 or 0
		local s1, s2, s3 = du - pen, -0.5 * du + 0.866 * dv - pen, -0.5 * du - 0.866 * dv - pen
		if s1 > b1 then b1, p1 = s1, c end
		if s2 > b2 then b2, p2 = s2, c end
		if s3 > b3 then b3, p3 = s3, c end
	end
	return p1, p2, p3
end

-- The frame three points make (the way from the first to the second, the way square to that in
-- their plane, and the plane's own normal); nil where they lie in one line.
local function Frame3(x1, y1, z1, x2, y2, z2, x3, y3, z3)
	local ax, ay, az = x2 - x1, y2 - y1, z2 - z1
	local al = sqrt(ax * ax + ay * ay + az * az)
	if al < 1e-3 then return nil end
	ax, ay, az = ax / al, ay / al, az / al
	local bx, by, bz = x3 - x1, y3 - y1, z3 - z1
	local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local nl = sqrt(nx * nx + ny * ny + nz * nz)
	if nl < 1e-3 then return nil end
	nx, ny, nz = nx / nl, ny / nl, nz / nl
	return ax, ay, az, ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax, nx, ny, nz
end

local OFFSET = 0.06
-- Rigid skin: from the bind pose, once. Bending skin: from the current pose, and again whenever
-- the skin has moved under it (W.Draw checks a few of its corners).
local function Bake(mk, m, pose)
	FreePatch(mk)
	local P = mk.patch
	local ids, us, vs, as = P.ids, P.u, P.v, P.a
	local ms
	if mk.rigid then
		local inv = m.inv[mk.bone]
		local ox, oy, oz = mk.nx * OFFSET, mk.ny * OFFSET, mk.nz * OFFSET
		local vx, vy, vz = m.vx, m.vy, m.vz
		ms = Mesh()
		mesh.Begin(ms, MATERIAL_TRIANGLES, P.n / 3)
		for c = 1, P.n do
			local id = ids[c]
			local x, y, z = vx[id] + ox, vy[id] + oy, vz[id] + oz
			V(inv[1] * x + inv[2] * y + inv[3] * z + inv[4], inv[5] * x + inv[6] * y + inv[7] * z + inv[8], inv[9] * x + inv[10] * y + inv[11] * z + inv[12], us[c], vs[c], as[c])
		end
		mesh.End()
		if mk.cav then
			-- the wound's space on its bone, from the bind pose
			local cx, cy, cz = BM.BindPoint(m, mk.tri, mk.u, mk.v)
			local function Rot(x, y, z) return inv[1] * x + inv[2] * y + inv[3] * z, inv[5] * x + inv[6] * y + inv[7] * z, inv[9] * x + inv[10] * y + inv[11] * z end
			local tx, ty, tz = Rot(mk.tx, mk.ty, mk.tz)
			local bx, by, bz = Rot(mk.bx, mk.by, mk.bz)
			local nx, ny, nz = Rot(mk.nx, mk.ny, mk.nz)
			SetFrame(mk, inv[1] * cx + inv[2] * cy + inv[3] * cz + inv[4], inv[5] * cx + inv[6] * cy + inv[7] * cz + inv[8], inv[9] * cx + inv[10] * cy + inv[11] * cz + inv[12],
				tx, ty, tz, bx, by, bz, nx, ny, nz)
		end
	else
		local inv = pose:BoneInv(mk.bone)
		if not inv then return false end
		local _, _, _, anx, any, anz = pose:SkinPoint(mk.anchor)
		local ox, oy, oz = anx * OFFSET, any * OFFSET, anz * OFFSET
		ms = Mesh()
		mesh.Begin(ms, MATERIAL_TRIANGLES, P.n / 3)
		for c = 1, P.n do
			local x, y, z = pose:Vertex(ids[c])
			x, y, z = x + ox, y + oy, z + oz
			V(inv[1] * x + inv[2] * y + inv[3] * z + inv[4], inv[5] * x + inv[6] * y + inv[7] * z + inv[8], inv[9] * x + inv[10] * y + inv[11] * z + inv[12], us[c], vs[c], as[c])
		end
		mesh.End()
		-- Three of its corners that stand well apart round the wound, and the wound's own place,
		-- as they lie now in the bone's space: the patch goes with them from frame to frame
		-- (Follow) and is baked again only when the skin between them has changed its shape.
		--   s[1..12]   the three: vertex, x, y, z      s[13..15]  the wound's place
		--   s[16..24]  the frame the three make       s[25..27]  their middle
		local s = mk.sample
		if not s then s = {} mk.sample = s end
		local c1, c2, c3 = Spread(P)
		for k = 1, 3 do
			local c = (k == 1 and c1) or (k == 2 and c2) or c3
			local x, y, z = pose:Vertex(ids[c])
			local o = (k - 1) * 4
			s[o + 1] = ids[c]
			s[o + 2] = inv[1] * x + inv[2] * y + inv[3] * z + inv[4]
			s[o + 3] = inv[5] * x + inv[6] * y + inv[7] * z + inv[8]
			s[o + 4] = inv[9] * x + inv[10] * y + inv[11] * z + inv[12]
		end
		do
			local wx, wy, wz = pose:SkinPoint(mk.anchor)
			s[13] = inv[1] * wx + inv[2] * wy + inv[3] * wz + inv[4]
			s[14] = inv[5] * wx + inv[6] * wy + inv[7] * wz + inv[8]
			s[15] = inv[9] * wx + inv[10] * wy + inv[11] * wz + inv[12]
			local a1, a2, a3, b1, b2, b3, n1, n2, n3 = Frame3(s[2], s[3], s[4], s[6], s[7], s[8], s[10], s[11], s[12])
			s.ok = a1 ~= nil
			if a1 then s[16], s[17], s[18], s[19], s[20], s[21], s[22], s[23], s[24] = a1, a2, a3, b1, b2, b3, n1, n2, n3 end
			s[25], s[26], s[27] = (s[2] + s[6] + s[10]) / 3, (s[3] + s[7] + s[11]) / 3, (s[4] + s[8] + s[12]) / 3
		end
		mk.fixOn = false
		if mk.cav then
			-- The wound's space on its bone as the skin lies now: at the wound's place on the
			-- skin, its normal the skin's, its tangent the mark's own carried by the bone and
			-- put square to that normal.
			local wx, wy, wz, wnx, wny, wnz = pose:SkinPoint(mk.anchor)
			local bw = pose:Bone(mk.bone)
			local bi = m.inv[mk.bone]
			local tx, ty, tz = mk.tx, mk.ty, mk.tz
			if bw and bi then
				-- bind -> the bone's own space -> the world, by the rotations alone
				local lx, ly, lz = bi[1] * tx + bi[2] * ty + bi[3] * tz, bi[5] * tx + bi[6] * ty + bi[7] * tz, bi[9] * tx + bi[10] * ty + bi[11] * tz
				tx, ty, tz = bw[1] * lx + bw[2] * ly + bw[3] * lz, bw[5] * lx + bw[6] * ly + bw[7] * lz, bw[9] * lx + bw[10] * ly + bw[11] * lz
			end
			local dn = tx * wnx + ty * wny + tz * wnz
			tx, ty, tz = ABL.Norm(tx - wnx * dn, ty - wny * dn, tz - wnz * dn)
			if tx == 0 and ty == 0 and tz == 0 then tx, ty, tz = ABL.Perp(wnx, wny, wnz) end
			local bx, by, bz = wny * tz - wnz * ty, wnz * tx - wnx * tz, wnx * ty - wny * tx
			local function Rot(x, y, z) return inv[1] * x + inv[2] * y + inv[3] * z, inv[5] * x + inv[6] * y + inv[7] * z, inv[9] * x + inv[10] * y + inv[11] * z end
			local t1, t2, t3 = Rot(tx, ty, tz)
			local b1, b2, b3 = Rot(bx, by, bz)
			local n1, n2, n3 = Rot(wnx, wny, wnz)
			SetFrame(mk, inv[1] * wx + inv[2] * wy + inv[3] * wz + inv[4], inv[5] * wx + inv[6] * wy + inv[7] * wz + inv[8], inv[9] * wx + inv[10] * wy + inv[11] * wz + inv[12],
				t1, t2, t3, b1, b2, b3, n1, n2, n3)
		end
	end
	mk.mesh = ms
	mk.bakeT = RealTime()
	return true
end

-- Bending skin under a baked patch (a chest that breathes, a trunk that turns): where three of
-- the patch's corners and the wound's own place are now, against where they were when it was
-- baked. What the three have done together as one stiff piece (moved, turned) the patch and the
-- wound's form do with them: that is put into mk.fr (the turn, by rows) and mk.ft (the move), in
-- the bone's space, for the draw. Returns how far the worst of the four is from where that puts
-- it: the skin between them has changed its shape by so much, and when that is too much the
-- patch is baked again.
-- (Until run wf3 a patch was only ever baked again, at the most every 0.07 s, once a corner had
-- moved 0.05 units. A patch lies 0.06 units over the skin it was baked on: a wound on a chest
-- that breathes was under the skin in some frames, and all of it was gone from the picture.)
local followC = {}
local function Follow(mk, pose)
	local inv = pose:BoneInv(mk.bone)
	local s = mk.sample
	if not inv or not s then return 0 end
	local c = followC
	for k = 0, 2 do
		local x, y, z = pose:Vertex(s[k * 4 + 1])
		c[k * 3 + 1] = inv[1] * x + inv[2] * y + inv[3] * z + inv[4]
		c[k * 3 + 2] = inv[5] * x + inv[6] * y + inv[7] * z + inv[8]
		c[k * 3 + 3] = inv[9] * x + inv[10] * y + inv[11] * z + inv[12]
	end
	local a1, a2, a3, b1, b2, b3, n1, n2, n3
	if s.ok then a1, a2, a3, b1, b2, b3, n1, n2, n3 = Frame3(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9]) end
	if not a1 then
		-- (its three corners make no frame: no going along; by how far they have moved)
		mk.fixOn = false
		local worst = 0
		for k = 0, 2 do
			local d = abs(c[k * 3 + 1] - s[k * 4 + 2]) + abs(c[k * 3 + 2] - s[k * 4 + 3]) + abs(c[k * 3 + 3] - s[k * 4 + 4])
			if d > worst then worst = d end
		end
		return worst
	end
	-- the turn: the frame now times the frame then, turned over
	local r = mk.fr
	if not r then r = {} mk.fr = r mk.ft = {} end
	r[1], r[2], r[3] = a1 * s[16] + b1 * s[19] + n1 * s[22], a1 * s[17] + b1 * s[20] + n1 * s[23], a1 * s[18] + b1 * s[21] + n1 * s[24]
	r[4], r[5], r[6] = a2 * s[16] + b2 * s[19] + n2 * s[22], a2 * s[17] + b2 * s[20] + n2 * s[23], a2 * s[18] + b2 * s[21] + n2 * s[24]
	r[7], r[8], r[9] = a3 * s[16] + b3 * s[19] + n3 * s[22], a3 * s[17] + b3 * s[20] + n3 * s[23], a3 * s[18] + b3 * s[21] + n3 * s[24]
	-- the move: their middle now, less their middle then, turned
	local mx, my, mz = s[25], s[26], s[27]
	local t = mk.ft
	t[1] = (c[1] + c[4] + c[7]) / 3 - (r[1] * mx + r[2] * my + r[3] * mz)
	t[2] = (c[2] + c[5] + c[8]) / 3 - (r[4] * mx + r[5] * my + r[6] * mz)
	t[3] = (c[3] + c[6] + c[9]) / 3 - (r[7] * mx + r[8] * my + r[9] * mz)
	mk.fixOn = true
	-- how far each of the four is from where that puts it
	local worst = 0
	for k = 0, 2 do
		local x, y, z = s[k * 4 + 2], s[k * 4 + 3], s[k * 4 + 4]
		local dx = r[1] * x + r[2] * y + r[3] * z + t[1] - c[k * 3 + 1]
		local dy = r[4] * x + r[5] * y + r[6] * z + t[2] - c[k * 3 + 2]
		local dz = r[7] * x + r[8] * y + r[9] * z + t[3] - c[k * 3 + 3]
		local d = dx * dx + dy * dy + dz * dz
		if d > worst then worst = d end
	end
	local wx, wy, wz = pose:SkinPoint(mk.anchor)
	local lx = inv[1] * wx + inv[2] * wy + inv[3] * wz + inv[4]
	local ly = inv[5] * wx + inv[6] * wy + inv[7] * wz + inv[8]
	local lz = inv[9] * wx + inv[10] * wy + inv[11] * wz + inv[12]
	local x, y, z = s[13], s[14], s[15]
	local dx, dy, dz = r[1] * x + r[2] * y + r[3] * z + t[1] - lx, r[4] * x + r[5] * y + r[6] * z + t[2] - ly, r[7] * x + r[8] * y + r[9] * z + t[3] - lz
	local d = dx * dx + dy * dy + dz * dz
	if d > worst then worst = d end
	return sqrt(worst)
end

------------------------------------------------------------------------------------------
-- Drawing (from ABL.Flow.DrawSource, before the body blood so it runs over the wound)
------------------------------------------------------------------------------------------
local colVec = Vector()
local boneMat = Matrix()
local texMat = Matrix()
local GAMMA = 1 / 2.2

-- Place a layer inside the patch: texture transform for half-size h, stretch st along the tangent,
-- rotation rot, offset (ox, oy) in units.
local function PlaceLayer(mat, S, l)
	local c, s = cos(l.rot), sin(l.rot)
	local su, sv = S / (l.half * l.st), S / l.half
	local oxp, oyp = l.ox / (2 * l.half * l.st), l.oy / (2 * l.half)
	texMat:SetField(1, 1, c * su)
	texMat:SetField(1, 2, -s * sv)
	texMat:SetField(1, 4, 0.5 - 0.5 * c * su + 0.5 * s * sv - c * oxp + s * oyp)
	texMat:SetField(2, 1, s * su)
	texMat:SetField(2, 2, c * sv)
	texMat:SetField(2, 4, 0.5 - 0.5 * s * su - 0.5 * c * sv - s * oxp - c * oyp)
	mat:SetMatrix("$basetexturetransform", texMat)
end

------------------------------------------------------------------------------------------
-- The recess, drawn (see the head of this file). Called with the bone's matrix pushed.
------------------------------------------------------------------------------------------
local maskMats = {}
local function MaskMat(name)
	local mt = maskMats[name]
	if mt then return mt end
	-- (alpha-tested: a pixel is written, into the stencil buffer, where the opening is; its
	-- colour is kept out of the picture by the blend it is drawn with)
	mt = CreateMaterial("abl_wm_" .. name, "UnlitGeneric", { ["$basetexture"] = "advancedblood/wounds/" .. name .. "_m", ["$alphatest"] = 1, ["$alphatestreference"] = 0.5, ["$nocull"] = 1 })
	maskMats[name] = mt
	return mt
end
local wallMat, bloodMat, sheenMat
local function CavMats()
	if wallMat then return end
	wallMat = CreateMaterial("abl_wcav_wall", "UnlitGeneric", { ["$basetexture"] = "advancedblood/wounds/tissue", ["$vertexcolor"] = 1 })
	bloodMat = CreateMaterial("abl_wcav_blood", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1 })
	sheenMat = CreateMaterial("abl_wcav_sheen", "UnlitGeneric", { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$additive"] = 1 })
end
W.CavMats = CavMats

-- One number for each wound of a body in a frame (two openings that overlap do not show each
-- other's inside): the seven lower bits of the stencil buffer; its top bit says that a place
-- is an opening (see "The form, drawn"). The buffer is cleared before the first wound of each
-- body (what an earlier body left there is nothing to a later one, which may stand in front
-- of it), and again should one body have more wounds than there are numbers.
local stFrame, stRef, stSrc = -1, 0, nil
local function NextRef()
	local fn = FrameNumber()
	if fn ~= stFrame or stSrc ~= FS.src or stRef >= 126 then
		stFrame, stSrc, stRef = fn, FS.src, 0
		render.ClearStencil()
	end
	stRef = stRef + 1
	return stRef
end

local levelMat = Matrix()
local levelVec, levelScale = Vector(), Vector()
W.cavFlip = false            -- (for a scene: the wall's triangles culled the other way round)
W.cavDrawn = 0
W.reliefDrawn = 0            -- (for a scene: rims drawn since it was last set to nought)
W.layersDrawn = 0            -- (for a scene: layers painted on skin since it was last set to nought)
local function DrawCavity(mk, ms, S, lr, lg, lb, wet, clot, dry, gk, film)
	local c = mk.cav
	CavMats()
	if not c.mesh then BakeCavity(mk) end
	if not c.mesh or not mk.frame then return end
	-- (an opening: the top bit, and this wound's number under it)
	local ref = 128 + NextRef()
	-- 1. the opening, into the stencil buffer: where this piece of skin is seen
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(ref)
	render.SetStencilCompareFunction(STENCIL_ALWAYS)
	render.SetStencilPassOperation(STENCIL_REPLACE)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	local mm = MaskMat(mk.holeName)
	PlaceLayer(mm, S, mk.hole)
	render.SetMaterial(mm)
	render.OverrideBlend(true, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	ms:Draw()
	render.OverrideBlend(false)
	-- 2. in it: the wound's dark ground, and nothing in front any more
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.ClearBuffersObeyStencil(min(255, 34 * lr), min(255, 7 * lg), min(255, 7 * lb), 255, true)
	-- 3. the recess through it
	cam.PushModelMatrix(mk.frame, true)
	render.CullMode(W.cavFlip and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
	-- (a fresh wound's wall is wet with blood: redder; dried, duller and darker)
	local wk = film * (1 - dry)
	colVec:SetUnpacked(min(1.5, lr * (1.05 - 0.18 * dry)), min(1.5, lg * (0.98 - 0.16 * wk - 0.14 * dry)), min(1.5, lb * (0.98 - 0.16 * wk - 0.14 * dry)))
	wallMat:SetVector("$color", colVec)
	render.SetMaterial(wallMat)
	c.mesh:Draw()
	-- the blood standing in it: high and wet while the wound bleeds, sunk, dark and dull once
	-- it has set (a graze holds a film at the bottom of its trench)
	local fresh = film * (1 - 0.6 * dry)
	local s = (c.graze and 0.62 or (mk.kind == "cut" and 0.34 or 0.20)) + 0.26 * dry + 0.10 * clot * (1 - dry)
	if fresh > 0.05 or clot > 0.1 then
		local rho = RhoAt(c.prof, s) * 0.99
		levelMat:Identity()
		levelVec:SetUnpacked(c.ox + c.kx * c.D * s, c.oy + c.ky * c.D * s, -c.D * s)
		levelMat:SetTranslation(levelVec)
		levelScale:SetUnpacked(rho, rho, 1)
		levelMat:SetScale(levelScale)
		cam.PushModelMatrix(levelMat, true)
		-- (fresh blood in a hole is seen by what little light comes back out of it: a deep
		-- red that is nearly black, browner and lighter as it dries)
		local k = 1 - 0.35 * clot
		-- (phase 19, holeRed: 0.34 made it as bright as the film round the opening, a plug in the
		-- hole; below about 0.14 it is darker than the hole's own ground, and the blood in it is gone)
		local hr = 0.34
		if v19Hole then hr = v19HoleRed end
		colVec:SetUnpacked(min(1, lr * (hr * k + 0.06 * dry)), min(1, lg * (0.022 + 0.035 * dry)), min(1, lb * (0.026 + 0.02 * dry)))
		bloodMat:SetVector("$color", colVec)
		render.SetMaterial(bloodMat)
		c.blood:Draw()
		-- what the wet surface gives back of the light: a sheen, never a white spot
		local g = gk * 1.6
		-- (phase 19, woundFade: added on, it goes over the recess's band of distance)
		if v19Fade then g = g * (mk.fForm or 1) end
		if g > 0.01 then
			colVec:SetUnpacked(g * lr, g * lg, g * lb)
			sheenMat:SetVector("$color", colVec)
			render.SetMaterial(sheenMat)
			c.blood:Draw()
		end
		cam.PopModelMatrix()
	end
	render.CullMode(MATERIAL_CULLMODE_CCW)
	cam.PopModelMatrix()
	render.SetStencilEnable(false)
	W.cavDrawn = W.cavDrawn + 1
end

-- Something that is to be drawn on a body's skin after its wounds' openings are cut keeps out of
-- them with this: every opening of the body has the top bit of the stencil buffer set and the
-- rest of the picture has not, and W.KeepOut(true) lets only that rest be drawn on.
-- (The blood on the body was drawn so, after the openings: it could not lie over a hole like a
-- lid, but the hole was dry, with blood round it. Now the openings are cut after the blood is
-- drawn, out of the blood too (W.DrawOpenings), and nothing of the addon's uses this.)
function W.KeepOut(on)
	if not on then render.SetStencilEnable(false) return end
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(0)
	render.SetStencilTestMask(128)
	render.SetStencilReferenceValue(0)
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
end

------------------------------------------------------------------------------------------
-- The form, drawn (see "The form" above). Called with the bone's matrix pushed, in place of
-- DrawCavity, for a mark whose form is built.
-- The stencil buffer, for a body's wounds (cleared before the first of each body in a frame):
--   the top bit        a wound's opening: nothing that is drawn on the skin goes there (W.KeepOut)
--   the seven below    whose: every wound of the body has a number of its own
-- A wound's patch of skin (the body's own triangles, tested against depth) writes the wound's
-- number where it is seen and no opening is yet; the form's lid over its opening, drawn without
-- a test against depth, turns the top bit on where that number stands. So an opening is where
-- the wound's own skin is seen and nowhere else, whatever the lid's own depth.
------------------------------------------------------------------------------------------
local backMat = Matrix()
local formFog
local function DrawForm(mk, ms, lr, lg, lb, clot, dry, film, body, ax, ay, az, rt)
	local c = mk.cav
	local fm = FS.mats
	-- which way the wound faces as it is drawn: the third axis of its frame, turned with its bone
	local f, bmx = mk.frame, mk.bm
	local f1, f2, f3 = f:GetField(1, 3), f:GetField(2, 3), f:GetField(3, 3)
	local nx = bmx:GetField(1, 1) * f1 + bmx:GetField(1, 2) * f2 + bmx:GetField(1, 3) * f3
	local ny = bmx:GetField(2, 1) * f1 + bmx:GetField(2, 2) * f2 + bmx:GetField(2, 3) * f3
	local nz = bmx:GetField(3, 1) * f1 + bmx:GetField(3, 2) * f2 + bmx:GetField(3, 3) * f3
	nx, ny, nz = ABL.Norm(nx, ny, nz)
	mk.wnx, mk.wny, mk.wnz = nx, ny, nz
	mk.wax, mk.way, mk.waz = ax, ay, az
	MarkLight(mk, body, ax, ay, az, nx, ny, nz, rt)
	local kx, ky, kz, ratio = mk.klx, mk.kly, mk.klz, mk.klr
	local id = NextRef()
	-- 1. this wound's piece of skin, where it is seen and is no opening yet: the wound's number
	render.SetStencilEnable(true)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilPassOperation(STENCIL_REPLACE)
	render.SetStencilTestMask(128)
	render.SetStencilWriteMask(127)
	render.SetStencilReferenceValue(id)
	render.OverrideBlend(true, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	render.OverrideDepthEnable(true, false)
	render.SetMaterial(fm.mark)
	ms:Draw()
	render.OverrideDepthEnable(false, false)
	-- 2. of that, what lies under the form's own lid: the opening
	render.SetStencilTestMask(127)
	render.SetStencilWriteMask(128)
	render.SetStencilReferenceValue(128 + id)
	cam.PushModelMatrix(f, true)
	-- (the lid and the inside are seen from one side only: see BakeForm)
	render.CullMode(W.cavFlip and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
	render.SetMaterial(fm.cap)
	c.fcap:Draw()
	render.OverrideBlend(false)
	-- 3. in it nothing is in front any more. The picture itself stays: what is seen in the
	-- opening is what was there (the skin or the cloth, and what is on it), gone down into the
	-- hole. (Should the picture not stay, it is the colour of a dim skin from here on.)
	render.SetStencilTestMask(255)
	render.SetStencilWriteMask(255)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.OverrideColorWriteEnable(true, false)
	render.ClearBuffersObeyStencil(min(255, 150 * lr), min(255, 110 * lg), min(255, 95 * lb), 255, true)
	-- 4. The inside, twice. First its depth alone: which of its faces is the nearest in each
	-- place (the far wall, the floor, the blood, and behind all of them the lid again, sunk
	-- under the floor: no place of the opening is left without an inside). Then the same faces
	-- once more, each drawn only where it is that nearest one, multiplied over the picture: what
	-- they leave of it (the redder and the darker the deeper, by the inside's picture) times
	-- the light they get, as a share of the light on the skin round the wound: what comes in
	-- from all round, what the walls throw across, and what gets in of the one light.
	local ts = render.GetToneMappingScaleLinear()
	local tone = 1 / Clamp(ts and ts.x or 1, 0.05, 20)
	local c0 = max(0, nx * kx + ny * ky + nz * kz)
	local E0 = 1 + ratio * c0
	local a, s = tone * (WC.inAmbient / E0 + WC.inFill), tone * WC.inKey * ratio / E0
	LightsOn(a, a, a, s, s, s, kx, ky, kz, ax, ay, az)
	formFog = render.GetFogMode()
	render.FogMode(MATERIAL_FOG_NONE)
	local im = fm.inside
	-- (a fresh wound's inside is wet with blood: redder; dried, duller and darker; under cloth
	-- it lies a little deeper in the shade)
	local wk = film * (1 - dry)
	local ck = mk.skin and 1 or 0.9
	-- How hard the wound bleeds right now (0 .. 1: W.Draw), and whether the body's film of blood
	-- lies over its opening. Where it does, the picture in the opening is that blood and no longer
	-- skin or cloth: it is dark and red already, and the inside takes far less of it away (taken
	-- as from skin, a wound in its own blood was a black hole).
	local fill, cover = mk.fill or 0, mk.cover or 0
	local ir, ig = ck * (1.0 - 0.15 * dry), ck * (0.98 - 0.16 * wk - 0.14 * dry)
	if cover > 0 then ir, ig = ir * (1 + WC.inFilmR * cover), ig * (1 + WC.inFilmG * cover) end
	colVec:SetUnpacked(ir, ig, ig)
	im:SetVector("$color2", colVec)
	-- the blood standing in it: to the brim while the wound bleeds, sunk, dark and dull once it
	-- has set (a graze holds a film at the bottom of its trench)
	local fresh = film * (1 - 0.6 * dry)
	local pool = fresh > 0.05 or clot > 0.1 or fill > 0.02
	if pool then
		local sd = (c.graze and 0.62 or ((c.fprof == FORM.cut or c.fprof == FORM.exit) and 0.34 or 0.24)) + 0.26 * dry + 0.10 * clot * (1 - dry)
		-- (while it bleeds the blood wells up to the lip, and runs over it: cl_film.lua)
		sd = sd + (WC.brimLevel - sd) * fill
		-- (as wide as the wall is there)
		local rho = FormRho(c.fprof, sd) * 0.98
		levelMat:Identity()
		levelVec:SetUnpacked(c.ox + c.kx * c.D * sd, c.oy + c.ky * c.D * sd, c.fz0 - c.D * sd)
		levelMat:SetTranslation(levelVec)
		levelScale:SetUnpacked(rho, rho, 1)
		levelMat:SetScale(levelScale)
		-- (Blood that stands in a hole is deep, and seen by what little light comes back out of
		-- it: it leaves less of the picture than the wall beside it does; browner and lighter as
		-- it dries. The numbers are of the picture, not of light: the lit shader takes $color2 so.)
		local k = 1 - 0.3 * clot
		local pr, pg, pb = 0.31 * k + 0.05 * dry, 0.05 + 0.035 * dry, 0.06 + 0.02 * dry
		if cover > 0 then
			-- (over the body's own blood: that blood, a little deeper; nearly all of it while the
			-- wound runs, so that the blood in the wound and the blood below it are one)
			local F0, F1 = WC.poolFilm, WC.poolFlow
			local fr, fg = F0[1] + (F1[1] - F0[1]) * fill, F0[2] + (F1[2] - F0[2]) * fill
			pr, pg, pb = pr + (fr * k - pr) * cover, pg + (fg - pg) * cover, pb + (fg - pb) * cover
		end
		colVec:SetUnpacked(pr, pg, pb)
		fm.pool:SetVector("$color2", colVec)
	end
	-- (what is behind everything: the lid, a little under the floor and as much aside as the floor is)
	backMat:Identity()
	levelVec:SetUnpacked(c.kx * c.D * 1.05, c.ky * c.D * 1.05, -c.D * 1.12)
	backMat:SetTranslation(levelVec)
	for pass = 1, 2 do
		if pass == 2 then
			render.OverrideColorWriteEnable(false, false)
			render.OverrideDepthEnable(true, false)
			render.OverrideBlend(true, BLEND_ZERO, BLEND_SRC_COLOR, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		end
		render.SetMaterial(im)
		c.fin:Draw()
		cam.PushModelMatrix(backMat, true)
		c.fcap:Draw()
		cam.PopModelMatrix()
		if pool then
			cam.PushModelMatrix(levelMat, true)
			render.SetMaterial(fm.pool)
			c.fblood:Draw()
			cam.PopModelMatrix()
		end
	end
	-- 5. And a little of its own over that: what is under skin or cloth is red and wet whatever
	-- is over it, and something of that comes back out of the hole. Added on, by the light as it
	-- is there (this is light, exposed like the picture): next to nothing where the picture is
	-- bright, but in cloth that is black, or black with blood, the inside was one black shape
	-- without it (run wf4).
	local Er, Eg, Eb = lr ^ 2.2, lg ^ 2.2, lb ^ 2.2
	-- (phase 19, woundFade: what is added on here goes over the bands of distance of the form and of
	-- the highlight, W.Draw; what is multiplied is drawn whole up to cavDist)
	local fF, fG = 1, 1
	if v19Fade then fF, fG = mk.fForm or 1, mk.fGlint or 1 end
	local own = WC.inOwn
	if own > 0 then
		local a2, s2 = WC.inAmbient / E0 + WC.inFill, WC.inKey * ratio / E0
		LightsOn(Er * a2, Eg * a2, Eb * a2, Er * s2, Eg * s2, Eb * s2, kx, ky, kz, ax, ay, az)
		render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		local o = own * (1 - 0.3 * dry) * fF
		colVec:SetUnpacked(o, o * 0.8, o * 0.8)
		im:SetVector("$color2", colVec)
		render.SetMaterial(im)
		c.fin:Draw()
		if pool then
			colVec:SetUnpacked(o * 0.36, o * 0.12, o * 0.13)
			fm.pool:SetVector("$color2", colVec)
			cam.PushModelMatrix(levelMat, true)
			render.SetMaterial(fm.pool)
			c.fblood:Draw()
			cam.PopModelMatrix()
		end
	end
	-- 6. wet, the blood in it shows the one light as a small bright point: added on, where the
	-- blood is the nearest
	-- (whether it is drawn is asked of it as it is, unfaded: the band itself is no threshold)
	local gl0 = pool and WC.bloodGlint * fresh * (1 - 0.8 * clot) or 0
	local gl = gl0 * fG * fF
	if gl0 > 0.03 and gl > 0 and mk.glintOK ~= false then
		local Sk = WC.inKey * ratio / E0
		LightsOn(0, 0, 0, Er * Sk, Eg * Sk, Eb * Sk, kx, ky, kz, ax, ay, az)
		render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		fm.blood:SetFloat("$phongboost", gl)
		cam.PushModelMatrix(levelMat, true)
		render.SetMaterial(fm.blood)
		c.fblood:Draw()
		cam.PopModelMatrix()
	end
	render.OverrideBlend(false)
	render.OverrideDepthEnable(false, false)
	render.CullMode(MATERIAL_CULLMODE_CCW)
	render.FogMode(formFog or MATERIAL_FOG_NONE)
	cam.PopModelMatrix()
	LightsOff()
	render.SetStencilEnable(false)
	W.cavDrawn = W.cavDrawn + 1
end

-- The rims of the wounds W.Draw has just drawn on this body: their light and shade over what is
-- on the skin by now (the blood that has run over it too), each where its own patch of skin is
-- seen and no opening is. See "The form" for how, and why it changes nothing where a rim is level.
-- A developer's probe (W.probe = {}; the test harness sets it): what the rim's light and shade
-- change in the picture, read off the picture itself in one and the same frame, just before
-- they are drawn and just after. Nothing else is drawn in between, so the difference is theirs.
local PROBE_NAMES = { "level skin at the form's outer end", "the ring next to it", "the rim's crest" }
local probeVec = Vector()
local function ProbeRead(mk, c)
	local M = mk.bm * mk.frame
	local out = {}
	render.CapturePixels()
	for a = 1, #c.fprobe do
		local row = {}
		for b, p in ipairs(c.fprobe[a]) do
			probeVec:SetUnpacked(p[1], p[2], p[3])
			local sc = (M * probeVec):ToScreen()
			local x, y = floor(sc.x), floor(sc.y)
			if sc.visible and x >= 0 and y >= 0 and x < ScrW() and y < ScrH() then
				local r, g, bl = render.ReadPixel(x, y)
				row[b] = { x, y, r, g, bl }
			end
		end
		out[a] = row
	end
	return out
end
local function ProbeReport(mk, c, before)
	render.CapturePixels()
	local log = ABL.TestLog or ABL.Print
	log("rim probe: %s %s on %s, lit %.2f times the light from all round; places as r g b before > after the rim's light and shade", mk.kind, tostring(mk.holeName), mk.skin and "skin" or "cloth", mk.klr or 0)
	for a = 1, #before do
		local parts, worst = {}, 0
		for b = 1, 6 do
			local e = before[a][b]
			if e then
				local r, g, bl = render.ReadPixel(e[1], e[2])
				worst = max(worst, abs(r - e[3]), abs(g - e[4]), abs(bl - e[5]))
				parts[#parts + 1] = string.format("%d %d %d > %d %d %d", e[3], e[4], e[5], r, g, bl)
			else
				parts[#parts + 1] = "(not in the picture)"
			end
		end
		log("rim probe:   %s: largest change %d of 255 | %s", PROBE_NAMES[a], worst, table.concat(parts, " | "))
	end
end

local reliefFog
function W.DrawRelief(src)
	local n = FS.n
	if n == 0 or FS.src ~= src then return end
	FS.n = 0
	local fm = FS.mats
	if not fm then return end
	V19Read()
	-- (the lit shader multiplies what it draws by the engine's exposure; the rim's shade is a
	-- share of the light, not light: taken out again)
	local ts = render.GetToneMappingScaleLinear()
	local tone = 1 / Clamp(ts and ts.x or 1, 0.05, 20)
	local glintK = WC.rimGlint
	reliefFog = render.GetFogMode()
	render.FogMode(MATERIAL_FOG_NONE)
	render.SetStencilEnable(true)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	-- (the faces turned to the eye only: the far side of a rim seen from low down is behind its crest)
	render.CullMode(W.cavFlip and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
	local list = FS.list
	-- (a developer's probe: of the wounds it may be, the one nearest the eye)
	local probeMk
	if W.probe then
		local best
		for i = 1, n do
			local mk = list[i]
			if mk.cav and mk.cav.fprobe and mk.wax and (not W.probe.kind or W.probe.kind == mk.kind) then
				local d = (mk.wax - L.eyeX) ^ 2 + (mk.way - L.eyeY) ^ 2 + (mk.waz - L.eyeZ) ^ 2
				if not best or d < best then best, probeMk = d, mk end
			end
		end
	end
	for i = 1, n do
		local mk = list[i]
		list[i] = nil
		local c = mk.cav
		if c and c.fout and mk.frame and mk.bm and mk.mesh and not mk.gone then
			local id = NextRef()
			-- where this wound's piece of skin is seen and is no opening: its number
			render.SetStencilTestMask(128)
			render.SetStencilWriteMask(127)
			render.SetStencilReferenceValue(id)
			render.SetStencilPassOperation(STENCIL_REPLACE)
			render.OverrideBlend(true, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
			render.OverrideDepthEnable(true, false)
			render.SetMaterial(fm.mark)
			cam.PushModelMatrix(mk.bm)
			mk.mesh:Draw()
			render.OverrideDepthEnable(false, false)
			-- there, and nowhere else:
			render.SetStencilTestMask(255)
			render.SetStencilWriteMask(0)
			render.SetStencilPassOperation(STENCIL_KEEP)
			cam.PushModelMatrix(mk.frame, true)
			local probed
			if probeMk == mk then
				probed = ProbeRead(mk, c)
				W.probe = nil
			end
			local nx, ny, nz = mk.wnx, mk.wny, mk.wnz
			local kx, ky, kz, ratio = mk.klx, mk.kly, mk.klz, mk.klr
			local c0 = max(0, nx * kx + ny * ky + nz * kz)
			local E0 = 1 + ratio * c0
			-- its shade: the light given so that level skin comes out white (a hair over it:
			-- white is where the picture is left as it is), a slope turned from the light darker
			local a, s = tone * 1.004 / E0, tone * 1.004 * ratio / E0
			LightsOn(a, a, a, s, s, s, kx, ky, kz, mk.wax, mk.way, mk.waz)
			render.OverrideBlend(true, BLEND_ZERO, BLEND_SRC_COLOR, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
			render.SetMaterial(fm.rim)
			c.fout:Draw()
			-- (phase 19, woundFade: what is added on goes over the rim's band of distance and the
			-- highlight's, W.Draw; the shade just drawn, multiplied, is drawn whole up to formDist)
			local fR, fG = 1, 1
			if v19Fade then fR, fG = mk.fRelief or 1, mk.fGlint or 1 end
			-- its light: by the part of the light that runs along the skin alone, which gives
			-- level skin nothing and a slope turned to it as much as that slope gains
			local t2 = 1 - c0 * c0
			if t2 > 0.003 then
				local t = sqrt(t2)
				local px, py, pz = ABL.Norm(kx - nx * c0, ky - ny * c0, kz - nz * c0)
				local g = tone * ratio * t / E0 * fR
				LightsOn(0, 0, 0, g, g, g, px, py, pz, mk.wax, mk.way, mk.waz)
				render.OverrideBlend(true, BLEND_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
				c.fout:Draw()
			end
			-- wet: what it gives back of the one light as a highlight (the light as it is there:
			-- this is light, and is exposed like the rest of the picture)
			-- (whether it is drawn is asked of it unfaded: the band itself is no threshold)
			local gl0 = glintK * (mk.wetK or 0) * (mk.skin and 1 or 0.45)
			local gl = gl0 * fG * fR
			if gl0 > 0.03 and gl > 0 and mk.glintOK then
				local lr, lg, lb = mk.flr or 1, mk.flg or 1, mk.flb or 1
				local Sk = ratio / E0
				LightsOn(0, 0, 0, lr ^ 2.2 * Sk, lg ^ 2.2 * Sk, lb ^ 2.2 * Sk, kx, ky, kz, mk.wax, mk.way, mk.waz)
				render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
				fm.glint:SetFloat("$phongboost", gl)
				render.SetMaterial(fm.glint)
				c.fout:Draw()
			end
			if probed then ProbeReport(mk, c, probed) end
			cam.PopModelMatrix()
			cam.PopModelMatrix()
			W.reliefDrawn = W.reliefDrawn + 1
		end
	end
	LightsOff()
	render.CullMode(MATERIAL_CULLMODE_CCW)
	render.OverrideBlend(false)
	render.SetStencilEnable(false)
	render.FogMode(reliefFog or MATERIAL_FOG_NONE)
end

-- formStarved: the last frame in which a wound within cavDist waited for the one bake of a frame
local patchFrame, formFrame, formStarved = -1, -1, -1
function W.Draw(src, pose, off)
	local marks = src.marks
	local frame = FrameNumber()
	local m = src.mesh
	if not marks or #marks == 0 or not m then return end
	local body = src.body
	local R = ABL.Render
	local now, rt = CurTime(), RealTime()
	local ex, ey, ez = L.eyeX, L.eyeY, L.eyeZ
	local drawn = 0
	local deep = C.cl.wound3d:GetBool()
	local form = C.cl.woundForm:GetBool()
	local cut = false
	FS.n, FS.on, FS.src = 0, 0, src
	if not C.cl.woundMarks:GetBool() then return false end
	local drawDist, cavDist = C.cl.woundDist:GetFloat(), C.cl.wound3dDist:GetFloat()
	local inten = Clamp(C.cl.woundIntensity:GetFloat(), 0.4, 1.6)
	local dbg = C.cl.woundDebug:GetBool()
	-- abl_wound_life: a mark older than that fades and goes (the blood a cloth has soaked up
	-- has its own drying, and comes again for as long as its wound bleeds)
	local life, old = C.cl.woundLife:GetFloat(), false
	V19Read()
	local fadeOn, blotFade, lightEase = v19Fade, v19Blot, v19Light
	R.EndFilter()
	for i = 1, #marks do
		local mk = marks[i]
		local fade = 1
		if life > 0 and mk.kind ~= "soak" then
			fade = Clamp((life - (now - mk.born)) / WC.lifeFade, 0, 1)
			if fade <= 0 then old = true end
		end
		if mk.m == m and fade > 0 then
			-- a limb that is not drawn (a destroyed head) takes its wounds with it
			if now > (mk.hidT or 0) then
				mk.hidT = now + 0.5
				mk.hidden = ABL.ZC.BoneHidden(body, mk.bone) or (body.headexploded and ABL.ZC.BoneLimb(body:GetBoneName(mk.bone) or "") == "head")
			end
			if not mk.hidden then
				-- (one new patch per frame: several wounds made at once appear over as many frames
				-- instead of costing one long frame)
				if not mk.patch and patchFrame ~= frame then
					patchFrame = frame
					BuildPatch(mk, m)
				end
				local P = mk.patch
				if P and P.n >= 3 then
					local ax, ay, az, anx, any, anz = pose:SkinPoint(mk.anchor)
					local vx, vy, vz = ex - ax, ey - ay, ez - az
					local d = sqrt(vx * vx + vy * vy + vz * vz)
					-- (a mark facing away from the camera is behind its own body part)
					if d < drawDist and vx * anx + vy * any + vz * anz > -0.3 * d then
						-- (skin that bends: the patch goes along with what the skin under it does as
						-- one piece, and is baked again when that no longer fits)
						if not mk.mesh or (not mk.rigid and Follow(mk, pose) > WC.patchDrift and rt - mk.bakeT > 0.07) then
							if Bake(mk, m, pose) then ABL.Prof.Count("mark bakes", 1) end
						end
						local ms = mk.mesh
						local ok = ms ~= nil
						if ok then
							if body.CopyBoneMatrix then
								body:CopyBoneMatrix(mk.bone, boneMat)
							else
								local bm = body:GetBoneMatrix(mk.bone)
								if bm then boneMat = bm else ok = false end
							end
						end
						if ok then
							local r = mk.rec
							local lr, lg, lb = R.Light(ax + anx * 2, ay + any * 2, az + anz * 2)
							-- (phase 19, woundLightTau: it follows the light of the place over a time,
							-- not in steps from one cell of R.Light's to the next)
							if lightEase then lr, lg, lb = EaseLight(mk, lr, lg, lb, rt) end
							-- (a soak-only mark dries once no blood has come for a while)
							if r.soakOnly then r.dry = Clamp((now - (r.fedT or now) - 30) / 120, 0, 1) end
							local wet, clot, dry, bruise = r.wet, r.clot, r.dry, r.bruise
							-- blood around the wound darkens as it sets and dries
							local dk = 1 - 0.22 * clot - 0.28 * dry
							local cosT = (vx * anx + vy * any + vz * anz) / max(d, 1)
							-- (the reflection of a small wet patch: never a white sticker)
							local gk = (wet ^ 1.5) * (1 - 0.8 * clot) * min(WC.gloss, 0.05 + 0.6 * C.Ground.sheen * R.Fresnel(cosT))
							-- the film is there within a second, and gives way to the crust as it dries
							local film = Clamp((now - mk.born) / 0.8, 0, 1) * (1 - 0.75 * dry)
							local crust = Clamp((clot - 0.25) / 0.6, 0, 1)
							-- What is painted round the opening is blood that came out of it: there is as
							-- much of it as has come out, from none. (It was there in full, or a third
							-- of the way there, in the moment of the hit: a patch round the hole
							-- before a drop had left it. Scene bleed_origin, run bo0.)
							local fed = mk.fed or 0
							local blot = fed >= WC.blotFull and 1 or fed / WC.blotFull
							local soak = r.soakOnly and r.soak or (fed >= WC.soakFull and 1 or fed / WC.soakFull)
							-- How hard it bleeds through this opening right now (ml/s over a moment), and
							-- from that how high the blood stands in it: to its brim while it runs, and
							-- sinking back when it stops. And whether the body's own film of blood lies
							-- over the opening (cl_film.lua): what is seen in the opening is then that
							-- blood, and the blood on the body goes on out of the wound without a seam.
							local dtf = rt - (mk.fillT or rt)
							mk.fillT = rt
							if dtf > 0.1 then dtf = 0.1 end
							local rT = mk.rateT
							if not rT then
								mk.rateT, mk.rateV, mk.rate = now, fed, 0
							elseif now - rT >= 0.1 then
								local got = (fed - mk.rateV) / (now - rT)
								mk.rate = mk.rate + (got - mk.rate) * (1 - exp(-(now - rT) / WC.brimTau))
								mk.rateT, mk.rateV = now, fed
							end
							local want = mk.rate >= WC.brimFlow and 1 or mk.rate / WC.brimFlow
							local fill = mk.fill or 0
							fill = fill + (want - fill) * (1 - exp(-dtf / (want > fill and WC.brimRise or WC.brimFall)))
							mk.fill = fill
							local over = 0
							local fs, fc = mk.fstate, mk.fcell
							if (not fc or fs ~= src.film) and src.film and now >= (mk.fcAsk or 0) then
								-- (a wound that is not fed here any more, a corpse's or one this
								-- client was told of later: asked for now and then)
								mk.fcAsk = now + 1
								local s2, c2 = ABL.Film.CellOf(src, mk.tri, mk.u, mk.v)
								if c2 then
									mk.fstate, mk.fcell = s2, c2
									fs, fc = s2, c2
								end
							end
							if fc and fs and src.film == fs and not fs.dead and fs.h[fc] + fs.k[fc] + fs.sd[fc] + fs.ab[fc] > KFM.showMin then over = 1 end
							local cover = mk.cover or 0
							cover = cover + (over - cover) * (1 - exp(-dtf / KFM.ease))
							mk.cover = cover
							-- (where the film shows the blood, what is painted keeps to the wound's own rim)
							local blotK, soakK = 1 - (1 - WC.blotFilm) * cover, 1 - (1 - WC.soakFilm) * cover
							-- Phase 19 (woundBlotFade): the blot and the soak round an opening are as large
							-- as their blood, and go where the film covers the wound: the blood there is the
							-- film's, and a disc of another red under it showed past its outline. Only
							-- where the film is drawn there: a cell with no canvas for its map (none to be
							-- had, or taken for a film nearer the eye) shows nothing, and then the blot is
							-- there in full at once, as the film is gone at once. (bc: the cover that
							-- counts, eased as cover is, and cover itself while the canvas stays.)
							local blotA, soakA = 1, 1
							if blotFade then
								local bc = 0
								local cvs = fc and fs and src.film == fs and fs.cv
								local cvk = cvs and fs.mk and cvs[fs.mk[fc]]
								if cvk and cvk.painted then
									bc = mk.bcover or 0
									bc = bc + (over - bc) * (1 - exp(-dtf / KFM.ease))
								end
								mk.bcover = bc
								blotK, soakK = 1, 1
								blotA = 1 - bc
								soakA = r.soakOnly and 1 or blotA
							end
							-- Phase 19 (woundFade): how much of each part that is cut at a distance is
							-- there at this one (Band). The cuts stay where they were, at the bands' far
							-- ends; what is laid on as a translucent layer or added on goes over the band.
							-- What the openings and rims are drawn with is kept on the mark, in every frame.
							local fMark, fDetail, fGloss = 1, 1, 1
							if fadeOn then
								fMark, fDetail, fGloss = Band(d, drawDist), Band(d, WC.detailDist), Band(d, 600)
								mk.fForm, mk.fRelief, mk.fGlint = Band(d, cavDist), Band(d, WC.formDist), Band(d, WC.glintDist)
								-- (what the highlights go by, in every frame: it was set only for a mark
								-- whose rim was queued, below, and the highlight in an opening between
								-- formDist and cavDist went by what it was set to last, nearer or further)
								mk.wetK = film * (1 - dry) * (1 - 0.8 * clot)
								mk.flr, mk.flg, mk.flb = lr, lg, lb
								mk.glintOK = d < WC.glintDist
							end
							local detailOK = d < WC.detailDist
							local layers, S = mk.layers, mk.S
							-- the wound's form, if it is to have one: built once (one in a frame: several
							-- wounds made at once get theirs over as many frames). Its opening is its
							-- own; the painted one is left out, and for the frame or two a form waits
							-- to be built the wound has no opening at all rather than the other kind's.
							local cav = mk.cav
							local shaped, waiting = false, false
							if form and deep and cav and mk.frame and d < cavDist and fade >= 1 then
								if not cav.fout and not cav.fbad then
									if FS.ready and formFrame ~= frame then
										formFrame = frame
										BakeForm(mk, m)
									elseif FS.ready or now - mk.born < 1 then
										if FS.ready then formStarved = frame end
										waiting = true
									end
								end
								shaped = cav.fout ~= nil
							elseif fadeOn and form and deep and cav and mk.frame and fade >= 1 and d < cavDist + 60 and not cav.fout and not cav.fbad and FS.ready and formFrame ~= frame and formStarved < frame - 1 then
								-- (phase 19, woundFade: made a little before it is wanted, so that it is
								-- there in the frame the wound comes within cavDist; for the frame or two
								-- it waited to be made there, the wound had no opening at all. Not in a
								-- frame after one in which a wound within cavDist waited for the bake:
								-- that one has the frame's bake first.)
								formFrame = frame
								BakeForm(mk, m)
							end
							local ownOpening = shaped or waiting
							-- what the mark is drawn with: its bone's matrix, and on skin that bends
							-- what the skin under it has done since its patch was baked (Follow)
							local dm = mk.bm
							if not dm then dm = Matrix() mk.bm = dm end
							if mk.fixOn and not mk.rigid then
								local b11, b12, b13, b14, b21, b22, b23, b24, b31, b32, b33, b34 = boneMat:Unpack()
								local fr, ft = mk.fr, mk.ft
								dm:SetUnpacked(
									b11 * fr[1] + b12 * fr[4] + b13 * fr[7], b11 * fr[2] + b12 * fr[5] + b13 * fr[8], b11 * fr[3] + b12 * fr[6] + b13 * fr[9], b11 * ft[1] + b12 * ft[2] + b13 * ft[3] + b14,
									b21 * fr[1] + b22 * fr[4] + b23 * fr[7], b21 * fr[2] + b22 * fr[5] + b23 * fr[8], b21 * fr[3] + b22 * fr[6] + b23 * fr[9], b21 * ft[1] + b22 * ft[2] + b23 * ft[3] + b24,
									b31 * fr[1] + b32 * fr[4] + b33 * fr[7], b31 * fr[2] + b32 * fr[5] + b33 * fr[8], b31 * fr[3] + b32 * fr[6] + b33 * fr[9], b31 * ft[1] + b32 * ft[2] + b33 * ft[3] + b34,
									0, 0, 0, 1)
							else
								dm:Set(boneMat)
							end
							cam.PushModelMatrix(dm)							for k = 1, #layers do
								local l = layers[k]
								local kind = l.kind
								local a = l.a * fade
								-- (phase 19, woundFade: what the bands of distance leave of the layer, the
								-- mark's and, for detail and sheen, their own. Whether it is drawn at all is
								-- asked of it unfaded, below: it is cut only where a band ends.)
								local fl = 1
								if fadeOn then
									fl = fMark
									if l.detail then fl = fl * fDetail end
									if kind == K_GLOSS then fl = fl * fGloss end
								end
								if (l.detail and not detailOK) or (ownOpening and l.ofHole) then
									a = 0
								elseif kind == K_BRUISE then
									a = a * bruise * inten
								elseif kind == K_FLUSH then
									a = a * (1 - 0.75 * bruise) * Clamp((now - mk.born) / 0.5, 0, 1) * inten
								elseif kind == K_BLOOD then
									-- (from nothing, at the opening, and outward as more comes)
									a = a * film * inten * min(1, blot * 5) * blotA
									l.half = l.half0 * (0.3 + 0.7 * sqrt(blot)) * blotK
								elseif kind == K_GLOSS then
									a = (d < 600) and a * gk or 0
									if l.ofBlot then
										a = a * min(1, blot * 5) * blotA
										l.half = l.half0 * (0.3 + 0.7 * sqrt(blot)) * blotK
									end
								elseif kind == K_CRUST then
									a = a * crust * min(1, blot * 5) * blotA
									l.half = l.half0 * (0.3 + 0.7 * sqrt(blot)) * blotK
								elseif kind == K_SOAK or kind == K_SOAKB then
									-- (from nothing: it starts as a spot at the opening)
									a = a * min(1, soak * 5) * soakA
									l.half = l.half0 * (0.22 + 0.78 * sqrt(soak)) * (r.soakOnly and 1 or soakK)
								end
								-- (phase 19, woundBlotFade: a layer of no size is not placed; PlaceLayer
								-- divides by it)
								if a > 0.02 and fl > 0 and not (blotFade and l.half < 1e-3) then
									a = a * fl
									local mat = l.mat
									PlaceLayer(mat, S, l)
									if l.pass == PASS_FILTER then
										-- multiplied over the lit surface: opacity through colour and alpha.
										-- Dried blood in cloth is browner and a little lighter than wet
										local f = min(a, 1)
										colVec:SetUnpacked(min(1, f * (1 + 0.5 * dry)) ^ GAMMA, min(1, f * (1 + 0.9 * dry)) ^ GAMMA, min(1, f * (1 + 0.5 * dry)) ^ GAMMA)
										mat:SetVector("$color", colVec)
										mat:SetFloat("$alpha", f)
										render.SetMaterial(mat)
										R.BeginFilter()
										ms:Draw()
										R.EndFilter()
									elseif l.pass == PASS_GLOSS then
										colVec:SetUnpacked(a * lr, a * lg, a * lb)
										mat:SetVector("$color", colVec)
										render.SetMaterial(mat)
										ms:Draw()
									elseif kind == K_SOAKB then
										-- (what blood in cloth scatters back: a dark red, browner as it dries)
										local t = 1 - 0.3 * dry
										colVec:SetUnpacked(min(1, lr * 0.5 * t), min(1, lg * (0.07 + 0.05 * dry) * t), min(1, lb * 0.08 * t))
										mat:SetVector("$color", colVec)
										mat:SetFloat("$alpha", min(a, 1))
										render.SetMaterial(mat)
										ms:Draw()
									else
										local t = ((kind == K_BLOOD or kind == K_CRUST) and dk or 1) * (l.tint or 1)
										colVec:SetUnpacked(min(1.3, lr * (kind == K_BLOOD and mk.tone or 1) * t * (l.cr or 1)), min(1.3, lg * t * (l.cg or 1)), min(1.3, lb * t * (l.cb or 1)))
										mat:SetVector("$color", colVec)
										mat:SetFloat("$alpha", min(a, 1))
										render.SetMaterial(mat)
										ms:Draw()
									end
									drawn = drawn + 1
								end
							end
							-- The wound's inside, through its opening: it is cut out of everything that
							-- is on the skin, the blood that lies on the body too, so it is drawn when
							-- that is there (W.DrawOpenings, after the body's film; it was drawn here
							-- and the film kept out of the opening: a dry hole with blood round it).
							local isForm = shaped
							if shaped or (deep and cav and not waiting and d < cavDist and fade >= 1) then
								local on = FS.on + 1
								FS.on = on
								local e = FS.open[on]
								if not e then
									e = {}
									FS.open[on] = e
								end
								e.mk, e.ms, e.S, e.form = mk, ms, S, isForm
								e.lr, e.lg, e.lb, e.wet, e.clot, e.dry, e.gk, e.film = lr, lg, lb, wet, clot, dry, gk, film
								e.ax, e.ay, e.az = ax, ay, az
								-- (a form's rim: its light and shade go over what is on the skin, after
								-- the opening: W.DrawRelief)
								if shaped and d < WC.formDist and WC.relief > 0 then
									mk.wetK = film * (1 - dry) * (1 - 0.8 * clot)
									mk.flr, mk.flg, mk.flb = lr, lg, lb
									mk.glintOK = d < WC.glintDist
									FS.n = FS.n + 1
									FS.list[FS.n] = mk
								end
								cut = true
							end
							cam.PopModelMatrix()
							-- abl_wound_debug: the wound's place and the skin's normal there
							if dbg then
								render.SetColorMaterial()
								local p0 = Vector(ax, ay, az)
								render.DrawLine(p0, Vector(ax + anx * 3, ay + any * 3, az + anz * 3), Color(60, 255, 60), false)
								render.DrawWireframeSphere(p0, 0.25, 6, 6, Color(255, 220, 40), false)
							end
						end
					end
				end
			end
		end
	end
	if drawn > 0 then ABL.Prof.Count("mark layers", drawn) end
	W.layersDrawn = W.layersDrawn + drawn
	if old then
		for i = #marks, 1, -1 do
			local mk = marks[i]
			if mk.kind ~= "soak" and now - mk.born >= life then mk.gone = true W.FreeMark(mk) table.remove(marks, i) end
		end
	end
	-- (true: a wound of this body has an opening to cut in this frame; W.DrawOpenings, W.DrawRelief)
	return cut
end

-- The openings of the wounds W.Draw has just drawn on this body, cut out of the picture as it is
-- by now: the skin or the cloth, what the wounds paint on it, and the blood that lies on the body.
-- So what is seen in a wound that bleeds is its own blood, standing in it to the brim and going
-- on over its lip into the flow below. Called once the body's blood is drawn, before the rims.
function W.DrawOpenings(src)
	local n = FS.on
	if n == 0 or FS.src ~= src then return end
	FS.on = 0
	local body = src.body
	local rt = RealTime()
	V19Read()
	ABL.Render.EndFilter()
	local open = FS.open
	for i = 1, n do
		local e = open[i]
		local mk = e.mk
		if IsValid(body) and mk.bm and not mk.gone then
			cam.PushModelMatrix(mk.bm)
			if e.form then
				DrawForm(mk, e.ms, e.lr, e.lg, e.lb, e.clot, e.dry, e.film, body, e.ax, e.ay, e.az, rt)
			else
				DrawCavity(mk, e.ms, e.S, e.lr, e.lg, e.lb, e.wet, e.clot, e.dry, e.gk, e.film)
			end
			cam.PopModelMatrix()
		end
		e.mk, e.ms = nil, nil
	end
end

function W.Clear(src)
	for _, mk in ipairs(src.marks or {}) do
		mk.gone = true
		FreeMark(mk)
	end
	src.marks = nil
	src.pendingMarks = nil
end

------------------------------------------------------------------------------------------
-- Commands (the console; all of them act on this client's picture only)
--   abl_wound_report        how many wounds are kept and drawn
--   abl_wound_clear         removes every wound mark and record (the blood stays: abl_clear)
--   abl_wound_test [kind]   a wound for looking at, on the character under the crosshair:
--                           bullet, through, cut, stab or blunt. It is made here and nowhere
--                           else: no damage is done, nobody else sees it, nothing bleeds on.
------------------------------------------------------------------------------------------
function W.Report()
	local recs, marks, withCav, built, patches = #ABL.Wounds.list, 0, 0, 0, 0
	local kinds = {}
	for _, src in ipairs(ABL.Sources.list) do
		for _, mk in ipairs(src.marks or {}) do
			marks = marks + 1
			kinds[mk.kind] = (kinds[mk.kind] or 0) + 1
			if mk.cav then withCav = withCav + 1 if mk.cav.mesh or mk.cav.fout then built = built + 1 end end
			if mk.mesh then patches = patches + 1 end
		end
	end
	local parts = {}
	for k, n in pairs(kinds) do parts[#parts + 1] = n .. " " .. k end
	table.sort(parts)
	return recs, marks, withCav, built, patches, table.concat(parts, ", ")
end

concommand.Add("abl_wound_report", function()
	local recs, marks, withCav, built, patches, kinds = W.Report()
	ABL.Print("wounds: %d record(s); %d mark(s) on bodies (%s); %d with a recess, %d of those built; %d patch mesh(es) held", recs, marks, kinds ~= "" and kinds or "none", withCav, built, patches)
	local life = C.cl.woundLife:GetFloat()
	ABL.Print("settings: marks %s, recess %s, at most %d a character, drawn to %d units, recess to %d units, intensity %.2f, kept %s", tostring(C.cl.woundMarks:GetBool()), tostring(C.cl.wound3d:GetBool()),
		C.cl.woundMax:GetInt(), C.cl.woundDist:GetInt(), C.cl.wound3dDist:GetInt(), C.cl.woundIntensity:GetFloat(),
		life > 0 and string.format("for %d s", life) or "as long as the body is there")
end, nil, "AdvancedBlood: how many wounds are kept and drawn on this client")

concommand.Add("abl_wound_clear", function()
	for _, src in ipairs(ABL.Sources.list) do W.Clear(src) end
	ABL.Wounds.Clear()
	ABL.Print("wound marks and records cleared (on this client)")
end, nil, "AdvancedBlood: removes every wound mark on this client")

local TEST = {
	bullet  = function(N) return { class = N.DMG_BULLET, pen = WD.PEN_RETAINED, energy = 2, velocity = 1, diameter = 6, damage = 30 } end,
	through = function(N) return { class = N.DMG_BULLET, pen = WD.PEN_THROUGH, energy = 4, velocity = 3, diameter = 5, damage = 60 } end,
	cut     = function(N) return { class = N.DMG_SLASH, pen = WD.PEN_SOFT, energy = 3, velocity = 0, diameter = 12, damage = 40 } end,
	stab    = function(N) return { class = N.DMG_SLASH, pen = WD.PEN_SOFT, energy = 7, velocity = 0, diameter = 4, damage = 30 } end,
	blunt   = function(N) return { class = N.DMG_CLUB, pen = WD.PEN_SOFT, energy = 2, velocity = 0, diameter = 8, damage = 28 } end,
}
concommand.Add("abl_wound_test", function(_, _, args)
	local make = TEST[string.lower(args[1] or "bullet")]
	if not make then ABL.Print("abl_wound_test: one of bullet, through, cut, stab, blunt") return end
	local eye, fwd = EyePos(), EyeAngles():Forward()
	local tr = util.TraceLine({ start = eye, endpos = eye + fwd * 800, filter = LocalPlayer(), mask = MASK_SHOT })
	local ent = tr.Entity
	if not tr.Hit or not IsValid(ent) or not (ent:IsPlayer() or ent:IsNPC() or ent:IsRagdoll()) then
		ABL.Print("abl_wound_test: no character under the crosshair")
		return
	end
	-- the bone of what was hit, and the place in that bone's space
	local bone
	if ent:IsRagdoll() then bone = ent:TranslatePhysBoneToBone(tr.PhysicsBone or 0)
	elseif tr.HitBox then bone = ent:GetHitBoxBone(tr.HitBox, ent:GetHitboxSet() or 0) end
	local bm = bone and ent:GetBoneMatrix(bone)
	if not bm then ABL.Print("abl_wound_test: that place has no bone to put a wound on") return end
	local ev = make(ABL.Net)
	ev.body, ev.owner = ent, ent:IsPlayer() and ent or nil
	ev.bone = bone
	ev.lpos = WorldToLocal(tr.HitPos, angle_zero, bm:GetTranslation(), bm:GetAngles())
	ev.dir = Vector(fwd.x, fwd.y, fwd.z)
	ev.bleed, ev.hitgroup, ev.range, ev.flags = 0, tr.HitGroup or 0, WD.RANGE_DISTANT, 0
	ev.seed = math.random(0, 65535)
	-- (a wound for looking at: shown as one that has bled, though nothing comes out of it)
	ev.forLooks = true
	local ok, err = pcall(ABL.Emission.OnHit, ev)
	if not ok then ABL.Print("abl_wound_test: %s", tostring(err)) return end
	ABL.Print("abl_wound_test: a %s on %s (this client only; nothing was damaged)", args[1] or "bullet", tostring(ent))
end, nil, "AdvancedBlood: a wound for looking at on the character under the crosshair (bullet, through, cut, stab, blunt); this client only, no damage")
