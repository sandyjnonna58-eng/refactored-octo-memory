-- Отладка «тело складывается пополам / выворачивает спину» (скрин пользователя: регдолл в падении ногами за голову,
-- в организме позвоночник цел - только картинка). rem_debug_bend 1 - раз в 0.1 с проверяет регдоллы живых игроков:
-- угол между «таз -> грудь» и «таз -> колени» (стоя ~180°, сидя ~90°, сложился ногами за голову - меньше 45°) и
-- изгиб «грудь -> голова» относительно «таз -> грудь». Сложился - печатает [rem_bend], кто в этот момент тянет тело:
-- мод Artagdoll (поведение, пауза, поза), наши реакции (кувырок, корчи, ползком), разболтанные кости Z-City (перелом
-- конечности), перелом позвоночника в организме, массы костей сейчас и при создании тела, скорость, кнопки.
local cv = CreateConVar("rem_debug_bend", "0", FCVAR_ARCHIVE, "Print what drives a living ragdoll when it folds in half (server console)", 0, 1)
local JACK = 45     -- таз: грудь и колени ближе этого угла - сложился
local NECK = 110    -- голова откинута/свёрнута сильнее этого относительно корпуса

local function PhysPos(rag, name)
	local b = rag:LookupBone(name)
	if not b then return nil end
	local p = rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(b))
	return IsValid(p) and p:GetPos() or nil, IsValid(p) and p or nil
end

local function Angle3(a, o, b)
	local u, v = (a - o):GetNormalized(), (b - o):GetNormalized()
	return math.deg(math.acos(math.Clamp(u:Dot(v), -1, 1)))
end

local function Masses(rag)
	local t = {}
	for _, n in ipairs({"Pelvis", "Spine2", "Head1", "R_Thigh", "L_Thigh", "R_Calf"}) do
		local _, p = PhysPos(rag, "ValveBiped.Bip01_" .. n)
		t[#t + 1] = n .. "=" .. (p and ("%.1f"):format(p:GetMass()) or "?")
	end
	return table.concat(t, " ")
end

hook.Add("Ragdoll_Create", "rem_debug_bend", function(ply, rag)
	if not cv:GetBool() or not IsValid(rag) then return end
	timer.Simple(0, function() if IsValid(rag) then rag.remBendMass0 = Masses(rag) end end)
end)

local nextT = 0
hook.Add("Think", "rem_debug_bend", function()
	if not cv:GetBool() then return end
	local now = CurTime()
	if now < nextT then return end
	nextT = now + 0.1
	for _, ply in player.Iterator() do
		local rag = ply.FakeRagdoll
		if not (ply:Alive() and IsValid(rag)) then continue end
		local pel, pp = PhysPos(rag, "ValveBiped.Bip01_Pelvis")
		local chest = PhysPos(rag, "ValveBiped.Bip01_Spine2")
		local head = PhysPos(rag, "ValveBiped.Bip01_Head1")
		local kr = PhysPos(rag, "ValveBiped.Bip01_R_Calf")
		local kl = PhysPos(rag, "ValveBiped.Bip01_L_Calf")
		if not (pel and chest and head and kr and kl) then continue end
		local knees = (kr + kl) / 2
		local jack = Angle3(chest, pel, knees)
		local neck = 180 - Angle3(pel, chest, head) -- 0 - голова продолжает корпус
		if jack >= JACK and neck <= NECK then rag.remBendOn = nil continue end
		if rag.remBendOn and now - rag.remBendOn < 2 then continue end
		rag.remBendOn = now
		local org = ply.organism or {}
		local st = hg.Reag and hg.Reag.R and hg.Reag.R[rag]
		local ar = ActiveRagdoll and ActiveRagdoll.Get and ActiveRagdoll.Get(rag)
		local floppy = {}
		for b in pairs(rag.hg_floppy_bones or {}) do floppy[#floppy + 1] = (b:gsub("ValveBiped.Bip01_", "")) end
		local keys = {}
		for k, n in pairs({[IN_ATTACK] = "ЛКМ", [IN_ATTACK2] = "ПКМ", [IN_USE] = "E", [IN_FORWARD] = "W", [IN_BACK] = "S",
			[IN_MOVELEFT] = "A", [IN_MOVERIGHT] = "D", [IN_JUMP] = "прыжок", [IN_SPEED] = "Shift", [IN_WALK] = "Alt"}) do
			if ply:KeyDown(k) then keys[#keys + 1] = n end
		end
		print(("[rem_bend] %s: СЛОЖИЛСЯ - таз %.0f° (грудь-колени), шея %.0f°; скорость %.0f, на земле: %s"):format(ply:Nick(), jack, neck,
			pp:GetVelocity():Length(), tostring(util.TraceLine({start = pel, endpos = pel - Vector(0, 0, 40), filter = {rag, ply}, mask = MASK_SOLID}).Hit)))
		print(("[rem_bend]   Artagdoll: %s%s%s%s"):format(ar and "ведёт тело" or "нет",
			ar and (", поведение " .. tostring(ar.CurrentBehavior)) or "",
			rag.remArtagPaused and ", на паузе" or "", rag.remArtagPose and (", поза " .. tostring(rag.remArtagPose.kind)) or ""))
		print(("[rem_bend]   наши реакции: %s; разболтанные кости (перелом конечности): %s"):format(
			st and table.concat({st.tumble and "кувырок" or nil, st.writhe and "корчи" or nil, st.crawl and "ползком" or nil,
				st.bal and "равновесие" or nil, st.guard and "закрывается" or nil, st.hs and "выстрел в голову" or nil}, ", ") or "нет",
			#floppy > 0 and table.concat(floppy, ", ") or "нет"))
		print(("[rem_bend]   организм: позвоночник %.2f/%.2f/%.2f, ноги %.2f/%.2f, тазовая %.2f, без сознания %s, боль %.0f, шокер %s, припадок %s, поза мозга %s; кнопки: %s"):format(
			org.spine1 or 0, org.spine2 or 0, org.spine3 or 0, org.lleg or 0, org.rleg or 0, org.pelvis or 0, tostring(org.otrub),
			org.pain or 0, tostring((org.tasered or 0) > now), tostring(org.seizureActive), tostring(org.brainfuckv2Posture),
			#keys > 0 and table.concat(keys, " ") or "нет"))
		print(("[rem_bend]   массы сейчас: %s; при создании тела: %s"):format(Masses(rag), tostring(rag.remBendMass0)))
	end
end)
