-- Server: what is known to be wrong with a character's bones and joints. The server alone writes
-- it; clients are told on request (sv_net.lua).
--
-- A record is a statement, not a mechanism: it says which bone, how badly, where along it and what
-- from. Nothing in this module derives a limp, a weakness or a loss of health from it: what an
-- injury does to a character is Z-City's (and the brain module's) to decide, as before.
--
-- Whose it is follows the blood module's wound store (lua/advancedblood/server/sv_woundstore.lua):
-- a living player (for themselves and for the ragdoll they lie in), or a body that is nobody's (a
-- corpse). A player who dies hands the record to the corpse made of them; one who spawns again
-- starts with none; a body that is removed, or a player who leaves, takes its record along.
--
--   rec.bones[idx]   state (C.State), integrity 0..255, site (0..1 along its long axis as the data has
--                    it; nil: not known), at = { side, face, up } (skull bones: the place in the head
--                    frame), flags (C.Flag), t, src ("zcity", "brain", "manual"), cause = { ... }
--   rec.joints[id]   state (C.JointState), t, src
--   rec.regions[key] what Z-City's own number for a region is, when no bone could be named for it
--   rec.ver          counts changes
--
--   SK.Injury.Get(who)               the record of a character (who: a player, a ragdoll, a corpse), or nil
--   SK.Injury.Of(who, id)            one bone's entry, or nil (intact)
--   SK.Injury.Set(who, id, fields, src)   writes it; returns the entry. hook SK_Injury(body, id, entry, was)
--   SK.Injury.SetJoint(who, joint, state, src)
--   SK.Injury.Clear(who, id, src)    one bone, or all (id nil); src: only what came from there
--   SK.Injury.Worst(who, group)      the worst state among the bones of a structure

local SK = HemoSkeleton
local C = SK.Config
SK.Injury = SK.Injury or {}
SK.Records = SK.Records or {}
local I, RC = SK.Injury, SK.Records
local S = C.State

local byChar = {}
RC.byChar = byChar
RC.stats = { set = 0, cleared = 0, handed = 0, dropped = 0 }

local function Log(...) if ABL and ABL.TestLog then ABL.TestLog(...) end end

-- The character an entity is the body of: a living player (for themselves and for the ragdoll they
-- lie in), or the entity itself (a corpse, an NPC, a ragdoll that is nobody's). nil: no character.
local function CharOf(ent)
	if not IsValid(ent) then return nil end
	if istable(ABL) and istable(ABL.WoundStore) and ABL.WoundStore.CharOf then return ABL.WoundStore.CharOf(ent) end
	if ent:IsPlayer() then return ent:Alive() and ent or nil end
	if ent:IsRagdoll() then
		local owner = istable(hg) and isfunction(hg.RagdollOwner) and hg.RagdollOwner(ent) or nil
		if IsValid(owner) and owner:IsPlayer() and owner:Alive() and SK.BodyOf(owner) == ent then return owner end
		return ent
	end
	if ent:IsNPC() then return ent end
	return nil
end
RC.CharOf = CharOf

-- The entity that is a character's body now.
function RC.BodyOf(char)
	if not IsValid(char) then return nil end
	if char:IsPlayer() then return char:Alive() and SK.BodyOf(char) or nil end
	return char
end

local function Touch(char, rec)
	rec.ver = (rec.ver or 0) + 1
	if RC.OnChange then RC.OnChange(char, rec) end
end

local function Ensure(char)
	local rec = byChar[char]
	if not rec then
		rec = { bones = {}, joints = {}, regions = {}, ver = 0, n = 0 }
		byChar[char] = rec
	end
	return rec
end

function I.Get(who)
	local char = CharOf(who)
	return char and byChar[char] or nil, char
end

function I.Of(who, id)
	local rec = I.Get(who)
	local b = SK.Bones[id]
	return rec and b and rec.bones[b.idx] or nil
end

-- fields: state, integrity, site, at, flags, cause. A state of INTACT clears the bone.
function I.Set(who, id, fields, src)
	if not SK.Enabled() then return nil end
	local b = SK.Bones[id]
	local char = CharOf(who)
	if not b or not char then return nil end
	fields = fields or {}
	local state = math.Clamp(math.floor(tonumber(fields.state) or S.FRACTURE), S.INTACT, S.LOST)
	if state == S.INTACT then I.Clear(char, id) return nil end
	local rec = Ensure(char)
	local was = rec.bones[b.idx]
	if not was then
		if rec.n >= C.Records.perChar then return nil end
		rec.n = rec.n + 1
	end
	local e = {
		state = state,
		integrity = math.Clamp(math.floor(tonumber(fields.integrity) or (255 - state * 51)), 0, 255),
		site = fields.site and math.Clamp(fields.site, 0, 1) or (was and was.site) or nil,
		at = fields.at or (was and was.at) or nil,
		flags = bit.band(tonumber(fields.flags) or (was and was.flags) or 0, 15),
		t = CurTime(), src = src or "manual", cause = fields.cause,
	}
	rec.bones[b.idx] = e
	RC.stats.set = RC.stats.set + 1
	Touch(char, rec)
	hook.Run("SK_Injury", RC.BodyOf(char), id, e, was)
	return e
end

function I.SetJoint(who, joint, state, src)
	if not SK.Enabled() then return nil end
	local char = CharOf(who)
	if not SK.Joints[joint] or not char then return nil end
	local rec = Ensure(char)
	state = tonumber(state) or C.JointState.DISLOCATED
	if state == C.JointState.SOUND then
		if not rec.joints[joint] then return nil end
		rec.joints[joint] = nil
	else
		rec.joints[joint] = { state = state, t = CurTime(), src = src or "manual" }
	end
	Touch(char, rec)
	hook.Run("SK_JointInjury", RC.BodyOf(char), joint, rec.joints[joint])
	return rec.joints[joint]
end

-- What Z-City's own number for one of its regions is, kept where no bone could be named.
function I.SetRegion(who, key, value)
	local char = CharOf(who)
	if not char then return end
	local rec = Ensure(char)
	local was = rec.regions[key]
	if value and value > 0 then
		if was and math.abs(was.value - value) < 0.004 then return end
		rec.regions[key] = { value = value, t = CurTime() }
	else
		if not was then return end
		rec.regions[key] = nil
	end
	Touch(char, rec)
end

function I.Clear(who, id, src)
	local char = CharOf(who) or who
	local rec = byChar[char]
	if not rec then return 0 end
	local n = 0
	if id then
		local b = SK.Bones[id]
		local e = b and rec.bones[b.idx]
		if e and (not src or e.src == src) then
			rec.bones[b.idx] = nil
			rec.n = rec.n - 1
			n = 1
			hook.Run("SK_Injury", RC.BodyOf(char), id, nil, e)
		end
	else
		for idx, e in pairs(rec.bones) do
			if not src or e.src == src then
				rec.bones[idx] = nil
				rec.n = rec.n - 1
				n = n + 1
			end
		end
		for jid, j in pairs(rec.joints) do
			if not src or j.src == src then rec.joints[jid] = nil n = n + 1 end
		end
		if not src then rec.regions = {} end
	end
	if n > 0 then
		RC.stats.cleared = RC.stats.cleared + n
		Touch(char, rec)
	end
	return n
end

-- The worst state among the bones of a structure (a group or a set of the registry), and which bone.
function I.Worst(who, group)
	local rec = I.Get(who)
	if not rec then return S.INTACT end
	local worst, which = S.INTACT, nil
	for _, id in ipairs(SK.BonesOf(group)) do
		local e = rec.bones[SK.Bones[id].idx]
		if e and e.state > worst then worst, which = e.state, id end
	end
	return worst, which
end

function I.Count()
	local chars, bones = 0, 0
	for _, rec in pairs(byChar) do chars = chars + 1 bones = bones + rec.n end
	return chars, bones
end

------------------------------------------------------------------------------------------
-- A character's life
------------------------------------------------------------------------------------------
local function Drop(char, why)
	local rec = byChar[char]
	if not rec then return end
	byChar[char] = nil
	RC.stats.dropped = RC.stats.dropped + 1
	Log("  skeleton records: those of %s dropped (%s)", tostring(char), why or "?")
	if RC.OnDrop then RC.OnDrop(char) end
end
RC.Drop = Drop

-- dies: the corpse Z-City makes of them carries the record on (it may take a moment to be there)
hook.Add("PostPlayerDeath", "SK_Records", function(ply)
	if not byChar[ply] then return end
	local function Try(n)
		if not IsValid(ply) then return end
		local rec = byChar[ply]
		if not rec or ply:Alive() then return end
		local corpse = ply:GetNWEntity("RagdollDeath")
		if IsValid(corpse) then
			byChar[corpse] = rec
			byChar[ply] = nil
			RC.stats.handed = RC.stats.handed + 1
			Log("  skeleton records: those of %s are its corpse's now (%s)", tostring(ply), tostring(corpse))
			if RC.OnDrop then RC.OnDrop(ply) end
			Touch(corpse, rec)
		elseif n < 20 then
			timer.Simple(0.1, function() Try(n + 1) end)
		else
			Drop(ply, "died and left no corpse")
		end
	end
	Try(0)
end)
-- lives again: a new body. (Z-City gets a player up from its ragdoll by spawning them anew, with its
-- hook "Fake Up" first, in the same call: that is the same life, and the record stays.)
local gotUp = setmetatable({}, { __mode = "k" })
hook.Add("Fake Up", "SK_Records", function(ply) if IsValid(ply) then gotUp[ply] = engine.TickCount() end end)
local function Spawned(ply)
	if not IsValid(ply) then return end
	if gotUp[ply] and engine.TickCount() - gotUp[ply] <= 1 then return end
	Drop(ply, "spawned")
end
hook.Add("PlayerSpawn", "SK_Records", Spawned)
hook.Add("Player Spawn", "SK_Records", Spawned)
hook.Add("PlayerDisconnected", "SK_Records", function(ply) Drop(ply, "left") end)
hook.Add("EntityRemoved", "SK_Records", function(ent) if byChar[ent] then Drop(ent, "removed") end end)
hook.Add("PostCleanupMap", "SK_Records", function()
	for k in pairs(byChar) do Drop(k, "the map was cleaned up") end
end)
-- whose character is no more, and what has lain there too long
timer.Create("SK_RecordsSweep", 30, 0, function()
	local now = CurTime()
	for char, rec in pairs(byChar) do
		if not IsValid(char) then
			byChar[char] = nil
		elseif not char:IsPlayer() then
			local newest = 0
			for _, e in pairs(rec.bones) do if e.t > newest then newest = e.t end end
			if now - newest > C.Records.age then Drop(char, "old") end
		end
	end
end)
