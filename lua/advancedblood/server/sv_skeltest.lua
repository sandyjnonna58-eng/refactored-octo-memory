-- Skeleton probe scene (developer tool, phase 1 of the anatomical skeleton: an audit, not a
-- feature; only with the test harness, see sv_selftest.lua; runs only when asked for by name).
--
--   skel_probe   what skeleton models the game has, what the engine hands out of the stock one,
--                and that model bone-merged onto a male and a female Z-City character: standing,
--                seen as part of the world (what shows has come through the body's surface) and
--                over everything; its fit in the rest pose in numbers; the skull as a rigid mesh
--                of its own on the head bone; and the male laid down as Z-City's ragdoll.
-- The client half is cl_skeltest.lua. Nothing of the addon uses either file.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

ST.Add("skel_probe", function()
	local p = FindSpot({ open = 160, outdoor = true })
	Client("skelassets", {})
	local bots = {}
	for i, model in ipairs({ "models/zcity/m/male_06.mdl", "models/zcity/f/female_01.mdl" }) do
		local bot = NewBot()
		Place(bot, p + Vector(0, (i - 1.5) * 44, 0), 0)
		bot:SetModel(model)
		bots[i] = bot
	end
	local mid = p + Vector(0, 0, 38)
	View(mid + Vector(96, 0, 6), mid)
	Wait(3.5)
	for i, bot in ipairs(bots) do
		Log("  skel_probe: %s is %s", bot:Nick(), tostring(bot:GetModel()))
		Client("skelshow", { ent = bot:EntIndex(), mode = "depth", fit = true })
	end
	Wait(2.5)
	Shot("sk_1_depth")
	for _, bot in ipairs(bots) do Client("skelshow", { ent = bot:EntIndex(), mode = "xray" }) end
	Wait(0.4)
	Shot("sk_2_xray")
	-- from the side and from behind
	View(mid + Vector(0, 110, 6), mid)
	Wait(0.5)
	Shot("sk_3_xray_side")
	View(mid + Vector(-96, 0, 6), mid)
	Wait(0.5)
	Shot("sk_4_xray_back")
	for _, bot in ipairs(bots) do Client("skelshow", { ent = bot:EntIndex(), mode = "depth" }) end
	Wait(0.4)
	Shot("sk_5_depth_back")
	-- the skull as a rigid mesh of its own on each head bone, from close by
	local head = bots[1]:GetPos() + Vector(0, 0, 66)
	View(head + Vector(26, 8, 2), head)
	for _, bot in ipairs(bots) do Client("skelshow", { ent = bot:EntIndex(), mode = "head" }) end
	Wait(0.8)
	Shot("sk_6_skull_piece_male")
	Client("skelshow", { ent = bots[1]:EntIndex(), mode = "xray" })
	Wait(0.4)
	Shot("sk_7_skull_merged_male")
	-- the male laid down as Z-City's ragdoll: the skeleton goes to the ragdoll's bones
	if hg and hg.Fake then hg.Fake(bots[1]) end
	Wait(0.6)
	local rag = ABL.DevRagdollOf(bots[1])
	if IsValid(rag) then
		ABL.DevPose(rag, "back", false)
		Client("skelmove", { from = bots[1]:EntIndex(), to = rag:EntIndex() })
		Wait(2.2)
		local c = rag:WorldSpaceCenter()
		View(c + Vector(40, 26, 62), c)
		Wait(0.5)
		Shot("sk_8_ragdoll_xray")
		Client("skelshow", { ent = rag:EntIndex(), mode = "depth" })
		Wait(0.4)
		Shot("sk_9_ragdoll_depth")
	else
		Log("  skel_probe: no ragdoll")
	end
	Client("skelclear", {})
	Wait(0.2)
end)
