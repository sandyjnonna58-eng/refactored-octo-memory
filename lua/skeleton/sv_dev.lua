-- Server: developer commands. All need skel_dev 1 and a superadmin (or the listen server's host,
-- or the console).
--
--   skel_status                         what the module holds
--   skel_records [target]               a character's record
--   skel_injure <target> <bone> [state] [integrity]    writes a record (state: a name or 0..5)
--   skel_joint <target> <joint> [0|1]   a joint's state
--   skel_heal <target> [bone]           clears one bone, or everything
--   skel_trace [target]                 what the line of the caller's aim meets in the target's body
-- target: self | aim | bot | part of a name | an entity's number

local SK = HemoSkeleton
local C, I, RC = SK.Config, SK.Injury, SK.Records
SK.Dev = SK.Dev or {}
local D = SK.Dev

local function Reply(ply, fmt, ...)
	local s = "[Skeleton] " .. string.format(fmt, ...)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else print(s) end
end
D.Reply = Reply

-- The body a token means.
function D.Target(caller, token)
	token = token or "aim"
	if token == "self" then return IsValid(caller) and SK.BodyOf(caller) or nil end
	if token == "bot" then local b = player.GetBots()[1] return IsValid(b) and SK.BodyOf(b) or nil end
	if tonumber(token) then
		local e = Entity(tonumber(token))
		return IsValid(e) and SK.BodyOf(e) or nil
	end
	if token == "aim" then
		if not IsValid(caller) then return nil end
		local e = caller:GetEyeTrace().Entity
		if IsValid(e) and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) then return SK.BodyOf(e) end
		return SK.BodyOf(caller)
	end
	for _, p in ipairs(player.GetAll()) do
		if string.find(string.lower(p:Nick()), string.lower(token), 1, true) then return SK.BodyOf(p) end
	end
	return nil
end

local function StateOf(token)
	if tonumber(token) then return math.Clamp(math.floor(tonumber(token)), 0, 5) end
	local s = C.State[string.upper(tostring(token or "fracture"))]
	return s
end

concommand.Add("skel_status", function(ply)
	if not SK.DevAllowed(ply) then return end
	local chars, bones = I.Count()
	local z = SK.ZC.stats
	Reply(ply, "records of %d character(s), %d bone(s); written %d, cleared %d, handed to a corpse %d, dropped %d", chars, bones, RC.stats.set, RC.stats.cleared, RC.stats.handed, RC.stats.dropped)
	Reply(ply, "Z-City: %d hits placed (%d crossed a bone, %d took the nearest), %d booked as an injury, %d not booked by Z-City, %d changes with no hit to place them", z.located, z.crossed, z.nearest, z.booked, z.unbooked, z.regions)
	local n = SK.Net.stats
	Reply(ply, "clients: asked %d time(s), refused %d, sent %d message(s), %d bytes", n.asked, n.refused, n.sent, n.bytes)
end, nil, "Skeleton: what the module holds (superadmin, skel_dev 1)")

-- A record as lines of text.
function D.Describe(who)
	local rec, char = I.Get(who)
	local lines = {}
	if not rec then return { string.format("%s: no record (every bone intact as far as is known)", tostring(char or who)) } end
	lines[#lines + 1] = string.format("%s: version %d, %d bone(s)", tostring(char), rec.ver, rec.n)
	local list = {}
	for idx in pairs(rec.bones) do list[#list + 1] = idx end
	table.sort(list)
	for _, idx in ipairs(list) do
		local e, b = rec.bones[idx], SK.BoneByIdx[idx]
		lines[#lines + 1] = string.format("  %-16s #%-3d %-10s integrity %3d%s%s%s  from %s%s", b.id, idx, C.StateName[e.state], e.integrity,
			e.site and string.format("  at %.2f of its length", e.site) or "", e.at and string.format("  at side %.1f face %.1f up %.1f", e.at[1], e.at[2], e.at[3]) or "",
			bit.band(e.flags, C.Flag.APPROX) ~= 0 and "  (nearest bone to the path)" or "", e.src,
			e.cause and e.cause.field and string.format(" (Z-City's %s %.2f)", e.cause.field, e.cause.value or 0) or "")
	end
	for jid, j in pairs(rec.joints) do lines[#lines + 1] = string.format("  joint %-22s %s  from %s", jid, j.state == C.JointState.DISLOCATED and "dislocated" or tostring(j.state), j.src) end
	for key, r in pairs(rec.regions) do lines[#lines + 1] = string.format("  Z-City's %s is %.2f", key, r.value) end
	return lines
end

concommand.Add("skel_records", function(ply, _, args)
	if not SK.DevAllowed(ply) then return end
	local body = D.Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	for _, l in ipairs(D.Describe(body)) do Reply(ply, "%s", l) end
end, nil, "Skeleton: a character's record (superadmin, skel_dev 1). skel_records [self | aim | bot | name | entity]")

concommand.Add("skel_injure", function(ply, _, args)
	if not SK.DevAllowed(ply) then return end
	local body = D.Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	local id = string.lower(args[2] or "")
	if not SK.Bones[id] then return Reply(ply, "no bone %q (skel_list on the client lists them)", id) end
	local state = StateOf(args[3])
	if not state then return Reply(ply, "no state %q: intact bruised fissure fracture comminuted lost", tostring(args[3])) end
	local e = I.Set(body, id, { state = state, integrity = tonumber(args[4]), site = 0.5 }, "manual")
	Reply(ply, "%s of %s: %s", id, tostring(body), e and C.StateName[e.state] or "cleared")
end, nil, "Skeleton: write a record (superadmin, skel_dev 1). skel_injure <target> <bone> [state] [integrity]")

concommand.Add("skel_joint", function(ply, _, args)
	if not SK.DevAllowed(ply) then return end
	local body = D.Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	local jid = string.lower(args[2] or "")
	if not SK.Joints[jid] then return Reply(ply, "no joint %q", jid) end
	local j = I.SetJoint(body, jid, tonumber(args[3]) or 1, "manual")
	Reply(ply, "%s of %s: %s", jid, tostring(body), j and "dislocated" or "sound")
end, nil, "Skeleton: a joint's state (superadmin, skel_dev 1). skel_joint <target> <joint> [0|1]")

concommand.Add("skel_heal", function(ply, _, args)
	if not SK.DevAllowed(ply) then return end
	local body = D.Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	local id = args[2] and string.lower(args[2]) or nil
	if id and not SK.Bones[id] then return Reply(ply, "no bone %q", id) end
	Reply(ply, "%d entr%s cleared", I.Clear(body, id), "y / ies")
end, nil, "Skeleton: clear a bone's record, or all (superadmin, skel_dev 1). skel_heal <target> [bone]")

-- What a line meets in a body, as lines of text (the server's own answer: its bones, its proxies).
function D.TraceText(body, a, b)
	local hits, why = SK.Trace(body, a, b)
	if not hits then return { "no skeleton on this body: " .. tostring(why) } end
	local len = (b - a):Length()
	local lines = { string.format("%d bone(s) on %.1f units of path through %s", #hits, len, tostring(body)) }
	for _, h in ipairs(hits) do
		lines[#lines + 1] = string.format("  %-16s #%-3d in at %5.1f out at %5.1f units%s", h.id, h.idx, h.tIn * len, h.tOut * len,
			h.kind == "shell" and string.format("  (skull, %s, assumed %.2f thick)", h.exit and "left by it" or "entered by it", h.thick) or "")
	end
	return lines
end

concommand.Add("skel_trace", function(ply, _, args)
	if not SK.DevAllowed(ply) or not IsValid(ply) then return end
	local body = D.Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	local a = ply:EyePos()
	local b = a + ply:GetAimVector() * 400
	for _, l in ipairs(D.TraceText(body, a, b)) do Reply(ply, "%s", l) end
end, nil, "Skeleton: what the line of your aim meets in a body (superadmin, skel_dev 1). skel_trace [target]")
