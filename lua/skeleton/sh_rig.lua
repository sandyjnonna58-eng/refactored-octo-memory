-- The rig: which animation bone of a player model carries what. The only file of the module in
-- which the name of an engine bone stands.
--
-- The registry's bones hang on rig keys ("thigh_l", "spine_up": sh_stock.lua says which); a profile
-- says under what names a family of models has those keys; resolving a model finds the numbers of
-- its bones for them, once, and what to do where a bone is missing:
--   a key the model lacks and can stand in for (a toe: the foot; a finger joint: the joint before
--   it, at last the hand) is carried by the stand-in and marked so;
--   a model that lacks one of the bones a body cannot do without gets no skeleton at all.
-- Models that are named explicitly (R.Overrides) are taken at their word instead of being looked at.

local SK = HemoSkeleton
SK.Rig = SK.Rig or {}
local R = SK.Rig

local B = "ValveBiped.Bip01_"

-- Every key the module knows, in a fixed order.
R.KEYS = { "pelvis", "spine_low", "spine_mid", "spine_up", "spine_top", "neck", "head" }
for _, s in ipairs({ "l", "r" }) do
	for _, k in ipairs({ "clavicle", "upperarm", "forearm", "hand", "thigh", "calf", "foot", "toe" }) do R.KEYS[#R.KEYS + 1] = k .. "_" .. s end
	for f = 0, 4 do for _, j in ipairs({ "a", "b", "c" }) do R.KEYS[#R.KEYS + 1] = "f" .. f .. j .. "_" .. s end end
end

-- The rig of Valve's two-legged characters, which Z-City's models and the stock skeleton have.
-- names: the names a key may go by, the first found is taken.
local function ValveBiped()
	local names = {
		pelvis = { B .. "Pelvis" }, spine_low = { B .. "Spine" }, spine_mid = { B .. "Spine1" }, spine_up = { B .. "Spine2" }, spine_top = { B .. "Spine4" },
		neck = { B .. "Neck1" }, head = { B .. "Head1" },
	}
	-- what stands in for a key the model has not
	local standin = { spine_low = "pelvis", spine_mid = "spine_up", spine_top = "spine_up", neck = "spine_top" }
	for _, s in ipairs({ { "l", "L" }, { "r", "R" } }) do
		local k, S = "_" .. s[1], s[2] .. "_"
		names["clavicle" .. k] = { B .. S .. "Clavicle" }
		names["upperarm" .. k] = { B .. S .. "UpperArm" }
		names["forearm" .. k] = { B .. S .. "Forearm" }
		names["hand" .. k] = { B .. S .. "Hand" }
		names["thigh" .. k] = { B .. S .. "Thigh" }
		names["calf" .. k] = { B .. S .. "Calf" }
		names["foot" .. k] = { B .. S .. "Foot" }
		names["toe" .. k] = { B .. S .. "Toe0" }
		standin["clavicle" .. k] = "spine_top"
		standin["hand" .. k] = "forearm" .. k
		standin["foot" .. k] = "calf" .. k
		standin["toe" .. k] = "foot" .. k
		for f = 0, 4 do
			names["f" .. f .. "a" .. k] = { B .. S .. "Finger" .. f }
			names["f" .. f .. "b" .. k] = { B .. S .. "Finger" .. f .. "1" }
			names["f" .. f .. "c" .. k] = { B .. S .. "Finger" .. f .. "2" }
			standin["f" .. f .. "a" .. k] = "hand" .. k
			standin["f" .. f .. "b" .. k] = "f" .. f .. "a" .. k
			standin["f" .. f .. "c" .. k] = "f" .. f .. "b" .. k
		end
	end
	return {
		id = "valvebiped", names = names, standin = standin,
		-- a body is not a body without these
		needs = { "pelvis", "spine_up", "head", "upperarm_l", "upperarm_r", "forearm_l", "forearm_r", "thigh_l", "thigh_r", "calf_l", "calf_r" },
	}
end
R.profiles = { ValveBiped() }

-- Models taken at their word: { pattern (a plain piece of the model's path, lower case), rig = id of
-- a profile | false (no skeleton on this model, whatever its bones), names = { key = bone name } (in
-- place of the profile's) }. The first that fits is taken.
R.Overrides = R.Overrides or {}

-- A model's bones looked up for a profile. lookup(name) -> the bone's number or nil.
local function Try(profile, lookup, over)
	local bone, via, missing, standins = {}, {}, {}, 0
	for _, key in ipairs(R.KEYS) do
		local names = over and over.names and over.names[key] and { over.names[key] } or profile.names[key]
		for _, name in ipairs(names or {}) do
			local idx = lookup(name)
			if idx and idx >= 0 then bone[key] = idx break end
		end
	end
	for _, need in ipairs(profile.needs) do
		if not bone[need] then return nil, need end
	end
	for _, key in ipairs(R.KEYS) do
		if not bone[key] then
			-- the stand-in's stand-in, as far as it goes
			local s, guard = profile.standin[key], 0
			while s and not bone[s] and guard < 8 do s = profile.standin[s] guard = guard + 1 end
			if s and bone[s] then
				via[key] = s
				standins = standins + 1
			else
				missing[#missing + 1] = key
			end
		end
	end
	return { rig = profile.id, bone = bone, via = via, missing = missing, standins = standins, ok = true }
end

-- Resolves a model by its path and a way of looking up its bones. Returns the profile it fits as
-- { model, rig, bone = { key = number }, via = { key = the key that stands in for it }, missing,
-- standins, ok } or { model, ok = false, why }.
function R.ResolveWith(model, lookup)
	model = string.lower(model or "")
	local over
	for _, o in ipairs(R.Overrides) do
		if string.find(model, o.pattern, 1, true) then over = o break end
	end
	if over and over.rig == false then return { model = model, ok = false, why = "named as a model without a skeleton" } end
	local lacking
	for _, profile in ipairs(R.profiles) do
		if not over or not over.rig or over.rig == profile.id then
			local res, need = Try(profile, lookup, over)
			if res then
				res.model = model
				res.named = over ~= nil
				return res
			end
			lacking = lacking or (profile.names[need] and profile.names[need][1]) or need
		end
	end
	return { model = model, ok = false, why = "it has no bone " .. tostring(lacking) }
end

local cache = {}
R.cache = cache

-- The profile of an entity's model (kept by model). nil while the entity's bones cannot be asked for.
function R.Resolve(ent)
	local model = ent:GetModel()
	if not model then return nil end
	local c = cache[model]
	if c then return c end
	local n = ent:GetBoneCount()
	if not n or n < 1 then return nil end
	-- (a model whose bones have not been set up yet answers every name with nothing: asked again later)
	local probe = ent:GetBoneName(0)
	if not probe or probe == "__INVALIDBONE__" then return nil end
	if n == 1 then
		c = { model = string.lower(model), ok = false, why = "it has one bone: not a body" }
		cache[model] = c
		return c
	end
	-- On the server the engine works out only the bones that hit boxes hang on, and the bones those
	-- hang on in turn; the others (the fingers, on most models the toes) have no place there that means
	-- anything. A key on such a bone is carried by its stand-in on the server (a finger joint by the
	-- hand, as it lies in the rest pose): found in the game, where the server had a finger bone 30
	-- units from where the client had it.
	local trusted
	if SERVER then
		trusted = {}
		for set = 0, math.max((ent:GetHitboxSetCount() or 1) - 1, 0) do
			for hb = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
				local b = ent:GetHitBoxBone(hb, set)
				local guard = 0
				while b and b >= 0 and not trusted[b] and guard < 64 do
					trusted[b] = true
					b = ent:GetBoneParent(b)
					guard = guard + 1
				end
			end
		end
		if next(trusted) == nil then trusted = nil end
	end
	c = R.ResolveWith(model, function(name)
		local b = ent:LookupBone(name)
		if b and trusted and not trusted[b] then return nil end
		return b
	end)
	c.serverSide = trusted ~= nil or nil
	cache[model] = c
	return c
end

function R.Forget() for k in pairs(cache) do cache[k] = nil end end

-- The engine bone that carries a key on a resolved model, and the key that really does (itself, or
-- its stand-in). nil: nothing does.
function R.BoneOf(prof, key)
	-- (a key that is a part of a bone's load, the lower jaw or a pair of ribs: that bone)
	local host = SK.Stock and SK.Stock.parts and SK.Stock.parts[key]
	if host then key = host end
	local b = prof.bone[key]
	if b then return b, key end
	local s = prof.via[key]
	if s then return prof.bone[s], s end
	return nil
end

-- A resolved model in words (for the developer).
function R.Describe(prof)
	if not prof then return { "not resolved yet" } end
	if not prof.ok then return { string.format("%s: no skeleton (%s)", prof.model, tostring(prof.why)) } end
	local n = 0
	for _ in pairs(prof.bone) do n = n + 1 end
	local out = { string.format("%s: rig %s%s, %d of %d keys on bones of their own, %d on a stand-in, %d carried by nothing", prof.model, prof.rig, prof.named and " (named explicitly)" or "", n, #R.KEYS, prof.standins, #prof.missing) }
	local via = {}
	for _, key in ipairs(R.KEYS) do if prof.via[key] then via[#via + 1] = key .. " on " .. prof.via[key] end end
	if #via > 0 then out[#out + 1] = "  stand-ins: " .. table.concat(via, ", ") end
	if #prof.missing > 0 then out[#out + 1] = "  carried by nothing: " .. table.concat(prof.missing, ", ") end
	return out
end
