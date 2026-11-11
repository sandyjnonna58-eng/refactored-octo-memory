-- Кровь из отрубленной конечности (sv_severedlimbs.lua): капли Z-City (hg.addBloodPart) из среза - начала кости
-- конечности (колено / локоть), по направлению из среза. Первые секунды льёт сильно, к концу (rem_limb_bleed) капает.
local limbs = {}
local BLEED_TIME = 45
local nextScan, nextDrip = 0, 0

hook.Add("Think", "rem_severed_limbs_blood", function()
	local now = CurTime()
	if now >= nextScan then
		nextScan = now + 0.5
		limbs = {}
		for _, e in ipairs(ents.FindByClass("prop_ragdoll")) do
			if e:GetNW2Bool("rem_limb", false) and e:GetNW2Float("rem_limb_bleed", 0) > now then limbs[#limbs + 1] = e end
		end
	end
	if now < nextDrip or not hg.addBloodPart then return end
	nextDrip = now + 0.05
	for _, e in ipairs(limbs) do
		if IsValid(e) and not e:IsDormant() then
			local left = e:GetNW2Float("rem_limb_bleed", 0) - now
			local k = math.Clamp(left / BLEED_TIME, 0, 1)
			if left > 0 and math.random() < 0.15 + k * 0.85 then
				local m = e:GetBoneMatrix(e:GetNW2Int("rem_limb_bone", 0))
				if m then
					local out = -m:GetAngles():Forward() -- кость смотрит от среза к кисти/стопе
					local vel = e:GetVelocity() * 0.5 + out * (20 + 60 * k * k) + VectorRand(-10, 10)
					local size = 1.2 + k * 1.3
					hg.addBloodPart(m:GetTranslation() + out, vel, nil, size, size, k > 0.6, false, e)
				end
			end
		end
	end
end)
