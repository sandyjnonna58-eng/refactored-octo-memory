-- Look scenes (developer tool; only with the test harness, see sv_selftest.lua). They put the
-- situations of a piece of reference footage, and the faults found with them, in front of fixed
-- cameras, so that two builds can be laid beside each other. They run only when asked for by name
-- (docs/TESTING.md, "Look scenes"):
--   look_match      a standing character shot in the chest from where a player stands; the body
--                   on the ground seen from standing height (4, 8 and 14 s after the hit); a second
--                   shot into the head of the lying body; then the blood on the ground at the head
--                   seen against the sun's mirror direction, across it and with the sun behind,
--                   with the stains' and the pools' own lights, the stains' bodies and the wounds'
--                   recesses switched off in turn (which of them makes a look is read off the
--                   pictures), and the highlight under several settings
--   look_prop       blood thrown at a crate; the crate moved aside; the crate removed
--   look_turn       stains with a known direction on the floor, on top of a crate and on its
--                   side: do they point the way they were given
--   look_bodydrops  drops that land on a body and stay where they landed, on three lying
--                   characters and on a standing one
--   look_caps       the limits by character: ground stains of one character's blood, decals on
--                   one body
--   look_decal      does a decal of the engine show on the map's own floor (five marks in a row)
-- Pictures lm_*, lp_*, lt_*, lb_*, lc_* in data/abl_test_<label>/; lines "leak M* / P*",
-- "lookcount", "lookbody", "lookstamp", "lookgloss" in client_stats.txt.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot
local V = Vector

-- gm_construct: the acceptance spot of the pool scenes (a paved floor in the sun), and the way to its sun
local SPOT = V(901.6, -413.9, -144.0)
local SUN = V(-0.38, 0.52, 0.77)
-- (Z-City gives every bot a model of its own choosing: one model, so that two runs can be compared)
local MODEL = "models/zcity/m/male_06.mdl"
local ROUND = "7.62x51mm"

local function Cvar(name, value) Client("cvar", { name = name, value = tostring(value) }) Wait(0.5) end
local function Leak(name, base) Client("leakcheck", { name = name, key = "look", base = base }) Wait(0.15) end

-- How far it is clear from `from` along `dir`, up to `most` units.
local function Room(from, dir, most)
	local tr = util.TraceLine({ start = from, endpos = from + dir * most, mask = MASK_SOLID_BRUSHONLY })
	return tr.Fraction * most
end

local function Fake(bot)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	return ABL.DevRagdollOf(bot)
end

local function Crate(pos)
	local prop = ents.Create("prop_physics")
	prop:SetModel("models/props_junk/wood_crate001a.mdl")
	prop:SetPos(pos)
	prop:Spawn()
	local phys = prop:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	Wait(1)
	return prop
end

ST.Add("look_match", function()
	local p = game.GetMap() == "gm_construct" and SPOT or FindSpot({ open = 200, outdoor = true })
	Client("clear", {})
	Wait(0.4)
	local bot = NewBot()
	if not IsValid(bot) then Log("look_match: no bot") return end
	Place(bot, p, 0)
	bot:SetPlayerColor(V(0.82, 0.8, 0.74))
	bot:SetModel(MODEL)
	Wait(1.2)
	local body = ABL.ZC.GetBody(bot)
	local chest = ABL.DevHitboxCenter(body, "chest")
	if not chest then Log("look_match: no chest") return end
	local fwd, right = bot:GetForward(), bot:GetRight()
	fwd.z = 0 fwd:Normalize()

	-- the shot, seen from where the shooter stands
	local dist = math.min(170, Room(chest, fwd, 190) - 12)
	local gun = chest + fwd * dist
	Log("look_match: spot %.1f %.1f %.1f, shooter %.0f units in front, facing %.2f %.2f", p.x, p.y, p.z, dist, fwd.x, fwd.y)
	View(gun + right * 10 + V(0, 0, 6), chest)
	Wait(0.7)
	Shot("lm_a_standing")
	Client("lookgloss", { name = "view: the shooter's" })
	ABL.DevShootAt(ST.Host(), chest, fwd, nil, dist, ROUND)
	Wait(0.12) Shot("lm_b_hit")
	local t0 = CurTime()
	-- the mark on the chest a second later, from three steps away (the body may be going down)
	Wait(0.3)
	local now = ABL.ZC.GetBody(bot)
	local c1 = IsValid(now) and ABL.DevHitboxCenter(now, "chest") or chest
	View(c1 + fwd * 46 + right * 16 + V(0, 0, 22), c1)
	Wait(0.4) Shot("lm_c_chest_1s")
	Wait(0.4)
	if bot:Alive() then bot:Kill() end
	Wait(1.6)
	local rag = ABL.DevRagdollOf(bot)
	if not IsValid(rag) then Log("look_match: no body on the ground") return end
	local rc = ABL.DevHitboxCenter(rag, "chest") or rag:WorldSpaceCenter()
	-- the body on the ground, from standing height, the sun to the side (no mirror of it in view)
	local side = V(0.6, 0.8, 0)
	local function Play()
		rc = ABL.DevHitboxCenter(rag, "chest") or rc
		local eye = V(rc.x, rc.y, p.z + 64) + side * 72
		View(eye, rc)
		return eye
	end
	Play()
	Wait(math.max(0.5, t0 + 4 - CurTime())) Shot("lm_d_down_4s")
	Play()
	Wait(math.max(0.5, t0 + 8 - CurTime())) Shot("lm_e_down_8s")
	local eye = Play()
	Wait(math.max(0.5, t0 + 14 - CurTime())) Shot("lm_f_down_14s")
	Client("lookgloss", { name = "view: standing over the body" })
	Client("wounds", { name = "lm_chest" })
	Leak("M1_body_down_14s")

	-- the second shot: into the head of the lying body, from where the player stands. (What it
	-- throws stays wet for the pictures that follow: they are of wet blood under several settings.)
	RunConsoleCommand("abl_drying_scale", "6")
	Wait(0.5)
	local head = ABL.DevHitboxCenter(rag, "head")
	if not head then Log("look_match: no head") RunConsoleCommand("abl_drying_scale", "1") return end
	ABL.DevShootAt(ST.Host(), head, (eye - head):GetNormalized(), nil, 60, ROUND)
	Wait(0.12) Shot("lm_g_head_hit")
	Wait(1.4) Shot("lm_h_head_1s")
	Wait(4.5) Shot("lm_i_head_6s")
	Client("wounds", { name = "lm_head" })
	Leak("M2_head_shot_6s")

	-- the blood on the ground at the head: toward the sun's mirror, across it, the sun behind
	head = ABL.DevHitboxCenter(rag, "head") or head
	local g = V(head.x, head.y, p.z + 1)
	local mirror = V(-SUN.x, -SUN.y, SUN.z)
	local across = V(-SUN.y, SUN.x, SUN.z)
	-- (ten degrees beside the mirror direction: where the camera of scene headshot stands)
	local beside = V(16, -18, 20):GetNormalized()
	-- (further beside it)
	local wide = (mirror + across * 0.42):GetNormalized()
	View(g + mirror * 36, g)
	Wait(0.6) Shot("lm_j_mirror")
	Client("sheeninfo", { name = "lm_mirror" })
	Client("lookgloss", { name = "view: toward the sun's mirror" })
	Cvar("abl_ground_debug", 1)
	Shot("lm_j_mirror_no_stain_light")
	Cvar("abl_ground_debug", 4)
	Shot("lm_j_mirror_no_stain_bodies")
	Cvar("abl_ground_debug", 0)
	Cvar("abl_pool_debug", 1)
	Shot("lm_j_mirror_no_pool_light")
	Cvar("abl_pool_debug", 0)
	Cvar("abl_wound_3d", 0)
	Shot("lm_j_mirror_no_recess")
	Cvar("abl_wound_3d", 1)
	View(g + across * 36, g)
	Wait(0.6) Shot("lm_k_across")
	View(g + SUN * 36, g)
	Wait(0.6) Shot("lm_l_sun_behind")
	Client("lookgloss", { name = "view: the sun behind" })
	-- the highlight: how narrow, how bright (the same stains, from the mirror direction, ten degrees
	-- beside it and further beside it)
	for _, v in ipairs({ { 70, 3 }, { 160, 3 }, { 300, 3 }, { 300, 6 } }) do
		Client("lookgloss", { name = "lm", exp = v[1], boost = v[2] })
		View(g + mirror * 36, g)
		Wait(0.5) Shot(string.format("lm_n_gloss_%d_%d_mirror", v[1], v[2]))
		View(g + beside * 36, g)
		Wait(0.5) Shot(string.format("lm_n_gloss_%d_%d_beside", v[1], v[2]))
		View(g + wide * 36, g)
		Wait(0.5) Shot(string.format("lm_n_gloss_%d_%d_wide", v[1], v[2]))
		Client("sheeninfo", { name = "lm_gloss_" .. v[1] })
	end
	Client("lookgloss", { name = "lm back", exp = ABL.Config.Ground.glossExp, boost = ABL.Config.Ground.glossBoost })
	Client("sheeninfo", { name = "lm_end" })
	-- and the whole of it once more from standing height
	Play()
	Wait(0.6) Shot("lm_m_end")
	Client("stats", { name = "lm_end" })
	RunConsoleCommand("abl_drying_scale", "1")
	Wait(0.3)
end)

ST.Add("look_prop", function()
	local q = FindSpot({ open = 200, outdoor = true })
	if not q then Log("look_prop: no spot") return end
	Client("clear", {})
	Wait(0.4)
	local wide, wideAt = q + V(150, 30, 80), q + V(0, 30, 16)
	View(wide, wideAt)
	Wait(0.8)
	Leak("P0_before", true)
	local prop = Crate(q + V(0, 0, 22))
	-- (onto its top from above, and against the side that faces the camera)
	for k = 1, 10 do
		Client("spray", { pos = q + V(0, 0, 90), dir = V(0, 0, -1), speed = 30, count = 10, vol = 0.3, cone = 0.1, seed = 4600 + k })
		Client("spray", { pos = q + V(70, 0, 40), dir = V(-1, 0, 0), speed = 200, count = 14, vol = 0.15, cone = 0.2, seed = 4700 + k })
		Wait(0.4)
	end
	Wait(3)
	Leak("P1_on_the_prop")
	Shot("lp_a_prop")
	local near, nearAt = q + V(62, -14, 34), q + V(20, 0, 22)
	View(near, nearAt)
	Wait(0.6) Shot("lp_b_prop_close")
	-- the crate is moved aside: what is left where it stood, what went with it
	prop:SetPos(q + V(0, 90, 22))
	Wait(1)
	Shot("lp_c_moved_old_place")
	Leak("P2_moved_1s")
	View(near + V(0, 90, 0), nearAt + V(0, 90, 0))
	Wait(0.6) Shot("lp_d_moved_crate")
	View(wide, wideAt)
	Wait(0.6) Shot("lp_e_moved_wide")
	-- turned a quarter where it stands: the wet marks turn with it
	prop:SetAngles(Angle(0, 90, 0))
	Wait(1)
	Shot("lp_e_turned_wide")
	prop:Remove()
	Wait(1)
	Shot("lp_f_removed_wide")
	Leak("P3_removed_1s")
	Wait(0.2)
end)

-- Stains with a direction: on the floor (the map's own decals, the reference), on top of a
-- crate and on its side. Each row: along the first direction, along the second, between the two.
-- The crate's are stamped twice, the model's picture taken to run either way (ABL.Stains.MODEL_V):
-- first -1 (pictures lt_a: mirrored), then 1 (lt_b: the setting of the build, pointing as given).
ST.Add("look_turn", function()
	local q = FindSpot({ open = 200, outdoor = true })
	if not q then Log("look_turn: no spot") return end
	Client("clear", {})
	Wait(0.4)
	local prop = Crate(q + V(0, 0, 22))
	local c0 = prop:GetPos()
	local wide, wideAt = q + V(105, -8, 86), q + V(22, 0, 14)
	View(wide, wideAt)
	Wait(0.6)
	local X, Y, Z = V(1, 0, 0), V(0, 1, 0), V(0, 0, 1)
	local function Row(at, n, a, b)
		local t = {}
		for i = 0, 2 do
			local d = (i == 0 and a) or (i == 1 and b) or (a + b):GetNormalized()
			t[#t + 1] = { pos = at + Y * ((i - 1) * 12), n = n, d = d, fam = "elong", idx = 1 }
		end
		return t
	end
	-- the floor: toward +x, toward +y, between
	Client("lookstamp", { name = "floor", stamps = Row(q + V(48, 0, 0), Z, X, Y) })
	Wait(0.4)
	for _, k in ipairs({ -1, 1 }) do
		local tag = k < 0 and "a" or "b"
		-- the crate's top: toward +x, toward +y, between; its side: down, toward +y, between
		Client("lookstamp", { name = "top " .. tag, ent = prop, wipe = true, modelV = k, stamps = Row(c0 + V(0, 0, 20), Z, X, Y) })
		Wait(0.3)
		Client("lookstamp", { name = "side " .. tag, ent = prop, modelV = k, stamps = Row(c0 + V(20, 0, 2), X, -Z, Y) })
		Wait(0.6)
		View(wide, wideAt)
		Wait(0.5) Shot("lt_" .. tag .. "_wide")
		View(c0 + V(64, 0, 6), c0 + V(20, 0, 2))
		Wait(0.5) Shot("lt_" .. tag .. "_side")
		View(c0 + V(26, 0, 66), c0 + V(0, 0, 20))
		Wait(0.5) Shot("lt_" .. tag .. "_top")
	end
	-- (the loop ends on 1, the setting of the build)
	prop:Remove()
	Wait(0.3)
end)

-- Drops that land on a body and stay where they landed (abl_body_catch 0: the spot alone, no
-- stream). Three characters on their backs, the first in fixed clothes, the others as Z-City
-- dresses them; each from two distances, then with every decal of the engine taken off it (what
-- is still on it then is no decal). Then a standing character, thrown at from in front.
ST.Add("look_bodydrops", function()
	local q = FindSpot({ open = 220, outdoor = true })
	if not q then Log("look_bodydrops: no spot") return end
	Client("clear", {})
	Cvar("abl_body_catch", 0)
	Client("lookwatch", {})
	for n = 1, 3 do
		local bot = NewBot()
		if not IsValid(bot) then Log("look_bodydrops: no bot") break end
		Place(bot, q + V((n - 2) * 90, 0, 0), 0)
		if n == 1 then
			bot:SetPlayerColor(V(0.82, 0.8, 0.74))
			bot:SetModel(MODEL)
		end
		Wait(1.4)
		local rag = Fake(bot)
		if IsValid(rag) then
			Wait(0.8)
			ABL.DevPose(rag, "back", false)
			Wait(2)
			local c = ABL.DevHitboxCenter(rag, "chest") or rag:WorldSpaceCenter()
			View(c + V(34, 26, 40), c)
			Wait(0.5)
			for k = 1, 8 do
				c = ABL.DevHitboxCenter(rag, "chest") or c
				Client("spray", { pos = c + V(0, 0, 36), dir = V(0, 0, -1), speed = 120, count = 5, vol = 0.15, cone = 0.05, seed = 4800 + n * 10 + k })
				Wait(0.25)
			end
			Wait(1)
			Shot("lb_" .. n .. "_a_spots")
			Client("lookbody", { ent = rag, name = "lying " .. n })
			View(c + V(12, 9, 24), c)
			Wait(0.5) Shot("lb_" .. n .. "_b_close")
			Client("lookdecals", { ent = rag })
			Wait(0.4) Shot("lb_" .. n .. "_c_no_decals")
		else
			Log("look_bodydrops: no ragdoll for bot %d", n)
		end
	end
	-- a standing character: what the throw leaves on it
	local bot = NewBot()
	if IsValid(bot) then
		Place(bot, q + V(0, 110, 0), 0)
		bot:SetPlayerColor(V(0.82, 0.8, 0.74))
		bot:SetModel(MODEL)
		Wait(1.5)
		local chest = ABL.DevHitboxCenter(ABL.ZC.GetBody(bot), "chest")
		if chest then
			local from = chest + V(46, 0, 6)
			local dir = (chest - from):GetNormalized()
			View(chest + V(42, 20, 2), chest + V(0, 0, -12))
			Wait(0.5)
			for k = 1, 8 do
				Client("spray", { pos = from, dir = dir, speed = 170, count = 5, vol = 0.15, cone = 0.07, seed = 4900 + k })
				Wait(0.25)
			end
			Wait(1)
			Shot("lb_s_a_standing")
			Client("lookbody", { ent = bot, name = "standing" })
			View(chest + V(20, 8, 2), chest)
			Wait(0.5) Shot("lb_s_b_close")
		end
	end
	Cvar("abl_body_catch", 1)
	Client("lookcount", { name = "after look_bodydrops", ents = {} })
	Wait(0.2)
end)

-- The limits by character: stains on the ground of one character's blood, decals on one body.
ST.Add("look_caps", function()
	local q = FindSpot({ open = 220, outdoor = true })
	if not q then Log("look_caps: no spot") return end
	Client("clear", {})
	local a, b = NewBot(), NewBot()
	if not (IsValid(a) and IsValid(b)) then Log("look_caps: no bots") return end
	Place(a, q + V(-150, 120, 0), 0)
	Place(b, q + V(150, 120, 0), 0)
	View(q + V(0, -190, 150), q + V(0, 0, 0))
	Wait(1.5)
	Cvar("abl_max_ground_stains_per_body", 40)
	Client("lookcount", { name = "C0 before", ents = { a, b } })
	-- (A's blood, far more of it than A may keep stains of)
	for k = 1, 10 do
		Client("spray", { pos = q + V(-60, 0, 70), dir = V(0, 0, -1), speed = 40, count = 24, vol = 0.05, cone = 0.5, seed = 5000 + k, owner = a })
		Wait(0.5)
	end
	Wait(3)
	Client("lookcount", { name = "C1 A's blood, 240 drops", ents = { a, b } })
	Shot("lc_a_one")
	-- (B's blood beside it: A's stains stay)
	for k = 1, 4 do
		Client("spray", { pos = q + V(60, 0, 70), dir = V(0, 0, -1), speed = 40, count = 24, vol = 0.05, cone = 0.5, seed = 5100 + k, owner = b })
		Wait(0.5)
	end
	Wait(3)
	Client("lookcount", { name = "C2 then B's blood, 96 drops", ents = { a, b } })
	Shot("lc_b_two")
	-- (A's stains become B's, as when a body becomes a corpse: B is over its limit only when more comes)
	Client("lookmove", { from = a, to = b })
	Wait(0.2)
	Client("lookcount", { name = "C3 A's stains handed to B", ents = { a, b } })
	Client("spray", { pos = q + V(60, 0, 70), dir = V(0, 0, -1), speed = 40, count = 6, vol = 0.05, cone = 0.5, seed = 5200, owner = b })
	Wait(3)
	Client("lookcount", { name = "C4 six more drops of B's", ents = { a, b } })
	Cvar("abl_max_ground_stains_per_body", 200)

	-- decals on one body: more drops than it may keep spots of
	Cvar("abl_body_catch", 0)
	Cvar("abl_max_body_decals", 6)
	local rag = Fake(a)
	if IsValid(rag) then
		Wait(0.8)
		ABL.DevPose(rag, "back", false)
		Wait(2)
		local c = ABL.DevHitboxCenter(rag, "chest") or rag:WorldSpaceCenter()
		View(c + V(26, 20, 34), c)
		for k = 1, 16 do
			c = ABL.DevHitboxCenter(rag, "chest") or c
			Client("spray", { pos = c + V(0, 0, 36), dir = V(0, 0, -1), speed = 120, count = 5, vol = 0.15, cone = 0.12, seed = 5300 + k })
			Wait(0.25)
		end
		Wait(1)
		Client("lookcount", { name = "C5 80 drops on a lying body, six decals allowed", ents = { rag } })
		Shot("lc_c_body")
	end
	Cvar("abl_max_body_decals", 12)
	Cvar("abl_body_catch", 1)
end)

-- Does a decal of the engine show on the map's own floor? Five marks in a row, from above, a
-- second after they were made and again later (the wet overlay of the fifth has gone by then
-- with the drying set short): the engine's own decal by name, one of ours through util.DecalEx,
-- a turned variant of it, one through ABL.Stains.Place without an overlay, one with.
ST.Add("look_decal", function()
	local q = FindSpot({ open = 200, outdoor = true })
	if not q then Log("look_decal: no spot") return end
	Client("clear", {})
	RunConsoleCommand("abl_drying_scale", "0.1")
	Wait(0.8)
	View(q + V(0, -60, 150), q)
	Wait(0.6)
	Shot("ld_a_before")
	Client("lookprobe", { name = "floor", pos = q, dir = V(1, 0, 0) })
	Wait(1)
	Shot("ld_b_1s")
	Wait(7)
	Shot("ld_c_8s")
	RunConsoleCommand("abl_drying_scale", "1")
	Wait(0.3)
end)

-- Why a decal of ours does not show on the map (look_decal: only the engine's own did): seven
-- marks, each one thing different from the way ABL.Stains.Place lays one (client: lookprobe2),
-- from 150 units and from 45, and once more with the engine's cull for small decals off.
ST.Add("look_decal2", function()
	local q = FindSpot({ open = 200, outdoor = true })
	if not q then Log("look_decal2: no spot") return end
	Client("clear", {})
	Wait(0.8)
	View(q + V(0, -60, 150), q)
	Wait(0.6)
	Client("lookprobe2", { name = "floor", pos = q, dir = V(1, 0, 0) })
	Wait(1)
	Shot("ld2_a_far")
	View(q + V(0, -16, 46), q)
	Wait(0.6) Shot("ld2_b_near_middle")
	View(q + V(-52, -16, 46), q + V(-52, 0, 0))
	Wait(0.6) Shot("ld2_c_near_left")
	View(q + V(52, -16, 46), q + V(52, 0, 0))
	Wait(0.6) Shot("ld2_d_near_right")
	Cvar("r_decal_cullsize", 0)
	View(q + V(0, -60, 150), q)
	Wait(0.8) Shot("ld2_e_far_no_cull")
	Cvar("r_decal_cullsize", 5)
end)
