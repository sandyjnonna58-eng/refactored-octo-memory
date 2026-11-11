-- Audit scenes: the chain from a real trauma to what is seen, stage by stage, with nothing
-- protected and nothing set by hand. Same harness as sv_selftest.lua (they exist only with
-- garrysmod/data/abl_selftest.txt). See docs/NEUROTRAUMA_TRAUMA_CHAIN.md.

local NT = NeuroTrauma
if not (istable(ABL) and istable(ABL.SelfTest)) then return end
local S = ABL.SelfTest
local Log, Wait = S.Log, S.Wait
local C, Z, E = NT.Config, NT.ZC, NT.E
local V = Vector

------------------------------------------------------------------------------------------
-- The trace: everything that happens to one character, as it happens
------------------------------------------------------------------------------------------
local watch                 -- the character being traced
local last = {}             -- what was logged last, per line kind

local function Org(bot) return IsValid(bot) and istable(bot.organism) and bot.organism or nil end

-- Z-City's side, and the module's
local function ZLine(bot)
	local org = Org(bot)
	if not org then return "no organism" end
	return string.format("alive %s (organism %s) health %d | brain %.2f skull %.2f consciousness %.1f unconscious %s | heart stopped %s breathing %s | ragdolled %s",
		tostring(bot:Alive()), tostring(org.alive), bot:Health(), tonumber(org.brain) or -1, tonumber(org.skull) or -1, tonumber(org.consciousness) or -1, tostring(org.otrub),
		tostring(org.heartstop), tostring(org.lungsfunction), tostring(IsValid(bot.FakeRagdoll)))
end
local function NLine(bot)
	local org = Org(bot)
	local st = org and NT.Get(org)
	if not st then return "no record" end
	return string.format("%s | consciousness %.2f (%s) | posture %.2f | seizure %s | breathing %.2f | circulation %s",
		tostring(st.label), st.consciousness or -1, tostring(st.lossWhy), st.posture or 0, st.sz and st.sz.phase or "none", st.resp or -1, tostring(st.cardio))
end

local function Trace(fmt, ...)
	Log("      | " .. fmt, ...)
end

local seenEvents = {}       -- mechanism -> events that reached the model since the trace was armed
local arrived = 0           -- damage calls that reached the watched character since then
local function Arm(bot)
	watch = bot
	last = {}
	seenEvents = {}
	arrived = 0
end
local function Disarm() watch = nil end

hook.Add("PreHomigradDamage", "NT_Audit", function(ply, dmgInfo, hitgroup, ent)
	if not watch or (ply ~= watch and ent ~= watch and ent ~= watch.FakeRagdoll) then return end
	arrived = arrived + 1
	Trace("DAMAGE arrives: %.1f of type %d, hitgroup %s, on %s | Z-City before: %s", dmgInfo:GetDamage(), dmgInfo:GetDamageType(), tostring(hitgroup), tostring(ent), ZLine(watch))
end)
-- (anything at all that takes damage while a character is watched: a shot that does not arrive
-- at the character has arrived somewhere)
hook.Add("EntityTakeDamage", "NT_AuditAny", function(ent, dmgInfo)
	if not watch then return end
	if ent == watch or ent == watch.FakeRagdoll then return end
	local owner = IsValid(ent) and (ent:GetOwner() or ent:GetParent())
	Trace("damage goes to something else: %.1f of type %d to %s (model %s, parent %s, owner %s)", dmgInfo:GetDamage(), dmgInfo:GetDamageType(), tostring(ent),
		tostring(IsValid(ent) and ent:GetModel()), tostring(IsValid(ent) and ent:GetParent()), tostring(owner))
end)
hook.Add("PreTraceOrganBulletDamage", "NT_Audit", function(org, bone, dmg, dmgInfo, box, dir, hit, ricochet, organ, info)
	if not watch or org ~= watch.organism then return end
	Trace("  organ box '%s': damage %.2f (of the hit: %.1f) | brain before %.3f skull %.2f%s", tostring(istable(organ) and organ[1]), tonumber(istable(info) and info.dmg or dmg) or -1,
		dmgInfo:GetDamage(), tonumber(org.brain) or -1, tonumber(org.skull) or -1, istable(info) and info.restricted and " | Z-City's own input for this box is switched off" or "")
end)
hook.Add("PreHomigradDamageBulletBleedAdd", "NT_Audit", function(ply, org, dmgInfo, hitgroup)
	if not watch or org ~= watch.organism then return end
	Trace("  Z-City's organ inputs have run: brain %.3f skull %.2f consciousness %.2f shock %.0f | damage left %.1f", tonumber(org.brain) or -1, tonumber(org.skull) or -1,
		tonumber(org.consciousness) or -1, tonumber(org.shock) or -1, dmgInfo:GetDamage())
end)
hook.Add("NT_InjuryEvent", "NT_Audit", function(ply, org, ev)
	if ply ~= watch then return end
	seenEvents[ev.mech] = (seenEvents[ev.mech] or 0) + 1
	Trace("TRAUMA EVENT #%d reaches the model (%s) | %s", ev.id, E.Mech.names[ev.mech] or "?", ZLine(watch))
end)
hook.Add("DoPlayerDeath", "NT_Audit", function(ply, attacker, dmgInfo)
	if ply ~= watch then return end
	Trace("DEATH (DoPlayerDeath) | %s | module: %s", ZLine(ply), NLine(ply))
	for line in string.gmatch(debug.traceback("", 2), "[^\n]+") do
		if string.find(line, ".lua", 1, true) then Trace("    called from%s", line) end
	end
end)
hook.Add("RagdollDeath", "NT_Audit", function(ply, rag)
	if ply ~= watch then return end
	Trace("the corpse is %s (model %s)", tostring(rag), IsValid(rag) and rag:GetModel() or "-")
end)
hook.Add("Think", "NT_Audit", function()
	local bot = watch
	if not IsValid(bot) then return end
	local z, n = ZLine(bot), NLine(bot)
	if z ~= last.z then last.z = z Trace("Z-City: %s", z) end
	if n ~= last.n then last.n = n Trace("module: %s", n) end
end)

-- what the watched body does, for a number of seconds: how far the hands and the head move
local function Moves(body, seconds)
	if not IsValid(body) then return "no body" end
	local names = { "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_Head1", "ValveBiped.Bip01_R_Foot" }
	local prev, path, peak = {}, {}, {}
	local t0 = CurTime()
	while CurTime() - t0 < seconds do
		for i, name in ipairs(names) do
			local b = body:LookupBone(name)
			local pos = b and body:GetBonePosition(b)
			if pos then
				if prev[i] then
					local d = pos:Distance(prev[i])
					path[i] = (path[i] or 0) + d
					peak[i] = math.max(peak[i] or 0, d / math.max(FrameTime(), 0.001))
				end
				prev[i] = pos
			end
		end
		Wait(0.05)
		if not IsValid(body) then break end
	end
	return string.format("right hand travelled %.0f units (up to %.0f u/s), left hand %.0f, head %.0f, right foot %.0f", path[1] or 0, peak[1] or 0, path[2] or 0, path[3] or 0, path[4] or 0)
end

local pass, fail = 0, 0
local function Check(what, ok, detail)
	if ok then pass = pass + 1 else fail = fail + 1 end
	Log("    %s %s%s", ok and "PASS" or "FAIL", what, detail and (" (" .. detail .. ")") or "")
end
local function Tally(name)
	Log("  == %s: %d checks passed, %d failed", name, pass, fail)
	pass, fail = 0, 0
end

local deaths = {}           -- player -> time of death, while a scene watches
hook.Add("DoPlayerDeath", "NT_AuditDeaths", function(ply) deaths[ply] = CurTime() end)

-- The body a character is in now: itself, the ragdoll it lies in, or its corpse.
local function BodyOf(bot)
	if IsValid(bot.FakeRagdoll) then return bot.FakeRagdoll end
	local corpse = bot:GetNWEntity("RagdollDeath")
	if IsValid(corpse) then return corpse end
	return bot
end

-- Watches a character for some seconds and says what was seen of it.
local function Watch(bot, seconds, tag)
	local t0 = CurTime()
	local seen = { labels = {}, order = {} }
	local body = BodyOf(bot)
	local prev, path = {}, { 0, 0, 0 }
	local names = { "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_Head1" }
	while CurTime() - t0 < seconds do
		local org = Org(bot)
		local st = org and NT.Get(org)
		local label = (not bot:Alive()) and "DEAD" or (st and tostring(st.label) or "no record")
		if not seen.labels[label] then
			seen.labels[label] = CurTime() - t0
			seen.order[#seen.order + 1] = string.format("%s at %.1f s", label, CurTime() - t0)
		end
		if st then
			if (st.posture or 0) > 0.05 then seen.posture = true end
			if st.sz then seen.seizure = true end
			if st.arrestSince then seen.arrest = true end
			if (st.resp or 1) < 0.8 then seen.breathing = true end
		end
		body = BodyOf(bot)
		for i, name in ipairs(names) do
			local b = IsValid(body) and body:LookupBone(name)
			local pos = b and body:GetBonePosition(b)
			if pos then
				if prev[i] and prev.body == body then path[i] = path[i] + pos:Distance(prev[i]) end
				prev[i] = pos
			end
		end
		prev.body = body
		Wait(0.1)
	end
	seen.path = path
	Log("    %s, %.0f s: %s | hands travelled %.0f and %.0f units, head %.0f", tag or "watched", seconds, table.concat(seen.order, ", "), path[1], path[2], path[3])
	return seen
end

------------------------------------------------------------------------------------------
-- Bullets into the head, unprotected: what decides, and when
------------------------------------------------------------------------------------------
S.Add("neuro_audit_shots", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local p = S.FindSpot({ open = 220, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	-- (the shots start 80 units from the head, in front, behind and to both sides: the character is
	-- turned to where all four lines are free)
	local yaw = 0
	for y = 0, 315, 45 do
		local a = Angle(0, y, 0)
		local head = p + V(0, 0, 64)
		local clear = true
		for _, d in ipairs({ a:Forward(), -a:Forward(), a:Right(), -a:Right() }) do
			if util.TraceLine({ start = head, endpos = head + d * 110, mask = MASK_SHOT }).Hit then clear = false break end
		end
		if clear then yaw = y break end
	end
	Log("  the character faces %d degrees", yaw)
	-- (this scene audits the model's own judgement of a bullet: the rules of the game that stand in
	-- for it by default are switched off for it. They have a scene of their own, neuro_headshot_rules.)
	RunConsoleCommand("neuro_headshot_rules", "0")
	Wait(0.3)
	-- expect: "dies" (unsurvivable in the instant), "lives" (the model decides what follows), "miss"
	local function Shoot(name, ammo, from, off, expect, watchFor)
		bot:Spawn()
		S.Place(bot, p, yaw)
		Wait(2.5)
		deaths[bot] = nil
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		if not centre then Log("  %s: no head", name) return end
		S.View(centre + (face * 0.5 + left * 0.9 + V(0, 0, 0.35)):GetNormalized() * 150, centre - V(0, 0, 30))
		Wait(0.4)
		centre, up, face, left = Z.HeadFrame(body)
		local aim = centre + up * off.x + face * off.y + left * off.z
		local fromDir = (up * from.x + face * from.y + left * from.z):GetNormalized()
		local tag = string.gsub(string.lower(name), "[^%w]+", "_")
		Log("-- %s (%s) | takeover %s", name, ammo, tostring(Z.Takeover()))
		Arm(bot)
		local t0 = CurTime()
		local spasmBefore, heldBefore = Z.spasmPassed or 0, Z.spasmHeld or 0
		do
			-- (what lies on the line of the shot, as the engine sees it)
			local src = aim + fromDir * 80
			local tr = util.TraceLine({ start = src, endpos = aim - fromDir * 20, filter = host, mask = MASK_SHOT })
			Log("    the line of the shot: %s at %.0f units of 100 (hitbox %s)", tr.Hit and tostring(tr.Entity) or "nothing", tr.Fraction * 100, tostring(tr.HitGroup))
		end
		ABL.DevShootAt(host, aim, fromDir, nil, 80, ammo)
		Wait(0.25)
		-- (Z-City's bullets are bodies in flight with a path of their own: now and then one passes a
		-- head that the straight line meets. A shot that reached nothing is fired again.)
		for try = 2, 4 do
			if arrived > 0 or expect == nil then break end
			Log("    nothing arrived: fired again (%d)", try)
			centre, up, face, left = Z.HeadFrame(body)
			aim = centre + up * off.x + face * off.y + left * off.z
			fromDir = (up * from.x + face * from.y + left * from.z):GetNormalized()
			t0 = CurTime()
			ABL.DevShootAt(host, aim, fromDir, nil, 80, ammo)
			Wait(0.25)
		end
		local org = Org(bot)
		local st = org and NT.Get(org)
		local died = deaths[bot] and (deaths[bot] - t0) or nil
		if expect == "dies" then
			Check("unsurvivable: dead in the same instant", died ~= nil and died < 0.05, died and string.format("%.2f s", died) or "alive")
			-- (what the body does then is Z-City's: its response to a death is no longer held back)
			Check("Z-City's own response to the death was left to run", (Z.spasmPassed or 0) > spasmBefore and (Z.spasmHeld or 0) == heldBefore,
				string.format("passed on %d times, held back %d", (Z.spasmPassed or 0) - spasmBefore, (Z.spasmHeld or 0) - heldBefore))
		elseif expect == "lives" then
			Check("not killed in the instant of the hit", died == nil, died and string.format("died at %.2f s", died) or nil)
			Check("a record exists and Z-City's brain value is the model's, not Z-City's 1.0", st ~= nil and org ~= nil and (tonumber(org.brain) or 1) < 0.69,
				string.format("record %s, brain %.3f, floor %.3f", tostring(st ~= nil), org and tonumber(org.brain) or -1, st and st.brainFloor or -1))
			Check("the character has dropped", IsValid(bot.FakeRagdoll) or not bot:Alive())
		end
		S.Shot("neuro_audit_" .. tag .. "_0s")
		local seen = Watch(bot, watchFor or 20, "what followed")
		S.Shot("neuro_audit_" .. tag .. "_end")
		Log("    at the end: %s", ZLine(bot))
		Log("    module: %s", NLine(bot))
		Disarm()
		return seen
	end
	local P, R = "9x19mmparabellum", "7.62x39mm"
	Shoot("front centre pistol", P, V(0, 1, 0), V(0.8, 0, 0), "lives", 30)
	Shoot("front left half pistol", P, V(0, 1, 0), V(0.8, 0, 1.6), "lives", 30)
	Shoot("side across pistol", P, V(0, 0, -1), V(0.8, 0, 0), "lives", 30)
	Shoot("side across rifle", R, V(0, 0, -1), V(0.8, 0, 0), "dies", 8)
	Shoot("behind low pistol", P, V(0, -1, 0), V(-2.6, -0.5, 0), nil, 30)
	Shoot("temple graze pistol", P, V(0, 1, 0), V(0.5, 0, 2.6), nil, 6)
	-- a second bullet into a character that lies with a record
	Log("-- two pistol rounds, front left half, two seconds apart")
	bot:Spawn()
	S.Place(bot, p, yaw)
	Wait(2.5)
	deaths[bot] = nil
	Arm(bot)
	for i = 1, 2 do
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		if centre then ABL.DevShootAt(host, centre + up * 0.8 + left * 1.6, face, nil, 80, P) end
		Wait(2)
	end
	Watch(bot, 10, "after the second")
	Log("    at the end: %s", ZLine(bot))
	Disarm()
	-- with the takeover off, Z-City's own rule stands
	RunConsoleCommand("neuro_zcity_takeover", "0")
	Wait(0.3)
	Shoot("front centre pistol, takeover off", P, V(0, 1, 0), V(0.8, 0, 0), "dies", 4)
	RunConsoleCommand("neuro_zcity_takeover", "1")
	RunConsoleCommand("neuro_headshot_rules", "1")
	Wait(0.3)
	Tally("neuro_audit_shots")
end)

------------------------------------------------------------------------------------------
-- The other mechanisms, unprotected: a club, a fall on the head, a blast, bullets in the chest
------------------------------------------------------------------------------------------
S.Add("neuro_audit_mechanisms", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local p = S.FindSpot({ open = 240, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local function Fresh()
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(2.2)
		deaths[bot] = nil
		local c = Z.Body(bot):GetPos()
		S.View(c + V(150, 110, 90), c + V(0, 0, 30))
	end
	local function Blow(name, damage, watchFor)
		Fresh()
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		local dir = left
		local pos = centre + up * 0.5 - left * 3
		local d = DamageInfo()
		d:SetDamage(damage)
		d:SetDamageType(DMG_CLUB)
		d:SetAttacker(host)
		d:SetInflictor(host)
		d:SetDamagePosition(pos)
		d:SetDamageForce(dir * damage * 60)
		d:SetReportedPosition(pos - dir * 40)
		Log("-- %s", name)
		Arm(bot)
		body:TakeDamageInfo(d)
		Wait(0.2)
		Check("the blow does not kill in the instant", bot:Alive() and not deaths[bot])
		Check("one event of a blow reached the model and a record exists", (seenEvents[E.Mech.BLUNT] or 0) == 1 and NT.Get(bot.organism) ~= nil,
			string.format("%d events", seenEvents[E.Mech.BLUNT] or 0))
		S.Shot("neuro_audit_" .. string.gsub(string.lower(name), "[^%w]+", "_"))
		Watch(bot, watchFor or 15, "what followed")
		Log("    at the end: %s", ZLine(bot))
		Log("    module: %s", NLine(bot))
		Disarm()
	end
	Blow("club to the side of the head, 25", 25)
	Blow("club to the side of the head, 45", 45)
	Blow("club to the side of the head, 90", 90, 20)

	-- a fall onto the head: lifted, turned head down, let go
	for _, h in ipairs({ 150, 300 }) do
		Fresh()
		Log("-- dropped head first from %d units", h)
		Arm(bot)
		hg.Fake(bot)
		Wait(0.4)
		local rag = bot.FakeRagdoll
		if IsValid(rag) then
			ABL.DevPose(rag, "upside", false)
			for i = 0, rag:GetPhysicsObjectCount() - 1 do
				local po = rag:GetPhysicsObjectNum(i)
				if IsValid(po) then po:SetPos(po:GetPos() + V(0, 0, h)) po:SetVelocity(vector_origin) po:Wake() end
			end
		end
		Watch(bot, 15, "what followed")
		Log("    at the end: %s", ZLine(bot))
		Log("    module: %s", NLine(bot))
		Disarm()
	end

	-- an explosion at 100 units
	for _, dmg in ipairs({ 40, 120 }) do
		Fresh()
		Log("-- a blast of %d at 100 units", dmg)
		Arm(bot)
		util.BlastDamage(host, host, bot:GetPos() + bot:GetForward() * 100 + V(0, 0, 40), 400, dmg)
		Wait(0.2)
		if dmg < 100 then
			-- (the size of Z-City's hand grenade)
			Check("an explosion of this size does not kill through the brain in the instant", bot:Alive() and not deaths[bot])
			Check("it reached the model as one event", (seenEvents[E.Mech.BLAST] or 0) == 1, string.format("%d events", seenEvents[E.Mech.BLAST] or 0))
			Check("the character is down (Z-City: shock and pain)", IsValid(bot.FakeRagdoll))
		else
			Check("a large explosion at this distance kills in the instant, by Z-City's rule for one explosion", deaths[bot] ~= nil)
		end
		Watch(bot, 15, "what followed")
		Log("    at the end: %s", ZLine(bot))
		Log("    module: %s", NLine(bot))
		Disarm()
	end

	-- the body, not the head: rifle rounds into the chest
	Fresh()
	Log("-- three rifle rounds into the chest")
	Arm(bot)
	for i = 1, 3 do
		local body = Z.Body(bot)
		local b = body:LookupBone("ValveBiped.Bip01_Spine2")
		local pos = b and body:GetBonePosition(b)
		if pos then ABL.DevShootAt(host, pos, bot:GetForward(), nil, 80, "7.62x39mm") end
		Wait(0.7)
	end
	Watch(bot, 40, "what followed")
	Log("    at the end: %s", ZLine(bot))
	Log("    module: %s", NLine(bot))
	do
		local st = NT.Get(bot.organism)
		Check("a wound of the heart ends in an arrest that the module shows, with a cause", st ~= nil and st.arrestSince ~= nil and st.label == "CARDIAC_ARREST",
			st and tostring(st.arrestCause) or "no record")
		-- the death that follows: this body has lain limp without circulation, and stays limp
		local held, passed = Z.spasmHeld or 0, Z.spasmPassed or 0
		bot:Kill()
		Wait(0.4)
		Check("the body that lay in that arrest does not stiffen when its death is booked", (Z.spasmHeld or 0) == held + 1 and (Z.spasmPassed or 0) == passed,
			string.format("held back %d, passed on %d", (Z.spasmHeld or 0) - held, (Z.spasmPassed or 0) - passed))
	end
	Disarm()
	Tally("neuro_audit_mechanisms")
end)

------------------------------------------------------------------------------------------
-- What each state looks like from where players stand: the last links of the chain (animation
-- state, pose, what a client draws). The camera stands 150 and 300 units from the body, at eye
-- height, square to it; the host's client measures what the drawn body does (cl_selftest.lua,
-- H.motion) and sends it back, and the checks are made on those numbers.
------------------------------------------------------------------------------------------
util.AddNetworkString("nt_test3")
util.AddNetworkString("nt_test4")
local results = {}
net.Receive("nt_test4", function(_, ply)
	if ply ~= S.Host() then return end
	local tag = net.ReadString()
	results[tag] = net.ReadTable()
end)
local function Client(cmd, tbl)
	net.Start("nt_test3")
	net.WriteString(cmd)
	net.WriteTable(tbl or {})
	net.Send(S.Host())
end

local function Motion(ent, tag, seconds)
	results[tag] = nil
	Client("motion", { ent = ent, tag = tag, seconds = seconds or 2 })
	local t0 = CurTime()
	while not results[tag] and CurTime() - t0 < (seconds or 2) + 2 do Wait(0.1) end
	local r = results[tag]
	if not r or r.missing then
		Log("     the client drew no such body")
		return nil
	end
	local function R(name) return string.format("%.0f (%.1f Hz)", r["range" .. name] or -1, r["hz" .. name] or 0) end
	Log("     drawn, %.1f s: hands moved R %s L %s, feet R %s L %s, knees R %s L %s, head %s | chest %.0f above the lowest point (%.0f to %.0f)", r.seconds or 0,
		R("R_Hand"), R("L_Hand"), R("R_Foot"), R("L_Foot"), R("R_Calf"), R("L_Calf"), R("Head1"), r.chest or -1, r.chestLo or -1, r.chestHi or -1)
	Log("     elbows R %.0f L %.0f, knees R %.0f L %.0f | trunk %.0f from upright (%.0f to %.0f), face %.0f up and %.0f to the left | hands from the chest R %.0f L %.0f, from the hips R %.0f L %.0f | feet apart %.0f | chest to the side %.1f (%.1f to %.1f)",
		r.elbowR or -1, r.elbowL or -1, r.kneeR or -1, r.kneeL or -1, r.lean or -1, r.leanLo or -1, r.leanHi or -1, r.faceNod or 0, r.faceTurn or 0,
		r.handChestR or -1, r.handChestL or -1, r.handHipR or -1, r.handHipL or -1, r.feetApart or -1, r.sideways or 0, r.sidewaysLo or 0, r.sidewaysHi or 0)
	return r
end

-- the camera square to a body, at a distance, at eye height
local function ViewBody(body, dist)
	local centre = body:WorldSpaceCenter()
	local side
	if body:IsPlayer() then
		local f = body:GetForward()
		side = (f + f:Cross(V(0, 0, 1)) * 0.6):GetNormalized()
	else
		local pelvis, chest = body:GetPhysicsObjectNum(hg.realPhysNum(body, 0)), body:GetPhysicsObjectNum(hg.realPhysNum(body, 1))
		local axis = (IsValid(pelvis) and IsValid(chest)) and (chest:GetPos() - pelvis:GetPos()) or V(1, 0, 0)
		axis.z = 0
		if axis:LengthSqr() < 0.01 then axis = V(1, 0, 0) end
		axis:Normalize()
		side = axis:Cross(V(0, 0, 1))
		centre = IsValid(pelvis) and IsValid(chest) and (pelvis:GetPos() + chest:GetPos()) * 0.5 or centre
	end
	local ground = centre.z - (body:IsPlayer() and 36 or 6)
	-- (The host stands a little behind the camera, and what the host cannot see is not sent to its
	-- client at all: from behind a wall a standing character was simply not there, run p23b. The
	-- side is turned until the line from there to the body is free.)
	local eye = V(centre.x, centre.y, ground + 64)
	for turn = 0, 270, 90 do
		local d = Vector(side)
		d:Rotate(Angle(0, turn, 0))
		if not util.TraceLine({ start = eye, endpos = eye + d * (dist + 70), mask = MASK_SOLID_BRUSHONLY }).Hit then
			side = d
			break
		end
	end
	S.View(eye + side * dist, centre)
	Wait(0.25)
end

S.Add("neuro_audit_visible", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local D = NT.Debug
	local p = S.FindSpot({ open = 330, outdoor = true })
	local bot = S.NewBot()
	local base = {}
	local function Frames(tag, body, n, gap)
		for _, dist in ipairs({ 150, 300 }) do
			ViewBody(body, dist)
			for i = 1, (dist == 150 and n or math.min(n, 2)) do
				S.Shot(string.format("vis_%s_%d_%d", tag, dist, i))
				if i < n then Wait(gap or 0.3) end
			end
		end
	end
	local function Lying(tag, fn, wait, n, gap, seconds)
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.5)
		if istable(bot.organism) then bot.organism.godmode = true end
		hg.Fake(bot)
		Wait(0.3)
		local rag = bot.FakeRagdoll
		if IsValid(rag) then ABL.DevPose(rag, "back", false) end
		Wait(2.2)
		fn()
		Wait(wait or 2.5)
		rag = bot.FakeRagdoll
		local st = istable(bot.organism) and NT.Get(bot.organism)
		Log("  %-20s %s | animation %s", tag, NLine(bot), st and NT.Anim and NT.Anim.Describe(st) or "-")
		if not IsValid(rag) then Log("     no ragdoll") return nil end
		ViewBody(rag, 150)
		local r = Motion(bot, tag, seconds or 2.5)
		Frames(tag, rag, n or 2, gap)
		return r, st
	end
	local function Standing(tag, fn, wait, n, gap, seconds)
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.5)
		if istable(bot.organism) then bot.organism.godmode = true end
		-- (the same character in the same stance, before: a bot does not stand the same way twice)
		ViewBody(Z.Body(bot), 150)
		Log("  %-20s before:", tag)
		local before = Motion(bot, tag .. "_before", 1.5) or {}
		if fn then fn() end
		Wait(wait or 2.5)
		local st = istable(bot.organism) and NT.Get(bot.organism)
		local up = not IsValid(bot.FakeRagdoll)
		Log("  %-20s %s | on its feet %s | animation %s", tag, NLine(bot), tostring(up), st and NT.Anim and NT.Anim.Describe(st) or "-")
		ViewBody(Z.Body(bot), 150)
		local r = Motion(bot, tag, seconds or 3)
		Frames(tag, Z.Body(bot), n or 2, gap)
		return r, st, up, before
	end
	local function Force(plan) return function() NT.Seizure.Force(bot, NT.Brain.Ensure(bot.organism), CurTime(), plan, 1, false) end end
	local function Both(r, a, b, test) return r ~= nil and r[a] ~= nil and r[b] ~= nil and test(r[a]) and test(r[b]) end

	Log("-- on the ground (on the back)")
	local limp = Lying("limp", function() D.Set(bot, "knockout", 30) end, 2.5, 2, 0.3, 4.5)
	base.limp = limp or {}
	-- (the hands are measured against the trunk, which tilts as the chest rises: they are not thrown)
	Check("unconscious and breathing: the chest rises and sinks, slowly, and nothing beats", limp ~= nil and (limp.chestHi - limp.chestLo) >= 1.2 and math.max(limp.hzR_Hand, limp.hzL_Hand) < 0.8,
		limp and string.format("chest rises %.1f units, hands %.0f %.0f units at %.1f %.1f Hz", limp.chestHi - limp.chestLo, limp.rangeR_Hand, limp.rangeL_Hand, limp.hzR_Hand, limp.hzL_Hand))

	-- (a posture shows itself in full when it appears, for some seconds: measured then)
	local r = Lying("flexor", function() D.Set(bot, "stem", 0.62) end, 1.2, 2, 0.3, 1.8)
	Check("flexor posture: both elbows bent, the hands on the chest", Both(r, "elbowR", "elbowL", function(v) return v < 100 end) and Both(r, "handChestR", "handChestL", function(v) return v < 15 end),
		r and string.format("elbows %.0f %.0f, hands from the chest %.0f %.0f", r.elbowR, r.elbowL, r.handChestR, r.handChestL))
	Check("flexor posture: the legs straight and together", Both(r, "kneeR", "kneeL", function(v) return v > 150 end) and r.feetApart < 16,
		r and string.format("knees %.0f %.0f, feet apart %.0f", r.kneeR, r.kneeL, r.feetApart))

	r = Lying("extensor", function() D.Set(bot, "stem", 0.85) end, 1.2, 2, 0.3, 1.8)
	Check("extensor posture: both elbows straight, the hands down at the hips", Both(r, "elbowR", "elbowL", function(v) return v > 150 end) and Both(r, "handHipR", "handHipL", function(v) return v < 15 end),
		r and string.format("elbows %.0f %.0f, hands from the hips %.0f %.0f", r.elbowR, r.elbowL, r.handHipR, r.handHipL))
	-- (a body that stands on its head and heels as a bridge has its knees a little bent: the legs run down from a lifted pelvis)
	Check("extensor posture: the legs out straight, the back arched off the ground", Both(r, "kneeR", "kneeL", function(v) return v > 115 end) and (r.chest or 0) >= (base.limp.chest or 0) + 2,
		r and string.format("knees %.0f %.0f, chest %.1f above the lowest point (limp %.1f)", r.kneeR, r.kneeL, r.chest, base.limp.chest or -1))

	r = Lying("knockout_posture", function()
		local st = NT.Brain.Ensure(bot.organism)
		local now = CurTime()
		st.locUntil, st.confusedUntil = now + 14, now + 40
		st.fencingUntil, st.fencingSeed = now + 9, 2
	end, 1.5, 2, 0.3, 2)
	do
		local a, b = r and r.meanR_Hand, r and r.meanL_Hand
		local hi = a and b and math.max(a[1], b[1]) or -99
		Check("the posture of a knockout: one forearm held up off the body", hi >= 12, a and string.format("hands toward the front %.0f and %.0f units", a[1], b[1]))
	end

	r = Lying("tonic", Force({ { "tonic", 14 } }), 3)
	Check("tonic phase: the limbs straight and rigid, the back arched", Both(r, "elbowR", "elbowL", function(v) return v > 140 end) and Both(r, "kneeR", "kneeL", function(v) return v > 115 end)
		and (r.chest or 0) >= (base.limp.chest or 0) + 2.5 and math.max(r.rangeR_Hand, r.rangeL_Hand) < 10,
		r and string.format("elbows %.0f %.0f, knees %.0f %.0f, chest %.1f (limp %.1f), hands moved %.0f %.0f", r.elbowR, r.elbowL, r.kneeR, r.kneeL, r.chest, base.limp.chest or -1, r.rangeR_Hand, r.rangeL_Hand))

	r = Lying("clonic", Force({ { "clonic", 16 } }), 2.5, 5, 0.1, 3)
	Check("clonic phase: both hands thrown at least 16 units, in a beat of 1 to 5 a second", Both(r, "rangeR_Hand", "rangeL_Hand", function(v) return v >= 16 end)
		and math.max(r.hzR_Hand, r.hzL_Hand) >= 1 and math.max(r.hzR_Hand, r.hzL_Hand) <= 5,
		r and string.format("hands %.0f %.0f units at %.1f %.1f Hz", r.rangeR_Hand, r.rangeL_Hand, r.hzR_Hand, r.hzL_Hand))
	Check("clonic phase: the legs and the trunk in it too", Both(r, "rangeR_Calf", "rangeL_Calf", function(v) return v >= 8 end) and (r.chestHi - r.chestLo) >= 2.5 and r.rangeHead1 >= 4,
		r and string.format("knees %.0f %.0f units, chest rises %.1f, head %.0f", r.rangeR_Calf, r.rangeL_Calf, r.chestHi - r.chestLo, r.rangeHead1))

	r = Lying("arrest_still", function()
		bot.organism.godmode = false
		NT.Cardio.TriggerArrest(bot, "test")
		Wait(1.2)
		local st = NT.Get(bot.organism)
		if st then
			st.gasp, st.jerksFrom = nil, nil
			if st.sz and st.sz.kind == "jerks" then st.sz = nil st.seizurePhase = 0 end
		end
	end, 2, 2, 0.5, 4.5)
	Check("an arrest without gasps: the chest does not move (which is what tells it from unconsciousness)", r ~= nil and (r.chestHi - r.chestLo) < 0.8 and math.max(r.rangeR_Hand, r.rangeL_Hand) < 3,
		r and string.format("chest rises %.1f units, hands moved %.0f %.0f", r.chestHi - r.chestLo, r.rangeR_Hand, r.rangeL_Hand))

	r = Lying("arrest", function()
		bot.organism.godmode = false
		NT.Cardio.TriggerArrest(bot, "test")
		Wait(1.2)
		local st = NT.Get(bot.organism)
		-- (gasps come in a share of arrests, jerks in another; here the gasps are made to come,
		-- soon, and the jerks are left out)
		if st then
			st.gasp = { next = CurTime() + 1.5, every = 2.2, stop = CurTime() + 40 }
			st.jerksFrom = nil
			if st.sz and st.sz.kind == "jerks" then st.sz = nil st.seizurePhase = 0 end
		end
	end, 2, 3, 0.8, 5)
	Check("an arrest with agonal gasps: the chest heaves, and nothing beats", r ~= nil and (r.chestHi - r.chestLo) >= 3 and math.max(r.hzR_Hand, r.hzL_Hand) < 1,
		r and string.format("chest rises %.1f, hands moved %.0f %.0f at %.1f %.1f Hz", r.chestHi - r.chestLo, r.rangeR_Hand, r.rangeL_Hand, r.hzR_Hand, r.hzL_Hand))

	Log("-- on its feet")
	local up, _, bs

	r, _, up, bs = Standing("dazed", function() D.Set(bot, "daze", 12) end, 1.5, 2, 0.3, 5)
	Check("dazed: the head hangs and the trunk sways", up and r ~= nil and (r.faceNod or 0) <= (bs.faceNod or 0) - 12 and (r.leanHi - r.leanLo) >= 5,
		r and string.format("face %.0f degrees up (before %.0f), trunk sways through %.0f degrees", r.faceNod or 0, bs.faceNod or 0, r.leanHi - r.leanLo))

	r, _, up, bs = Standing("unsteady", function() D.Set(bot, "diffuse", 0.3) end, 2, 3, 0.6, 6)
	Check("unsteady: the trunk sways through at least 10 degrees, the chest 3 units from side to side", up and r ~= nil and (r.leanHi - r.leanLo) >= 10 and (r.sidewaysHi - r.sidewaysLo) >= 3,
		r and string.format("trunk through %.0f degrees, chest %.1f units side to side", r.leanHi - r.leanLo, r.sidewaysHi - r.sidewaysLo))

	r, _, up, bs = Standing("left_side_weak", function()
		NT.DamageRegion(bot, "R_precentral_hand", 1) NT.DamageRegion(bot, "R_precentral_arm", 1) NT.DamageRegion(bot, "R_paracentral", 0.5) NT.DamageRegion(bot, "R_precentral_face", 1)
	end, 3)
	do
		local a, b = r and r.meanL_Hand, bs.meanL_Hand
		local moved = a and b and math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) or 0
		Check("a weak left side: the trunk leans to it and the arm hangs out of its place", up and r ~= nil and moved >= 4 and math.abs((r.sideways or 0) - (bs.sideways or 0)) >= 2,
			r and string.format("left hand %.1f units from where it was, chest %.1f to the side (before %.1f)", moved, r.sideways, bs.sideways or 0))
	end

	r, _, up, bs = Standing("ataxia", function() NT.DamageRegion(bot, "vermis", 1) NT.DamageRegion(bot, "L_cerebellum_sup", 1) NT.DamageRegion(bot, "R_cerebellum_sup", 1) end, 3, 3, 0.4, 4)
	Check("ataxia: a broad stance and a trunk that wobbles", up and r ~= nil and r.feetApart >= (bs.feetApart or 0) + 5 and (r.leanHi - r.leanLo) >= 6,
		r and string.format("feet %.0f apart (before %.0f), trunk through %.0f degrees", r.feetApart, bs.feetApart or -1, r.leanHi - r.leanLo))

	r, _, up, bs = Standing("focal_seizure", function() NT.TriggerSeizure(bot, { focal = true, aware = true, spread = false, side = 1, todd = false }) end, 2, 5, 0.1)
	Check("a focal seizure on the feet: one hand thrown at least 14 units in a beat, the head turned to that side", up and r ~= nil and r.rangeL_Hand >= 14 and r.hzL_Hand >= 1.5 and ((r.faceTurn or 0) - (bs.faceTurn or 0)) >= 15,
		r and string.format("left hand %.0f units at %.1f Hz (right %.0f), face turned %.0f to the left (before %.0f)", r.rangeL_Hand, r.hzL_Hand, r.rangeR_Hand, r.faceTurn or 0, bs.faceTurn or 0))

	r, _, up, bs = Standing("awareness_lost", function() NT.TriggerSeizure(bot, { focal = true, aware = false, spread = false, side = -1, todd = false }) end, 3, 3, 0.4)
	Check("a seizure that takes awareness: a hand drawn up to the chest and working, the head turned", up and r ~= nil and r.handChestR <= (bs.handChestR or 99) - 5 and r.rangeR_Hand >= 3 and ((bs.faceTurn or 0) - (r.faceTurn or 0)) >= 8,
		r and string.format("right hand %.0f from the chest (before %.0f), moving %.1f, face turned %.0f to the left (before %.0f)", r.handChestR, bs.handChestR or -1, r.rangeR_Hand, r.faceTurn or 0, bs.faceTurn or 0))
	NT.Reset(bot)
	Tally("neuro_audit_visible")
end)

------------------------------------------------------------------------------------------
-- Going down (sv_collapse.lua): the stagger, the catch, the fall and its kinds; and the rule
-- that a critical state is never seen on a body that is not down.
------------------------------------------------------------------------------------------
local function TrunkLean(body)
	-- degrees the line from the pelvis part to the chest part is from upright
	if not IsValid(body) then return -1 end
	local a, b
	if body:IsPlayer() then
		local pb, cb = body:LookupBone("ValveBiped.Bip01_Pelvis"), body:LookupBone("ValveBiped.Bip01_Spine2")
		local pm, cm = pb and body:GetBoneMatrix(pb), cb and body:GetBoneMatrix(cb)
		if not pm or not cm then return -1 end
		a, b = pm:GetTranslation(), cm:GetTranslation()
	else
		local pp, cp = body:GetPhysicsObjectNum(hg.realPhysNum(body, 0)), body:GetPhysicsObjectNum(hg.realPhysNum(body, 1))
		if not IsValid(pp) or not IsValid(cp) then return -1 end
		a, b = pp:GetPos(), cp:GetPos()
	end
	local d = b - a
	d:Normalize()
	return math.deg(math.acos(math.Clamp(d.z, -1, 1)))
end

S.Add("neuro_collapse", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local D, K, A = NT.Debug, NT.Collapse, NT.Anim
	local p = S.FindSpot({ open = 330, outdoor = true })
	local bot = S.NewBot()
	local function Fresh()
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.6)
		if istable(bot.organism) then bot.organism.godmode = true end
		bot.NT_staggerNext = nil
		ViewBody(bot, 170)
	end
	local function Mode() local st = NT.Get(bot.organism) return st and st.anim and A.names[st.anim.mode] or "no record" end
	-- frames of the body while something happens to it, a fifth of a second apart
	local function Film(tag, n)
		for i = 1, n do
			S.Shot(string.format("col_%s_%d", tag, i))
			Wait(0.05)
		end
	end

	Log("-- a stagger that is caught")
	Fresh()
	do
		local st = NT.Brain.Ensure(bot.organism)
		st.quiet = false
		local ok = K.Stagger(bot, st, { dir = bot:GetRight(), dur = 1.5, peak = 0.9, fall = false, why = "test" })
		Check("a stagger begins on a standing character, and is the animation state at once", ok and Mode() == "STAGGER", Mode())
		-- (measured on the client while it lasts; the pictures are taken meanwhile)
		results.stagger_caught = nil
		Client("motion", { ent = bot, tag = "stagger_caught", seconds = 1.2 })
		Wait(0.35)
		Film("caught", 2)
		local t0 = CurTime()
		while not results.stagger_caught and CurTime() - t0 < 3 do Wait(0.1) end
		Wait(0.8)
		Check("it is caught: the character is still on its feet and no longer staggering", not IsValid(bot.FakeRagdoll) and not K.Staggering(bot) and Mode() ~= "STAGGER", Mode())
		local r = results.stagger_caught
		Check("while it lasted the body went over and sank: seen on the client", r ~= nil and not r.missing and (r.leanHi or 0) >= (r.leanLo or 0) + 7 and (r.chestLo or 99) <= (r.chestHi or 0) - 3,
			r and not r.missing and string.format("trunk between %.0f and %.0f degrees from upright, chest between %.0f and %.0f units up", r.leanLo or -1, r.leanHi or -1, r.chestLo or -1, r.chestHi or -1) or "nothing measured")
	end

	Log("-- a stagger that ends on the ground: the ragdoll is made in the pose and with the movement it had")
	Fresh()
	do
		local st = NT.Brain.Ensure(bot.organism)
		st.quiet = false
		local dir = bot:GetRight()
		-- (the ragdoll as it is made: how it leans, how low its feet are, how it moves)
		local born
		hook.Add("NT_Collapse", "NT_AuditCollapse", function(ply, rag)
			if ply ~= bot then return end
			local chest = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, 1))
			local lf = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, 13))
			born = { lean = TrunkLean(rag), v = IsValid(chest) and chest:GetVelocity():Dot(dir) or 0, foot = IsValid(lf) and (lf:GetPos().z - bot:GetPos().z) or -99 }
		end)
		K.Stagger(bot, st, { dir = dir, dur = 0.8, peak = 1, fall = true, kind = "topple", why = "test" })
		Wait(0.45)
		Film("fall", 2)
		local t0 = CurTime()
		while not IsValid(bot.FakeRagdoll) and CurTime() - t0 < 1.5 do Wait(0.02) end
		hook.Remove("NT_Collapse", "NT_AuditCollapse")
		local rag = bot.FakeRagdoll
		Check("it goes down, and the ragdoll is made leaning as the stagger did, with its feet on the ground", IsValid(rag) and born ~= nil and born.lean >= 12 and born.foot < 8,
			born and string.format("trunk %.0f degrees from upright and the left foot %.0f units above the ground, at the moment it was made", born.lean, born.foot) or "no ragdoll")
		Check("the fall goes on the way the stagger went", born ~= nil and born.v >= 40, born and string.format("chest moving %.0f units a second that way", born.v) or "-")
		Film("fall_b", 3)
		Wait(1.5)
		Log("    state: %s", NLine(bot))
	end

	Log("-- a hit that dazes a standing character")
	Fresh()
	do
		local n0 = K.count.staggers
		D.Hit(bot, 10, 3, 1)
		Wait(0.1)
		Check("a hit that leaves the character on its feet makes it stagger, away from the blow", K.count.staggers == n0 + 1 and (K.Staggering(bot) or IsValid(bot.FakeRagdoll)),
			string.format("%d staggers begun, animation %s", K.count.staggers - n0, Mode()))
		Film("daze", 3)
		Wait(1.5)
		Log("    it %s | %s", IsValid(bot.FakeRagdoll) and "fell" or "caught itself", NLine(bot))
	end

	Log("-- consciousness that goes, slowly: the feet go first")
	Fresh()
	do
		local st = NT.Brain.Ensure(bot.organism)
		st.quiet = false
		st.diffuse, st.diffuseFloor = 0.05, 0.05
		local n0, f0 = K.count.staggers, K.count.takedowns
		local t0 = CurTime()
		local staggered, down
		while CurTime() - t0 < 14 do
			-- (a diffuse injury that deepens: wakefulness falls by a few hundredths a second)
			st = NT.Get(bot.organism)
			if not st then break end
			st.diffuse = math.min((st.diffuse or 0) + 0.004, 0.9)
			st.diffuseFloor = st.diffuse
			if not staggered and K.Staggering(bot) then staggered = CurTime() - t0 Film("faint", 2) end
			if IsValid(bot.FakeRagdoll) then down = CurTime() - t0 break end
			Wait(0.05)
		end
		st = NT.Get(bot.organism)
		Check("it staggers before it falls, and falls by folding", staggered ~= nil and down ~= nil and down > staggered and st ~= nil and st.collapseKind == "fold",
			string.format("staggering at %s s, down at %s s, kind %s, %d staggers, %d take-downs", staggered and string.format("%.1f", staggered) or "-", down and string.format("%.1f", down) or "-",
				tostring(st and st.collapseKind), K.count.staggers - n0, K.count.takedowns - f0))
		Film("faint_b", 2)
	end

	Log("-- a leg that does not carry")
	Fresh()
	do
		NT.DamageRegion(bot, "R_paracentral", 1)
		local t0 = CurTime()
		local staggered
		while not IsValid(bot.FakeRagdoll) and CurTime() - t0 < 4 do
			if not staggered and K.Staggering(bot) then staggered = true Film("leg", 2) end
			Wait(0.03)
		end
		local st = NT.Get(bot.organism)
		Check("the character goes down over that leg, after a moment on its feet", staggered == true and IsValid(bot.FakeRagdoll) and st ~= nil and st.collapseKind == "leg",
			string.format("staggered %s, down %s, kind %s, left leg %.2f", tostring(staggered), tostring(IsValid(bot.FakeRagdoll)), tostring(st and st.collapseKind), st and st.legL or -1))
	end

	Log("-- what takes a body down at once, and how it falls")
	local function AtOnce(name, kind, fn)
		Fresh()
		local c0 = K.count.takedowns
		fn()
		local t0 = CurTime()
		while not IsValid(bot.FakeRagdoll) and CurTime() - t0 < 2 do Wait(0.02) end
		local took = CurTime() - t0
		local st = NT.Get(bot.organism)
		Film(name, 2)
		Check(string.format("%s: down within a moment, falling %s", name, kind), IsValid(bot.FakeRagdoll) and st ~= nil and (kind == "any" or st.collapseKind == kind),
			string.format("%.2f s, kind %s, animation %s", took, tostring(st and st.collapseKind), Mode()))
	end
	AtOnce("tonic_start", "rigid", function() NT.Seizure.Force(bot, NT.Brain.Ensure(bot.organism), CurTime(), { { "tonic", 8 }, { "clonic", 6 }, { "postictal", 6 } }, 1, false) end)
	AtOnce("arrest", "fold", function() bot.organism.godmode = false NT.Cardio.TriggerArrest(bot, "test") end)
	AtOnce("brainstem", "fold", function() D.Set(bot, "stem", 0.85) end)
	NT.Reset(bot)
	Log("  staggers %d, of which %d ended on the ground and %d were caught; %d take-downs in all", K.count.staggers, K.count.falls, K.count.recoveries, K.count.takedowns)
	Tally("neuro_collapse")
end)

S.Add("neuro_anim_authority", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local D, A = NT.Debug, NT.Anim
	local p = S.FindSpot({ open = 260, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local v0 = A.violations
	Client("authority", { reset = true })
	local function Case(name, fn, hold)
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		bot:Spawn()
		S.Place(bot, p, 0)
		Wait(1.6)
		ViewBody(bot, 170)
		fn()
		-- when the state became a critical one, and when the body was down
		local t0 = CurTime()
		local crit, down
		while CurTime() - t0 < 3 and not (crit and down) and bot:Alive() do
			if not crit and A.IsCritical(bot) then crit = CurTime() end
			if not down and IsValid(bot.FakeRagdoll) then down = CurTime() end
			Wait(0.015)
		end
		local st = NT.Get(bot.organism)
		local mode = st and st.anim and A.names[st.anim.mode] or "no record"
		Check(string.format("%s: the state is a critical one and the body is down, in the same moment", name), crit ~= nil and down ~= nil and down - crit <= 0.1,
			string.format("critical after %s s, down after %s s, %s", crit and string.format("%.2f", crit - t0) or "-", down and string.format("%.2f", down - t0) or "-", mode))
		Check(string.format("%s: Z-City is told it may neither get up nor be steered", name), hook.Run("Should Fake Up", bot) == false and hook.Run("CanControlFake", bot, bot.FakeRagdoll) == false)
		Wait(hold or 2.5)
		st = NT.Get(bot.organism)
		mode = st and st.anim and A.names[st.anim.mode] or "no record"
		Check(string.format("%s: seconds later it is still down and still in a critical state", name), IsValid(bot.FakeRagdoll) and (A.IsCritical(bot) or not bot:Alive()), mode)
	end
	Case("a knockout", function() D.Set(bot, "knockout", 20) end)
	Case("a convulsion", function() NT.Seizure.Force(bot, NT.Brain.Ensure(bot.organism), CurTime(), { { "tonic", 3 }, { "clonic", 8 }, { "postictal", 10 } }, 1, false) end, 4)
	Case("posturing", function() D.Set(bot, "stem", 0.85) end)
	Case("a coma", function() D.Set(bot, "diffuse", 0.8) end)
	Case("a stopped heart", function() NT.Cardio.TriggerArrest(bot, "test") end, 5)
	Case("a pistol round through both hemispheres", function()
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		for try = 1, 4 do
			if IsValid(bot.FakeRagdoll) or not bot:Alive() then break end
			centre, up, face, left = Z.HeadFrame(body)
			ABL.DevShootAt(host, centre + up * 0.8, -left, nil, 80, "9x19mmparabellum")
			Wait(0.25)
		end
	end)
	NT.Reset(bot)
	Check("on the server, no critical state was ever found on a body that was not down", A.violations == v0, string.format("%d such steps", A.violations - v0))
	results.authority = nil
	Client("authority", {})
	local t0 = CurTime()
	while not results.authority and CurTime() - t0 < 3 do Wait(0.1) end
	local r = results.authority
	Check("on the client, no critical state was ever drawn on a standing body", r ~= nil and (r.frames or -1) == 0, r and string.format("%d frames", r.frames or -1) or "no answer")
	Tally("neuro_anim_authority")
end)

------------------------------------------------------------------------------------------
-- Which sequences and pose parameters the player models carry: what a base animation through
-- GM:CalcMainActivity could be made of at all. Read, not assumed.
------------------------------------------------------------------------------------------
S.Add("neuro_probe_anims", function()
	local bot = S.NewBot()
	local p = S.FindSpot({ open = 200, outdoor = true })
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	Log("-- model %s", tostring(bot:GetModel()))
	local list = bot:GetSequenceList() or {}
	local n = 0
	for _ in pairs(list) do n = n + 1 end
	Log("  %d sequences", n)
	local words = { "zombie", "death", "injur", "wound", "limp", "stagger", "stumble", "cower", "scared", "flinch", "fall", "lay", "lie", "sit", "seiz", "convuls", "pain", "hurt", "collapse", "faint", "knock", "drunk", "idle_all", "swim", "prone", "crawl" }
	local found = {}
	for id, name in pairs(list) do
		local l = string.lower(name)
		for _, w in ipairs(words) do
			if string.find(l, w, 1, true) then
				found[w] = found[w] or {}
				table.insert(found[w], string.format("%s (%.1f s)", name, bot:SequenceDuration(id)))
				break
			end
		end
	end
	for _, w in ipairs(words) do
		local f = found[w]
		if f then
			table.sort(f)
			local line = table.concat(f, ", ")
			while #line > 0 do
				Log("  %-9s %s", w, string.sub(line, 1, 220))
				line = string.sub(line, 221)
				w = ""
			end
		else
			Log("  %-9s none", w)
		end
	end
	local pp = {}
	for i = 0, bot:GetNumPoseParameters() - 1 do
		local lo, hi = bot:GetPoseParameterRange(i)
		pp[#pp + 1] = string.format("%s [%.0f, %.0f]", bot:GetPoseParameterName(i), lo or 0, hi or 0)
	end
	Log("  pose parameters: %s", table.concat(pp, ", "))
	Log("  activities: flinch head %d, flinch stomach %d, flinch physics %d, cower %d, zombie walk 06 %d", bot:SelectWeightedSequence(ACT_FLINCH_HEAD), bot:SelectWeightedSequence(ACT_FLINCH_STOMACH),
		bot:SelectWeightedSequence(ACT_FLINCH_PHYSICS), bot:SelectWeightedSequence(ACT_HL2MP_IDLE_COWER or -1), bot:SelectWeightedSequence(ACT_HL2MP_WALK_ZOMBIE_06 or -1))
	-- what the candidates look like, played through Z-City's own entry for a sequence of one's choice
	if bot.PlayCustomAnims then
		for _, name in ipairs({ "pose_injured1", "pose_injured3", "idle_all_scared", "idle_all_cower", "zombie_idle_01", "zombie_slump_idle_01", "death_01", "death_04", "react_blast_base_layer" }) do
			local id, dur = bot:LookupSequence(name)
			if id and id >= 0 then
				bot:PlayCustomAnims(name, false, math.max(dur or 1, 1) * 2.2)
				Wait(math.max(dur or 1, 1) * 1.0)
				ViewBody(bot, 150)
				S.Shot("seq_" .. name)
			end
		end
		bot:PlayCustomAnims("")
		Wait(0.3)
	end
	-- who else answers the animation hooks
	for _, name in ipairs({ "CalcMainActivity", "UpdateAnimation", "DoAnimationEvent", "TranslateActivity", "Bones" }) do
		local t = hook.GetTable()[name] or {}
		local ids = {}
		for id in pairs(t) do ids[#ids + 1] = tostring(id) end
		table.sort(ids)
		Log("  hook %s: %s", name, #ids > 0 and table.concat(ids, ", ") or "nobody")
	end
end)

------------------------------------------------------------------------------------------
-- The three rules of the game for bullets in the head (neuro_headshot_rules):
--   A  one wound: survived at first, a critical state that is seen
--   B  a second wound: death at once, with no arrest before it
--   C  a rifle round: a fall, cardiac arrest for about four seconds, death
------------------------------------------------------------------------------------------
-- the way to face at a spot so that the lines of fire from the front, the back and both sides are free
local function ClearYaw(p)
	for y = 0, 315, 45 do
		local a = Angle(0, y, 0)
		local head = p + V(0, 0, 64)
		local clear = true
		for _, d in ipairs({ a:Forward(), -a:Forward(), a:Right(), -a:Right() }) do
			if util.TraceLine({ start = head, endpos = head + d * 110, mask = MASK_SHOT }).Hit then clear = false break end
		end
		if clear then return y end
	end
	return 0
end
-- One round into the head of a watched character; fired again if Z-City's bullet passed it.
-- from, off: where the gun is and where it aims, in the head's own frame (x crown, y face, z left);
-- from nil: from straight above into the middle of the head, for a body that lies. Returns the
-- time of the hit.
local function HeadShot(host, bot, ammo, from, off)
	Arm(bot)
	for try = 1, 4 do
		local body = Z.Body(bot)
		local centre, up, face, left = Z.HeadFrame(body)
		if not centre then return nil end
		local aim = from and (centre + up * off.x + face * off.y + left * off.z) or centre
		local dir = from and (up * from.x + face * from.y + left * from.z):GetNormalized() or V(0, 0, 1)
		local t = CurTime()
		ABL.DevShootAt(host, aim, dir, nil, 80, ammo)
		Wait(0.1)
		if arrived > 0 then return t end
		Wait(0.2)
		Log("    nothing arrived: fired again (%d)", try + 1)
	end
	return nil
end

-- (the bodies of earlier cases are taken away: a body that falls onto another does not lie as it would)
local corpses = {}
hook.Add("RagdollDeath", "NT_AuditCorpses", function(ply, rag) corpses[#corpses + 1] = rag end)
local function Clean()
	for i = #corpses, 1, -1 do
		if IsValid(corpses[i]) then corpses[i]:Remove() end
		corpses[i] = nil
	end
end
-- the camera nearly straight above a body
local function TopView(body)
	local centre = body:WorldSpaceCenter()
	S.View(centre + V(28, 0, 165), centre)
	Wait(0.2)
end

S.Add("neuro_headshot_rules", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local A = NT.Anim
	local p = S.FindSpot({ open = 330, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local P, R = "9x19mmparabellum", "7.62x39mm"
	local yaw = ClearYaw(p)
	-- every animation mode the watched character goes through, with its time
	local modes = {}
	hook.Add("NT_AnimState", "NT_AuditRules", function(ply, org, st, mode)
		if ply == bot then modes[#modes + 1] = { t = CurTime(), mode = mode } end
	end)
	local function Saw(name)
		for _, m in ipairs(modes) do
			if A.names[m.mode] == name then return m.t end
		end
		return nil
	end
	local function Fresh()
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		Clean()
		bot:Spawn()
		S.Place(bot, p, yaw)
		Wait(2.3)
		deaths[bot] = nil
		modes = {}
		ViewBody(bot, 150)
	end
	local function Fam()
		local st = istable(bot.organism) and NT.Get(bot.organism)
		return st and st.anim and A.Family(st.anim.mode) or nil, st and st.anim and A.names[st.anim.mode] or "no record"
	end

	Log("-- A: one pistol round in the head, from four sides")
	for _, c in ipairs({ { "front", V(0, 1, 0), V(0.8, 0, 0) }, { "front, left half", V(0, 1, 0), V(0.8, 0, 1.6) }, { "side", V(0, 0, -1), V(0.8, 0, 0) }, { "behind, low", V(0, -1, 0), V(-2.6, -0.5, 0) } }) do
		Fresh()
		Log("  - %s", c[1])
		local tag = "rule_A_" .. string.gsub(c[1], "[^%w]+", "_")
		local t = HeadShot(host, bot, P, c[2], c[3])
		Wait(0.25)
		local fam, mode = Fam()
		Check(string.format("A, %s: alive, down and in a critical state within a third of a second", c[1]),
			t ~= nil and bot:Alive() and IsValid(bot.FakeRagdoll) and fam == "HEAD_TRAUMA_CRITICAL", string.format("alive %s, down %s, %s (%s), wound %s of this life",
				tostring(bot:Alive()), tostring(IsValid(bot.FakeRagdoll)), tostring(fam), mode, tostring(bot.NT_headWounds)))
		S.Shot(tag .. "_1")
		Wait(1.6)
		local st = NT.Get(bot.organism)
		Check(string.format("A, %s: it holds the posture of the first moments and does not breathe", c[1]),
			st ~= nil and Saw("ABNORMAL_POSTURING") ~= nil and st.respPattern ~= NT.CardioResp.Pattern.NORMAL,
			st and string.format("%s, breathing: %s", A.names[st.anim.mode], NT.CardioResp.PatternNames[st.respPattern or 0]) or "no record")
		S.Shot(tag .. "_2")
		Wait(3.4)
		fam, mode = Fam()
		Check(string.format("A, %s: five seconds after the hit it is alive, down and in a critical state", c[1]), bot:Alive() and deaths[bot] == nil and IsValid(bot.FakeRagdoll) and fam ~= nil,
			string.format("%s | %s", mode, NLine(bot)))
		S.Shot(tag .. "_3")
		Wait(15)
		fam, mode = Fam()
		Check(string.format("A, %s: twenty seconds after the hit it is alive and has not got up", c[1]), bot:Alive() and deaths[bot] == nil and IsValid(bot.FakeRagdoll),
			string.format("%s | %s", mode, NLine(bot)))
		Disarm()
	end

	Log("-- B: a second pistol round, three seconds after the first")
	Fresh()
	do
		local t1 = HeadShot(host, bot, P, V(0, 0, -1), V(0.8, 0, 0))
		Wait(3)
		local alive1 = bot:Alive()
		local passed, held = Z.spasmPassed or 0, Z.spasmHeld or 0
		-- (the body lies: from straight above)
		local t2 = HeadShot(host, bot, P)
		Wait(0.2)
		local died = deaths[bot]
		Check("B: alive after the first round, dead in the same moment as the second", t1 ~= nil and alive1 and t2 ~= nil and died ~= nil and died - t2 < 0.12,
			string.format("alive after the first: %s; died %s s after the second; wound %s", tostring(alive1), died and t2 and string.format("%.2f", died - t2) or "-", tostring(bot.NT_headWounds)))
		Check("B: no cardiac arrest was shown before it", Saw("CARDIAC_ARREST") == nil and Saw("TERMINAL_COLLAPSE") == nil)
		Check("B: the death is Z-City's own (its response to a death was left to run)", (Z.spasmPassed or 0) == passed + 1 and (Z.spasmHeld or 0) == held,
			string.format("passed on %d, held back %d", (Z.spasmPassed or 0) - passed, (Z.spasmHeld or 0) - held))
		S.Shot("rule_B_dead")
		Disarm()
	end

	Log("-- C: one rifle round in the head")
	Fresh()
	do
		local hold = C.sv.rifleArrest:GetFloat()
		local held = Z.spasmHeld or 0
		local t = HeadShot(host, bot, R, V(0, 0, -1), V(0.8, 0, 0))
		Wait(0.2)
		local fam, mode = Fam()
		Check("C: alive, down and in a critical state at once", t ~= nil and bot:Alive() and IsValid(bot.FakeRagdoll) and fam == "HEAD_TRAUMA_CRITICAL",
			string.format("alive %s, down %s, %s (%s)", tostring(bot:Alive()), tostring(IsValid(bot.FakeRagdoll)), tostring(fam), mode))
		S.Shot("rule_C_1_fall")
		Wait(math.max(C.Headshot.collapse + 0.35 - (CurTime() - (t or CurTime())), 0))
		fam, mode = Fam()
		local tArrest = Saw("CARDIAC_ARREST")
		Check("C: cardiac arrest after the fall", fam == "CARDIAC_ARREST" and tArrest ~= nil and t ~= nil and tArrest - t <= C.Headshot.collapse + 0.3,
			string.format("%s, %s s after the hit", mode, tArrest and t and string.format("%.2f", tArrest - t) or "-"))
		S.Shot("rule_C_2_arrest_begins")
		local t0 = CurTime()
		while not deaths[bot] and CurTime() - t0 < hold + 3 do Wait(0.05) end
		local died = deaths[bot]
		local due = C.Headshot.collapse + hold
		Check(string.format("C: death %.1f s after the hit, give or take 0.6", due), t ~= nil and died ~= nil and math.abs((died - t) - due) <= 0.6,
			died and t and string.format("%.2f s", died - t) or "still alive")
		Check("C: nothing in those seconds was a convulsion or a posture", Saw("SEIZURE") == nil and Saw("ABNORMAL_POSTURING") == nil)
		Check("C: the body stays as it lay (Z-City's stiffening of the corpse was held back)", (Z.spasmHeld or 0) == held + 1, string.format("held back %d", (Z.spasmHeld or 0) - held))
		Wait(0.6)
		ViewBody(BodyOf(bot), 150)
		S.Shot("rule_C_3_dead")
		Disarm()
	end
	hook.Remove("NT_AnimState", "NT_AuditRules")

	Log("-- the rules switched off: the model judges (a rifle round is death at once)")
	RunConsoleCommand("neuro_headshot_rules", "0")
	Wait(0.3)
	Fresh()
	do
		local t = HeadShot(host, bot, R, V(0, 0, -1), V(0.8, 0, 0))
		Wait(0.2)
		Check("rules off: a rifle round is death in the same moment", t ~= nil and deaths[bot] ~= nil and deaths[bot] - t < 0.12)
		Disarm()
	end
	RunConsoleCommand("neuro_headshot_rules", "1")
	Wait(0.3)
	Clean()
	Tally("neuro_headshot_rules")
end)

------------------------------------------------------------------------------------------
-- neuro_getup: the count of head wounds "of one life" (sv_injury.lua, the PlayerSpawn hook
-- NT_HeadWounds) and Z-City's way of getting a living player up from its ragdoll. hg.FakeUp runs
-- the hook "Fake Up" and then spawns the player anew in the same call; the game calls a hook's
-- functions in the order of its table and stops at the first that returns a value, and two of
-- Z-City's own return false for such a spawn: a handler that stands before them is run by every
-- get-up. The handler is counted where it stands (the same key, so the order stays), and the
-- count is read before hg.FakeUp and as it returns. The numbers are in the server's log.
--   A  two pistol rounds in the brain with no get-up between them (the rule: the second is
--      death); then the player lives again
--   B  one round, a get-up at once (hg.FakeUp(bot, true, true)), a second round, and a third
--   C  a player with a count lies down and gets up as a player's own key does it (hg.FakeUp(bot))
--   D  a living player with a count is spawned anew without dying
--   E  spawned anew in the very tick of a get-up
-- (C to E begin with a count set by hand, and say so: no round is fired in them.)
------------------------------------------------------------------------------------------
S.Add("neuro_getup", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local I = NT.Injury
	local HOOK = "NT_HeadWounds"
	local orig = (hook.GetTable().PlayerSpawn or {})[HOOK]
	if not isfunction(orig) then Log("neuro_getup: no PlayerSpawn hook %s on this server", HOOK) return end
	if not (hg and hg.Fake and hg.FakeUp) then Log("neuro_getup: no hg.Fake and hg.FakeUp here") return end
	local p = S.FindSpot({ open = 330, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	if not IsValid(bot) then return end
	local P = "9x19mmparabellum"
	local yaw = ClearYaw(p)
	Log("  neuro_getup: neuro_headshot_rules %s, the takeover %s, the module %s", C.sv.headshot:GetBool() and "on" or "off", Z.Takeover() and "on" or "off", NT.Enabled() and "on" or "off")

	-- (the handler where it stands in the hook's table, counted; and Z-City's own sign that a body
	-- is made new, which is that it clears the organism)
	local calls, cleared = 0, 0
	hook.Add("PlayerSpawn", HOOK, function(ply, ...)
		if ply == bot then calls = calls + 1 end
		return orig(ply, ...)
	end)
	hook.Add("Org Clear", "NT_GetupProbe", function(org)
		if istable(org) and org.owner == bot then cleared = cleared + 1 end
	end)
	local function Restore()
		hook.Add("PlayerSpawn", HOOK, orig)
		hook.Remove("Org Clear", "NT_GetupProbe")
	end
	do
		local names, at = {}, {}
		for k in pairs(hook.GetTable().PlayerSpawn or {}) do
			names[#names + 1] = tostring(k)
			at[tostring(k)] = #names
		end
		Log("  neuro_getup: PlayerSpawn has %d hooks, called in this order: %s", #names, table.concat(names, ", "))
		Log("  neuro_getup: of those %s is number %s; Z-City's two that end the call for a get-up are numbers %s and %s", HOOK, tostring(at[HOOK]), tostring(at["!!!!!!"]), tostring(at.z))
	end

	local function Fresh()
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		Clean()
		bot:Spawn()
		S.Place(bot, p, yaw)
		Wait(2.3)
		deaths[bot] = nil
		ViewBody(bot, 150)
	end
	local function State()
		return string.format("alive %s, in a ragdoll %s, count %s", tostring(bot:Alive()), tostring(IsValid(bot.FakeRagdoll)), tostring(bot.NT_headWounds))
	end
	-- One pistol round into the head (from the side into a body that stands, from above into one
	-- that lies): what the count was and is, how many rounds the module judged in the brain, and
	-- whether the player died of it. Returns the time of death, or nil.
	local function Round(tag, what)
		local n0, j0 = bot.NT_headWounds, I.triaged or 0
		local lying = IsValid(bot.FakeRagdoll)
		local t
		if lying then t = HeadShot(host, bot, P) else t = HeadShot(host, bot, P, V(0, 0, -1), V(0.8, 0, 0)) end
		Wait(0.25)
		local died = deaths[bot]
		Log("  neuro_getup %s: %s into a body that %s%s: the count of head wounds was %s and is %s; rounds the module judged in the brain: %d; %s",
			tag, what, lying and "lies" or "stands", t and "" or " (NOTHING ARRIVED)", tostring(n0), tostring(bot.NT_headWounds), (I.triaged or 0) - j0,
			(died and t) and string.format("the player died %.2f s after it", died - t) or (bot:Alive() and "the player is alive" or "the player is dead"))
		return died
	end
	-- hg.FakeUp with the count read before it and as it returns. quiet: nothing is said of a call
	-- that Z-City refused.
	local function GetUp(tag, forced, instant, quiet)
		local n0, k0, o0, tick = bot.NT_headWounds, calls, cleared, engine.TickCount()
		local ok = hg.FakeUp(bot, forced, instant)
		local n1 = bot.NT_headWounds
		if ok == true or not quiet then
			Log("  neuro_getup %s: hg.FakeUp(bot, %s, %s) gave %s: the count of head wounds was %s before it and is %s as it returns (in the same tick: %s); in it the handler %s was called %d time(s) on PlayerSpawn, and Z-City cleared the organism %d time(s)",
				tag, tostring(forced), tostring(instant), tostring(ok), tostring(n0), tostring(n1), tostring(engine.TickCount() == tick), HOOK, calls - k0, cleared - o0)
		end
		return n0, n1, ok
	end

	Log("-- A: two rounds in the brain with no get-up between them; then the player lives again")
	Fresh()
	do
		Round("A", "the first round")
		Wait(3)
		local died = deaths[bot]
		if bot:Alive() then died = Round("A", "the second round, 3 s on") end
		Check("A: with no get-up between them the second round in the brain is death", died ~= nil and bot.NT_headWounds == 2, State())
		Disarm()
		Wait(1.0)
		local n0, k0, o0 = bot.NT_headWounds, calls, cleared
		bot:Spawn()
		local n1, k1, o1 = bot.NT_headWounds, calls - k0, cleared - o0
		Wait(1.0)
		Log("  neuro_getup A: the count was %s; the player lives again (bot:Spawn()): it is %s as the call returns; in the call the handler was called %d time(s) and Z-City cleared the organism %d time(s) (%d a second later)",
			tostring(n0), tostring(n1), k1, o1, cleared - o0)
		Check("A: a new life begins without a count", n0 ~= nil and n1 == nil and k1 == 1, State())
	end

	Log("-- B: one round, a get-up at once, a second round, and a third")
	Fresh()
	do
		Round("B", "the first round")
		Wait(1.5)
		Log("  neuro_getup B: before the get-up: %s", State())
		local n0, n1, ok = GetUp("B", true, true)
		bot:Freeze(true)
		if ok == true then
			Check("B: a get-up leaves the count of head wounds as it was", n0 ~= nil and n1 == n0, string.format("%s before, %s after", tostring(n0), tostring(n1)))
		else
			Log("  neuro_getup B: no get-up took place: nothing measured")
		end
		Wait(2.5)
		Log("  neuro_getup B: 2.5 s on: %s", State())
		if ok == true and bot:Alive() then
			local died = Round("B", "the second round of this life, after the get-up")
			Check("B: the second round in the brain of a life is death, with a get-up before it too", died ~= nil, State())
			if bot:Alive() then
				Wait(2.5)
				Round("B", "a third round, with no get-up before it")
				Log("  neuro_getup B: after the third round: %s", State())
			end
		elseif ok == true then
			Log("  neuro_getup B: the player died before a second round could be fired (the trace above says of what)")
		end
		Disarm()
	end

	Log("-- C: a player with a count lies down and gets up as a player's own key does it")
	Fresh()
	do
		bot.NT_headWounds = 1
		Log("  neuro_getup C: the count is set by hand to 1 on a player that is whole (no round was fired)")
		-- (what the head meets as the body is laid down is not to make a patient of it: Z-City
		-- would then not let it up)
		I.muted = true
		hg.Fake(bot)
		Wait(1.5)
		I.muted = nil
		Log("  neuro_getup C: lying: %s", State())
		local t0 = CurTime()
		local n0, n1, ok
		repeat
			n0, n1, ok = GetUp("C", nil, nil, true)
			if ok ~= true then Wait(0.2) end
		until ok == true or CurTime() - t0 > 8
		if ok == true then
			Log("  neuro_getup C: Z-City let the player up %.1f s after the first try", CurTime() - t0)
			Check("C: a player's own get-up leaves the count of head wounds as it was", n0 ~= nil and n1 == n0, string.format("%s before, %s after", tostring(n0), tostring(n1)))
		else
			Log("  neuro_getup C: Z-City did not let the player up within 8 s: nothing measured (%s)", State())
		end
		-- (the ragdoll of such a get-up goes a second later)
		Wait(1.6)
		bot:Freeze(true)
	end

	Log("-- D: a living player with a count is spawned anew without dying")
	do
		bot.NT_headWounds = 1
		local k0, o0 = calls, cleared
		bot:Spawn()
		local n1, k1, o1 = bot.NT_headWounds, calls - k0, cleared - o0
		Log("  neuro_getup D: the count is set by hand to 1; bot:Spawn() on the living player: it is %s as the call returns; in the call the handler was called %d time(s) and Z-City cleared the organism %d time(s)",
			tostring(n1), k1, o1)
		Check("D: a player spawned anew begins without a count", n1 == nil and k1 == 1)
		Wait(1.0)
	end

	Log("-- E: spawned anew in the very tick of a get-up")
	do
		S.Place(bot, p, yaw)
		Wait(1.2)
		bot.NT_headWounds = 1
		hg.Fake(bot)
		Wait(1.5)
		local tick = engine.TickCount()
		local _, n1 = GetUp("E", true, true)
		bot:Spawn()
		Log("  neuro_getup E: the count is set by hand to 1; it is %s after hg.FakeUp(bot, true, true) and %s after bot:Spawn() in the same tick (the same tick: %s)",
			tostring(n1), tostring(bot.NT_headWounds), tostring(engine.TickCount() == tick))
		Wait(1.0)
	end
	Restore()
	Clean()
	Tally("neuro_getup")
end)

------------------------------------------------------------------------------------------
-- The body in cardiac arrest, for the eye and by the numbers: a rifle round from three sides, and
-- an arrest of a body that already lies on its back, on its face, on its side. Frames from 150
-- and 300 units through the seconds of the arrest; what the client draws once the body has been
-- let fall.
------------------------------------------------------------------------------------------
S.Add("neuro_arrest_pose", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local p = S.FindSpot({ open = 330, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local yaw = ClearYaw(p)
	local function Fresh()
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		Clean()
		bot:Spawn()
		S.Place(bot, p, yaw)
		Wait(2.3)
		deaths[bot] = nil
		ViewBody(bot, 150)
	end
	-- Frames and numbers, from the moment the arrest begins. quiet: an arrest made by hand, without
	-- the jerks and gasps some arrests have. slow: the body had lain for a while (it only lets go).
	local function Through(tag, quiet, slow)
		local t0 = CurTime()
		local st
		while CurTime() - t0 < 2.5 do
			st = istable(bot.organism) and NT.Get(bot.organism)
			if st and st.arrestSince then break end
			Wait(0.02)
		end
		local rag = bot.FakeRagdoll
		if not (st and st.arrestSince) or not IsValid(rag) then
			Log("  %s: no arrest (%s)", tag, NLine(bot))
			Check(tag .. ": an arrest began", false)
			return
		end
		if quiet then
			st.gasp, st.jerksFrom = nil, nil
		end
		local a0 = CurTime()
		local function At(s, name, dist)
			Wait(math.max(a0 + s - 0.25 - CurTime(), 0))
			local body = BodyOf(bot)
			if body == bot then return end
			ViewBody(body, dist or 150)
			S.Shot(string.format("pose_%s_%s", tag, name))
		end
		At(0.3, "1_begins")
		At(slow and 1.2 or 0.75, "2_falling_open")
		At(slow and 2.4 or 1.3, "3_let_fall")
		if BodyOf(bot) ~= bot then
			TopView(BodyOf(bot))
			S.Shot(string.format("pose_%s_3_top", tag))
		end
		if not quiet then At(2.6, "4_gasp") end
		-- what is drawn when the body has been let go (and the gasp is over)
		Wait(math.max(a0 + (slow and 3.7 or 3.3) - CurTime(), 0))
		local r = Motion(bot, "pose_" .. tag, 0.5)
		At(0, "5_300", 300)
		Check(tag .. ": flat on the ground, not propped up", r ~= nil and (r.chest or 99) < 9, r and string.format("chest %.1f above the lowest point", r.chest or -1) or "nothing measured")
		if slow then
			Check(tag .. ": the legs let go: apart, or one of them bent outward", r ~= nil and ((r.feetApart or 0) >= 12 or math.abs((r.kneeR or 0) - (r.kneeL or 0)) >= 25),
				r and string.format("knees %.0f and %.0f, feet %.0f apart, face turned %.0f", r.kneeR or -1, r.kneeL or -1, r.feetApart or -1, r.faceTurn or 0) or "nothing measured")
		else
			Check(tag .. ": one arm flung out; the legs let go: apart, or one of them bent outward", r ~= nil and math.max(r.handChestR or 0, r.handChestL or 0) >= 18
				and ((r.feetApart or 0) >= 12 or math.abs((r.kneeR or 0) - (r.kneeL or 0)) >= 25),
				r and string.format("hands %.0f and %.0f from the chest, %.0f and %.0f from the hips, elbows %.0f and %.0f, knees %.0f and %.0f, feet %.0f apart, face turned %.0f",
					r.handChestR or -1, r.handChestL or -1, r.handHipR or -1, r.handHipL or -1, r.elbowR or -1, r.elbowL or -1, r.kneeR or -1, r.kneeL or -1, r.feetApart or -1, r.faceTurn or 0) or "nothing measured")
		end
		Check(tag .. ": still: nothing moves, the chest does not rise", r ~= nil and math.max(r.rangeR_Hand or 99, r.rangeL_Hand or 99, r.rangeHead1 or 99) < 3 and (r.chestHi or 99) - (r.chestLo or 0) < 0.8,
			r and string.format("hands moved %.1f and %.1f, head %.1f, chest rises %.1f", r.rangeR_Hand or -1, r.rangeL_Hand or -1, r.rangeHead1 or -1, (r.chestHi or 99) - (r.chestLo or 0)) or "nothing measured")
	end

	Log("-- a rifle round in the head (rule C), from three sides")
	for _, c in ipairs({ { "side", V(0, 0, -1), V(0.8, 0, 0) }, { "front", V(0, 1, 0), V(0.8, 0, 0) }, { "behind", V(0, -1, 0), V(0.8, 0, 0) } }) do
		Fresh()
		Log("  - %s", c[1])
		local t = HeadShot(host, bot, "7.62x39mm", c[2], c[3])
		S.Shot("pose_rifle_" .. c[1] .. "_0_hit")
		Wait(0.3)
		S.Shot("pose_rifle_" .. c[1] .. "_0_fall")
		if t then Through("rifle_" .. c[1], false) else Log("    the shot did not arrive") end
		local t0 = CurTime()
		while not deaths[bot] and CurTime() - t0 < 3 do Wait(0.05) end
		Wait(0.5)
		if BodyOf(bot) ~= bot then
			ViewBody(BodyOf(bot), 150)
			S.Shot("pose_rifle_" .. c[1] .. "_6_dead")
		end
		Disarm()
	end

	Log("-- an arrest of a body that has lain for a while: it only lets go")
	for _, how in ipairs({ "back", "front", "side" }) do
		Fresh()
		Log("  - on its %s", how)
		if istable(bot.organism) then bot.organism.godmode = true end
		hg.Fake(bot)
		Wait(0.3)
		if IsValid(bot.FakeRagdoll) then ABL.DevPose(bot.FakeRagdoll, how, false) end
		Wait(C.Motor.arrestFresh + 0.6)
		bot.organism.godmode = false
		NT.Cardio.TriggerArrest(bot, "test")
		Through("lying_" .. how, true, true)
	end
	Log("-- an arrest that finds a character on its feet: it folds, and falls open")
	Fresh()
	NT.Cardio.TriggerArrest(bot, "test")
	Through("standing", true)
	NT.Reset(bot)
	Clean()
	Tally("neuro_arrest_pose")
end)

------------------------------------------------------------------------------------------
-- The spinal cord (sv_spine.lua): Z-City's three spine organs read as what the cord still
-- conducts, graded below Z-City's own "broken" values, per level and per half; and the trace of a
-- signal from the key to the limb (brain_trace, brain_show_signal).
------------------------------------------------------------------------------------------
S.Add("neuro_spine", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local SP, D = NT.Spine, NT.Debug
	local devWas = C.sv.dev:GetBool()
	RunConsoleCommand("neuro_dev", "1")
	local p = S.FindSpot({ open = 420, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	local fwd = V(1, 0, 0)
	local walk
	S.Drive(bot, function(ply, cmd)
		if not walk then return end
		cmd:SetViewAngles(fwd:Angle())
		ply:SetEyeAngles(fwd:Angle())
		cmd:SetForwardMove(10000)
		local b = IN_FORWARD
		if walk.run then b = bit.bor(b, IN_SPEED) end
		cmd:SetButtons(b)
		NT.ApplyControl(ply, cmd)
	end)
	-- The line this scene walks and runs: the direction with the most room. (A spot is clear for
	-- its 420 units in seven directions of eight, and a run goes 830 units past it; in run r25a
	-- the uninjured run, which is the measure for "cannot run", came to 97 units a second instead
	-- of 340.)
	do
		local best = -1
		local mid = p + V(0, 0, 40)
		local mins, maxs = V(-16, -16, -30), V(16, 16, 30)
		for i = 0, 7 do
			local d = V(math.cos(i * math.pi / 4), math.sin(i * math.pi / 4), 0)
			local back = util.TraceHull({ start = mid, endpos = mid - d * 400, mins = mins, maxs = maxs, mask = MASK_PLAYERSOLID_BRUSHONLY })
			if not back.Hit then
				local ahead = util.TraceHull({ start = mid, endpos = mid + d * 1400, mins = mins, maxs = maxs, mask = MASK_PLAYERSOLID_BRUSHONLY })
				if ahead.Fraction * 1400 > best then fwd, best = d, ahead.Fraction * 1400 end
			end
		end
		Log("  the line it walks: %.0f units of room ahead of the spot (a run needs 850)", best)
	end
	local start = p - fwd * 380
	-- And nobody else on it: the bots of earlier scenes stay on the map.
	do
		local side = fwd:Cross(V(0, 0, 1))
		local moved = 0
		for _, o in ipairs(player.GetBots()) do
			if o ~= bot then
				local body = Z.Body(o)
				local rel = (IsValid(body) and body:GetPos() or o:GetPos()) - start
				local along, across = rel:Dot(fwd), rel:Dot(side)
				if along > -80 and along < 1500 and math.abs(across) < 140 then
					Log("  %s is on the line (%.0f units along it, %.0f beside it): moved away", o:Nick(), along, across)
					o:Spawn()
					S.Place(o, p + side * 260 - fwd * (200 - 70 * moved), 0)
					moved = moved + 1
				else
					Log("  %s is off the line (%.0f units along it, %.0f beside it)", o:Nick(), along, across)
				end
			end
		end
		if moved > 0 then Wait(1.2) end
	end
	local function Fresh()
		walk = nil
		if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
		bot:Spawn()
		S.Place(bot, start, 0)
		Wait(1.5)
		S.View(p + V(0, 300, 140), p + V(0, 0, 30))
	end
	-- forward speed over two seconds of the walking key, and whether the body is still on its feet
	local function Walk(opt)
		bot:Freeze(false)
		walk = opt or {}
		Wait(0.8)
		local p1 = bot:GetPos()
		Wait(2)
		local p2 = bot:GetPos()
		local up = not IsValid(bot.FakeRagdoll)
		walk = nil
		return (p2 - p1):Dot(fwd) / 2, up
	end
	local function Rec(wait)
		local t0 = CurTime()
		while CurTime() - t0 < (wait or 2) do
			local st = istable(bot.organism) and NT.Get(bot.organism)
			-- (a record is made by the watch first and worked out with its next step)
			if st and st.legL and (st.cordHurt or next(st.an.td) ~= nil) then return st end
			Wait(0.1)
		end
		return istable(bot.organism) and NT.Get(bot.organism) or nil
	end
	local function Limbs(st)
		return string.format("arms %.2f %.2f, hands %.2f %.2f, legs %.2f %.2f, trunk %.2f", st.armL, st.armR, st.handL, st.handR, st.legL, st.legR, st.trunk)
	end
	local function Trace(key)
		for _, l in ipairs(D.TraceLines(bot, key)) do Log("    %s", l) end
	end
	local broken = { tonumber(hg.organism.fake_spine1) or 1, tonumber(hg.organism.fake_spine2) or 1, tonumber(hg.organism.fake_spine3) or 0.5 }
	Log("  Z-City's own values for a broken spine: lower %.2f, upper %.2f, neck %.2f", broken[1], broken[2], broken[3])

	Log("-- uninjured")
	Fresh()
	local v0, up0 = Walk()
	local vr0 = Walk({ run = true })
	Log("  walking %.0f units a second, running %.0f, on its feet %s, record %s", v0, vr0, tostring(up0), tostring(NT.Get(bot.organism) ~= nil))
	Check("uninjured: no record, and the trace says so", NT.Get(bot.organism) == nil and #D.TraceLines(bot, "walk") >= 2)

	Log("-- the lower spine at 0.6 of broken: the bone is past bruised, the cord half conducts")
	Fresh()
	bot.organism.spine1 = 0.6 * broken[1]
	local st = Rec(2)
	Check("a hurt spine gives the character a record without any injury of the head", st ~= nil and st.cordHurt == true, st and Limbs(st) or "no record")
	if st then
		Check("the legs are weak on both sides, the arms and hands are not", st.legL < 0.75 and st.legR < 0.75 and st.legL > 0.3 and st.armL > 0.95 and st.handR > 0.95, Limbs(st))
		local v, up = Walk()
		local vr = Walk({ run = true })
		local run = NT.Limits(bot)
		Check("it walks, more slowly, and cannot run", up and v < v0 * 0.9 and v > 10 and run == false and vr < vr0 * 0.75,
			string.format("walking %.0f (uninjured %.0f), with the run key %.0f (uninjured %.0f), may run %s, on its feet %s", v, v0, vr, vr0, tostring(run), tostring(up)))
		Check("Z-City's own rule has not been touched: it still says the character can move", bot.organism.canmove == true, tostring(bot.organism.canmove))
		Trace("walk")
		-- the live trace on the host's screen, while the bot walks
		walk = {}
		host:ConCommand("brain_show_signal " .. bot:EntIndex())
		Wait(1.4)
		S.Shot("spine_signal_walk")
		walk = nil
		host:ConCommand("brain_show_off")
	end

	Log("-- the lower spine at 0.9 of broken: the legs do not carry")
	Fresh()
	bot.organism.spine1 = 0.9 * broken[1]
	st = Rec(2)
	Wait(2)
	Check("the legs give way before Z-City's own value is reached; the arms still work", st ~= nil and st.legL < 0.25 and st.armL > 0.95 and IsValid(bot.FakeRagdoll) and bot.organism.canmove == true,
		st and string.format("%s | down %s | Z-City: can move %s", Limbs(st), tostring(IsValid(bot.FakeRagdoll)), tostring(bot.organism.canmove)) or "no record")

	Log("-- the upper spine at 0.6 of broken")
	Fresh()
	bot.organism.spine2 = 0.6 * broken[2]
	st = Rec(2)
	Check("legs and trunk are weak, arms and hands are not", st ~= nil and st.legL < 0.75 and st.trunk < 0.95 and st.armL > 0.95 and st.handL > 0.95, st and Limbs(st) or "no record")
	-- healed (Z-City's value back at nothing)
	bot.organism.spine2 = 0
	Wait(3.5)
	Check("the record closes when the cord is whole again", NT.Get(bot.organism) == nil, NT.Get(bot.organism) and NLine(bot) or nil)

	Log("-- the neck at 0.6 of broken")
	Fresh()
	bot.organism.spine3 = 0.6 * broken[3]
	st = Rec(2)
	Wait(1)
	Check("arms, hands and legs are weak, and breathing is no longer regular", st ~= nil and st.armL < 0.75 and st.handR < 0.75 and st.legL < 0.75 and st.resp < 0.8 and st.resp > 0.4
		and st.respPattern ~= NT.CardioResp.Pattern.NORMAL,
		st and string.format("%s | breathing %.2f (%s)", Limbs(st), st.resp, NT.CardioResp.PatternNames[st.respPattern or 0]) or "no record")
	Trace("attack")

	Log("-- one half of the lower cord, by the module's own call")
	Fresh()
	NT.DamageRegion(bot, "L_cord_lumbar", 0.6)
	st = Rec(2)
	Wait(0.5)
	local _, _, _, _, veer = NT.Limits(bot)
	Check("the left leg is weak, the right is not, and the walk is pulled to the weak side", st ~= nil and st.legL < 0.5 and st.legR > 0.95 and (veer or 0) > 0,
		st and string.format("%s | pulled %s", Limbs(st), tostring(veer)) or "no record")

	Log("-- Z-City's own value for a broken upper spine")
	Fresh()
	bot.organism.spine2 = broken[2]
	st = Rec(2)
	Wait(1.5)
	Check("at its value Z-City's rule applies as before (cannot move, down), and the model agrees: nothing reaches the legs", st ~= nil and st.legL < 0.02 and st.armL > 0.95
		and bot.organism.canmove == false and IsValid(bot.FakeRagdoll),
		st and string.format("%s | Z-City: can move %s, down %s", Limbs(st), tostring(bot.organism.canmove), tostring(IsValid(bot.FakeRagdoll))) or "no record")


	Log("-- a pistol round into the lower back, from behind")
	Fresh()
	Arm(bot)
	do
		local body = Z.Body(bot)
		local pb = body:LookupBone("ValveBiped.Bip01_Pelvis")
		local m = pb and body:GetBoneMatrix(pb)
		local was = tonumber(bot.organism.spine1) or 0
		if m then
			-- (Z-City's box for the lower spine sits at this place of the pelvis bone)
			local at = LocalToWorld(V(0, 2, -5), angle_zero, m:GetTranslation(), m:GetAngles())
			for try = 1, 4 do
				ABL.DevShootAt(host, at, -bot:GetForward(), nil, 80, "9x19mmparabellum")
				Wait(0.4)
				if (tonumber(bot.organism.spine1) or 0) > was then break end
			end
		end
		Wait(1.2)
		local now = tonumber(bot.organism.spine1) or 0
		st = NT.Get(bot.organism)
		Log("  Z-City's lower spine: %.2f before, %.2f after | %s", was, now, st and (Limbs(st) .. " | " .. SP.Describe(st, st.an.tsrc.spine)) or "no record")
		if now > was + 0.25 * broken[1] then
			Check("a bullet that reached the spine weakens the legs through the cord", st ~= nil and math.min(st.legL, st.legR) < 0.9, st and Limbs(st) or "no record")
		else
			Log("  (the rounds did not reach Z-City's spine box, which is one unit wide: nothing to check)")
		end
	end
	Disarm()
	NT.Reset(bot)
	RunConsoleCommand("neuro_dev", devWas and "1" or "0")
	Tally("neuro_spine")
end)

------------------------------------------------------------------------------------------
-- The brain as a body (cl_brain3d.lua): the mesh made from the atlas, in the developer's window
-- and inside the head of a character. A scene for the eye: frames of every view, and a few checks
-- on what the client built and on what it says when a structure is asked about.
------------------------------------------------------------------------------------------
S.Add("neuro_brain3d", function()
	NT.Brain.paused = nil
	NT.Trauma.silent = nil
	local D = NT.Debug
	local devWas = C.sv.dev:GetBool()
	RunConsoleCommand("neuro_dev", "1")
	local p = S.FindSpot({ open = 260, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	Log("  a brain among the game's own models (models/gibs/humans/brain_gib.mdl): %s", tostring(file.Exists("models/gibs/humans/brain_gib.mdl", "GAME")))
	local function Ask(t, wait)
		results.brain3d = nil
		t.tag = "brain3d"
		Client("brain3d", t)
		local t0 = CurTime()
		while not results.brain3d and CurTime() - t0 < 3 do Wait(0.05) end
		Wait(wait or 0.6)
		return results.brain3d
	end
	local function Show(name, t, wait)
		local r = Ask(t, wait)
		S.Shot("brain3d_" .. name)
		return r
	end
	-- The mark and the click, against the picture itself: the client paints a body of a colour of
	-- its own at the place of what was asked about, finds it in what was painted, and clicks there.
	local function Probe(key, what)
		Ask({ probe = true }, 0.5)
		local r = Ask({}, 0.1)
		local pr = r and r.probe
		local ok = istable(pr) and (pr.n or 0) > 5
		Check("the mark of " .. what .. " is drawn on it", ok and math.abs(pr.markX - pr.drawnX) < 6 and math.abs(pr.markY - pr.drawnY) < 6,
			ok and string.format("the mark at %.0f, %.0f; the structure in the picture at %.0f, %.0f (viewport %d x %d). Vector:ToScreen put %s", pr.markX, pr.markY, pr.drawnX, pr.drawnY, pr.w or -1, pr.h or -1, tostring(pr.toScreen)) or "nothing found in the picture")
		Check("a click on " .. what .. " asks about it", ok and pr.picked == key, ok and string.format("%s (%.0f ms)", tostring(pr.picked), pr.pickMs or -1) or "")
	end

	Log("-- the window, on an uninjured character")
	host:ConCommand("brain_show_3d " .. bot:EntIndex())
	Wait(1.2)
	local r = Ask({ manual = true, open = true, preset = "Whole brain", mode = "natural", yaw = 205, pitch = 12, spin = false }, 0.5)
	-- (the lit surfaces are read and built over the first frames the window is open)
	do
		local t0 = CurTime()
		while CurTime() - t0 < 12 do
			r = Ask({}, 0.2)
			if r and r.surfReady then break end
		end
	end
	Wait(0.5)
	S.Shot("brain3d_whole_front")
	Check("the client has built the brain", r ~= nil and r.surfReady == true and (r.tris or 0) > 150000 and (r.structures or 0) > 150,
		r and string.format("%d vertices, %d triangles, %d structures that can be asked about; the bodies built in %.0f ms, one mesh a frame, and everything painted in %.1f ms; the lit surfaces read in %.0f ms and built in %.0f ms over the first frames",
			r.verts or -1, r.tris or -1, r.structures or -1, r.buildMs or -1, r.bakeAllMs or -1, r.surfLoadMs or -1, r.surfBuildMs or -1) or "no answer")
	Show("whole_left", { yaw = 270, pitch = 6 })
	Show("whole_top", { yaw = 180, pitch = 82 })
	Show("whole_back", { yaw = 20, pitch = 10 })
	Show("lobes", { mode = "lobes", yaw = 248, pitch = 14 })
	Show("territories", { mode = "vascular", yaw = 248, pitch = 14 })
	Show("vasculature", { preset = "Vasculature", mode = "natural", yaw = 215, pitch = 6 })
	Show("willis", { preset = "Circle of Willis", yaw = 200 })
	Show("deep", { preset = "Deep grey", mode = "lobes", yaw = 215, pitch = 14 })
	Show("cord", { preset = "Hindbrain and cord", mode = "natural", yaw = 235, pitch = 4 })
	r = Show("asked_motor_cortex", { preset = "Whole brain", mode = "motor", yaw = 262, pitch = 28, select = "L_precentral_hand" })
	Check("a structure that is asked about answers: name, integrity, what it carries", r ~= nil and istable(r.selected) and #r.selected >= 6,
		r and istable(r.selected) and table.concat(r.selected, " / ", 1, math.min(#r.selected, 4)) or "nothing")
	Probe("L_precentral_hand", "the hand zone of the motor cortex")

	Log("-- what is in use: the uninjured character walks")
	do
		local walking = true
		local fwd = bot:GetForward()
		S.Drive(bot, function(ply, cmd)
			if not walking then return end
			cmd:SetViewAngles(fwd:Angle())
			cmd:SetForwardMove(10000)
			cmd:SetButtons(IN_FORWARD)
		end)
		bot:Freeze(false)
		Ask({ preset = "Whole brain", mode = "activation", yaw = 250, pitch = 34, select = "none" }, 1.6)
		r = Show("in_use_walking", {}, 0.2)
		local bakes = r and r.bakes
		Check("the structures a walking character uses light up", r ~= nil and (r.glowing or 0) >= 8, r and string.format("%d structures lit", r.glowing or -1) or "no answer")
		Show("in_use_pathway", { preset = "Motor pathway", mode = "activation", yaw = 215 }, 0.6)
		walking = false
		S.Drive(bot, nil)
		Wait(2.2)
		r = Ask({}, 0.1)
		Check("and go dark when it stands, with nothing coloured again in between", r ~= nil and (r.glowing or 99) == 0 and r.bakes == bakes,
			r and string.format("%d structures lit; colourings %s then, %s now", r.glowing or -1, tostring(bakes), tostring(r.bakes)) or "no answer")
		r = Ask({ preset = "Whole brain", mode = "natural" }, 0.3)
		Log("  the window's brain takes %.2f ms of a frame to draw; the developer's stream for an uninjured character is %d bytes, twice a second", r and r.drawMs or -1, D.streamBytes or -1)
	end

	Log("-- in the head of a standing character")
	Ask({ close = true })
	Wait(0.3)
	Ask({ world = true })
	do
		local centre = Z.HeadFrame(Z.Body(bot))
		local f = bot:GetForward()
		S.View(centre + f * 34 + f:Cross(V(0, 0, 1)) * 22 + V(0, 0, 6), centre)
		Wait(0.6)
		S.Shot("brain3d_head_standing")
	end

	Log("-- injured: a bullet from temple to temple, the left half of the lower cord, the left middle cerebral artery shut")
	D.Tests.projectile(bot, { "side", "500" })
	NT.DamageRegion(bot, "L_cord_lumbar", 0.8)
	NT.DamageVessel(bot, "L_mca_m1", 0)
	Wait(3)
	do
		local body = Z.Body(bot)
		local centre = Z.HeadFrame(body)
		if centre then
			S.View(centre + V(26, 18, 30), centre)
			Wait(0.6)
			S.Shot("brain3d_head_lying")
		end
	end
	Ask({ world = false })
	host:ConCommand("brain_show_3d " .. bot:EntIndex())
	Wait(1.2)
	Show("damage", { open = true, preset = "Whole brain", mode = "damage", alpha = 0.5, yaw = 215, pitch = 14, spin = false }, 1.2)
	Show("damage_natural", { mode = "natural", alpha = 1, yaw = 270, pitch = 8 })
	Show("perfusion", { mode = "perfusion", alpha = 1, yaw = 270, pitch = 8 })
	-- (what a change in the character's state costs: one more region destroyed, the colours the same)
	Ask({ mode = "damage" }, 1.0)
	NT.DamageRegion(bot, "R_precentral_hand", 0.9)
	Wait(1.6)
	r = Ask({}, 0.1)
	Log("  one more region destroyed while its damage is shown: the paint of the surfaces and the %d cells of the bodies' palette painted again in %.1f ms (the first time: %.1f ms); no mesh built", r and r.bakeParts or -1, r and r.bakeMs or -1, r and r.bakeAllMs or -1)
	Log("  the brain in %d head(s) took %.2f ms of a frame to draw; the developer's stream for this injured character is %d bytes, twice a second", r and r.worldHeads or -1, r and r.worldMs or -1, D.streamBytes or -1)
	r = Show("motor_pathway", { preset = "Motor pathway", yaw = 215, pitch = 4, select = "L_cord_lumbar" }, 1.0)
	local said = r and istable(r.selected) and table.concat(r.selected, " / ") or ""
	-- (A fifth of it is left. What it conducts is that, less what the circulation takes off: the
	-- character bleeds from the head, and when the shock comes before this question the answer is
	-- 17 % and not 20 %: twice in six runs of phase 37, once each way within one game.)
	local conducts = tonumber(string.match(said, "Conducting now: (%d+)%%"))
	Check("the lower cord says what it still conducts", conducts ~= nil and conducts >= 12 and conducts <= 20, said)
	-- (far from the middle of the picture: where a wrong field of view would show most)
	Probe("L_cord_lumbar", "the lower cord")
	Ask({ close = true, manual = false })
	Wait(0.3)
	NT.Reset(bot)
	RunConsoleCommand("neuro_dev", devWas and "1" or "0")
	Tally("neuro_brain3d")
end)

------------------------------------------------------------------------------------------
-- A probe, not a test: what the engine does with a mesh made in Lua under a lit material
-- (cl_litprobe.lua). Two frames to look at, and brightness figures in client_neuro.txt.
------------------------------------------------------------------------------------------
S.Add("neuro_litprobe", function()
	local p = S.FindSpot({ open = 200, outdoor = true })
	S.View(p + V(0, 260, 90), p + V(0, 0, 60))
	Wait(1.0)
	Client("litprobe", { mode = "hud" })
	Wait(2.0)
	S.Shot("litprobe_hud")
	Client("litprobe", { measure = true })
	Wait(1.0)
	Client("litprobe", { mode = "world" })
	Wait(1.5)
	S.Shot("litprobe_world")
	Client("litprobe", { mode = "off" })
	Wait(0.3)
	Log("  the probe has drawn; see client_neuro.txt and the two frames")
end)

------------------------------------------------------------------------------------------
-- The look of the brain: frames only. The same brain from the sides the reference pictures show
-- it from, near and far, under each of a few settings of light and gloss (cl_brainsurf.lua,
-- BS.look). A scene for choosing by eye; it checks nothing.
------------------------------------------------------------------------------------------
S.Add("neuro_brainlook", function()
	local devWas = C.sv.dev:GetBool()
	RunConsoleCommand("neuro_dev", "1")
	local p = S.FindSpot({ open = 200, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	local function Ask(t, wait)
		results.brain3d = nil
		t.tag = "brain3d"
		Client("brain3d", t)
		local t0 = CurTime()
		while not results.brain3d and CurTime() - t0 < 3 do Wait(0.05) end
		Wait(wait or 0.4)
		return results.brain3d
	end
	host:ConCommand("brain_show_3d " .. bot:EntIndex())
	Wait(1.0)
	Ask({ manual = true, open = true, preset = "Whole brain", mode = "natural", yaw = 270, pitch = 5, spin = false }, 0.5)
	do
		local t0 = CurTime()
		while CurTime() - t0 < 14 do
			local r = Ask({}, 0.2)
			if r and r.surfReady then break end
		end
	end
	local looks = S.brainLooks or {
		{ "a", { exponent = 22, boost = 0.8 } },
		{ "b", { exponent = 50, boost = 2.2 } },
		{ "c", { exponent = 36, boost = 1.4 } },
	}
	for _, l in ipairs(looks) do
		Ask({ tune = l[2], preset = "Whole brain", select = "-", yaw = 270, pitch = 5, dist = 64, at = { 0, 0, -0.05 } }, 0.5)
		S.Shot("look_" .. l[1] .. "_left")
		Ask({ yaw = 0, pitch = 5 }, 0.4)
		S.Shot("look_" .. l[1] .. "_back")
		Ask({ yaw = 180, pitch = 5 }, 0.4)
		S.Shot("look_" .. l[1] .. "_front")
		Ask({ yaw = 262, pitch = 12, dist = 24, at = { 0.55, 0.1, 0.25 } }, 0.4)
		S.Shot("look_" .. l[1] .. "_near")
		Ask({ yaw = 250, pitch = 8, dist = 15, at = { 0.8, 0.0, 0.1 } }, 0.4)
		S.Shot("look_" .. l[1] .. "_close")
	end
	-- the other sides, under the look the viewer has by default
	Ask({ tune = looks[1][2], preset = "Whole brain", select = "-", yaw = 90, pitch = 5, dist = 64, at = { 0, 0, -0.05 } }, 0.5)
	S.Shot("view_right")
	Ask({ yaw = 180, pitch = 86 }, 0.4)
	S.Shot("view_top")
	Ask({ yaw = 180, pitch = -84 }, 0.4)
	S.Shot("view_under")
	Ask({ yaw = 232, pitch = 18 }, 0.4)
	S.Shot("view_quarter")
	Ask({ side = "L", yaw = 90, pitch = 3 }, 0.4)
	S.Shot("view_inner")
	Ask({ side = "L", yaw = 96, pitch = 6, dist = 26, at = { 0, 0.0, 0.05 } }, 0.4)
	S.Shot("view_inner_near")
	Ask({ side = "B", yaw = 20, pitch = 10, dist = 30, at = { 0, -0.75, -0.75 } }, 0.4)
	S.Shot("view_hind_near")
	Ask({ yaw = 200, pitch = -8, dist = 30, at = { 0, -0.45, -0.85 } }, 0.4)
	S.Shot("view_hind_front")
	Ask({ side = "B" }, 0.2)
	Ask({ close = true, manual = false })
	Wait(0.3)
	NT.Reset(bot)
	RunConsoleCommand("neuro_dev", devWas and "1" or "0")
	Log("  the brain was photographed under %d looks", #looks)
end)

------------------------------------------------------------------------------------------
-- The vessels of the brain as bodies (cl_brainvasc.lua): frames for the eye. The whole brain
-- with its arteries and veins on it, the vessels alone, the base and the circle under it, near
-- and far, under three lights; and a few checks on what was built and on a click.
------------------------------------------------------------------------------------------
S.Add("neuro_vessels", function()
	local devWas = C.sv.dev:GetBool()
	RunConsoleCommand("neuro_dev", "1")
	local p = S.FindSpot({ open = 200, outdoor = true })
	local host = S.Host()
	local bot = S.NewBot()
	bot:Spawn()
	S.Place(bot, p, 0)
	Wait(1.5)
	local function Ask(t, wait)
		results.brain3d = nil
		t.tag = "brain3d"
		Client("brain3d", t)
		local t0 = CurTime()
		while not results.brain3d and CurTime() - t0 < 3 do Wait(0.05) end
		Wait(wait or 0.4)
		return results.brain3d
	end
	local function Show(name, t, wait)
		local r = Ask(t, wait or 0.45)
		S.Shot("vasc_" .. name)
		return r
	end
	host:ConCommand("brain_show_3d " .. bot:EntIndex())
	Wait(1.0)
	local ALL = { cortex = true, hind = true, arteries = true, branches = true, veins = true }
	local r = Ask({ manual = true, open = true, preset = "Whole brain", mode = "natural", layers = ALL, alpha = 1, yaw = 270, pitch = 6, spin = false }, 0.5)
	do
		local t0 = CurTime()
		while CurTime() - t0 < 20 do
			r = Ask({}, 0.2)
			if r and r.surfReady then break end
		end
	end
	Check("the vessels are read and built", r ~= nil and r.surfReady == true and (r.vessels or 0) > 300 and (r.vesselTris or 0) > 80000,
		r and string.format("%d vessels, %d vertices, %d triangles in %d meshes; read in %.0f ms, built in %.0f ms over the first frames, %.1f ms the longest of them",
			r.vessels or -1, r.vesselVerts or -1, r.vesselTris or -1, r.vesselMeshes or -1, r.vesselLoadMs or -1, r.vesselBuildMs or -1, r.vesselWorstMs or -1) or "no answer")

	Log("-- the whole brain with its vessels")
	Show("whole_left", { layers = ALL, alpha = 1, select = "-", yaw = 270, pitch = 6, dist = 64, at = { 0, 0, -0.05 } })
	Show("whole_front", { yaw = 180, pitch = 5 })
	Show("whole_top", { yaw = 180, pitch = 84 })
	Show("whole_back", { yaw = 0, pitch = 8 })
	Show("whole_under", { yaw = 180, pitch = -84 })
	Show("whole_quarter", { yaw = 232, pitch = 18 })
	Wait(1.2)
	r = Ask({}, 0.1)
	local drawAll = r and r.drawMs or -1

	Log("-- at a middle distance")
	Show("med_convexity", { yaw = 262, pitch = 12, dist = 30, at = { 0.55, 0.1, 0.25 } })
	Show("med_base", { yaw = 180, pitch = -70, dist = 34, at = { 0, 0.05, -0.5 } })
	Show("med_hind", { yaw = 200, pitch = -10, dist = 32, at = { 0, -0.4, -1.0 } })
	Show("med_top", { yaw = 180, pitch = 80, dist = 34, at = { 0, -0.2, 0.9 } })
	Show("med_inner", { side = "L", yaw = 90, pitch = 3, dist = 44, at = { 0, 0, 0 } })
	Ask({ side = "B" }, 0.2)

	Log("-- near")
	Show("close_fissure", { yaw = 258, pitch = 4, dist = 14, at = { 0.72, 0.15, -0.15 } })
	Show("close_convexity", { yaw = 250, pitch = 20, dist = 12, at = { 0.7, -0.1, 0.45 } })
	Show("close_willis", { yaw = 180, pitch = -75, dist = 16, at = { 0, 0.1, -0.45 } })
	Show("close_basilar", { yaw = 185, pitch = -15, dist = 14, at = { 0, -0.15, -0.85 } })
	Show("close_sinus", { yaw = 180, pitch = 70, dist = 14, at = { 0, -0.5, 0.85 } })

	Log("-- the vessels alone")
	local ONLY = { arteries = true, branches = true, veins = true }
	Show("only_left", { layers = ONLY, yaw = 270, pitch = 6, dist = 64, at = { 0, 0, -0.05 } })
	Show("only_front", { yaw = 180, pitch = 5 })
	Show("only_top", { yaw = 180, pitch = 84 })
	Show("only_under", { yaw = 180, pitch = -84 })
	Show("only_willis", { yaw = 180, pitch = -78, dist = 22, at = { 0, 0.05, -0.45 } })
	Show("only_arteries", { layers = { arteries = true, branches = true }, yaw = 232, pitch = 14, dist = 64, at = { 0, 0, -0.05 } })
	Show("only_veins", { layers = { veins = true }, yaw = 232, pitch = 14 })
	Show("only_trunks", { layers = { arteries = true }, yaw = 200, pitch = -20, dist = 50, at = { 0, 0, -0.5 } })

	Log("-- under a clear cortex")
	Show("glass_left", { preset = "Vasculature", mode = "natural", yaw = 270, pitch = 6 })
	Show("glass_front", { yaw = 200, pitch = 6 })

	Log("-- under other lights")
	Show("light_soft", { layers = ALL, alpha = 1, yaw = 262, pitch = 12, dist = 30, at = { 0.55, 0.1, 0.25 }, tune = { key = { 0.46, 0.45, 0.43 }, fill = { 0.15, 0.16, 0.19 } } }, 0.6)
	Show("light_hard", { tune = { key = { 1.0, 0.96, 0.9 }, fill = { 0.03, 0.035, 0.05 } } }, 0.6)
	Show("light_hard_base", { yaw = 180, pitch = -70, dist = 34, at = { 0, 0.05, -0.5 } })
	Ask({ tune = { key = { 0.78, 0.76, 0.72 }, fill = { 0.07, 0.085, 0.12 } } }, 0.3)

	Log("-- the surface itself under less gloss")
	-- (as it was until phase 37, and less still than now)
	Show("gloss_before", { layers = ALL, alpha = 1, yaw = 250, pitch = 20, dist = 12, at = { 0.7, -0.1, 0.45 }, tune = { exponent = 36, boost = 1.4 } }, 0.6)
	Show("gloss_less", { tune = { exponent = 16, boost = 0.5 } }, 0.6)
	Ask({ tune = { exponent = 22, boost = 0.8 } }, 0.3)

	Log("-- whose a vessel is, and one that is shut")
	Show("territories", { mode = "vascular", layers = ALL, alpha = 1, yaw = 270, pitch = 6, dist = 64, at = { 0, 0, -0.05 } }, 1.0)
	Show("territories_only", { layers = ONLY, yaw = 232, pitch = 14 }, 0.6)
	NT.DamageVessel(bot, "L_mca_m1", 0)
	Wait(2.5)
	Show("shut", { mode = "natural", layers = ONLY, yaw = 250, pitch = 10, dist = 50, at = { 0.3, 0.1, -0.1 } }, 1.2)

	r = Ask({ vesselRay = "L_basilar_half" }, 0.2)
	Check("a ray at the basilar artery meets the basilar artery", r ~= nil and r.rayHit ~= nil and r.rayHit == r.rayWant, r and string.format("met %s, meant %s", tostring(r.rayHit), tostring(r.rayWant)) or "no answer")
	r = Ask({ vesselRay = "L_ica" }, 0.2)
	Check("a ray at the left carotid meets the left carotid", r ~= nil and r.rayHit ~= nil and r.rayHit == r.rayWant, r and string.format("met %s, meant %s", tostring(r.rayHit), tostring(r.rayWant)) or "no answer")

	-- what it costs to draw: the whole brain with every vessel, and without them
	Ask({ preset = "Whole brain", mode = "natural", layers = { cortex = true, hind = true }, alpha = 1, yaw = 232, pitch = 18 }, 2.0)
	r = Ask({}, 0.1)
	Log("  the window's brain takes %.2f ms of a frame to draw with every vessel on it, %.2f ms without the vessels", drawAll, r and r.drawMs or -1)

	Log("-- in the head of a standing character, near")
	Ask({ close = true })
	Wait(0.3)
	Ask({ world = true, layers = ALL })
	do
		local centre = Z.HeadFrame(Z.Body(bot))
		if centre then
			local f = bot:GetForward()
			S.View(centre + f * 20 + f:Cross(V(0, 0, 1)) * 14 + V(0, 0, 4), centre)
			Wait(0.8)
			S.Shot("vasc_head_near")
			S.View(centre + f * 90 + f:Cross(V(0, 0, 1)) * 40 + V(0, 0, 10), centre)
			Wait(1.5)
			S.Shot("vasc_head_far")
			r = Ask({}, 0.1)
			Log("  the brain with its vessels in %d head(s) took %.2f ms of a frame to draw from afar", r and r.worldHeads or -1, r and r.worldMs or -1)
		end
	end
	Ask({ world = false, manual = false })
	Wait(0.3)
	NT.Reset(bot)
	RunConsoleCommand("neuro_dev", devWas and "1" or "0")
	Tally("neuro_vessels")
end)
