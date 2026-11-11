-- Network receivers. Each message is a compact event; everything visual is rebuilt locally.

ABL.NoJIT()
local N = ABL.Net

-- Hits wait in a queue, in the order they came, for two things. A hit can name an entity the
-- client does not know yet: a knockdown or a lethal hit turns the player into a ragdoll in the same
-- server tick, and the message can outrun the entity or its bone data (up to half a second; the
-- wound's position is in bone space, so nothing is lost by waiting). And a wound costs a few
-- surface queries to place: at most HITS_PER_FRAME are worked off per frame, so a burst that
-- strikes several bodies in one tick costs several short frames instead of one long one.
local HITS_PER_FRAME = 2
local waiting = {}
local workedFrame, worked = -1, 0

-- A hit names its body by entity index, and waits for it up to half a second: whatever has that
-- index when the hit is worked off must be a character. (An index is used again as soon as its
-- entity is gone: a prop made in that moment is no body, and gets no wounds, no source and no
-- surface model.)
local function Ready(body, ev)
	return IsValid(body) and (body:IsPlayer() or body:IsRagdoll() or body:IsNPC()) and not body:IsDormant() and body:GetBoneMatrix(ev.bone) ~= nil
end

-- The same event a second time would make a second wound record, a second set of marks and a
-- second burst of the same wound. The server sends every hit once, on a reliable channel, and the
-- client makes no blood of its own ahead of the server: so this is only a safeguard. Events are
-- told apart by what the server put in them: the body, the bone, the place on it and the seed it
-- drew for the hit. They are remembered for a few seconds.
local seen, seenN = {}, 0
local function Duplicate(index, ev)
	local now = RealTime()
	if seenN > 96 then
		for k, t in pairs(seen) do
			if now - t > 5 then seen[k] = nil seenN = seenN - 1 end
		end
	end
	local p = ev.lpos
	local key = index .. ":" .. ev.bone .. ":" .. (ev.seed or 0) .. ":" .. p.x .. ":" .. p.y .. ":" .. p.z
	local t = seen[key]
	if t and now - t < 5 then return true end
	if not t then seenN = seenN + 1 end
	seen[key] = now
	return false
end

-- no wound lies further from the bone it is on than this (units; the wire allows 127)
local LOCAL_MAX = 100

local function Take()
	local f = FrameNumber()
	if f ~= workedFrame then workedFrame, worked = f, 0 end
	if worked >= HITS_PER_FRAME then return false end
	worked = worked + 1
	return true
end

hook.Add("Think", "ABL_WaitingHits", function()
	if #waiting == 0 then return end
	local now = RealTime()
	local list = waiting
	waiting = {}
	for i = 1, #list do
		local w = list[i]
		local body = Entity(w.index)
		if Ready(body, w.ev) then
			if Take() then
				w.ev.body = body
				ABL.Emission.OnHit(w.ev)
			else
				waiting[#waiting + 1] = w
			end
		elseif now > w.t then
			local why = (not IsValid(body) and "its entity never arrived") or ((body:IsPlayer() or body:IsRagdoll() or body:IsNPC()) and "its body has no bone data here (not in this client's sight)" or "what has that number is no character")
			ABL.Trace.Event(nil, nil, string.format("hit on entity %d dropped", w.index), why)
			if ABL.TestLog then ABL.TestLog("   hit on entity %d dropped: %s", w.index, why) end
		else
			waiting[#waiting + 1] = w
		end
	end
end)

net.Receive(N.HIT, function(len)
	N.Account(len)
	if not ABL.Enabled() then return end
	local ev = {}
	local index = net.ReadUInt(13)
	ev.body = Entity(index)
	ev.bone = net.ReadUInt(8)
	ev.lpos = N.ReadLocal()
	ev.dir = net.ReadNormal()
	ev.class = net.ReadUInt(3)
	ev.damage = net.ReadUInt(10)
	ev.bleed = net.ReadUInt(10) / 4
	ev.hitgroup = net.ReadUInt(4)
	-- the wound event: what the projectile was, what it crossed, whether it left the body
	ABL.Wound.Read(ev)
	-- Z-City keeps two wound records for this shot; the second lies at exitLocal (the wound
	-- bone's space) when given, else at the entry
	ev.second = net.ReadBool()
	if net.ReadBool() then ev.exitLocal = N.ReadLocal() end
	-- the same bullet striking the same character a second time (sv_main.lua)
	ev.continued = net.ReadBool()
	-- the living player whose body it is (0: a corpse, or no player's)
	local own = net.ReadUInt(8)
	if own > 0 then ev.owner = Entity(own) end
	if ABL.Debug then ABL.Debug.LogNet("hit", len, ev) end
	-- (an event with a place no wound can have is no event; an exit like that is no exit)
	if ev.lpos:LengthSqr() > LOCAL_MAX * LOCAL_MAX then
		ABL.Trace.Event(nil, nil, string.format("hit on entity %d dropped", index), string.format("its place is %.0f units from the bone it names: no wound lies there", ev.lpos:Length()))
		if ABL.TestLog then ABL.TestLog("   hit on entity %d dropped: its place is %.0f units from the bone it names", index, ev.lpos:Length()) end
		return
	end
	if ev.exitLocal and ev.exitLocal:LengthSqr() > LOCAL_MAX * LOCAL_MAX then ev.exitLocal = nil end
	if Duplicate(index, ev) then
		ABL.Trace.Event(nil, nil, string.format("hit on entity %d ignored", index), "the same event a second time")
		if ABL.TestLog then ABL.TestLog("   hit on entity %d dropped: the same event again", index) end
		return
	end
	-- (hits already waiting go first)
	if #waiting > 0 or not Ready(ev.body, ev) or not Take() then
		if index > 0 and #waiting < 96 then waiting[#waiting + 1] = { index = index, ev = ev, t = RealTime() + 0.5 } end
		return
	end
	ABL.Emission.OnHit(ev)
end)

------------------------------------------------------------------------------------------
-- Wounds this client was not there for (server/sv_woundstore.lua)
-- A hit is sent once, to those who have the body in sight then. A body that comes into this
-- client's sight later (or was there before this client joined) is asked about: the server
-- answers with the wounds it carries, each as the hit it was and how old it is. The wound is
-- made from that as from a hit, without what belonged to the moment (cl_emission.lua E.OnHit
-- with ev.replay), and one this client already has is not made again (it is looked for among
-- the body's own records there: the server answers with all of a body's wounds).
------------------------------------------------------------------------------------------
local SC = ABL.Config.WoundStore
local want, asked = {}, {}     -- entity number -> when to ask; when last asked
local function Want(ent, now)
	if not IsValid(ent) or not (ent:IsPlayer() or ent:IsRagdoll() or ent:IsNPC()) then return end
	local i = ent:EntIndex()
	if i <= 0 or i > 8191 then return end
	local t = RealTime()
	if now then want[i] = t return end
	if asked[i] and t - asked[i] < SC.askAgain then return end
	if not want[i] then want[i] = t + SC.askDelay end
end
ABL.WoundSync = { Want = Want, stats = { asked = 0, told = 0, had = 0 } }
local WY = ABL.WoundSync

hook.Add("NotifyShouldTransmit", "ABL_WoundSync", function(ent, on)
	if on then Want(ent) end
end)
hook.Add("NetworkEntityCreated", "ABL_WoundSync", function(ent)
	-- (an entity's number is given to another once it is gone: a body that is new is asked
	-- about whenever that number was last asked about)
	if IsValid(ent) then
		asked[ent:EntIndex()] = nil
		Want(ent)
	end
end)
hook.Add("InitPostEntity", "ABL_WoundSync", function()
	timer.Simple(5, function()
		for _, e in ipairs(ents.GetAll()) do
			if IsValid(e) and not e:IsDormant() then Want(e) end
		end
	end)
end)
timer.Create("ABL_WoundSync", 0.25, 0, function()
	if next(want) == nil then return end
	if not ABL.Enabled() then
		for k in pairs(want) do want[k] = nil end
		return
	end
	local now = RealTime()
	local list = {}
	for i, t in pairs(want) do
		if now >= t then
			want[i] = nil
			local ent = Entity(i)
			if IsValid(ent) and not ent:IsDormant() then
				list[#list + 1] = i
				asked[i] = now
				if #list >= 15 then break end
			end
		end
	end
	if #list == 0 then return end
	net.Start(N.WREQ)
	net.WriteUInt(#list, 4)
	for _, i in ipairs(list) do net.WriteUInt(i, 13) end
	net.SendToServer()
	WY.stats.asked = WY.stats.asked + #list
end)

net.Receive(N.WREP, function(len)
	N.Account(len)
	local ev, index = N.ReadHit()
	ev.age = net.ReadUInt(12)
	local own = net.ReadUInt(8)
	if own > 0 then ev.owner = Entity(own) end
	ev.replay = true
	if not ABL.Enabled() then return end
	WY.stats.told = WY.stats.told + 1
	if ABL.Debug then ABL.Debug.LogNet("wound told again", len, ev) end
	if ev.lpos:LengthSqr() > LOCAL_MAX * LOCAL_MAX then return end
	if ev.exitLocal and ev.exitLocal:LengthSqr() > LOCAL_MAX * LOCAL_MAX then ev.exitLocal = nil end
	-- (in its turn, behind the hits that wait; and the body's bones have to be there)
	if #waiting > 0 or not Ready(ev.body, ev) or not Take() then
		if index > 0 and #waiting < 96 then waiting[#waiting + 1] = { index = index, ev = ev, t = RealTime() + 1.5 } end
		return
	end
	ABL.Emission.OnHit(ev)
end)

-- A player has been spawned anew (server/sv_woundstore.lua): its blood begins again.
net.Receive(N.LIFE, function(len)
	N.Account(len)
	local ply = Entity(net.ReadUInt(8))
	if not ABL.Enabled() then return end
	-- (hits of the old life that still wait for their body)
	for i = #waiting, 1, -1 do
		local ev = waiting[i].ev
		if IsValid(ply) and (ev.owner == ply or waiting[i].index == ply:EntIndex()) then table.remove(waiting, i) end
	end
	if IsValid(ply) then ABL.Sources.NewLife(ply, "the server says its life begins again") end
end)

concommand.Add("abl_wound_resync", function()
	local n = 0
	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and not e:IsDormant() and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) then
			Want(e, true)
			n = n + 1
		end
	end
	ABL.Print("asking the server for the wounds of %d character(s) in sight (it answers for one character every %d s at the most)", n, SC.again)
end, nil, "AdvancedBlood: asks the server again for the wounds of every character in sight (after abl_wound_clear, for one)")

net.Receive(N.RCOL, function(len)
	N.Account(len)
	if not ABL.Enabled() then return end
	local ev = {}
	ev.rag = N.ReadEnt()
	ev.bone = net.ReadUInt(8)
	ev.pos = net.ReadVector()
	ev.normal = net.ReadNormal()
	ev.speed = net.ReadUInt(12)
	ev.world = net.ReadBool()
	-- (a ragdoll, and a place on the map)
	if not IsValid(ev.rag) or not ev.rag:IsRagdoll() then return end
	if not ABL.InWorld(ev.pos.x, ev.pos.y, ev.pos.z) then return end
	ABL.Transfer.OnCollide(ev)
	if ABL.Debug then ABL.Debug.LogNet("rcol", len, ev) end
end)

net.Receive(N.PERSIST, function(len)
	N.Account(len)
	local n = net.ReadUInt(7)
	local recs = {}
	for i = 1, n do
		recs[i] = { pos = net.ReadVector(), normal = net.ReadNormal(), vol = net.ReadUInt(14), age = net.ReadUInt(14) }
	end
	if not ABL.Enabled() then return end
	for _, r in ipairs(recs) do
		local ok = ABL.InWorld(r.pos.x, r.pos.y, r.pos.z) and r.normal:LengthSqr() > 0.5
		local t = ok and util.TraceLine({ start = r.pos + r.normal * 4, endpos = r.pos - r.normal * 6, mask = MASK_SOLID_BRUSHONLY })
		-- (a trace that begins inside the floor has found no floor)
		if t and t.Hit and not t.StartSolid then
			local p = ABL.Pools.Create(t.HitPos.x, t.HitPos.y, t.HitPos.z, t.HitNormal.x, t.HitNormal.y, t.HitNormal.z, r.vol, ABL.Surface.FromTrace(t), nil, r.age)
			if p then
				p.lastFeed = CurTime() - r.age
				ABL.FlowCore.Release("pool", r.vol)
			end
		end
	end
	if ABL.Debug then ABL.Debug.LogNet("persist", len, { count = n }) end
end)

hook.Add("InitPostEntity", "ABL_RequestPersist", function()
	timer.Simple(4, function()
		net.Start(N.REQ)
		net.SendToServer()
	end)
end)
