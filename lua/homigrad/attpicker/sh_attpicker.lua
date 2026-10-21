-- Меню выбора обвесов: все обвесы, которые подходят к оружию в руках, ставятся бесплатно, без инвентаря.
hg.AttPicker = hg.AttPicker or {}
local AP = hg.AttPicker

-- порядок и названия разделов меню (mount - служебные крепления, их ставит само оружие)
AP.Placements = {
	{"sight", "Sights"},
	{"barrel", "Muzzle"},
	{"grip", "Grips"},
	{"underbarrel", "Underbarrel"},
	{"magwell", "Magazines"},
	{"agsmag", "Drums"},
}

function AP.Placement(att)
	for plc, tbl in pairs(hg.attachments) do
		if istable(tbl[att]) then return tbl[att][1] end
	end
end

local function IsPickable(att)
	return hg.IsValidAtt(att) and not (string.find(att, "empty", 1, true) or string.find(att, "mount", 1, true))
end

-- та же проверка, что в hg.AddAttachment: слот есть, обвес в явном списке или подходит тип крепления
function AP.CanMount(wep, att)
	if not IsValid(wep) or not istable(wep.availableAttachments) or not IsPickable(att) then return false end

	local placement = AP.Placement(att)
	local slot = placement and wep.availableAttachments[placement]
	if not istable(slot) or not istable(hg.attachments[placement]) then return false end

	local listed = false
	for _, entry in pairs(slot) do
		if istable(entry) and entry[1] == att then listed = true end
	end

	local mountType = slot.mountType
	local attMountType = hg.attachments[placement][att].mountType
	if not listed and not (mountType or attMountType) then return false end

	return (istable(mountType) and table.HasValue(mountType, attMountType)) or mountType == attMountType
end

function AP.GetMountable(wep)
	local result = {}
	for _, info in ipairs(AP.Placements) do
		local list = {}
		for att in pairs(hg.attachments[info[1]] or {}) do
			if AP.CanMount(wep, att) then list[#list + 1] = att end
		end

		table.sort(list)
		if #list > 0 then result[#result + 1] = {placement = info[1], name = info[2], list = list} end
	end

	return result
end
