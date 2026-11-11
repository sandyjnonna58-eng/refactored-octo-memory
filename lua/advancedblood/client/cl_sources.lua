-- Bleeding sources. A source is one character: keyed by the player while alive (whether upright
-- or ragdolled) and by the corpse ragdoll after death. Its body entity is re-resolved every frame,
-- and all body-attached blood lives in mesh/bone space, so player <-> ragdoll <-> corpse
-- transitions keep blood exactly where it was instead of teleporting it.
-- Persistent wounds mirror Z-City's replicated wound netvars (no extra networking).

ABL.NoJIT()
ABL.Sources = ABL.Sources or {}
local S = ABL.Sources
local C, Z, BM = ABL.Config, ABL.ZC, ABL.BodyMesh
-- (what happens to a character's blood and to each wound is written down as it happens: cl_trace.lua)
local TR = ABL.Trace
local floor = math.floor

S.list = S.list or {}
S.byKey = S.byKey or {}
S.byBody = S.byBody or {}   -- body entity -> source (for render hooks keyed by entity)
-- player -> when its life began, where this client was told (S.NewLife)
S.lifeT = S.lifeT or setmetatable({}, { __mode = "k" })
local lifeT = S.lifeT

local function WoundId(w, arterial)
	local p = w[2]
	if arterial and isstring(w[7]) then return "A:" .. w[7] end
	return (arterial and "a:" or "v:") .. tostring(w[4]) .. ":" .. floor(p.x * 2 + 0.5) .. ":" .. floor(p.y * 2 + 0.5) .. ":" .. floor(p.z * 2 + 0.5)
end

function S.Get(key) return S.byKey[key] end

function S.Ensure(key)
	if not IsValid(key) then return nil end
	local src = S.byKey[key]
	if src then return src end
	src = {
		key = key,
		owner = key:IsPlayer() and key or nil,
		isCorpse = not key:IsPlayer(),
		body = nil, bodyIdx = -1, meshKey = nil, mesh = nil,
		wounds = {}, woundList = {},
		blobs = {}, segCount = 0, wet = {}, wetTri = {},
		pose = BM.NewPose(),
		lod = 0, importance = 0, visible = false, dist = 1e9,
		pulse = 70, alive = true, blood = 5000, flowRate = 0, deathTime = nil,
		nextSync = 0, nextEval = 0, created = CurTime(), lastActive = CurTime(),
		filterAll = {}, filterOwner = {},
		seed = ABL.Hash(tostring(key:EntIndex()) .. ":" .. floor(CurTime())),
		pendingHits = {},
		lifeT = lifeT[key],
	}
	src.rng = ABL.RNG(src.seed)
	S.byKey[key] = src
	S.list[#S.list + 1] = src
	TR.Event(src, nil, "taken up", key:IsPlayer() and "a player" or "a body that is no living player's")
	return src
end

local function FreeBodyState(src)
	for i = #src.blobs, 1, -1 do ABL.Flow.FreeBlob(src.blobs[i]) end
	src.blobs = {}
	ABL.Flow.FreeSegs(src)
	ABL.FlowCore.FreeSource(src)
	ABL.Film.FreeSource(src)
	-- (blood the beads still held is written off)
	if (src.lbk or 0) > 0 then ABL.FlowCore.Move("surface", "lost", src.lbk) end
	src.lbk = nil
	src.wet = {}
	src.wetTri = {}
	for _, w in pairs(src.wounds) do w.bead = nil w.tri = nil w.chan = nil end
	if ABL.WoundFX and ABL.WoundFX.Clear then ABL.WoundFX.Clear(src) else src.marks, src.pendingMarks = nil, nil end
	if ABL.Wounds then ABL.Wounds.ForgetSource(src) end
end

-- The body has another surface model now (another model, other clothes, another entity whose
-- model differs): nothing that was laid on the old one can stay. Beads and channels go (the blood
-- in them is written off), wounds find their place on the new surface, marks are placed again from
-- their records. model: the model itself is another one (not only its clothes), so bone numbers
-- mean other bones too.
local function DropSurface(src, model)
	for i = #src.blobs, 1, -1 do ABL.Flow.FreeBlob(src.blobs[i]) end
	src.blobs = {}
	ABL.FlowCore.FreeSource(src)
	-- (the film's cells are places of the old surface model)
	ABL.Film.FreeSource(src)
	src.wetTri = {}
	for _, w in pairs(src.wounds) do
		w.tri, w.bead, w.chan, w.anchorTried = nil, nil, nil, false
		-- (its bone is looked up by name again)
		w.boneFor = -1
	end
	if model then
		-- streaks and wetness are kept per bone number
		ABL.Flow.FreeSegs(src)
		src.wet = {}
		src.contact = nil
		src.heartFor = nil
	end
	if ABL.WoundFX and ABL.WoundFX.Remesh then ABL.WoundFX.Remesh(src) end
end

function S.Remove(src, why)
	TR.Event(src, nil, "let go", why)
	FreeBodyState(src)
	for i = #S.list, 1, -1 do
		if S.list[i] == src then ABL.SwapRemove(S.list, i) break end
	end
	if S.byKey[src.key] == src then S.byKey[src.key] = nil end
	if src.body and S.byBody[src.body] == src then S.byBody[src.body] = nil end
	src.removed = true
	ABL.Drops.ForgetSource(src)
end

function S.ClearAll()
	for i = #S.list, 1, -1 do S.Remove(S.list[i], "all blood cleared") end
	S.list, S.byKey, S.byBody = {}, {}, {}
end

------------------------------------------------------------------------------------------
-- Wound mirror
------------------------------------------------------------------------------------------
local function SyncList(src, list, arterial, now)
	if not list then return end
	-- (a wound Z-City made more than a second before this life began is the last life's: its
	-- list reaches a client a moment after the spawn does. w[5]: when Z-City made the wound.)
	local born = src.lifeT and src.lifeT - 1 or nil
	for _, w in ipairs(list) do
		if istable(w) and isvector(w[2]) and isstring(w[4]) and not (born and isnumber(w[5]) and w[5] < born) then
			local id = WoundId(w, arterial)
			local wd = src.wounds[id]
			if not wd then
				wd = ABL.Emission.NewWound(src, id, arterial, w)
				src.wounds[id] = wd
				src.woundList[#src.woundList + 1] = wd
				TR.Event(src, wd, "opened", (arterial and "an artery" or "a wound") .. " in Z-City's list" .. (wd.rec and ", of a hit this client knows" or ", of no hit this client knows yet"))
			elseif wd.closing then
				TR.Event(src, wd, "open again", "in Z-City's list again while it was closing")
			end
			wd.sev = tonumber(w[1]) or 0
			-- (it was on its way out and is in the list again: it comes back from where it stood)
			wd.closing = nil
			if arterial and isvector(w[6]) then
				local d = w[6]
				local l = d:Length()
				if l > 1e-3 then wd.ldx, wd.ldy, wd.ldz = d.x / l, d.y / l, d.z / l end
			end
			wd.seen = now
		end
	end
end

function S.Sync(src)
	-- a dead player's wounds now live on the corpse (the player's netvars keep the old list)
	if src.migratedTo and IsValid(src.migratedTo) then
		if #src.woundList > 0 then
			TR.Event(src, nil, string.format("%d wound(s) dropped", #src.woundList), "its wounds are its corpse's")
			src.wounds, src.woundList = {}, {}
		end
		return
	end
	local now = CurTime()
	local vlist, alist = Z.GetWoundLists(src.key)
	SyncList(src, vlist, false, now)
	SyncList(src, alist, true, now)
	-- (the neck of a headless body: Z-City has a fountain there and no wound)
	SyncList(src, Z.StumpWounds(src.key), true, now)
	-- wounds that disappeared (bandaged, healed, coagulated) stop emitting; blood already out stays
	local wl = src.woundList
	for i = #wl, 1, -1 do
		local wd = wl[i]
		local gone
		if wd.synthetic then
			-- ABL's own wounds (exits) close up on their own
			wd.sev = wd.sev0 * math.exp(-(now - wd.born) / wd.tau)
			gone = wd.sev < 0.3
		else
			gone = now - wd.seen > 1.3 or wd.sev <= 0
			-- It has closed (bandaged, healed, clotted over). What it releases does not end from
			-- one frame to the next: its response falls away first (cl_emission.lua, Respond), and
			-- the stream thins out and breaks up with it. A few seconds at most.
			if gone and wd.sev > 0 and (wd.resp or 0) > 0.02 then
				if not wd.closing then
					wd.closing = now
					TR.Event(src, wd, "closing", "no longer in Z-City's list: what it lets out falls away")
				end
				if now - wd.closing < C.Wound.closeMax then gone = false end
			end
		end
		if gone then
			if wd.bead then wd.bead.tethered = nil wd.bead = nil end
			-- (its channel keeps what blood is in it: it runs on, and dries)
			if wd.chan then wd.chan.wd = nil wd.chan = nil end
			TR.Event(src, wd, "removed", wd.synthetic and "an exit of this module's own: closed up" or (wd.sev <= 0 and "its value in Z-City's list is nought") or
				(wd.closing and "closed: not in Z-City's list") or "not in Z-City's list")
			wd.removed = true
			src.wounds[wd.id] = nil
			ABL.SwapRemove(wl, i)
		end
	end
end

------------------------------------------------------------------------------------------
-- Body resolution & transitions
------------------------------------------------------------------------------------------
-- Everything a source holds about its body goes over to another source of the same character
-- (same model, same bone indices, same mesh): body blood, wound marks, wound records, wounds and
-- the books.
local function MoveState(src, dst, why)
	-- What lies on the surface was built on src's surface model. dst takes it over together with
	-- that model (UpdateBody drops it when dst's body turns out to have another); a dst that already
	-- has a different one cannot take it.
	local dropped = false
	if dst.meshKey == nil then
		dst.meshKey, dst.mesh, dst.bodyModel = src.meshKey, src.mesh, src.bodyModel
	elseif dst.meshKey ~= src.meshKey then
		DropSurface(src, true)
		dropped = true
	end
	TR.Event(dst, nil, string.format("took over the blood of %s: %d wound(s), %d mark(s), film %d cells%s", tostring(src.key), #src.woundList, src.marks and #src.marks or 0,
		src.film and src.film.n or 0, dropped and " (another surface model: what lay on the skin was dropped, marks are placed again)" or ""), why)
	for _, b in ipairs(src.blobs) do b.src = dst dst.blobs[#dst.blobs + 1] = b end
	ABL.Flow.MoveSegs(src, dst)
	ABL.FlowCore.MoveSource(src, dst)
	ABL.Film.MoveSource(src, dst)
	-- (the pools on the ground and the drops in the air that are this character's: dst's from here on)
	ABL.Pools.MoveOwner(src.key, dst.key)
	ABL.Drops.MoveOwner(src.key, dst.key)
	if ABL.Ground.MoveOwner then ABL.Ground.MoveOwner(src.key, dst.key) end
	dst.lbk = (dst.lbk or 0) + (src.lbk or 0)
	src.lbk = nil
	for bone, v in pairs(src.wet) do dst.wet[bone] = (dst.wet[bone] or 0) + v end
	for tri, v in pairs(src.wetTri) do dst.wetTri[tri] = (dst.wetTri[tri] or 0) + v end
	-- wound marks (cl_woundfx) go with the body too
	if src.marks then
		dst.marks = dst.marks or {}
		for _, mk in ipairs(src.marks) do dst.marks[#dst.marks + 1] = mk end
	end
	if src.pendingMarks then
		dst.pendingMarks = dst.pendingMarks or {}
		for _, q in ipairs(src.pendingMarks) do dst.pendingMarks[#dst.pendingMarks + 1] = q end
	end
	-- the wound records behind them, and hits whose Z-City wounds have not arrived yet
	ABL.Wounds.Move(src, dst)
	for _, h in ipairs(src.pendingHits) do dst.pendingHits[#dst.pendingHits + 1] = h end
	src.pendingHits = {}
	src.marks, src.pendingMarks = nil, nil
	-- the books: what was lost and what was shown
	if src.ledger then
		for k, v in pairs(src.ledger) do ABL.Wounds.Ledger(dst, k, v) end
		src.ledger = nil
	end
	dst.lost = (dst.lost or 0) + (src.lost or 0)
	src.lost = nil
	-- wounds keep their anchors, beads and links, so the body goes on bleeding from the same spots
	for id, wd in pairs(src.wounds) do
		local own = dst.wounds[id]
		if not own then
			wd.src = dst
			dst.wounds[id] = wd
			dst.woundList[#dst.woundList + 1] = wd
			wd.seen = CurTime() + 1 -- grace until the new body's netvars arrive
		elseif own ~= wd then
			-- The new body's own wound list was here first (a corpse gets its whole list as it is
			-- made) and a wound was made of this entry a moment ago. The old one takes its place:
			-- it has the anchor, the stream that leaves it, and where its flow stood. Else the
			-- flow began again from nothing and the stream was begun a second time.
			if own.bead then own.bead.tethered = nil own.bead = nil end
			if own.chan then own.chan.wd = nil own.chan = nil end
			if own.rec and not wd.rec then ABL.Wounds.Link(own.rec, wd, own.role, own.mark) end
			TR.Event(dst, wd, "kept", "the same wound was made anew from the new body's list a moment ago: the older one takes its place")
			own.removed = true
			wd.src = dst
			wd.sev, wd.seen, wd.closing = own.sev, own.seen, nil
			dst.wounds[id] = wd
			for i, w in ipairs(dst.woundList) do
				if w == own then dst.woundList[i] = wd break end
			end
		end
	end
	src.blobs, src.wet, src.wetTri, src.wounds, src.woundList = {}, {}, {}, {}, {}
	-- hits and wounds that had been waiting for each other in different sources
	ABL.Emission.LinkWaiting(dst, CurTime())
end

-- (UpdateBody is below; MigrateToCorpse binds a corpse's new source with it)
local UpdateBody

local function MigrateToCorpse(src, corpse)
	if src.migratedTo == corpse then return end
	src.migratedTo = corpse
	corpse.ablFlowLegacy = src.key.ablFlowLegacy
	corpse.ablNoFilm = src.key.ablNoFilm
	local dst = S.Ensure(corpse)
	if not dst or dst == src then return end
	MoveState(src, dst, "the player died: this is its corpse")
	-- (once: the ooze of a dead body fades from the moment of death, see Discover)
	dst.deathTime = dst.deathTime or CurTime()
	dst.alive = false
	-- Phase 19 (bindAtDeath): the corpse's source is bound to its body in this same frame. A new
	-- source is taken up at the end of S.list, which S.Update walks from the end down, so it was
	-- first bound and given a distance in the next frame: the body was drawn without its blood for
	-- one to three frames at every death (the draw hook knows a body only by S.byBody, and needs
	-- its distance). Until the LOD looks at it (at its first S.Update), it has the distance and
	-- tiers of the source it took the blood from, which stood where it lies.
	if C.V19On and C.V19On("bindAtDeath") and dst.isCorpse and dst.body == nil then
		UpdateBody(dst)
		if IsValid(dst.body) then
			dst.dist, dst.lod, dst.flowLod, dst.visible = src.dist, src.lod, src.flowLod, src.visible
			dst.pose:Begin(FrameNumber())
		end
	end
end

-- A source keyed by a ragdoll that turns out to be a living player's fake ragdoll (the hit that
-- made it arrived before the link that says whose it is): it is that player's.
local function AdoptByOwner(src)
	local owner = Z.GetOwner(src.key)
	if not (IsValid(owner) and owner:IsPlayer() and owner:Alive()) then return false end
	local dst = S.Ensure(owner)
	if not dst or dst == src then return false end
	MoveState(src, dst, "the body is the ragdoll this living player lies in")
	dst.nextSync = 0
	S.Remove(src, "its blood is its owner's now")
	return true
end

function S.ResolveBody(src)
	local key = src.key
	if not IsValid(key) then return nil end
	if key:IsPlayer() then
		if not key:Alive() then
			local corpse = Z.GetCorpse(key)
			if IsValid(corpse) then MigrateToCorpse(src, corpse) end
			return nil
		end
		src.migratedTo = nil
		return Z.GetBody(key)
	end
	return key
end

function UpdateBody(src)
	local body = S.ResolveBody(src)
	if src.body ~= body then
		if src.body and S.byBody[src.body] == src then S.byBody[src.body] = nil end
		if IsValid(body) then S.byBody[body] = src end
		if src.body ~= nil or body ~= src.key then
			TR.Event(src, nil, "its body is now " .. (IsValid(body) and tostring(body) or "none"), src.body ~= nil and ("was " .. tostring(src.body)) or nil)
		end
	end
	src.body = body
	if not IsValid(body) then return end
	local idx = body:EntIndex()
	if idx ~= src.bodyIdx then
		src.filterAll = { body }
		src.filterOwner = {}
		if IsValid(src.owner) then
			src.filterAll[2] = src.owner
			src.filterOwner[1] = src.owner
		end
	end
	-- Which surface model the body has (model and bodygroups: a key string). Looked up when the
	-- body is another entity or has another model, while no surface model is there yet, and twice
	-- a second (clothes change without anything else changing).
	-- Everything on the body's surface (channels, beads, wound anchors, marks) is built on the
	-- surface model of src.meshKey, and src.mesh is that model or nil: never another one. The
	-- moment the key changes, what was built on the old one is dropped and src.mesh waits for the new.
	local now = CurTime()
	local model = body:GetModel()
	if idx ~= src.bodyIdx or model ~= src.bodyModel or not src.mesh or now > (src.nextMeshCheck or 0) then
		local modelChanged = src.bodyModel ~= nil and model ~= src.bodyModel
		src.bodyIdx, src.bodyModel = idx, model
		src.nextMeshCheck = now + 0.5
		local key = BM.KeyFor(body)
		if key ~= src.meshKey then
			if src.meshKey then
				TR.Event(src, nil, "surface model changed", (modelChanged and "another model" or "the same model in other clothes") .. ": what lay on the skin is dropped, wounds and marks find their place again")
				DropSurface(src, modelChanged)
			end
			src.meshKey = key
			src.mesh = nil
		end
		if not src.mesh then src.mesh = BM.Get(body) end
	end
	src.pose:Bind(body, src.mesh)
	src.bodyCenter = body:WorldSpaceCenter()
	-- world bounds of the body (hull for players, physics bounds for ragdolls): cheap first test
	-- before droplets are checked against the individual hitboxes
	src.bbMin, src.bbMax = body:WorldSpaceAABB()
	src.isRagdoll = body:IsRagdoll()
end

------------------------------------------------------------------------------------------
-- Discovery
------------------------------------------------------------------------------------------
local function HasWounds(ent)
	local v, a = Z.GetWoundLists(ent)
	return (v and #v > 0) or (a and #a > 0)
end

local nextScan = 0
local warmIdx = 0
local function Discover()
	local all = player.GetAll()
	for _, ply in ipairs(all) do
		if not S.byKey[ply] and HasWounds(ply) then
			-- A dead player keeps the wound list it died with; its wounds are the corpse's now. It
			-- gets a source only to hand them over (a corpse whose own wounds reached this client
			-- before the corpse did has none yet), not again and again once the corpse has one: each
			-- handing-over used to set the time of death anew, and the corpse never stopped bleeding.
			local corpse = not ply:Alive() and Z.GetCorpse(ply) or nil
			if not (IsValid(corpse) and S.byKey[corpse]) then S.Ensure(ply) end
		end
	end
	-- A headless body bleeds from the neck even when no wound of its own reached this client.
	for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
		if not S.byKey[rag] and Z.StumpWounds(rag) then
			local owner = Z.GetOwner(rag)
			if not (IsValid(owner) and owner:Alive()) then S.Ensure(rag) end
		end
	end
	-- One nearby player per scan: have the surface model of its body ready before it is hit, so
	-- that the first wound already knows its geometry (angle of impact, track, where the bullet
	-- leaves). Built once per model and outfit, in the time-sliced job runner.
	if #all > 0 then
		warmIdx = warmIdx % #all + 1
		local ply = all[warmIdx]
		if IsValid(ply) and ply:Alive() and not ply:IsDormant() then
			local d = ply:GetPos():DistToSqr(EyePos())
			if d < C.WoundFX.warmDist ^ 2 then
				local m = BM.Get(Z.GetBody(ply))
				-- (and where a film of blood lies on it, cl_filmchart.lua: built once per surface model too,
				-- so that a wound's first blood has a surface to spread on)
				if m and ABL.Film.cv:GetBool() then ABL.FilmChart.Get(m) end
			end
		end
	end
end

hook.Add("OnNetVarSet", "ABL_WoundNetVar", function(index, key, var)
	if key ~= "wounds" and key ~= "arterialwounds" then return end
	if not ABL.Enabled() then return end
	if not istable(var) or #var == 0 then
		local src = S.byKey[Entity(index)]
		if src then src.nextSync = 0 end
		return
	end
	local ent = Entity(index)
	if not IsValid(ent) then return end
	-- a living player's fake ragdoll is represented by the player's source
	if ent:IsRagdoll() and IsValid(Z.GetOwner(ent)) and Z.GetOwner(ent):Alive() then return end
	-- (an NPC Z-City runs an organism for bleeds like a player)
	if ent:IsPlayer() or ent:IsRagdoll() or ent:IsNPC() then
		local src = S.Ensure(ent)
		if src then src.nextSync = 0 end
	end
end)

------------------------------------------------------------------------------------------
-- Per-frame update (not fixed-step): bodies, LOD, wound sync, lifetime
------------------------------------------------------------------------------------------
function S.Update()
	local now = CurTime()
	if now > nextScan then
		nextScan = now + 0.5
		Discover()
	end
	local frame = FrameNumber()
	local list = S.list
	-- (phase 19, bindAtDeath: marks that wait for their body are placed in the first frame it can
	-- take them, not at the LOD's next look a fifth of a second later)
	local markNow = C.V19On ~= nil and C.V19On("bindAtDeath")
	for i = #list, 1, -1 do
		local src = list[i]
		local key = src.key
		if not IsValid(key) then
			S.Remove(src, "its entity is gone")
		elseif src.isCorpse and now - src.created < 3 and now >= src.nextEval and AdoptByOwner(src) then
			-- (gone: its state is the owner's now)
		else
			UpdateBody(src)
			src.pose:Begin(frame)
			if now >= src.nextSync then
				src.nextSync = now + 0.35
				S.Sync(src)
				local pulse, alive, blood = Z.Vitals(src.body or key, src.owner)
				if src.alive and not alive then src.deathTime = src.deathTime or now end
				if alive then src.deathTime = nil end
				src.pulse, src.alive, src.blood = pulse, alive, blood
				ABL.Wounds.Reservoir(src, blood, now)
			end
			if now >= src.nextEval then
				src.nextEval = now + 0.2
				ABL.LOD.Evaluate(src)
				if src.pendingMarks then ABL.WoundFX.Think(src) end
				-- hits whose Z-City wounds never came (the wound list was full, or cleared at once)
				local ph = src.pendingHits
				for k = #ph, 1, -1 do
					if now - ph[k].t > 4 then table.remove(ph, k) end
				end
			elseif markNow and src.pendingMarks and #src.pendingMarks > 0 then
				ABL.WoundFX.Think(src)
			end
			local active = #src.woundList > 0 or #src.blobs > 0 or (src.segCount or 0) > 0 or (src.marks ~= nil and #src.marks > 0) or ABL.FlowCore.Active(src) or ABL.Film.Active(src)
			if active then
				src.lastActive = now
				TR.DrawState(src, frame)
			end
			-- forget idle sources (dead bodies keep trails until the entity goes away)
			if not active and now - src.lastActive > 5 then S.Remove(src, "no wound and no blood of it for five seconds") end
		end
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle hooks from Z-City / GMod
------------------------------------------------------------------------------------------
-- A player's new life: nothing of the old body's blood belongs on the new one.
-- Told by the server (abl_life, cl_events.lua): it knows a spawn from a get-up. Z-City's own hook
-- "Player Spawn" on a client says the same where it is run, but it is not run for any spawn of a
-- player who has once been got up from its ragdoll (its flag for the get-up is taken back only
-- inside that hook), so by itself it left the bullet holes and the film of the last life on the
-- new body. A wound of the old life that is still in Z-City's list a moment after (the list comes
-- a little later than the spawn) is not taken up again: SyncList, by the time Z-City made it.
function S.NewLife(ply, why)
	if not IsValid(ply) then return end
	local now = CurTime()
	-- (twice for one spawn, by the server's word and by the hook: once is enough)
	if lifeT[ply] and now - lifeT[ply] < 0.5 then return end
	lifeT[ply] = now
	local src = S.byKey[ply]
	if not src then return end
	src.lifeT = now
	TR.Event(src, nil, string.format("a new life: %d wound(s), %d mark(s), film %d cells dropped", #src.woundList, src.marks and #src.marks or 0, src.film and src.film.n or 0), why)
	FreeBodyState(src)
	for _, wd in pairs(src.wounds) do wd.removed = true end
	src.wounds, src.woundList = {}, {}
	src.deathTime = nil
	-- a new body: the books start again
	src.ledger, src.lost, src.bank, src.lossRate, src.lossT, src.owed, src.advance, src.bloodSeen, src.gov = nil, nil, nil, nil, nil, nil, nil, nil, nil
	src.pendingHits = {}
end

hook.Add("Player Spawn", "ABL_ResetOnSpawn", function(ply)
	S.NewLife(ply, "Z-City's hook \"Player Spawn\" on this client")
end)

hook.Add("EntityRemoved", "ABL_SourceRemoved", function(ent, fullUpdate)
	if fullUpdate then return end
	local src = S.byKey[ent]
	if src then S.Remove(src, "its entity was removed") end
end)

gameevent.Listen("player_disconnect")
hook.Add("player_disconnect", "ABL_SourceDisconnect", function(data)
	timer.Simple(0, function()
		for i = #S.list, 1, -1 do
			local src = S.list[i]
			if not IsValid(src.key) then S.Remove(src, "its player left") end
		end
	end)
end)
