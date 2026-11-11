-- Отрубленная конечность на клиенте (сервер - sv_severedlimbs.lua).
-- 1) Спрятанные кости тела (всё, кроме конечности) сжимаем в ОДНУ точку - в начало конечности (колено / локоть):
--    hg.RemLimbCollapse ставит колбэк BuildBonePositions, который задаёт им нулевую матрицу в точке среза. Просто
--    ManipulateBoneScale 0 так не умеет: каждая кость сжимается в своё начало, и кожа между ними тянется чёрными
--    плоскими треугольниками, а на обычной (не регдолл) модели ноль у родителя гасит и саму конечность.
--    Тот же колбэк - у конечности в руке (weapon_rem_flesh).
-- 2) Кровь: капли Z-City (hg.addBloodPart) из среза, по направлению из среза; к концу (rem_limb_bleed) только капает.
local BLEED_TIME = 45
local ZERO = Vector(0, 0, 0)

local function Collect(ent, bone, out)
	out[bone] = true
	for _, c in ipairs(ent:GetChildBones(bone) or {}) do
		if not out[c] then Collect(ent, c, out) end
	end
end

local function CollapseCallback(e)
	local r = e.remCollapseRoot
	local m = r and e:GetBoneMatrix(r)
	if not m then return end
	local z = Matrix()
	z:SetTranslation(m:GetTranslation())
	z:SetAngles(m:GetAngles())
	z:Scale(ZERO)
	for _, b in ipairs(e.remCollapseHidden or {}) do
		if e:GetBoneMatrix(b) then e:SetBoneMatrix(b, z) end
	end
end

function hg.RemLimbCollapse(ent, root)
	if not IsValid(ent) or not root or root < 0 then return end
	if ent.remCollapseRoot == root and ent.remCollapseHidden then return end
	local keep = {}
	Collect(ent, root, keep)
	local hidden = {}
	for b = 0, ent:GetBoneCount() - 1 do
		if not keep[b] then hidden[#hidden + 1] = b end
	end
	ent.remCollapseRoot = root
	ent.remCollapseHidden = hidden
	if not ent.remCollapseCB then
		ent.remCollapseCB = ent:AddCallback("BuildBonePositions", CollapseCallback)
	end
end

local limbs, bleeding = {}, {}
local nextScan, nextDrip = 0, 0

hook.Add("Think", "rem_severed_limbs_blood", function()
	local now = CurTime()
	if now >= nextScan then
		nextScan = now + 0.5
		limbs, bleeding = {}, {}
		for _, e in ipairs(ents.FindByClass("prop_ragdoll")) do
			if e:GetNW2Bool("rem_limb", false) then
				limbs[#limbs + 1] = e
				hg.RemLimbCollapse(e, e:GetNW2Int("rem_limb_bone", -1))
				if e:GetNW2Float("rem_limb_bleed", 0) > now then bleeding[#bleeding + 1] = e end
			end
		end
	end
	if now < nextDrip or not hg.addBloodPart then return end
	nextDrip = now + 0.05
	for _, e in ipairs(bleeding) do
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

-- новая конечность - сжать сразу, не дожидаясь скана (иначе полсекунды видно всё тело)
hook.Add("NetworkEntityCreated", "rem_severed_limbs_collapse", function(e)
	if not IsValid(e) or e:GetClass() ~= "prop_ragdoll" then return end
	timer.Simple(0, function()
		if IsValid(e) and e:GetNW2Bool("rem_limb", false) then hg.RemLimbCollapse(e, e:GetNW2Int("rem_limb_bone", -1)) end
	end)
end)
