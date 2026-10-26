-- Индикатор здоровья (из MELEECITY): слева снизу выезжает белый силуэт твоего персонажа,
-- сломанные/вывихнутые конечности мигают красным, отрубленные исчезают, силуэт темнеет вместе с сознанием.
-- По центру снизу - иконки состояний (materials/sef_icons): раны, кровотечение, сотрясение, переломы и т.д.
-- Включается пунктом "Afflictions" в радиальном меню или командой rem_afflictions (можно забиндить).
hg.HealthIndicator = hg.HealthIndicator or {}
local HI = hg.HealthIndicator

local whiteMat = Material("models/debug/debugwhite")
local statusCircleMat = Material("sef_icons/statuseffectcircle.png", "smooth")
local statusIconCache = {}

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

HI.Shown = HI.Shown or false

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

local function GetStatusIcon(iconName)
	local cached = statusIconCache[iconName]
	if cached ~= nil then return cached or nil end

	local mat = Material("sef_icons/" .. iconName .. ".png", "smooth")
	statusIconCache[iconName] = not mat:IsError() and mat or false
	return statusIconCache[iconName] or nil
end

local function CollectAfflictionIcons(ply, org)
	local icons, seen = {}, {}
	local function add(iconName, severity)
		severity = math.Clamp(severity or 0.5, 0.05, 1)
		if seen[iconName] then
			seen[iconName].severity = math.max(seen[iconName].severity, severity)
			return
		end
		local mat = GetStatusIcon(iconName)
		if not mat then return end
		local entry = {mat = mat, severity = severity}
		seen[iconName] = entry
		icons[#icons + 1] = entry
	end

	if not org then return icons end

	local wounds = ply.wounds or ply:GetNetVar("wounds")
	local arterialwounds = ply.arterialwounds or ply:GetNetVar("arterialwounds")
	local woundsCount = istable(wounds) and #wounds or 0
	local arterialCount = istable(arterialwounds) and #arterialwounds or 0

	if woundsCount > 0 then add("open-wound", woundsCount / 6) end
	if arterialCount > 0 then add("deepwound", 0.7 + arterialCount * 0.2) end

	local bleed = Num(org.bleed)
	if bleed > 0 then add("bleed", bleed / 8) end

	local hasBrokenLimb = Num(org.lleg) >= 1 or Num(org.rleg) >= 1 or Num(org.larm) >= 1 or Num(org.rarm) >= 1
	local hasDislocation = org.llegdislocation or org.rlegdislocation or org.larmdislocation or org.rarmdislocation or org.jawdislocation
	local hasAmputation = org.llegamputated or org.rlegamputated or org.larmamputated or org.rarmamputated or org.headamputated
	if hasBrokenLimb or hasDislocation or hasAmputation then
		add("vuln", hasAmputation and 1 or (hasDislocation and 0.65 or 0.5))
	end

	if Num(org.skull) >= 1 then add("broken", 1) end

	local concussion = Num(org.concussion)
	if concussion > 0 then add("concussion", concussion) end

	local brain = Num(org.brain)
	if brain > 0.05 then add("exposed", brain / 0.6) end

	if org.seizureActive then add("discharge", 1) end
	if org.blindness then add("blind", 0.7) end

	local assimilated = Num(org.assimilated)
	if assimilated > 0 then add("wither", assimilated) end

	if org.incapacitated then add("incap", 1) end
	if org.berserkActive2 then add("bloodlust", 0.45) end
	if org.noradrenalineActive then add("haste", 0.45) end
	if Num(org.adrenaline) > 0.5 then add("endurance", Num(org.adrenaline) / 2) end
	if Num(org.analgesia) > 0.3 then add("healing-shield", Num(org.analgesia)) end

	local depression = Num(org.depression)
	if depression > 0.25 then add("anagenthasdied", depression) end

	local fear = Num(org.fear)
	if fear > 0.3 then add("darkvision", fear) end

	if org.critical then add("warning", 1) end

	if org.canmove == false or Num(org.immobilization) > 0 then add("hindered", 0.65) end

	local pain, shock = Num(org.pain), Num(org.shock)
	if pain > 60 or shock > 0.5 then add("stunned", math.max(pain / 120, shock)) end

	if Num(org.CO) > 0.1 then add("poison-gas", Num(org.CO) / 4) end

	local o2 = Num(org.o2)
	if o2 > 0 and o2 < 20 then add("exhaust", (20 - o2) / 20) end

	local stamina = Num(org.stamina)
	if stamina > 0 and stamina < 50 then add("fatigue", (50 - stamina) / 50) end

	local temperature = Num(org.temperature)
	if temperature > 39 then
		add("discharge", (temperature - 39) / 2)
	elseif temperature > 0 and temperature < 34.5 then
		add("frozen", (34.5 - temperature) / 3)
	end

	return icons
end

local function DrawAfflictionIcons(iconEntries, centerX, bottomY, visibility, appearTime, timeNow)
	if #iconEntries == 0 or visibility <= 0.01 then return end

	local iconSize = math.max(math.floor(ScreenScaleFixed(26)), 18)
	local bgSize = math.max(math.floor(iconSize * 1.35), iconSize + 8)
	local spacing = math.max(math.floor(ScreenScaleFixed(2)), 1)
	local horizontalSpace = ScrW() - ScreenScaleFixed(ICONS_SCREEN_EDGE_MARGIN) * 2
	local maxPerRow = math.max(1, math.floor((horizontalSpace + spacing) / (bgSize + spacing)))
	local rows = math.ceil(#iconEntries / maxPerRow)
	local appearFrac = math.Clamp((timeNow - appearTime) / 0.35, 0, 1)
	local shakeMul = (1 - appearFrac) * visibility
	local baseAlpha = math.floor(255 * visibility)

	for row = 1, rows do
		local rowStart = (row - 1) * maxPerRow + 1
		local rowCount = math.min(maxPerRow, #iconEntries - rowStart + 1)
		local rowWidth = rowCount * bgSize + (rowCount - 1) * spacing
		local x = centerX - rowWidth * 0.5
		local y = bottomY - row * bgSize - (row - 1) * spacing
		if y < 0 then break end

		for col = 1, rowCount do
			local idx = rowStart + col - 1
			local entry = iconEntries[idx]
			local severity = entry.severity
			local pulse = 1 + math.sin(timeNow * (4 + severity * 9) + idx * 1.4) * (0.05 + severity * 0.08) * visibility
			local shakeAmp = ScreenScaleFixed(2 + severity * 2) * shakeMul
			local cx = x + (col - 1) * (bgSize + spacing) + bgSize * 0.5 + math.sin(timeNow * (95 + idx * 7)) * shakeAmp
			local cy = y + bgSize * 0.5 + math.cos(timeNow * (110 + idx * 9)) * shakeAmp
			local bgDrawSize = bgSize * pulse
			local iconDrawSize = iconSize * pulse

			surface.SetMaterial(statusCircleMat)
			surface.SetDrawColor(8, 8, 8, math.floor((160 + severity * 95) * visibility))
			surface.DrawTexturedRect(cx - bgDrawSize * 0.5, cy - bgDrawSize * 0.5, bgDrawSize, bgDrawSize)

			surface.SetMaterial(entry.mat)
			surface.SetDrawColor(255, 255, 255, baseAlpha)
			surface.DrawTexturedRect(cx - iconDrawSize * 0.5, cy - iconDrawSize * 0.5, iconDrawSize, iconDrawSize)
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
		lastLifeState = alive
		if not alive then HI.Shown = false end
	end

	if not alive or gui.IsGameUIVisible() then return end

	local org = ply.organism
	local otrub = org and org.otrub
	local shown = HI.Shown and not otrub

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
		DrawAfflictionIcons(cachedAfflictionIcons, ScrW() * 0.5, ScrH() - ScreenScaleFixed(ICONS_SCREEN_MARGIN_Y), iconsVisibility, iconsAppearTime, time)
	elseif not shown and iconsVisibility <= 0.01 then
		cachedAfflictionIcons = {}
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
	surface.SetDrawColor(colBackdrop)
	surface.DrawRect(backdropX, backdropY, w * 0.92, h * 0.92)
	surface.SetDrawColor(colOutline)
	surface.DrawOutlinedRect(backdropX, backdropY, w * 0.92, h * 0.92, 1)

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
end)

hook.Add("ShutDown", "rem_health_indicator", ResetModels)
