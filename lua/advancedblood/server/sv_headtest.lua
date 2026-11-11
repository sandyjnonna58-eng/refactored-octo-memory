-- Scenes of head wounds (developer tool; only with the test harness, see sv_selftest.lua). They
-- run only when asked for by name. What the blood module holds and draws of the watched
-- character, frame by frame, is in the client's log (cl_headtest.lua, "probe").
--
--   head_obs    a bot is shot in the head while this client watches: the first seconds, the
--               camera turned away and back, a second round (by the brain module's rule: death),
--               the corpse, and the player's next life.
--   head_self   the local player's own head: the same wound on the host and on a bot, seen from
--               outside with the host drawn as the game draws one's own body, and through
--               Z-City's own camera (standing, looking down, lying in its ragdoll).
--   head_fix    the bones a body's film is drawn with (abl_film_bones 0 and 1 by turns): a bot
--               shot in the head, in bursts of pictures; the host's own head from outside and
--               through Z-City's camera.
--   head_life   one character through its lives: shot, got up from its ragdoll (the same life),
--               its organism begun again without a spawn (a new life), wounded and spawned anew
--               while alive (a new life), shot dead, its corpse, the next life.
--   head_place  a wound Z-City has at a place that is not on the part it names.
--   head_models four heads of four models, each shot and lying: is the film steady on each?
--   head_sight  a bleeding body out of the picture and in it again as the camera turns, from
--               150 units: is its blood there in the first frame the body is?
--   head_multi  two players side by side, one hit in the head three times and one once.
--   head_move   a head wound on a bot that runs to and fro, the camera going with its head.
--   head_flow   the same head wound at three values on three bots; then all closed.
--   head_perf   five bleeding bodies in the picture and behind the camera: frames per second
--               and what the module's parts cost.
--   head_host   the local player itself is shot in the head by a bot, through Z-City's own
--               camera (abl_film_bones 0, a new life, abl_film_bones 1), and got up again.
-- Pictures in bursts are measured with tools/harness/redflicker.ps1.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot
local Z = ABL.ZC

local P9 = "9x19mmparabellum"

-- The middle of a character's head, and the entity that is its body now (its corpse when dead).
local function HeadOf(ply)
	local body = ply:Alive() and Z.GetBody(ply) or Z.GetCorpse(ply)
	if not IsValid(body) then return nil end
	return ABL.DevHitboxCenter(body, "head"), body
end
local function Note(text)
	Log("  " .. text)
	Client("headnote", { text = text })
end
local function Probe(ent, name) Client("headprobe", { ent = ent:EntIndex(), name = name }) end
local function ProbeOff(ent) if IsValid(ent) then Client("headprobe", { ent = ent:EntIndex(), off = true }) end end
local function MarkCam(kind, dist, fov)
	Client("viewmark", { kind = kind or "entry", dist = dist or 16, tilt = 24, spin = 0, fov = fov or 40, newerThan = 600, follow = true })
end
local function Burst(name, frames, every)
	Client("poolburst", { name = name, frames = frames, every = every or 1, x = 480, y = 150, w = 960, h = 780, quality = 85 })
end
local function Cvar(name, value) Client("cvar", { name = name, value = tostring(value) }) end
-- what the blood module holds of every character now, and its last events (cl_trace.lua)
local function Dump(name, events)
	Client("tracedump", { name = name, events = events or 0 })
	Wait(0.15)
end
-- the camera goes with a character's head (top: from above, for one that lies)
local function Follow(ent, dist, top, fov)
	Client("headcam", { follow = ent:EntIndex(), dist = dist or 30, side = 12, up = 3, fov = fov or 50, top = top })
end
-- a bot put somewhere without anything else being done to it
local function Put(bot, pos, yaw)
	bot:SetPos(pos + Vector(0, 0, 2))
	bot:SetEyeAngles(Angle(0, yaw or 0, 0))
	bot:SetLocalVelocity(vector_origin)
	bot:Freeze(true)
end
local function State(tag, ply)
	Log("  %s: %s alive %s, in its ragdoll %s, its corpse %s", tag, tostring(ply), tostring(ply:Alive()), tostring(IsValid(ply.FakeRagdoll)), tostring(Z.GetCorpse(ply)))
end
-- what Z-City keeps of a character's wounds on the server
local function ZWounds(tag, ply)
	local org = istable(ply.organism) and ply.organism or nil
	local parts = {}
	for _, w in ipairs(org and istable(org.wounds) and org.wounds or {}) do
		parts[#parts + 1] = string.format("%.1f on %s (%.1f %.1f %.1f)", tonumber(w[1]) or -1, tostring(w[4]), w[2].x, w[2].y, w[2].z)
	end
	local body = ply:Alive() and Z.GetBody(ply) or Z.GetCorpse(ply)
	Log("  %s: Z-City's wounds of %s (alive %s, body %s): %s | arterial %d | headexploded %s", tag, tostring(ply), tostring(ply:Alive()), tostring(body),
		#parts > 0 and table.concat(parts, "; ") or "none", org and istable(org.arterialwounds) and #org.arterialwounds or 0, tostring(IsValid(body) and body.headexploded))
end

ST.Add("head_obs", function()
	local p = FindSpot({ open = 200, outdoor = true })
	local host = ST.Host()
	local bot = NewBot()
	if not IsValid(bot) then return end
	Client("headcam", { off = true })
	Place(bot, p, 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	Wait(1.5)
	Client("headinfo", { name = "head_obs" })
	local head = HeadOf(bot)
	if not head then Log("head_obs: no head") return end
	local fwd, right = bot:GetForward(), bot:GetRight()
	View(head + fwd * 34 + right * 16 + Vector(0, 0, 4), head)
	-- (the body's surface model and its film's chart are built over the first frames it is in view)
	Wait(2.5)
	Probe(bot, "obs")
	Wait(0.4)
	Shot("ho_0_before")

	Note("A: one 9 mm round into the head of the standing bot, from its front left")
	ABL.DevShootAt(host, head + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
	local t0 = CurTime()
	Wait(1.2)
	ZWounds("head_obs A", bot)
	MarkCam("entry", 16)
	Wait(0.5)
	Shot("ho_a_02s")
	-- (every fourth frame for about two and a half seconds: does anything come and go)
	Burst("ho_a", 36, 4)
	Wait(3.2)
	Client("wounds", { name = "ho_a" })
	for _, t in ipairs({ 6, 10, 14 }) do
		local w = t0 + t - CurTime()
		if w > 0 then Wait(w) end
		MarkCam("entry", 16)
		Wait(0.3)
		Shot(string.format("ho_a_%02ds", t))
	end
	ZWounds("head_obs A, 14 s", bot)

	Note("B: the camera turns away from the body for a second and back, three times")
	for i = 1, 3 do
		local h2 = HeadOf(bot)
		if not h2 then break end
		local eye = h2 + Vector(30, 18, 26)
		Client("view", { pos = eye, ang = (eye - h2):Angle(), fov = 60 })
		Wait(1.0)
		Client("headnote", { text = "B" .. i .. ": the camera turns back now" })
		Burst("ho_back" .. i, 14, 1)
		Client("view", { pos = eye, ang = (h2 - eye):Angle(), fov = 60 })
		Wait(1.3)
	end

	Note("C: a second 9 mm round into the head of the lying body, from above (by the brain module's rule: death)")
	local h3 = HeadOf(bot)
	if h3 then
		MarkCam("entry", 18)
		Wait(0.4)
		ABL.DevShootAt(host, h3 + Vector(0, 0, 1), Vector(0.3, 0.2, 1):GetNormalized(), nil, 60, P9)
		Wait(0.5)
		Burst("ho_c", 24, 4)
		Wait(2.2)
		ZWounds("head_obs C", bot)
		Shot("ho_c_03s")
		Client("wounds", { name = "ho_c" })
		Wait(4)
		Shot("ho_c_07s")
	end
	local corpse = Z.GetCorpse(bot)
	Log("  head_obs: the bot is alive %s; its corpse %s", tostring(bot:Alive()), tostring(corpse))
	if IsValid(corpse) then Probe(corpse, "corpse") end

	Note("D: the player lives again somewhere else; its corpse lies where it lay")
	bot:Spawn()
	Wait(0.5)
	Place(bot, p + Vector(0, 90, 0), 0)
	Wait(2.5)
	Shot("ho_d_corpse")
	local bh = HeadOf(bot)
	if bh then
		View(bh + bot:GetForward() * 34 + bot:GetRight() * 16 + Vector(0, 0, 4), bh)
		Wait(1.2)
		Shot("ho_d_new_life")
	end
	ZWounds("head_obs D", bot)
	Client("wounds", { name = "ho_d" })
	Wait(0.3)
	ProbeOff(bot)
	ProbeOff(corpse)
	Wait(0.3)
end)

-- head_fix: a body and its film drawn with the same bones (cl_filmdraw.lua, KeepBones), or not
-- (abl_film_bones 0: as it was). A bot that was shot in the head and lies, watched from close
-- by, in bursts of pictures; and the host's own head, from outside and through Z-City's own
-- camera.
ST.Add("head_fix", function()
	local p = FindSpot({ open = 220, outdoor = true })
	local host = ST.Host()
	local bot = NewBot()
	if not IsValid(bot) then return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Place(bot, p, 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	Wait(1.5)
	local head = HeadOf(bot)
	if not head then Log("head_fix: no head") return end
	local fwd, right = bot:GetForward(), bot:GetRight()
	View(head + fwd * 34 + right * 16 + Vector(0, 0, 4), head)
	Wait(2.5)
	Note("one 9 mm round into the head of the standing bot")
	ABL.DevShootAt(host, head + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
	Wait(4.0)
	MarkCam("entry", 16)
	Wait(0.6)
	for i, on in ipairs({ "0", "1", "0", "1" }) do
		Note("the lying bot's head, abl_film_bones " .. on)
		Cvar("abl_film_bones", on)
		Wait(0.8)
		Burst("hf_bot_" .. i .. "_bones" .. on, 20, 3)
		Wait(2.6)
	end
	Dump("head_fix: the bot", 12)

	Note("the host's own head: a wound on its front, the host drawn as the game draws one's own body")
	host:SetMoveType(MOVETYPE_WALK)
	host:SetPos(p + Vector(0, 120, 2))
	host:SetLocalVelocity(vector_origin)
	host:SetEyeAngles(Angle(0, 0, 0))
	Wait(0.6)
	local ok, err = ABL.DevAddWound(host, "head", 14, false, 4, 0.8, 0.5)
	Log("  head_fix: a wound on the front of the host's head: %s%s", tostring(ok), err and (" (" .. err .. ")") or "")
	Probe(host, "self")
	local hp = ABL.DevHitboxCenter(Z.GetBody(host), "head") or host:EyePos()
	local from = hp + Vector(44, 16, 5)
	Client("headcam", { pos = from, ang = (hp - from):Angle(), fov = 44, viewer = true })
	Wait(5.0)
	for _, on in ipairs({ "0", "1" }) do
		Note("the host from outside, abl_film_bones " .. on)
		Cvar("abl_film_bones", on)
		Wait(2.4)
		Shot("hf_self_outside_bones" .. on)
	end
	Note("the same through Z-City's own camera")
	Client("headcam", { off = true })
	Client("zview", { on = true })
	host:SetEyeAngles(Angle(8, 0, 0))
	for _, on in ipairs({ "0", "1" }) do
		Note("the host through Z-City's camera, abl_film_bones " .. on)
		Cvar("abl_film_bones", on)
		Wait(2.4)
		Shot("hf_self_first_bones" .. on)
	end
	Note("the host looks down at itself, abl_film_bones 1")
	host:SetEyeAngles(Angle(62, 0, 0))
	Wait(2.4)
	Shot("hf_self_first_down_bones1")
	Client("zview", { on = false })
	Dump("head_fix: the host", 6)
	ProbeOff(host)
	ABL.DevHeal(host)
	ABL.DevHeal(bot)
	Wait(0.5)
end)

-- head_life: what the blood module holds of one character through its lives (the events are in
-- the client's log as they come: "trace:").
ST.Add("head_life", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local host = ST.Host()
	if not (hg and hg.Fake and hg.FakeUp) then Log("head_life: no hg.Fake and hg.FakeUp here") return end
	local bot = NewBot()
	if not IsValid(bot) then return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Cvar("abl_film_bones", "1")
	Place(bot, p, 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	Wait(1.5)
	local head = HeadOf(bot)
	if not head then Log("head_life: no head") return end
	local fwd, right = bot:GetForward(), bot:GetRight()
	View(head + fwd * 34 + right * 16 + Vector(0, 0, 4), head)
	Wait(2.5)
	Probe(bot, "life")

	Note("L1: one 9 mm round into the head of the standing bot; it lies in its ragdoll, alive")
	ABL.DevShootAt(host, head + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
	Wait(5.0)
	MarkCam("entry", 18)
	Wait(0.6)
	Shot("hl_1_lying")
	ZWounds("head_life L1", bot)
	State("head_life L1", bot)
	Dump("L1: lying, before it is got up", 14)

	Note("L2: Z-City gets the living player up from its ragdoll (hg.FakeUp): the same life")
	if bot:Alive() and IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) else Log("  head_life L2: NOT got up (not alive in a ragdoll)") end
	Wait(1.5)
	State("head_life L2", bot)
	Follow(bot, 30, IsValid(bot.FakeRagdoll))
	Wait(0.8)
	Shot("hl_2_after_getup")
	ZWounds("head_life L2", bot)
	Dump("L2: after the get-up", 14)

	Note("L3: Z-City begins the living player's organism again and gets it up, without a spawn (as its round start does for the survivors of the last round): a new life")
	hg.organism.Clear(bot.organism)
	if IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) end
	Wait(1.8)
	State("head_life L3", bot)
	Follow(bot, 30, IsValid(bot.FakeRagdoll))
	Wait(0.8)
	Shot("hl_3_begun_again")
	ZWounds("head_life L3", bot)
	Dump("L3: after its organism was begun again", 14)

	Note("L4: a 9 mm round of little damage into the upper arm of the standing bot; then, while it stands and bleeds, it is spawned anew (a real spawn of a living player): a new life")
	local body = Z.GetBody(bot)
	local arm = IsValid(body) and ABL.DevHitboxCenter(body, "rupperarm") or nil
	if arm then
		Client("headcam", { off = true })
		View(arm + fwd * 40 + right * 18 + Vector(0, 0, 6), arm)
		Wait(0.8)
		ABL.DevShootAt(host, arm, (fwd + right * 0.4):GetNormalized(), 8, 60, P9)
		Wait(3.0)
		Shot("hl_4_arm_wound")
		State("head_life L4, wounded", bot)
		ZWounds("head_life L4, wounded", bot)
		Dump("L4: a wound in the arm, before the spawn", 10)
	end
	bot:Spawn()
	Wait(0.3)
	Put(bot, p + Vector(0, 80, 0), 0)
	Wait(1.7)
	State("head_life L4, spawned", bot)
	Follow(bot, 34, IsValid(bot.FakeRagdoll))
	Wait(0.8)
	Shot("hl_4_new_life_while_alive")
	ZWounds("head_life L4, spawned", bot)
	Dump("L4: after a real spawn of the living player", 14)

	Note("L5: two 9 mm rounds into the head, two and a half seconds apart (by the brain module's rule: death at the second)")
	local h4 = HeadOf(bot)
	if h4 then
		Client("headcam", { off = true })
		View(h4 + fwd * 34 + right * 16 + Vector(0, 0, 4), h4)
		Wait(0.8)
		ABL.DevShootAt(host, h4 + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
		Wait(2.5)
		local h5 = HeadOf(bot)
		if h5 then ABL.DevShootAt(host, h5 + Vector(0, 0, 1), Vector(0.3, 0.2, 1):GetNormalized(), nil, 60, P9) end
		Wait(3.0)
	end
	State("head_life L5", bot)
	local corpse = Z.GetCorpse(bot)
	if IsValid(corpse) then Probe(corpse, "corpse") end
	MarkCam("entry", 18)
	Wait(0.6)
	Shot("hl_5_corpse")
	ZWounds("head_life L5", bot)
	Dump("L5: dead, its corpse", 16)

	Note("L6: the dead player lives again somewhere else; its corpse lies where it lay")
	bot:Spawn()
	Wait(0.3)
	Put(bot, p + Vector(0, 160, 0), 0)
	Wait(2.0)
	State("head_life L6", bot)
	Follow(bot, 30, false)
	Wait(0.8)
	Shot("hl_6_new_life")
	if IsValid(corpse) then
		Follow(corpse, 34, true)
		Wait(0.8)
		Shot("hl_6_corpse_still")
	end
	ZWounds("head_life L6", bot)
	Dump("L6: after death and a new life", 14)
	ProbeOff(bot)
	ProbeOff(corpse)
	Client("headcam", { off = true })
	ABL.DevHeal(bot)
	Wait(0.3)
end)

-- head_sight: a bleeding body comes into the picture as the camera turns. Is its blood there in
-- the first frame the body is? First as it was (the blood waited for the LOD to look, five times
-- a second), then as the module has it.
-- Two bodies: one that stands (a bot the harness has made is not drawn through Z-City's renderer
-- on this client: its blood is drawn by the module's own pass), and one that lies in its ragdoll
-- (drawn by Z-City's renderer, its blood from the hook there). "As it was" can only be put back
-- for the second (cl_headtest.lua, headsight); for the first the run of 2026-10-13 "head3" is the
-- measure of how it was: its blood came one to nine frames after the camera had turned back.
ST.Add("head_sight", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local bot, lying = NewBot(), NewBot()
	if not (IsValid(bot) and IsValid(lying)) or bot == lying then Log("head_sight: two bots are needed") return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Place(bot, p, 0)
	Place(lying, p + Vector(0, 70, 0), 0)
	Wait(1.5)
	local head = HeadOf(bot)
	if not head then Log("head_sight: no head") return end
	local fwd, right = bot:GetForward(), bot:GetRight()
	local mid = head + Vector(0, 35, -20)
	local eye = mid + fwd * 160 + Vector(0, 0, 24)
	local toward, away = (mid - eye):Angle(), (eye - mid):Angle()
	View(eye, mid)
	Wait(1.0)
	for _, b in ipairs({ bot, lying }) do
		Log("  head_sight: wounds on the head and the chest of %s: %s, %s", tostring(b), tostring(ABL.DevAddWound(b, "head", 14, false, 4, 0.8, 0.5)), tostring(ABL.DevAddWound(b, "chest", 12, false, 3, 0.6, 0.5)))
	end
	Wait(3.0)
	if hg and hg.Fake then hg.Fake(lying) end
	Wait(5.0)
	State("head_sight, the one that lies", lying)
	Probe(bot, "stands")
	Probe(lying, "lies")
	Wait(0.3)
	Shot("hs2_0_before")
	for _, old in ipairs({ true, false }) do
		local tag = old and "as it was" or "as the module has it"
		Client("headsight", { old = old })
		Wait(0.6)
		for _, b in ipairs({ bot, lying }) do Client("headprobe", { ent = b:EntIndex(), mark = tag .. ", before the turns" }) end
		for i = 1, 6 do
			Client("view", { pos = eye, ang = away, fov = 60 })
			-- (not in step with the LOD's fifth of a second)
			Wait(0.83 + 0.07 * i)
			Client("headnote", { text = tag .. ", turn " .. i .. ": the camera turns back now" })
			if i == 1 then Burst(old and "hs2_old" or "hs2_new", 8, 1) end
			Client("view", { pos = eye, ang = toward, fov = 60 })
			Wait(1.0)
		end
		for _, b in ipairs({ bot, lying }) do Client("headprobe", { ent = b:EntIndex(), mark = tag .. ": six turns away and back" }) end
	end
	Client("headsight", { old = false })
	Dump("head_sight", 8)
	ProbeOff(lying)
	ABL.DevHeal(lying)
	ProbeOff(bot)
	ABL.DevHeal(bot)
	Wait(0.3)
end)

-- head_multi: two players side by side. A is hit in the head three times, at three places (the
-- second by the brain module's rule kills it; the third strikes its body), B once.
ST.Add("head_multi", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local host = ST.Host()
	local a, b = NewBot(), NewBot()
	if not (IsValid(a) and IsValid(b)) or a == b then Log("head_multi: two bots are needed") return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Place(a, p, 0)
	Place(b, p + Vector(0, 64, 0), 0)
	a:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	b:SetPlayerColor(Vector(0.55, 0.62, 0.78))
	Wait(1.5)
	local ha, hb = HeadOf(a), HeadOf(b)
	if not (ha and hb) then Log("head_multi: no heads") return end
	local fwd, right = a:GetForward(), a:GetRight()
	local mid = (ha + hb) * 0.5
	View(mid + fwd * 84 + Vector(0, 0, 6), mid)
	Wait(2.5)
	Probe(a, "A")
	Probe(b, "B")
	Note("M1: a 9 mm round into the head of A, from its front left")
	ABL.DevShootAt(host, ha + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
	Wait(1.2)
	Note("M2: a 9 mm round into the head of B, from its front")
	ABL.DevShootAt(host, hb + Vector(0, 0, 1.0), (fwd + Vector(0, 0, 0.12)):GetNormalized(), nil, 60, P9)
	Wait(3.0)
	Shot("hm_1_one_round_each")
	Dump("M2: one round each", 16)
	Note("M3: a second round into the head of A, from above, at another place")
	local h2 = HeadOf(a)
	if h2 then ABL.DevShootAt(host, h2 + Vector(1.5, 0, 0), Vector(0.2, 0.3, 1):GetNormalized(), nil, 60, P9) end
	Wait(2.2)
	Note("M4: a third round into the head of A's body, from its side")
	local h3 = HeadOf(a)
	if h3 then ABL.DevShootAt(host, h3 + Vector(0, 0, 0.5), Vector(0.1, 1, 0.5):GetNormalized(), nil, 60, P9) end
	Wait(3.0)
	State("head_multi A", a)
	State("head_multi B", b)
	ZWounds("head_multi A", a)
	ZWounds("head_multi B", b)
	local ca = Z.GetCorpse(a)
	for _, e in ipairs({ { IsValid(ca) and ca or a, "A" }, { b, "B" } }) do
		Follow(e[1], 30, true, 45)
		Wait(0.8)
		Shot("hm_2_head_of_" .. e[2])
		Burst("hm_" .. e[2], 16, 3)
		Wait(2.4)
	end
	Client("wounds", { name = "hm" })
	Dump("M4: A hit three times, B once", 24)
	ProbeOff(a)
	ProbeOff(b)
	Client("headcam", { off = true })
	Wait(0.3)
end)

-- head_move: a head wound on a bot that stands, then runs to and fro; the camera goes with its head.
ST.Add("head_move", function()
	local p = FindSpot({ open = 300, outdoor = true })
	local bot = NewBot()
	if not IsValid(bot) then return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Place(bot, p, 0)
	Wait(1.5)
	View(p + Vector(150, -130, 80), p + Vector(40, 0, 40))
	Wait(1.0)
	Log("  head_move: a wound on the front of the head: %s", tostring(ABL.DevAddWound(bot, "head", 16, false, 4, 0.8, 0.5)))
	Wait(6.0)
	Probe(bot, "move")
	Follow(bot, 30, false)
	Wait(0.8)
	Shot("hv_0_standing")
	Burst("hv_stand", 16, 3)
	Wait(2.4)
	Note("the bot runs to and fro")
	bot:Freeze(false)
	ST.Drive(bot, function(ply, cmd)
		local phase = math.floor(CurTime() / 2.2) % 2
		cmd:SetForwardMove(phase == 0 and 260 or -260)
		cmd:SetButtons(IN_SPEED)
	end)
	Wait(1.5)
	Burst("hv_run", 24, 3)
	Wait(3.4)
	Shot("hv_1_running")
	Wait(2.0)
	Shot("hv_2_running")
	ST.Drive(bot, nil)
	bot:Freeze(true)
	Note("the bot stands again")
	Wait(1.2)
	Shot("hv_3_stopped")
	Client("wounds", { name = "hv" })
	Dump("head_move", 10)
	ProbeOff(bot)
	Client("headcam", { off = true })
	ABL.DevHeal(bot)
	Wait(0.3)
end)

-- head_flow: the same wound on three heads at three values; then all three are closed.
ST.Add("head_flow", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local vals = { 4, 14, 40 }
	local bots = {}
	for i = 1, 3 do
		local b = NewBot()
		if not IsValid(b) then Log("head_flow: no bot") return end
		bots[i] = b
	end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	for i, b in ipairs(bots) do Place(b, p + Vector(0, (i - 2) * 56, 0), 0) end
	Wait(1.5)
	local mid = HeadOf(bots[2])
	if not mid then Log("head_flow: no head") return end
	View(mid + bots[2]:GetForward() * 96 + Vector(0, 0, 2), mid - Vector(0, 0, 8))
	Wait(2.0)
	Note("E: the same wound on three heads, values 4, 14 and 40 (left to right in the picture: 40, 14, 4 or the reverse)")
	for i, b in ipairs(bots) do
		Log("  head_flow: value %d on %s: %s", vals[i], tostring(b), tostring(ABL.DevAddWound(b, "head", vals[i], false, 4, 0.8, 0.5)))
		Probe(b, "value" .. vals[i])
	end
	local t0 = CurTime()
	for _, t in ipairs({ 3, 8, 14 }) do
		local w = t0 + t - CurTime()
		if w > 0 then Wait(w) end
		Shot(string.format("hw_e_%02ds", t))
	end
	Client("wounds", { name = "hw_e" })
	Dump("E: three values, 14 s", 12)
	Note("F: the wounds are closed (gone from Z-City's lists, as when they are bandaged)")
	for _, b in ipairs(bots) do ABL.DevHeal(b) end
	t0 = CurTime()
	for _, t in ipairs({ 1, 4, 10 }) do
		local w = t0 + t - CurTime()
		if w > 0 then Wait(w) end
		Shot(string.format("hw_f_%02ds", t))
	end
	Client("wounds", { name = "hw_f" })
	Dump("F: 10 s after the wounds were closed", 16)
	for _, b in ipairs(bots) do ProbeOff(b) end
	Wait(0.3)
end)

-- head_models: is the film steady on every kind of head? Four bots, the models asked for by turns
-- (two male, two female; what each really wears is in the log), each shot in the head and lying
-- alive in its ragdoll. For each a burst of pictures from above with the module as it is, then
-- with the face's own shapes taken off the body (headz "noflex"), then with the model's finest
-- mesh for both drawings ("lod0"); and what the head bone's matrix is at the three moments.
ST.Add("head_models", function()
	local p = FindSpot({ open = 280, outdoor = true })
	local host = ST.Host()
	local want = { "models/zcity/m/male_06.mdl", "models/zcity/f/female_01.mdl", "models/zcity/m/male_01.mdl", "models/zcity/f/female_04.mdl" }
	local bots = {}
	for i = 1, #want do
		local b = NewBot()
		if IsValid(b) then bots[#bots + 1] = b end
	end
	if #bots == 0 then Log("head_models: no bots") return end
	Client("headcam", { off = true })
	Client("tracesink", { on = false })
	Cvar("abl_film_bones", "1")
	for i, b in ipairs(bots) do
		Place(b, p + Vector(0, (i - 2.5) * 62, 0), 0)
		if util.IsValidModel(want[i]) then b:SetModel(want[i]) end
	end
	Wait(2.0)
	local fwd = bots[1]:GetForward()
	View(p + fwd * 150 + Vector(0, 0, 70), p + Vector(0, 0, 30))
	Wait(2.0)
	for i, b in ipairs(bots) do
		Log("  head_models: bot %d is %s, model %s (asked: %s)", i, tostring(b), tostring(b:GetModel()), want[i])
		local h = HeadOf(b)
		if h then ABL.DevShootAt(host, h + Vector(0, 0, 1.2), (fwd + Vector(0, 0, 0.12)):GetNormalized(), nil, 60, P9) end
		Wait(0.5)
	end
	Wait(5.0)
	Shot("hmd_0_all")
	for i, b in ipairs(bots) do Probe(b, "model" .. i) end
	for i, b in ipairs(bots) do
		State("head_models " .. i, b)
		local body = b:Alive() and Z.GetBody(b) or Z.GetCorpse(b)
		if IsValid(body) then
			Follow(IsValid(Z.GetCorpse(b)) and Z.GetCorpse(b) or b, 26, true, 45)
			Wait(0.8)
			Shot("hmd_" .. i .. "_head")
			for _, mode in ipairs({ "watch", "noflex", "lod0" }) do
				Client("headz", { ent = b:EntIndex(), mode = mode, name = "bot" .. i .. "_" .. mode })
				Wait(0.6)
				Burst("hmd_" .. i .. "_" .. mode, 12, 2)
				Wait(1.6)
			end
			Client("headz", { off = true })
		end
	end
	Client("headcam", { off = true })
	Dump("head_models", 0)
	for _, b in ipairs(bots) do ABL.DevHeal(b) end
	Wait(0.3)
end)

-- head_place: a wound that Z-City has at a place that is not on the part it names (its wounds
-- on a bone drawn at random lie at the offset of the true place from that bone). Here: booked on
-- the right thigh, 29 units from it. It must bleed from the body, not from the air beside it.
ST.Add("head_place", function()
	local p = FindSpot({ open = 220, outdoor = true })
	local bot = NewBot()
	if not IsValid(bot) then return end
	if not (hg and hg.organism and hg.organism.AddWoundManual) then Log("head_place: no hg.organism.AddWoundManual here") return end
	Client("headcam", { off = true })
	Client("tracesink", { on = true })
	Place(bot, p, 0)
	Wait(1.5)
	local c = p + Vector(0, 0, 38)
	View(c + bot:GetForward() * 90 + bot:GetRight() * 30 + Vector(0, 0, 10), c)
	Wait(2.0)
	Probe(bot, "place")
	Note("a wound booked on the right thigh at (-17.5 -13.7 -19.1) in that bone's space: 29 units from it")
	hg.organism.AddWoundManual(bot, 24, Vector(-17.5, -13.7, -19.1), angle_zero, "ValveBiped.Bip01_R_Thigh", CurTime())
	Wait(3.0)
	Shot("hpl_03s")
	Client("debug", { mask = 1 })
	Wait(0.4)
	Shot("hpl_03s_where_it_bleeds")
	Client("debug", { mask = 0 })
	Wait(4.0)
	Shot("hpl_08s")
	ZWounds("head_place", bot)
	Client("wounds", { name = "hpl" })
	Dump("head_place", 10)
	ProbeOff(bot)
	ABL.DevHeal(bot)
	Wait(0.3)
end)

-- head_perf: five bleeding bodies in the picture, and behind the camera.
ST.Add("head_perf", function()
	local p = FindSpot({ open = 300, outdoor = true })
	local bots = {}
	for i = 1, 5 do
		local b = NewBot()
		if IsValid(b) then bots[#bots + 1] = b end
	end
	if #bots == 0 then Log("head_perf: no bots") return end
	Client("headcam", { off = true })
	Client("tracesink", { on = false })
	for i, b in ipairs(bots) do Place(b, p + Vector((i % 2) * 40, (i - 3) * 50, 0), 0) end
	Wait(1.5)
	local c = p + Vector(20, 0, 50)
	local eye = c + bots[1]:GetForward() * 190 + Vector(0, 0, 20)
	local toward, away = (c - eye):Angle(), (eye - c):Angle()
	View(eye, c)
	Wait(1.0)
	for _, b in ipairs(bots) do
		ABL.DevAddWound(b, "head", 16, false, 4, 0.8, 0.5)
		ABL.DevAddWound(b, "chest", 12, false, 3, 0.6, 0.5)
	end
	Log("  head_perf: %d bots, each with a wound on the head and one on the chest", #bots)
	Wait(4.0)
	-- (lying in their ragdolls: bodies Z-City's renderer draws, with bones it sets by hand, so that
	-- the film is drawn with the bones kept: cl_filmdraw.lua)
	if hg and hg.Fake then
		for _, b in ipairs(bots) do hg.Fake(b) end
	end
	Wait(6.0)
	c = p + Vector(20, 0, 10)
	toward, away = (c - eye):Angle(), (eye - c):Angle()
	Client("view", { pos = eye, ang = toward, fov = 60 })
	Wait(0.5)
	Shot("hp_five_bodies")
	for _, on in ipairs({ "1", "0", "1" }) do
		Cvar("abl_film_bones", on)
		Wait(0.5)
		Client("profile", { reset = true })
		Client("fps", { name = "(begins)" })
		Wait(4.0)
		Client("fps", { name = #bots .. " bleeding bodies in the picture, abl_film_bones " .. on })
		Client("profile", { name = #bots .. " in the picture, abl_film_bones " .. on })
	end
	Client("view", { pos = eye, ang = away, fov = 60 })
	Wait(0.5)
	Client("profile", { reset = true })
	Client("fps", { name = "(begins)" })
	Wait(4.0)
	Client("fps", { name = #bots .. " bleeding bodies behind the camera" })
	Client("profile", { name = #bots .. " behind the camera" })
	Client("view", { pos = eye, ang = toward, fov = 60 })
	Dump("head_perf", 4)
	for _, b in ipairs(bots) do ABL.DevHeal(b) end
	Wait(0.3)
end)

-- head_host: the local player itself is shot in the head by a bot, while its own body is drawn
-- the way the game draws it in play (Z-City's camera: the head hidden). First as it was
-- (abl_film_bones 0), then a new life, then as the module has it; then it is got up.
ST.Add("head_host", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local host = ST.Host()
	if not (hg and hg.Fake and hg.FakeUp) then Log("head_host: no hg.Fake and hg.FakeUp here") return end
	local bot = NewBot()
	if not IsValid(bot) then return end
	Client("headcam", { off = true })
	Client("view", {})
	Client("tracesink", { on = true })
	local function God(on)
		if on then host:GodEnable() else host:GodDisable() end
		if istable(host.organism) then host.organism.godmode = on end
	end
	local function Stand()
		host:SetMoveType(MOVETYPE_WALK)
		host:SetPos(p + Vector(0, 0, 2))
		host:SetLocalVelocity(vector_origin)
		host:SetEyeAngles(Angle(2, 0, 0))
	end
	local function Outside()
		local body = host:Alive() and Z.GetBody(host) or Z.GetCorpse(host)
		local hp = IsValid(body) and ABL.DevHitboxCenter(body, "head") or host:EyePos()
		local from = hp + Vector(40, 16, 14)
		Client("headcam", { pos = from, ang = (hp - from):Angle(), fov = 46, viewer = true })
	end
	local function Hit(tag)
		Stand()
		Client("zview", { on = true })
		Wait(2.5)
		God(false)
		local hp = ABL.DevHitboxCenter(Z.GetBody(host), "head") or host:EyePos()
		Note(tag .. ": the bot fires a 9 mm round into the front of the host's head (the host's body drawn by Z-City's camera)")
		ABL.DevShootAt(bot, hp + Vector(0, 0, 1.5), Vector(1, 0.25, 0.05):GetNormalized(), 12, 60, P9)
		Wait(0.3)
		God(true)
		Wait(1.5)
		Shot("hh_" .. tag .. "_first_person")
		State("head_host " .. tag, host)
		ZWounds("head_host " .. tag, host)
		Client("zview", { on = false })
		Outside()
		Wait(2.5)
		Shot("hh_" .. tag .. "_outside")
		Client("wounds", { name = "hh_" .. tag })
		Dump("head_host " .. tag, 16)
	end
	Stand()
	Place(bot, p + Vector(80, 0, 0), 180)
	Wait(1.5)
	Probe(host, "host")
	Cvar("abl_film_bones", "0")
	Wait(0.3)
	Hit("bones0")

	Note("the host is spawned anew: a new life")
	Client("headcam", { off = true })
	host:Spawn()
	Wait(1.0)
	God(true)
	Stand()
	Wait(1.5)
	State("head_host, new life", host)
	Outside()
	Wait(1.2)
	Shot("hh_new_life_outside")
	Dump("head_host: after the host's real spawn", 12)
	Client("headcam", { off = true })

	Cvar("abl_film_bones", "1")
	Wait(0.3)
	Hit("bones1")
	if host:Alive() and IsValid(host.FakeRagdoll) then
		Note("the host is got up from its ragdoll (hg.FakeUp): the same life")
		hg.FakeUp(host, true, true)
		Wait(1.8)
		State("head_host, got up", host)
		Outside()
		Wait(1.2)
		Shot("hh_after_getup_outside")
		Dump("head_host: after the host's get-up", 12)
	else
		Log("  head_host: the host is not alive in a ragdoll: no get-up")
	end
	-- the host as the scenes after this one expect it
	Client("headcam", { off = true })
	ProbeOff(host)
	host:Spawn()
	Wait(1.0)
	God(true)
	Stand()
	ABL.DevHeal(host)
	ABL.DevHeal(bot)
	Wait(0.5)
end)

ST.Add("head_self", function()
	local p = FindSpot({ open = 220, outdoor = true })
	local host = ST.Host()
	if not (hg and hg.Fake and hg.FakeUp) then Log("head_self: no hg.Fake and hg.FakeUp here") return end
	local bot = NewBot()
	if not IsValid(bot) then return end
	-- the host itself stands at the spot and looks along +x; the bot stands in front of it and looks back
	Client("headcam", { off = true })
	Client("view", {})
	host:SetMoveType(MOVETYPE_WALK)
	host:SetPos(p + Vector(0, 0, 2))
	host:SetLocalVelocity(vector_origin)
	host:SetEyeAngles(Angle(0, 0, 0))
	Place(bot, p + Vector(70, 0, 0), 180)
	Wait(1.5)
	Client("headinfo", { name = "head_self" })
	local horg = istable(host.organism) and host.organism or nil
	Log("  head_self: the host %s at %s, godmode %s (its organism: %s)", tostring(host), tostring(host:GetPos()), tostring(host:HasGodMode()), tostring(horg and horg.godmode))

	-- the same wound on both: the front of the head, above the middle
	local okH, errH = ABL.DevAddWound(host, "head", 14, false, 4, 0.8, 0.5)
	local okB, errB = ABL.DevAddWound(bot, "head", 14, false, 4, 0.8, 0.5)
	Log("  head_self: a wound on the front of the head: host %s%s, bot %s%s", tostring(okH), errH and (" (" .. errH .. ")") or "", tostring(okB), errB and (" (" .. errB .. ")") or "")
	Probe(host, "self")
	Probe(bot, "bot")
	local function Outside(viewer)
		local hp = ABL.DevHitboxCenter(Z.GetBody(host), "head") or host:EyePos()
		local from = hp + Vector(44, 16, 5)
		Client("headcam", { pos = from, ang = (hp - from):Angle(), fov = 44, viewer = viewer })
	end

	Note("A: a camera in front of the host, the host not drawn (the harness's way)")
	Outside(false)
	Wait(3.0)
	ZWounds("head_self A", host)
	Shot("hs_a_host_not_drawn")

	Note("B: the same camera, the host drawn as the game draws one's own body")
	Outside(true)
	Wait(4.0)
	Shot("hs_b_host_drawn_4s")
	Wait(4.0)
	Shot("hs_b_host_drawn_8s")
	Client("wounds", { name = "hs_b" })

	Note("C: Z-City's own camera, the host looks at the bot")
	Client("headcam", { off = true })
	Client("zview", { on = true })
	host:SetEyeAngles(Angle(4, 0, 0))
	Wait(3.0)
	Client("headinfo", { name = "head_self, Z-City's camera" })
	Shot("hs_c_first_person_ahead")
	Note("C: the host looks down at itself")
	host:SetEyeAngles(Angle(62, 0, 0))
	Wait(3.0)
	Shot("hs_c_first_person_down")
	Wait(3.0)
	Shot("hs_c_first_person_down_6s")

	Note("D: the host lies in its ragdoll (Z-City's camera)")
	host:SetEyeAngles(Angle(10, 0, 0))
	hg.Fake(host)
	Wait(3.0)
	Shot("hs_d_ragdoll_3s")
	Wait(3.0)
	Shot("hs_d_ragdoll_6s")
	Client("zview", { on = false })
	Note("D: the same from outside, the host drawn")
	Outside(true)
	Wait(2.0)
	Shot("hs_d_ragdoll_outside")
	Client("wounds", { name = "hs_d" })

	Note("E: the host gets up again")
	hg.FakeUp(host, true, true)
	Wait(2.0)
	Outside(true)
	Wait(1.5)
	Shot("hs_e_up_again")
	ABL.DevHeal(host)
	ABL.DevHeal(bot)
	Wait(1.0)
	ProbeOff(host)
	ProbeOff(bot)
	Client("headcam", { off = true })
	Wait(0.3)
end)
