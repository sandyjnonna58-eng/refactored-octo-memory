-- The anatomical registry: the bones of a person, the joints between them and the structures they
-- make up. Plain data, built once at load, the same on server and client and for every player model.
-- It names no animation bone and no model: which of a model's bones carries which of these is the
-- rig's business (sh_rig.lua), and what is drawn the geometry's (client/cl_geometry.lua).
--
--   SK.Bones[id]     id      stable name, lower case ("femur_l")
--                    idx     0..205, fixed for good: the number a bone has on the wire. New bones are
--                            only ever appended; SK.REGISTRY_SUM guards the list against a reordering.
--                    name    in words
--                    region  cranium face cervical thorax lumbar sacral pelvis shoulder arm forearm
--                            hand thigh leg foot
--                    side    L, R or M (midline)
--                    class   long short flat irregular sesamoid
--                    tier    1 structural, 2 detailed, 3 minute: what a level of detail may leave out
--                    group   the structure it is part of (SK.Groups: a tree up to "skeleton")
--                    proximal the bone toward the trunk that it hangs on, where there is one: a tree
--                            for asking what lies beyond a bone. Not the rig's tree, and not the
--                            articulations: those are the joints.
--                    joints  ids of the joints it takes part in
--                    mirror  the same bone of the other side
--   SK.Joints[id]    name, type, bones, rig = { parent key, child key } when a joint of the rig moves
--                    it, serves = what it is for (a function key, for later)
--   SK.Groups[id]    name, parent, bones (its own), kids
--   SK.Sets[id]      structures that cut across the tree (the pelvis, the rib cage)
--
-- Anatomy as in any textbook of it [P: standard anatomy, not verified here from a fetched source];
-- the 206 are the usual count of an adult (the sesamoids of hand and foot other than the patellae
-- are not counted, teeth are not bones).

local SK = HemoSkeleton
SK.Bones, SK.BoneList, SK.Joints, SK.JointList, SK.Groups, SK.Sets = {}, {}, {}, {}, {}, {}

-- What the list of ids, in order, adds up to (SK.Sum below). A change of it means that a bone was
-- taken out, renamed or moved, and with it the number of every bone after it: records on the wire
-- and anything saved by number would then name other bones.
SK.REGISTRY_SUM = 948486667

------------------------------------------------------------------------------------------
-- Groups
------------------------------------------------------------------------------------------
local function Group(id, name, parent)
	local g = { id = id, name = name, parent = parent, bones = {}, kids = {} }
	SK.Groups[id] = g
	if parent then local p = SK.Groups[parent] p.kids[#p.kids + 1] = id end
	return g
end

Group("skeleton", "skeleton")
Group("axial", "axial skeleton", "skeleton")
Group("appendicular", "appendicular skeleton", "skeleton")
Group("skull", "skull", "axial")
Group("cranium", "cranium", "skull")
Group("face", "bones of the face", "skull")
Group("ear_l", "ossicles of the left ear", "skull")
Group("ear_r", "ossicles of the right ear", "skull")
Group("hyoid_g", "hyoid", "axial")
Group("column", "vertebral column", "axial")
Group("cervical", "cervical vertebrae", "column")
Group("thoracic", "thoracic vertebrae", "column")
Group("lumbar", "lumbar vertebrae", "column")
Group("sacral", "sacrum and coccyx", "column")
Group("thorax", "thoracic cage", "axial")
Group("ribs_l", "left ribs", "thorax")
Group("ribs_r", "right ribs", "thorax")
for _, s in ipairs({ { "l", "left" }, { "r", "right" } }) do
	local k, w = "_" .. s[1], s[2] .. " "
	Group("upper" .. k, w .. "upper limb", "appendicular")
	Group("shoulder" .. k, w .. "shoulder girdle", "upper" .. k)
	Group("arm" .. k, w .. "arm", "upper" .. k)
	Group("forearm" .. k, w .. "forearm", "upper" .. k)
	Group("hand" .. k, w .. "hand", "upper" .. k)
	Group("carpus" .. k, w .. "carpus", "hand" .. k)
	Group("metacarpus" .. k, w .. "metacarpus", "hand" .. k)
	Group("fingers" .. k, w .. "fingers", "hand" .. k)
	Group("lower" .. k, w .. "lower limb", "appendicular")
	Group("girdle" .. k, w .. "half of the pelvic girdle", "lower" .. k)
	Group("thigh" .. k, w .. "thigh", "lower" .. k)
	Group("leg" .. k, w .. "leg", "lower" .. k)
	Group("foot" .. k, w .. "foot", "lower" .. k)
	Group("tarsus" .. k, w .. "tarsus", "foot" .. k)
	Group("metatarsus" .. k, w .. "metatarsus", "foot" .. k)
	Group("toes" .. k, w .. "toes", "foot" .. k)
end

------------------------------------------------------------------------------------------
-- Bones, in the order of their numbers
------------------------------------------------------------------------------------------
local function Bone(id, name, region, side, class, tier, group, proximal)
	local b = { id = id, idx = #SK.BoneList, name = name, region = region, side = side, class = class, tier = tier, group = group, proximal = proximal, joints = {} }
	SK.Bones[id] = b
	SK.BoneList[#SK.BoneList + 1] = b
	local g = SK.Groups[group]
	g.bones[#g.bones + 1] = id
	return b
end
-- a bone of both sides: left, then right (what it hangs on is the same bone for both)
local function Pair(id, name, region, class, tier, group, proximal)
	for _, s in ipairs({ { "_l", "left ", "L" }, { "_r", "right ", "R" } }) do
		Bone(id .. s[1], s[2] .. name, region, s[3], class, tier, group, proximal)
	end
end

-- skull: cranium (8), face (14)
Bone("frontal", "frontal bone", "cranium", "M", "flat", 2, "cranium", "occipital")
Pair("parietal", "parietal bone", "cranium", "flat", 2, "cranium", "occipital")
Pair("temporal", "temporal bone", "cranium", "irregular", 2, "cranium", "occipital")
Bone("occipital", "occipital bone", "cranium", "M", "flat", 2, "cranium", "c1")
Bone("sphenoid", "sphenoid bone", "cranium", "M", "irregular", 2, "cranium", "occipital")
Bone("ethmoid", "ethmoid bone", "cranium", "M", "irregular", 3, "cranium", "occipital")
Bone("mandible", "mandible", "face", "M", "irregular", 1, "face", "occipital")
Pair("maxilla", "maxilla", "face", "irregular", 2, "face", "occipital")
Pair("zygomatic", "zygomatic bone", "face", "irregular", 2, "face", "occipital")
Pair("nasal", "nasal bone", "face", "flat", 3, "face", "occipital")
Pair("lacrimal", "lacrimal bone", "face", "flat", 3, "face", "occipital")
Pair("palatine", "palatine bone", "face", "irregular", 3, "face", "occipital")
Pair("concha_inf", "inferior nasal concha", "face", "irregular", 3, "face", "occipital")
Bone("vomer", "vomer", "face", "M", "flat", 3, "face", "occipital")
-- hyoid, ossicles
Bone("hyoid", "hyoid bone", "cervical", "M", "irregular", 3, "hyoid_g", nil)
for _, s in ipairs({ { "_l", "left ", "L" }, { "_r", "right ", "R" } }) do
	Bone("malleus" .. s[1], s[2] .. "malleus", "cranium", s[3], "irregular", 3, "ear" .. s[1], "temporal" .. s[1])
	Bone("incus" .. s[1], s[2] .. "incus", "cranium", s[3], "irregular", 3, "ear" .. s[1], "temporal" .. s[1])
	Bone("stapes" .. s[1], s[2] .. "stapes", "cranium", s[3], "irregular", 3, "ear" .. s[1], "temporal" .. s[1])
end
-- vertebral column (26), from the top
local ORDINAL = { "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth" }
do
	local function Next(level, n, count, after)
		if n < count then return level .. (n + 1) end
		return after
	end
	for n = 1, 7 do Bone("c" .. n, ORDINAL[n] .. " cervical vertebra" .. (n == 1 and " (atlas)" or (n == 2 and " (axis)" or "")), "cervical", "M", "irregular", 2, "cervical", Next("c", n, 7, "t1")) end
	for n = 1, 12 do Bone("t" .. n, ORDINAL[n] .. " thoracic vertebra", "thorax", "M", "irregular", 2, "thoracic", Next("t", n, 12, "l1")) end
	for n = 1, 5 do Bone("l" .. n, ORDINAL[n] .. " lumbar vertebra", "lumbar", "M", "irregular", 2, "lumbar", Next("l", n, 5, "sacrum")) end
	Bone("sacrum", "sacrum", "sacral", "M", "irregular", 1, "sacral", nil)
	Bone("coccyx", "coccyx", "sacral", "M", "irregular", 2, "sacral", "sacrum")
end
-- thorax: sternum, ribs (24): the first pair, the second pair ...
Bone("sternum", "sternum", "thorax", "M", "flat", 1, "thorax", nil)
for n = 1, 12 do
	for _, s in ipairs({ { "_l", "left ", "L" }, { "_r", "right ", "R" } }) do
		Bone("rib" .. n .. s[1], s[2] .. ORDINAL[n] .. " rib", "thorax", s[3], "flat", 1, "ribs" .. s[1], "t" .. n)
	end
end
-- limbs: a whole upper limb of the left, then of the right; then the lower limbs
local DIGIT = { "first", "second", "third", "fourth", "fifth" }
for _, s in ipairs({ { "_l", "left ", "L" }, { "_r", "right ", "R" } }) do
	local k, w, S = s[1], s[2], s[3]
	Bone("clavicle" .. k, w .. "clavicle", "shoulder", S, "long", 1, "shoulder" .. k, "sternum")
	Bone("scapula" .. k, w .. "scapula", "shoulder", S, "flat", 1, "shoulder" .. k, "clavicle" .. k)
	Bone("humerus" .. k, w .. "humerus", "arm", S, "long", 1, "arm" .. k, "scapula" .. k)
	Bone("radius" .. k, w .. "radius", "forearm", S, "long", 1, "forearm" .. k, "humerus" .. k)
	Bone("ulna" .. k, w .. "ulna", "forearm", S, "long", 1, "forearm" .. k, "humerus" .. k)
	for _, c in ipairs({ { "scaphoid", "radius" }, { "lunate", "radius" }, { "triquetrum", "radius" }, { "pisiform", "triquetrum" },
		{ "trapezium", "scaphoid" }, { "trapezoid", "scaphoid" }, { "capitate", "lunate" }, { "hamate", "triquetrum" } }) do
		Bone(c[1] .. k, w .. c[1], "hand", S, "short", 3, "carpus" .. k, c[2] .. k)
	end
	local CARPAL = { "trapezium", "trapezoid", "capitate", "hamate", "hamate" }
	for i = 1, 5 do Bone("mc" .. i .. k, w .. DIGIT[i] .. " metacarpal", "hand", S, "long", 2, "metacarpus" .. k, CARPAL[i] .. k) end
	-- phalanges of the hand: proximal 1..5, middle 2..5, distal 1..5 (the thumb has no middle one)
	for i = 1, 5 do Bone("hpp" .. i .. k, w .. "proximal phalanx of the " .. DIGIT[i] .. " finger", "hand", S, "long", 2, "fingers" .. k, "mc" .. i .. k) end
	for i = 2, 5 do Bone("hmp" .. i .. k, w .. "middle phalanx of the " .. DIGIT[i] .. " finger", "hand", S, "long", 2, "fingers" .. k, "hpp" .. i .. k) end
	for i = 1, 5 do Bone("hdp" .. i .. k, w .. "distal phalanx of the " .. DIGIT[i] .. " finger", "hand", S, "long", 2, "fingers" .. k, (i == 1 and "hpp" or "hmp") .. i .. k) end
end
for _, s in ipairs({ { "_l", "left ", "L" }, { "_r", "right ", "R" } }) do
	local k, w, S = s[1], s[2], s[3]
	Bone("hip" .. k, w .. "hip bone", "pelvis", S, "irregular", 1, "girdle" .. k, "sacrum")
	Bone("femur" .. k, w .. "femur", "thigh", S, "long", 1, "thigh" .. k, "hip" .. k)
	Bone("patella" .. k, w .. "patella", "thigh", S, "sesamoid", 2, "thigh" .. k, "femur" .. k)
	Bone("tibia" .. k, w .. "tibia", "leg", S, "long", 1, "leg" .. k, "femur" .. k)
	Bone("fibula" .. k, w .. "fibula", "leg", S, "long", 1, "leg" .. k, "tibia" .. k)
	for _, c in ipairs({ { "calcaneus", "calcaneus", "talus" }, { "talus", "talus", "tibia" }, { "navicular", "navicular bone", "talus" }, { "cuboid", "cuboid bone", "calcaneus" },
		{ "cuneiform_med", "medial cuneiform bone", "navicular" }, { "cuneiform_int", "intermediate cuneiform bone", "navicular" }, { "cuneiform_lat", "lateral cuneiform bone", "navicular" } }) do
		Bone(c[1] .. k, w .. c[2], "foot", S, "short", 2, "tarsus" .. k, c[3] .. k)
	end
	local TARSAL = { "cuneiform_med", "cuneiform_int", "cuneiform_lat", "cuboid", "cuboid" }
	for i = 1, 5 do Bone("mt" .. i .. k, w .. DIGIT[i] .. " metatarsal", "foot", S, "long", 2, "metatarsus" .. k, TARSAL[i] .. k) end
	for i = 1, 5 do Bone("fpp" .. i .. k, w .. "proximal phalanx of the " .. DIGIT[i] .. " toe", "foot", S, "long", 3, "toes" .. k, "mt" .. i .. k) end
	for i = 2, 5 do Bone("fmp" .. i .. k, w .. "middle phalanx of the " .. DIGIT[i] .. " toe", "foot", S, "long", 3, "toes" .. k, "fpp" .. i .. k) end
	for i = 1, 5 do Bone("fdp" .. i .. k, w .. "distal phalanx of the " .. DIGIT[i] .. " toe", "foot", S, "long", 3, "toes" .. k, (i == 1 and "fpp" or "fmp") .. i .. k) end
end

SK.BoneByIdx = {}
for _, b in ipairs(SK.BoneList) do
	SK.BoneByIdx[b.idx] = b
	if b.side ~= "M" then b.mirror = string.sub(b.id, 1, -2) .. (b.side == "L" and "r" or "l") end
end
SK.BONES = #SK.BoneList

------------------------------------------------------------------------------------------
-- Joints
------------------------------------------------------------------------------------------
local function Joint(id, name, kind, bones, rig, serves)
	local j = { id = id, name = name, type = kind, bones = bones, rig = rig, serves = serves }
	SK.Joints[id] = j
	SK.JointList[#SK.JointList + 1] = j
	return j
end
local function Each(fn) fn("_l", "left ") fn("_r", "right ") end

-- the skull
Joint("suture_coronal", "coronal suture", "suture", { "frontal", "parietal_l", "parietal_r" })
Joint("suture_sagittal", "sagittal suture", "suture", { "parietal_l", "parietal_r" })
Joint("suture_lambdoid", "lambdoid suture", "suture", { "occipital", "parietal_l", "parietal_r" })
Joint("suture_frontonasal", "frontonasal suture", "suture", { "frontal", "nasal_l", "nasal_r" })
Joint("suture_internasal", "internasal suture", "suture", { "nasal_l", "nasal_r" })
Joint("suture_intermaxillary", "intermaxillary suture", "suture", { "maxilla_l", "maxilla_r" })
Joint("sutures_sphenoid", "sutures of the sphenoid bone", "suture", { "sphenoid", "frontal", "parietal_l", "parietal_r", "temporal_l", "temporal_r", "occipital", "ethmoid", "zygomatic_l", "zygomatic_r", "palatine_l", "palatine_r", "vomer" })
Joint("sutures_ethmoid", "sutures of the ethmoid bone", "suture", { "ethmoid", "frontal", "nasal_l", "nasal_r", "lacrimal_l", "lacrimal_r", "maxilla_l", "maxilla_r", "concha_inf_l", "concha_inf_r", "palatine_l", "palatine_r", "vomer" })
Joint("sutures_vomer", "sutures of the vomer", "suture", { "vomer", "maxilla_l", "maxilla_r", "palatine_l", "palatine_r" })
Joint("suture_palatine", "median palatine suture", "suture", { "palatine_l", "palatine_r" })
Each(function(k, w)
	Joint("suture_squamous" .. k, w .. "squamous suture", "suture", { "temporal" .. k, "parietal" .. k })
	Joint("suture_occipitomastoid" .. k, w .. "occipitomastoid suture", "suture", { "occipital", "temporal" .. k })
	Joint("suture_frontozygomatic" .. k, w .. "frontozygomatic suture", "suture", { "frontal", "zygomatic" .. k })
	Joint("suture_zygomaticotemporal" .. k, w .. "zygomaticotemporal suture", "suture", { "zygomatic" .. k, "temporal" .. k })
	Joint("sutures_maxilla" .. k, "sutures of the " .. w .. "maxilla", "suture", { "maxilla" .. k, "frontal", "zygomatic" .. k, "nasal" .. k, "lacrimal" .. k, "palatine" .. k, "concha_inf" .. k })
	Joint("tmj" .. k, w .. "temporomandibular joint", "condylar", { "temporal" .. k, "mandible" }, nil, "jaw")
	Joint("tympanic" .. k, w .. "fastenings of the ossicles", "syndesmosis", { "temporal" .. k, "malleus" .. k, "stapes" .. k })
	Joint("incudomalleolar" .. k, w .. "incudomalleolar joint", "saddle", { "malleus" .. k, "incus" .. k })
	Joint("incudostapedial" .. k, w .. "incudostapedial joint", "ball", { "incus" .. k, "stapes" .. k })
end)
-- the column
Joint("atlantooccipital", "atlanto-occipital joint", "condylar", { "occipital", "c1" }, { "neck", "head" }, "neck")
Joint("atlantoaxial", "atlanto-axial joint", "pivot", { "c1", "c2" }, nil, "neck")
do
	local order = {}
	for n = 2, 7 do order[#order + 1] = "c" .. n end
	for n = 1, 12 do order[#order + 1] = "t" .. n end
	for n = 1, 5 do order[#order + 1] = "l" .. n end
	order[#order + 1] = "sacrum"
	for i = 1, #order - 1 do
		local a, b = order[i], order[i + 1]
		local serves = string.sub(a, 1, 1) == "c" and "neck" or "spine"
		Joint("iv_" .. a .. "_" .. (b == "sacrum" and "s1" or b), "joints between " .. string.upper(a) .. " and " .. (b == "sacrum" and "the sacrum" or string.upper(b)), "intervertebral", { a, b }, nil, serves)
	end
end
Joint("sacrococcygeal", "sacrococcygeal joint", "symphysis", { "sacrum", "coccyx" })
-- the chest
Each(function(k, w)
	for n = 1, 12 do
		local bones = { "rib" .. n .. k, "t" .. n }
		-- (the heads of the second to the ninth rib also touch the vertebra above)
		if n >= 2 and n <= 9 then bones[3] = "t" .. (n - 1) end
		Joint("costovertebral_" .. n .. k, "joints of the " .. w .. ORDINAL[n] .. " rib with the column", "plane", bones, nil, "breathing")
	end
	for n = 1, 7 do Joint("sternocostal_" .. n .. k, "joint of the " .. w .. ORDINAL[n] .. " rib with the sternum (by its cartilage)", "cartilaginous", { "rib" .. n .. k, "sternum" }, nil, "breathing") end
	for n = 8, 10 do Joint("interchondral_" .. n .. k, "cartilage of the " .. w .. ORDINAL[n] .. " rib on that of the rib above", "cartilaginous", { "rib" .. n .. k, "rib" .. (n - 1) .. k }, nil, "breathing") end
end)
-- the limbs
Each(function(k, w)
	Joint("sternoclavicular" .. k, w .. "sternoclavicular joint", "saddle", { "sternum", "clavicle" .. k }, { "spine_top", "clavicle" .. k }, "shoulder" .. k)
	Joint("acromioclavicular" .. k, w .. "acromioclavicular joint", "plane", { "clavicle" .. k, "scapula" .. k }, nil, "shoulder" .. k)
	Joint("glenohumeral" .. k, w .. "shoulder joint", "ball", { "scapula" .. k, "humerus" .. k }, { "clavicle" .. k, "upperarm" .. k }, "shoulder" .. k)
	Joint("elbow" .. k, w .. "elbow joint", "hinge", { "humerus" .. k, "ulna" .. k, "radius" .. k }, { "upperarm" .. k, "forearm" .. k }, "elbow" .. k)
	Joint("radioulnar_prox" .. k, w .. "proximal radioulnar joint", "pivot", { "radius" .. k, "ulna" .. k }, nil, "forearm" .. k)
	Joint("radioulnar_dist" .. k, w .. "distal radioulnar joint", "pivot", { "radius" .. k, "ulna" .. k }, nil, "forearm" .. k)
	Joint("radiocarpal" .. k, w .. "wrist joint", "ellipsoid", { "radius" .. k, "scaphoid" .. k, "lunate" .. k, "triquetrum" .. k }, { "forearm" .. k, "hand" .. k }, "wrist" .. k)
	Joint("intercarpal" .. k, w .. "joints between the carpal bones", "plane", { "scaphoid" .. k, "lunate" .. k, "triquetrum" .. k, "pisiform" .. k, "trapezium" .. k, "trapezoid" .. k, "capitate" .. k, "hamate" .. k }, nil, "wrist" .. k)
	local CARPAL = { "trapezium", "trapezoid", "capitate", "hamate", "hamate" }
	for i = 1, 5 do
		local f = i - 1     -- the rig's finger: 0 thumb .. 4 little
		Joint("cmc" .. i .. k, w .. DIGIT[i] .. " carpometacarpal joint", i == 1 and "saddle" or "plane", { CARPAL[i] .. k, "mc" .. i .. k }, i == 1 and { "hand" .. k, "f0a" .. k } or nil, "hand" .. k)
		if i == 1 then
			Joint("mcp1" .. k, w .. "first metacarpophalangeal joint", "condylar", { "mc1" .. k, "hpp1" .. k }, { "f0a" .. k, "f0b" .. k }, "hand" .. k)
			Joint("thumb_ip" .. k, w .. "interphalangeal joint of the thumb", "hinge", { "hpp1" .. k, "hdp1" .. k }, { "f0b" .. k, "f0c" .. k }, "hand" .. k)
		else
			Joint("mcp" .. i .. k, w .. DIGIT[i] .. " metacarpophalangeal joint", "condylar", { "mc" .. i .. k, "hpp" .. i .. k }, { "hand" .. k, "f" .. f .. "a" .. k }, "hand" .. k)
			Joint("hpip" .. i .. k, w .. "proximal interphalangeal joint of the " .. DIGIT[i] .. " finger", "hinge", { "hpp" .. i .. k, "hmp" .. i .. k }, { "f" .. f .. "a" .. k, "f" .. f .. "b" .. k }, "hand" .. k)
			Joint("hdip" .. i .. k, w .. "distal interphalangeal joint of the " .. DIGIT[i] .. " finger", "hinge", { "hmp" .. i .. k, "hdp" .. i .. k }, { "f" .. f .. "b" .. k, "f" .. f .. "c" .. k }, "hand" .. k)
		end
	end
	Joint("intermetacarpal" .. k, w .. "joints between the bases of the metacarpals", "plane", { "mc2" .. k, "mc3" .. k, "mc4" .. k, "mc5" .. k }, nil, "hand" .. k)

	Joint("sacroiliac" .. k, w .. "sacroiliac joint", "plane", { "sacrum", "hip" .. k }, nil, "spine")
	Joint("coxofemoral" .. k, w .. "hip joint", "ball", { "hip" .. k, "femur" .. k }, { "pelvis", "thigh" .. k }, "hip" .. k)
	Joint("knee" .. k, w .. "knee joint", "hinge", { "femur" .. k, "tibia" .. k, "patella" .. k }, { "thigh" .. k, "calf" .. k }, "knee" .. k)
	Joint("tibiofibular_prox" .. k, w .. "proximal tibiofibular joint", "plane", { "tibia" .. k, "fibula" .. k }, nil, "ankle" .. k)
	Joint("tibiofibular_dist" .. k, w .. "distal tibiofibular joint", "syndesmosis", { "tibia" .. k, "fibula" .. k }, nil, "ankle" .. k)
	Joint("talocrural" .. k, w .. "ankle joint", "hinge", { "tibia" .. k, "fibula" .. k, "talus" .. k }, { "calf" .. k, "foot" .. k }, "ankle" .. k)
	Joint("subtalar" .. k, w .. "subtalar joint", "plane", { "talus" .. k, "calcaneus" .. k }, nil, "foot" .. k)
	Joint("midtarsal" .. k, w .. "transverse tarsal joint", "plane", { "talus" .. k, "navicular" .. k, "calcaneus" .. k, "cuboid" .. k }, nil, "foot" .. k)
	Joint("intertarsal" .. k, w .. "joints between navicular, cuneiform and cuboid bones", "plane", { "navicular" .. k, "cuneiform_med" .. k, "cuneiform_int" .. k, "cuneiform_lat" .. k, "cuboid" .. k }, nil, "foot" .. k)
	local TARSAL = { "cuneiform_med", "cuneiform_int", "cuneiform_lat", "cuboid", "cuboid" }
	for i = 1, 5 do
		Joint("tmt" .. i .. k, w .. DIGIT[i] .. " tarsometatarsal joint", "plane", { TARSAL[i] .. k, "mt" .. i .. k }, nil, "foot" .. k)
		Joint("mtp" .. i .. k, w .. DIGIT[i] .. " metatarsophalangeal joint", "condylar", { "mt" .. i .. k, "fpp" .. i .. k }, { "foot" .. k, "toe" .. k }, "foot" .. k)
		if i == 1 then
			Joint("fip1" .. k, w .. "interphalangeal joint of the great toe", "hinge", { "fpp1" .. k, "fdp1" .. k }, nil, "foot" .. k)
		else
			Joint("fpip" .. i .. k, w .. "proximal interphalangeal joint of the " .. DIGIT[i] .. " toe", "hinge", { "fpp" .. i .. k, "fmp" .. i .. k }, nil, "foot" .. k)
			Joint("fdip" .. i .. k, w .. "distal interphalangeal joint of the " .. DIGIT[i] .. " toe", "hinge", { "fmp" .. i .. k, "fdp" .. i .. k }, nil, "foot" .. k)
		end
	end
end)
Joint("pubic_symphysis", "pubic symphysis", "symphysis", { "hip_l", "hip_r" }, nil, "spine")

for _, j in ipairs(SK.JointList) do
	for _, id in ipairs(j.bones) do
		local b = SK.Bones[id]
		if b then b.joints[#b.joints + 1] = j.id end
	end
end

------------------------------------------------------------------------------------------
-- Structures that cut across the tree
------------------------------------------------------------------------------------------
do
	local function Of(...)
		local out = {}
		for _, g in ipairs({ ... }) do
			if SK.Bones[g] then out[#out + 1] = g
			else for _, id in ipairs(SK.Groups[g].bones) do out[#out + 1] = id end end
		end
		return out
	end
	SK.Sets.pelvis = { name = "pelvis", bones = Of("girdle_l", "girdle_r", "sacral") }
	SK.Sets.rib_cage = { name = "rib cage", bones = Of("thoracic", "ribs_l", "ribs_r", "sternum") }
	SK.Sets.neurocranium = { name = "braincase", bones = Of("cranium") }
	SK.Sets.orbit_l = { name = "left orbit", bones = { "frontal", "sphenoid", "ethmoid", "zygomatic_l", "maxilla_l", "lacrimal_l", "palatine_l" } }
	SK.Sets.orbit_r = { name = "right orbit", bones = { "frontal", "sphenoid", "ethmoid", "zygomatic_r", "maxilla_r", "lacrimal_r", "palatine_r" } }
end

------------------------------------------------------------------------------------------
-- Asking
------------------------------------------------------------------------------------------
-- A bone by its id or its number.
function SK.Bone(key)
	if type(key) == "number" then return SK.BoneByIdx[key] end
	return SK.Bones[key]
end

-- Every bone of a group and of the groups in it, or of a set: a list of ids.
function SK.BonesOf(name, out)
	out = out or {}
	local set = SK.Sets[name]
	if set then for _, id in ipairs(set.bones) do out[#out + 1] = id end return out end
	local g = SK.Groups[name]
	if not g then return out end
	for _, id in ipairs(g.bones) do out[#out + 1] = id end
	for _, kid in ipairs(g.kids) do SK.BonesOf(kid, out) end
	return out
end

-- The structures a bone is part of, from its own group up: a list of group ids.
function SK.PartOf(id)
	local b = SK.Bones[id]
	local out = {}
	local g = b and SK.Groups[b.group]
	while g do out[#out + 1] = g.id g = g.parent and SK.Groups[g.parent] end
	return out
end

-- The bones a bone articulates with: { [id] = the id of a joint they share }.
function SK.Neighbours(id)
	local b = SK.Bones[id]
	local out = {}
	if not b then return out end
	for _, jid in ipairs(b.joints) do
		for _, other in ipairs(SK.Joints[jid].bones) do
			if other ~= id and not out[other] then out[other] = jid end
		end
	end
	return out
end

-- What lies beyond a bone: every bone whose way toward the trunk passes through it. A list of ids.
local distal
function SK.Distal(id)
	if not distal then
		distal = {}
		for _, b in ipairs(SK.BoneList) do
			local p, guard = b.proximal, 0
			while p and guard < 64 do
				distal[p] = distal[p] or {}
				distal[p][#distal[p] + 1] = b.id
				p = SK.Bones[p] and SK.Bones[p].proximal
				guard = guard + 1
			end
		end
	end
	return distal[id] or {}
end

-- The joints of the rig that move a bone: { joint id = { parent key, child key } }.
function SK.RigJointsOf(id)
	local b = SK.Bones[id]
	local out = {}
	if not b then return out end
	for _, jid in ipairs(b.joints) do
		local j = SK.Joints[jid]
		if j.rig then out[jid] = j.rig end
	end
	return out
end

-- What the list of ids adds up to (see SK.REGISTRY_SUM).
function SK.Sum()
	local h = 7
	for _, b in ipairs(SK.BoneList) do
		local s = b.idx .. ":" .. b.id .. ";"
		for i = 1, #s do h = (h * 31 + string.byte(s, i)) % 4294967296 end
	end
	return h
end

-- The registry looked over: a list of what is wrong with it (empty: nothing).
function SK.Check()
	local bad = {}
	local function Bad(fmt, ...) bad[#bad + 1] = string.format(fmt, ...) end
	if #SK.BoneList ~= 206 then Bad("%d bones, not 206", #SK.BoneList) end
	local seen = {}
	for i, b in ipairs(SK.BoneList) do
		if b.idx ~= i - 1 then Bad("%s has number %d at place %d", b.id, b.idx, i) end
		if seen[b.id] then Bad("the id %s twice", b.id) end
		seen[b.id] = true
		if b.id ~= string.lower(b.id) or string.find(b.id, "[^a-z0-9_]") then Bad("the id %s is not lower-case letters, digits and _", b.id) end
		if not SK.Groups[b.group] then Bad("%s: no group %s", b.id, tostring(b.group)) end
		if b.proximal and not SK.Bones[b.proximal] then Bad("%s: hangs on %s, which is no bone", b.id, b.proximal) end
		if b.side ~= "M" and not (b.mirror and SK.Bones[b.mirror] and SK.Bones[b.mirror].mirror == b.id) then Bad("%s: no mirror bone", b.id) end
		if #b.joints == 0 and b.id ~= "hyoid" then Bad("%s takes part in no joint", b.id) end
		-- the way toward the trunk ends
		local p, n = b.proximal, 0
		while p and n < 80 do p = SK.Bones[p] and SK.Bones[p].proximal n = n + 1 end
		if n >= 80 then Bad("%s: its way toward the trunk never ends", b.id) end
	end
	for _, j in ipairs(SK.JointList) do
		if #j.bones < 2 then Bad("joint %s has fewer than two bones", j.id) end
		for _, id in ipairs(j.bones) do
			if not SK.Bones[id] then Bad("joint %s names %s, which is no bone", j.id, tostring(id)) end
		end
	end
	for _, g in pairs(SK.Groups) do
		if g.parent and not SK.Groups[g.parent] then Bad("group %s: no parent %s", g.id, g.parent) end
	end
	if #SK.BonesOf("skeleton") ~= #SK.BoneList then Bad("the tree of structures holds %d bones of %d", #SK.BonesOf("skeleton"), #SK.BoneList) end
	-- every bone but the hyoid can be reached from every other over joints
	do
		local reached, queue, n = { sacrum = true }, { "sacrum" }, 1
		while #queue > 0 do
			local id = table.remove(queue)
			for other in pairs(SK.Neighbours(id)) do
				if not reached[other] then reached[other] = true n = n + 1 queue[#queue + 1] = other end
			end
		end
		if n ~= #SK.BoneList - 1 then
			local missing = {}
			for _, b in ipairs(SK.BoneList) do if not reached[b.id] and b.id ~= "hyoid" then missing[#missing + 1] = b.id end end
			Bad("not joined to the rest by any joint: %s", table.concat(missing, ", "))
		end
	end
	local sum = SK.Sum()
	if sum ~= SK.REGISTRY_SUM then Bad("the list of bones adds up to %d, not %d: a bone was taken out, renamed or moved", sum, SK.REGISTRY_SUM) end
	return bad
end
