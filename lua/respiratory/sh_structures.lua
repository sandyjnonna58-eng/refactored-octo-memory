-- What there is of the respiratory system: structures with stable ids, the same for every model and
-- every asset. Not a second registry of anything: bones are the skeleton module's (HemoSkeleton),
-- the brain is the brain module's (NeuroTrauma.Atlas); a structure here points at those by their
-- own ids. Z-City's names for what it keeps stand in the adapter (sv_zcity.lua), not here.
--
-- Rules, as the skeleton registry has them: an id is never renamed, a number never reused, new
-- structures are appended; RS.STRUCT_SUM is a checksum of the ids in order.
--
--   RS.Struct(id or number)        the structure
--   RS.StructList, RS.Structs      in order, and by id
--   RS.Children(id)                what it is made of
--   RS.CheckStructures()           complaints as lines (none: the list is whole)

local RS = HemoRespiratory

-- id, name, kind, side ("l", "r" or nil), parent, tier (1: what the model and the state know of;
-- 2: named for completeness, with nothing drawn or kept for it yet)
local LIST = {
	{ "upper_airway", "nose, mouth and pharynx", "airway", nil, nil, 2 },
	{ "larynx", "larynx", "airway", nil, nil, 2 },
	{ "trachea", "trachea", "airway", nil, nil, 1 },
	{ "bronchus_r", "right main bronchus", "airway", "r", "trachea", 1 },
	{ "bronchus_l", "left main bronchus", "airway", "l", "trachea", 1 },
	{ "bronchus_ru", "right upper lobe bronchus", "airway", "r", "bronchus_r", 1 },
	{ "bronchus_rm", "right middle lobe bronchus", "airway", "r", "bronchus_r", 1 },
	{ "bronchus_rl", "right lower lobe bronchus", "airway", "r", "bronchus_r", 1 },
	{ "bronchus_lu", "left upper lobe bronchus", "airway", "l", "bronchus_l", 1 },
	{ "bronchus_ll", "left lower lobe bronchus", "airway", "l", "bronchus_l", 1 },
	{ "lung_r", "right lung", "lung", "r", nil, 1 },
	{ "lung_l", "left lung", "lung", "l", nil, 1 },
	{ "lobe_ru", "right upper lobe", "lobe", "r", "lung_r", 1 },
	{ "lobe_rm", "right middle lobe", "lobe", "r", "lung_r", 1 },
	{ "lobe_rl", "right lower lobe", "lobe", "r", "lung_r", 1 },
	{ "lobe_lu", "left upper lobe", "lobe", "l", "lung_l", 1 },
	{ "lobe_ll", "left lower lobe", "lobe", "l", "lung_l", 1 },
	{ "pleura_r", "right pleural space", "pleura", "r", nil, 1 },
	{ "pleura_l", "left pleural space", "pleura", "l", nil, 1 },
	{ "diaphragm_r", "right half of the diaphragm", "muscle", "r", nil, 1 },
	{ "diaphragm_l", "left half of the diaphragm", "muscle", "l", nil, 1 },
	{ "intercostals_r", "right intercostal muscles", "muscle", "r", nil, 2 },
	{ "intercostals_l", "left intercostal muscles", "muscle", "l", nil, 2 },
}

RS.Structs, RS.StructList = {}, {}
local sum = 0
for i, e in ipairs(LIST) do
	local s = { id = e[1], idx = i - 1, name = e[2], kind = e[3], side = e[4], parent = e[5], tier = e[6] }
	RS.Structs[s.id] = s
	RS.StructList[i] = s
	for k = 1, #s.id do sum = (sum * 31 + string.byte(s.id, k) * i) % 2147483647 end
end
for _, s in ipairs(RS.StructList) do
	if s.side then
		local other = string.gsub(s.id, "_" .. s.side .. "(%a?)$", "_" .. (s.side == "l" and "r" or "l") .. "%1")
		-- (a mirror is a structure of the same kind on the other side: the right middle lobe has none)
		if RS.Structs[other] and other ~= s.id then s.mirror = other end
	end
end
RS.STRUCT_SUM = sum
RS.STRUCT_EXPECT = sum          -- (set to the number itself once the list is published: a change of it is then a complaint)

function RS.Struct(id)
	if isnumber(id) then return RS.StructList[id + 1] end
	return RS.Structs[id]
end

function RS.Children(id)
	local out = {}
	for _, s in ipairs(RS.StructList) do if s.parent == id then out[#out + 1] = s.id end end
	return out
end

-- What a structure has to do with the structures of other systems, in those systems' own terms
-- (the form of the skeleton module's SK.Relations). bones: a bone, a set or a group of its registry.
RS.Relations = {
	{ rel = "enclosed by", what = { "lung_r", "lung_l", "pleura_r", "pleura_l" }, system = "skeleton", bones = "rib_cage", note = "each pair of ribs is a load of its own on a body: the model's bones go with them pair by pair" },
	{ rel = "fastened to", what = { "diaphragm_r", "diaphragm_l" }, system = "skeleton", bones = { "rib7_l", "rib8_l", "rib9_l", "rib10_l", "rib11_l", "rib12_l", "rib7_r", "rib8_r", "rib9_r", "rib10_r", "rib11_r", "rib12_r", "sternum", "l1", "l2", "l3" } },
	{ rel = "level with", what = { "trachea" }, system = "skeleton", bones = { "c6", "c7", "t1", "t2", "t3", "t4" }, note = "from the sixth neck vertebra to its fork at the fourth chest vertebra" },
	{ rel = "driven by", what = { "diaphragm_r", "diaphragm_l" }, system = "neurotrauma", channel = "respiration", regions = { "L_medulla_teg", "R_medulla_teg", "L_pons_teg", "R_pons_teg" }, tracts = { "L_cord_cervical", "R_cord_cervical" },
		note = "the brain module works out how much control is left (its st.resp) and what pattern the breathing has; nothing of that is worked out here" },
	{ rel = "kept by", what = { "lung_l", "lung_r", "trachea", "pleura_l", "pleura_r" }, system = "zcity", note = "damage, puncture, air in the pleural space, the oxygen store: sv_zcity.lua names the fields" },
}

function RS.CheckStructures()
	local bad = {}
	local seen = {}
	for i, s in ipairs(RS.StructList) do
		if seen[s.id] then bad[#bad + 1] = "the id " .. s.id .. " stands twice" end
		seen[s.id] = true
		if s.idx ~= i - 1 then bad[#bad + 1] = s.id .. " has the number " .. tostring(s.idx) end
		if s.parent and not RS.Structs[s.parent] then bad[#bad + 1] = s.id .. " hangs on " .. tostring(s.parent) .. ", which is not there" end
		if s.mirror and (not RS.Structs[s.mirror] or RS.Structs[s.mirror].mirror ~= s.id) then bad[#bad + 1] = s.id .. " and its mirror do not name each other" end
	end
	for _, r in ipairs(RS.Relations) do
		for _, id in ipairs(r.what) do if not RS.Structs[id] then bad[#bad + 1] = "a relation names " .. tostring(id) .. ", which is not there" end end
		-- the other modules' ids, where those modules are loaded
		if r.system == "skeleton" and istable(HemoSkeleton) and istable(HemoSkeleton.Bones) then
			local SK = HemoSkeleton
			for _, b in ipairs(istable(r.bones) and r.bones or { r.bones }) do
				if not SK.Bones[b] and not (istable(SK.Groups) and SK.Groups[b]) and not (istable(SK.Sets) and SK.Sets[b]) then bad[#bad + 1] = "the skeleton's registry has no " .. tostring(b) end
			end
		elseif r.system == "neurotrauma" and istable(NeuroTrauma) and istable(NeuroTrauma.Atlas) then
			local A = NeuroTrauma.Atlas
			for _, k in ipairs(r.regions or {}) do if not (istable(A.regionOf) and A.regionOf[k]) then bad[#bad + 1] = "the brain's atlas has no region " .. k end end
			for _, k in ipairs(r.tracts or {}) do if not (istable(A.tractOf) and A.tractOf[k]) then bad[#bad + 1] = "the brain's atlas has no tract " .. k end end
		end
	end
	return bad
end
