-- Индикатор здоровья (из MELEECITY): слева снизу выезжает белый силуэт твоего персонажа,
-- сломанные/вывихнутые конечности мигают красным, отрубленные исчезают, силуэт темнеет вместе с сознанием.
-- По центру снизу - плитки состояний (materials/rem_affl, в стиле Neurotrauma): красный квадрат, чем тяжелее - тем ярче,
-- критические в белой рамке; наведи курсор (когда он виден) - подпись.
-- Включается пунктом "Afflictions" в радиальном меню или командой rem_afflictions (можно забиндить).
hg.HealthIndicator = hg.HealthIndicator or {}
local HI = hg.HealthIndicator

local whiteMat = Material("models/debug/debugwhite")

local IND_SIZE = 120
local BACKDROP_OFFSET_X = -20
local BACKDROP_OFFSET_Y = 37
local SILHOUETTE_OFFSET_X = -15
local SILHOUETTE_OFFSET_Y = 15
local ICONS_SCREEN_EDGE_MARGIN = 20
local ICONS_SCREEN_MARGIN_Y = 18
local BLINK_SCALE = Vector(1.05, 1.05, 1.05)
local BLINK_DURATION = 5
local FRACTURE_BLINK_SPEED = 10
local POS_VISIBLE_X = 0
local POS_HIDDEN_X = -400
local vector_zero = Vector(0, 0, 0)
local vector_one = Vector(1, 1, 1)
local colBackdrop = Color(10, 10, 19, 150)
local colOutline = Color(255, 255, 255, 70)

local healthModel, blinkModel
local currentX
local limbStates = {}
local lastLifeState
local iconsVisibility = 0
local iconsAppearTime = 0
local iconsTargetVisible = false
local cachedAfflictionIcons = {}
-- ряд как в Fading Vitality: слева направо, первым всегда сердце (бьётся с пульсом), остальные - в порядке появления
-- (новые - в конец); пропала плитка - те, что за ней, скользят к сердцу (белую вспышку при смене набора убрали по просьбе)
local iconOrder, iconOrderSeq = {pulse = 0}, 0
local tileSlotX = {} -- имя -> текущий x плитки от начала ряда (скользит к своему месту)
local SLIDE_TIME = 0.12 -- за сколько плитка проходит одну клетку к сердцу
local function ResetIconOrder()
	iconOrder, iconOrderSeq, tileSlotX = {pulse = 0}, 0, {}
end

HI.Shown = HI.Shown or false

-- без сознания осмотр (силуэт с ранами и плитки) виден сам, тускло и "дышит" в темноте - как в Fading Vitality
local cvOtrubInspect = CreateClientConVar("rem_otrub_inspect", 1, true, false, "Show the afflictions panel dimly while unconscious", 0, 1)
local otrub_dim_min, otrub_dim_max = 0.35, 0.65 -- сколько темноты поверх осмотра в отключке (пульсирует)
local otrub_dim_period = 4.5
local otrub_silhouette_min = 0.45                -- силуэт не темнее этого (иначе сознание 0 - чёрный)

local limbBones = {
	lleg = "ValveBiped.Bip01_L_Thigh",
	rleg = "ValveBiped.Bip01_R_Thigh",
	larm = "ValveBiped.Bip01_L_UpperArm",
	rarm = "ValveBiped.Bip01_R_UpperArm"
}

local amputationBones = {
	lleg = "ValveBiped.Bip01_L_Calf",
	rleg = "ValveBiped.Bip01_R_Calf",
	larm = "ValveBiped.Bip01_L_Forearm",
	rarm = "ValveBiped.Bip01_R_Forearm"
}

function HI.Toggle(state)
	if state == nil then state = not HI.Shown end
	HI.Shown = state
end

concommand.Add("rem_afflictions", function() HI.Toggle() end)

hook.Add("radialOptions", "rem_afflictions", function()
	local ply = LocalPlayer()
	local org = ply.organism or {}
	if not ply:Alive() or org.otrub then return end

	hg.radialOptions[#hg.radialOptions + 1] = {function() HI.Toggle() end, HI.Shown and "Hide Afflictions" or "Afflictions"}
end)

local function ScreenScaleFixed(size)
	return size * (ScrH() / 480)
end

local function ScaleBoneAndChildren(ent, boneID, scale)
	ent:ManipulateBoneScale(boneID, scale)
	for _, child in ipairs(ent:GetChildBones(boneID)) do
		ScaleBoneAndChildren(ent, child, scale)
	end
end

local function ScaleBoneByName(ent, boneName, scale)
	local boneID = ent:LookupBone(boneName)
	if boneID then ScaleBoneAndChildren(ent, boneID, scale) end
end

local function SetIdlePose(ent)
	local seq = ent:LookupSequence("idle_suitcase")
	if seq and seq >= 0 then
		ent:SetSequence(seq)
		ent:SetCycle(0)
	end
end

local function InitBlinkModel(ent)
	ent:SetupBones()
	for i = 0, ent:GetBoneCount() - 1 do
		ent:ManipulateBoneScale(i, vector_zero)
	end
end

local function RemoveAccessories(ent)
	if not ent.accessories then return end
	for _, v in pairs(ent.accessories) do
		if IsValid(v) then v:Remove() end
	end
	ent.accessories = nil
end

local function ResetModels()
	if IsValid(healthModel) then
		RemoveAccessories(healthModel)
		healthModel:Remove()
	end
	if IsValid(blinkModel) then blinkModel:Remove() end
	healthModel = nil
	blinkModel = nil
	limbStates = {}
	iconsVisibility = 0
	iconsAppearTime = 0
	iconsTargetVisible = false
	cachedAfflictionIcons = {}
end

local function CreateModel(mdl)
	local ent = ClientsideModel(mdl, RENDERGROUP_OTHER)
	ent:SetNoDraw(true)
	ent:SetIK(false)
	SetIdlePose(ent)
	return ent
end

local function DrawHealthAccessories(ent, ply)
	local accessories = ply:GetNetVar("Accessories")
	if not accessories or not hg.Accessories then
		RemoveAccessories(ent)
		return
	end

	ent.accessories = ent.accessories or {}
	local accList = istable(accessories) and accessories or {accessories}
	local currentAccs = {}
	local fuckYou = hg.Appearance and hg.Appearance.FuckYouModels
	local isFemale = fuckYou and fuckYou[2] and fuckYou[2][ent:GetModel()] and true or false

	for _, accName in pairs(accList) do
		currentAccs[accName] = true
		local accessData = hg.Accessories[accName]
		if not accessData or accessData.norender then continue end

		local posData = accessData[isFemale and "fempos" or "malepos"]
		if not posData then continue end

		local model = ent.accessories[accName]
		if not IsValid(model) then
			local modelPath = isFemale and accessData.femmodel or accessData.model
			if not modelPath then continue end

			model = ClientsideModel(modelPath, RENDERGROUP_OTHER)
			model:SetNoDraw(true)
			model:SetModelScale(posData[3] or 1)

			local skin = accessData.skin
			if isfunction(skin) then skin = skin(ent) end
			model:SetSkin(skin or 0)
			model:SetBodyGroups(accessData.bodygroups or "")

			if accessData.bonemerge then model:AddEffects(EF_BONEMERGE) end
			if accessData.bSetColor then model:SetColor((ply:GetPlayerColor() or vector_one):ToColor()) end
			if accessData.SubMat then model:SetSubMaterial(0, accessData.SubMat) end

			ent.accessories[accName] = model
		end

		local bone = accessData.bone and ent:LookupBone(accessData.bone)
		local matrix = bone and ent:GetBoneMatrix(bone)
		if matrix then
			local pos, ang = LocalToWorld(posData[1], posData[2], matrix:GetTranslation(), matrix:GetAngles())
			model:SetRenderOrigin(pos)
			model:SetRenderAngles(ang)
			if model:GetParent() ~= ent then model:SetParent(ent, bone) end
			model:DrawModel()
		end
	end

	for name, model in pairs(ent.accessories) do
		if not currentAccs[name] then
			if IsValid(model) then model:Remove() end
			ent.accessories[name] = nil
		end
	end
end

local function Num(value)
	if isnumber(value) then return value end
	if istable(value) then
		if isnumber(value[1]) then return value[1] end
		if isnumber(value.cur) then return value.cur end
		if isnumber(value.value) then return value.value end
	end
	return 0
end

-- значки состояний: квадратные плитки (materials/rem_affl, белые значки Tabler Icons + свои),
-- фон от тёмно-красного (лёгкое) до ярко-красного (тяжёлое), у критических - белая рамка
local afflIconCache = {}
local function AfflIcon(name)
	local cached = afflIconCache[name]
	if cached ~= nil then return cached or nil end
	local mat = Material("rem_affl/" .. name .. ".png", "smooth mips")
	afflIconCache[name] = not mat:IsError() and mat or false
	return afflIconCache[name] or nil
end

-- стадии ярости: тяжесть плитки, название, описание (строки через \n)
local RAGE_STAGES = {
	{0.45, "Blinding anger", "You can barely hold it in.\nSomeone here is asking for it,\nand you feel more than ready.\nLess fear and pain."},
	{0.75, "FURIOUS", "You're at your limit.\nYour fists clench on their own.\nWhoever gets in your way, regrets it."},
	{1, "UNDETERRABLE RAGE", "NOTHING. ELSE. MATTERS. BUT. THIS."},
}

-- паника (modules/sv_panic.lua): с 0.35 и с 0.7 (слепая)
local PANIC_STAGES = {
	{0.35, 0.6, "Panic", "Your heart is pounding out of your chest.\nYour breath comes in short gasps\nand your hands won't stay still.\nYou flinch at everything that moves."},
	{0.7, 1, "BLIND PANIC", "You can't think. You just want OUT.\nYour body moves on its own."},
}

local function CollectAfflictionIcons(ply, org)
	local icons, seen = {}, {}
	local function add(iconName, severity, label, good, desc)
		severity = math.Clamp(severity or 0.5, 0.05, 1)
		local e = seen[iconName]
		if e then
			e.severity = math.max(e.severity, severity)
			return
		end
		local mat = AfflIcon(iconName)
		if not mat then return end
		e = {name = iconName, mat = mat, severity = severity, label = label or iconName, good = good, desc = desc}
		seen[iconName] = e
		icons[#icons + 1] = e
	end

	if not org then return icons end

	-- плитка сердца - только если ЭКГ выключена (rem_ecg 0): пульс показывает монитор над силуэтом
	if not (hg.ECG and hg.ECG.cv and hg.ECG.cv:GetBool()) then
		add("pulse", 0.05, "Heart", false, "Pulse: " .. math.Round(Num(org.pulse)) .. " bpm")
	end

	-- раны и кровь
	local wounds = ply.wounds or ply:GetNetVar("wounds")
	local arterialwounds = ply.arterialwounds or ply:GetNetVar("arterialwounds")
	local woundsCount = istable(wounds) and #wounds or 0
	local arterialCount = istable(arterialwounds) and #arterialwounds or 0
	if arterialCount > 0 then add("arterial", 0.75 + arterialCount * 0.15, "Arterial bleeding") end
	local bleed = Num(org.bleed)
	if bleed > 0 then add("bleeding", bleed / 8, "Bleeding") end
	if woundsCount > 0 then add("wound", woundsCount / 6, "Open wounds") end
	local blood = Num(org.blood)
	if blood > 0 and blood < 4500 then add("bloodloss", (4500 - blood) / 2500, "Blood loss") end
	if Num(org.internalBleed) > 0.5 then add("internal", Num(org.internalBleed) / 10, "Internal bleeding") end

	-- кости и конечности
	if org.llegamputated or org.rlegamputated or org.larmamputated or org.rarmamputated then add("amputation", 1, "Amputation") end
	local broken = {}
	for limb, name in pairs({lleg = "left leg", rleg = "right leg", larm = "left arm", rarm = "right arm"}) do
		if Num(org[limb]) >= 1 and not org[limb .. "amputated"] then broken[#broken + 1] = name end
	end
	if #broken > 0 then add("fracture", 0.55 + #broken * 0.1, "Fracture: " .. table.concat(broken, ", ")) end
	if org.llegdislocation or org.rlegdislocation or org.larmdislocation or org.rarmdislocation or org.jawdislocation then
		add("dislocation", 0.55, "Dislocation")
	end
	if Num(org.skull) >= 1 then add("skull", 1, "Skull fracture") end

	-- голова и сознание
	local concussion = Num(org.concussion)
	if concussion > 0 then add("concussion", concussion / 5, "Concussion") end
	local brain = Num(org.brain)
	if brain > 0.05 then add("brain", brain / 0.6, "Brain damage") end
	if org.seizureActive then add("seizure", 1, "Seizure") end
	if org.otrub then add("unconscious", 1, "Unconscious") end
	if org.blindness then add("blind", 0.7, "Blindness") end

	-- боль и шок
	local pain = Num(org.pain)
	if pain > 20 then add("pain", pain / 120, "Pain") end
	local shock = Num(org.shock)
	if shock > 10 then add("shock", shock / 40, "Shock") end
	if org.critical then add("critical", 1, "Critical condition") end

	-- сердце и давление: стадии шкалы фибрилляции 0..100 (sv_pulse.lua, как в SCAV Prototype)
	local fib = org.fib ~= nil and Num(org.fib) or Num(org.arrhythmia) * 100
	local hr = Num(org.heartbeat)
	if org.heartstop then
		add("cardiac_arrest", 1, "Cardiac arrest", nil, "Asystole. The heart is not pumping - CPR or a defibrillator, fast.")
	elseif fib > 75 then
		add("fibrillation", 1, "Ventricular fibrillation", nil, "Chaotic rhythm, the heart barely pumps. Cardiac arrest is close - defibrillate.")
	elseif fib > 50 then
		add("vtach", 0.6 + (fib - 50) / 25 * 0.4, "Ventricular tachycardia", nil, "Severe irregular heartbeat. Will turn into ventricular fibrillation if not treated.")
	elseif fib > 15 then
		add("arrhythmia", 0.25 + (fib - 15) / 35 * 0.35, "Arrhythmia", nil, "Abnormal heart rhythm from strain on the body. Worsens if the cause stays.")
	end
	-- частота (если ритм не сорван)
	if not org.heartstop and fib <= 50 and hr > 0 then
		if hr > 110 then
			add("tachycardia", math.Clamp((hr - 110) / 90, 0.15, 1), "Tachycardia", nil, "Heart rate: " .. math.Round(hr) .. " bpm")
		elseif hr < 60 then
			add("bradycardia", math.Clamp((60 - hr) / 40, 0.15, 1), "Bradycardia", nil, "Heart rate: " .. math.Round(hr) .. " bpm")
		end
	end
	if Num(org.heart) > 0.1 then add("heart", Num(org.heart), "Heart damage") end
	if Num(org.hypotension) > 0.2 then add("pressure_low", Num(org.hypotension), "Low blood pressure") end
	if Num(org.hypertension) > 0.2 then add("pressure_high", Num(org.hypertension), "High blood pressure") end

	-- лёгкие и кислород
	if org.lungsfunction == false then add("lung_failure", 1, "Lung failure") end
	if Num(org.pneumothorax) > 0.05 or Num(org.lungsL) > 0.3 or Num(org.lungsR) > 0.3 then
		add("lungs", math.max(Num(org.pneumothorax), Num(org.lungsL), Num(org.lungsR)), "Lung damage")
	end
	local o2 = Num(org.o2)
	if o2 > 0 and o2 < 20 then add("hypoxia", (20 - o2) / 20, "Hypoxia") end
	if Num(org.CO) > 0.1 then add("gas", Num(org.CO) / 4, "Carbon monoxide") end

	-- температура и сосуды (modules/sv_vessels.lua)
	local temperature = Num(org.temperature)
	if temperature > 38 then
		add("hot", (temperature - 38) / 2.5, "Fever / overheating")
	elseif temperature > 0 and temperature < 33.5 then
		add("freezing", (35.5 - temperature) / 4, "Hypothermia")
	elseif temperature > 0 and temperature < 35.5 then
		add("cold", (35.5 - temperature) / 3, "Cold")
	end
	if ply:IsOnFire() then add("burning", 1, "Burning") end
	local vessels = ply:GetNW2Float("rem_vessels", 0)
	if vessels < -0.4 then add("vessels_narrow", -vessels, "Constricted vessels") end
	if vessels > 0.4 then add("vessels_wide", vessels, "Dilated vessels") end

	-- органы, вещества, настроение
	if Num(org.liver) > 0.2 then add("liver", Num(org.liver), "Liver damage") end
	local bac = ply:GetNW2Float("rem_bac", 0)
	if bac > 0.3 then add("alcohol", bac / 3, string.format("Drunk (%.1f‰)", bac)) end
	local bacEff = ply:GetNW2Float("rem_bac_eff", bac)
	local nausea = ply:GetNW2Float("rem_nausea", 0)
	if Num(org.wantToVomit) > 0.3 or nausea > 0.2 or bacEff > 2.2 then add("nausea", math.max(Num(org.wantToVomit), nausea, (bacEff - 2.2) / 1.5), "Nausea") end
	if Num(org.analgesia) > 0.3 then add("painkillers", Num(org.analgesia), "Painkillers") end
	if Num(org.adrenaline) > 0.5 then add("adrenaline", Num(org.adrenaline) / 2, "Adrenaline") end
	if org.noradrenalineActive then add("haste", 0.45, "Noradrenaline") end
	if org.berserkActive2 then add("rage", 0.6, "Rage") end
	-- ярость (modules/sv_rage.lua): своя плитка на каждую стадию, с описанием
	local rageStage = ply:GetNW2Int("rem_rage_stage", 0)
	local rageInfo = RAGE_STAGES[rageStage]
	if rageInfo then add("anger", rageInfo[1], rageInfo[2], false, rageInfo[3]) end
	local panic = ply:GetNW2Float("rem_panic", 0)
	for i = #PANIC_STAGES, 1, -1 do
		local s = PANIC_STAGES[i]
		if panic >= s[1] then add("panic", s[2], s[3], false, s[4]) break end
	end
	local fear = Num(org.fear)
	if fear > 0.3 then add("fear", fear, "Fear") end
	local depression = Num(org.depression)
	if depression > 0.25 then add("depression", depression, "Depression") end
	local assimilated = Num(org.assimilated)
	if assimilated > 0 then add("infection", assimilated, "Infection") end

	-- никотин, привыкание и ломка (modules/sv_nicotine.lua, sv_addiction.lua)
	local nic = ply:GetNW2Float("rem_nicotine", 0)
	if nic > 0.2 then add("nicotine", nic / 2.5, "Nicotine") end
	-- наркотики (modules/sv_drugs.lua): «Веселье» и передоз
	local high = ply:GetNW2Float("rem_high", 0)
	if high > 0.05 then
		local h, m, l = ply:GetNW2Float("rem_heroin", 0), ply:GetNW2Float("rem_meth", 0), ply:GetNW2Float("rem_lsd", 0)
		local od = h > 1.8 and "Heroin overdose - can't breathe" or m > 2.5 and "Meth overdose - heart racing" or l > 2 and "Bad trip" or nil
		local what = {}
		if h > 0.05 then what[#what + 1] = "heroin" end
		if m > 0.05 then what[#what + 1] = "meth" end
		if l > 0.05 then what[#what + 1] = "LSD" end
		add("euphoria", od and 1 or high * 0.6, od or "High", not od, "Fun. On " .. table.concat(what, ", ") .. ".")
	end
	for _, kind in ipairs({"nicotine", "alcohol", "heroin", "meth"}) do
		local name = ({nicotine = "Nicotine", alcohol = "Alcohol", heroin = "Heroin", meth = "Meth"})[kind]
		local wd, dep = ply:GetNW2Float("rem_wd_" .. kind, 0), ply:GetNW2Float("rem_dep_" .. kind, 0)
		if wd > 0.1 then
			add(kind .. "_wd", wd, name .. " withdrawal")
		elseif dep > 0.25 then
			add(kind .. "_wd", 0.12, string.format("%s dependence (%d%%)", name, math.Round(dep * 100)))
		end
	end
	local tremor = ply:GetNW2Float("rem_wd_alcohol", 0)
	if tremor > 0.3 then add("tremor", tremor, "Tremor") end

	-- движение и силы
	if org.incapacitated then add("incapacitated", 1, "Incapacitated") end
	if org.canmove == false or Num(org.immobilization) > 0 then add("immobilized", 0.65, "Immobilized") end
	local stamina = Num(org.stamina)
	if stamina > 0 and stamina < 50 then add("fatigue", (50 - stamina) / 50, "Exhausted") end

	-- порядок появления: новые - в конец, сердце - первое
	for _, e in ipairs(icons) do
		if not iconOrder[e.name] then
			iconOrderSeq = iconOrderSeq + 1
			iconOrder[e.name] = iconOrderSeq
		end
	end
	table.sort(icons, function(a, b) return iconOrder[a.name] < iconOrder[b.name] end)
	return icons
end

local gradDown = Material("vgui/gradient-d")
-- как в Fading Vitality: тяжёлые плитки приподняты над рядом (чем тяжелее - тем выше) и над ними горит красный
-- столб свечения, тающий кверху, со слабым знаком тревоги; все плитки мелко трясутся рывками (тяжёлые - сильнее)
local gradUp = Material("vgui/gradient-u")
-- зерно плиток - тот же пиксельный шум, что у таймера смерти (крупные пиксели, без smooth)
local tileGrain = {}
for i = 1, 4 do tileGrain[i] = Material("rem_death/vortex_static" .. i .. ".png") end
local LIFT_START = 0.45                   -- с какой тяжести плитка поднимается
local LIFT_MAX = 0.55                     -- на сколько плиток поднимается самая тяжёлая
local GLOW_HEIGHT = 1.7                   -- высота столба свечения (в плитках) у самой тяжёлой
local SHAKE_LIGHT, SHAKE_HEAVY = 0.6, 2.6 -- тряска, пикселей
local SHAKE_RATE = 18                     -- раз в секунду меняется положение (рывками)
local warnIcon

local function Shake(idx, timeNow, amp)
	local step = math.floor(timeNow * SHAKE_RATE)
	local sx = math.sin(step * 12.9898 + idx * 78.233) * 43758.5453
	local sy = math.sin(step * 39.346 + idx * 11.135) * 24634.6345
	return (sx - math.floor(sx) - 0.5) * 2 * amp, (sy - math.floor(sy) - 0.5) * 2 * amp
end

local function DrawAfflictionIcons(iconEntries, x0, bottomY, visibility, appearTime, timeNow, org)
	if #iconEntries == 0 or visibility <= 0.01 then return end
	warnIcon = warnIcon or Material("rem_affl/critical.png", "smooth mips")

	local tile = math.max(math.floor(ScreenScaleFixed(25)), 22)
	local spacing = math.max(math.floor(ScreenScaleFixed(2.5)), 2)
	local border = math.max(math.floor(tile / 26), 1)
	local horizontalSpace = ScrW() - x0 - ScreenScaleFixed(ICONS_SCREEN_EDGE_MARGIN)
	local maxPerRow = math.max(1, math.floor((horizontalSpace + spacing) / (tile + spacing)))
	local rows = math.ceil(#iconEntries / maxPerRow)
	local appearFrac = math.Clamp((timeNow - appearTime) / 0.3, 0, 1)
	local alphaMul = visibility
	local cursor = vgui.CursorVisible()
	local mx, my = input.GetCursorPos()
	local hovered

	for row = 1, rows do
		local rowStart = (row - 1) * maxPerRow + 1
		local rowCount = math.min(maxPerRow, #iconEntries - rowStart + 1)
		local y = bottomY - row * tile - (row - 1) * spacing + (1 - appearFrac) * tile * 0.6
		if y < 0 then break end

		for col = 1, rowCount do
			local idx = rowStart + col - 1
			local e = iconEntries[idx]
			local sev = e.severity
			-- место в ряду; к нему плитка скользит (освободилось место ближе к сердцу - идёт туда)
			local targetX = (col - 1) * (tile + spacing)
			local cur = tileSlotX[e.name]
			if cur == nil or math.abs(cur - targetX) > tile * 8 then cur = targetX end
			cur = math.Approach(cur, targetX, FrameTime() * (tile + spacing) / SLIDE_TIME)
			tileSlotX[e.name] = cur
			local x = math.floor(x0 + cur)
			-- тяжёлые подняты, все трясутся рывками
			local lift = 0
			if sev > LIFT_START and not e.good then
				local k = (sev - LIFT_START) / (1 - LIFT_START)
				lift = tile * LIFT_MAX * k * k * (3 - 2 * k)
			end
			local sx, sy = Shake(idx, timeNow, Lerp(sev, SHAKE_LIGHT, SHAKE_HEAVY))
			x = math.floor(x + sx * alphaMul)
			local yy = math.floor(y - lift * alphaMul + sy * alphaMul)

			-- столб красного свечения над поднятой плиткой
			if lift > 1 then
				local k = lift / (tile * LIFT_MAX)
				local gh = tile * GLOW_HEIGHT * k
				local flick = 0.85 + math.sin(timeNow * 9 + idx * 2.3) * 0.1 + math.sin(timeNow * 23 + idx) * 0.05
				surface.SetMaterial(gradUp)
				surface.SetDrawColor(255, 20, 20, math.floor(200 * flick * k * alphaMul))
				surface.DrawTexturedRect(x - 1, yy - gh, tile + 2, gh + tile * 0.5)
				if warnIcon then
					local ws = tile * 0.6
					surface.SetMaterial(warnIcon)
					surface.SetDrawColor(255, 120, 120, math.floor(55 * k * flick * alphaMul))
					surface.DrawTexturedRect(x + (tile - ws) / 2, yy - gh * 0.6 - ws / 2, ws, ws)
				end
			end
			-- тяжёлые чуть пульсируют яркостью
			local pulse = sev > 0.7 and (math.sin(timeNow * (3 + sev * 4) + idx) * 0.5 + 0.5) * 0.25 * sev or 0
			local a = math.floor(235 * alphaMul)

			-- фон: снизу тёмный, сверху ярче; цвет от тяжести (импланты - синие)
			if e.good then
				surface.SetDrawColor(6, 18, 40, a)
				surface.DrawRect(x, yy, tile, tile)
				surface.SetMaterial(gradDown)
				surface.SetDrawColor(30, 110, 190, a)
				surface.DrawTexturedRect(x, yy, tile, tile)
			else
				-- как в Fading Vitality: почти чёрная плитка, снизу наливается красным по тяжести, сверху грязное зерно
				surface.SetDrawColor(12 + 20 * sev, 3, 3, a)
				surface.DrawRect(x, yy, tile, tile)
				surface.SetMaterial(gradDown)
				surface.SetDrawColor(math.min(255, 40 + 150 * sev + 40 * pulse), 5 + 8 * sev, 5 + 8 * sev, math.floor(a * (0.45 + 0.5 * sev)))
				surface.DrawTexturedRect(x, yy, tile, tile)
				if tileGrain[1] and not tileGrain[1]:IsError() then
					surface.SetMaterial(tileGrain[(idx + math.floor(timeNow * 6)) % 4 + 1])
					surface.SetDrawColor(120, 40, 40, math.floor(a * 0.18))
					surface.DrawTexturedRectUV(x, yy, tile, tile, (idx * 0.13) % 1, 0, (idx * 0.13) % 1 + 0.12, 0.2)
				end
			end

			-- рамка
			if e.good then
				surface.SetDrawColor(90, 180, 240, a)
			elseif sev >= 0.9 then
				surface.SetDrawColor(255, 255, 255, a)
			else
				-- бледно-розовая рамка, у тяжёлых светлее
				surface.SetDrawColor(170 + 70 * sev, 110 + 60 * sev, 110 + 60 * sev, a)
			end

			surface.DrawOutlinedRect(x, yy, tile, tile, border)

			-- значок (сердце - бьётся с пульсом)
			local pad = math.floor(tile * 0.1)
			local isz = tile - pad * 2
			if e.name == "pulse" and org then
				local beat = (math.sin(org.pulsethink or 0) + 1) * 0.5
				local grow = math.floor(tile * 0.14 * beat * beat)
				pad, isz = pad - grow * 0.5, isz + grow
			end
			surface.SetMaterial(e.mat)
			surface.SetDrawColor(255, 235 + 20 * sev, 235 + 20 * sev, math.floor(255 * alphaMul))
			surface.DrawTexturedRect(x + pad, yy + pad, isz, isz)

			if cursor and mx >= x and mx <= x + tile and my >= yy and my <= yy + tile then
				hovered = {e.label, x + tile * 0.5, yy, e.desc}
			end
		end
	end

	-- подпись под курсором (когда курсор виден - меню, чат, контекст)
	-- с описанием - название сверху, ниже строки описания (серые)
	if hovered then
		surface.SetFont("HomigradFontSmall")
		local lines = {hovered[1]}
		if hovered[4] then
			for line in string.gmatch(hovered[4], "[^\n]+") do lines[#lines + 1] = line end
		end
		local tw, th = 0, 0
		for _, line in ipairs(lines) do
			local w, h = surface.GetTextSize(line)
			tw, th = math.max(tw, w), math.max(th, h)
		end
		local bh = th * #lines + 4
		local tx, ty = hovered[2] - tw * 0.5 - 6, hovered[3] - bh - 6
		tx = math.Clamp(tx, 2, ScrW() - tw - 14)
		surface.SetDrawColor(10, 0, 0, 220)
		surface.DrawRect(tx, ty, tw + 12, bh)
		surface.SetDrawColor(200, 60, 60, 255)
		surface.DrawOutlinedRect(tx, ty, tw + 12, bh, 1)
		for i, line in ipairs(lines) do
			if i == 1 then surface.SetTextColor(255, 255, 255, 255) else surface.SetTextColor(200, 200, 200, 255) end
			surface.SetTextPos(tx + 6, ty + 2 + (i - 1) * th)
			surface.DrawText(line)
		end
	end
end

-- обновляет масштаб костей: перелом/вывих - кость красная на blinkModel, отрубленная - исчезает и мигает 5 с
local function UpdateLimbStates(org, time)
	for limb, boneName in pairs(limbBones) do
		local isAmputated = org[limb .. "amputated"]
		local isBroken = Num(org[limb]) >= 1
		local isDislocated = org[limb .. "dislocation"]

		limbStates[limb] = limbStates[limb] or {amputated = false, blinking = false, blinkEnd = 0, fractured = false}
		local state = limbStates[limb]
		local ampBoneName = amputationBones[limb] or boneName

		if state.amputated and not isAmputated then
			state.amputated = false
			state.blinking = false
			ScaleBoneByName(healthModel, ampBoneName, vector_one)
			ScaleBoneByName(blinkModel, ampBoneName, vector_zero)
		end

		if state.fractured and (isAmputated or not (isBroken or isDislocated)) then
			state.fractured = false
			if not state.amputated then
				ScaleBoneByName(blinkModel, boneName, vector_zero)
				ScaleBoneByName(healthModel, boneName, vector_one)
			end
		end

		if isAmputated then
			if not state.amputated then
				state.amputated = true
				state.blinking = true
				state.blinkEnd = time + BLINK_DURATION
				ScaleBoneByName(healthModel, ampBoneName, vector_zero)
				ScaleBoneByName(blinkModel, ampBoneName, BLINK_SCALE)
			end

			if state.blinking and time > state.blinkEnd then
				state.blinking = false
				ScaleBoneByName(blinkModel, ampBoneName, vector_zero)
			end
		elseif (isBroken or isDislocated) and not state.fractured then
			state.fractured = true
			ScaleBoneByName(blinkModel, boneName, BLINK_SCALE)
			ScaleBoneByName(healthModel, boneName, vector_zero)
		end
	end
end

-- рисует blinkModel красным, временно скрывая кости другого вида мигания
local function DrawBlinkPass(modelOffset, val, hideKey, hideBones)
	if hideKey then
		for l, s in pairs(limbStates) do
			if s[hideKey] then ScaleBoneByName(blinkModel, hideBones[l] or limbBones[l], vector_zero) end
		end
	end

	render.SetColorModulation(val, 0, 0)
	blinkModel:SetPos(modelOffset)
	blinkModel:SetAngles(angle_zero)
	blinkModel:SetupBones()
	blinkModel:DrawModel()

	if hideKey then
		for l, s in pairs(limbStates) do
			if s[hideKey] then ScaleBoneByName(blinkModel, hideBones[l] or limbBones[l], BLINK_SCALE) end
		end
	end
end

hook.Add("HUDPaint", "rem_health_indicator", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local alive = ply:Alive()
	if lastLifeState ~= alive then
		ResetModels()
		ResetIconOrder()
		lastLifeState = alive
		if not alive then HI.Shown = false end
	end

	if not alive or gui.IsGameUIVisible() then return end

	local org = ply.organism
	local otrub = org and org.otrub
	local otrubView = otrub and cvOtrubInspect:GetBool()
	local shown = (HI.Shown and not otrub) or otrubView

	if not currentX then currentX = ScreenScaleFixed(POS_HIDDEN_X) end
	currentX = Lerp(FrameTime() * 2, currentX, ScreenScaleFixed(shown and POS_VISIBLE_X or POS_HIDDEN_X))

	local time = CurTime()

	if shown then
		cachedAfflictionIcons = CollectAfflictionIcons(ply, org)
		if not iconsTargetVisible then iconsAppearTime = time end
	end
	iconsVisibility = Lerp(FrameTime() * 10, iconsVisibility, shown and 1 or 0)
	iconsTargetVisible = shown

	if iconsVisibility > 0.01 and #cachedAfflictionIcons > 0 then
		-- ряд начинается справа от панели с силуэтом (слева внизу, как в Fading Vitality)
		local panelRight = currentX + ScreenScaleFixed(BACKDROP_OFFSET_X) + ScreenScaleFixed(IND_SIZE) * 0.92
		local x0 = math.max(panelRight + ScreenScaleFixed(10), ScreenScaleFixed(ICONS_SCREEN_EDGE_MARGIN))
		DrawAfflictionIcons(cachedAfflictionIcons, x0, ScrH() - ScreenScaleFixed(ICONS_SCREEN_MARGIN_Y), iconsVisibility, iconsAppearTime, time, org)
	elseif not shown and iconsVisibility <= 0.01 then
		cachedAfflictionIcons = {}
		ResetIconOrder()
	end

	-- совсем уехал за край - модели не трогаем
	if not shown and currentX <= ScreenScaleFixed(POS_HIDDEN_X) + 2 then return end

	local mdl = ply:GetModel()
	if not IsValid(healthModel) then healthModel = CreateModel(mdl) end
	if not IsValid(blinkModel) then
		blinkModel = CreateModel(mdl)
		InitBlinkModel(blinkModel)
	end

	if healthModel:GetModel() ~= mdl then
		healthModel:SetModel(mdl)
		blinkModel:SetModel(mdl)
		SetIdlePose(healthModel)
		SetIdlePose(blinkModel)
		InitBlinkModel(blinkModel)
		limbStates = {}
		RemoveAccessories(healthModel)
	end

	if org then UpdateLimbStates(org, time) end

	local w, h = ScreenScaleFixed(IND_SIZE), ScreenScaleFixed(IND_SIZE)
	local y = ScrH() - h - ScreenScaleFixed(20)

	local backdropX = currentX + ScreenScaleFixed(BACKDROP_OFFSET_X)
	local backdropY = y + ScreenScaleFixed(BACKDROP_OFFSET_Y)
	-- ЭКГ-монитор (cl_ecg.lua) - верхняя часть той же панели: общий фон и рамка, тонкий разделитель
	local ecgOn = hg.ECG and hg.ECG.Draw and hg.ECG.cv:GetBool()
	local monH = ecgOn and math.floor(w * 0.46) or 0
	surface.SetDrawColor(colBackdrop)
	surface.DrawRect(backdropX, backdropY - monH, w * 0.92, h * 0.92 + monH)
	surface.SetDrawColor(colOutline)
	surface.DrawOutlinedRect(backdropX, backdropY - monH, w * 0.92, h * 0.92 + monH, 1)
	if ecgOn then
		surface.SetDrawColor(colOutline.r, colOutline.g, colOutline.b, colOutline.a * 0.5)
		surface.DrawRect(backdropX + 1, backdropY, w * 0.92 - 2, 1)
		-- панель заходит за левый край экрана на BACKDROP_OFFSET_X - монитор рисуем только в видимой части
		local hidden = -ScreenScaleFixed(BACKDROP_OFFSET_X)
		hg.ECG.Draw(backdropX + hidden, backdropY - monH, w * 0.92 - hidden, monH, org, 1)
	end

	local camPos = Vector(95, 0, 65)
	local camRenderX = currentX + ScreenScaleFixed(SILHOUETTE_OFFSET_X)
	local viewY = y + ScreenScaleFixed(SILHOUETTE_OFFSET_Y)
	local modelOffset = Vector(0, 0, 0)

	-- вьюпорт не может начинаться левее экрана: сдвигаем саму модель
	if camRenderX < 0 then
		local unitsPerPixel = 2 * camPos.x * math.tan(math.rad(50) / 2) / h
		modelOffset.y = camRenderX * unitsPerPixel
		camRenderX = 0
	end

	cam.Start3D(camPos, Angle(11, 180, 0), 50, camRenderX, viewY, w, h)
		render.SuppressEngineLighting(true)
		render.MaterialOverride(whiteMat)

		local col = math.Clamp(org and org.consciousness or 1, 0, 1)
		if otrubView then col = math.max(col, otrub_silhouette_min) end
		render.SetColorModulation(col, col, col)

		healthModel:SetPos(modelOffset)
		healthModel:SetAngles(angle_zero)
		for i = 0, ply:GetNumBodyGroups() - 1 do
			healthModel:SetBodygroup(i, ply:GetBodygroup(i))
		end
		healthModel:SetSkin(ply:GetSkin())
		healthModel:SetupBones()
		healthModel:DrawModel()

		DrawHealthAccessories(healthModel, ply)

		local hasAmputationBlink, hasFractureBlink = false, false
		for _, state in pairs(limbStates) do
			if state.blinking then hasAmputationBlink = true end
			if state.fractured then hasFractureBlink = true end
		end

		if hasAmputationBlink then
			DrawBlinkPass(modelOffset, (math.sin(time * 10) + 1) / 2, hasFractureBlink and "fractured", limbBones)
		end
		if hasFractureBlink then
			DrawBlinkPass(modelOffset, (math.sin(time * FRACTURE_BLINK_SPEED) + 1) / 2, hasAmputationBlink and "blinking", amputationBones)
		end

		render.MaterialOverride(nil)
		render.SetColorModulation(1, 1, 1)
		render.SuppressEngineLighting(false)
	cam.End3D()

	-- в отключке всё это еле видно: поверх - темнота, медленно сгущается и отступает. Сверху вниз она нарастает
	-- плавно (полосами по 1/48 высоты) - без резкого края: прямоугольник давал линию поперёк экрана
	if otrubView then
		local k = (math.sin(time * math.pi * 2 / otrub_dim_period) + 1) / 2
		local alpha = 255 * Lerp(k, otrub_dim_min, otrub_dim_max)
		local sw, sh = ScrW(), ScrH()
		local top, fade = sh * 0.3, sh * 0.3 -- с 30% высоты темнота нарастает, с 60% - полная
		local strips = 48
		local stripH = fade / strips
		for i = 0, strips - 1 do
			surface.SetDrawColor(0, 0, 0, alpha * (i + 0.5) / strips)
			surface.DrawRect(0, math.floor(top + i * stripH), sw, math.ceil(stripH) + 1)
		end
		surface.SetDrawColor(0, 0, 0, alpha)
		surface.DrawRect(0, math.floor(top + fade), sw, sh - math.floor(top + fade))
	end
end)

hook.Add("ShutDown", "rem_health_indicator", ResetModels)
