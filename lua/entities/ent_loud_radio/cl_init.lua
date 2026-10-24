include("shared.lua")

-- басы трясут экран и бьют радиальным размытием от радио (FFT по низким частотам)
local bass_bins_from, bass_bins_to = 2, 6
local bass_peak_mul = 1.35
local bass_min = 0.04
local bass_hit_gap = 0.12

local fft = {}

function ENT:OnRadioPlaying(station)
	local ply = LocalPlayer()
	if not ply:Alive() then return end

	local dist = ply:GetPos():Distance(self:GetPos())
	if dist > self.CalmRange then return end

	station:FFT(fft, FFT_256)
	local bass = 0
	for i = bass_bins_from, bass_bins_to do bass = bass + (fft[i] or 0) end

	self.bassAvg = Lerp(0.05, self.bassAvg or bass, bass)

	if bass > bass_min and bass > self.bassAvg * bass_peak_mul and (self.nextBassHit or 0) < CurTime() then
		self.nextBassHit = CurTime() + bass_hit_gap

		local frac = 1 - dist / self.CalmRange
		local hit = math.min((bass - self.bassAvg) * 8, 1) * frac
		if hg.RemFX and hg.RemFX.Kick then hg.RemFX.Kick(hit * 1.3, self:WorldSpaceCenter()) end
		util.ScreenShake(ply:GetPos(), 6 * hit, 25, 0.15, 0)
	end
end
