-- Z-City compatibility, client side: with the takeover on (abl_zcity_takeover, default 1)
-- AdvancedBlood is the only blood on screen. (The server side is server/sv_compat.lua; every
-- Z-City lookup goes through sh_zcity.lua; all of it is described in docs/ZCITY_INTEGRATION.md.)
--
-- Z-City's physiology is not touched: its wound think still runs (it also drives the heartbeat and
-- the breathing), its wound lists, pulse and blood volume are what ABL bleeds from. What is taken
-- over is how the bleeding looks. Z-City draws blood in one way only, canned particles kept in two
-- lists (hg.bloodparticles1, the drops, and hg.bloodparticles2, the clouds) that it moves, draws
-- and turns into engine decals where they land. They get there
--
--   * from its wound think (hook "Player-Ragdoll think" / "organism-think-client-blood"): drips
--     from every wound, arterial spurts, the fountain of a headless body. The think is wrapped;
--     while it runs, the particles it asks for are swallowed (ABL bleeds those wounds itself);
--   * from other callers of hg.addBloodPart / hg.addBloodPart2: wrapped, turned into ABL drops
--     (clouds are left out);
--   * from net messages: "hg_bloodimpact" (spray at a bullet's entry; ABL's abl_hit carries the
--     same hit), "bloodsquirt" (250 particles out of a head wound; the wound ABL made of that hit
--     bleeds as its vessels and the pulse allow), "bloodsquirt2" (blood coughed or vomited up:
--     becomes ABL drops from the mouth). Their receivers are replaced;
--   * from functions local to Z-City's files that no wrapper reaches: the burst of an amputation
--     (hook HG_OrganismChanged) and of a head coming off (net "addfountain"). For these, and for
--     whatever a later Z-City version adds, the two lists themselves are emptied before every
--     frame is drawn: a burst's blobs become ABL drops, everything else is dropped. Nothing of
--     Z-City's is on screen for even one frame, and none of its decals is stamped.
--
-- With the convar at 0 every wrapper passes straight through to the original function and the
-- lists are left alone. abl_zcity_status prints what is in place and what was caught.

ABL.NoJIT()
ABL.Compat = ABL.Compat or {}
local CP = ABL.Compat
local C, N, Z = ABL.Config, ABL.Net, ABL.ZC

-- (lua refresh: what the previous load of this file put in place comes off first)
if CP.Uninstall then pcall(CP.Uninstall) end

local suppress = false
CP.installed = false
CP.recv = {}
CP.stat = CP.stat or {}
local stat = CP.stat
for _, k in ipairs({ "swallowed", "adopted", "clouds", "impacts", "squirts", "coughs", "bursts", "drained",
	"zDrawn", "zDecals", "leakDrawn", "leakDecals", "rewraps" }) do
	stat[k] = stat[k] or 0
end

local function Takeover()
	return C.cl.takeover:GetBool() and ABL.Enabled()
end
CP.Takeover = Takeover

------------------------------------------------------------------------------------------
-- Z-City's particles as ABL drops
------------------------------------------------------------------------------------------
-- (Z-City's velocities are already in units per second)
local function Adopt(pos, vel, artery)
	local vol = (artery and 0.05 or 0.025) * math.Rand(0.6, 1.4)
	ABL.Drops.Spawn(pos.x, pos.y, pos.z, vel.x, vel.y, vel.z, vol, nil, 1, artery and 1 or 0)
	stat.adopted = stat.adopted + 1
end

-- One blob of a burst (a limb or a head coming off).
local function Burst(pos, vel)
	local v = C.ZCity.burstVol
	ABL.Drops.Spawn(pos.x, pos.y, pos.z, vel.x, vel.y, vel.z, math.Rand(v[1], v[2]), nil, 1, 0)
	stat.bursts = stat.bursts + 1
end

-- A short spray back along a shot, for a server that sends no abl_hit (abl_net_hits 0).
local sprayRng
local function Spray(pos, dir, amt)
	if not (isvector(pos) and isvector(dir)) or not ABL.InWorld(pos.x, pos.y, pos.z) then return end
	local dx, dy, dz = ABL.Norm(-dir.x, -dir.y, -dir.z)
	if dx == 0 and dy == 0 and dz == 0 then return end
	sprayRng = sprayRng or ABL.RNG(1977)
	local n = math.Clamp(math.floor(tonumber(amt) or 1), 1, 8) * 4
	for _ = 1, n do
		local cx, cy, cz = ABL.Emission.Cone(sprayRng, dx, dy, dz, 0.3)
		local s = sprayRng:Range(60, 220)
		ABL.Drops.Spawn(pos.x + dx * 2, pos.y + dy * 2, pos.z + dz * 2, cx * s, cy * s, cz * s, sprayRng:Range(0.02, 0.06), nil, 1, 0)
	end
end

------------------------------------------------------------------------------------------
-- Z-City's wound think and its two particle functions, wrapped. Each wrapper keeps the function it
-- wraps to itself. Z-City may put its own functions back (its files are loaded again, a round
-- restarts its hooks): the takeover would then be lost without a word, and every wound would bleed
-- twice, Z-City's canned drips next to ABL's blood. So this is looked at again now and then
-- (Watch, below), and whatever is not wrapped any more is wrapped again.
------------------------------------------------------------------------------------------
local function WrapThink()
	local set = hook.GetTable()["Player-Ragdoll think"]
	local woundThink = set and set["organism-think-client-blood"]
	if not isfunction(woundThink) then return false end
	if woundThink == CP.wrapThink then return true end
	local orig = woundThink
	CP.origWoundThink = orig
	CP.wrapThink = function(...)
		if not Takeover() then return orig(...) end
		suppress = true
		local ok, err = pcall(orig, ...)
		suppress = false
		if not ok then ErrorNoHalt("[AdvancedBlood] Z-City wound think error: " .. tostring(err) .. "\n") end
	end
	hook.Add("Player-Ragdoll think", "organism-think-client-blood", CP.wrapThink)
	return true
end

local function WrapAdd()
	if not istable(hg) then return end
	if isfunction(hg.addBloodPart) and hg.addBloodPart ~= CP.wrapAdd then
		local orig = hg.addBloodPart
		CP.origAdd = orig
		CP.wrapAdd = function(pos, vel, mat, w, h, artery, kishki, owner, ...)
			if Takeover() and isvector(pos) and isvector(vel) then
				if suppress then
					stat.swallowed = stat.swallowed + 1
				elseif kishki then
					Burst(pos, vel)
				else
					Adopt(pos, vel, artery)
				end
				return
			end
			return orig(pos, vel, mat, w, h, artery, kishki, owner, ...)
		end
		hg.addBloodPart = CP.wrapAdd
	end
	if isfunction(hg.addBloodPart2) and hg.addBloodPart2 ~= CP.wrapAdd2 then
		local orig2 = hg.addBloodPart2
		CP.origAdd2 = orig2
		-- (clouds: mist at a hit, blood in water. ABL's drops make their own where they meet water)
		CP.wrapAdd2 = function(...)
			if Takeover() then
				stat.clouds = stat.clouds + 1
				return
			end
			return orig2(...)
		end
		hg.addBloodPart2 = CP.wrapAdd2
	end
end

------------------------------------------------------------------------------------------
-- Net receivers of Z-City's blood messages, replaced. fn(orig, len, ply) decides what becomes of
-- one message; the original receiver is kept and called while the takeover is off.
------------------------------------------------------------------------------------------
local RECEIVERS = {}

local function Replace(name)
	local fn = RECEIVERS[name]
	local cur = net.Receivers and net.Receivers[name]
	if not isfunction(cur) then return false end
	local r = CP.recv[name]
	if r and r.wrap == cur then return true end
	local orig = cur
	local wrap = function(len, ply) return fn(orig, len, ply) end
	CP.recv[name] = { orig = orig, wrap = wrap }
	net.Receive(name, wrap)
	return true
end

-- Entry-wound spray: abl_hit carries the same event with bone-space positions and the exit.
RECEIVERS["hg_bloodimpact"] = function(orig, len, ply)
	if not Takeover() then return orig(len, ply) end
	stat.impacts = stat.impacts + 1
	if C.sv.netHits:GetBool() then return end
	local pos, dir = net.ReadVector(), net.ReadVector()
	net.ReadFloat()
	Spray(pos, dir, net.ReadInt(8))
end

-- Head squirt: on some headshots Z-City sprays 250 of its own particles out of the entry and the
-- exit for two and a half seconds (they stamp engine blood decals where they land). The wound ABL
-- made of that hit already bleeds as its vessels and the pulse allow.
RECEIVERS["bloodsquirt"] = function(orig, len, ply)
	if not Takeover() then return orig(len, ply) end
	stat.squirts = stat.squirts + 1
end

-- Blood coughed or vomited up (a lung or stomach wound, bleeding inside): the same event, as ABL
-- droplets out of the mouth (cl_emission.lua) instead of Z-City's particles.
RECEIVERS["bloodsquirt2"] = function(orig, len, ply)
	if not Takeover() then return orig(len, ply) end
	stat.coughs = stat.coughs + 1
	local ent = net.ReadEntity()
	if not IsValid(ent) then return end
	local boneName = net.ReadString()
	local m = net.ReadMatrix()
	local pos = net.ReadVector()
	local dir = net.ReadVector()
	local owner = isfunction(hg.RagdollOwner) and hg.RagdollOwner(ent) or nil
	local ok, err = pcall(ABL.Emission.Cough, IsValid(owner) and owner or ent, boneName, m, pos, dir)
	if not ok then ErrorNoHalt("[AdvancedBlood] cough: " .. tostring(err) .. "\n") end
end

local function WrapReceivers()
	for name in pairs(RECEIVERS) do Replace(name) end
end

------------------------------------------------------------------------------------------
-- Z-City's particle lists, emptied before every frame is drawn (see the head of this file). The
-- same hook keeps count of what Z-City shows all the same: particles that are in its lists when it
-- draws, and decals its particle code stamps (hg.bloodcount is Z-City's own counter of them).
-- With the takeover on both must stay at nothing; abl_zcity_status reports them.
------------------------------------------------------------------------------------------
local ADOPT_MAX = 48 -- burst blobs turned into drops per frame; more than that are dropped
local lastCount, lastOn

local function Lists()
	if not istable(hg) then return nil, nil end
	local a, b = hg.bloodparticles1, hg.bloodparticles2
	return istable(a) and a or nil, istable(b) and b or nil
end

local function Drain()
	local t1, t2 = Lists()
	if not t1 and not t2 then return end
	local on = Takeover()
	-- decals Z-City's particle code has stamped since the last frame (it stamps while it draws:
	-- they belong to the state the takeover was in then)
	local bc = tonumber(hg.bloodcount) or 0
	if lastCount and bc > lastCount then
		stat.zDecals = stat.zDecals + (bc - lastCount)
		if lastOn then
			stat.leakDecals = stat.leakDecals + (bc - lastCount)
			stat.lastLeak = RealTime()
		end
	end
	lastCount, lastOn = bc, on
	if not on then return end
	if t1 then
		local n = #t1
		local left = ADOPT_MAX
		for i = 1, n do
			local p = t1[i]
			t1[i] = nil
			if istable(p) and p.kishki and left > 0 and isvector(p[2]) and isvector(p[3]) then
				left = left - 1
				Burst(p[2], p[3])
			else
				stat.drained = stat.drained + 1
			end
		end
	end
	if t2 then
		local n = #t2
		for i = 1, n do t2[i] = nil end
		stat.clouds = stat.clouds + n
	end
end

local function Witness(depth, skybox)
	if depth or skybox then return end
	local t1, t2 = Lists()
	local n = (t1 and #t1 or 0) + (t2 and #t2 or 0)
	if n == 0 then return end
	stat.zDrawn = stat.zDrawn + n
	if Takeover() then
		stat.leakDrawn = stat.leakDrawn + n
		stat.lastLeak = RealTime()
	end
end

------------------------------------------------------------------------------------------
-- Install, keep in place, take off
------------------------------------------------------------------------------------------
local function Install()
	if CP.installed then return true end
	if not Z.Present() then return false end
	-- (a Z-City without one of these is taken as it is: the lists are emptied whatever fills them)
	local think = WrapThink()
	WrapAdd()
	WrapReceivers()
	hook.Add("PreRender", "ABL_CompatDrain", Drain)
	hook.Add("PostDrawTranslucentRenderables", "ABL_CompatWitness", Witness)
	CP.installed = true
	ABL.Print("Z-City integration installed (takeover %s%s)", Takeover() and "on" or "off", think and "" or "; Z-City's wound think was not found")
	return true
end
CP.Install = Install

function CP.Uninstall()
	local set = hook.GetTable()["Player-Ragdoll think"]
	if CP.wrapThink and set and set["organism-think-client-blood"] == CP.wrapThink and CP.origWoundThink then
		hook.Add("Player-Ragdoll think", "organism-think-client-blood", CP.origWoundThink)
	end
	if istable(hg) then
		if CP.wrapAdd and hg.addBloodPart == CP.wrapAdd then hg.addBloodPart = CP.origAdd end
		if CP.wrapAdd2 and hg.addBloodPart2 == CP.wrapAdd2 then hg.addBloodPart2 = CP.origAdd2 end
	end
	for name, r in pairs(CP.recv or {}) do
		if net.Receivers and net.Receivers[name] == r.wrap then net.Receive(name, r.orig) end
	end
	hook.Remove("PreRender", "ABL_CompatDrain")
	hook.Remove("PostDrawTranslucentRenderables", "ABL_CompatWitness")
	CP.wrapThink, CP.wrapAdd, CP.wrapAdd2, CP.recv = nil, nil, nil, {}
	CP.installed = false
end

hook.Add("InitPostEntity", "ABL_CompatInstall", function()
	if Install() then return end
	timer.Create("ABL_CompatRetry", 1, 30, function()
		if Install() then timer.Remove("ABL_CompatRetry") end
	end)
end)
hook.Add("HomigradRun", "ABL_CompatInstall", function() timer.Simple(0, Install) end)

-- The wrappers are still in place? (see WrapThink) A few times at most: something that keeps
-- putting its own function back is left alone after that, and abl_zcity_status says so.
local REWRAP_MAX = 8
local function InPlace()
	if not istable(hg) then return true end
	local set = hook.GetTable()["Player-Ragdoll think"]
	local think = set and set["organism-think-client-blood"]
	if isfunction(think) and think ~= CP.wrapThink then return false end
	if isfunction(hg.addBloodPart) and hg.addBloodPart ~= CP.wrapAdd then return false end
	if isfunction(hg.addBloodPart2) and hg.addBloodPart2 ~= CP.wrapAdd2 then return false end
	for name in pairs(RECEIVERS) do
		local cur = net.Receivers and net.Receivers[name]
		local r = CP.recv[name]
		if isfunction(cur) and not (r and r.wrap == cur) then return false end
	end
	return true
end

local function Watch()
	if not CP.installed or stat.rewraps >= REWRAP_MAX then return end
	if InPlace() then return end
	stat.rewraps = stat.rewraps + 1
	WrapThink()
	WrapAdd()
	WrapReceivers()
	ABL.Print("Z-City integration put back in place (%d)", stat.rewraps)
end
timer.Create("ABL_CompatWatch", 5, 0, Watch)
if IsValid(LocalPlayer()) then timer.Simple(0, Install) end -- lua refresh

------------------------------------------------------------------------------------------
-- abl_zcity_status
------------------------------------------------------------------------------------------
local function State(present, ok, what)
	if not present then return "not in this Z-City" end
	if not ok then return "NOT TAKEN OVER (Z-City's own is running)" end
	if not Takeover() then return "passed through (takeover off)" end
	return what
end

-- Lines of the report, and the number of Z-City blood paths that can still draw.
function CP.Status()
	local out = {}
	local function P(s, ...) out[#out + 1] = string.format(s, ...) end
	local on = Takeover()
	local present = Z.Present()
	P("AdvancedBlood: %s (abl_enabled %d, abl_cl_enabled %d)", ABL.Enabled() and "ACTIVE" or "OFF", C.sv.enabled:GetInt(), C.cl.enabled:GetInt())
	local sig = {}
	for _, s in ipairs(Z.Signals()) do sig[#sig + 1] = (s[2] and "+" or "-") .. s[1] end
	P("Z-City: %s (gamemode %s; %s)", present and "DETECTED" or "NOT DETECTED", tostring(engine.ActiveGamemode()), table.concat(sig, " "))
	if not present then
		P("Nothing of Z-City's is touched; AdvancedBlood has no wounds to bleed from outside Z-City.")
		return out, 0
	end
	local set = hook.GetTable()["Player-Ragdoll think"]
	local think = set and set["organism-think-client-blood"]
	local t1, t2 = Lists()
	local open = 0
	local function Path(label, isThere, ok, what)
		if isThere and not ok then open = open + 1 end
		P("  %-46s %s", label, State(isThere, ok, what))
	end
	P("Takeover: %s (abl_zcity_takeover %d)%s", on and "ON" or "OFF", C.cl.takeover:GetInt(), CP.installed and "" or " - NOT INSTALLED YET")
	Path("wound drips, spurts, neck fountain (think)", isfunction(think), think == CP.wrapThink, string.format("swallowed, %d particles", stat.swallowed))
	Path("hg.addBloodPart (other callers)", isfunction(hg.addBloodPart), hg.addBloodPart == CP.wrapAdd, string.format("as AdvancedBlood drops, %d", stat.adopted))
	Path("hg.addBloodPart2 (mist, clouds in water)", isfunction(hg.addBloodPart2), hg.addBloodPart2 == CP.wrapAdd2, string.format("left out, %d", stat.clouds))
	for _, e in ipairs({ { "hg_bloodimpact", "net hg_bloodimpact (entry spray)", "abl_hit instead, %d", "impacts" },
		{ "bloodsquirt", "net bloodsquirt (head squirt)", "left out, %d", "squirts" },
		{ "bloodsquirt2", "net bloodsquirt2 (blood coughed up)", "as AdvancedBlood drops, %d", "coughs" } }) do
		local cur = net.Receivers and net.Receivers[e[1]]
		local r = CP.recv[e[1]]
		Path(e[2], isfunction(cur), r ~= nil and r.wrap == cur, string.format(e[3], stat[e[4]]))
	end
	local drainOn = hook.GetTable().PreRender ~= nil and hook.GetTable().PreRender["ABL_CompatDrain"] ~= nil
	Path("particle lists (amputation, head burst, the rest)", t1 ~= nil or t2 ~= nil, drainOn,
		string.format("emptied every frame: %d burst blobs as drops, %d dropped", stat.bursts, stat.drained))
	if stat.rewraps > 0 then P("  put back in place %d time(s)%s", stat.rewraps, stat.rewraps >= REWRAP_MAX and " - GIVEN UP, something keeps undoing it" or "") end
	local recent = stat.lastLeak ~= nil and RealTime() - stat.lastLeak < 60
	if on and recent then open = open + 1 end
	P("Z-City visual blood: %s", not on and "RUNNING (takeover off)" or (open == 0 and "SUPPRESSED" or "PARTLY RUNNING"))
	P("  Z-City particles on screen with the takeover on: %d particle-frames; Z-City decals stamped with it on: %d%s",
		stat.leakDrawn, stat.leakDecals, stat.lastLeak and string.format(" (last %.0f s ago)", RealTime() - stat.lastLeak) or "")
	P("  seen in all, takeover on or off: %d particle-frames, %d decals; in the lists now: %d", stat.zDrawn, stat.zDecals, (t1 and #t1 or 0) + (t2 and #t2 or 0))
	-- physiology: Z-City's organism, as this client has it
	local lp = LocalPlayer()
	local orgs = 0
	for _, p in ipairs(player.GetAll()) do
		if istable(p.organism) then orgs = orgs + 1 end
	end
	local org = IsValid(lp) and istable(lp.organism) and lp.organism or nil
	P("Z-City physiology: %s (organisms on this client %d%s)", orgs > 0 and "ACTIVE" or "no organism seen", orgs,
		org and string.format("; yours: blood %.0f ml, pulse %.0f", tonumber(org.blood) or 0, tonumber(org.pulse) or 0) or "")
	local nw = 0
	for _, src in ipairs(ABL.Sources.list) do nw = nw + #src.woundList end
	P("AdvancedBlood bleeding: %s (%d bleeding bodies, %d wounds, %d drops in the air)", ABL.Enabled() and "ACTIVE" or "OFF", #ABL.Sources.list, nw, ABL.Drops.Count())
	P("Duplicate visual systems: %d%s", on and open or 1, on and "" or " (the takeover is off: Z-City's blood runs next to AdvancedBlood's)")
	return out, on and open or 1
end

net.Receive(N.ZCS, function()
	local present, sup = net.ReadBool(), net.ReadBool()
	local rh = net.ReadUInt(2)
	local decal, effect = net.ReadBool(), net.ReadBool()
	local hits, decals, effects = net.ReadUInt(24), net.ReadUInt(24), net.ReadUInt(24)
	local orgs = net.ReadUInt(8)
	print(string.format("Server: Z-City %s; its blood decals and puffs are %s", present and "detected" or "NOT detected",
		sup and "SUPPRESSED" or "KEPT (abl_zcity_hitdecals 1, abl_enabled 0 or no Z-City)"))
	if present then
		print(string.format("  decals behind every bullet hit (hook)            %s, %d left out", rh == 2 and "wrapped" or (rh == 1 and "NOT WRAPPED" or "not in this Z-City"), hits))
		print(string.format("  blood decals by name (cuts, claws, gibs, charges) %s, %d left out", decal and "caught" or "something else replaced util.Decal since (ABL's part may still run inside it: watch the count)", decals))
		print(string.format("  blood puffs by name (brain hits)                  %s, %d left out", effect and "caught" or "something else replaced util.Effect since (ABL's part may still run inside it: watch the count)", effects))
		print(string.format("  physiology: %d player organisms run by Z-City", orgs))
	end
	if net.ReadBool() then
		local blood, bleed, pulse = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
		local nv, na = net.ReadUInt(8), net.ReadUInt(8)
		print(string.format("  yours on the server: blood %.0f ml, bleeding %.2f, pulse %.0f, wounds %d + %d arterial", blood, bleed, pulse, nv, na))
	end
end)

concommand.Add("abl_zcity_status", function()
	for _, line in ipairs((CP.Status())) do print(line) end
	net.Start(N.ZCS)
	net.SendToServer()
end)
