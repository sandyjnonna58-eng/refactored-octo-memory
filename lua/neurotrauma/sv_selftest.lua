-- Test scenarios of the neurotrauma module (developer tool). They run inside the blood module's
-- harness (lua/advancedblood/server/sv_selftest.lua), which exists only when
-- garrysmod/data/abl_selftest.txt does, and only when asked for by name. See docs/TESTING.md.

local NT = NeuroTrauma
if not (istable(ABL) and istable(ABL.SelfTest)) then return end
local S = ABL.SelfTest
local Log, Wait = S.Log, S.Wait
local C, Z, I, E = NT.Config, NT.ZC, NT.Injury, NT.E
local V = Vector

NT.TestLog = Log
RunConsoleCommand("neuro_dev", "1")

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------
local captured = {}
hook.Add("NT_InjuryEvent", "NT_SelfTest", function(ply, org, ev) captured[#captured + 1] = ev end)

local function Stat(key)
	local vals = {}
	for _, ev in ipairs(captured) do vals[#vals + 1] = ev[key] or 0 end
	table.sort(vals)
	local n = #vals
	return string.format("%.1f/%.1f/%.1f", vals[1], vals[math.ceil(n / 2)], vals[n])
end

-- What the events since the last summary measured: lowest / median / highest.
local function Summary(name)
	local n = #captured
	if n == 0 then Log("  == %s: no events", name) return end
	Log("  == %s: %d events | dv %s normal %s m/s | dw %s rad/s | rot %s | contact %s | landing %s | alpha %s",
		name, n, Stat("dv"), Stat("dvn"), Stat("dOmega"), Stat("rot"), Stat("contact"), Stat("landing"), Stat("alpha"))
	captured = {}
end

local function Up(bot)
	local org = bot.organism
	if istable(org) then org.consciousness = 1 org.otrub = false end
	if IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) Wait(1.3) end
end

local function EachPhys(rag, fn)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local po = rag:GetPhysicsObjectNum(i)
		if IsValid(po) then fn(po) end
	end
end

-- A spot near `p` whose ground is of a kind (substring of the surface property name).
local function FindGround(p, pattern)
	for ring = 1, 30 do
		local r = ring * 90
		for k = 1, ring * 6 do
			local a = k / (ring * 6) * math.pi * 2
			local q = p + V(math.cos(a) * r, math.sin(a) * r, 0)
			local tr = util.TraceLine({ start = q + V(0, 0, 60), endpos = q - V(0, 0, 200), mask = MASK_PLAYERSOLID_BRUSHONLY })
			if tr.Hit and tr.HitNormal.z > 0.95 and math.abs(tr.HitPos.z - p.z) < 80 then
				local name = string.lower(util.GetSurfacePropName(tr.SurfaceProps) or "")
				if string.find(name, pattern, 1, true) then return tr.HitPos, name end
			end
		end
	end
	return nil
end

-- Every scene starts with the brain model running and nothing left over from the scene before
-- (the calibration scene pauses the model; a scene that fails half way must not leave it paused).
local function Add(name, fn)
	S.Add(name, function()
		NT.Brain.paused = nil
		if NT.Trauma then NT.Trauma.silent = nil end
		captured = {}
		fn()
	end)
end

------------------------------------------------------------------------------------------
-- Falls: what the head of a ragdoll actually does (calibration, stage 3)
------------------------------------------------------------------------------------------
Add("neuro_falls", function()
	-- (what the head does is measured here; what it does to the brain is left out, or a bot knocked
	-- out by one fall would lie through the next)
	NT.Brain.paused = true
	local p = S.FindSpot({ open = 170, outdoor = true })
	local grass, gname = FindGround(p, "grass")
	if not grass then grass, gname = FindGround(p, "dirt") end
	Log("ground: paved spot %s, soft spot %s (%s)", tostring(p), tostring(grass), tostring(gname))
	local bot = S.NewBot()
	S.Place(bot, p, 0)
	Wait(1)
	if istable(bot.organism) then bot.organism.godmode = true end
	S.View(p + V(150, 60, 70), p + V(0, 0, 30))
	local fwd, right = bot:GetForward(), bot:GetRight()

	-- o.awake: conscious as it falls; o.push: velocity given to the upper body; o.h: height of the
	-- drop; o.pose: turned upside down first (the head arrives first)
	local function Case(name, n, o)
		o = o or {}
		local spot = o.spot or p
		for rep = 1, n do
			Up(bot)
			bot:SetPos(spot + V(0, 0, 2 + ((not o.pose) and o.h or 0)))
			bot:SetLocalVelocity(vector_origin)
			Wait(0.25)
			local org = bot.organism
			if istable(org) then org.consciousness = o.awake and 1 or 0 end
			hg.Fake(bot)
			Wait(0.05)
			local rag = bot.FakeRagdoll
			if not IsValid(rag) then Log("  %s rep %d: not ragdolled", name, rep) end
			if IsValid(rag) then
				if o.pose then
					ABL.DevPose(rag, o.pose, false)
					-- the lowest point of the body (the head) starts o.h above the ground
					local low = math.huge
					EachPhys(rag, function(po) low = math.min(low, po:GetPos().z) end)
					local lift = spot.z + 8 + (o.h or 0) - low
					EachPhys(rag, function(po) po:SetPos(po:GetPos() + V(0, 0, lift)) po:SetVelocity(vector_origin) end)
				end
				if o.push then
					local head = Z.HeadPhys(rag)
					if head then head:SetVelocity(o.push) end
					local chest = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, 1))
					if IsValid(chest) then chest:SetVelocity(o.push * 0.6) end
				end
			end
			if rep == 1 then S.View(spot + V(150, 60, 70), spot + V(0, 0, 30)) end
			Wait(3.2)
		end
		Summary(name)
	end

	Case("collapse awake", 5, { awake = true })
	Case("collapse limp", 8)
	Case("collapse limp, pushed back", 5, { push = fwd * -160 })
	Case("collapse limp, pushed forward", 5, { push = fwd * 160 })
	Case("collapse limp, pushed sideways", 5, { push = right * 160 })
	Case("drop 100 limp", 3, { h = 100 })
	Case("drop 250 limp", 3, { h = 250 })
	Case("drop 500 limp", 3, { h = 500 })
	Case("head first 40", 4, { h = 40, pose = "upside" })
	Case("head first 120", 4, { h = 120, pose = "upside" })
	Case("head first 300", 3, { h = 300, pose = "upside" })
	if grass then
		Case("collapse limp on " .. gname, 6, { spot = grass })
		Case("head first 120 on " .. gname, 4, { h = 120, pose = "upside", spot = grass })
	end
	S.Shot("neuro_falls_end")
	Up(bot)
	NT.Brain.paused = nil

end)

------------------------------------------------------------------------------------------
-- Blows: what Z-City books for a blow to the head, and what the estimate makes of it
------------------------------------------------------------------------------------------
Add("neuro_blunt", function()
	local p = S.FindSpot({ open = 150, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local function Fresh()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.2)
	end
	-- travel: the way the blow moves (unit, in the head's own frame: x toward the crown, y toward
	-- the face, z toward the character's left); at: where on the head, same frame, in units
	local function Blow(name, damage, travel, at, ragdolled)
		Fresh()
		if ragdolled then hg.Fake(bot) Wait(2.5) captured = {} end
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		if not centre then Log("  %s: no head", name) return end
		local dir = (up * travel.x + face * travel.y + left * travel.z):GetNormalized()
		local pos = centre + up * at.x + face * at.y + left * at.z
		S.View(centre + (face + left * 0.6):GetNormalized() * 70 + V(0, 0, 10), centre)
		Wait(0.3)
		local d = DamageInfo()
		d:SetDamage(damage)
		d:SetDamageType(DMG_CLUB)
		d:SetAttacker(host)
		d:SetInflictor(host)
		d:SetDamagePosition(pos)
		d:SetDamageForce(dir * damage * 60)
		d:SetReportedPosition(pos - dir * 40)
		Log("  blow %s: damage %d", name, damage)
		body:TakeDamageInfo(d)
		Wait(1.5)
		Log("    after: alive %s ragdolled %s consciousness %.2f brain %.3f skull %.2f", tostring(bot:Alive()), tostring(IsValid(bot.FakeRagdoll)),
			tonumber(bot.organism and bot.organism.consciousness) or -1, tonumber(bot.organism and bot.organism.brain) or -1, tonumber(bot.organism and bot.organism.skull) or -1)
		Summary(name)
	end
	for _, dmg in ipairs({ 8, 25, 45 }) do
		Blow("front, straight " .. dmg, dmg, V(0, -1, 0), V(0.5, 3.4, 0))
		Blow("side, straight " .. dmg, dmg, V(0, 0, 1), V(0.5, 0, -3))
		Blow("back, straight " .. dmg, dmg, V(0, 1, 0), V(0.5, -3.4, 0))
		Blow("top, down " .. dmg, dmg, V(-1, 0, 0), V(3.4, 0, 0))
		Blow("hook to the jaw " .. dmg, dmg, V(0, 0, 1), V(-2.6, 2.4, -1.5))
		Blow("uppercut " .. dmg, dmg, V(1, 0, 0), V(-3, 2.6, 0))
	end
	Blow("side, on a ragdoll 25", 25, V(0, 0, 1), V(0.5, 0, -3), true)
end)

------------------------------------------------------------------------------------------
-- Bullets: the track through the head
------------------------------------------------------------------------------------------
Add("neuro_shots", function()
	local p = S.FindSpot({ open = 220, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	-- (held in place: a bullet fired by a player is checked against where its target was a moment ago)
	S.Place(bot, p, 0)
	Wait(1.5)
	-- from: where the gun is in the head's frame (x crown, y face, z left); off: aim offset from
	-- the centre of the skull in the same frame
	local function Shoot(name, ammo, from, off)
		captured = {}
		if not bot:Alive() or IsValid(bot.FakeRagdoll) then
			bot:Spawn()
			S.Place(bot, p, 0)
			Wait(2.5)
		else
			ABL.DevHeal(bot)
			Wait(0.6)
		end
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		if not centre then Log("  %s: no head", name) return end
		local fromDir = (up * from.x + face * from.y + left * from.z):GetNormalized()
		S.View(centre + (fromDir + V(0, 0, 0.25)):GetNormalized() * 60, centre)
		Wait(0.4)
		-- (the head moves with the idle animation: aim where it is now)
		centre, up, face, left = Z.HeadFrame(body)
		local aim = centre + up * off.x + face * off.y + left * off.z
		fromDir = (up * from.x + face * from.y + left * from.z):GetNormalized()
		local tr = util.TraceLine({ start = aim + fromDir * 80, endpos = aim - fromDir * 30, filter = host })
		Log("  shot %s: %s | line of fire meets %s (hitgroup %s) %.1f units from the aim point; face %s eye yaw %.0f", name, ammo, tostring(tr.Entity), tostring(tr.HitGroup), tr.HitPos:Distance(aim), tostring(face), bot:EyeAngles().y)
		ABL.DevShootAt(host, aim, fromDir, nil, 80, ammo)
		Wait(1.5)
		-- (a shot that should have hit sometimes books nothing on a bot that has just been placed:
		-- fired again, up to twice)
		for try = 1, 2 do
			if #captured > 0 or not bot:Alive() or not IsValid(tr.Entity) then break end
			Log("    nothing booked, fired again (%d)", try)
			ABL.DevShootAt(host, aim, fromDir, nil, 80, ammo)
			Wait(1.5)
		end
		Log("    after: alive %s consciousness %.2f brain %.3f skull %.2f", tostring(bot:Alive()),
			tonumber(bot.organism and bot.organism.consciousness) or -1, tonumber(bot.organism and bot.organism.brain) or -1, tonumber(bot.organism and bot.organism.skull) or -1)
		Summary(name)
	end
	local P, R = "9x19mmparabellum", "7.62x39mm"
	Shoot("front, centre, pistol", P, V(0, 1, 0), V(0.8, 0, 0))
	Shoot("front, left half, pistol", P, V(0, 1, 0), V(0.8, 0, 1.6))
	Shoot("from the right, across, pistol", P, V(0, 0, -1), V(0.8, 0, 0))
	Shoot("from the right, across, rifle", R, V(0, 0, -1), V(0.8, 0, 0))
	Shoot("from behind, low, pistol", P, V(0, -1, 0), V(-2.6, -0.5, 0))
	Shoot("from above, pistol", P, V(1, 0, 0), V(0, 0, 0.8))
	Shoot("along the crown, rifle", R, V(0, 1, 0), V(3.3, 0, 0))
	Shoot("along the temple, pistol", P, V(0, 1, 0), V(0.5, 0, 3.1))
	Shoot("jaw, pistol", P, V(0, 1, 0), V(-3.2, 0, 0))
end)

------------------------------------------------------------------------------------------
-- What the capture costs: ragdolls tumbling, hooks timed
------------------------------------------------------------------------------------------
Add("neuro_perf", function()
	-- (what the module costs when nobody reads its log: the stage report of the trauma pipeline is off)
	NT.Trauma.silent = true
	local p = S.FindSpot({ open = 260, outdoor = true })
	local bots = {}
	for i = 1, 6 do
		local bot = S.NewBot()
		if IsValid(bot) then
			S.Place(bot, p + V((i - 3.5) * 60, 0, 0), 0)
			if istable(bot.organism) then bot.organism.godmode = true end
			bots[#bots + 1] = bot
		end
	end
	Wait(1.5)
	S.View(p + V(0, 330, 160), p + V(0, 0, 40))
	local function Timed(event, id)
		local ht = hook.GetTable()[event]
		local fn = ht and ht[id]
		if not fn then return nil end
		local st = { calls = 0, total = 0, fn = fn }
		hook.Add(event, id, function(...)
			local t = SysTime()
			local a, b = fn(...)
			st.total = st.total + (SysTime() - t)
			st.calls = st.calls + 1
			return a, b
		end)
		return st
	end
	local function Run(name, seconds)
		local col, think = Timed("Ragdoll Collide", "NT_Collide"), Timed("Think", "NT_Injury")
		local n0 = I.count
		local t0 = CurTime()
		while CurTime() - t0 < seconds do
			for _, bot in ipairs(bots) do
				if not IsValid(bot.FakeRagdoll) then hg.Fake(bot) end
			end
			Wait(0.3)
			for _, bot in ipairs(bots) do
				local rag = bot.FakeRagdoll
				if IsValid(rag) then ABL.DevPose(rag, "spin") end
			end
			Wait(2.2)
		end
		local dt = CurTime() - t0
		if col then
			hook.Add("Ragdoll Collide", "NT_Collide", col.fn)
			Log("  %s: collision hook %d calls in %.1f s (%.0f /s), %.2f us per call, %.3f ms per second", name, col.calls, dt, col.calls / dt, col.total / math.max(col.calls, 1) * 1e6, col.total / dt * 1000)
		end
		if think then
			hook.Add("Think", "NT_Injury", think.fn)
			Log("  %s: think hook %d calls, %.2f us per call, %.3f ms per second; %d events", name, think.calls, think.total / math.max(think.calls, 1) * 1e6, think.total / dt * 1000, I.count - n0)
		end
	end
	Run("6 ragdolls tumbling, module on", 12)
	captured = {}
	RunConsoleCommand("neuro_enabled", "0")
	Wait(1.5)
	Run("6 ragdolls tumbling, module off", 8)
	RunConsoleCommand("neuro_enabled", "1")
	Wait(1.5)
	for _, bot in ipairs(bots) do Up(bot) end
end)

------------------------------------------------------------------------------------------
-- States: what the model writes and what Z-City then does (architecture 5.5), a lesion that
-- grows, and what real impacts lead to
------------------------------------------------------------------------------------------
Add("neuro_states", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local D = NT.Debug
	local function Fresh()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.6)
		S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	end
	local function Report(tag)
		local org = bot.organism
		if not istable(org) then Log("  [%s] no organism", tag) return end
		local st = NT.Get(org)
		Log("  [%s] %s | overlays %s | model consciousness %s | Z-City: consciousness %.2f brain %.3f otrub %s ragdolled %s alive %s heart stopped %s breathing %s",
			tag, st and string.upper(E.State.names[st.state]) or "no record", st and E.OverlayText(st.overlays) or "-",
			st and string.format("%.2f", st.consciousness) or "-", tonumber(org.consciousness) or -1, tonumber(org.brain) or -1,
			tostring(org.otrub), tostring(IsValid(bot.FakeRagdoll)), tostring(bot:Alive()), tostring(org.heartstop), tostring(org.lungsfunction))
	end

	Log("-- dazed for 4 s")
	Fresh()
	D.Set(bot, "daze", 4)
	Wait(0.5) Report("0.5 s") S.Shot("neuro_state_dazed")
	Wait(2) Report("2.5 s")
	Wait(2.5) Report("5 s")

	Log("-- knocked out for 5 s")
	Fresh()
	D.Set(bot, "knockout", 5)
	Wait(0.6) Report("0.6 s")
	Wait(2) Report("2.6 s") S.Shot("neuro_state_knockout")
	Wait(3.4) Report("6 s")
	Log("  getting up allowed: %s", tostring(hg.FakeUp(bot)))
	Wait(2) Report("8 s")
	Wait(12) Report("20 s")
	Wait(22) Report("42 s")

	Log("-- diffuse injury 0.3")
	Fresh()
	D.Set(bot, "diffuse", 0.3)
	Wait(1) Report("1 s")
	Wait(5) Report("6 s") S.Shot("neuro_state_impaired")

	Log("-- diffuse injury 0.7")
	Fresh()
	D.Set(bot, "diffuse", 0.7)
	Wait(1) Report("1 s")
	Wait(5) Report("6 s") S.Shot("neuro_state_coma")

	Log("-- a lesion growing on the left, critical in 20 minutes of a clock running 60 times faster")
	Fresh()
	RunConsoleCommand("neuro_timescale", "60")
	Wait(0.2)
	D.Set(bot, "massSide", 1)
	D.Set(bot, "massFinal", 1.25)
	D.Set(bot, "massRate", 1 / 1200)
	for i = 1, 20 do
		Wait(2)
		Report(string.format("%d s", i * 2))
		if not bot:Alive() then break end
	end
	for _, l in ipairs(D.StatusLines(bot.organism or {})) do Log("    %s", l) end
	S.Shot("neuro_state_lesion_end")
	RunConsoleCommand("neuro_timescale", "15")
	Wait(0.5)

	Log("-- real impacts: collapsing limp onto the pavement, ten times")
	local function Fall(name, n, h, pose)
		local tally = {}
		for rep = 1, n do
			Fresh()
			local org = bot.organism
			org.consciousness = 0
			bot:SetPos(p + V(0, 0, 2 + ((not pose) and h or 0)))
			hg.Fake(bot)
			Wait(0.05)
			local rag = bot.FakeRagdoll
			if IsValid(rag) and pose then
				ABL.DevPose(rag, pose, false)
				local low = math.huge
				EachPhys(rag, function(po) low = math.min(low, po:GetPos().z) end)
				local lift = p.z + 8 + h - low
				EachPhys(rag, function(po) po:SetPos(po:GetPos() + V(0, 0, lift)) po:SetVelocity(vector_origin) end)
			end
			-- (the test made the character limp; from the impact on only the injury keeps it down)
			Wait(1.6)
			if istable(bot.organism) then bot.organism.consciousness = 1 bot.organism.otrub = false end
			Wait(2.4)
			Report(string.format("%s %d", name, rep))
			local st = istable(bot.organism) and NT.Get(bot.organism)
			local key = (not bot:Alive()) and "dead" or (st and E.State.names[st.state] or "no injury")
			tally[key] = (tally[key] or 0) + 1
		end
		local parts = {}
		for k, v in pairs(tally) do parts[#parts + 1] = k .. " " .. v end
		table.sort(parts)
		Log("  == %s: %s", name, table.concat(parts, ", "))
		captured = {}
	end
	Fall("limp collapse", 10, 0)
	Fall("head first from 120", 5, 120, "upside")
	Fall("head first from 300", 4, 300, "upside")
end)

------------------------------------------------------------------------------------------
-- What each axis of a bone does to a standing character (to write the standing animation)
------------------------------------------------------------------------------------------
util.AddNetworkString("nt_test")
local function TestLayers(list)
	net.Start("nt_test")
	net.WriteUInt(#list, 4)
	for _, e in ipairs(list) do
		net.WriteString(e[1])
		net.WriteAngle(e[2])
	end
	net.Send(S.Host())
end

Add("neuro_axes", function()
	local p = S.FindSpot({ open = 150, outdoor = true })
	local bot = S.NewBot()
	S.Place(bot, p, 0)
	Wait(1.5)
	local fwd, right = bot:GetForward(), bot:GetRight()
	S.View(p + fwd * 95 + right * 45 + V(0, 0, 52), p + V(0, 0, 40))
	Wait(0.6)
	S.Shot("ax_none")
	local bones = { "Spine1", "Head1", "Neck1", "L_Clavicle", "L_UpperArm", "L_Forearm", "L_Thigh", "L_Calf" }
	local axes = { { "p", Angle(40, 0, 0) }, { "y", Angle(0, 40, 0) }, { "r", Angle(0, 0, 40) } }
	for _, b in ipairs(bones) do
		for _, a in ipairs(axes) do
			TestLayers({ { "ValveBiped.Bip01_" .. b, a[2] } })
			Wait(0.9)
			S.Shot("ax_" .. b .. "_" .. a[1])
		end
	end
	TestLayers({})
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- The postures of a ragdoll, and what an injured character looks like on its feet
------------------------------------------------------------------------------------------
Add("neuro_postures", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local D = NT.Debug
	local function Lying(pose)
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.5)
		if istable(bot.organism) then bot.organism.godmode = true end
		hg.Fake(bot)
		Wait(0.3)
		local rag = bot.FakeRagdoll
		if IsValid(rag) then ABL.DevPose(rag, pose or "back", false) end
		Wait(2.2)
		rag = bot.FakeRagdoll
		local c = IsValid(rag) and rag:GetPos() or p
		S.View(c + V(55, 35, 75), c)
		Wait(0.3)
		return rag
	end
	local function Dist(rag, a, b)
		local pa, pb = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, a)), rag:GetPhysicsObjectNum(hg.realPhysNum(rag, b))
		return (IsValid(pa) and IsValid(pb)) and pa:GetPos():Distance(pb:GetPos()) or -1
	end
	local function Measure(rag, tag)
		if not IsValid(rag) then Log("  %s: no ragdoll", tag) return end
		local st = NT.Get(bot.organism)
		Log("  %s: left hand-chest %.1f right hand-chest %.1f | left hand-pelvis %.1f right hand-pelvis %.1f | feet apart %.1f | posture %s %.2f, driven %s",
			tag, Dist(rag, 5, 1), Dist(rag, 7, 1), Dist(rag, 5, 0), Dist(rag, 7, 0), Dist(rag, 13, 14),
			st and E.Posture.names[st.postureKind] or "-", st and st.posture or 0, tostring(NT.Motor.ctlOf[rag] ~= nil))
	end

	Log("-- limp (deep unresponsiveness without brainstem stress)")
	local rag = Lying()
	D.Set(bot, "diffuse", 0.8)
	Wait(3)
	Measure(rag, "limp") S.Shot("neuro_pose_limp")

	Log("-- flexor posturing (brainstem stress 0.62)")
	rag = Lying()
	D.Set(bot, "stem", 0.62)
	Wait(1.5) Measure(rag, "flexor, appearing") S.Shot("neuro_pose_flexor_1")
	Wait(2.5) Measure(rag, "flexor, evoked") S.Shot("neuro_pose_flexor_2")
	Wait(9) Measure(rag, "flexor, at rest") S.Shot("neuro_pose_flexor_rest")
	NT.Motor.Stimulus(bot, 1)
	Wait(2.5) Measure(rag, "flexor, stimulated again") S.Shot("neuro_pose_flexor_again")

	Log("-- extensor posturing (brainstem stress 0.85)")
	rag = Lying()
	D.Set(bot, "stem", 0.85)
	Wait(1.5) Measure(rag, "extensor, appearing") S.Shot("neuro_pose_extensor_1")
	Wait(2.5) Measure(rag, "extensor, evoked") S.Shot("neuro_pose_extensor_2")

	Log("-- extensor posturing, lying on the front")
	rag = Lying("front")
	D.Set(bot, "stem", 0.85)
	Wait(4) Measure(rag, "extensor, prone") S.Shot("neuro_pose_extensor_prone")

	Log("-- forearm posture of a knockout")
	rag = Lying()
	do
		local st = NT.Brain.Ensure(bot.organism)
		local now = CurTime()
		st.locUntil, st.confusedUntil = now + 12, now + 40
		st.fencingUntil, st.fencingSeed = now + 6, 2
	end
	Wait(1.2) Measure(rag, "fencing 1.2 s") S.Shot("neuro_pose_fencing_1")
	Wait(2.5) Measure(rag, "fencing 3.7 s") S.Shot("neuro_pose_fencing_2")
	Wait(5) Measure(rag, "fencing over") S.Shot("neuro_pose_fencing_after")

	Log("-- on its feet: unsteady, then weak on the left")
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	if istable(bot.organism) then bot.organism.godmode = true end
	local fwd, right = bot:GetForward(), bot:GetRight()
	S.View(p + fwd * 95 + right * 30 + V(0, 0, 52), p + V(0, 0, 40))
	D.Set(bot, "diffuse", 0.3)
	for i = 1, 4 do Wait(0.9) S.Shot("neuro_stand_unsteady_" .. i) end
	D.Set(bot, "focalR", 0.6)
	for i = 1, 3 do Wait(0.9) S.Shot("neuro_stand_weak_left_" .. i) end
	local st = NT.Get(bot.organism)
	if st then Log("  standing: state %s motor L %.2f R %.2f balance %.2f walking speed %d/15", E.State.names[st.state], st.motorL, st.motorR, st.balance, st.moveQ or -1) end
	Log("  net: %d messages, %d bytes so far", NT.Net.messages, NT.Net.bytes)
end)

------------------------------------------------------------------------------------------
-- Seizures: the phases in order, their beat, what is left afterwards
------------------------------------------------------------------------------------------
Add("neuro_seizures", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local SZ, BR = NT.Seizure, NT.Brain
	local function Lying()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.5)
		if istable(bot.organism) then bot.organism.godmode = true end
		hg.Fake(bot)
		Wait(0.3)
		local rag = bot.FakeRagdoll
		if IsValid(rag) then ABL.DevPose(rag, "back", false) end
		Wait(2.2)
		rag = bot.FakeRagdoll
		local c = IsValid(rag) and rag:GetPos() or p
		S.View(c + V(55, 35, 75), c)
		Wait(0.3)
		return rag
	end
	-- the left hand: how high above the ground it is and how fast it moves
	local function Hand(rag, hand)
		local a = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, hand))
		if not IsValid(a) then return 0, 0 end
		return a:GetPos().z - p.z, a:GetVelocity():Length()
	end
	local function HandChest(rag, hand)
		local z, v = Hand(rag, hand)
		return { z, v }
	end
	-- follows a seizure to its end: per phase, how far the hand rises, how fast it moves, and how
	-- many separate movements it makes (its speed rising through 30 u/s)
	local function Follow(rag, st, shots)
		local series, phase = {}, nil
		local shot = {}
		local function Close()
			if not phase or #series < 4 then return end
			local lo, hi, top, beats, above = math.huge, -math.huge, 0, 0, false
			for _, s in ipairs(series) do
				local z, v = s[2][1], s[2][2]
				lo, hi, top = math.min(lo, z), math.max(hi, z), math.max(top, v)
				local a = v > 30
				if a and not above then beats = beats + 1 end
				above = a
			end
			local dur = series[#series][1] - series[1][1]
			Log("  phase %s: %.1f s | left hand %.1f .. %.1f above the ground, up to %.0f u/s | %d movements (%.1f per second) | consciousness %.2f", phase, dur, lo, hi, top, beats, beats / math.max(dur, 0.1), st.consciousness)
		end
		local t0 = CurTime()
		while st.sz and CurTime() - t0 < 120 and IsValid(rag) do
			local ph = st.sz.phase
			if ph ~= phase then
				Close()
				phase, series = ph, {}
			end
			series[#series + 1] = { CurTime(), HandChest(rag, 5) }
			local n = (shot[ph] or 0)
			if shots and n < 3 and CurTime() - st.sz.t0 > 1.5 + n * 0.14 then
				shot[ph] = n + 1
				S.Client("shot", { name = string.format("%s_%s_%d", shots, ph, n + 1) })
			end
			Wait(0.05)
		end
		Close()
	end

	Log("-- a full course: focal (left), tonic, clonic, postictal")
	local rag = Lying()
	local st = BR.Ensure(bot.organism)
	SZ.Force(bot, st, CurTime(), { { "focal", 6 }, { "tonic", 6 }, { "clonic", 14 }, { "postictal", 14 } }, 1, true)
	Follow(rag, st, "neuro_seizure")
	Log("  after: state %s overlays %s | motor L %.2f R %.2f | driven %s", E.State.names[st.state], E.OverlayText(st.overlays), st.motorL, st.motorR, tostring(NT.Motor.ctlOf[rag] ~= nil))

	Log("-- an impact convulsion: knocked out, stiffens, a short run of jerks")
	rag = Lying()
	st = BR.Ensure(bot.organism)
	do
		local now = CurTime()
		st.locUntil, st.confusedUntil = now + 14, now + 50
		st.convulsionFrom, st.convulsionUntil = now + 0.8, now + 0.8 + 9
	end
	Wait(1.2)
	Follow(rag, st, "neuro_convulsion")
	Log("  after: state %s overlays %s", E.State.names[st.state], E.OverlayText(st.overlays))

	Log("-- planned by chance: twenty seizures, what they consist of")
	do
		local tally = {}
		for i = 1, 20 do
			local fake = { focalL = 0.4, focalR = 0.1, log = {}, born = 0 }
			SZ.Start(NULL, fake, CurTime(), "early", 1000 + i * 77)
			local names = {}
			for _, s in ipairs(fake.sz.plan) do names[#names + 1] = s.phase end
			local key = table.concat(names, " > ")
			tally[key] = (tally[key] or 0) + 1
		end
		for k, v in pairs(tally) do Log("  %2d x %s", v, k) end
	end

	Log("-- on its feet: a focal seizure of the left arm that does not spread")
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	if istable(bot.organism) then bot.organism.godmode = true end
	local fwd, right = bot:GetForward(), bot:GetRight()
	S.View(p + fwd * 80 + right * 25 + V(0, 0, 55), p + V(0, 0, 45))
	st = BR.Ensure(bot.organism)
	SZ.Force(bot, st, CurTime(), { { "focal", 5 }, { "postictal", 3 } }, 1, false)
	Wait(1.5)
	for i = 1, 4 do S.Client("shot", { name = "neuro_seizure_standing_" .. i }) Wait(0.11) end
	Log("  standing focal: ragdolled %s, state %s overlays %s, consciousness %.2f", tostring(IsValid(bot.FakeRagdoll)), E.State.names[st.state], E.OverlayText(st.overlays), st.consciousness)
	Wait(7)
	Log("  after: state %s overlays %s, record %s", E.State.names[st.state], E.OverlayText(st.overlays), tostring(NT.Get(bot.organism) ~= nil))
end)

------------------------------------------------------------------------------------------
-- Breathing and cardiac arrest
------------------------------------------------------------------------------------------
Add("neuro_arrest", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local D, CR = NT.Debug, NT.CardioResp
	local function Fresh()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.6)
		S.View(p + V(110, 50, 70), p + V(0, 0, 25))
	end
	local function Report(tag)
		local org = bot.organism
		if not istable(org) then Log("  [%s] no organism", tag) return end
		local st = NT.Get(org)
		Log("  [%s] %s | %s | breathing %s, gasps %d | Z-City: consciousness %.2f brain %.3f oxygen %.1f pulse %.0f heart stopped %s lungs %s otrub %s ragdolled %s alive %s",
			tag, st and string.upper(E.State.names[st.state]) or "no record", st and E.OverlayText(st.overlays) or "-",
			st and CR.PatternNames[st.respPattern or 0] or "-", st and (st.gasps or 0) or 0,
			tonumber(org.consciousness) or -1, tonumber(org.brain) or -1, istable(org.o2) and org.o2[1] or -1, tonumber(org.pulse) or -1,
			tostring(org.heartstop), tostring(org.lungsfunction), tostring(org.otrub), tostring(IsValid(bot.FakeRagdoll)), tostring(bot:Alive()))
	end

	Log("-- breathing stops for 10 s at a knockout, then comes back")
	Fresh()
	do
		local st = NT.Brain.Ensure(bot.organism)
		local now = CurTime()
		st.locUntil, st.confusedUntil, st.apnoeaUntil = now + 14, now + 50, now + 10
	end
	for i = 1, 8 do Wait(2) Report(string.format("%d s", i * 2)) end

	Log("-- a heart stopped by Z-City for a reason of its own, in an uninjured character; restarted after 24 s")
	Fresh()
	bot.organism.heartstop = true
	for i = 1, 12 do
		Wait(2)
		-- (hold Z-City's arrest for the test: its own logic may restart or kill)
		if i < 12 then bot.organism.heartstop = true end
		Report(string.format("%d s", i * 2))
		if i == 5 then S.Shot("neuro_arrest_10s") end
		if not bot:Alive() then break end
	end
	if bot:Alive() then
		Log("  heart restarted")
		bot.organism.heartstop = false
		bot.organism.pulse = 60
		bot.organism.lungsfunction = true
		if istable(bot.organism.o2) then bot.organism.o2[1] = math.max(bot.organism.o2[1], 20) end
		for i = 1, 6 do Wait(4) Report(string.format("restart + %d s", i * 4)) end
	end

	Log("-- brainstem failure: breathing goes, then Z-City stops the heart")
	Fresh()
	D.Set(bot, "stem", 0.6)
	Wait(3) Report("stem 0.60, 3 s")
	D.Set(bot, "stem", 0.8)
	for i = 1, 4 do Wait(3) Report(string.format("stem 0.80, %d s", i * 3)) end
	D.Set(bot, "stem", 0.97)
	for i = 1, 12 do
		Wait(3)
		Report(string.format("stem 0.97, %d s", i * 3))
		if i == 3 then S.Shot("neuro_arrest_stem") end
		if not bot:Alive() then break end
	end
	if istable(bot.organism) then
		for _, l in ipairs(D.StatusLines(bot.organism)) do Log("    %s", l) end
	end
end)


------------------------------------------------------------------------------------------
-- What clients are told: the record on the listen server's client against the server's own,
-- what it costs on the wire, and that it is forgotten when the character recovers
------------------------------------------------------------------------------------------
util.AddNetworkString("nt_test2")
local function ClientCmd(cmd, arg)
	net.Start("nt_test2")
	net.WriteString(cmd)
	net.WriteString(tostring(arg or ""))
	net.Send(S.Host())
end

Add("neuro_net", function()
	local p = S.FindSpot({ open = 200, outdoor = true })
	local D = NT.Debug
	local bots = {}
	for i = 1, 3 do
		local bot = S.NewBot()
		S.Place(bot, p + V((i - 2) * 70, 0, 0), 0)
		bots[i] = bot
	end
	Wait(1.5)
	S.View(p + V(0, 230, 90), p + V(0, 0, 35))
	local function Server(tag)
		for _, bot in ipairs(bots) do
			local st = istable(bot.organism) and NT.Get(bot.organism)
			if st then
				Log("  [%s] server %s: state %d overlays %d motor L %.2f R %.2f balance %.2f consciousness %.2f walking %d/15 posture %d seizure phase %d", tag, bot:Nick(),
					st.state, st.overlays, st.motorL, st.motorR, st.balance, st.effective, st.moveQ or -1, st.postureKind, st.seizurePhase or 0)
			else
				Log("  [%s] server %s: no record", tag, bot:Nick())
			end
		end
		ClientCmd("dump", tag)
	end
	local m0, b0, t0 = NT.Net.messages, NT.Net.bytes, CurTime()
	D.Set(bots[1], "diffuse", 0.3)
	D.Set(bots[2], "focalR", 0.5)
	D.Set(bots[3], "daze", 5)
	Wait(2)
	Server("three injured, 2 s")
	ClientCmd("panel", "1")
	Wait(1.5)
	S.Shot("neuro_net_panel")
	ClientCmd("panel", "0")
	Wait(6.5)
	Server("10 s")
	local dt = CurTime() - t0
	Log("  wire: %d messages, %d bytes in %.1f s for 3 injured characters = %.1f bytes per second each", NT.Net.messages - m0, NT.Net.bytes - b0, dt, (NT.Net.bytes - b0) / dt / 3)
	-- recovery: the records are dropped on the server and forgotten by the client
	for _, bot in ipairs(bots) do
		local st = NT.Get(bot.organism)
		if st then NT.Brain.Drop(bot.organism, bot, st, "test") end
	end
	Wait(1)
	Server("after recovery, 1 s")
	Wait(4)
	Server("after recovery, 5 s")
end)

------------------------------------------------------------------------------------------
-- Living with Z-City: the takeover switch and the master switch
------------------------------------------------------------------------------------------
Add("neuro_coexist", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local function Fresh()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.6)
	end
	local function Fencing(tag)
		Fresh()
		hg.Fake(bot)
		Wait(1.5)
		local org = bot.organism
		hg.applyFencingToPlayer(bot, org)
		Wait(0.5)
		Log("  [%s] the fencing spasm of Z-City after its own trigger: %s | wrapped %s", tag, tostring(org.fencing == true), tostring(NT.ZC.wrapped))
		org.fencing, org.fencingEnd = nil, nil
	end
	Fencing("takeover on")
	RunConsoleCommand("neuro_zcity_takeover", "0")
	Wait(0.5)
	Fencing("takeover off")
	-- with takeover off the impact posturing of the model is not shown either
	do
		local st = NT.Brain.Ensure(bot.organism)
		local now = CurTime()
		st.locUntil, st.confusedUntil, st.fencingUntil, st.fencingSeed = now + 8, now + 30, now + 5, 2
		Wait(1.5)
		Log("  [takeover off] impact posturing of the model driven: %s", tostring(IsValid(bot.FakeRagdoll) and NT.Motor.ctlOf[bot.FakeRagdoll] ~= nil))
	end
	RunConsoleCommand("neuro_zcity_takeover", "1")
	Wait(0.5)

	-- the master switch: nothing is recorded, nothing is written
	local function Bat(tag)
		Fresh()
		local n0 = NT.Injury.count
		local body = Z.Body(bot)
		local centre, _, _, left = Z.HeadFrame(body)
		local d = DamageInfo()
		d:SetDamage(25)
		d:SetDamageType(DMG_CLUB)
		d:SetAttacker(S.Host())
		d:SetInflictor(S.Host())
		d:SetDamagePosition(centre - left * 3)
		d:SetDamageForce(left * 1500)
		body:TakeDamageInfo(d)
		Wait(1)
		Log("  [%s] a bat to the head: events %d, record %s, alive %s", tag, NT.Injury.count - n0, tostring(istable(bot.organism) and NT.Get(bot.organism) ~= nil), tostring(bot:Alive()))
	end
	RunConsoleCommand("neuro_enabled", "0")
	Wait(1.5)
	Bat("module off")
	RunConsoleCommand("neuro_enabled", "1")
	Wait(1.5)
	Bat("module on")
end)

------------------------------------------------------------------------------------------
-- What the whole module costs: eight characters uninjured, then all injured and moving
------------------------------------------------------------------------------------------
Add("neuro_perf2", function()
	-- (what the module costs when nobody reads its log: the stage report of the trauma pipeline is off)
	NT.Trauma.silent = true
	local p = S.FindSpot({ open = 300, outdoor = true })
	local D = NT.Debug
	local bots = {}
	for i = 1, 7 do
		local bot = S.NewBot()
		if IsValid(bot) then
			S.Place(bot, p + V((i - 4) * 55, 0, 0), 0)
			if istable(bot.organism) then bot.organism.godmode = true end
			bots[#bots + 1] = bot
		end
	end
	Wait(2)
	S.View(p + V(0, 330, 150), p + V(0, 0, 30))
	local hooks = { { "Org Think", "NT_Brain" }, { "Think", "NT_Motor" }, { "Think", "NT_Injury" }, { "Ragdoll Collide", "NT_Collide" }, { "HG_MovementCalc_2", "NT_Move" }, { "Should Fake Up", "NT_Motor" }, { "CanControlFake", "NT_Motor" } }
	local function Measure(name, seconds)
		local st = {}
		for _, h in ipairs(hooks) do
			local ht = hook.GetTable()[h[1]]
			local fn = ht and ht[h[2]]
			if fn then
				local s = { calls = 0, total = 0, fn = fn, ev = h[1], id = h[2] }
				st[#st + 1] = s
				hook.Add(h[1], h[2], function(...)
					local t = SysTime()
					local a, b = fn(...)
					s.total = s.total + (SysTime() - t)
					s.calls = s.calls + 1
					return a, b
				end)
			end
		end
		local t0, ticks0 = CurTime(), engine.TickCount()
		Wait(seconds)
		local dt, ticks = CurTime() - t0, engine.TickCount() - ticks0
		local sum = 0
		for _, s in ipairs(st) do
			hook.Add(s.ev, s.id, s.fn)
			sum = sum + s.total
			Log("    %-28s %6d calls  %7.2f us per call  %7.3f ms per second", s.ev .. " / " .. s.id, s.calls, s.total / math.max(s.calls, 1) * 1e6, s.total / dt * 1000)
		end
		Log("  %s: %d bots, %d records | all hooks together %.3f ms per second = %.2f us per server tick (%d ticks)", name, #bots, NT.Brain.count, sum / dt * 1000, sum / math.max(ticks, 1) * 1e6, ticks)
	end
	Measure("uninjured, standing", 8)
	-- all injured: three posturing, two in a seizure, two unsteady on their feet
	for i, bot in ipairs(bots) do
		if i <= 5 then hg.Fake(bot) end
	end
	Wait(2)
	for i, bot in ipairs(bots) do
		if i <= 3 then
			D.Set(bot, "stem", 0.6 + i * 0.1)
		elseif i <= 5 then
			NT.Seizure.Force(bot, NT.Brain.Ensure(bot.organism), CurTime(), { { "tonic", 3 }, { "clonic", 20 }, { "postictal", 10 } }, 1, false)
		else
			D.Set(bot, "diffuse", 0.3)
		end
	end
	Wait(1)
	S.Shot("neuro_perf2_injured")
	Measure("all injured (3 posturing, 2 seizing, 2 unsteady)", 10)
	Log("  net so far: %d messages, %d bytes", NT.Net.messages, NT.Net.bytes)
end)
