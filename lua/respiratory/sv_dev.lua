-- Server: developer commands. All need resp_dev 1 and a superadmin (or the listen server's host,
-- or the console).
--
--   resp_status                       what the module holds
--   resp_state [target]               a character's respiratory state, in words
--   resp_mod <target> <rate> <depth> [left] [right] [airway] [seconds]
--                                     asks for a change of the breathing, as another system would
--                                     (RS.Modify, source "dev"): factors; left, right, airway 0..1
--   resp_unmod [target]               takes that back
--   resp_paths                        by what way each quantity reaches each consumer
-- target: self | aim | bot | part of a name | an entity's number (the skeleton module's rule)

local RS = HemoRespiratory
local K = RS.Clocks
RS.Dev = RS.Dev or {}
local D = RS.Dev

local function Reply(ply, fmt, ...)
	local s = "[Respiratory] " .. string.format(fmt, ...)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else print(s) end
end
D.Reply = Reply

local function Target(caller, token)
	local SD = istable(HemoSkeleton) and HemoSkeleton.Dev
	if SD and SD.Target then return SD.Target(caller, token) end
	return IsValid(caller) and RS.ZC.Body(caller) or nil
end
D.Target = Target

concommand.Add("resp_status", function(ply)
	if not RS.DevAllowed(ply) then return end
	local n = 0
	for _ in pairs(K.recs) do n = n + 1 end
	local ks, ns = K.stats, RS.Net.stats
	Reply(ply, "version %s; %s; Z-City %s, brain module %s", RS.VERSION, RS.Active() and "acting" or (RS.Quiet and "quiet (a test run of another module)" or "switched off"),
		RS.ZC.Present() and "there" or "NOT THERE", RS.Brain.Available() and "loaded" or "not loaded")
	Reply(ply, "%d breathing record(s); %d step(s), %d time(s) a clock did not simply run on, %d made, %d cleared", n, ks.steps, ks.jumps, ks.made, ks.cleared)
	Reply(ply, "clients: %d clock message(s), %d bytes; records asked for %d time(s), refused %d, sent %d, %d bytes", ns.clocks, ns.clockBytes, ns.asked, ns.refused, ns.recs, ns.recBytes)
end, nil, "Respiratory: what the module holds (superadmin, resp_dev 1)")

concommand.Add("resp_state", function(ply, _, args)
	if not RS.DevAllowed(ply) then return end
	local body = Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	for _, l in ipairs(RS.Describe(body)) do Reply(ply, "%s", l) end
end, nil, "Respiratory: a character's state in words (superadmin, resp_dev 1). resp_state [self | aim | bot | name | entity]")

concommand.Add("resp_mod", function(ply, _, args)
	if not RS.DevAllowed(ply) then return end
	local body = Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	local ok, why = RS.Modify(body, "dev", { rate = tonumber(args[2]), depth = tonumber(args[3]), left = tonumber(args[4]), right = tonumber(args[5]), airway = tonumber(args[6]), ttl = tonumber(args[7]) })
	Reply(ply, "%s: %s", tostring(body), ok and "asked" or ("refused: " .. tostring(why)))
end, nil, "Respiratory: ask for a change of a character's breathing (superadmin, resp_dev 1). resp_mod <target> <rate> <depth> [left] [right] [airway] [seconds]")

concommand.Add("resp_unmod", function(ply, _, args)
	if not RS.DevAllowed(ply) then return end
	local body = Target(ply, args[1])
	if not IsValid(body) then return Reply(ply, "no such target") end
	Reply(ply, "%s: %s", tostring(body), RS.Unmodify(body, "dev") and "taken back" or "nothing was asked")
end, nil, "Respiratory: take back what resp_mod asked (superadmin, resp_dev 1). resp_unmod [target]")

concommand.Add("resp_paths", function(ply)
	if not RS.DevAllowed(ply) then return end
	for consumer, qs in pairs(RS.Paths) do
		for quantity, p in pairs(qs) do
			Reply(ply, "%s reaches %s by %s (entered by %s)%s", quantity, consumer, p.via, p.owner, p.note and (": " .. p.note) or "")
		end
	end
end, nil, "Respiratory: by what way each quantity reaches each consumer (superadmin, resp_dev 1)")
