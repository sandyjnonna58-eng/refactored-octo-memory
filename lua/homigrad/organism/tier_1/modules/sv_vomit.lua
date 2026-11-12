-- Обычная рвота (не кровью): от алкоголя, ломки, перекура. hg.organism.Vomit из сборки - рвота кровью при внутреннем
-- кровотечении (минус кровь, красные брызги), её не трогаем.
-- Тошнота копится в org.nausea (0..1, AddNausea); на 1 - рвёт: желтовато-бурая струя изо рта (cl_vomit.lua),
-- лужи на полу, звук, на пару секунд замедляет; если лежит без сознания на спине - может захлебнуться (как в сборке).
-- Клиенту - NW2 "rem_nausea" (значок тошноты в осмотре).
util.AddNetworkString("rem_vomit")
resource.AddSingleFile("sound/rem_puke.wav")

local phrases = {
	"I'm gonna be sick...",
	"Ugh... my stomach...",
	"*retches*",
}

function hg.organism.VomitNormal(owner)
	if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then return end
	local org = owner.organism
	if not org then return end
	local ent = hg.GetCurrentCharacter and hg.GetCurrentCharacter(owner) or owner
	if not IsValid(ent) then return end

	local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
	local mat = bone and ent:GetBoneMatrix(bone)
	if not mat then return end

	-- лицом вверх без сознания - рвота в горле (захлебнуться)
	local onSpine = mat:GetAngles():Right()[3] > 0.25
	if onSpine then org.vomitInThroat = true end

	owner:SetNetVar("vomiting", CurTime() + 1.5)
	org.nausea = 0
	owner:SetNW2Float("rem_nausea", 0)
	-- выблеванное уже не всосётся
	if org.alcoholStomach then org.alcoholStomach = org.alcoholStomach * 0.3 end
	org.painadd = (org.painadd or 0) + 2

	if onSpine then
		-- на спине - давится, а не выплёвывает
		local female = ThatPlyIsFemale and ThatPlyIsFemale(ent)
		ent:EmitSound("zcitysnd/real_sonar/" .. (female and "female" or "male") .. "_cough" .. math.random(4) .. ".mp3", 65)
	else
		ent:EmitSound("rem_puke.wav", 70, math.random(96, 104))
	end

	if not onSpine then
		net.Start("rem_vomit")
		net.WriteEntity(ent)
		net.WriteFloat(1.4)
		net.Broadcast()
	end
	if org.isPly and not org.otrub and owner.Notify then owner:Notify(table.Random(phrases), true, "vomit", 0) end
end

-- стадии тошноты - мысль при переходе (подкатывает -> сейчас вырвет)
local stageThoughts = {
	[1] = {"My stomach is turning...", "Ugh... I feel queasy...", "Something's not right with my stomach..."},
	[2] = {"I'm going to throw up...", "Oh no... here it comes...", "Can't... hold it..."},
}

function hg.organism.AddNausea(owner, org, amount)
	if not org or amount <= 0 then return end
	org.nausea = math.min((org.nausea or 0) + amount, 1)
	local stage = org.nausea >= 0.8 and 2 or org.nausea >= 0.45 and 1 or 0
	if stage > (org.nauseaStage or 0) and org.isPly and not org.otrub and IsValid(owner) and owner.Notify then
		owner:Notify(table.Random(stageThoughts[stage]), true, "rem_nausea_stage", 0)
	end
	org.nauseaStage = stage
	if org.nausea >= 1 then
		org.nauseaStage = 0
		hg.organism.VomitNormal(owner)
	elseif IsValid(owner) and owner:IsPlayer() then
		local r = math.Round(org.nausea, 1)
		if r ~= org.nauseaSent then
			org.nauseaSent = r
			owner:SetNW2Float("rem_nausea", r)
		end
	end
end

-- вызвать рвоту самому (кнопка "Vomit" в C-меню - cl_vomit.lua): два пальца в рот
local VOMIT_COOLDOWN = 20
concommand.Add("rem_vomit", function(ply)
	if not IsValid(ply) or not ply:Alive() then return end
	local org = ply.organism
	if not org or org.otrub or (ply.rem_vomit_next or 0) > CurTime() then return end
	ply.rem_vomit_next = CurTime() + VOMIT_COOLDOWN
	hg.organism.VomitNormal(ply)
end)

-- тошнота сама понемногу проходит (раз в секунду), если её ничего не подпитывает
local NAUSEA_DECAY = 0.003
timer.Create("rem_nausea_decay", 1, 0, function()
	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		if org and (org.nausea or 0) > 0 and ply:Alive() then
			org.nausea = math.max(org.nausea - NAUSEA_DECAY, 0)
			org.nauseaStage = org.nausea >= 0.8 and 2 or org.nausea >= 0.45 and 1 or 0
			local r = math.Round(org.nausea, 1)
			if r ~= org.nauseaSent then
				org.nauseaSent = r
				ply:SetNW2Float("rem_nausea", r)
			end
		end
	end
end)
