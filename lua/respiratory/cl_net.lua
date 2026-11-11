-- Client: what the server has said of the breathing of the characters in sight, and how full each
-- breath is now.
--
-- A clock arrives a few times in ten seconds; between two of them this side runs it forward on
-- the game's own time, which is the server's (sh_clock.lua does the arithmetic). A new clock does
-- not move anything at once: what was shown is carried over into what is now true within half a
-- second, so that a breath that stops, begins or changes its pace does so without a jerk.
--
--   RS.CL.ClockOf(body)        the clock of the living character whose body this is, or nil
--   RS.CL.Fill(clock, now)     how full the breath is: left lung, right lung (0..1), and its depth
--   RS.CL.Record(body)         what is known to be wrong with its lungs (developer view only), or nil
--   RS.CL.Watch(body, on)      asks the server for that record, or lets it go

local RS = HemoRespiratory
local C, CK = RS.Config, RS.Clock
RS.CL = RS.CL or {}
local CL = RS.CL
CL.clocks = CL.clocks or {}       -- a player's entity number -> clock
CL.recs = CL.recs or {}           -- a body's entity number -> record
CL.watched = CL.watched or {}     -- a body's entity number -> when it was asked for
CL.stats = CL.stats or { clocks = 0, recs = 0 }
local clocks, recs = CL.clocks, CL.recs

local function Raw(c, now, lag)
	if c.mode == CK.HELD then return C.Breath.heldAt end
	if c.mode ~= CK.BREATHING then return 0 end
	return CK.Wave(c.phase + c.rate / 60 * (now - c.t) - lag, c.rate, c.sym)
end

-- The left lung a moment behind the right: two lungs, not one shape drawn twice.
-- While a new clock is being come to, what is shown is what the new clock says plus what was left
-- over from the old one at the moment it arrived, and that remainder is let go of smoothly. (It is
-- the remainder that fades, not a breath frozen at that moment: a clock that only confirms the old
-- one, as most do, then changes nothing at all. Seen in the game with the other way round: the
-- lungs stood still for an instant every two seconds and caught up.)
function CL.Fill(c, now)
	local B = C.Breath
	local vr, vl, depth = Raw(c, now, 0), Raw(c, now, B.lagLeft), c.depth
	if c.easeT then
		local k = (now - c.easeT) / B.ease
		if k >= 1 or k < 0 then
			c.easeT = nil
		else
			k = 1 - CK.Smooth(k)
			vl, vr, depth = CK.Clamp(vl + c.offL * k, 0, 1), CK.Clamp(vr + c.offR * k, 0, 1), depth + c.offDepth * k
		end
	end
	return vl, vr, depth
end

net.Receive("resp_clock", function()
	local idx = net.ReadUInt(8)
	local mode = net.ReadUInt(2)
	local sym = net.ReadBool()
	local phase = net.ReadUInt(10) / 1024
	local rate = net.ReadUInt(8) / 4
	local depth = net.ReadUInt(6) / 20
	local stamp = net.ReadUInt(22) / 1024
	local now = CurTime()
	local t = now - now % 4096 + stamp
	if t - now > 2048 then t = t - 4096 elseif now - t > 2048 then t = t + 4096 end
	local c = clocks[idx]
	local wasL, wasR, wasDepth
	if c then
		wasL, wasR, wasDepth = CL.Fill(c, now)
	else
		c = {}
		clocks[idx] = c
	end
	c.t, c.phase, c.rate, c.depth, c.mode, c.sym, c.got = t, phase, rate, depth, mode, sym, RealTime()
	c.easeT = nil
	if wasL then
		-- what was shown, less what the new clock shows at this moment: carried over, and let go of
		local offL, offR, offDepth = wasL - Raw(c, now, C.Breath.lagLeft), wasR - Raw(c, now, 0), wasDepth - depth
		if math.abs(offL) > 0.001 or math.abs(offR) > 0.001 or math.abs(offDepth) > 0.001 then
			c.offL, c.offR, c.offDepth, c.easeT = offL, offR, offDepth, now
		end
	end
	CL.stats.clocks = CL.stats.clocks + 1
end)

-- The living player a body is the body of now, or nil (a corpse, a body left behind, an NPC).
function CL.OwnerOf(body)
	if not IsValid(body) then return nil end
	local o
	if body:IsPlayer() then
		o = body
	elseif istable(hg) and isfunction(hg.RagdollOwner) then
		o = hg.RagdollOwner(body)
	end
	if not IsValid(o) or not o:IsPlayer() or not o:Alive() then return nil end
	return o
end

function CL.ClockOf(body)
	local o = CL.OwnerOf(body)
	if not o then return nil end
	local c = clocks[o:EntIndex()]
	-- (a clock nothing has been heard of for a while is no longer believed)
	if c and RealTime() - c.got > C.Net.stale and c.mode ~= CK.STOPPED then return nil end
	return c
end

------------------------------------------------------------------------------------------
-- Records (the developer view)
------------------------------------------------------------------------------------------
local WHY = { [0] = false, "grip", "vomit", "water", "no air enters", "shut" }
-- (the order and the widths are the server's: sv_net.lua, Pack and BITS)
local BITS = { 4, 2, 8, 1, 3, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 1, 8, 6, 4 }

net.Receive("resp_rec", function()
	local idx = net.ReadUInt(13)
	if not net.ReadBool() then recs[idx] = nil return end
	local v = {}
	for i, bits in ipairs(BITS) do v[i] = net.ReadUInt(bits) end
	local r = recs[idx] or {}
	recs[idx] = r
	r.label, r.mode = RS.Labels[v[1]] or "?", v[2]
	r.patency, r.blocked, r.why, r.trachea = v[3] / 255, v[4] == 1, WHY[v[5]] or nil, v[6] / 255
	r.damageL, r.breachL, r.collapseL, r.shareL = v[7] / 255, v[8] / 255, v[9] / 255, v[10] / 255
	r.damageR, r.breachR, r.collapseR, r.shareR = v[11] / 255, v[12] / 255, v[13] / 255, v[14] / 255
	r.pneumothorax, r.needle, r.exchange, r.oxygen, r.ceiling, r.want = v[15] / 255, v[16] / 255, v[17] / 255, v[18] / 255, v[19] / 255, v[20] / 255
	r.control = v[21] < 255 and v[21] / 254 or nil
	r.pattern, r.brain = v[22], v[23] == 1
	r.targetRate, r.targetDepth, r.mods = v[24] / 4, v[25] / 20, v[26]
	r.got = RealTime()
	CL.stats.recs = CL.stats.recs + 1
end)

function CL.Record(body)
	return IsValid(body) and recs[body:EntIndex()] or nil
end

function CL.Watch(body, on)
	if not IsValid(body) then return end
	local idx = body:EntIndex()
	if idx <= 0 then return end
	if on then
		-- (asked again now and then: the server forgets a body that has become another entity)
		local last = CL.watched[idx]
		if last and RealTime() - last < C.Net.askAgain then return end
		CL.watched[idx] = RealTime()
	else
		if not CL.watched[idx] then return end
		CL.watched[idx] = nil
		recs[idx] = nil
	end
	net.Start("resp_sub")
	net.WriteUInt(idx, 13)
	net.WriteBool(on)
	net.SendToServer()
end

function CL.Forget()
	for idx in pairs(CL.watched) do
		local e = Entity(idx)
		if IsValid(e) then CL.Watch(e, false) end
		CL.watched[idx] = nil
	end
	for idx in pairs(recs) do recs[idx] = nil end
end

hook.Add("EntityRemoved", "RS_Net", function(ent)
	if not IsValid(ent) then return end
	local idx = ent:EntIndex()
	if idx <= 0 then return end
	recs[idx], CL.watched[idx] = nil, nil
	if ent:IsPlayer() then clocks[idx] = nil end
end)

-- Clocks of players who are gone (the removal above is not run for every way of leaving).
timer.Create("RS_ClockSweep", 5, 0, function()
	for idx in pairs(clocks) do
		local e = Entity(idx)
		if not IsValid(e) or not e:IsPlayer() then clocks[idx] = nil end
	end
end)
