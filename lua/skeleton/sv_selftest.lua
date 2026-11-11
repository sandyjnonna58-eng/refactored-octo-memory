-- Test scenes of the skeleton module (developer tool). They run inside the blood module's harness
-- (lua/advancedblood/server/sv_selftest.lua), which exists only when garrysmod/data/abl_selftest.txt
-- does, and only when asked for by name:
--
--   skel_registry   the registry on both sides; how a list of models resolves
--   skel_align      the skeleton in each of Z-City's fifteen character models, standing: in numbers
--                   (its surface against the body's, as it is and fitted) and in pictures
--   skel_anim       a character walking, running, crouching and jumping with its skeleton
--   skel_ragdoll    laid down as Z-City's ragdoll, up again, dead, alive again: the skeleton and the
--                   record through all of it, and what is left behind
--   skel_head       skull, lower jaw and brain in the heads of several models, through the fitting view
--                   (cl_headview.lua): from five sides, glass, cut open, alone; turning, moving, laid
--                   down, dead, gone; the brain's own surface against the skull's, measured
--   skel_inspect    the inspection view: the bone under the crosshair, joints, solids, colours
--   skel_brain      the brain module: what lies under which skull bone; a skull fracture gets a place
--   skel_injury     records: by hand, to a client, and from bullets through Z-City's own damage
--   skel_trace      paths through a body: the server's answers, and this client's to the same paths
--   skel_perf       what it costs
-- The client half is cl_selftest.lua.

local SK = HemoSkeleton
if not (istable(ABL) and istable(ABL.SelfTest)) then return end
local S = ABL.SelfTest
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = S.Log, S.Wait, S.Client, S.NewBot, S.Place, S.View, S.Shot, S.FindSpot
local C, I, RC, ST, M = SK.Config, SK.Injury, SK.Records, SK.Stock, SK.M

RunConsoleCommand("skel_dev", "1")

local function L(fmt, ...) Log("  skel: " .. string.format(fmt, ...)) end
local function Cvar(name, value) Client("cvar", { name = name, value = tostring(value) }) end
local function ViewOff() Cvar("skel_view", 0) Cvar("skel_view_labels", 1) Cvar("skel_view_colour", 0) Cvar("skel_view_joints", 0) Cvar("skel_view_proxies", 0) Cvar("skel_view_missing", 0) Cvar("skel_view_fit", 1) Cvar("skel_view_tier", 3) end

local MALE, FEMALE = {}, {}
for i = 1, 9 do MALE[i] = string.format("models/zcity/m/male_%02d.mdl", i) end
for _, i in ipairs({ 1, 2, 3, 4, 6, 7 }) do FEMALE[#FEMALE + 1] = string.format("models/zcity/f/female_%02d.mdl", i) end

local function Model(bot, model)
	bot:SetModel(model)
	Wait(0.3)
	if bot:GetModel() ~= model then L("WARNING: %s is %s, not %s", bot:Nick(), tostring(bot:GetModel()), model) end
end

-- a place on a bone of a body, in the world (the middle of the middle solid of its proxy)
local function PointOn(body, id)
	local pose = SK.PoseOf(body)
	local st = ST.bones[id]
	local rows = pose and st and pose:Bone(id)
	if not rows then return nil end
	local x, y, z = st.c[1], st.c[2], st.c[3]
	if istable(st.proxy) then
		local s = st.proxy[math.ceil(#st.proxy / 2)]
		if s[1] == "c" then x, y, z = (s[2] + s[5]) / 2, (s[3] + s[6]) / 2, (s[4] + s[7]) / 2 else x, y, z = s[2], s[3], s[4] end
	end
	return Vector(M.Xf(rows, x, y, z))
end

------------------------------------------------------------------------------------------
S.Add("skel_registry", function()
	local bad = SK.Check()
	L("registry: %d bones, %d joints, sum %d: %d complaint(s)", #SK.BoneList, #SK.JointList, SK.Sum(), #bad)
	for _, s in ipairs(bad) do L("   %s", s) end
	local src, proxies = {}, 0
	for id, st in pairs(ST.bones) do src[st.src] = (src[st.src] or 0) + 1 if istable(st.proxy) then proxies = proxies + #st.proxy end end
	L("stock data: %d bones measured on the asset, %d placed by rule, %d a place only; %d solids; %d units", src.stock or 0, src.derived or 0, src.placed or 0, proxies, table.Count(ST.units))
	Client("skelreg", { sum = SK.Sum() })
	Wait(0.5)
	local models = {}
	for _, m in ipairs(MALE) do models[#models + 1] = m end
	for _, m in ipairs(FEMALE) do models[#models + 1] = m end
	for _, m in ipairs({ "models/player/skeleton.mdl", "models/player/kleiner.mdl", "models/player/combine_soldier.mdl", "models/player/police.mdl", "models/player/zombie_classic.mdl",
		"models/player/group01/male_07.mdl", "models/player/group01/female_02.mdl", "models/combine_soldier.mdl", "models/police.mdl", "models/zombie/classic.mdl", "models/alyx.mdl",
		"models/vortigaunt.mdl", "models/headcrabclassic.mdl", "models/antlion.mdl", "models/props_c17/oildrum001.mdl" }) do models[#models + 1] = m end
	Client("skelmodels", { models = models })
	Wait(3)
	-- the same question on the server, of entities that are there
	local bot = NewBot()
	local p = FindSpot({ open = 120, outdoor = true })
	Place(bot, p, 0)
	Wait(1)
	local body = SK.BodyOf(bot)
	local pose, why = SK.PoseOf(body)
	for _, line in ipairs(SK.Rig.Describe(SK.Rig.Resolve(body))) do L("server: %s", line) end
	L("server: pose of %s: %s; fit %s", tostring(body), pose and "there" or ("none: " .. tostring(why)), pose and pose.fit.src or "-")
	local prop = ents.Create("prop_physics")
	prop:SetModel("models/props_c17/oildrum001.mdl")
	prop:SetPos(p + Vector(60, 60, 30))
	prop:Spawn()
	Wait(0.3)
	local pp, pw = SK.PoseOf(prop)
	L("server: a barrel: %s; a path through it meets %s", pp and "a pose (WRONG)" or ("no skeleton (" .. tostring(pw) .. ")"), tostring(SK.Trace(prop, prop:GetPos() - Vector(50, 0, 0), prop:GetPos() + Vector(50, 0, 0))))
	prop:Remove()
end)

------------------------------------------------------------------------------------------
S.Add("skel_align", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(96, 0, 4), mid)
	Cvar("skel_view_who", "all")
	Cvar("skel_view_labels", 0)
	Cvar("skel_view", 1)
	Wait(3)
	local shots = { ["male_06"] = true, ["male_07"] = true, ["female_01"] = true, ["female_06"] = true }
	local all = {}
	for _, m in ipairs(MALE) do all[#all + 1] = m end
	for _, m in ipairs(FEMALE) do all[#all + 1] = m end
	for _, model in ipairs(all) do
		Model(bot, model)
		local name = string.match(model, "([^/]+)%.mdl$")
		Wait(1.2)
		Client("skelfit", { ent = bot:EntIndex(), tag = "standing " .. name })
		Wait(2.6)
		if shots[name] then
			Cvar("skel_view", 1)
			View(mid + Vector(96, 0, 4), mid)
			Wait(0.4)
			Shot("ska_" .. name .. "_1_front")
			View(mid + Vector(0, 100, 4), mid)
			Wait(0.4)
			Shot("ska_" .. name .. "_2_side")
			Cvar("skel_view_fit", 0)
			Wait(0.3)
			Shot("ska_" .. name .. "_3_side_unfitted")
			Cvar("skel_view_fit", 1)
			-- as part of the world: what shows has come through the body's surface
			Cvar("skel_view", 2)
			Wait(0.3)
			Shot("ska_" .. name .. "_4_side_inside")
			View(mid + Vector(-96, 0, 4), mid)
			Wait(0.4)
			Shot("ska_" .. name .. "_5_back_inside")
			Cvar("skel_view_fit", 0)
			Wait(0.3)
			Shot("ska_" .. name .. "_6_back_inside_unfitted")
			Cvar("skel_view_fit", 1)
			-- the front and the feet, as part of the world
			View(mid + Vector(96, 0, 4), mid)
			Wait(0.4)
			Shot("ska_" .. name .. "_7_front_inside")
			local feet = p + Vector(0, 0, 6)
			View(feet + Vector(46, 14, 16), feet)
			Wait(0.4)
			Shot("ska_" .. name .. "_8_feet_inside")
			Cvar("skel_view", 1)
			Wait(0.3)
			Shot("ska_" .. name .. "_9_feet_through")
			View(mid + Vector(96, 0, 4), mid)
		end
	end
	-- a model the generator has not measured: a fit of lengths only
	Model(bot, "models/player/kleiner.mdl")
	Wait(1.2)
	Client("skelfit", { ent = bot:EntIndex(), tag = "standing kleiner (not measured by the generator)" })
	Wait(2.6)
	Shot("ska_kleiner_front")
	ViewOff()
end)

------------------------------------------------------------------------------------------
S.Add("skel_anim", function()
	for _, model in ipairs({ "models/zcity/m/male_03.mdl", "models/zcity/f/female_02.mdl" }) do
		-- (a place of its own for each: the one before stays where it stood, out of this one's picture)
		local p = FindSpot({ open = 260, outdoor = true })
		local bot = NewBot()
		Place(bot, p, 90)
		Model(bot, model)
		local name = string.match(model, "([^/]+)%.mdl$")
		Cvar("skel_view_who", "all")
		Cvar("skel_view_labels", 0)
		Cvar("skel_view", 1)
		local mid = p + Vector(0, 0, 36)
		View(mid + Vector(230, 0, 26), mid)
		Wait(3)
		Client("skelfit", { ent = bot:EntIndex(), tag = "idle " .. name })
		Wait(1.5)
		-- to and fro along the line of sight's cross direction
		local mode = "run"
		bot:Freeze(false)
		S.Drive(bot, function(b, cmd)
			local phase = math.floor(CurTime() / 0.7) % 2
			if mode == "run" then cmd:SetForwardMove(phase == 0 and 300 or -300) cmd:SetButtons(IN_SPEED)
			elseif mode == "walk" then cmd:SetForwardMove(phase == 0 and 90 or -90)
			elseif mode == "crouch" then cmd:SetForwardMove(phase == 0 and 60 or -60) cmd:SetButtons(IN_DUCK)
			elseif mode == "jump" then cmd:SetButtons(bit.bor(IN_JUMP, IN_SPEED)) cmd:SetForwardMove(200) end
		end)
		for _, step in ipairs({ { "run", 1.1 }, { "run", 0.9 }, { "walk", 1.3 }, { "crouch", 1.6 }, { "jump", 0.45 } }) do
			mode = step[1]
			Wait(step[2])
			Client("skelfit", { ent = bot:EntIndex(), tag = step[1] .. " " .. name, every = 5 })
			Shot("skm_" .. name .. "_" .. step[1] .. "_through")
			Cvar("skel_view", 2)
			Wait(0.25)
			Shot("skm_" .. name .. "_" .. step[1] .. "_inside")
			Cvar("skel_view", 1)
			Wait(0.2)
		end
		S.Drive(bot, nil)
		bot:Freeze(true)
		Wait(0.5)
	end
	ViewOff()
end)

------------------------------------------------------------------------------------------
S.Add("skel_ragdoll", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	Cvar("skel_view_who", "all")
	Cvar("skel_view_labels", 0)
	Cvar("skel_view", 1)
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(90, 30, 10), mid)
	Wait(3)
	Client("skelstate", { tag = "before" })
	I.Set(bot, "femur_l", { state = C.State.FRACTURE, site = 0.4 }, "manual")
	I.Set(bot, "rib5_r", { state = C.State.FISSURE }, "manual")
	I.SetJoint(bot, "glenohumeral_r", 1, "manual")
	Wait(0.8)
	Client("skelrec", { ent = bot:EntIndex(), tag = "standing" })
	Shot("skr_1_standing_with_record")
	-- laid down
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.7)
	local rag = ABL.DevRagdollOf(bot)
	if not IsValid(rag) then L("no ragdoll") return end
	ABL.DevPose(rag, "back", false)
	Wait(2.2)
	local c = rag:WorldSpaceCenter()
	View(c + Vector(40, 26, 64), c)
	Wait(0.6)
	local rec, char = I.Get(rag)
	L("laid down: the body is %s; the record is %s's, %d bone(s)", tostring(rag), tostring(char), rec and rec.n or 0)
	Client("skelrec", { ent = rag:EntIndex(), tag = "lying" })
	Client("skelfit", { ent = rag:EntIndex(), tag = "lying male_06" })
	Wait(1.5)
	Shot("skr_2_lying_through")
	Cvar("skel_view", 2)
	Wait(0.3)
	Shot("skr_3_lying_inside")
	Cvar("skel_view", 1)
	-- up again
	hg.FakeUp(bot, true, true)
	Wait(1.8)
	View(mid + Vector(90, 30, 10), mid)
	Wait(0.6)
	rec, char = I.Get(bot)
	L("up again: the body is %s; the record is %s's, %d bone(s)", tostring(SK.BodyOf(bot)), tostring(char), rec and rec.n or 0)
	Client("skelrec", { ent = bot:EntIndex(), tag = "up again" })
	Shot("skr_4_up_again")
	-- dead: the corpse has the skeleton and the record
	Wait(2.5)
	bot:Kill()
	Wait(0.3)
	L("killed: alive %s, corpse %s", tostring(bot:Alive()), tostring(bot:GetNWEntity("RagdollDeath")))
	local corpse
	for _ = 1, 20 do
		corpse = bot:GetNWEntity("RagdollDeath")
		if IsValid(corpse) then break end
		if bot:Alive() then bot:Kill() end
		Wait(0.3)
	end
	Wait(1.5)
	rec, char = I.Get(IsValid(corpse) and corpse or bot)
	L("dead: the corpse is %s; its record: %s, %d bone(s); the player's own: %s", tostring(corpse), tostring(char), rec and rec.n or 0, tostring(RC.byChar[bot] ~= nil))
	if IsValid(corpse) then
		c = corpse:WorldSpaceCenter()
		View(c + Vector(40, 26, 64), c)
		Wait(1.2)
		Client("skelrec", { ent = corpse:EntIndex(), tag = "corpse" })
		Client("skelfit", { ent = corpse:EntIndex(), tag = "corpse male_06" })
		Wait(1.5)
		Shot("skr_5_corpse_through")
	end
	-- alive again: a new body, no record; the corpse keeps its own
	bot:Spawn()
	Wait(0.6)
	Place(bot, p + Vector(0, 90, 0), 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	Wait(1.6)
	local rc = IsValid(corpse) and I.Get(corpse)
	L("alive again: the player's record: %s; the corpse's: %s bone(s)", tostring(RC.byChar[bot] ~= nil), rc and rc.n or "none")
	Client("skelrec", { ent = bot:EntIndex(), tag = "alive again" })
	View(mid + Vector(110, 45, 30), mid + Vector(0, 45, -10))
	Wait(0.8)
	Shot("skr_6_alive_again_and_corpse")
	-- the corpse removed: its record goes with it
	if IsValid(corpse) then corpse:Remove() end
	Wait(1.2)
	local chars, bones = I.Count()
	L("corpse removed: records of %d character(s), %d bone(s) left; written %d, handed over %d, dropped %d", chars, bones, RC.stats.set, RC.stats.handed, RC.stats.dropped)
	ViewOff()
	Wait(0.5)
	Client("skelstate", { tag = "after, view off" })
end)

------------------------------------------------------------------------------------------
-- The head: skull, lower jaw and brain in the heads of several models, through the fitting view
-- (cl_headview.lua). From the head's side, front, back, top and three quarters; the skull as glass
-- round the brain, cut open, alone, the brain alone; with the body as it is, faint, not drawn; the
-- landmarks the fit was made by; while the head is turned and the body moves; laid down, up, dead,
-- alive again, gone; a model that was not measured; and the view off again.
S.Add("skel_head", function()
	local p = FindSpot({ open = 200, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	RunConsoleCommand("neuro_dev", "1")
	local e = bot:EntIndex()
	local function Head(t) t.ent = t.ent or e Client("skelhead", t) end
	local function Show(show, body, marks) Cvar("skel_head_show", show) Cvar("skel_head_body", body) Cvar("skel_head_marks", marks and 1 or 0) end
	local function Pic(name) Wait(0.4) Shot(name) end
	ViewOff()
	-- (the host is stood near: a body out of its sight is not sent to the client)
	View(p + Vector(80, 0, 66), p + Vector(0, 0, 62))
	Cvar("neuro_brain_world", 0)
	Cvar("neuro_brain_fit", 1)
	Cvar("skel_head_who", "aim")
	Cvar("skel_head_cam", "off")
	Show("both", 1, true)
	Cvar("skel_head", 1)
	Wait(0.5)
	Head({ cam = "side" })
	-- (the game's skeleton model is taken apart and the brain's surfaces are built, a little a frame)
	Wait(14)
	Client("skelheadstate", { tag = "on" })
	local full = { ["male_06"] = true, ["female_06"] = true }
	for _, model in ipairs({ "models/zcity/m/male_06.mdl", "models/zcity/f/female_06.mdl", "models/zcity/m/male_01.mdl", "models/zcity/f/female_01.mdl", "models/zcity/m/male_09.mdl", "models/zcity/f/female_04.mdl", "models/zcity/m/male_03.mdl" }) do
		Model(bot, model)
		local name = string.match(model, "([^/]+)%.mdl$")
		Wait(1.4)
		Show("both", 1, true)
		Head({ cam = "side", log = name })
		Client("skelbrainfit", { ent = e, tag = name })
		Client("skelfit", { ent = e, tag = "standing " .. name })
		Wait(2.4)
		Pic("skh_" .. name .. "_1_side")
		Show("both", 2, true)
		Pic("skh_" .. name .. "_2_side_body_faint")
		Head({ cam = "front" })
		Pic("skh_" .. name .. "_3_front_body_faint")
		Show("cut", 0, false)
		Head({ cam = "side" })
		Pic("skh_" .. name .. "_4_side_skull_cut_open")
		if full[name] then
			Show("both", 2, true)
			Head({ cam = "top" })
			Pic("skh_" .. name .. "_5_top_body_faint")
			Head({ cam = "back" })
			Pic("skh_" .. name .. "_6_back_body_faint")
			Show("both", 1, false)
			Head({ cam = "quarter" })
			Pic("skh_" .. name .. "_7_three_quarter")
			Show("skull", 0, true)
			Head({ cam = "side" })
			Pic("skh_" .. name .. "_8_skull_alone")
			Show("brain", 0, false)
			Pic("skh_" .. name .. "_9_brain_alone")
			Show("brain", 2, false)
			Head({ cam = "front" })
			Pic("skh_" .. name .. "_10_brain_front_body_faint")
			-- for holding against it: the stock skull as the rig carries it, and the brain where the brain module puts it on its own
			Cvar("neuro_brain_fit", 0)
			Show("both", 2, false)
			Head({ cam = "side", nofit = true })
			Pic("skh_" .. name .. "_11_side_nothing_fitted")
			Head({ cam = "front" })
			Pic("skh_" .. name .. "_12_front_nothing_fitted")
			Cvar("neuro_brain_fit", 1)
			Head({ cam = "side", nofit = false })
			Wait(0.3)
		end
	end

	-- fitting by hand: a number tried out from the console, seen at once, printed, dropped again
	Model(bot, "models/zcity/m/male_06.mdl")
	Wait(1.2)
	Show("both", 2, true)
	Head({ cam = "side" })
	Client("skelheadcmd", { cmd = "skel_head_nudge", args = { "skull.up", "1.2" } })
	Client("skelheadcmd", { cmd = "skel_head_set", args = { "skull.side", "1" } })
	Client("skelheadcmd", { cmd = "skel_head_set", args = { "brain.k", "2.58" } })
	Wait(0.8)
	Pic("skh_hand_1_skull_up_and_wide_brain_large")
	Head({ cam = "front" })
	Pic("skh_hand_2_the_same_front")
	Client("skelheadcmd", { cmd = "skel_head_print", args = {} })
	Client("skelheadcmd", { cmd = "skel_head_reset", args = {} })
	Wait(0.8)
	Head({ cam = "side" })
	Pic("skh_hand_3_dropped_again")

	-- what the brain in a head costs to draw by the brain module's own hook: where the skull is fitted
	-- (with the cord turned at the skull's base), and at the place that module gives it on its own
	Model(bot, "models/zcity/m/male_06.mdl")
	Wait(1.2)
	Show("skull", 1, false)
	Head({ cam = "quarter" })
	Cvar("neuro_brain_world", 1)
	Wait(4)
	Client("skelheadstate", { tag = "the brain module's own drawing in a head, where the skull is fitted" })
	Cvar("neuro_brain_fit", 0)
	Wait(4)
	Client("skelheadstate", { tag = "the same with neuro_brain_fit 0" })
	Cvar("neuro_brain_fit", 1)
	Cvar("neuro_brain_world", 0)
	Wait(0.5)

	-- the head turned and the body moving: the camera goes with the head's place and keeps its own turn
	Show("both", 2, false)
	Head({ cam = "quarter", dist = 50, follow = true })
	-- (a bot looks where its commands say: the head goes up and down with the eyes, the body round with them)
	local lookP, lookY = 0, 0
	bot:Freeze(false)
	S.Drive(bot, function(b, cmd)
		cmd:SetViewAngles(Angle(lookP, lookY, 0))
		b:SetEyeAngles(Angle(lookP, lookY, 0))
	end)
	for _, look in ipairs({ { "level", 0, 0 }, { "up", -70, 0 }, { "down", 70, 0 }, { "left", 0, 55 }, { "right", 0, -55 } }) do
		lookP, lookY = look[2], look[3]
		Wait(1.0)
		local hb = bot:LookupBone("ValveBiped.Bip01_Head1")
		local hm = hb and bot:GetBoneMatrix(hb)
		L("head: looking %s: eyes pitch %.0f yaw %.0f; the head bone's own axis points %s", look[1], bot:EyeAngles().p, bot:EyeAngles().y, hm and tostring(hm:GetForward()) or "?")
		Pic("skh_turn_" .. look[1])
	end
	lookP, lookY = 0, 0
	Wait(0.5)
	local mode = "walk"
	S.Drive(bot, function(b, cmd)
		local phase = math.floor(CurTime() / 0.7) % 2
		if mode == "run" then cmd:SetForwardMove(phase == 0 and 300 or -300) cmd:SetButtons(IN_SPEED)
		elseif mode == "walk" then cmd:SetForwardMove(phase == 0 and 90 or -90)
		elseif mode == "crouch" then cmd:SetForwardMove(phase == 0 and 60 or -60) cmd:SetButtons(IN_DUCK)
		elseif mode == "jump" then cmd:SetButtons(bit.bor(IN_JUMP, IN_SPEED)) cmd:SetForwardMove(200) end
	end)
	for _, step in ipairs({ { "run", 1.0 }, { "walk", 1.2 }, { "crouch", 1.5 }, { "jump", 0.45 } }) do
		mode = step[1]
		Wait(step[2])
		Shot("skh_move_" .. step[1])
		Wait(0.2)
	end
	S.Drive(bot, nil)
	bot:Freeze(true)
	Wait(0.6)

	-- laid down as Z-City's ragdoll, up again, dead, alive again
	Place(bot, p, 0)
	Wait(0.8)
	Show("both", 1, false)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.7)
	local rag = ABL.DevRagdollOf(bot)
	if IsValid(rag) then
		ABL.DevPose(rag, "back", false)
		Wait(2.2)
		Head({ ent = rag:EntIndex(), cam = "quarter", dist = 44, log = "laid down" })
		Client("skelbrainfit", { ent = rag:EntIndex(), tag = "laid down" })
		Wait(1.2)
		Pic("skh_life_1_laid_down")
		Show("cut", 2, false)
		Pic("skh_life_2_laid_down_cut_open")
		Show("both", 1, false)
		hg.FakeUp(bot, true, true)
		Wait(1.8)
		Head({ cam = "quarter", dist = 44 })
		Client("skelheadstate", { tag = "up again" })
		Pic("skh_life_3_up_again")
	else
		L("head: no ragdoll to lay it down as")
	end
	Wait(1.5)
	bot:Kill()
	local corpse
	for _ = 1, 20 do
		corpse = bot:GetNWEntity("RagdollDeath")
		if IsValid(corpse) then break end
		if bot:Alive() then bot:Kill() end
		Wait(0.3)
	end
	Wait(1.6)
	if IsValid(corpse) then
		Head({ ent = corpse:EntIndex(), cam = "quarter", dist = 44, log = "corpse" })
		Wait(0.8)
		Pic("skh_life_4_corpse")
	else
		L("head: no corpse")
	end
	bot:Spawn()
	Wait(0.6)
	Place(bot, p + Vector(0, 90, 0), 0)
	Model(bot, "models/zcity/f/female_06.mdl")
	Wait(1.6)
	Head({ cam = "quarter", dist = 44, log = "alive again" })
	Client("skelheadstate", { tag = "alive again" })
	Pic("skh_life_5_alive_again")
	-- gone: the corpse, then the character itself
	if IsValid(corpse) then corpse:Remove() end
	Show("both", 2, false)
	Wait(0.5)
	Client("skelheadstate", { tag = "before its body goes" })
	local spare = NewBot()
	Place(spare, p + Vector(0, -90, 0), 0)
	Model(spare, "models/player/kleiner.mdl")
	Wait(1.5)
	bot:Kick("test")
	Wait(1.5)
	Client("skelheadstate", { tag = "its body gone" })
	Shot("skh_life_6_body_gone")

	-- a model the generator has not measured: the stock skull as the rig carries it, the brain as it lies in that skull
	-- (Z-City dresses a character a moment after it spawns, and may give it its own model back)
	for _ = 1, 4 do
		if spare:GetModel() == "models/player/kleiner.mdl" then break end
		Model(spare, "models/player/kleiner.mdl")
		Wait(0.8)
	end
	L("head: the model that was not measured is %s", tostring(spare:GetModel()))
	Show("both", 2, true)
	Head({ ent = spare:EntIndex(), cam = "side", log = "kleiner (not measured)" })
	Client("skelbrainfit", { ent = spare:EntIndex(), tag = "kleiner (not measured)" })
	Wait(2)
	Pic("skh_unmeasured_1_side")
	Head({ ent = spare:EntIndex(), cam = "front" })
	Pic("skh_unmeasured_2_front")

	-- the view off: nothing of it is left
	Cvar("skel_head", 0)
	Wait(0.6)
	Client("skelheadstate", { tag = "off" })
	Shot("skh_off")
	Show("both", 1, true)
end)

------------------------------------------------------------------------------------------
S.Add("skel_inspect", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(96, 0, 4), mid)
	Cvar("skel_view_who", "all")
	Cvar("skel_view", 1)
	Wait(3.5)
	local e = bot:EntIndex()
	-- the bone under the crosshair: the camera is pointed at a bone, the view names what it finds there
	for _, a in ipairs({ { "femur_l", Vector(1, 0.25, 0), 42 }, { "tibia_r", Vector(1, -0.2, 0), 42 }, { "humerus_l", Vector(1, 0.4, 0.2), 40 }, { "rib6_l", Vector(0.3, 1, 0), 40 },
		{ "frontal", Vector(1, 0, 0.15), 30 }, { "mandible", Vector(1, 0.3, -0.2), 30 }, { "scapula_r", Vector(-1, -0.3, 0.1), 40 }, { "l3", Vector(-1, 0, 0), 40 }, { "hip_l", Vector(0.3, 1, 0.1), 44 },
		{ "calcaneus_l", Vector(-0.4, 1, 0.3), 30 } }) do
		Client("skelaim", { ent = e, bone = a[1], dir = a[2], dist = a[3] })
		Wait(0.7)
		Client("skelhover", { tag = a[1], want = a[1], lines = a[1] == "femur_l" or a[1] == "frontal" or a[1] == "l3" })
		Wait(0.2)
		if a[1] == "femur_l" or a[1] == "frontal" or a[1] == "l3" or a[1] == "rib6_l" then Shot("ski_hover_" .. a[1]) end
	end
	-- the solids of the bone under the crosshair
	Cvar("skel_view_proxies", 1)
	Client("skelaim", { ent = e, bone = "femur_l", dir = Vector(1, 0.25, 0), dist = 42 })
	Wait(0.8)
	Client("skelhover", { tag = "femur_l, with its solids", want = "femur_l" })
	Shot("ski_solids_hover")
	Cvar("skel_view_proxies", 0)
	-- the overlays
	View(mid + Vector(84, 30, 6), mid)
	Wait(0.5)
	Cvar("skel_view_joints", 1)
	Wait(0.4)
	Shot("ski_joints")
	Cvar("skel_view_joints", 0)
	Cvar("skel_view_proxies", 2)
	Wait(0.4)
	Shot("ski_solids")
	Cvar("skel_view_proxies", 0)
	Cvar("skel_view_missing", 1)
	Wait(0.4)
	Shot("ski_missing")
	local hand = bot:GetPos() + Vector(4, 22, 34)
	View(hand + Vector(34, 10, 8), hand)
	Wait(0.5)
	Shot("ski_missing_hand")
	Cvar("skel_view_missing", 0)
	View(mid + Vector(84, 30, 6), mid)
	for mode, name in ipairs({ "units", "carriers", "sureness" }) do
		Cvar("skel_view_colour", mode)
		Wait(0.4)
		Shot("ski_colour_" .. name)
	end
	Cvar("skel_view_colour", 0)
	Cvar("skel_view_tier", 1)
	Wait(0.4)
	Shot("ski_tier_structural")
	Cvar("skel_view_tier", 3)
	-- off: nothing is left on the screen
	Cvar("skel_view", 0)
	Wait(0.5)
	Shot("ski_off")
	Client("skelstate", { tag = "view off" })
	-- the model on this machine taken as if it were not the stock one
	Cvar("skel_geo_coarse", 1)
	Cvar("skel_geo_reload", "")
	Cvar("skel_view", 1)
	Wait(3)
	Shot("ski_not_stock")
	Client("skelstate", { tag = "as if not the stock model" })
	Cvar("skel_geo_coarse", 0)
	Cvar("skel_geo_reload", "")
	Wait(3)
	Client("skelstate", { tag = "the stock model again" })
	ViewOff()
end)

------------------------------------------------------------------------------------------
S.Add("skel_brain", function()
	Client("skelbrain", {})
	Wait(0.5)
	if not (istable(NeuroTrauma) and NeuroTrauma.ApplyImpact) then L("brain: the brain module is not loaded on the server") return end
	local p = FindSpot({ open = 160, outdoor = true })
	local NT = NeuroTrauma
	-- blows from four sides: where the brain module books a skull fracture, the record names the bone
	for i, blow in ipairs({ { "the front", { 0, 0.9, 0.45 }, "frontal" }, { "the left", { 1, -0.1, 0.15 }, "temporal_l / parietal_l" }, { "behind", { 0, -1, 0.1 }, "occipital" }, { "above, right of the middle", { -0.3, -0.2, 1 }, "parietal_r" } }) do
		local bot = NewBot()
		Place(bot, p + Vector(0, (i - 2.5) * 50, 0), 0)
		Wait(0.8)
		local got
		for try = 1, 6 do
			local before = NT.Get(bot.organism)
			NT.ApplyImpact(bot, { contact = 13, rotation = 4, dir = blow[2], mechanism = "blunt", seed = 1000 * i + try })
			Wait(0.25)
			local st = NT.Get(bot.organism)
			local sk = SK.Skull(bot)
			if sk then
				got = sk
				L("brain: a blow from %s: the brain module's fracture %.2f (try %d); the record: %s, %s, at side %.1f face %.1f up %.1f (expected: %s)", blow[1], st and st.fracture or 0, try, sk.bone, C.StateName[sk.state],
					sk.at and sk.at[1] or 0, sk.at and sk.at[2] or 0, sk.at and sk.at[3] or 0, blow[3])
				break
			end
		end
		if not got then
			local st = NT.Get(bot.organism)
			L("brain: a blow from %s: the brain module booked no fracture in six blows (its number: %.2f); no record", blow[1], st and st.fracture or 0)
		end
		local st = NT.Get(bot.organism)
		L("brain: the brain module's own state of %s after it: %s", bot:Nick(), st and tostring(st.label or st.state) or "no record")
	end
	-- skull and brain shown together, each by its own module
	local bot = NewBot()
	Place(bot, p + Vector(120, 0, 0), 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	RunConsoleCommand("neuro_dev", "1")
	-- (the host is stood near: a body out of its sight is not sent to the client, and has no bones there to aim at)
	local head = p + Vector(120, 0, 62)
	View(head + Vector(0, 70, 4), head)
	Cvar("skel_view_who", "all")
	Cvar("skel_view", 1)
	Wait(3)
	local e = bot:EntIndex()
	Client("skelaim", { ent = e, bone = "temporal_l", dir = Vector(0, 1, 0.05), dist = 26 })
	Wait(0.8)
	Shot("skb_1_skull_side")
	Cvar("neuro_brain_world", 1)
	Wait(12)
	Shot("skb_2_skull_and_brain_side")
	Cvar("skel_view", 0)
	Wait(0.4)
	Shot("skb_3_brain_alone_side")
	Cvar("skel_view", 1)
	Client("skelaim", { ent = e, bone = "frontal", dir = Vector(1, 0.2, 0.1), dist = 26 })
	Wait(0.8)
	Shot("skb_4_skull_and_brain_front")
	Cvar("neuro_brain_world", 0)
	ViewOff()
end)

------------------------------------------------------------------------------------------
local function Fields(org)
	local out = {}
	for _, f in ipairs(SK.ZC.FIELDS) do if (tonumber(org[f]) or 0) > 0 then out[#out + 1] = string.format("%s %.2f", f, org[f]) end end
	for flag in pairs(SK.ZC.DISLOCATION) do if org[flag] then out[#out + 1] = flag end end
	for flag in pairs(SK.ZC.AMPUTATION) do if org[flag] then out[#out + 1] = flag end end
	return #out > 0 and table.concat(out, ", ") or "all zero"
end

S.Add("skel_injury", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local host = S.Host()
	-- by hand: written on the server, told to a client that watches, nothing else touched
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(90, 20, 6), mid)
	Cvar("skel_view_who", "all")
	Cvar("skel_view", 1)
	Wait(3)
	local org = bot.organism
	local before = Fields(org)
	local speed, hp = bot:GetWalkSpeed(), bot:Health()
	I.Set(bot, "radius_r", { state = C.State.FRACTURE, site = 0.7 }, "manual")
	I.Set(bot, "tibia_l", { state = C.State.COMMINUTED }, "manual")
	I.Set(bot, "t7", { state = C.State.BRUISED }, "manual")
	I.Set(bot, "parietal_l", { state = C.State.FISSURE, at = { 2.5, 0, 3 } }, "manual")
	Wait(0.8)
	L("by hand: four bones written; Z-City's numbers before: %s; after: %s; walking speed %d -> %d; health %d -> %d", before, Fields(org), speed, bot:GetWalkSpeed(), hp, bot:Health())
	for _, l in ipairs(SK.Dev.Describe(bot)) do L("   %s", l) end
	Client("skelrec", { ent = bot:EntIndex(), tag = "by hand" })
	Wait(0.3)
	Shot("skj_1_by_hand")
	L("worst of the left leg: %s; of the skull: %s; SK.Skull: %s; SK.SpineLevel: %s", C.StateName[I.Worst(bot, "lower_l")], C.StateName[I.Worst(bot, "skull")], tostring((SK.Skull(bot) or {}).bone), tostring(SK.SpineLevel(bot)))
	I.Clear(bot)
	Wait(0.5)
	Client("skelrec", { ent = bot:EntIndex(), tag = "cleared" })
	-- bullets through Z-City's own damage: each aimed at a bone
	local z = SK.ZC.stats
	local function Shoot(target, bone, fromDir, ammo)
		local body = SK.BodyOf(target)
		local at = PointOn(body, bone)
		if not at then L("shot at %s: no place for it on %s", bone, tostring(body)) return end
		local o = IsValid(target) and (target.organism or (IsValid(RC.CharOf(body)) and RC.CharOf(body).organism))
		local was = o and Fields(o) or "?"
		local n0 = z.booked
		ABL.DevShootAt(host, at, fromDir, nil, 60, ammo or "9x19mmparabellum")
		Wait(0.9)
		local rec, char = I.Get(SK.BodyOf(target))
		local hit = rec and rec.bones[SK.Bones[bone].idx]
		local parts = {}
		if rec then for idx, e in pairs(rec.bones) do parts[#parts + 1] = SK.BoneByIdx[idx].id .. "=" .. C.StateName[e.state] .. (bit.band(e.flags, C.Flag.APPROX) ~= 0 and "~" or "") end end
		table.sort(parts)
		L("shot at %s of %s (%s): Z-City before: %s; after: %s | booked by this shot: %d | on the aimed bone: %s | record now: %s", bone, tostring(char or target), ammo or "9 mm", was, o and Fields(o) or "?", z.booked - n0,
			hit and C.StateName[hit.state] or "nothing", #parts > 0 and table.concat(parts, " ") or "none")
	end
	local targets = { { "femur_l", "7.62x39mm" }, { "tibia_r", "7.62x39mm" }, { "humerus_l", "7.62x39mm" }, { "radius_r", "9x19mmparabellum" }, { "rib6_l", "9x19mmparabellum" }, { "hip_r", "7.62x39mm" }, { "l3", "7.62x39mm" }, { "mandible", "9x19mmparabellum" } }
	for i, tg in ipairs(targets) do
		local b = NewBot()
		Place(b, p + Vector(-70, (i - 4.5) * 44, 0), 0)
		if istable(b.organism) then b.organism.godmode = false end
		Wait(1.2)
		-- from the front (the bots face +x), a little from the side the bone is on
		local side = string.sub(tg[1], -2) == "_l" and 0.25 or (string.sub(tg[1], -2) == "_r" and -0.25 or 0)
		Shoot(b, tg[1], Vector(1, side, 0.05):GetNormalized(), tg[2])
		if i == 1 then
			Wait(0.5)
			local body = SK.BodyOf(b)
			local c = body:WorldSpaceCenter()
			View(c + Vector(40, 26, 64), c)
			Wait(0.8)
			Client("skelrec", { ent = body:EntIndex(), tag = "after the shot at the femur" })
			Shot("skj_2_after_a_shot")
		end
	end
	L("Z-City: %d hits placed (%d crossed a bone, %d took the nearest), %d booked, %d not booked by Z-City, %d changes with no hit to place them", z.located, z.crossed, z.nearest, z.booked, z.unbooked, z.regions)
	-- a shot character gets up again: its record stays (and, looked at in passing: what the blood module's store of hits keeps)
	local last = player.GetBots()[#player.GetBots()]
	if IsValid(last) and last:Alive() and IsValid(last.FakeRagdoll) then
		local rec = I.Get(last)
		local ws = ABL.WoundStore and ABL.WoundStore.Count(last) or -1
		if istable(last.organism) then last.organism.consciousness = 1 last.organism.otrub = false end
		hg.FakeUp(last, true, true)
		Wait(1.6)
		local rec2 = I.Get(last)
		L("a shot character got up: its bones on record %d -> %d; the blood module's kept hits %d -> %d (ragdoll still there: %s)", rec and rec.n or 0, rec2 and rec2.n or 0, ws, ABL.WoundStore and ABL.WoundStore.Count(last) or -1, tostring(IsValid(last.FakeRagdoll)))
	end
	ViewOff()
end)

------------------------------------------------------------------------------------------
S.Add("skel_trace", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	Cvar("skel_view_who", "all")
	Cvar("skel_view", 1)
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(96, 0, 4), mid)
	Wait(3.5)
	local IDS = { "frontal", "mandible", "c4", "t6", "l3", "sacrum", "rib5_l", "clavicle_r", "scapula_l", "humerus_l", "radius_r", "capitate_l", "mc1_l", "hpp2_l", "hdp3_r", "hip_r", "femur_l", "patella_r", "tibia_r",
		"calcaneus_l", "mt1_r", "fpp1_r", "fdp2_l" }
	do
		local prof = SK.Rig.Resolve(SK.BodyOf(bot))
		for _, line in ipairs(SK.Rig.Describe(prof)) do L("server: %s", line) end
	end
	local function Compare(body, tag)
		local pose = SK.PoseOf(body)
		if not pose then L("%s: no pose on the server", tag) return end
		pose:Fresh()
		local pos = {}
		for _, id in ipairs(IDS) do local x, y, z = pose:BonePos(id) if x then pos[id] = Vector(x, y, z) end end
		-- named paths
		local fl, fr = PointOn(body, "femur_l"), PointOn(body, "femur_r")
		if fl and fr then
			local d = (fr - fl):GetNormalized()
			for _, l in ipairs(SK.Dev.TraceText(body, fl - d * 8, fr + d * 8)) do L("%s, through both thighs from its left: %s", tag, l) end
		end
		local hp = pos.frontal
		if hp then
			local hm = pose:Skin("head")
			local fx, fy, fz = SK.Cranial.FromHead(0, 9, 1)
			local bx, by, bz = SK.Cranial.FromHead(0, -9, 0.5)
			local st = ST.bones.frontal
			local rows = pose:Bone("frontal")
			for _, l in ipairs(SK.Dev.TraceText(body, Vector(M.Xf(rows, fx, fy, fz)), Vector(M.Xf(rows, bx, by, bz)))) do L("%s, through the head from the front: %s", tag, l) end
		end
		local c = body:WorldSpaceCenter()
		for _, l in ipairs(SK.Dev.TraceText(body, c + Vector(0, 0, 90), c + Vector(60, 0, 90))) do L("%s, past it overhead: %s", tag, l) end
		-- paths for the client to ask too: three through each of the listed bones as the server has it,
		-- from any direction (paths taken at random through the space round a body meet next to nothing)
		local segs = {}
		for _, id in ipairs(IDS) do
			local at = PointOn(body, id)
			if at then
				for _ = 1, 3 do
					local d = VectorRand():GetNormalized()
					local a, b = at + d * 10, at - d * 10
					local hits = SK.Trace(pose, a, b)
					local ids = {}
					for _, h in ipairs(hits) do ids[#ids + 1] = h.id end
					segs[#segs + 1] = { a = a, b = b, ids = ids, want = id }
				end
			end
		end
		Client("skelwhere", { ent = body:EntIndex(), tag = tag, pos = pos, segs = segs })
		Wait(0.6)
	end
	Compare(SK.BodyOf(bot), "standing")
	Shot("skt_1_standing")
	hg.Fake(bot)
	Wait(0.7)
	local rag = ABL.DevRagdollOf(bot)
	if IsValid(rag) then
		ABL.DevPose(rag, "back", true)
		Wait(1.5)
		Compare(rag, "lying still (ragdoll)")
		ABL.DevPose(rag, "side", true)
		Wait(1.5)
		Compare(rag, "on its side (ragdoll)")
	end
	ViewOff()
end)

------------------------------------------------------------------------------------------
S.Add("skel_perf", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local bots = {}
	for i = 1, 6 do
		bots[i] = NewBot()
		Place(bots[i], p + Vector(0, (i - 3.5) * 46, 0), 0)
		Model(bots[i], i % 2 == 0 and "models/zcity/f/female_01.mdl" or "models/zcity/m/male_06.mdl")
	end
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(210, 0, 30), mid)
	ViewOff()
	Wait(2.5)
	Client("skelperf", { tag = "view off", secs = 2 })
	Wait(2.6)
	Cvar("skel_view_who", "all")
	Cvar("skel_view", 1)
	Wait(3.5)
	Client("skelperf", { tag = "six bodies, through", secs = 3 })
	Wait(3.6)
	Client("skelpasses", { tag = "six bodies" })
	Wait(0.5)
	Shot("skp_six")
	Cvar("skel_view_proxies", 2)
	Wait(1)
	Client("skelperf", { tag = "six bodies, with every solid as lines", secs = 2 })
	Wait(2.6)
	Shot("skp_six_solids")
	Client("skelstate", { tag = "with every solid of the nearest body shown" })
	Cvar("skel_view_proxies", 0)
	Cvar("skel_view_who", "aim")
	View(mid + Vector(210, 0, 30), bots[3]:GetPos() + Vector(0, 0, 40))
	Wait(1.5)
	Client("skelperf", { tag = "one body (the one looked at), with its bone named", secs = 3 })
	Wait(3.6)
	Client("skelpasses", { tag = "one body (the one looked at)" })
	Wait(0.5)
	Client("skelhover", { tag = "the one looked at, from 210 units" })
	Shot("skp_aimed")
	Client("skelquery", { ent = bots[3]:EntIndex(), tag = "client", n = 1000 })
	Wait(1)
	-- the server's side of it
	local body = SK.BodyOf(bots[3])
	local pose = SK.PoseOf(body)
	local c = body:WorldSpaceCenter()
	local t0, hits = SysTime(), 0
	for i = 1, 1000 do
		-- (through the middle of the body, from any side)
		local d = VectorRand():GetNormalized()
		local a, b = c + d * 40 + VectorRand() * 8, c - d * 40 + VectorRand() * 8
		hits = hits + #SK.Trace(pose, a, b)
	end
	local ms = (SysTime() - t0) * 1000
	L("queries server: 1000 paths through the middle of a body in %.1f ms (%.3f ms each), %.1f bones met a path", ms, ms / 1000, hits / 1000)
	t0 = SysTime()
	for i = 1, 1000 do pose:Fresh() for _, b in ipairs(SK.BoneList) do pose:Bone(b.id) end end
	L("pose server: every bone's matrix of a body worked out afresh 1000 times in %.1f ms (%.3f ms each)", (SysTime() - t0) * 1000, (SysTime() - t0))
	local org = bots[3].organism
	if istable(org) then
		t0 = SysTime()
		for i = 1, 2000 do SK.ZC.Look(org) end
		L("watching Z-City's numbers: 2000 looks at one character in %.2f ms (%.4f ms each; one is taken twice a second)", (SysTime() - t0) * 1000, (SysTime() - t0) * 1000 / 2000)
	end
	local chars, bones = I.Count()
	L("server holds records of %d character(s), %d bone(s); timers of its own: 2; hooks of its own run a tick: Org Think (a time check)", chars, bones)
	ViewOff()
	Wait(0.5)
	Client("skelstate", { tag = "after" })
end)
