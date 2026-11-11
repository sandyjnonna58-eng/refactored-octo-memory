-- Scenes of blood that gathers (phase 18, 2026-10-14; developer tool, only with the test harness, see
-- sv_selftest.lua; client half cl_acctest.lua, measurement cl_accum.lua). They run only when asked
-- for by name. The phase's test sequence: A a dry place, B blood reaching it, C what gathers there
-- over successive times from one place, D blood that comes in and goes on at once, E the source
-- stopping, F the body turned, laid down and got up, G drops landing in a pool, H a long bleed; and
-- whether all of it can be seen from the distances one plays at.
--
--   acc_lying      a body on its back bleeds from the chest for 100 s and stops: from one place above
--                  it and from three fixed cameras on where its blood gathers (near, 170 and 340 units
--                  away), every 5 to 10 s; the developer's view at 30 and 90 s; what each region holds,
--                  gains and loses at every picture; checks.
--   acc_lying_was  the same with everything of phase 18 switched back to how it was (the pool spreads
--                  under the body, blood routed by the governor and by the view, the film drawn as the
--                  governor says, waves on a clock, one rim for every depth, every cell painted again).
--   acc_stand      a body that stands bleeds into a pool at its feet (D, G), is laid down, turned on its
--                  side and got up again while it bleeds (F).
--   acc_far        a body on its back bleeds and is watched only from 220 and 400 units away; the camera
--                  looks away for 15 s and back, once as it was and once as it is now.
--   acc_long       a body on its back bleeds for 300 s (H): numbers every 30 s, pictures every 60 s.
--   acc_footage    video from the game's own recorder of a body on its back bleeding: 12 s as it
--                  happens, then a time lapse of 100 s, then 8 s after the wound closed.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

local MODEL = "models/zcity/m/male_06.mdl"
local WHITE = "models/humans/male/group01/sweater"

local function Hold(bot, seconds)
	local name = "ABL_AccHold" .. bot:EntIndex()
	local untilT = CurTime() + seconds
	local values = {}
	timer.Create(name, 0.3, 0, function()
		if not IsValid(bot) or not istable(bot.organism) or CurTime() > untilT then timer.Remove(name) return end
		local w = bot.organism.wounds
		if not istable(w) then return end
		for i, e in ipairs(w) do
			if not values[i] then values[i] = e[1] end
			e[1] = values[i]
		end
		bot.organism.owner:SetNetVar("wounds", w)
	end)
end
local function Release(bot) timer.Remove("ABL_AccHold" .. bot:EntIndex()) end

local function Bot(p, yaw, o)
	o = o or {}
	local bot = NewBot()
	Place(bot, p, yaw or 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel(o.model or MODEL)
	Wait(0.3)
	bot:SetNetVar("Accessories", o.worn or {})
	for i, m in ipairs(bot:GetMaterials() or {}) do
		if string.find(string.lower(m), "players_sheet", 1, true) then
			bot:SetSubMaterial(i - 1, o.dress or WHITE)
			break
		end
	end
	return bot
end

local function Wound(bot, w)
	local ok, err = ABL.DevAddWound(bot, w.bone or "chest", w.amount or 10, false, w.side or 3, w.f1 or 0.55, w.f2 or 0.5)
	Log("  wound on %s of %s, amount %.1f: %s %s", w.bone or "chest", bot:Nick(), w.amount or 10, tostring(ok), tostring(err or ""))
end

local function At(t0, tt)
	local w = t0 + tt - CurTime()
	if w > 0 then Wait(w) end
end

local function Stats(name)
	Client("accstats", { name = name })
	Wait(0.1)
end

-- A bot laid on its back. Returns the bot, its ragdoll, where its chest is, and the way its body lies
-- (from the pelvis to the head) and across it.
local function OnItsBack(p, yaw, o)
	local bot = Bot(p, yaw, o)
	View(p + Vector(90, 0, 60), p + Vector(0, 0, 30))
	Wait(3.5)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(bot)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	Wait(2.5)
	local chest, along = p + Vector(0, 0, 6), Vector(1, 0, 0)
	if IsValid(rag) then
		local function B(name)
			local b = rag:LookupBone(name)
			return b and rag:GetBonePosition(b)
		end
		local c, head, pelvis = B("ValveBiped.Bip01_Spine2"), B("ValveBiped.Bip01_Head1"), B("ValveBiped.Bip01_Pelvis")
		if c then chest = c end
		if head and pelvis then
			along = head - pelvis
			along.z = 0
			if along:LengthSqr() > 1 then along:Normalize() else along = Vector(1, 0, 0) end
		end
	end
	local across = along:Cross(Vector(0, 0, 1))
	Log("  on its back: chest at %s, the body lies along %s", tostring(chest), tostring(along))
	return bot, rag, chest, along, across
end

-- The look of everything phase 18 changed: as it was (was = true) or as it is.
local NOW = {
	cvars = { abl_pool_body = "1", abl_flow_by_distance = "1", abl_film_full_near = "1" },
	k = { rippleWith = { 1.3, 1.8 }, rimGrow = 0.35, paintSkip = 1, liquidPasses = 2 },
}
local WAS = {
	cvars = { abl_pool_body = "0", abl_flow_by_distance = "0", abl_film_full_near = "0" },
	k = { rippleWith = false, rimGrow = 0, paintSkip = 0, liquidPasses = 1 },
	-- (the pools' colours before phase 18)
	pool = { wetFresh = { rim = { 108, 15, 18 }, body = { 80, 6, 11 } }, thin = { rim = { 116, 18, 21 }, body = { 92, 9, 13 } }, wetDeep = { 58, 3, 7 } },
}
local function Mode(was)
	local m = was and WAS or NOW
	for name, v in pairs(m.cvars) do Client("cvar", { name = name, value = v }) end
	Client("filmlook", { name = was and "phase 18 off: as it was" or "phase 18 on", k = m.k })
	Client("poollook", { name = was and "pools as they were" or "pools as they are", reset = true, palette = m.pool })
	Wait(0.5)
	Log("  mode: %s", was and "as it was before phase 18" or "phase 18")
end

------------------------------------------------------------------------------------------
-- acc_lying / acc_lying_was
------------------------------------------------------------------------------------------
local function Lying(tag, was)
	Mode(was)
	local p = FindSpot({ open = 220, outdoor = true })
	local bot, rag, chest, along, across = OnItsBack(p, 0)
	Client("acctrack", { on = true })
	-- one place above the body that shows it whole and the floor round it, from the side the sun is on
	local ov = chest + across * 34 + along * -8 + Vector(0, 0, 78)
	View(ov, chest + Vector(0, 0, -4))
	Wait(0.6)
	Shot(tag .. "_00_dry")
	Stats(tag .. "_dry")
	Wound(bot, { amount = 12 })
	Hold(bot, 130)
	local t0 = CurTime()
	-- the first seconds: where the blood comes out and where it goes first (A, B)
	for _, tt in ipairs({ 1, 3, 6, 9 }) do
		At(t0, tt)
		Shot(string.format("%s_ov_%03ds", tag, tt))
	end
	Stats(tag .. "_009")
	-- three fixed cameras on where its blood gathers, set once (C: the same place from the same eye)
	At(t0, 12)
	local e = rag and IsValid(rag) and rag:EntIndex() or bot:EntIndex()
	Client("acccam", { ent = bot:EntIndex(), name = "near", dist = 52, elev = 34, fov = 60 })
	Client("acccam", { ent = bot:EntIndex(), name = "mid", dist = 170, elev = 30, fov = 60 })
	Client("acccam", { ent = bot:EntIndex(), name = "far", dist = 340, elev = 24, fov = 60 })
	Wait(0.2)
	local function Round(tt, far)
		Client("acccam", { use = "near" }) Wait(0.35) Shot(string.format("%s_near_%03ds", tag, tt))
		Client("acccam", { use = "mid" }) Wait(0.35) Shot(string.format("%s_mid_%03ds", tag, tt))
		if far then Client("acccam", { use = "far" }) Wait(0.35) Shot(string.format("%s_far_%03ds", tag, tt)) end
		Client("view", { pos = ov, ang = (chest + Vector(0, 0, -4) - ov):Angle() }) Wait(0.35) Shot(string.format("%s_ov_%03ds", tag, tt))
		Stats(string.format("%s_%03d", tag, tt))
	end
	for _, tt in ipairs({ 14, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110 }) do
		At(t0, tt)
		Round(tt, tt == 30 or tt == 60 or tt == 110)
		if tt == 30 or tt == 90 then
			-- the developer's view of the same moment
			Client("accview", { mode = 2 })
			Client("acccam", { use = "near" }) Wait(0.5) Shot(string.format("%s_near_%03ds_dev", tag, tt))
			Client("view", { pos = ov, ang = (chest + Vector(0, 0, -4) - ov):Angle() }) Wait(0.4) Shot(string.format("%s_ov_%03ds_dev", tag, tt))
			Client("accview", { mode = 0 })
			Wait(0.2)
		end
	end
	local ent = bot:EntIndex()
	Client("acccheck", { ent = ent, kind = "grow", from = tag .. "_020", to = tag .. "_060", k = 0.25, minArea = 4 })
	Client("acccheck", { ent = ent, kind = "grow", from = tag .. "_060", to = tag .. "_110", k = 0.1, minArea = 2 })
	Client("acccheck", { ent = ent, kind = "beside", to = tag .. "_110" })
	-- the source stops (E): nothing more comes, what is there stays
	Release(bot)
	ABL.DevHeal(bot)
	Log("  %s: the wound closed", tag)
	local t1 = CurTime()
	for _, tt in ipairs({ 5, 15, 30 }) do
		At(t1, tt)
		Round(tt + 200, tt == 30)
	end
	Client("acccheck", { ent = ent, kind = "still", from = tag .. "_215", to = tag .. "_230", most = 0.4 })
	Client("acccheck", { ent = ent, kind = "film", from = tag .. "_110", to = tag .. "_230", k = 0.05 })
	Client("filmstats", { name = tag .. "_end" })
	Client("stats", { name = tag })
	Wait(0.3)
	Client("acctrack", { on = false })
	if was then Mode(false) end
end

ST.Add("acc_lying", function() Lying("al", false) end)
ST.Add("acc_lying_was", function() Lying("aw", true) end)

------------------------------------------------------------------------------------------
-- acc_look: the material (18.4), the same blood from the same places in several looks. Two bodies on
-- their backs (a white sweater, a black suit) in the sun and one that stands (its front in its own
-- shade), all bleeding into pools; for each look a picture of each from close by and from 170 units:
--   1 as it is now
--   2 the liquid standing on the body drawn darker than the stain round it (deepTint 0.7)
--   3 the liquid lit by its own surface as well (liquidPasses 2: the pass that was turned down on
--     10-12 against a stain whose relief was a texture named "error")
--   4 the pools a richer, less black red
--   5 2 and 4 together
------------------------------------------------------------------------------------------
local BLACK = "models/humans/male/group01/formal"
local POOL_RICH = {
	wetFresh = { rim = { 112, 16, 19 }, body = { 92, 9, 13 } },
	wetDeep = { 72, 6, 9 },
	thin = { rim = { 118, 19, 22 }, body = { 98, 11, 14 } },
}
ST.Add("acc_look", function()
	Mode(false)
	local p = FindSpot({ open = 260, outdoor = true })
	local a, ra = OnItsBack(p + Vector(0, -70, 0), 0)
	local b, rb = OnItsBack(p + Vector(0, 70, 0), 0, { dress = BLACK })
	local c = Bot(p + Vector(70, 0, 0), 0)
	View(p + Vector(150, 0, 80), p + Vector(0, 0, 20))
	Wait(2.5)
	c:Freeze(true)
	for _, bot in ipairs({ a, b, c }) do
		Wound(bot, { amount = 12 })
		Hold(bot, 160)
	end
	Wait(40)
	Client("acccam", { ent = a:EntIndex(), name = "a_near", dist = 50, elev = 34, fov = 60 })
	Client("acccam", { ent = a:EntIndex(), name = "a_mid", dist = 170, elev = 30, fov = 60 })
	Client("acccam", { ent = b:EntIndex(), name = "b_near", dist = 50, elev = 34, fov = 60 })
	Client("acccam", { ent = b:EntIndex(), name = "b_mid", dist = 170, elev = 30, fov = 60 })
	Wait(0.3)
	Stats("ak_begin")
	local K = ABL.Config.Film
	local base = { deepTint = 1.0, liquidPasses = K.liquidPasses or 1 }
	local looks = {
		{ "1now", { deepTint = 1.0, liquidPasses = base.liquidPasses }, nil },
		{ "2deep", { deepTint = 0.7, liquidPasses = base.liquidPasses }, nil },
		{ "3lit", { deepTint = 1.0, liquidPasses = 2 }, nil },
		{ "4pool", { deepTint = 1.0, liquidPasses = base.liquidPasses }, POOL_RICH },
		{ "5both", { deepTint = 0.7, liquidPasses = base.liquidPasses }, POOL_RICH },
	}
	for _, lk in ipairs(looks) do
		local tag = lk[1]
		Client("poollook", { name = tag, reset = true, palette = lk[3] })
		Client("filmlook", { name = tag, k = lk[2] })
		Wait(2.2)
		for _, v in ipairs({ "a_near", "a_mid", "b_near", "b_mid" }) do
			Client("acccam", { use = v }) Wait(0.4) Shot(string.format("ak_%s_%s", tag, v))
		end
		Client("filmcam", { ent = c:EntIndex(), min = 34, max = 80, pad = 10 })
		Wait(0.4)
		Shot(string.format("ak_%s_c_shade", tag))
	end
	Client("poollook", { name = "as it was", reset = true })
	Client("filmlook", { name = "as it was", k = base })
	Stats("ak_end")
	for _, bot in ipairs({ a, b, c }) do
		Release(bot)
		ABL.DevHeal(bot)
	end
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- acc_stand: D, G and F
------------------------------------------------------------------------------------------
ST.Add("acc_stand", function()
	Mode(false)
	local p = FindSpot({ open = 200, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(70, -40, 50), p + Vector(0, 0, 36))
	Wait(3.5)
	bot:Freeze(true)
	Client("acctrack", { on = true })
	Wound(bot, { amount = 12 })
	Hold(bot, 120)
	local t0 = CurTime()
	local feet = p + Vector(0, 0, 1)
	-- the body from where its blood faces, and the floor at its feet from one fixed place
	local fv = p + Vector(46, -30, 40)
	for _, tt in ipairs({ 6, 15, 25, 40, 55 }) do
		At(t0, tt)
		Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
		Wait(0.35)
		Shot(string.format("as_body_%03ds", tt))
		Client("view", { pos = fv, ang = (feet - fv):Angle() })
		Wait(0.35)
		Shot(string.format("as_feet_%03ds", tt))
		Stats(string.format("as_%03d", tt))
	end
	Client("acccheck", { ent = bot:EntIndex(), kind = "grow", from = "as_015", to = "as_055", k = 0.2, minArea = 2 })
	-- F: laid down while it bleeds, turned on its side, got up again
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(bot)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	Wait(4)
	Client("filmcam", { ent = bot:EntIndex(), min = 30, max = 70, pad = 10 })
	Wait(0.35)
	Shot("as_f1_back")
	Stats("as_f1")
	Client("acccheck", { ent = bot:EntIndex(), kind = "film", from = "as_055", to = "as_f1", k = 0.3 })
	if IsValid(rag) then ABL.DevPose(rag, "side", false) end
	Wait(5)
	Client("filmcam", { ent = bot:EntIndex(), min = 30, max = 70, pad = 10 })
	Wait(0.35)
	Shot("as_f2_side")
	Stats("as_f2")
	Client("acccheck", { ent = bot:EntIndex(), kind = "film", from = "as_f1", to = "as_f2", k = 0.3 })
	if hg and hg.FakeUp then hg.FakeUp(bot, true, true) end
	Wait(1.5)
	bot:Freeze(true)
	Wait(4)
	Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
	Wait(0.35)
	Shot("as_f3_up")
	Stats("as_f3")
	Client("acccheck", { ent = bot:EntIndex(), kind = "film", from = "as_f2", to = "as_f3", k = 0.3 })
	Release(bot)
	ABL.DevHeal(bot)
	Wait(8)
	Client("view", { pos = fv, ang = (feet - fv):Angle() })
	Wait(0.35)
	Shot("as_closed_feet")
	Stats("as_closed")
	Client("acctrack", { on = false })
	Client("stats", { name = "acc_stand" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- acc_far: from the distances one plays at; a look away and back, as it was and as it is
------------------------------------------------------------------------------------------
ST.Add("acc_far", function()
	Mode(false)
	local p = FindSpot({ open = 260, outdoor = true })
	local bot, rag, chest, along, across = OnItsBack(p, 0)
	Client("acctrack", { on = true })
	Wound(bot, { amount = 12 })
	Hold(bot, 120)
	local t0 = CurTime()
	-- (the host stays near enough for the body to be sent to it: the first view parks it)
	local e1 = chest + across * 200 + Vector(0, 0, 105)
	local e2 = chest + across * 360 + Vector(0, 0, 160)
	View(e1, chest)
	for _, tt in ipairs({ 10, 25, 40 }) do
		At(t0, tt)
		Client("view", { pos = e1, ang = (chest - e1):Angle(), fov = 60 }) Wait(0.35) Shot(string.format("af_220_%03ds", tt))
		Client("view", { pos = e2, ang = (chest - e2):Angle(), fov = 60 }) Wait(0.35) Shot(string.format("af_400_%03ds", tt))
		Stats(string.format("af_%03d", tt))
	end
	-- looking away for 15 s: as it was (blood off the wound straight to the floor while unseen) and as it is
	for i, was in ipairs({ true, false }) do
		Client("cvar", { name = "abl_flow_by_distance", value = was and "0" or "1" })
		Wait(0.3)
		Client("view", { pos = e1, ang = (chest - e1):Angle(), fov = 60 }) Wait(0.5)
		Stats(string.format("af_away%d_before", i))
		Client("view", { pos = e1, ang = (e1 - chest):Angle(), fov = 60 })
		Wait(15)
		Client("view", { pos = e1, ang = (chest - e1):Angle(), fov = 60 })
		Wait(0.1)
		Stats(string.format("af_away%d_after", i))
		Shot(string.format("af_away%d_back", i))
	end
	Client("cvar", { name = "abl_flow_by_distance", value = "1" })
	Release(bot)
	ABL.DevHeal(bot)
	Client("acctrack", { on = false })
	Client("stats", { name = "acc_far" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- acc_long: H
------------------------------------------------------------------------------------------
ST.Add("acc_long", function()
	Mode(false)
	local p = FindSpot({ open = 220, outdoor = true })
	local bot, rag, chest, along, across = OnItsBack(p, 0)
	Client("acctrack", { on = true })
	local ov = chest + across * 40 + along * -10 + Vector(0, 0, 90)
	View(ov, chest + Vector(0, 0, -4))
	Wound(bot, { amount = 9 })
	Hold(bot, 320)
	local t0 = CurTime()
	for tt = 30, 300, 30 do
		At(t0, tt)
		Stats(string.format("ag_%03d", tt))
		if tt % 60 == 0 then
			Client("view", { pos = ov, ang = (chest + Vector(0, 0, -4) - ov):Angle() })
			Wait(0.35)
			Shot(string.format("ag_ov_%03ds", tt))
			Client("filmstats", { name = string.format("ag_%03d", tt) })
			Client("stats", { name = string.format("acc_long %d", tt) })
			Wait(0.3)
		end
	end
	Client("acccheck", { ent = bot:EntIndex(), kind = "grow", from = "ag_060", to = "ag_300", k = 0.2, minArea = 4 })
	Client("acccheck", { ent = bot:EntIndex(), kind = "beside", to = "ag_300" })
	Release(bot)
	ABL.DevHeal(bot)
	Client("acctrack", { on = false })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- acc_footage: the game's own video recorder
------------------------------------------------------------------------------------------
ST.Add("acc_footage", function()
	Mode(false)
	local p = FindSpot({ open = 220, outdoor = true })
	local bot, rag, chest, along, across = OnItsBack(p, 0)
	local cam = chest + across * 38 + along * -6 + Vector(0, 0, 40)
	View(cam, chest + Vector(0, 0, -5))
	Wait(0.5)
	Wound(bot, { amount = 12 })
	Hold(bot, 140)
	local t0 = CurTime()
	-- as it happens: the first twelve seconds
	Client("record", { name = "abl_acc_realtime", secs = 12, fps = 30, w = 960, h = 540 })
	Wait(13)
	-- a time lapse: one frame every second of game time for 100 s (ten seconds of video at ten frames a second)
	Client("record", { name = "abl_acc_lapse", secs = 100, lapse = 1, fps = 10, w = 960, h = 540 })
	At(t0, 115)
	Shot("aft_115s")
	Release(bot)
	ABL.DevHeal(bot)
	Wait(1)
	-- after the wound closed: what is there stays
	Client("record", { name = "abl_acc_closed", secs = 8, fps = 30, w = 960, h = 540 })
	Wait(9)
	Shot("aft_closed")
	Wait(0.2)
end)
