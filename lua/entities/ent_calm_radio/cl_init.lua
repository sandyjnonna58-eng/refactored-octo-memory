include("shared.lua")

-- музыку играет каждый клиент сам: 3D-звук от радио, по кругу; если файла нет - запасной трек
local tracks = {"sound/music/radio1.mp3", "sound/music/hl1_song10.mp3"}
local fade_near, fade_far = 150, 900

local function Play(self, index)
	local path = tracks[index]
	if not path then return end

	self.radioLoading = true
	sound.PlayFile(path, "3d noblock noplay", function(station)
		if not IsValid(self) then
			if IsValid(station) then station:Stop() end
			return
		end
		self.radioLoading = false

		if not IsValid(station) then
			Play(self, index + 1)
			return
		end
		if not self:GetOn() then station:Stop() return end

		self.radioStation = station
		station:SetPos(self:GetPos())
		station:Set3DFadeDistance(fade_near, fade_far)
		station:EnableLooping(true)
		station:Play()
	end)
end

function ENT:Think()
	local station = self.radioStation

	if self:GetOn() then
		if IsValid(station) then
			station:SetPos(self:GetPos())
			station:SetVolume(GetConVar("snd_musicvolume"):GetFloat() * 0.8 + 0.2)
		elseif not self.radioLoading then
			Play(self, 1)
		end
	elseif IsValid(station) then
		station:Stop()
		self.radioStation = nil
	end

	self:SetNextClientThink(CurTime() + 0.1)
	return true
end

function ENT:OnRemove()
	if IsValid(self.radioStation) then self.radioStation:Stop() end
end
