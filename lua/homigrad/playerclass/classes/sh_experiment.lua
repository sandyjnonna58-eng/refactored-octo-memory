-- Эксперимент: жёлтая кровь; переломы, позвоночник и шея не обездвиживают - двигаться можно, но больно.
local CLASS = player.RegClass("experiment")

-- Expie лежит в сборке (models/akittu/stylizedexpie), Milky - только если стоит его аддон.
-- Модель, скин и аксессуары игрок выбирает в меню (открывается, когда становишься экспериментом, и по !skin)
local models = {
	{model = "models/akittu/stylizedexpie/akittuexpie.mdl", name = "Expie"},
	{model = "models/akittu/stylizedexpie/akittuexpiev3.mdl", name = "Expie V3"},
	{model = "models/akittu/stylizedmilky/akittumilky.mdl", name = "Milky"},
	{model = "models/akittu/stylizedmilky/akittumilky3dmouth.mdl", name = "Milky (3D mouth)"},
}
CLASS.Models = models

local role_color = Color(230, 190, 0)

-- боль в секунду за каждую сломанную часть при движении на полной скорости
local move_pain_per_fracture = 4
local move_pain_speed = 200

CLASS.NoGloves = true
CLASS.YellowBlood = true
CLASS.FractureTolerance = true

function hg.HasYellowBlood(ent)
	if not IsValid(ent) then return false end
	if ent:GetNWBool("hg_yellowblood", false) then return true end

	if ent:IsRagdoll() and hg.RagdollOwner then
		local owner = hg.RagdollOwner(ent)
		return IsValid(owner) and owner ~= ent and owner:GetNWBool("hg_yellowblood", false)
	end

	return false
end

local function GiveHands(ply)
	if not ply:Alive() then return end

	local class = hg.GetHandsWeaponClass(ply)
	for _, other in ipairs({"weapon_hands_sh", "weapon_hg_coolhands"}) do
		if other ~= class and ply:HasWeapon(other) then ply:StripWeapon(other) end
	end

	if not ply:HasWeapon(class) then ply:Give(class) end
	ply:SelectWeapon(class)
end

function CLASS.Off(self)
	if CLIENT then return end

	-- класс уже сменился - вернуть руки нового класса
	timer.Simple(0, function()
		if IsValid(self) then GiveHands(self) end
	end)

	self:SetNWBool("hg_yellowblood", false)
	self.bloodColorHitFix = BLOOD_COLOR_RED
	if hg.Mutations and hg.Mutations.Clear then hg.Mutations.Clear(self) end
end

-- аксессуары: те же правила, что в меню внешности - до 3 штук, по одной на слот
CLASS.MaxAccessories = 3
CLASS.AccessorySlots = {"head", "face", "ears", "spine", "torso"}

-- можно ли надеть: есть в списке, не запрещён во внешности, платный - только если куплен
function CLASS.CanUseAccessory(ply, uid)
	local data = hg.Accessories and hg.Accessories[uid]
	if not data or uid == "none" or not data.model or data.disallowinappearance then return false end

	local shopItem = hg.PointShop and hg.PointShop.Items and hg.PointShop.Items[uid]
	if not shopItem then return true end
	if hg.Appearance and hg.Appearance.GetAccessToAll and hg.Appearance.GetAccessToAll(ply) then return true end

	local ok, has = pcall(ply.PS_HasItem, ply, uid)
	return ok and has and true or false
end

local function FilterAccessories(ply, list)
	local out, used = {}, {}
	for _, uid in ipairs(istable(list) and list or {}) do
		local data = hg.Accessories and hg.Accessories[uid]
		if #out < CLASS.MaxAccessories and CLASS.CanUseAccessory(ply, uid) and not used[data.placement or uid] then
			used[data.placement or uid] = true
			out[#out + 1] = uid
		end
	end
	return out
end

local function SetExperimentModel(ply, index, skin, accessories)
	ply:SetModel(models[index].model)
	ply:SetSkin(math.Clamp(skin, 0, math.max(ply:SkinCount() - 1, 0)))
	local claws = ply:FindBodygroupByName("Claws")
	if claws >= 0 then ply:SetBodygroup(claws, 1) end
	ply:SetSubMaterial()

	local list = FilterAccessories(ply, accessories)
	ply:SetNetVar("Accessories", #list > 0 and list or "")
	return list
end

function CLASS.On(self)
	if CLIENT then return end

	self:SetNWBool("hg_yellowblood", true)
	self.bloodColorHitFix = BLOOD_COLOR_YELLOW

	if zb.GiveRole then zb.GiveRole(self, "Experiment", role_color) end
	GiveHands(self)

	local valid = {}
	for i, entry in ipairs(models) do
		if util.IsValidModel(entry.model) then valid[#valid + 1] = i end
	end

	if #valid == 0 then
		ApplyAppearance(self)
		self:ChatPrint("Experiment: Expie model is not installed, using a normal model.")
		return
	end

	ApplyAppearance(self, nil, nil, nil, true)
	local Appearance = self.CurAppearance or hg.Appearance.GetRandomAppearance()
	Appearance.AAttachments = ""
	Appearance.AColthes = ""

	-- прошлый выбор игрока, иначе случайно; потом меню, чтобы поменять
	local choice = self.experimentSkinChoice
	if choice and util.IsValidModel(models[choice.index] and models[choice.index].model or "") then
		SetExperimentModel(self, choice.index, choice.skin, choice.accessories)
	else
		SetExperimentModel(self, valid[math.random(#valid)], 0)
		self:SetSkin(math.random(0, math.max(self:SkinCount() - 1, 0)))
	end
	self.CurAppearance = Appearance

	timer.Simple(0.5, function()
		if IsValid(self) and self.PlayerClassName == "experiment" then
			net.Start("rem_experiment_skin_menu")
			net.Send(self)
		end
	end)
end

local function brokenParts(org)
	local count = 0
	if org.lleg >= 1 then count = count + 1 end
	if org.rleg >= 1 then count = count + 1 end
	if org.pelvis >= 1 then count = count + 1 end
	if org.spine1 >= hg.organism.fake_spine1 then count = count + 1 end
	if org.spine2 >= hg.organism.fake_spine2 then count = count + 1 end
	if org.spine3 >= hg.organism.fake_spine3 then count = count + 1 end
	return count
end

function CLASS.Think(self, time, dtime)
	if CLIENT then return end

	local org = self.organism
	if not org or not org.alive or org.otrub or not dtime then return end

	local broken = brokenParts(org)
	if broken == 0 then return end

	local char = hg.GetCurrentCharacter(self)
	local speed = IsValid(char) and char:GetVelocity():Length2D() or 0
	if speed < 20 then return end

	org.painadd = org.painadd + dtime * broken * move_pain_per_fracture * math.min(speed / move_pain_speed, 1.5)
end

if SERVER then
	util.AddNetworkString("rem_experiment_skin_menu")
	util.AddNetworkString("rem_experiment_skin")

	net.Receive("rem_experiment_skin", function(len, ply)
		local index = net.ReadUInt(4)
		local skin = net.ReadUInt(8)
		local accessories = {}
		for i = 1, math.min(net.ReadUInt(3), CLASS.MaxAccessories) do accessories[i] = net.ReadString() end

		if not ply:Alive() or ply.PlayerClassName ~= "experiment" then return end
		if (ply.experimentSkinNext or 0) > CurTime() then return end
		ply.experimentSkinNext = CurTime() + 0.5

		local entry = models[index]
		if not entry or not util.IsValidModel(entry.model) then return end
		-- в рэгдолле модель не меняем, иначе тело и игрок разъедутся
		if IsValid(ply.FakeRagdoll) then
			ply:Notify("Get up first.", 0, "experiment_skin", 2)
			return
		end

		local worn = SetExperimentModel(ply, index, skin, accessories)
		ply.experimentSkinChoice = {index = index, skin = ply:GetSkin(), accessories = worn}
	end)

	COMMANDS = COMMANDS or {}
	COMMANDS.skin = {function(ply)
		if ply.PlayerClassName ~= "experiment" then ply:ChatPrint("Only experiments can change their skin.") return end

		net.Start("rem_experiment_skin_menu")
		net.Send(ply)
	end, 0}

	-- труп тоже истекает жёлтой кровью
	hook.Add("RagdollDeath", "hg_experiment_yellowblood", function(ply, ragdoll)
		if IsValid(ragdoll) and IsValid(ply) and ply:GetNWBool("hg_yellowblood", false) then
			ragdoll:SetNWBool("hg_yellowblood", true)
		end
	end)

	-- у мёртвого Expie глаза закрыты (живым моргание делает hg.mouthmove)
	hook.Add("RagdollDeath", "hg_experiment_closeeyes", function(ply, ragdoll)
		if not IsValid(ragdoll) then return end

		local blinks = ragdoll:GetFlexIDByName("Blinks")
		if blinks then ragdoll:SetFlexWeight(blinks, 1) end
	end)

	return
end

-- у части крови нет владельца (брызги от попаданий), её красим по ближайшему эксперименту
local yellow_radius_sqr = 90 * 90
local yellowSources = {}
local nextScan = 0

hook.Add("Think", "hg_experiment_yellowblood", function()
	if CurTime() < nextScan then return end
	nextScan = CurTime() + 0.5

	yellowSources = {}
	for _, ply in player.Iterator() do
		if ply:Alive() and ply:GetNWBool("hg_yellowblood", false) then
			yellowSources[#yellowSources + 1] = hg.GetCurrentCharacter(ply)
		end
	end

	for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
		if rag:GetNWBool("hg_yellowblood", false) then yellowSources[#yellowSources + 1] = rag end
	end
end)

function hg.IsYellowBloodAt(owner, pos)
	if IsValid(owner) then return hg.HasYellowBlood(owner) end
	if not pos then return false end

	for i = 1, #yellowSources do
		local ent = yellowSources[i]
		if IsValid(ent) and ent:WorldSpaceCenter():DistToSqr(pos) < yellow_radius_sqr then return true end
	end

	return false
end

-- меню выбора модели и скина (стиль hg.RemUI)
local skinMenu

local function OpenSkinMenu()
	if IsValid(skinMenu) then skinMenu:Remove() end

	local UI = hg.RemUI
	if not UI then return end
	local U = UI.U
	local ply = LocalPlayer()

	local available = {}
	for i, entry in ipairs(models) do
		if util.IsValidModel(entry.model) then available[#available + 1] = i end
	end
	if #available == 0 then return end

	-- начинаем с того, что сейчас на игроке
	local index, skin = available[1], ply:GetSkin()
	for _, i in ipairs(available) do
		if models[i].model == ply:GetModel() then index = i end
	end

	-- надетые сейчас аксессуары
	local worn = {}
	local current = ply:GetNetVar("Accessories", "")
	for _, uid in ipairs(istable(current) and current or {}) do
		if hg.Accessories and hg.Accessories[uid] then worn[#worn + 1] = uid end
	end

	local function IsWorn(uid)
		for _, v in ipairs(worn) do if v == uid then return true end end
		return false
	end

	local frame = UI.Frame(ScrW() * 0.72, ScrH() * 0.7, "EXPERIMENT", "Choose your body and accessories")
	skinMenu = frame

	local preview = vgui.Create("DModelPanel", frame)
	preview:Dock(LEFT)
	preview:SetWide(ScrW() * 0.22)
	preview:SetFOV(30)

	local function UpdatePreview()
		preview:SetModel(models[index].model)
		local ent = preview:GetEntity()
		if not IsValid(ent) then return end

		skin = math.Clamp(skin, 0, math.max(ent:SkinCount() - 1, 0))
		ent:SetSkin(skin)
		local claws = ent:FindBodygroupByName("Claws")
		if claws >= 0 then ent:SetBodygroup(claws, 1) end

		local mins, maxs = ent:GetRenderBounds()
		local center = (mins + maxs) / 2
		preview:SetLookAt(center)
		preview:SetCamPos(center + Vector(maxs.z * 1.9, 0, maxs.z * 0.1))
	end
	preview.LayoutEntity = function(self, ent) ent:SetAngles(Angle(0, CurTime() * 30 % 360, 0)) end

	-- аксессуары на превью: тот же рисовальщик, что у превью внешности в главном меню
	preview.PostDrawModel = function(self, ent)
		if not DrawAccesories then return end
		for _, uid in ipairs(worn) do
			local data = hg.Accessories[uid]
			if data then DrawAccesories(ent, ent, uid, data, false, true) end
		end
		ent:SetupBones()
	end
	-- свой OnRemove заменяет стандартный, поэтому модель превью удаляем сами
	preview.OnRemove = function(self)
		local ent = self.Entity
		if not IsValid(ent) then return end
		for k, v in pairs(ent.modelAccess or {}) do
			if IsValid(v) then v:Remove() end
			ent.modelAccess[k] = nil
		end
		ent:Remove()
	end

	-- колонка аксессуаров: по слотам, до 3 штук, по одному на слот
	local accCol = vgui.Create("DPanel", frame)
	accCol:Dock(RIGHT)
	accCol:SetWide(ScrW() * 0.22)
	accCol:DockMargin(U(14), 0, 0, 0)
	accCol.Paint = nil

	local accHeader = vgui.Create("DPanel", accCol)
	accHeader:Dock(TOP)
	accHeader:SetTall(U(30))
	accHeader.Paint = function(self, w, h)
		draw.SimpleText("Accessories  " .. #worn .. " / " .. CLASS.MaxAccessories, "RemUI_Small", 0, h / 2, UI.White, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local clear = UI.TextButton(accCol, "remove all", {
		font = "RemUI_Tiny",
		canClick = function() return #worn > 0 end,
		onClick = function() worn = {} end,
	})
	clear:Dock(TOP)

	local accScroll = vgui.Create("DScrollPanel", accCol)
	accScroll:Dock(FILL)
	UI.StyleScroll(accScroll)

	local function Toggle(uid)
		if IsWorn(uid) then
			for k, v in ipairs(worn) do if v == uid then table.remove(worn, k) break end end
			return
		end

		-- тот же слот - заменяем, иначе добавляем, если есть место
		local placement = hg.Accessories[uid].placement
		for k, v in ipairs(worn) do
			if hg.Accessories[v].placement == placement then
				worn[k] = uid
				return
			end
		end

		if #worn >= CLASS.MaxAccessories then
			surface.PlaySound("buttons/button10.wav")
			return
		end
		worn[#worn + 1] = uid
	end

	local slotNames = {head = "Head", face = "Face", ears = "Ears", spine = "Back", torso = "Torso"}
	for _, slot in ipairs(CLASS.AccessorySlots) do
		local list = {}
		for uid, data in pairs(hg.Accessories or {}) do
			if data.placement == slot and CLASS.CanUseAccessory(ply, uid) then list[#list + 1] = uid end
		end
		table.sort(list, function(a, b) return (hg.Accessories[a].name or a) < (hg.Accessories[b].name or b) end)

		if #list > 0 then
			local header = accScroll:Add("DPanel")
			header:Dock(TOP)
			header:DockMargin(0, U(8), 0, U(2))
			header:SetTall(U(22))
			header.Paint = function(self, w, h)
				draw.SimpleText(slotNames[slot] or slot, "RemUI_Tiny", 0, h / 2, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				surface.SetDrawColor(UI.Line)
				surface.DrawRect(0, h - 1, w - U(8), 1)
			end

			for _, uid in ipairs(list) do
				local btn = UI.TextButton(accScroll, hg.Accessories[uid].name or uid, {
					font = "RemUI_Tiny",
					color = function() return IsWorn(uid) and UI.White or UI.TextDim end,
					onClick = function() Toggle(uid) end,
				})
				btn:Dock(TOP)
				btn:DockMargin(U(6), 0, 0, 0)
				btn.PaintOver = function(self, w, h)
					if not IsWorn(uid) then return end
					surface.SetDrawColor(UI.Accent)
					surface.DrawRect(0, U(4), U(2), h - U(8))
				end
			end
		end
	end

	local side = vgui.Create("DPanel", frame)
	side:Dock(FILL)
	side:DockMargin(U(14), 0, 0, 0)
	side.Paint = nil

	local function Header(text)
		local label = vgui.Create("DPanel", side)
		label:Dock(TOP)
		label:DockMargin(0, U(8), 0, U(4))
		label:SetTall(U(26))
		label.Paint = function(self, w, h)
			draw.SimpleText(isfunction(text) and text() or text, "RemUI_Small", 0, h / 2, UI.White, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end

	Header("Model")
	for _, i in ipairs(available) do
		local btn = UI.TextButton(side, models[i].name, {
			color = function() return index == i and UI.White or UI.TextDim end,
			onClick = function()
				index = i
				skin = 0
				UpdatePreview()
			end,
		})
		btn:Dock(TOP)
		btn.PaintOver = function(self, w, h)
			if index ~= i then return end
			surface.SetDrawColor(UI.Accent)
			surface.DrawRect(0, U(6), U(2), h - U(12))
		end
	end

	local function SkinCount()
		local ent = preview:GetEntity()
		return IsValid(ent) and math.max(ent:SkinCount(), 1) or 1
	end

	Header(function() return "Skin  " .. (skin + 1) .. " / " .. SkinCount() end)

	local skinRow = vgui.Create("DPanel", side)
	skinRow:Dock(TOP)
	skinRow:SetTall(U(40))
	skinRow.Paint = nil

	local prev = UI.TextButton(skinRow, "<  previous", {onClick = function()
		skin = (skin - 1) % SkinCount()
		UpdatePreview()
	end})
	prev:Dock(LEFT)

	local nextBtn = UI.TextButton(skinRow, "next  >", {onClick = function()
		skin = (skin + 1) % SkinCount()
		UpdatePreview()
	end})
	nextBtn:Dock(LEFT)
	nextBtn:DockMargin(U(20), 0, 0, 0)

	local apply = UI.TextButton(side, "Apply", {font = "RemUI_Medium", color = UI.Accent, onClick = function()
		net.Start("rem_experiment_skin")
			net.WriteUInt(index, 4)
			net.WriteUInt(skin, 8)
			net.WriteUInt(#worn, 3)
			for _, uid in ipairs(worn) do net.WriteString(uid) end
		net.SendToServer()
		frame:Close()
	end})
	apply:Dock(BOTTOM)

	local hint = vgui.Create("DPanel", side)
	hint:Dock(BOTTOM)
	hint:SetTall(U(22))
	hint.Paint = function(self, w, h)
		draw.SimpleText("You can change it later with !skin", "RemUI_Tiny", 0, h / 2, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	UpdatePreview()
end

net.Receive("rem_experiment_skin_menu", OpenSkinMenu)
