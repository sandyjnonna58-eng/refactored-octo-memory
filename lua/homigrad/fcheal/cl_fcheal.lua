-- Лечение как в Far Cry - клиент: F отправляет просьбу полечиться (сервер сам решает, можно ли)
hg = hg or {}
hg.FCHeal = hg.FCHeal or {}

local wasF = false
local nextSend = 0
hook.Add("Think", "rem_fcheal_key", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local free = not ply:IsTyping() and not gui.IsGameUIVisible() and not gui.IsConsoleVisible() and not IsValid(vgui.GetKeyboardFocus())
	local f = free and input.IsKeyDown(KEY_F)
	if f and not wasF and CurTime() > nextSend and ply:Alive() then
		nextSend = CurTime() + 0.3
		net.Start("rem_fcheal")
		net.SendToServer()
	end
	wasF = f
end)

-- руки лечения от первого лица: в homigrad своё тело рисуется от первого лица (drawviewer), а при этом движок
-- не показывает обычный viewmodel - поэтому модель рук с анимацией FC рисуется здесь сама, перед камерой,
-- с руками игрока (c_arms) через bonemerge
local FH = hg.FCHeal
local VM_FOV = 80
local vm, hands

local function Clear()
	if IsValid(vm) then vm:Remove() end
	if IsValid(hands) then hands:Remove() end
	vm, hands = nil, nil
end

local function HandsInfo(ply)
	local info = player_manager.TranslatePlayerHands(player_manager.TranslateToPlayerModelName(ply:GetModel()))
	if not info or not info.model or info.model == "" then
		info = {model = "models/weapons/c_arms_citizen.mdl", skin = 0, body = "0000000"}
	end
	return info
end

hook.Add("PostDrawTranslucentRenderables", "rem_fcheal_hands", function(depth, sky)
	if depth or sky then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or GetViewEntity() ~= ply or not ply:Alive() or not ply:GetNW2Bool("rem_fcheal", false) then
		if vm then Clear() end
		return
	end
	local data = FH.Kinds and FH.Kinds[ply:GetNW2String("rem_fcheal_kind", "")]
	if not data then return end

	if not IsValid(vm) or vm:GetModel() ~= data.model then
		Clear()
		vm = ClientsideModel(data.model, RENDERGROUP_OPAQUE)
		if not IsValid(vm) then return end
		vm:SetNoDraw(true)
		vm:SetPlaybackRate(0)
		local info = HandsInfo(ply)
		hands = ClientsideModel(info.model, RENDERGROUP_OPAQUE)
		if IsValid(hands) then
			hands:SetNoDraw(true)
			hands:SetSkin(info.matchBodySkin and ply:GetSkin() or info.skin or 0)
			hands:SetBodyGroups(info.body or "")
			hands:SetParent(vm)
			hands:AddEffects(EF_BONEMERGE)
		end
	end

	local seq = vm:LookupSequence(ply:GetNW2String("rem_fcheal_seq", ""))
	if not seq or seq < 0 then seq = 0 end
	if vm:GetSequence() ~= seq then vm:ResetSequence(seq) vm:SetPlaybackRate(0) end
	local dur = math.max(vm:SequenceDuration(seq), 0.1)
	vm:SetCycle(math.Clamp((CurTime() - ply:GetNW2Float("rem_fcheal_start", CurTime())) / dur, 0, 1))

	local pos, ang = EyePos(), EyeAngles()
	cam.Start3D(pos, ang, VM_FOV, 0, 0, ScrW(), ScrH(), 1, 2048)
		render.ClearDepth()
		vm:SetPos(pos)
		vm:SetAngles(ang)
		vm:InvalidateBoneCache()
		vm:SetupBones()
		vm:DrawModel()
		if IsValid(hands) then
			hands:InvalidateBoneCache()
			hands:SetupBones()
			hands:DrawModel()
		end
	cam.End3D()
end)
