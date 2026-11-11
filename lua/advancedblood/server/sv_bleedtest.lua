-- Scenes of where a wound's blood comes from and where it goes (developer tool; only with the test
-- harness, see sv_selftest.lua). They run only when asked for by name.
--
--   bleed_origin   one body on its back, one shot into the chest from above: the first seconds
--                  frame by frame, then the wound and what is round it at set times (once with
--                  the film's outlines read the old way, abl_film_smooth 0), the wound closed,
--                  and what is left. The numbers of each picture are in the client's log
--                  (cl_bleedtest.lua, "origin"), and so is whether the picture the outlines are
--                  read from lies where the film's own does ("smoothprobe").
--   bleed_stand    a body is shot in the chest lying (a body that is shot falls: Z-City lays it
--                  down in the tick of the hit), gets up again, stands, and runs: the same wound
--                  on a body that stands upright and moves.
--   bleed_turn     a body on its back that bleeds from the chest is tilted, laid on its side and
--                  on its back again: where the blood goes then.
--   bleed_many     three bodies with wounds at once, one of them running: what a frame costs,
--                  and what is left when they die.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

local function Fake(bot)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	return ABL.DevRagdollOf(bot)
end

local function Origin(name, ent)
	Client("bleedorigin", { name = name, ent = ent })
	Wait(0.1)
end
local function FStats(name)
	Client("filmstats", { name = name })
	Wait(0.1)
end

-- The newest entry wound from close by and from a little further off, and its numbers.
local function Look(tag, kind, o)
	o = o or {}
	Client("viewmark", { kind = kind or "entry", dist = o.near or 11, tilt = o.tilt or 28, spin = o.spin or 0, fov = 34, newerThan = 600, follow = true })
	Wait(0.4)
	Shot(tag .. "_near")
	if not o.nearOnly then
		Client("viewmark", { kind = kind or "entry", dist = o.far or 30, tilt = o.tilt or 28, spin = o.spin or 0, fov = 42, newerThan = 600, follow = true })
		Wait(0.4)
		Shot(tag .. "_far")
	end
	Origin(tag)
end

-- Pictures and numbers at set times after t0 (seconds).
local function Timeline(tag, t0, times, kind, o)
	for _, tt in ipairs(times) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Look(string.format("%s_%04.1fs", tag, tt), kind, o)
	end
end

local function LieDown(p, pose)
	local bot = NewBot()
	Place(bot, p, 0)
	-- (light clothes: blood reads best on them)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	local rag = Fake(bot)
	if not IsValid(rag) then Log("  fake failed") return bot, nil end
	Wait(0.8)
	ABL.DevPose(rag, pose or "back", false)
	Wait(2.2)
	return bot, rag
end

ST.Add("bleed_origin", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local host = ST.Host()
	local bot, rag = LieDown(p, "back")
	if not rag then return end
	local aim = ABL.DevHitboxCenter(rag, "chest")
	if not aim then Log("bleed_origin: no chest") return end
	-- (the body's surface model and its film's chart are built over the first frames it is in view)
	View(aim + Vector(40, 24, 46), aim)
	Wait(3.0)
	-- (is the picture the film's outlines are read from where the film's own picture is: cl_bleedtest.lua)
	Client("smoothprobe", {})
	Wait(0.3)
	-- the camera over the place before anything is there, and the first second and a half of it
	local eye = aim + Vector(5.5, 3.5, 14)
	View(eye, aim)
	Client("bleedview", { pos = eye, look = aim, fov = 56 })
	Wait(0.5)
	Shot("bo_before")
	Client("poolburst", { name = "bo_first", frames = 26, every = 4, x = 480, y = 150, w = 960, h = 780, quality = 90 })
	Wait(0.12)
	Log("  bleed_origin: 9x19 into the chest from above")
	ABL.DevShootAt(host, aim, Vector(0.2, 0.08, 1):GetNormalized(), nil, 60, "9x19mmparabellum")
	local t0 = CurTime()
	Wait(2.3)
	Client("wounds", { name = "bo" })
	Timeline("bo", t0, { 3, 5, 8 })
	-- the same view with the film's outlines read the old way, straight from the cells' picture
	Client("viewmark", { kind = "entry", dist = 7, tilt = 28, spin = 0, fov = 34, newerThan = 600, follow = true })
	Wait(0.4)
	Shot("bo_smooth_on")
	Client("cvar", { name = "abl_film_smooth", value = "0" })
	Wait(0.45)
	Shot("bo_smooth_off")
	Client("cvar", { name = "abl_film_smooth", value = "1" })
	Wait(0.3)
	Timeline("bo", t0, { 12, 17, 24, 32 })
	FStats("bo_bleeding")
	-- the wound closes: what was laid down stays, nothing more comes
	ABL.DevHeal(bot)
	Log("  bleed_origin: wounds closed")
	local t1 = CurTime()
	Timeline("bo_closed", t1, { 2, 8, 16 })
	FStats("bo_closed")
	-- the ground under and beside the body: only what fell there
	local c = rag:WorldSpaceCenter()
	View(Vector(c.x + 44, c.y - 30, p.z + 38), Vector(c.x, c.y, p.z + 2))
	Wait(0.5)
	Shot("bo_ground")
	Client("stats", { name = "bleed_origin" })
	Wait(0.2)
end)

-- The whole film of one character from where it faces, and its numbers.
local function Whole(bot, name, o)
	o = o or {}
	Client("filmcam", { ent = bot:EntIndex(), min = o.min or 26, max = o.max or 70, dist = o.dist, pad = o.pad })
	Wait(0.35)
	Shot(name)
	Origin(name)
end

-- bleed_stand: a body that is shot falls (Z-City lays it down). It is shot in the chest lying,
-- gets up again with the wound bleeding, stands, and then runs: the blood that ran one way while
-- it lay runs down it now, from the same opening, and goes with the body.
local runner
ST.Add("bleed_stand", function()
	local p = FindSpot({ open = 220, outdoor = true })
	local host = ST.Host()
	local bot, rag = LieDown(p, "back")
	if not rag then return end
	local aim = ABL.DevHitboxCenter(rag, "chest")
	if not aim then Log("bleed_stand: no chest") return end
	View(aim + Vector(40, 24, 46), aim)
	Wait(3.0)
	Log("  bleed_stand: 9x19 into the chest from above")
	ABL.DevShootAt(host, aim, Vector(0.2, 0.08, 1):GetNormalized(), nil, 60, "9x19mmparabellum")
	local t0 = CurTime()
	Wait(2.3)
	Timeline("bs_lying", t0, { 4 }, "entry", { nearOnly = true })
	-- it gets up
	if hg and hg.FakeUp then hg.FakeUp(bot, true, true) end
	Wait(1.2)
	bot:Freeze(true)
	Log("  bleed_stand: up again %s, alive %s", tostring(not IsValid(bot.FakeRagdoll)), tostring(bot:Alive()))
	View(bot:GetPos() + bot:GetForward() * 70 + Vector(0, 20, 50), bot:GetPos() + Vector(0, 0, 44))
	Wait(0.8)
	local t1 = CurTime()
	for _, tt in ipairs({ 1.5, 4, 8, 13 }) do
		local w = t1 + tt - CurTime()
		if w > 0 then Wait(w) end
		local tag = string.format("bs_up_%04.1fs", tt)
		Whole(bot, tag)
		Client("viewmark", { kind = "entry", dist = 11, tilt = 20, spin = 0, fov = 34, newerThan = 600, follow = true })
		Wait(0.4)
		Shot(tag .. "_near")
	end
	FStats("bs_standing")
	-- it runs, the camera with the wound
	if IsValid(bot) and bot:Alive() and not IsValid(bot.FakeRagdoll) then
		bot:Freeze(false)
		runner = bot
		Wait(0.8)
		Client("viewmark", { kind = "entry", dist = 12, tilt = 25, spin = 0, fov = 36, newerThan = 600, follow = true })
		for i = 1, 5 do
			Wait(0.6)
			Shot("bs_run_" .. i)
		end
		Client("viewmark", { kind = "entry", dist = 46, tilt = 25, spin = 0, fov = 50, newerThan = 600, follow = true })
		Wait(0.6) Shot("bs_run_far_1")
		Wait(0.8) Shot("bs_run_far_2")
		Origin("bs_run")
		runner = nil
		bot:Freeze(true)
		Wait(1.0)
		Whole(bot, "bs_after_run")
	else
		Log("  bleed_stand: it does not stand: no run")
	end
	FStats("bs_ran")
	-- the wound closes: what is on the body stays
	ABL.DevHeal(bot)
	Log("  bleed_stand: wounds closed")
	Wait(6)
	Whole(bot, "bs_closed_06s")
	-- the ground it stood and ran on: only what fell there
	View(p + Vector(70, -50, 60), p + Vector(0, 0, 2))
	Wait(0.5)
	Shot("bs_ground")
	FStats("bs_closed")
	Client("stats", { name = "bleed_stand" })
	Wait(0.2)
end)

-- bleed_turn: a body on its back that bleeds from the chest is laid on its side, and on its back
-- again: where the blood goes then. Seen as a whole, from where its blood faces.
ST.Add("bleed_turn", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local host = ST.Host()
	local bot, rag = LieDown(p, "back")
	if not rag then return end
	local aim = ABL.DevHitboxCenter(rag, "chest")
	if not aim then Log("bleed_turn: no chest") return end
	View(aim + Vector(40, 24, 46), aim)
	Wait(3.0)
	Log("  bleed_turn: 9x19 into the chest from above")
	ABL.DevShootAt(host, aim, Vector(0.2, 0.08, 1):GetNormalized(), nil, 60, "9x19mmparabellum")
	local t0 = CurTime()
	Wait(2.3)
	for _, tt in ipairs({ 4, 9 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Whole(bot, string.format("bt_1back_%02ds", tt), { min = 22, max = 40 })
	end
	for i, pose in ipairs({ "tilt", "side", "back" }) do
		ABL.DevPose(rag, pose, false)
		Log("  bleed_turn: laid %s", pose)
		local t1 = CurTime()
		for _, tt in ipairs({ 3, 8 }) do
			local w = t1 + tt - CurTime()
			if w > 0 then Wait(w) end
			Whole(bot, string.format("bt_%d%s_%02ds", i + 1, pose, tt), { min = 22, max = 40 })
		end
	end
	FStats("bt")
	Client("stats", { name = "bleed_turn" })
	Wait(0.2)
end)
-- Three bodies bleeding at once, one of them running with its wounds.
hook.Add("StartCommand", "ABL_BleedTestRun", function(ply, cmd)
	if ply ~= runner then return end
	local t = CurTime() % 6
	cmd:SetForwardMove(400)
	cmd:SetButtons(bit.bor(IN_FORWARD, IN_SPEED))
	local yaw = t < 3 and 0 or 180
	cmd:SetViewAngles(Angle(0, yaw, 0))
	ply:SetEyeAngles(Angle(0, yaw, 0))
end)

ST.Add("bleed_many", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local host = ST.Host()
	local bodies = {}
	for i = 1, 2 do
		local bot, rag = LieDown(p + Vector((i - 1.5) * 70, 30, 0), i == 1 and "back" or "side")
		if rag then bodies[#bodies + 1] = { bot = bot, rag = rag } end
	end
	local run = NewBot()
	Place(run, p + Vector(0, -60, 0), 0)
	View(p + Vector(10, -150, 90), p + Vector(0, 0, 20))
	Wait(3.0)
	FStats("bm_before")
	for _, b in ipairs(bodies) do
		local aim = ABL.DevHitboxCenter(b.rag, "chest")
		if aim then
			ABL.DevShootAt(host, aim, Vector(0.2, 0.08, 1):GetNormalized(), nil, 60, "9x19mmparabellum")
			Wait(0.4)
			local a2 = ABL.DevHitboxCenter(b.rag, "ValveBiped.Bip01_L_Thigh")
			if a2 then ABL.DevShootAt(host, a2, Vector(0.1, 0.2, 1):GetNormalized(), nil, 60, "7.62x39mm") end
			Wait(0.4)
		end
	end
	-- the runner: wounds that leave it on its feet (an arm and a thigh, from the side)
	do
		local body = ABL.ZC.GetBody(run)
		local right = run:GetRight()
		for _, part in ipairs({ "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_R_Forearm" }) do
			local aim = ABL.DevHitboxCenter(body, part)
			if aim then ABL.DevShootAt(host, aim, right, nil, 60, "9x19mmparabellum") Wait(0.4) end
		end
	end
	Wait(1.5)
	Client("wounds", { name = "bm" })
	run:Freeze(false)
	runner = run
	for i = 1, 4 do
		Wait(4)
		Shot("bm_" .. i)
		FStats("bm_" .. i)
		Origin("bm_" .. i)
	end
	runner = nil
	if IsValid(run) then run:Freeze(true) end
	-- a close look at the runner's thigh while it stands again
	Wait(1.0)
	Client("viewmark", { kind = "entry", dist = 14, tilt = 20, spin = 0, fov = 40, newerThan = 600, follow = true })
	Wait(0.5)
	Shot("bm_runner")
	-- everything goes: nothing may be left of what was on them
	for _, b in ipairs(bodies) do if IsValid(b.bot) then b.bot:Kill() end end
	Wait(3.0)
	Shot("bm_dead")
	FStats("bm_dead")
	Client("stats", { name = "bleed_many" })
	Wait(0.2)
end)
