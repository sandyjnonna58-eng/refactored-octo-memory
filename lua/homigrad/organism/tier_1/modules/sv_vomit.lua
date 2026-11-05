-- Обычная рвота (не кровью): от алкоголя, ломки, перекура. hg.organism.Vomit из сборки - рвота кровью при внутреннем
-- кровотечении (минус кровь, красные брызги), её не трогаем.
-- Тошнота копится в org.nausea (0..1, AddNausea); на 1 - рвёт: желтовато-бурая струя изо рта (cl_vomit.lua),
-- лужи на полу, звук, на пару секунд замедляет; если лежит без сознания на спине - может захлебнуться (как в сборке).
-- Клиенту - NW2 "rem_nausea" (значок тошноты в осмотре).
util.AddNetworkString("rem_vomit")

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

	local female = ThatPlyIsFemale and ThatPlyIsFemale(ent)
	ent:EmitSound("zcitysnd/real_sonar/" .. (female and "female" or "male") .. "_cough" .. math.random(4) .. ".mp3", 65)
	if not onSpine then ent:EmitSound("vomit/vomit5.mp3", 70, math.random(95, 108)) end

	if not onSpine then
		net.Start("rem_vomit")
		net.WriteEntity(ent)
		net.WriteFloat(1.4)
		net.Broadcast()
	end
	if org.isPly and not org.otrub and owner.Notify then owner:Notify(table.Random(phrases), true, "vomit", 0) end
end

function hg.organism.AddNausea(owner, org, amount)
	if not org or amount <= 0 then return end
	org.nausea = math.min((org.nausea or 0) + amount, 1)
	if org.nausea >= 1 then
		hg.organism.VomitNormal(owner)
	elseif IsValid(owner) and owner:IsPlayer() then
		local r = math.Round(org.nausea, 1)
		if r ~= org.nauseaSent then
			org.nauseaSent = r
			owner:SetNW2Float("rem_nausea", r)
		end
	end
end
