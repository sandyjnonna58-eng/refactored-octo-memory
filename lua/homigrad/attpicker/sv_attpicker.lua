hg.AttPicker = hg.AttPicker or {}
local AP = hg.AttPicker

util.AddNetworkString("rem_attpicker_install")

local install_cooldown = 0.6
-- через сколько убрать из инвентаря выданный обвес, если поставить его не вышло
local leftover_check = 1.5

local function CountInInventory(ply, att)
	local count = 0
	for _, owned in ipairs(ply.inventory.Attachments) do
		if owned == att then count = count + 1 end
	end
	return count
end

net.Receive("rem_attpicker_install", function(len, ply)
	if (ply.attPickerNext or 0) > CurTime() then return end
	ply.attPickerNext = CurTime() + install_cooldown

	local att = net.ReadString()
	local wep = ply:GetActiveWeapon()
	if not ply:Alive() or not IsValid(wep) or not ishgweapon(wep) or not istable(wep.attachments) then return end
	if not AP.CanMount(wep, att) then return end
	if not istable(ply.inventory) then return end

	local placement = AP.Placement(att)
	local current = wep.attachments[placement]
	if istable(current) and current[1] == att then return end

	-- слот занят: обвес бесплатный, поэтому старый просто снимаем
	if istable(current) and not table.IsEmpty(current) and current[1] ~= "empty" then
		local slot = wep.availableAttachments[placement]
		if slot.cannotremove then
			ply:ChatPrint("This attachment can't be removed.")
			return
		end

		local empty
		for _, entry in pairs(slot) do
			if istable(entry) and entry[1] == "empty" then empty = entry end
		end
		wep.attachments[placement] = empty or {}
		wep:SyncAtts()
	end

	-- обычная установка сборки берёт обвес из инвентаря - кладём его туда
	ply.inventory.Attachments = ply.inventory.Attachments or {}
	local before = CountInInventory(ply, att)
	ply.inventory.Attachments[#ply.inventory.Attachments + 1] = att

	hg.AddAttachment(ply, wep, att)

	timer.Simple(leftover_check, function()
		if not IsValid(ply) or not istable(ply.inventory) or not istable(ply.inventory.Attachments) then return end
		if CountInInventory(ply, att) <= before then return end

		table.RemoveByValue(ply.inventory.Attachments, att)
		ply:SetNetVar("Inventory", ply.inventory)
	end)
end)
