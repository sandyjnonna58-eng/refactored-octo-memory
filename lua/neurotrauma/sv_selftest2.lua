-- Test scenarios of the second pass (anatomy, vessels, language, limbs, hands, status and
-- midazolam, circulation, networking, many injured). Same harness as sv_selftest.lua: they exist
-- only with garrysmod/data/abl_selftest.txt and run when asked for by name. See docs/TESTING.md.

local NT = NeuroTrauma
if not (istable(ABL) and istable(ABL.SelfTest)) then return end
local S = ABL.SelfTest
local Log, Wait = S.Log, S.Wait
local C, Z, E, A = NT.Config, NT.ZC, NT.E, NT.Atlas
local AN, VA, BR, D = NT.Anatomy, NT.Vascular, NT.Brain, NT.Debug
local V = Vector

util.AddNetworkString("nt_test3")
local function Client(cmd, tbl)
	net.Start("nt_test3")
	net.WriteString(cmd)
	net.WriteTable(tbl or {})
	net.Send(S.Host())
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

local function Add(name, fn)
	S.Add(name, function()
		NT.Brain.paused = nil
		if NT.Trauma then NT.Trauma.silent = nil end
		pass, fail = 0, 0
		RunConsoleCommand("neuro_dominance", "left")
		Wait(0.1)
		fn()
		RunConsoleCommand("neuro_dominance", "auto")
	end)
end

local function Fresh(bot, p)
	if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end
	if IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) Wait(1.3) end
	bot:Spawn()
	S.Place(bot, p, 0)
	if istable(bot.organism) then bot.organism.godmode = true end
	Wait(1.2)
end

-- the record of a bot after its next step
local function Rec(bot, wait)
	Wait(wait or 0.35)
	local org = bot.organism
	return istable(org) and NT.Get(org) or nil
end

local function Limbs(st)
	return string.format("arm L %.2f R %.2f hand L %.2f R %.2f leg L %.2f R %.2f face L %.2f R %.2f", st.armL, st.armR, st.handL, st.handR, st.legL, st.legR, st.faceL, st.faceR)
end


-- The camera on a part of a body. The client knows where the drawn bones are (the server does not
-- know the client's own layers): it works out the place and sends it back.
net.Receive("nt_test3", function(_, ply)
	if ply ~= S.Host() then return end
	local pos, look = net.ReadVector(), net.ReadVector()
	S.View(pos, look)
end)
local function ViewPart(ent, part, lying)
	if not IsValid(ent) then return end
	Client("viewpart", { ent = ent, part = part, lying = lying })
	Wait(0.25)
end

------------------------------------------------------------------------------------------
-- Anatomy: a lesion in a place costs the functions of that place
------------------------------------------------------------------------------------------
Add("neuro_anatomy", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	-- (a character that loses consciousness or a leg falls, and the fall is an injury of its own:
	-- kept out of these measurements, which are of the lesion that was set)
	NT.Injury.muted = true
	local function Case(name, fn)
		Fresh(bot, p)
		Log("-- %s", name)
		fn()
		local st = Rec(bot, 1.6)
		if not st then Log("    no record") return nil end
		local ch = AN.Channels(st)
		Log("    %s | %s | coordination L %.2f R %.2f balance %.2f", tostring(st.label), Limbs(st), st.coordL, st.coordR, st.balance)
		Log("    speech out %.2f understanding %.2f repeating %.2f reading %.2f writing %.2f articulation %.2f | memory %.2f attention %.2f executive %.2f drive %.2f",
			ch.language_production, ch.language_comprehension, ch.language_repetition, ch.reading, ch.writing, ch.articulation, ch.memory, ch.attention, ch.executive, ch.drive)
		Log("    sight left up %.2f down %.2f right up %.2f down %.2f | hearing %.2f | feeling L %.2f R %.2f | neglect L %.2f R %.2f | consciousness %.2f (%s) breathing %.2f",
			ch.vision_upperL, ch.vision_lowerL, ch.vision_upperR, ch.vision_lowerR, ch.hearing, ch.sensationL, ch.sensationR, ch.neglectL, ch.neglectR, st.consciousness, tostring(st.lossWhy), st.resp)
		Log("    damaged: %s", AN.Describe(st, 6))
		Log("    %s", VA.Describe(st))
		return st, ch
	end
	local st, ch

	-- motor cortex, zone by zone and side by side
	st = Case("left hand zone of the motor cortex destroyed", function() NT.DamageRegion(bot, "L_precentral_hand", 1) end)
	Check("right hand weak, the left one not", st.handR < 0.5 and st.handL > 0.95, string.format("%.2f / %.2f", st.handR, st.handL))
	Check("right leg spared", st.legR > 0.95)
	st = Case("right hand zone destroyed", function() NT.DamageRegion(bot, "R_precentral_hand", 1) end)
	Check("left hand weak, the right one not", st.handL < 0.5 and st.handR > 0.95)
	st = Case("left paracentral lobule destroyed", function() NT.DamageRegion(bot, "L_paracentral", 1) end)
	Check("right leg weak, right hand not", st.legR < 0.5 and st.handR > 0.9, string.format("leg %.2f hand %.2f", st.legR, st.handR))

	Log("-- partial lesions of the left hand zone: 10, 25, 50, 75, 90, 100 %%")
	local last = 1.01
	local mono = true
	for _, pct in ipairs({ 10, 25, 50, 75, 90, 100 }) do
		Fresh(bot, p)
		NT.DamageRegion(bot, "L_precentral_hand", pct / 100)
		local s2 = Rec(bot, 1.4)
		Log("    %3d %%: right hand %.2f", pct, s2 and s2.handR or -1)
		if s2 then
			if s2.handR > last + 0.001 then mono = false end
			last = s2.handR
		end
	end
	Check("the hand gets weaker with every step, and a small lesion is absorbed", mono)

	-- the narrow passage: the internal capsule
	st = Case("left internal capsule, posterior limb, destroyed", function() NT.DamageRegion(bot, "L_ic_post", 1) end)
	Check("right arm, hand and leg all gone, face spared, left side whole", st.armR < 0.1 and st.handR < 0.1 and st.legR < 0.1 and st.faceR > 0.9 and st.motorL > 0.95)

	-- vessels
	st, ch = Case("left anterior cerebral artery shut beyond the communicating artery (A2)", function() NT.DamageVessel(bot, "L_aca_a2", 0) end)
	Check("right leg far weaker than right hand", st.legR < 0.4 and st.handR > st.legR + 0.3, string.format("leg %.2f hand %.2f", st.legR, st.handR))
	Check("drive and the start of speech suffer", ch.drive < 0.9 or ch.language_production < 0.9, string.format("drive %.2f speech %.2f", ch.drive, ch.language_production))
	st, ch = Case("left middle cerebral artery, upper division, shut", function() NT.DamageVessel(bot, "L_mca_sup", 0) end)
	Check("right face and hand weak, leg spared", st.faceR < 0.6 and st.handR < 0.6 and st.legR > 0.8, string.format("face %.2f hand %.2f leg %.2f", st.faceR, st.handR, st.legR))
	Check("speech is lost more than understanding", ch.language_production < ch.language_comprehension - 0.2, string.format("%.2f / %.2f", ch.language_production, ch.language_comprehension))
	-- (How well the surface collaterals of a character hold is drawn by chance, once per life, and
	-- decides how much of this territory is lost: with good ones understanding stood at 0.50 and
	-- 0.57 and the check below missed, runs m24 and p25a. Here they are set to their poorest.)
	st, ch = Case("left middle cerebral artery, lower division, shut (poor collaterals)", function()
		local s = NT.Brain.Ensure(bot.organism)
		s.an.lepto = C.Vascular.leptoQuality[1]
		s.an.flowDirty = true
		NT.DamageVessel(bot, "L_mca_inf", 0)
	end)
	Check("understanding is lost, the limbs are not", ch.language_comprehension < 0.5 and st.handR > 0.8 and st.legR > 0.9, string.format("understanding %.2f hand %.2f", ch.language_comprehension, st.handR))
	st, ch = Case("left middle cerebral artery shut at its stem (M1)", function() NT.DamageVessel(bot, "L_mca_m1", 0) end)
	Check("right side paralysed through the capsule, leg included", st.armR < 0.2 and st.legR < 0.4)
	Check("language gone", ch.language_production < 0.3 and ch.language_comprehension < 0.5)
	st, ch = Case("right middle cerebral artery shut at its stem", function() NT.DamageVessel(bot, "R_mca_m1", 0) end)
	Check("left side paralysed, language kept, the left half of space neglected", st.armL < 0.2 and ch.language_production > 0.9 and ch.neglectL > 0.4, string.format("neglect %.2f", ch.neglectL))
	st, ch = Case("left posterior cerebral artery shut beyond the communicating artery (P2)", function() NT.DamageVessel(bot, "L_pca_p2", 0) end)
	Check("the right half of the field is lost, the left kept", ch.vision_upperR < 0.3 and ch.vision_lowerR < 0.3 and ch.vision_upperL > 0.95)
	Check("limbs keep their strength", st.armR > 0.8 and st.legR > 0.8)
	st, ch = Case("right posterior cerebral artery, calcarine branch only", function() NT.DamageVessel(bot, "R_pca_calcarine", 0) end)
	Check("the left half of the field is lost", ch.vision_upperL < 0.5 and ch.vision_lowerL < 0.5)
	st, ch = Case("right cerebellar arteries shut (upper and lower)", function() NT.DamageVessel(bot, "R_sca", 0) NT.DamageVessel(bot, "R_pica", 0) end)
	Check("the right side is clumsy, the left is not; strength is kept", st.coordR < 0.5 and st.coordL > 0.9 and st.armR > 0.9, string.format("coordination R %.2f L %.2f", st.coordR, st.coordL))
	st, ch = Case("basilar artery shut on both sides", function() NT.DamageVessel(bot, "L_basilar_half", 0) NT.DamageVessel(bot, "R_basilar_half", 0) end)
	Check("unconscious", st.consciousness < 0.1, string.format("%.2f, %s", st.consciousness, tostring(st.lossWhy)))
	st, ch = Case("base of the pons destroyed on both sides, tegmentum spared", function() NT.DamageRegion(bot, "L_pons_base", 1) NT.DamageRegion(bot, "R_pons_base", 1) end)
	Check("all four limbs gone, consciousness kept", st.armL < 0.1 and st.armR < 0.1 and st.legL < 0.1 and st.legR < 0.1 and st.consciousness > 0.9)
	st, ch = Case("pontine tegmentum of one side destroyed", function() NT.DamageRegion(bot, "L_pons_teg", 1) end)
	Check("drowsy, not in a coma", st.consciousness > 0.2 and st.consciousness < 0.9, string.format("%.2f", st.consciousness))
	st, ch = Case("pontine tegmentum of both sides destroyed", function() NT.DamageRegion(bot, "L_pons_teg", 1) NT.DamageRegion(bot, "R_pons_teg", 1) end)
	Check("in a coma", st.consciousness < 0.05 and st.state == E.State.COMATOSE)
	st, ch = Case("paramedian thalamus of both sides", function() NT.DamageVessel(bot, "L_pca_perf", 0) NT.DamageVessel(bot, "R_pca_perf", 0) end)
	Check("consciousness lost through the thalamus; no posturing, breathing kept", st.consciousness < 0.6 and st.lossWhy == "thalamus" and st.posture < 0.1 and st.resp > 0.8,
		string.format("%.2f, %s, posture %.2f, breathing %.2f", st.consciousness, tostring(st.lossWhy), st.posture, st.resp))
	st, ch = Case("midbrain tegmentum of both sides destroyed", function() NT.DamageRegion(bot, "L_midbrain_teg", 1) NT.DamageRegion(bot, "R_midbrain_teg", 1) end)
	Check("in a coma, breathing kept", st.consciousness < 0.05 and st.lossWhy == "stem" and st.resp > 0.8, string.format("%.2f, %s, breathing %.2f", st.consciousness, tostring(st.lossWhy), st.resp))
	st, ch = Case("medullary tegmentum of both sides destroyed", function() NT.DamageRegion(bot, "L_medulla_teg", 1) NT.DamageRegion(bot, "R_medulla_teg", 1) end)
	Check("breathing stops", st.resp < 0.05, string.format("breathing %.2f", st.resp))

	-- disconnections: the regions at both ends are whole
	st, ch = Case("left optic radiation, temporal loop, cut", function() NT.DamageRegion(bot, "L_optic_meyer", 1) end)
	Check("the upper right quarter of the field is lost, the lower kept", ch.vision_upperR < 0.1 and ch.vision_lowerR > 0.95 and ch.vision_upperL > 0.95, string.format("up %.2f down %.2f", ch.vision_upperR, ch.vision_lowerR))
	st, ch = Case("right superior cerebellar peduncle cut", function() NT.DamageRegion(bot, "R_scp", 1) end)
	Check("the right side is clumsy, the cerebellum itself whole", st.coordR < 0.6 and st.coordL > 0.9 and st.armR > 0.95, string.format("coordination R %.2f L %.2f", st.coordR, st.coordL))
	st, ch = Case("left medullary pyramid cut", function() NT.DamageRegion(bot, "L_pyramid", 1) end)
	Check("right arm and leg gone, the face spared", st.armR < 0.1 and st.legR < 0.1 and st.faceR > 0.95 and st.motorL > 0.95, string.format("arm %.2f leg %.2f face %.2f", st.armR, st.legR, st.faceR))

	-- language, region by region, and the other hemisphere
	st, ch = Case("left inferior frontal gyrus (opercular and triangular parts)", function() NT.DamageRegion(bot, "L_parsopercularis", 1) NT.DamageRegion(bot, "L_parstriangularis", 1) end)
	Check("speech reduced, understanding intact", ch.language_production < 0.6 and ch.language_comprehension > 0.95)
	st, ch = Case("rear of the left superior temporal gyrus", function() NT.DamageRegion(bot, "L_superiortemporal_post", 1) NT.DamageRegion(bot, "L_bankssts", 1) end)
	Check("understanding reduced more than the frontal part of speech", ch.language_comprehension < 0.6)
	st, ch = Case("left arcuate fasciculus cut", function() NT.DamageRegion(bot, "L_arcuate", 1) end)
	Check("repeating lost, understanding intact", ch.language_repetition < 0.2 and ch.language_comprehension > 0.95)
	st, ch = Case("the same frontal lesion on the right", function() NT.DamageRegion(bot, "R_parsopercularis", 1) NT.DamageRegion(bot, "R_parstriangularis", 1) end)
	Check("no loss of language", ch.language_production > 0.95)
	RunConsoleCommand("neuro_dominance", "right")
	Wait(0.2)
	st, ch = Case("the same frontal lesion on the right, in a brain whose right hemisphere leads for language", function() NT.DamageRegion(bot, "R_parsopercularis", 1) NT.DamageRegion(bot, "R_parstriangularis", 1) end)
	Check("speech reduced", ch.language_production < 0.6)
	RunConsoleCommand("neuro_dominance", "left")
	Wait(0.2)

	-- memory needs both sides
	st, ch = Case("left hippocampus", function() NT.DamageRegion(bot, "L_hippocampus", 1) end)
	local one = ch.memory
	st, ch = Case("both hippocampi", function() NT.DamageRegion(bot, "L_hippocampus", 1) NT.DamageRegion(bot, "R_hippocampus", 1) end)
	Check("one side costs little, both a lot", one > 0.8 and ch.memory < 0.6, string.format("%.2f / %.2f", one, ch.memory))

	-- combined lesions
	st, ch = Case("left hand zone and right cerebellum together", function() NT.DamageRegion(bot, "L_precentral_hand", 1) NT.DamageRegion(bot, "R_cerebellum_sup", 1) NT.DamageRegion(bot, "R_cerebellum_inf", 1) end)
	Check("the right hand is both weak and clumsy", st.handR < 0.5 and st.coordR < 0.5)

	-- collaterals: the same shut carotid in a person with good and with poor communicating arteries
	local function Carotid(caps, name)
		Fresh(bot, p)
		NT.DamageRegion(bot, "L_frontalpole", 0.001)
		local s2 = Rec(bot, 0.3)
		for i, w in pairs(s2.an.wcap) do for k in pairs(w) do if w[k] < 1 then w[k] = caps end end end
		s2.an.lepto = caps
		NT.DamageVessel(bot, "L_ica", 0)
		s2 = Rec(bot, 1.6)
		Log("    %s: %s | %s", name, Limbs(s2), VA.Describe(s2))
		return s2
	end
	Log("-- left internal carotid shut")
	local good = Carotid(0.95, "good collaterals")
	local poor = Carotid(0.05, "poor collaterals")
	Check("with good collaterals the hemisphere is kept, with poor ones it is lost", good.handR > 0.9 and poor.handR < 0.3, string.format("%.2f / %.2f", good.handR, poor.handR))

	-- Z-City's single brain number: a lesion of one place does not raise it
	st = Case("left hand zone destroyed: what is written to Z-City", function() NT.DamageRegion(bot, "L_precentral_hand", 1) end)
	Check("Z-City's brain damage stays at zero", (tonumber(bot.organism.brain) or 0) < 0.01, string.format("%.3f", tonumber(bot.organism.brain) or -1))
	NT.Injury.muted = nil
	Fresh(bot, p)
	Tally("neuro_anatomy")
end)

------------------------------------------------------------------------------------------
-- Language: what comes out in chat, and whether the voice is heard
------------------------------------------------------------------------------------------
Add("neuro_chat", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local LG = NT.Language
	local texts = { "the quick brown fox jumps over the lazy dog near the old bridge", "help me i cannot feel my arm", "нужна помощь у меня не работает рука" }
	local function Case(name, fn)
		Fresh(bot, p)
		fn()
		local st = Rec(bot, 1.6)
		local pr = LG.Profile(st)
		Log("-- %s: non-fluent %.2f fluent %.2f conduction %.2f spelling %.2f typing %.2f confusion %.2f | speech %.2f", name, pr.nonfluent, pr.fluent, pr.conduction, pr.spelling, pr.typing, pr.confusion, pr.speech)
		for i, text in ipairs(texts) do
			local out, did = LG.Transform(st, text, 100 + i)
			Log("    '%s'", out)
		end
		return st, pr
	end
	local st, pr = Case("left hand zone destroyed (one hand)", function() NT.DamageRegion(bot, "L_precentral_hand", 1) end)
	Check("one good hand still types cleanly", pr.typing < 0.2 and pr.nonfluent < 0.05)
	st, pr = Case("both hand zones destroyed", function() NT.DamageRegion(bot, "L_precentral_hand", 1) NT.DamageRegion(bot, "R_precentral_hand", 1) end)
	Check("typing errors, language intact", pr.typing > 0.4 and pr.nonfluent < 0.05 and pr.fluent < 0.05)
	st, pr = Case("left inferior frontal gyrus", function() NT.DamageRegion(bot, "L_parsopercularis", 1) NT.DamageRegion(bot, "L_parstriangularis", 1) end)
	Check("non-fluent", pr.nonfluent > 0.3 and pr.fluent < 0.1)
	st, pr = Case("rear of the left superior temporal gyrus", function() NT.DamageRegion(bot, "L_superiortemporal_post", 1) NT.DamageRegion(bot, "L_bankssts", 1) NT.DamageRegion(bot, "L_middletemporal", 0.6) end)
	Check("fluent with wrong words", pr.fluent > 0.3)
	st, pr = Case("left arcuate fasciculus", function() NT.DamageRegion(bot, "L_arcuate", 1) end)
	Check("sounds of long words out of order", pr.conduction > 0.5)
	st, pr = Case("left middle cerebral artery, stem", function() NT.DamageVessel(bot, "L_mca_m1", 0) end)
	Check("hardly any language left", pr.nonfluent > 0.7)
	st, pr = Case("both cerebellar hemispheres", function() for _, k in ipairs({ "L_cerebellum_sup", "L_cerebellum_inf", "R_cerebellum_sup", "R_cerebellum_inf" }) do NT.DamageRegion(bot, k, 1) end end)
	Check("clumsy typing, words intact", pr.typing > 0.3 and pr.fluent < 0.05)
	st, pr = Case("diffuse injury 0.35", function() D.Set(bot, "diffuse", 0.35) end)
	Check("the thread is lost", pr.confusion > 0.1)

	-- the real path: the host speaks through Z-City's chat
	Log("-- through Z-City's chat hooks (the host speaks)")
	local host = S.Host()
	local seen = {}
	hook.Add("HG_PlayerSay", "zz_NT_Test", function(ply, txtTbl, text) seen[#seen + 1] = tostring(txtTbl[1]) end)
	local function Say(tag, text)
		seen = {}
		host:Say(text)
		Wait(0.5)
		Log("    [%s] '%s' -> '%s'", tag, text, tostring(seen[1]))
		return seen[1]
	end
	Log("    hooks taken over: %s", tostring(LG.wrapped))
	RunConsoleCommand("neuro_chat_admins", "1")
	Wait(0.2)
	local plain = Say("uninjured", texts[1])
	Check("an uninjured speaker is not changed", plain == texts[1])
	NT.DamageRegion(host, "L_parsopercularis", 1) NT.DamageRegion(host, "L_parstriangularis", 1)
	Wait(0.6)
	local out = Say("frontal lesion", texts[1])
	Check("an aphasic speaker is changed", out ~= nil and out ~= texts[1])
	local cmd = Say("frontal lesion, a command", "!help")
	Check("a command is not touched", cmd == "!help")
	RunConsoleCommand("neuro_chat_admins", "0")
	Wait(0.2)
	local adm = Say("frontal lesion, admins exempt", texts[1])
	Check("an admin passes when admins are exempt", adm == texts[1])
	-- Z-City's own rule (brain damage number) must not garble a character the model handles
	NT.Reset(host)
	NT.DamageRegion(host, "L_precentral_hand", 0.001)
	local org = host.organism
	local keep = org.brain
	org.brain = 0.2
	RunConsoleCommand("neuro_chat_admins", "1")
	Wait(0.3)
	local z = Say("Z-City brain number 0.2, no language lesion", texts[1])
	Check("Z-City's garbling is switched off for a character with a record", z == texts[1])
	-- voice
	local can = hook.Run("HG_PlayerCanHearPlayersVoice", bot, host)
	Log("    voice with Z-City brain number 0.2 and intact language: %s", tostring(can))
	Check("the voice is not cut by Z-City's rule", can ~= false)
	NT.DamageRegion(host, "L_parsopercularis", 1) NT.DamageRegion(host, "L_parstriangularis", 1) NT.DamageRegion(host, "L_insula", 1) NT.DamageRegion(host, "L_sma", 1)
	NT.DamageRegion(host, "L_precentral_face", 1) NT.DamageRegion(host, "L_rostralmiddlefrontal", 1)
	Wait(0.5)
	can = hook.Run("HG_PlayerCanHearPlayersVoice", bot, host)
	Log("    voice with speech at %.2f: %s", LG.Profile(NT.Get(org)).speech, tostring(can))
	Check("the voice is cut when speech is nearly gone", can == false)
	org.brain = keep
	NT.Reset(host)
	hook.Remove("HG_PlayerSay", "zz_NT_Test")
	RunConsoleCommand("neuro_chat_admins", "0")
	-- without a record Z-City's own rule still applies
	Fresh(bot, p)
	Tally("neuro_chat")
end)

------------------------------------------------------------------------------------------
-- Limbs against the keys: a bot that is made to walk
------------------------------------------------------------------------------------------
Add("neuro_limbs", function()
	local p = S.FindSpot({ open = 420, outdoor = true })
	local bot = S.NewBot()
	local fwd = V(1, 0, 0)
	local right = V(0, -1, 0)
	local walk
	S.Drive(bot, function(ply, cmd)
		if not walk then return end
		cmd:SetViewAngles(fwd:Angle())
		ply:SetEyeAngles(fwd:Angle())
		cmd:SetForwardMove(10000)
		local b = IN_FORWARD
		if walk.run then b = bit.bor(b, IN_SPEED) end
		if walk.jump then b = bit.bor(b, IN_JUMP) end
		cmd:SetButtons(b)
		-- (the keys are set here, after the module's own hook may have run: apply its limits to them)
		NT.ApplyControl(ply, cmd)
	end)
	local start = p - fwd * 380
	Fresh(bot, start)
	-- (one body for the whole scene: the same model, the same load, the same speeds)
	local function Walk(name, lesion, opt)
		if NT.Get(bot.organism) then NT.Reset(bot) end
		if IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) Wait(1.5) end
		bot:SetPos(start + V(0, 0, 2))
		bot:SetLocalVelocity(vector_origin)
		bot:Freeze(false)
		if lesion then lesion() end
		local st = Rec(bot, 1.5)
		local p0 = bot:GetPos()
		walk = opt or {}
		S.View(p + V(0, 300, 140), p + V(0, 0, 30))
		Wait(opt and opt.run and 1.0 or 2.0)
		local p1 = bot:GetPos()
		if opt and opt.shot then S.Shot(opt.shot) end
		local span = opt and opt.run and 1.2 or 2.0
		Wait(span)
		local p2 = bot:GetPos()
		local fake = IsValid(bot.FakeRagdoll)
		walk = nil
		local d = p2 - p0
		local run, jump, fire, aim, veer = NT.Limits(bot)
		local speed = (p2 - p1):Dot(fwd) / (span + (opt and opt.shot and 0.35 or 0))
		Log("  %-46s forward %4.0f sideways %+4.0f | forward speed %3.0f | on its feet %s | walking %s/15, may run %s jump %s fire %s aim %s, pulled %s | %s",
			name, d:Dot(fwd), -d:Dot(right), speed, tostring(not fake), st and tostring(st.moveQ) or "-",
			tostring(run), tostring(jump), tostring(fire), tostring(aim), tostring(veer), st and Limbs(st) or "no record")
		bot:Freeze(true)
		Wait(0.5)
		return d:Dot(fwd), -d:Dot(right), speed, fake
	end
	local f0, s0, v0 = Walk("uninjured, walking", nil, {})
	local f1, s1, v1 = Walk("uninjured, running", nil, { run = true })
	local f2, s2, v2 = Walk("left leg weak (right paracentral 0.55)", function() NT.DamageRegion(bot, "R_paracentral", 0.55) end, { shot = "neuro_limbs_legweak" })
	Check("slower than uninjured", v2 < v0 * 0.95, string.format("%.0f against %.0f", v2, v0))
	Check("pulled to the left", s2 > s0 + 8, string.format("%+.0f against %+.0f", s2, s0))
	local f3, s3, v3 = Walk("the same, trying to run", function() NT.DamageRegion(bot, "R_paracentral", 0.55) end, { run = true })
	Check("running is refused: no faster than its walk", v3 < v2 * 1.15 and v3 < v1 * 0.9, string.format("%.0f, its walk %.0f, an uninjured run %.0f", v3, v2, v1))
	local f4, s4, v4 = Walk("right leg weak (left paracentral 0.55)", function() NT.DamageRegion(bot, "L_paracentral", 0.55) end, {})
	Check("pulled to the right", s4 < s0 - 8, string.format("%+.0f against %+.0f", s4, s0))
	local f5, s5, v5, fake5 = Walk("left leg gone (right paracentral 1.0)", function() NT.DamageRegion(bot, "R_paracentral", 1) end, { shot = "neuro_limbs_leggone" })
	Check("a leg that does not carry takes the character down", fake5 == true)
	local f6, s6, v6 = Walk("right cerebellum gone", function() NT.DamageRegion(bot, "R_cerebellum_sup", 1) NT.DamageRegion(bot, "R_cerebellum_inf", 1) end, { shot = "neuro_limbs_ataxia" })
	Check("unsteady: slower", v6 < v0 * 0.97, string.format("%.0f against %.0f", v6, v0))
	local f7, s7, v7 = Walk("right arm and hand gone (left hand and arm zones)", function() NT.DamageRegion(bot, "L_precentral_hand", 1) NT.DamageRegion(bot, "L_precentral_arm", 1) end, { shot = "neuro_limbs_armgone" })
	local run, jump, fire, aim = NT.Limits(bot)
	Check("walks as before, cannot pull a trigger", v7 > v0 * 0.95 and fire == false, string.format("speed %.0f against %.0f, fire %s", v7, v0, tostring(fire)))
	local f8, s8, v8 = Walk("left hand gone (right hand zone): the support hand", function() NT.DamageRegion(bot, "R_precentral_hand", 1) end, {})
	run, jump, fire, aim = NT.Limits(bot)
	Check("can fire, cannot aim a long weapon", fire == true and aim == false)
	local f9, s9, v9 = Walk("uninjured again, trying to jump", nil, { jump = true })
	local f10, s10, v10 = Walk("both legs weak, trying to jump", function() NT.DamageRegion(bot, "R_paracentral", 0.72) NT.DamageRegion(bot, "L_paracentral", 0.72) end, { jump = true })
	run, jump = NT.Limits(bot)
	Check("jumping is refused", jump == false)
	S.Drive(bot, nil)
	-- getting up with legs that do not carry
	Fresh(bot, p)
	NT.DamageRegion(bot, "L_ic_post", 1)
	Wait(2.5)
	local down = IsValid(bot.FakeRagdoll)
	local up = hg.FakeUp(bot)
	Wait(1.5)
	Log("  right leg gone: went down %s, getting up allowed %s, still down %s", tostring(down), tostring(up), tostring(IsValid(bot.FakeRagdoll)))
	Check("a character whose leg does not carry goes down and stays down", down and IsValid(bot.FakeRagdoll))
	Fresh(bot, p)
	Tally("neuro_limbs")
end)

------------------------------------------------------------------------------------------
-- Hands, feet, face: what a client draws, measured on the client and photographed
------------------------------------------------------------------------------------------
Add("neuro_hands", function()
	local p = S.FindSpot({ open = 170, outdoor = true })
	local bot = S.NewBot()
	local function Stand(name, fn, shots)
		Fresh(bot, p)
		Wait(1.5)
		Client("pose_base", { ent = bot })
		Wait(0.4)
		fn()
		Wait(2.2)
		Client("pose_measure", { ent = bot, tag = name })
		Wait(0.4)
		for _, s in ipairs(shots or {}) do
			ViewPart(bot, s[1])
			Wait(0.7)
			S.Shot("neuro_hands_" .. s[2])
		end
		S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	end
	Log("-- standing")
	Stand("uninjured", function() end, { { "hands", "base_hands" }, { "face", "base_face" }, { "body", "base_body" } })
	Stand("right arm and hand weak", function() NT.DamageRegion(bot, "L_precentral_hand", 1) NT.DamageRegion(bot, "L_precentral_arm", 1) end, { { "handR", "weak_right_hand" }, { "body", "weak_right_body" } })
	Stand("left side weak with the face (right capsule and face zone)", function() NT.DamageRegion(bot, "R_ic_post", 0.6) NT.DamageRegion(bot, "R_precentral_face", 1) NT.DamageRegion(bot, "R_ic_genu", 0.9) end,
		{ { "face", "weak_left_face" }, { "body", "weak_left_body" }, { "feet", "weak_left_feet" } })
	Stand("right cerebellum", function() NT.DamageRegion(bot, "R_cerebellum_sup", 1) NT.DamageRegion(bot, "R_cerebellum_inf", 1) NT.DamageRegion(bot, "vermis", 0.8) end, { { "body", "ataxia_body" }, { "feet", "ataxia_feet" } })
	Stand("focal seizure of the left arm, aware", function() NT.TriggerSeizure(bot, { focal = true, aware = true, spread = false, side = 1, todd = false }) end, { { "handL", "focal_left_hand" }, { "body", "focal_body" }, { "face", "focal_face" } })
	Stand("focal seizure, awareness lost", function() NT.TriggerSeizure(bot, { focal = true, aware = false, spread = false, side = -1, todd = false }) end, { { "handR", "impaired_right_hand" }, { "face", "impaired_face" } })
	Stand("gaze held left (left frontal eye field destroyed)", function() NT.DamageRegion(bot, "L_caudalmiddlefrontal", 1) end, { { "face", "gaze_face" } })
	Stand("lid of the right side droops (right lateral medulla)", function() NT.DamageRegion(bot, "R_medulla_lateral", 1) end, { { "face", "lid_face" } })
	Stand("one dose of midazolam, awake", function() NT.AdministerMedication(bot, "midazolam") local st = NT.Get(bot.organism) st.med.midazolam.doses[1].onsetAt = CurTime() - 30 end, { { "face", "drowsy_face" } })

	-- fingers under a weapon: do two writers alternate?
	Fresh(bot, p)
	bot:Give("weapon_glock17")
	bot:SelectWeapon("weapon_glock17")
	Wait(2.5)
	NT.DamageRegion(bot, "L_precentral_hand", 1)
	Wait(2)
	Client("flicker", { ent = bot, frames = 40, tag = "pistol in a limp right hand" })
	Wait(1.5)
	ViewPart(bot, "handR")
	Wait(0.6) S.Shot("neuro_hands_weapon_limp")
	-- a hand that cannot close at all (the hand zone and the areas that could stand in for it)
	NT.DamageRegion(bot, "L_caudalmiddlefrontal", 1)
	NT.DamageRegion(bot, "L_sma", 1)
	Wait(2)
	local held = bot:GetActiveWeapon()
	local stw = NT.Get(bot.organism)
	Log("  right hand %.2f: in the hand now: %s", stw and stw.handR or -1, IsValid(held) and held:GetClass() or "nothing")
	Check("a hand that cannot close lets the weapon go", not (IsValid(held) and held:GetClass() == "weapon_glock17"))
	for _, w in ipairs(ents.FindByClass("weapon_glock17")) do
		if not IsValid(w:GetOwner()) then w:Remove() end
	end
	bot:StripWeapons()
	S.View(p + V(120, 50, 60), p + V(0, 0, 35))

	Log("-- ragdolled")
	local function Lying(name, fn, shots)
		Fresh(bot, p)
		hg.Fake(bot)
		Wait(2.5)
		fn()
		Wait(3)
		Client("rag_measure", { ent = bot, tag = name })
		Wait(0.3)
		for _, s in ipairs(shots or {}) do
			ViewPart(bot.FakeRagdoll, s[1], true)
			Wait(0.7)
			S.Shot("neuro_hands_" .. s[2])
		end
		S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	end
	Lying("unconscious, no posture", function() D.Set(bot, "knockout", 30) end, { { "handR", "rag_limp_hand" } })
	Lying("flexor posturing", function() D.Set(bot, "stem", 0.62) end, { { "handR", "rag_flexor_hand" }, { "feet", "rag_flexor_feet" }, { "body", "rag_flexor_body" } })
	Lying("extensor posturing", function() D.Set(bot, "stem", 0.85) end, { { "handR", "rag_extensor_hand" }, { "feet", "rag_extensor_feet" }, { "body", "rag_extensor_body" } })
	Lying("tonic phase", function() NT.Seizure.Force(bot, BR.Ensure(bot.organism), CurTime(), { { "tonic", 12 } }, 1, false) end, { { "handR", "rag_tonic_hand" }, { "face", "rag_tonic_face" } })
	Lying("clonic phase", function() NT.Seizure.Force(bot, BR.Ensure(bot.organism), CurTime(), { { "clonic", 14 } }, 1, false) end, { { "handR", "rag_clonic_hand" }, { "face", "rag_clonic_face" } })
	Fresh(bot, p)
	Tally("neuro_hands")
end)

------------------------------------------------------------------------------------------
-- Seizure kinds, a seizure that does not stop, and midazolam
------------------------------------------------------------------------------------------
Add("neuro_status", function()
	local p = S.FindSpot({ open = 300, outdoor = true })
	local SZ = NT.Seizure
	local CS, CM = C.Seizure, C.Med.midazolam
	local bots = {}
	for i = 1, 6 do
		local bot = S.NewBot()
		if IsValid(bot) then bots[#bots + 1] = bot end
	end
	local function Place()
		for i, bot in ipairs(bots) do Fresh(bot, p + V((i - 3.5) * 60, 0, 0)) end
		S.View(p + V(0, 330, 150), p + V(0, 0, 30))
	end
	-- kinds
	Place()
	local kinds = {
		{ "focal, aware", { focal = true, aware = true, spread = false, todd = false }, "FOCAL_MOTOR" },
		{ "focal, awareness lost", { focal = true, aware = false, spread = false, todd = false }, "FOCAL_IMPAIRED_AWARENESS" },
		{ "tonic only", { focal = false, tonic = true, clonic = false, status = false }, "GENERALIZED_TONIC" },
		{ "clonic only", { focal = false, tonic = false, clonic = true, status = false }, "GENERALIZED_CLONIC" },
		{ "tonic-clonic", { focal = false, tonic = true, clonic = true, status = false }, "TONIC_CLONIC" },
		{ "focal spreading to both sides, weakness after", { focal = true, aware = true, spread = true, tonic = true, clonic = true, status = false, todd = true, side = 1 }, "FOCAL_MOTOR" },
	}
	Log("-- kinds of seizure")
	for i, k in ipairs(kinds) do
		local bot = bots[i]
		NT.TriggerSeizure(bot, k[2])
	end
	Wait(1.5)
	for i, k in ipairs(kinds) do
		local st = NT.Get(bots[i].organism)
		local cat = SZ.CategoryOf(st, CurTime())
		Log("  %-46s -> %s | %s | standing %s | consciousness %.2f", k[1], tostring(cat), tostring(st.label), tostring(not IsValid(bots[i].FakeRagdoll)), st.consciousness)
		Check(k[1] .. " is called " .. k[3], cat == k[3])
	end
	Check("a focal seizure with awareness leaves the character on its feet", not IsValid(bots[1].FakeRagdoll))
	Check("awareness lost: on its feet but not answering", not IsValid(bots[2].FakeRagdoll) and NT.Get(bots[2].organism).consciousness < 0.6)
	Check("a generalised seizure takes the character down", IsValid(bots[5].FakeRagdoll))
	S.Shot("neuro_status_kinds")
	-- the last one: postictal and one-sided weakness
	local b6 = bots[6]
	local t0 = CurTime()
	local sawPost, sawWeak = false, false
	while CurTime() - t0 < 150 do
		Wait(2)
		local st = NT.Get(b6.organism)
		if not st then break end
		local cat = SZ.CategoryOf(st, CurTime())
		if cat == "POSTICTAL" then
			if not sawPost then Log("  postictal after %.0f s: %s | %s", CurTime() - t0, tostring(st.label), Limbs(st)) end
			sawPost = true
			if st.armL < 0.7 and st.armR > 0.9 then sawWeak = true end
		end
		if sawPost and not st.sz and not st.postictalUntil then break end
	end
	Check("the postictal state follows", sawPost)
	Check("the left side, where it began, is weak afterwards", sawWeak)

	-- a seizure that does not stop, on a shortened clock
	Log("-- a seizure that does not stop (time points shortened: prolonged 12 s, status 25 s, little movement left 45 s, exhausted 80 s)")
	local keep = { CS.prolongedAfter, CS.statusAfter, CS.subtleAfter, CS.statusMax, CS.statusBlock, CS.tonicTime, CS.clonicTime }
	CS.prolongedAfter, CS.statusAfter, CS.subtleAfter, CS.statusMax, CS.statusBlock = 12, 25, 45, 80, { 8, 12 }
	CS.tonicTime, CS.clonicTime = { 4, 5 }, { 6, 8 }
	Place()
	local b = bots[1]
	NT.TriggerSeizure(b, { focal = false, tonic = true, clonic = true, status = true })
	local seen = {}
	local o2a = istable(b.organism.o2) and b.organism.o2[1] or -1
	t0 = CurTime()
	while CurTime() - t0 < 110 do
		Wait(3)
		local st = NT.Get(b.organism)
		if not st then break end
		local cat = SZ.CategoryOf(st, CurTime()) or "none"
		if not seen[cat] then
			seen[cat] = true
			Log("  %5.0f s: %s (%s phase) | breathing %s | oxygen %.1f | heart rate %.0f", CurTime() - t0, cat, st.sz and st.sz.phase or "-",
				NT.CardioResp.PatternNames[st.respPattern or 0], istable(b.organism.o2) and b.organism.o2[1] or -1, tonumber(b.organism.heartbeat) or -1)
		end
		if cat == "STATUS_EPILEPTICUS" and not seen.shot then seen.shot = true S.Shot("neuro_status_status") end
		if not st.sz then break end
	end
	Check("it is called prolonged, then status", seen.PROLONGED_SEIZURE and seen.STATUS_EPILEPTICUS)
	Check("it burns out by itself in the end", seen.POSTICTAL == true)
	Log("  oxygen at the start %.1f, after it %.1f", o2a, istable(b.organism.o2) and b.organism.o2[1] or -1)

	-- midazolam: six characters in status, one dose each, a second dose where the first fails
	Log("-- midazolam in status: six characters, a dose each when they are in status, a second where the first fails")
	local onset = CM.onset
	local rise = CM.rise
	CM.rise = 2
	CM.onset = { 3, 5 }
	Place()
	for _, bot in ipairs(bots) do NT.TriggerSeizure(bot, { focal = false, tonic = true, clonic = true, status = true }) end
	Wait(28)
	local host = S.Host()
	for _, bot in ipairs(bots) do
		local ok, why = NT.AdministerMedication(bot, "midazolam")
		if not ok then Log("  refused: %s", tostring(why)) end
	end
	Wait(8)
	local stopped1 = 0
	for _, bot in ipairs(bots) do
		local st = NT.Get(bot.organism)
		if st and (not st.sz or st.sz.phase == "postictal") then stopped1 = stopped1 + 1 end
	end
	Log("  after the first dose: %d of %d stopped (chance per dose %.0f%%)", stopped1, #bots, CM.stopP[1] * 100)
	for _, bot in ipairs(bots) do
		local st = NT.Get(bot.organism)
		if st and st.sz and st.sz.phase ~= "postictal" then NT.AdministerMedication(bot, "midazolam") end
	end
	Wait(8)
	local stopped2 = 0
	for _, bot in ipairs(bots) do
		local st = NT.Get(bot.organism)
		if st and (not st.sz or st.sz.phase == "postictal") then stopped2 = stopped2 + 1 end
	end
	Log("  after a second dose where needed: %d of %d stopped", stopped2, #bots)
	Check("the drug stops seizures, and not all of them at the first dose every time", stopped2 >= stopped1 and stopped2 >= 3)
	for _, bot in ipairs(bots) do
		local st = NT.Get(bot.organism)
		if st then Log("    %s: %s | sedation %.2f breathing %.2f | injury unchanged: diffuse %.2f stem %.2f", bot:Nick(), tostring(st.label), st.sedation or 0, st.resp, st.diffuse, st.stem) end
	end
	CS.prolongedAfter, CS.statusAfter, CS.subtleAfter, CS.statusMax, CS.statusBlock, CS.tonicTime, CS.clonicTime = keep[1], keep[2], keep[3], keep[4], keep[5], keep[6], keep[7]

	-- doses in an uninjured, awake character
	Log("-- doses in an uninjured, awake character")
	Place()
	local a = bots[1]
	for n = 1, 4 do
		local ok, why = NT.AdministerMedication(a, "midazolam")
		Wait(7)
		local st = NT.Get(a.organism)
		if st then
			Log("  dose %d (%s): %s | consciousness %.2f | respiratory control %.2f (%s) | standing %s | Z-City consciousness %.2f", n, ok and "given" or tostring(why), tostring(st.label), st.consciousness, st.resp,
				NT.CardioResp.PatternNames[st.respPattern or 0], tostring(not IsValid(a.FakeRagdoll)), tonumber(a.organism.consciousness) or -1)
			if n == 1 then Check("one dose: drowsy, on the feet, breathing normally", st.consciousness < 0.9 and st.consciousness > 0.4 and st.resp >= 0.8) end
			if n == 3 then Check("three doses: unresponsive, breathing depressed", st.consciousness < 0.3 and st.resp < 0.8) end
		end
	end
	-- validation: a giver out of reach, a giver without hands
	Place()
	local giver, patient = bots[1], bots[2]
	giver:SetPos(p + V(600, 0, 5))
	Wait(0.3)
	local ok, why = NT.AdministerMedication(patient, "midazolam", giver)
	Check("a giver out of reach is refused", ok == false, tostring(why))
	Fresh(giver, p + V(-90, 0, 0))
	Wait(1.6)
	ok, why = NT.AdministerMedication(patient, "midazolam", giver)
	Check("a giver next to the patient is accepted", ok == true, tostring(why))
	ok, why = NT.AdministerMedication(patient, "midazolam", giver)
	Check("a second call at once is refused (rate limit)", ok == false, tostring(why))
	Wait(2)
	NT.DamageRegion(giver, "L_precentral_hand", 1) NT.DamageRegion(giver, "R_precentral_hand", 1)
	Wait(0.6)
	ok, why = NT.AdministerMedication(patient, "midazolam", giver)
	Check("a giver whose hands do not work is refused", ok == false, tostring(why))
	-- the item
	local w = host:Give("weapon_midazolam")
	Log("  item: %s (registered %s)", tostring(w), tostring(NT.Items and NT.Items.midazolam))
	Check("the item exists and derives from Z-City's medicine base", IsValid(w) and w.Base == "weapon_bandage_sh" and isfunction(w.Heal))
	if IsValid(w) then
		local done = w:Heal(host, 1)
		Wait(0.3)
		local hst = NT.Get(host.organism)
		Check("using it on oneself books a dose", done == true and hst ~= nil and hst.med ~= nil and hst.med.midazolam ~= nil)
		NT.Reset(host)
	end
	CM.onset = onset
	CM.rise = rise
	for _, bot in ipairs(bots) do Fresh(bot, p) end
	Tally("neuro_status")
end)

------------------------------------------------------------------------------------------
-- Circulation: labels, an arrest, compressions, the return of circulation and what it leaves
------------------------------------------------------------------------------------------
Add("neuro_cardio", function()
	local p = S.FindSpot({ open = 200, outdoor = true })
	local bot = S.NewBot()
	S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	local function Show(tag)
		local org = bot.organism
		local label, t = Cardio.GetState(bot)
		local st = NT.Get(org)
		Log("  [%s] %s | %s | pressure %.0f volume %.0f%% oxygen %.0f%% | perfusion %.2f | %s%s", tag, tostring(label), Cardio.GetHeartState(bot), t.pressure, t.circulatingVolume * 100, t.oxygenSaturation * 100, t.perfusion,
			st and tostring(st.label) or "no record", st and string.format(" | consciousness %.2f | memory %.2f | infarcted %.1f%%", st.consciousness, AN.Channels(st).memory, st.an.infarct * 100) or "")
		return label, t, st
	end
	Fresh(bot, p)
	local label = Show("uninjured")
	Check("an uninjured character reads NORMAL or STRESSED", label == "NORMAL" or label == "STRESSED")
	-- blood loss
	Log("-- blood loss (Z-City's blood volume lowered by hand)")
	bot.organism.godmode = false
	for _, ml in ipairs({ 4000, 3200, 2600 }) do
		bot.organism.blood = ml
		Wait(6)
		label = Show(string.format("%d ml", ml))
	end
	Check("heavy blood loss reads as shock or worse", label == "SHOCK" or label == "CRITICAL" or label == "CARDIAC_ARREST" or label == "HYPOPERFUSION")
	-- stress
	Fresh(bot, p)
	local hr0 = tonumber(bot.organism.heartbeat) or 0
	Cardio.ApplyStress(bot, 1.5)
	Wait(5)
	Log("  stress applied: heart rate %.0f -> %.0f", hr0, tonumber(bot.organism.heartbeat) or 0)
	Check("stress raises the heart rate through Z-City's own input", (tonumber(bot.organism.heartbeat) or 0) > hr0 + 5)
	-- pressure in the skull slows the heart
	Fresh(bot, p)
	D.Set(bot, "massSide", 1) D.Set(bot, "massFinal", 0.9) D.Set(bot, "mass", 0.85)
	Wait(4)
	local st = NT.Get(bot.organism)
	Log("  lesion 0.85: pressure %.2f | heart rate %.0f | slowed by the model %s", st and st.pressure or -1, tonumber(bot.organism.heartbeat) or -1, tostring(st and st.cushing))
	Check("the heart is slowed", st ~= nil and st.cushing == true and (tonumber(bot.organism.heartbeat) or 99) < 68, string.format("%.0f per minute", tonumber(bot.organism.heartbeat) or -1))

	-- arrests of different length, restarted
	local function Arrest(seconds, cpr)
		Fresh(bot, p)
		bot.organism.godmode = false
		Cardio.TriggerArrest(bot, "test")
		local t0 = CurTime()
		local saw = {}
		while CurTime() - t0 < seconds do
			Wait(1)
			local s2 = NT.Get(bot.organism)
			if s2 then
				if s2.cpr and not saw.cpr then saw.cpr = true end
				if (s2.posture or 0) > 0.05 then saw.posture = true end
				if cpr and CurTime() - t0 > 6 and not saw.started then
					saw.started = true
					-- what Z-City's compressions do to its numbers, two a second, without the restart
					timer.Create("NT_TestCPR2", 0.5, math.floor((seconds - 6) * 2), function()
						local o = IsValid(bot) and bot.organism
						if istable(o) and o.heartstop == true then o.pulse = math.min((tonumber(o.pulse) or 0) + 5, 70) end
					end)
				end
			end
			if not bot:Alive() then break end
		end
		local alive = bot:Alive()
		local back = false
		if alive and bot.organism.heartstop == true then
			-- (the test gives back what the heart needs, as a successful resuscitation would)
			bot.organism.o2[1] = math.max(bot.organism.o2[1], 20)
			for _ = 1, 6 do
				back = Cardio.AttemptROSC(bot, 1)
				if back then break end
			end
		elseif alive then back = true end
		Wait(3)
		local label2, t, s3 = Show(string.format("%d s without circulation%s, then restarted (%s)", seconds, cpr and ", compressions from 6 s" or "", back and "back" or "not back"))
		Wait(12)
		local s4 = NT.Get(bot.organism)
		local mem = s4 and AN.Channels(s4).memory or 1
		Log("    15 s later: %s | %s | memory %.2f | damaged: %s", tostring(Cardio.GetState(bot)), s4 and tostring(s4.label) or "-", mem, s4 and AN.Describe(s4, 5) or "-")
		return alive, back, saw, s4, mem
	end
	Log("-- arrests")
	local alive, back, saw, s4, mem1 = Arrest(12, false)
	Check("12 s: back, and the brain essentially whole", alive and back and mem1 > 0.9)
	local _, back2, saw2, s5, mem2 = Arrest(70, false)
	Check("70 s without compressions: the brain is injured, and stays so after the circulation is back", mem2 < mem1 - 0.05 or (s5 and s5.an.infarct > 0.02), string.format("memory %.2f, infarcted %.1f%%", mem2, s5 and s5.an.infarct * 100 or -1))
	Check("a body without circulation lies limp: no posturing in either arrest", not saw.posture and not saw2.posture)
	local _, back3, saw3, s6, mem3 = Arrest(70, true)
	Check("compressions are recognised", saw3.cpr == true)
	Check("70 s with compressions leaves less injury than 70 s without", (s6 and s6.an.infarct or 1) < (s5 and s5.an.infarct or 0) + 0.001, string.format("%.1f%% against %.1f%%", s6 and s6.an.infarct * 100 or -1, s5 and s5.an.infarct * 100 or -1))
	Fresh(bot, p)
	Tally("neuro_cardio")
end)

------------------------------------------------------------------------------------------
-- Networking: versions, the detail block, the owner's block, the field of vision
------------------------------------------------------------------------------------------
Add("neuro_net2", function()
	local p = S.FindSpot({ open = 200, outdoor = true })
	local bot = S.NewBot()
	local host = S.Host()
	S.View(p + V(120, 50, 60), p + V(0, 0, 35))
	Fresh(bot, p)
	local m0, b0 = NT.Net.messages, NT.Net.bytes
	NT.DamageVessel(bot, "L_mca_sup", 0)
	Wait(3)
	Client("dump", { tag = "left upper division shut" })
	Wait(0.5)
	Log("  3 s of one injured character: %d messages, %d bytes (%.0f bytes per second)", NT.Net.messages - m0, NT.Net.bytes - b0, (NT.Net.bytes - b0) / 3)
	-- stale and reordered messages, fed to the client by hand
	Client("stale", { ent = bot })
	Wait(0.6)
	-- the owner's block: the host is given a lesion of its own
	NT.DamageVessel(host, "L_pca_p2", 0)
	NT.DamageRegion(host, "R_supramarginal", 1) NT.DamageRegion(host, "R_inferiorparietal", 1) NT.DamageRegion(host, "R_superiortemporal_post", 1)
	Wait(3)
	Client("self", { tag = "host: left posterior cerebral artery shut, right parietal lesion" })
	Wait(0.4)
	S.Shot("neuro_net2_field_right")
	NT.Reset(host)
	Wait(0.5)
	NT.DamageVessel(host, "R_pca_calcarine", 0)
	NT.DamageRegion(host, "R_optic_meyer", 1)
	Wait(3)
	Client("self", { tag = "host: right calcarine branch shut" })
	S.Shot("neuro_net2_field_left")
	NT.Reset(host)
	Wait(0.5)
	NT.DamageRegion(host, "L_optic_meyer", 1)
	Wait(2.5)
	Client("self", { tag = "host: left temporal loop of the optic radiation cut" })
	S.Shot("neuro_net2_field_quadrant")
	-- reading: what the host makes of the bot's chat with a comprehension lesion
	NT.Reset(host)
	Wait(0.5)
	NT.DamageRegion(host, "L_superiortemporal_post", 1) NT.DamageRegion(host, "L_bankssts", 1) NT.DamageRegion(host, "L_middletemporal", 1) NT.DamageRegion(host, "L_inferiorparietal", 1)
	Wait(2.5)
	Client("self", { tag = "host: left temporal language cortex destroyed" })
	Client("read", { text = "the quick brown fox jumps over the lazy dog near the old bridge" })
	Wait(0.5)
	NT.Reset(host)
	Wait(1.5)
	Client("self", { tag = "host: after reset" })
	-- the brain view
	NT.DamageVessel(bot, "R_mca_m1", 0)
	Wait(1.5)
	RunConsoleCommand("neuro_dev", "1")
	for _, m in ipairs({ "damage", "vascular", "connectivity", "motor", "language", "perfusion" }) do
		host:ConCommand("brain_show_" .. m .. " " .. bot:EntIndex())
		Wait(1.6)
		S.Shot("neuro_net2_view_" .. m)
	end
	host:ConCommand("brain_show_off")
	local r, t, v, c = D.Export()
	Log("  export: %d regions, %d tracts, %d vessels, %d channels written to data/neurotrauma/", r, t, v, c)
	Fresh(bot, p)
end)

------------------------------------------------------------------------------------------
-- Many injured at once: what the module costs with 1, 5, 10 and 20
------------------------------------------------------------------------------------------
Add("neuro_perf3", function()
	NT.Trauma.silent = true
	local p = S.FindSpot({ open = 420, outdoor = true })
	local bots = {}
	for i = 1, 20 do
		local bot = S.NewBot()
		if IsValid(bot) then
			S.Place(bot, p + V(((i - 1) % 7 - 3) * 60, (math.floor((i - 1) / 7) - 1) * 90, 0), 0)
			if istable(bot.organism) then bot.organism.godmode = true end
			bots[#bots + 1] = bot
		end
	end
	Log("  bots: %d (the server must allow that many players)", #bots)
	Wait(2)
	S.View(p + V(0, 420, 260), p + V(0, 0, 20))
	local hooks = { { "Org Think", "NT_Brain" }, { "Think", "NT_Motor" }, { "Think", "NT_Injury" }, { "Ragdoll Collide", "NT_Collide" }, { "HG_MovementCalc_2", "NT_Move" },
		{ "StartCommand", "NT_Control" }, { "Should Fake Up", "NT_Motor" }, { "CanControlFake", "NT_Motor" } }
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
		local m0, b0, sm0, sb0 = NT.Net.messages, NT.Net.bytes, NT.Net.selfMessages, NT.Net.selfBytes
		local t0, ticks0 = CurTime(), engine.TickCount()
		Wait(seconds)
		local dt, ticks = CurTime() - t0, engine.TickCount() - ticks0
		local sum = 0
		for _, s in ipairs(st) do
			hook.Add(s.ev, s.id, s.fn)
			sum = sum + s.total
			Log("    %-28s %6d calls  %7.2f us per call  %7.3f ms per second", s.ev .. " / " .. s.id, s.calls, s.total / math.max(s.calls, 1) * 1e6, s.total / dt * 1000)
		end
		Log("  %s: %d records | all hooks %.3f ms per second = %.1f us per server tick (%d ticks in %.1f s) | net %.0f bytes per second in %.1f messages per second",
			name, NT.Brain.count, sum / dt * 1000, sum / math.max(ticks, 1) * 1e6, ticks, dt, (NT.Net.bytes - b0) / dt, (NT.Net.messages - m0) / dt)
		Client("posestats", { tag = name })
	end
	local function Injure(i, bot)
		local kind = i % 5
		if kind == 0 then
			hg.Fake(bot)
			D.Set(bot, "stem", 0.7)                                  -- posturing
		elseif kind == 1 then
			NT.DamageVessel(bot, i % 2 == 0 and "L_mca_m1" or "R_mca_m1", 0)   -- a stroke: vessels active, weak side, standing
		elseif kind == 2 then
			hg.Fake(bot)
			NT.Seizure.Force(bot, BR.Ensure(bot.organism), CurTime(), { { "tonic", 4 }, { "clonic", 40 }, { "postictal", 20 } }, 1, false)
		elseif kind == 3 then
			D.Set(bot, "diffuse", 0.3)                               -- unsteady on its feet
		else
			NT.DamageRegion(bot, "R_cerebellum_sup", 1) NT.DamageRegion(bot, "L_precentral_hand", 1)   -- clumsy and weak, standing, quiet
		end
	end
	Measure("nobody injured", 6)
	local n = 0
	for _, target in ipairs({ 1, 5, 10, 20 }) do
		while n < target and n < #bots do
			n = n + 1
			Injure(n, bots[n])
		end
		Wait(2.5)
		if target == 20 then S.Shot("neuro_perf3_twenty") end
		Measure(string.format("%d injured", n), 8)
	end
	-- single operations, on the first character (a shut middle cerebral artery)
	local st1 = IsValid(bots[1]) and istable(bots[1].organism) and NT.Get(bots[1].organism)
	if st1 then
		local n = 2000
		local t0 = SysTime()
		for _ = 1, n do st1.an.dirty = true AN.Compute(st1) end
		local t1 = SysTime()
		for _ = 1, n do BR.Derive(st1, CurTime()) end
		local t2 = SysTime()
		for _ = 1, n do VA.Flow(st1.an) end
		local t3 = SysTime()
		Log("  single operations, %d calls each: all channels %.1f us | the neurological variables %.1f us | blood through the vessel tree %.1f us",
			n, (t1 - t0) / n * 1e6, (t2 - t1) / n * 1e6, (t3 - t2) / n * 1e6)
	end
	for _, bot in ipairs(bots) do if istable(bot.organism) and NT.Get(bot.organism) then NT.Reset(bot) end end
end)
