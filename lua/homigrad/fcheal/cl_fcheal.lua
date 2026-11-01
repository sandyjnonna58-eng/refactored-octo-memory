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
