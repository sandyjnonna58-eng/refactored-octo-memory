-- Server: what clients are told of a character's breathing.
--
--   resp_clock   server -> every client that can see the character: the breathing clock. Where in
--                a breath it stood at a game time, how fast and how deep it breathes, and whether
--                at all; a client runs it forward by itself (cl_net.lua). Sent when the clock does
--                not simply run on (a breath stops, begins, is held), when rate or depth have
--                moved by a step, and every couple of seconds; some ten bytes. No shape, no bone
--                and no frame of any animation is ever sent.
--   resp_sub     client -> server: a body's entity number, and whether to watch it or let it go
--   resp_rec     server -> a client that watches a body and may use the developer view: what is
--                wrong with its lungs (what Z-City itself tells no client)

local RS = HemoRespiratory
local C, CK, Z, K = RS.Config, RS.Clock, RS.ZC, RS.Clocks
local floor, abs = math.floor, math.abs
local Clamp = CK.Clamp
util.AddNetworkString("resp_clock")
util.AddNetworkString("resp_sub")
util.AddNetworkString("resp_rec")

RS.Net = RS.Net or {}
local N = RS.Net
-- player -> { tokens, t, bodies = { [body] = what was sent last } }
local subs = setmetatable({}, { __mode = "k" })
N.subs = subs
N.stats = N.stats or { clocks = 0, clockBytes = 0, asked = 0, refused = 0, recs = 0, recBytes = 0 }

local function SendClock(ply, r, now, sure)
	local c = r.clock
	local body = Z.Body(ply)
	if not IsValid(body) then return end
	-- (a change that must not be missed goes the sure way; the rest may be lost: the next one is near)
	net.Start("resp_clock", not sure)
	net.WriteUInt(ply:EntIndex(), 8)
	net.WriteUInt(c.mode, 2)
	net.WriteBool(c.sym == true)
	net.WriteUInt(floor(CK.PhaseAt(c, now) * 1024) % 1024, 10)
	net.WriteUInt(Clamp(floor(c.rate * 4 + 0.5), 0, 255), 8)
	net.WriteUInt(Clamp(floor(c.depth * 20 + 0.5), 0, 63), 6)
	-- the game time it is true of, within some 68 minutes and to a thousandth of a second
	net.WriteUInt(floor((now % 4096) * 1024) % 4194304, 22)
	N.stats.clockBytes = N.stats.clockBytes + net.BytesWritten()
	net.SendPVS(body:WorldSpaceCenter())
	N.stats.clocks = N.stats.clocks + 1
	local s = r.sent
	if not s then s = {} r.sent = s end
	s.t, s.rate, s.depth, s.ver = now, c.rate, c.depth, r.ver
end

-- What is sent of a record, as whole numbers; and those as one string, to tell a change by.
local WHY = { ["grip"] = 1, ["vomit"] = 2, ["water"] = 3, ["no air enters"] = 4, ["shut"] = 5 }
local function B8(v) return Clamp(floor((v or 0) * 255 + 0.5), 0, 255) end
local function Pack(r)
	local s, c = r.s, r.clock
	return {
		RS.LabelIdx[r.label] or 1, c.mode, B8(s.patency), s.blocked and 1 or 0, WHY[s.blockedWhy or ""] or 0, B8(s.trachea),
		B8(s.damageL), B8(s.breachL), B8(s.collapseL), B8(s.shareL), B8(s.damageR), B8(s.breachR), B8(s.collapseR), B8(s.shareR),
		B8(s.pneumothorax), B8(s.needle), B8(s.ventilation), B8(s.oxygen), B8(s.ceiling), B8(r.target.want),
		r.control and Clamp(floor(r.control * 254 + 0.5), 0, 254) or 255, Clamp(r.pattern or 0, 0, 15), r.follows == "brain" and 1 or 0,
		Clamp(floor(r.target.rate * 4 + 0.5), 0, 255), Clamp(floor(r.target.depth * 20 + 0.5), 0, 63), Clamp(table.Count(r.mods), 0, 15),
	}
end
N.BITS = { 4, 2, 8, 1, 3, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 1, 8, 6, 4 }

local function SendRec(ply, body, vals)
	net.Start("resp_rec")
	net.WriteUInt(body:EntIndex(), 13)
	net.WriteBool(vals ~= nil)
	if vals then for i, bits in ipairs(N.BITS) do net.WriteUInt(vals[i], bits) end end
	N.stats.recBytes = N.stats.recBytes + net.BytesWritten()
	net.Send(ply)
	N.stats.recs = N.stats.recs + 1
end

local function RecOf(body)
	local r = RS.RecordOf(body)
	if not r then return nil, "" end
	local vals = Pack(r)
	return vals, table.concat(vals, ",")
end

net.Receive("resp_sub", function(_, ply)
	if not IsValid(ply) then return end
	local ent = Entity(net.ReadUInt(13))
	local on = net.ReadBool()
	N.stats.asked = N.stats.asked + 1
	if not RS.Active() or not RS.DevAllowed(ply) then N.stats.refused = N.stats.refused + 1 return end
	local s = subs[ply]
	local now = CurTime()
	if not s then s = { tokens = C.Net.burst, t = now, bodies = {} } subs[ply] = s end
	s.tokens = math.min(C.Net.burst, s.tokens + (now - s.t) * C.Net.rate)
	s.t = now
	if not IsValid(ent) then return end
	if not on then s.bodies[ent] = nil return end
	if s.tokens < 1 then N.stats.refused = N.stats.refused + 1 return end
	s.tokens = s.tokens - 1
	local vals, sig = RecOf(ent)
	s.bodies[ent] = sig
	SendRec(ply, ent, vals)
end)

local nextRecs = 0
timer.Create("RS_NetFlush", C.Net.every, 0, function()
	if not RS.Active() then return end
	local now = CurTime()
	local NC = C.Net
	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		local r = istable(org) and K.Of(org)
		if r and now - r.stepped < 1 then
			local s, c = r.sent, r.clock
			if not s or s.ver ~= r.ver then
				SendClock(ply, r, now, true)
			elseif c.mode == CK.BREATHING and (abs(c.rate - s.rate) >= NC.rateStep or abs(c.depth - s.depth) >= NC.depthStep or now - s.t >= NC.keep) then
				SendClock(ply, r, now, false)
			elseif c.mode == CK.HELD and now - s.t >= NC.keep then
				SendClock(ply, r, now, false)
			elseif c.mode == CK.STOPPED and ply:Alive() and now - s.t >= NC.keep * 4 then
				-- (a living character whose breath has stopped: said again now and then, for whoever comes to see it)
				SendClock(ply, r, now, false)
			end
		end
	end
	if now < nextRecs then return end
	nextRecs = now + NC.recEvery
	for ply, s in pairs(subs) do
		if not IsValid(ply) or not RS.DevAllowed(ply) then
			subs[ply] = nil
		else
			for body, sent in pairs(s.bodies) do
				if not IsValid(body) then
					s.bodies[body] = nil
				else
					local vals, sig = RecOf(body)
					if sig ~= sent then
						s.bodies[body] = sig
						SendRec(ply, body, vals)
					end
				end
			end
		end
	end
end)

-- A client that has only now come to see a character is told within a couple of seconds by the
-- clock's regular sending; one that has just joined is told of everybody at once.
hook.Add("PlayerInitialSpawn", "RS_Net", function(ply)
	timer.Simple(5, function()
		if not IsValid(ply) or not RS.Active() then return end
		for _, p in ipairs(player.GetAll()) do
			local r = istable(p.organism) and K.Of(p.organism)
			if r then r.sent = nil end
		end
	end)
end)

hook.Add("PlayerDisconnected", "RS_Net", function(ply) subs[ply] = nil end)
