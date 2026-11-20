if SERVER then AddCSLuaFile() end
-- Амиодарон (как в SCAV Prototype): антиаритмик. Пока действует (org.remAmioT, 150 с на шприц, до 300), фибрилляция
-- снимается на 2% в секунду сверх обычного спада (organism/tier_1/modules/sv_pulse.lua) - аритмия, желудочковая
-- тахикардия и фибрилляция уходят, даже если причина ещё есть. Остановившееся сердце не заводит (нужен дефибриллятор,
-- эпинефрин или СЛР). Шприц и вид - от налоксона Z-City (weapon_naloxone). ЛКМ - себе, ПКМ - другому.
SWEP.Base = "weapon_naloxone"
SWEP.PrintName = "Amiodarone"
SWEP.Instructions = "An antiarrhythmic. Brings an irregular heartbeat back to normal over time: arrhythmia, ventricular tachycardia and fibrillation. Does not restart a stopped heart. RMB to inject into someone else."
SWEP.Category = "ZCity Medicine"
SWEP.Spawnable = true
SWEP.modeNames = {
	[1] = "amiodarone"
}

local AMIO_TIME, AMIO_MAX = 150, 300

if SERVER then
	function SWEP:Heal(ent, mode)
		if ent:IsNPC() then return end

		local org = ent.organism
		if not org then return end

		local owner = self:GetOwner()
		local healanims = GetConVar("hg_healanims")
		if ent == hg.GetCurrentCharacter(owner) and healanims and healanims:GetBool() then
			self:SetHolding(math.min(self:GetHolding() + 4, 100))

			if self:GetHolding() < 100 then return end
		end

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		entOwner:EmitSound("snd_jack_hmcd_needleprick.wav", 60, math.random(95, 105))

		org.remAmioT = math.min((org.remAmioT or 0) + AMIO_TIME * self.modeValues[1], AMIO_MAX)
		self.modeValues[1] = 0

		owner:SelectWeapon("weapon_hands_sh")
		self:Remove()
	end
end
