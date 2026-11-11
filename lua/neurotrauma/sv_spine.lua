-- The spinal cord: what reaches the body below the brain.
--
-- The chain of a voluntary movement in this module ran from the motor cortex to the pyramid
-- (sh_atlas.lua). Below the pyramid the fibres run down the cord on the side of the limb they move
-- and leave it at the level of that limb: the arm at the neck, the leg at the lower back [P:
-- standard anatomy]. The cord is kept as three levels of two halves each, as tracts of the atlas
-- (L_cord_cervical ... R_cord_lumbar), and the channels of the limbs, the trunk and breathing pass
-- through them.
--
-- Z-City already has a spine: three organs (spine3 the neck, spine2 the upper spine, spine1 the
-- lower spine), each a number from 0 to 1, and one rule each. At a set value (hg.organism.
-- fake_spine1 / 2 / 3) the spine is "broken": the character is dropped, cannot get up and, for
-- the upper two, cannot move. Below that value the number does nothing but hurt.
--
-- This file does not keep a second spine. It reads Z-City's three numbers and turns them into how
-- much each level still conducts:
--
--   up to a quarter of the "broken" value   the bone is hurt, the cord conducts in full
--   from there to the "broken" value        conduction falls to nothing, in a straight line [G]
--   at the "broken" value and above         nothing, and Z-City's own rule applies as before
--
-- so that a character whose lower spine is half way to broken has weak legs, walks slowly and
-- cannot run, instead of nothing at all until the last blow. A bullet that passed to one side of
-- the middle takes more of that half [G]. Nothing is ever written to Z-City's organs: what the
-- module does with the cord it does through its own channels (the limb outputs of sv_brain.lua).
--
-- Breathing: the diaphragm is driven from the neck [P]. Z-City's own words for a broken neck are
-- "I can barely even breathe", and its lungs go on working; the module leaves half of the
-- breathing with the cervical cord cut [G], which shows as irregular breathing, not as none.
--
-- A character with a hurt spine and an uninjured head gets a neurological record, as one with a
-- stopped heart does (sv_cardioresp.lua): the limb outputs live there.

local NT = NeuroTrauma
NT.Spine = NT.Spine or {}
local SP = NT.Spine
local A, C, Z = NT.Atlas, NT.Config, NT.ZC
local AN = NT.Anatomy
local CS = C.Spine
local Clamp, floor = math.Clamp, math.floor

-- the levels from the top: the tract of each half, and Z-City's organ for the level
local LEVELS = {}
for i, lv in ipairs({ { "cervical", "spine3" }, { "thoracic", "spine2" }, { "lumbar", "spine1" } }) do
	LEVELS[i] = { key = lv[1], field = lv[2], L = A.tractOf["L_cord_" .. lv[1]], R = A.tractOf["R_cord_" .. lv[1]] }
end
SP.levels = LEVELS
local LEVEL_OF = { spine3 = 1, spine2 = 2, spine1 = 3 }

-- the value of an organ at which Z-City itself calls the spine broken
local function Broken(field)
	local v = istable(hg) and istable(hg.organism) and tonumber(hg.organism["fake_" .. field])
	return (v and v > 0) and v or 1
end

-- How much of a level's conduction a value of Z-City's organ takes.
function SP.Loss(field, value)
	local x = (tonumber(value) or 0) / Broken(field)
	return Clamp((x - CS.from) / (1 - CS.from), 0, 1)
end

-- Is anything of this organism's cord lost?
function SP.Hurt(org)
	for i = 1, 3 do
		if SP.Loss(LEVELS[i].field, org[LEVELS[i].field]) > 0.001 then return true end
	end
	return false
end

-- On which side of the middle the last bullet met each level, per organism, until a record takes
-- it over: > 0 the left half.
local pending = setmetatable({}, { __mode = "k" })

-- Called with every step of a record: Z-City's spine as what the cord's tracts have lost. The map
-- is replaced only when it differs (a new map is a new working-out of every channel).
function SP.Refresh(st, org)
	local an = st.an
	local bias = st.cordBias
	local pend = pending[org]
	if pend then
		bias = bias or {}
		for i, b in pairs(pend) do bias[i] = b end
		st.cordBias = bias
		pending[org] = nil
	end
	local map, key = nil, 0
	for i = 1, 3 do
		local lv = LEVELS[i]
		local loss = SP.Loss(lv.field, org[lv.field])
		if loss > 0.001 then
			map = map or {}
			-- (the half the bullet passed through loses more, the other less; both nothing when
			-- nothing is lost and all when all is)
			local b = bias and bias[i] or 0
			local l, r = loss ^ (1 - CS.sideShare * b), loss ^ (1 + CS.sideShare * b)
			map[lv.L], map[lv.R] = l, r
			key = key + (floor(l * 20 + 0.5) * 31 + floor(r * 20 + 0.5)) * (i * 977)
		end
	end
	if key ~= (an.cordKey or 0) then
		an.cordKey = key
		AN.Suppress(st, "spine", nil, map)
		st.quiet = false
		NT.States.Push(st, org.owner, "spinal cord: " .. SP.Describe(st, map))
	end
	-- (the record is kept for as long as the cord is not whole: by Z-City's organs, or by damage
	-- the module itself holds for it)
	local own = false
	for i = 1, 3 do
		if (an.td[LEVELS[i].L] or 0) > 0.02 or (an.td[LEVELS[i].R] or 0) > 0.02 then own = true break end
	end
	st.cordHurt = map ~= nil or own
end

-- What a half of a level still conducts, 0..1 (side "L" or "R").
function SP.Conduction(st, level, side)
	local an = st.an
	local id = LEVELS[level][side]
	return (1 - (an.td[id] or 0)) * (1 - (an.ts[id] or 0))
end

function SP.Describe(st, map)
	local parts = {}
	for i = 1, 3 do
		local lv = LEVELS[i]
		local l, r = map and map[lv.L] or 0, map and map[lv.R] or 0
		if l > 0 or r > 0 then parts[#parts + 1] = string.format("%s conducts %.0f%% left, %.0f%% right", lv.key, (1 - l) * 100, (1 - r) * 100) end
	end
	return #parts > 0 and table.concat(parts, "; ") or "whole again"
end

-- The share of breathing the cord leaves: the cervical level, both halves.
function SP.Breath(st)
	if not st.cordHurt then return 1 end
	local c = (SP.Conduction(st, 1, "L") + SP.Conduction(st, 1, "R")) * 0.5
	return CS.breathFloor + (1 - CS.breathFloor) * c
end

------------------------------------------------------------------------------------------
-- A bullet through a spine organ: on which side of the middle. Z-City calls this for every organ
-- box a bullet meets, before its own input for the box runs.
------------------------------------------------------------------------------------------
local B = "ValveBiped.Bip01_"
hook.Add("PreTraceOrganBulletDamage", "NT_Spine", function(org, bone, dmg, dmgInfo, box, dir, hit, ricochet, organ)
	if not NT.Enabled() or not istable(org) or not istable(organ) then return end
	local level = LEVEL_OF[organ[1]]
	if not level or not isvector(hit) then return end
	local owner = org.owner
	if not IsValid(owner) then return end
	local body = Z.Body(owner)
	if not IsValid(body) then return end
	-- the body's left, from its shoulders (the same for a standing body and for one that lies)
	local lb, rb = body:LookupBone(B .. "L_UpperArm"), body:LookupBone(B .. "R_UpperArm")
	local sb = body:LookupBone(level == 1 and (B .. "Neck1") or (level == 2 and (B .. "Spine2") or (B .. "Pelvis")))
	local lm, rm, sm = lb and body:GetBoneMatrix(lb), rb and body:GetBoneMatrix(rb), sb and body:GetBoneMatrix(sb)
	if not (lm and rm and sm) then return end
	local left = lm:GetTranslation() - rm:GetTranslation()
	if left:LengthSqr() < 1 then return end
	left:Normalize()
	local off = (hit - sm:GetTranslation()):Dot(left)
	local b = Clamp(off / CS.sideReach, -1, 1)
	local p = pending[org]
	if not p then p = {} pending[org] = p end
	p[level] = b
	if NT.TestLog then NT.TestLog("  spine: a bullet meets the %s level %.1f units to the %s of the middle", LEVELS[level].key, math.abs(off), off >= 0 and "left" or "right") end
end)

------------------------------------------------------------------------------------------
-- A hurt cord in a character without a record: it gets one. Twice a second over the players, three
-- fields each.
------------------------------------------------------------------------------------------
timer.Create("NT_SpineWatch", 0.5, 0, function()
	if not NT.Enabled() then return end
	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		if istable(org) and ply:Alive() and org.alive ~= false and not NT.Get(org) and SP.Hurt(org) then
			NT.Brain.Ensure(org)
		end
	end
end)
