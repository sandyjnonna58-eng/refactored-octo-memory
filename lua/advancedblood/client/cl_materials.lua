-- Material registry. Engine decals use the shipped LightmappedGeneric VMTs (with $modelmaterial
-- for studio models). Directional decals get lazily created rotated variants through
-- $basetexturetransform. Everything else ABL draws itself with UnlitGeneric materials, in three kinds
-- of pass (see tools/texgen for the textures and cl_render.lua for the blend states):
--   * filter:  blood as an absorbing film multiplied over the lit surface (the surface shows through
--              thin blood, lighting and shadows are the real ones): ground stains, runoff trails,
--              settled body streaks,
--   * colour:  blood with its own colour and alpha, lit on the CPU through vertex colours: drops,
--              flowing rivulets, wet overlays on walls,
--   * gloss:   additive reflection of the surroundings where blood is wet, shaped by a gloss mask.

ABL.NoJIT()
ABL.Mat = ABL.Mat or {}
local M = ABL.Mat

local families = {
	drop = 4, splat = 4, elong = 4, sat = 3, streak = 4, smear = 4, pool = 4, soak = 3, wound = 1,
}
M.families = families

-- texture width in pixels (decalscale = 1/width, so DecalEx scale == world units)
M.texSize = { drop = 256, splat = 512, elong = 512, sat = 256, streak = 256, smear = 512, pool = 512, soak = 256, wound = 256 }
-- world units covered by the stain content relative to the texture width (content radius)
M.contentScale = { drop = 0.66, splat = 0.8, elong = 0.9, sat = 0.9, streak = 0.5, smear = 0.95, pool = 0.9, soak = 0.62, wound = 0.6 }

M.decal = {}   -- family -> { IMaterial ... }
M.rotated = {} -- "family:index:step" -> IMaterial

local function Unlit(name, tex, kind, extra)
	local kv = { ["$basetexture"] = tex, ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1 }
	if kind == "additive" then kv["$additive"] = 1 else kv["$translucent"] = 1 end
	for k, v in pairs(extra or {}) do kv[k] = v end
	return CreateMaterial(name, "UnlitGeneric", kv)
end

local function Load()
	for fam, n in pairs(families) do
		M.decal[fam] = {}
		for i = 1, n do M.decal[fam][i] = Material("advancedblood/decals/" .. fam .. i) end
	end
	-- airborne blood
	M.droplet = Material("advancedblood/sprites/droplet")        -- a lit liquid drop (colour)
	M.dropStreak = Material("advancedblood/sprites/dropstreak")  -- the same drop smeared by motion
	M.stream = Material("advancedblood/sprites/stream")          -- arterial jet segment (loose)
	M.streamTile = Material("advancedblood/sprites/streamtile")  -- a continuous stream, tiled along it
	M.glint = Material("advancedblood/sprites/glint")            -- additive highlight
	M.mist = {}
	for i = 1, 4 do M.mist[i] = Material("advancedblood/sprites/mist" .. i) end
	-- rivulets: flowing (colour), trails and soaked streaks (filter), their reflection (gloss)
	M.film = Material("advancedblood/sprites/film")
	M.filmFilter = Unlit("abl_filmfilter", "advancedblood/sprites/filmfilter")
	M.filmGloss = Unlit("abl_filmgloss", "advancedblood/sprites/filmgloss", "additive")
	-- the same reflection for static body meshes: its strength is set per draw through $color
	M.bodyGloss = Unlit("abl_bodygloss", "advancedblood/sprites/filmgloss", "additive")
	-- ground impact stains: the filter atlas, and the gloss atlas (same layout) for the reflection,
	-- its unevenness from the sheen pattern as a detail texture. One stain sees less than one band
	-- of the pattern (the atlas has 8 cells across: at eight periods across the atlas a stain was
	-- striped like a sweet)
	M.groundFilter = Unlit("abl_groundfilter", "advancedblood/ground/stainfilter")
	M.groundGloss = Unlit("abl_groundgloss", "advancedblood/ground/stainatlas", "additive", {
		["$detail"] = "advancedblood/sprites/sheen", ["$detailscale"] = 1, ["$detailblendmode"] = 0,
	})
	-- (the same for the stains' mirror where the map has no cubemap: its strength per draw in $color)
	M.groundSheen = Unlit("abl_groundsheen", "advancedblood/ground/stainatlas", "additive", {
		["$detail"] = "advancedblood/sprites/sheen", ["$detailscale"] = 1, ["$detailblendmode"] = 0,
	})
	-- the key light's highlight on the bodies of liquid on a floor: the engine's own highlight, worked
	-- out for every pixel from the way the body's surface faces there. A lit material with a black
	-- body, added to the picture; the atlas' coverage is its mask (the stain's outline).
	M.groundPhong = CreateMaterial("abl_groundphong", "VertexLitGeneric", {
		["$basetexture"] = "advancedblood/ground/stainatlas", ["$nocull"] = 1, ["$additive"] = 1, ["$color2"] = "[0 0 0]",
		["$phong"] = 1, ["$phongexponent"] = ABL.Config.Ground.glossExp, ["$phongboost"] = ABL.Config.Ground.glossBoost,
		["$phongfresnelranges"] = "[1 1 1]", ["$basemapalphaphongmask"] = 1,
	})
	-- drop outlines (gloss atlas: luminance + coverage) for the liquid beads on bodies
	M.ground = Unlit("abl_ground", "advancedblood/ground/stainatlas")
	M.white = Material("vgui/white")
	-- all wet overlays share one atlas (fresh colour) so they can be batched into a few static meshes;
	-- their reflection uses the gloss version of the same cells
	M.atlas = Unlit("abl_stainatlas", "advancedblood/sprites/stainatlas")
	M.atlasGloss = Unlit("abl_stainatlasgloss", "advancedblood/sprites/stainglossatlas", "additive", {
		["$detail"] = "advancedblood/sprites/sheen", ["$detailscale"] = 0.5, ["$detailblendmode"] = 0,
	})
end
Load()

function M.Mist() return M.mist[math.random(1, #M.mist)] end

-- Atlas cells (4x4, 512 px each with a 12 px margin); order matches tools/texgen/texgen.cs.
local ATLAS_ORDER = { "drop1", "drop2", "drop3", "drop4", "splat1", "splat2", "splat3", "splat4",
	"elong1", "elong2", "elong3", "elong4", "soak1", "soak2", "soak3", "smear1" }
M.atlasCells = {}
for i, name in ipairs(ATLAS_ORDER) do
	local cx, cy = (i - 1) % 4, math.floor((i - 1) / 4)
	local m = 12 / 2048
	M.atlasCells[name] = { cx * 0.25 + m, cy * 0.25 + m, (cx + 1) * 0.25 - m, (cy + 1) * 0.25 - m }
end
-- families without their own cell reuse a similar shape (overlays are soft wet sheens)
function M.AtlasCell(fam, idx)
	return M.atlasCells[fam .. idx] or M.atlasCells[fam .. "1"] or M.atlasCells.drop1
end

M.ROT_STEPS = 16

-- Engine decal material for `fam` variant `idx`, rotated by `step` (0..ROT_STEPS-1) in texture space.
function M.Decal(fam, idx, step)
	if not step or step == 0 then return M.decal[fam][idx] end
	local key = fam .. ":" .. idx .. ":" .. step
	local mat = M.rotated[key]
	if mat then return mat end
	local deg = step * 360 / M.ROT_STEPS
	local path = "advancedblood/decals/" .. fam .. idx
	mat = CreateMaterial("abl_rot_" .. fam .. idx .. "_" .. step, "LightmappedGeneric", {
		["$basetexture"] = path,
		["$decal"] = 1,
		["$decalscale"] = 1 / M.texSize[fam],
		["$translucent"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$basetexturetransform"] = string.format("center .5 .5 scale 1 1 rotate %.3f translate 0 0", deg),
		["$modelmaterial"] = path .. "_model",
	})
	M.rotated[key] = mat
	return mat
end

-- The same stain for a model (a prop, a body). On a model the engine draws a decal with the
-- material named in "$modelmaterial", and for every turned variant above that is the one model
-- material there is, which is not turned. So on a model every stain lay the same way up, and one
-- with a direction lay level whatever its direction was (phase 46: the trail a stream left down
-- the side of a crate was a ladder of level dashes). A model gets a turned model material of its
-- own, handed to the engine as the decal itself.
M.rotatedModel = {}
function M.DecalModel(fam, idx, step)
	step = step or 0
	local key = fam .. ":" .. idx .. ":" .. step
	local mat = M.rotatedModel[key]
	if mat then return mat end
	local path = "advancedblood/decals/" .. fam .. idx
	if step == 0 then
		mat = Material(path .. "_model")
	else
		-- (as the shipped <name>_model.vmt, turned)
		mat = CreateMaterial("abl_rotm_" .. fam .. idx .. "_" .. step, "VertexLitGeneric", {
			["$basetexture"] = path,
			["$decal"] = 1,
			["$decalscale"] = 1 / M.texSize[fam],
			["$translucent"] = 1,
			["$color2"] = "[0.62 0.58 0.58]",
			["$basetexturetransform"] = string.format("center .5 .5 scale 1 1 rotate %.3f translate 0 0", step * 360 / M.ROT_STEPS),
		})
	end
	M.rotatedModel[key] = mat
	return mat
end

-- The spot a drop leaves on a character where no film of blood can lie (cl_stains.lua,
-- S.OnCharacter): the same stain in the colour the blood on that body has. The stains' own
-- pictures are the dark of blood that has soaked in and dried (58 12 16 of 255, and the model
-- material takes 0.62 of that), right for cloth soaked round a wound; on a face beside the film
-- of fresh blood that has just run there, a spot of it was a black blotch (measured in one
-- picture, in the sun: 42 11 9 beside the film's 120 22 21; in the shade 5 1 0 beside 47 6 4).
local SPOT_TINT = "[1.75 1.2 1.3]"
M.spotModel = {}
function M.DecalSpot(fam, idx, step)
	step = step or 0
	local key = fam .. ":" .. idx .. ":" .. step
	local mat = M.spotModel[key]
	if mat then return mat end
	mat = CreateMaterial("abl_spot_" .. fam .. idx .. "_" .. step, "VertexLitGeneric", {
		["$basetexture"] = "advancedblood/decals/" .. fam .. idx,
		["$decal"] = 1,
		["$decalscale"] = 1 / M.texSize[fam],
		["$translucent"] = 1,
		["$color2"] = SPOT_TINT,
		["$basetexturetransform"] = string.format("center .5 .5 scale 1 1 rotate %.3f translate 0 0", step * 360 / M.ROT_STEPS),
	})
	M.spotModel[key] = mat
	return mat
end

-- Making one of these while the game runs holds the frame it is made in: about 15 ms each (the
-- material system waits for the renderer), once for every rotation of every stain texture that
-- is used for the first time. That was a stutter all through the first fight of a session, and
-- the governor took the lost time for the cost of the blood and cut its detail for a while
-- (measured, phase 28). They are all made here instead, once, while the map loads.
do
	local t0 = SysTime()
	local n = 0
	for fam, cnt in pairs(families) do
		for i = 1, cnt do
			for step = 1, M.ROT_STEPS - 1 do
				M.Decal(fam, i, step)
				M.DecalModel(fam, i, step)
				n = n + 2
			end
		end
	end
	ABL.Print("decal materials: %d rotations made in %.0f ms", n, (SysTime() - t0) * 1000)
end

function M.Random(fam, rng)
	local n = families[fam] or 1
	if rng then return math.min(n, 1 + math.floor(rng:Next() * n)) end
	return math.random(1, n)
end
