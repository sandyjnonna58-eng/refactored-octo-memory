-- Server: the wounds a character carries, kept so that a client who was not there when they
-- were made can be told of them.
--
-- A hit is sent once (sv_main.lua, abl_hit), to those who have the body in sight at that moment:
-- everything a client shows of a wound it makes from that one event. A player who comes round
-- the corner a minute later, or joins the game, never got it: to them the body bled from no
-- opening. So the server keeps what it sent, for as long as the character is there:
--   * one list for each character: a living player (whichever entity is their body just now:
--     themselves, or the ragdoll they lie in), or a corpse. A player who dies hands the list to
--     the corpse that is made of them; a player who spawns again starts with none (one whom
--     Z-City gets up from its ragdoll is spawned for that too, and keeps the list); a body that
--     is removed, or a player who leaves, takes its list along.
--   * a record is what the event was, with the place and the direction in the space of the
--     bone it struck, and the bone by its name: it can be sent again whatever the body has done
--     since, and whichever entity the body is by then.
--   * a client asks (abl_wreq) for the bodies that have come into its sight; the answer
--     (abl_wrep) is the body's records, each as the event it was and how old it is. The client
--     makes the wound from it as it makes one from a hit, without what belongs to the moment of
--     the hit alone (the spatter), and aged; a record it already has it does not make again.
-- Nothing here changes a wound, a damage or what bleeds: it is a copy of what was sent.
-- Bounds: C.WoundStore (records for one character, in all, how old, how often a client may ask).

local C, N, Z, WD = ABL.Config, ABL.Net, ABL.ZC, ABL.Wound
local SC = C.WoundStore
ABL.WoundStore = ABL.WoundStore or {}
local ST = ABL.WoundStore
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local byChar = {}       -- character -> its records, oldest first
local total = 0
-- player -> { tokens, t (what it may still ask, and as of when), [character] = when last answered }
local asked = setmetatable({}, { __mode = "k" })
ST.asked = asked
ST.stats = { kept = 0, merged = 0, dropped = 0, asked = 0, answered = 0, sent = 0, refused = 0 }

local function Log(...) if ABL.TestLog then ABL.TestLog(...) end end

local function Drop(key, why)
	local l = byChar[key]
	if not l then return end
	total = total - #l
	ST.stats.dropped = ST.stats.dropped + #l
	byChar[key] = nil
	Log("  wound store: %d record(s) of %s dropped (%s)", #l, tostring(key), why or "?")
end

-- The character an entity is the body of: a living player (for themselves and for the ragdoll
-- they lie in), or the entity itself (a corpse, an NPC). nil: not a character.
local function CharOf(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent:Alive() and ent or nil end
	if ent:IsRagdoll() then
		local owner = Z.GetOwner(ent)
		if IsValid(owner) and owner:IsPlayer() and owner:Alive() and Z.GetBody(owner) == ent then return owner end
		return ent
	end
	if ent:IsNPC() then return ent end
	return nil
end
ST.CharOf = CharOf

-- The entity that is a character's body now.
local function BodyOf(key)
	if not IsValid(key) then return nil end
	if key:IsPlayer() then
		if not key:Alive() then return nil end
		local b = Z.GetBody(key)
		return IsValid(b) and b or key
	end
	return key
end

-- A hit as it was sent (sv_main.lua SendHit: body, the bone and the places in its space, rec).
function ST.Keep(body, bone, lEntry, lExit, rec)
	if not SC or SC.perBody <= 0 then return end
	local key = CharOf(body)
	if not key then return end
	local m = body:GetBoneMatrix(bone)
	local name = body:GetBoneName(bone)
	if not m or not name or name == "" then return end
	local now = CurTime()
	local l = byChar[key]
	if rec.continued and l and #l > 0 and now - l[#l].t < 1.5 then
		-- (the same bullet again: it adds to the wound it had made, as it does on a client that
		-- saw it: cl_wounds.lua WS.Extend)
		local r = l[#l]
		r.flags = bor(r.flags, band(rec.flags or 0, bnot(WD.F.INTERMEDIATE)))
		if r.pen == WD.PEN_SOFT and rec.pen and rec.pen ~= WD.PEN_SOFT and rec.pen ~= WD.PEN_ARMOR then r.pen = rec.pen end
		r.bleed = r.bleed + (rec.bleed or 0)
		ST.stats.merged = ST.stats.merged + 1
		return
	end
	if not l then l = {} byChar[key] = l end
	l[#l + 1] = {
		t = now, boneName = name, lEntry = Vector(lEntry), lExit = lExit and Vector(lExit) or nil,
		-- (the direction with the bone: the body turns, falls and is carried about)
		ldir = WorldToLocal(rec.dir, angle_zero, vector_origin, m:GetAngles()),
		class = rec.class or 0, damage = rec.damage or 0, bleed = rec.bleed or 0, hitgroup = rec.hitgroup,
		pen = rec.pen or 0, energy = rec.energy or 0, velocity = rec.velocity or 0, diameter = rec.diameter or 0,
		range = rec.range or 0, flags = rec.flags or 0, seed = rec.seed or 0, second = rec.second and true or false,
	}
	total = total + 1
	ST.stats.kept = ST.stats.kept + 1
	-- one character's oldest go first; then, over all, the oldest character's oldest
	while #l > SC.perBody do table.remove(l, 1) total = total - 1 ST.stats.dropped = ST.stats.dropped + 1 end
	if total > SC.total then
		local oldK, oldT
		for k, kl in pairs(byChar) do
			if kl[1] and (not oldT or kl[1].t < oldT) then oldK, oldT = k, kl[1].t end
		end
		if oldK then
			table.remove(byChar[oldK], 1)
			total = total - 1
			ST.stats.dropped = ST.stats.dropped + 1
			if #byChar[oldK] == 0 then byChar[oldK] = nil end
		end
	end
end

function ST.Count(ent)
	if ent == nil then return total end
	local key = CharOf(ent) or ent
	local l = byChar[key]
	return l and #l or 0
end

------------------------------------------------------------------------------------------
-- A character's life
------------------------------------------------------------------------------------------
-- dies: the corpse Z-City makes of them carries their wounds on (it may take a moment to be there)
hook.Add("PostPlayerDeath", "ABL_WoundStore", function(ply)
	if not byChar[ply] then return end
	local function Try(n)
		if not IsValid(ply) then return end
		local l = byChar[ply]
		if not l or ply:Alive() then return end
		local corpse = Z.GetCorpse(ply)
		if IsValid(corpse) then
			local cl = byChar[corpse]
			if cl then
				-- (hits the corpse took before this ran: they are the newer ones)
				for i = 1, #cl do l[#l + 1] = cl[i] end
				while #l > SC.perBody do table.remove(l, 1) total = total - 1 end
			end
			byChar[corpse] = l
			byChar[ply] = nil
			Log("  wound store: %d record(s) of %s are its corpse's now (%s)", #l, tostring(ply), tostring(corpse))
		elseif n < 20 then
			timer.Simple(0.1, function() Try(n + 1) end)
		end
	end
	Try(0)
end)
-- lives again: a new body. (Z-City gets a player up from its ragdoll by spawning them anew, with its
-- hook "Fake Up" first, in the same call: that is the same life, and the list stays.)
local gotUp = setmetatable({}, { __mode = "k" })
hook.Add("Fake Up", "ABL_WoundStore", function(ply) if IsValid(ply) then gotUp[ply] = engine.TickCount() end end)
-- The clients are told of the new life (abl_life): what they hold of the old body's blood, its
-- wound marks and its film, does not belong on the new one. They cannot tell by themselves:
-- Z-City's own hook "Player Spawn" on a client is not run for a get-up, and, for a player who has
-- once been got up, for no spawn after that either (its flag for the get-up is taken back only
-- inside that hook). Measured: a player spawned anew while alive kept the bullet holes and the
-- film of its last life on every client; so did the local player (scene head_life, head_host).
local told = setmetatable({}, { __mode = "k" })
local function NewLife(ply, why)
	Drop(ply, why)
	-- (a spawn comes here by both of its hooks, and by its organism being begun again: told once)
	local tick = engine.TickCount()
	if (told[ply] and tick - told[ply] <= 2) or not ABL.Enabled() then return end
	told[ply] = tick
	net.Start(N.LIFE)
	net.WriteUInt(ply:EntIndex(), 8)
	net.Broadcast()
	Log("  new life: clients told that %s begins again (%s)", tostring(ply), why)
end
local function Spawned(ply)
	if not IsValid(ply) then return end
	if gotUp[ply] and engine.TickCount() - gotUp[ply] <= 1 then return end
	NewLife(ply, "spawned")
end
-- A living player whose organism Z-City begins again without spawning it: a round that starts
-- with the survivors of the last (its zb:KillPlayers heals them and gets them up, no more). Their
-- wounds are gone, and what bled from them is the last round's. Looked at a tick later: the
-- organism is cleared as its owner dies as well, and that is no new life.
hook.Add("Org Clear", "ABL_WoundStore", function(org)
	local ply = istable(org) and org.owner or nil
	if not (IsValid(ply) and ply:IsPlayer() and ply:Alive()) then return end
	timer.Simple(0, function()
		if IsValid(ply) and ply:Alive() then NewLife(ply, "its organism was begun again") end
	end)
end)
hook.Add("PlayerSpawn", "ABL_WoundStore", Spawned)
hook.Add("Player Spawn", "ABL_WoundStore", Spawned)
hook.Add("PlayerDisconnected", "ABL_WoundStore", function(ply) Drop(ply, "left") end)
hook.Add("EntityRemoved", "ABL_WoundStore", function(ent) if byChar[ent] then Drop(ent, "removed") end end)
hook.Add("PostCleanupMap", "ABL_WoundStore", function()
	for k in pairs(byChar) do byChar[k] = nil end
	total = 0
end)
-- what is too old, and whose character is no more
timer.Create("ABL_WoundStoreSweep", 20, 0, function()
	local now = CurTime()
	for k, l in pairs(byChar) do
		if not IsValid(k) then
			total = total - #l
			byChar[k] = nil
		else
			while l[1] and now - l[1].t > SC.age do table.remove(l, 1) total = total - 1 ST.stats.dropped = ST.stats.dropped + 1 end
			if #l == 0 then byChar[k] = nil end
		end
	end
	-- (and, of who was answered about whom and when, what no longer matters)
	for _, a in pairs(ST.asked) do
		for k, v in pairs(a) do
			if k ~= "tokens" and k ~= "t" and (not IsValid(k) or now - v > 60) then a[k] = nil end
		end
	end
end)

------------------------------------------------------------------------------------------
-- A client asks
------------------------------------------------------------------------------------------
local function Answer(ply, ent)
	local key = CharOf(ent)
	local l = key and byChar[key]
	if not l or #l == 0 then return end
	local body = BodyOf(key)
	if not IsValid(body) then return end
	local a = asked[ply]
	local now = CurTime()
	if a[key] and now - a[key] < SC.again then ST.stats.refused = ST.stats.refused + 1 return end
	a[key] = now
	local n = 0
	for i = 1, #l do
		local r = l[i]
		local bone = body:LookupBone(r.boneName)
		local m = bone and bone <= 255 and body:GetBoneMatrix(bone)
		if m then
			local dir = LocalToWorld(r.ldir, angle_zero, vector_origin, m:GetAngles())
			net.Start(N.WREP)
			N.WriteHit(body, bone, r.lEntry, r.lExit, dir, r)
			net.WriteUInt(math.Clamp(math.floor(now - r.t), 0, 4095), 12)
			-- (whose body it is: a living player's, or nobody's)
			net.WriteUInt(key:IsPlayer() and math.min(key:EntIndex(), 255) or 0, 8)
			net.Send(ply)
			n = n + 1
		end
	end
	ST.stats.answered = ST.stats.answered + 1
	ST.stats.sent = ST.stats.sent + n
	Log("  wound store: %d record(s) of %s sent to %s (its body: %s)", n, tostring(key), tostring(ply), tostring(body))
end

net.Receive(N.WREQ, function(len, ply)
	if not IsValid(ply) then return end
	local n = net.ReadUInt(4)
	if not ABL.Enabled() or not C.sv.netReplay:GetBool() then return end
	-- (a few a second from one client at the most: what is over that is not answered, and the
	-- client asks again when the body comes into its sight the next time)
	local a = asked[ply]
	local now = CurTime()
	if not a then a = { tokens = SC.burst, t = now } asked[ply] = a end
	a.tokens = math.min(SC.burst, a.tokens + (now - a.t) * SC.rate)
	a.t = now
	for _ = 1, n do
		local ent = Entity(net.ReadUInt(13))
		ST.stats.asked = ST.stats.asked + 1
		if a.tokens >= 1 then
			a.tokens = a.tokens - 1
			Answer(ply, ent)
		else
			ST.stats.refused = ST.stats.refused + 1
		end
	end
end)

concommand.Add("abl_wound_store", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local chars = 0
	for _ in pairs(byChar) do chars = chars + 1 end
	local s = ST.stats
	local line = string.format("[AdvancedBlood] wound store: %d record(s) of %d character(s); kept %d, merged %d, dropped %d; asked %d time(s), answered %d with %d record(s), refused %d",
		total, chars, s.kept, s.merged, s.dropped, s.asked, s.answered, s.sent, s.refused)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
end, nil, "AdvancedBlood: what the server keeps of wounds for clients that were not there")
