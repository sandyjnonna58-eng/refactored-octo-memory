-- The skull and what it holds: references between the skeleton's registry and the brain module
-- (lua/neurotrauma). There is one brain and it is that module's: nothing of it is copied here.
-- This file only says which of its structures lie under which bone, in its own terms (the ids of
-- its atlas), and which stretch of its spinal cord runs through which vertebrae.
--
-- Skull and brain are two structures in one frame. The frame is the brain module's head frame
-- (Z.HeadFrame in its sv_zcity.lua: the directions left, face, up from a place over the head
-- bone); the skull's regions are laid out in it (sh_stock.lua, cranial). Where the brain lies in the
-- skull is said in one place, sh_headfit.lua (its size, centre and pitch in the stock skull and in
-- each fitted head): a region of the atlas is under the bone that lies outward of it there.
-- That is the brain as it is drawn. The brain module's own reckoning of hits (its server's head
-- frame, the atlas at the head's half extents) is that module's and is not touched from here.
--
--   SK.Brain.Available()          is the brain module loaded
--   SK.Brain.BoneOver(region)     the skull bone over a region of the atlas (its key or its id)
--   SK.Brain.RegionsUnder(bone)   the atlas's cortical regions under a skull bone: a list of their ids
--   SK.Brain.Cord(vertebra)       the stretch of cord in a vertebra: { level, field, tracts }
--   SK.Relations                  what encloses what, as data

local SK = HemoSkeleton
SK.Brain = SK.Brain or {}
local BR = SK.Brain
local CR = SK.Cranial

function BR.Available()
	return istable(NeuroTrauma) and istable(NeuroTrauma.Atlas) and istable(NeuroTrauma.Atlas.regions) and istable(NeuroTrauma.Config)
end

-- A place of the atlas (its own numbers: x to the side, left positive; y back to front; z base to
-- crown; in units of the head's half extents) in the stock skull's head frame, in units: where the
-- brain's mesh has it (the atlas by the head's half extents, a third of that a mesh unit), as the
-- brain lies in that skull (sh_headfit.lua: its size, centre and pitch there).
function BR.AtlasToHead(x, y, z)
	local A = NeuroTrauma.Config.Anatomy
	return SK.HeadFit.BrainCanon(x * A.headX / 3, y * A.headY / 3, z * A.headZ / 3)
end

local over, under

local function Build()
	over, under = {}, {}
	if not BR.Available() then return end
	-- (the brain lies under the braincase: a region low at the front is under the frontal or the
	-- sphenoid bone, not under the cheek that the line through it happens to come out at)
	local braincase = {}
	for _, id in ipairs(SK.BonesOf("neurocranium")) do braincase[id] = true end
	-- The bone over a region: out from the brain's own middle through the region to the skull's
	-- outside, and the bone that place belongs to. (The brain's middle is not the middle the shell is
	-- laid out about: the brain lies back and up in this skull.)
	local cx, cy, cz = BR.AtlasToHead(0, 0, 0)
	local sqrt = math.sqrt
	local function Over(hx, hy, hz)
		local dx, dy, dz = hx - cx, hy - cy, hz - cz
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		if l < 1e-6 then return nil end
		dx, dy, dz = dx / l, dy / l, dz / l
		local function Outside(t)
			local x, y, z = cx + dx * t, cy + dy * t, cz + dz * t
			return sqrt(x * x + y * y + z * z) - CR.Radius(x, y, z) > 0, x, y, z
		end
		local lo, hi = 0, 14
		if Outside(lo) or not Outside(hi) then return CR.FromDir(hx, hy, hz, braincase) end
		for _ = 1, 24 do
			local mid = (lo + hi) / 2
			if Outside(mid) then hi = mid else lo = mid end
		end
		local _, x, y, z = Outside(hi)
		return CR.BoneAt(x, y, z, braincase)
	end
	for id, r in pairs(NeuroTrauma.Atlas.regions) do
		-- (cortex only: what lies deep is under no one bone)
		if r.kind == "C" then
			-- (three numbers taken first: a call in the middle of a list of arguments hands on only its first)
			local hx, hy, hz = BR.AtlasToHead(r.x, r.y, r.z)
			local bone = Over(hx, hy, hz)
			if bone then
				over[id] = bone
				under[bone] = under[bone] or {}
				under[bone][#under[bone] + 1] = id
			end
		end
	end
	for _, l in pairs(under) do table.sort(l) end
end

function BR.BoneOver(region)
	if not over then Build() end
	if isstring(region) and BR.Available() then region = NeuroTrauma.Atlas.regionOf[region] end
	return region and over[region] or nil
end

function BR.RegionsUnder(bone)
	if not under then Build() end
	return under[bone] or {}
end

-- (the atlas is built at load and does not change; a reload of either module asks again)
hook.Add("NT_Loaded", "SK_Brain", function() over, under = nil, nil end)

-- The cord. The brain module has three stretches of it, each in a left and a right half, and
-- reads how much of each still conducts from Z-City's three spine regions.
local CORD = {
	cervical = { level = "cervical", field = "spine3", tracts = { "L_cord_cervical", "R_cord_cervical" } },
	thoracic = { level = "thoracic", field = "spine2", tracts = { "L_cord_thoracic", "R_cord_thoracic" } },
	lumbar = { level = "lumbar", field = "spine1", tracts = { "L_cord_lumbar", "R_cord_lumbar" } },
}
function BR.Cord(vertebra)
	local b = SK.Bones[vertebra]
	return b and CORD[b.group] or nil
end

-- What encloses what. what: a structure of another system, named in that system's own terms.
SK.Relations = {
	{ rel = "encloses", bones = "neurocranium", system = "neurotrauma", what = "brain", note = "regions of the atlas of kinds C, D, X and the upper brainstem; BoneOver / RegionsUnder name them bone by bone" },
	{ rel = "encloses", bones = "cervical", system = "neurotrauma", what = "cord_cervical", note = CORD.cervical.tracts },
	{ rel = "encloses", bones = "thoracic", system = "neurotrauma", what = "cord_thoracic", note = CORD.thoracic.tracts },
	{ rel = "encloses", bones = "lumbar", system = "neurotrauma", what = "cord_lumbar", note = CORD.lumbar.tracts },
	{ rel = "encloses", bones = "rib_cage", system = "zcity", what = "heart, lungs", note = "Z-City's organ boxes on the chest bone; nothing of them is modelled here" },
	{ rel = "encloses", bones = "pelvis", system = "zcity", what = "pelvic organs", note = "not modelled" },
}
