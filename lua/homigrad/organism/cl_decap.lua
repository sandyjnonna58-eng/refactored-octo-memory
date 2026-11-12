-- Отрезанная голова на клиенте (сервер - sv_decap.lua).
-- 1) Все кости, кроме головы, сжимаем в ОДНУ точку - у среза (колбэк BuildBonePositions ставит им нулевую матрицу
--    в начале кости головы). Просто ManipulateBoneScale 0 так не умеет: каждая кость сжимается в своё начало, и кожа
--    между ними тянется чёрными плоскими треугольниками.
-- 2) Плоскость отсечения у самой головы (SetRenderClipPlane, едет с костью головы): всё ниже основания головы не
--    рисуется - иначе воротник (его вершины привязаны и к голове, и к шее) торчит лоскутами вокруг головы.
-- 3) Кровь: капли Z-City (hg.addBloodPart) из шеи, сначала льёт, к концу (rem_head_bleed) капает.
local BLEED_TIME = 40
local CLIP_BELOW = 2 -- насколько ниже начала кости головы режем (подбородок не задеть)
local ZERO = Vector(0, 0, 0)

local function Collect(ent, bone, out)
	out[bone] = true
	for _, c in ipairs(ent:GetChildBones(bone) or {}) do
		if not out[c] then Collect(ent, c, out) end
	end
end

local function Collapse(e)
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

local function Setup(e)
	local root = e:GetNW2Int("rem_head_bone", -1)
	if root < 0 or e.remCollapseRoot == root then return end
	local keep, hidden = {}, {}
	Collect(e, root, keep)
	for b = 0, e:GetBoneCount() - 1 do
		if not keep[b] then hidden[#hidden + 1] = b end
	end
	e.remCollapseRoot, e.remCollapseHidden = root, hidden
	if not e.remCollapseCB then e.remCollapseCB = e:AddCallback("BuildBonePositions", Collapse) end
end

local heads = {}
local nextScan, nextDrip = 0, 0

hook.Add("Think", "rem_decap_heads", function()
	local now = CurTime()
	-- плоскость отсечения - каждый кадр за костью головы
	for _, e in ipairs(heads) do
		if IsValid(e) and not e:IsDormant() then
			local m = e:GetBoneMatrix(e:GetNW2Int("rem_head_bone", 0))
			if m then
				local up = m:GetAngles():Forward() -- кость головы смотрит к макушке
				local p = m:GetTranslation() - up * CLIP_BELOW
				e:SetRenderClipPlaneEnabled(true)
				e:SetRenderClipPlane(up, up:Dot(p))
			end
		end
	end
	if now >= nextScan then
		nextScan = now + 0.5
		heads = {}
		for _, e in ipairs(ents.FindByClass("prop_ragdoll")) do
			if e:GetNW2Bool("rem_head", false) then
				Setup(e)
				heads[#heads + 1] = e
			end
		end
	end
	if now < nextDrip or not hg.addBloodPart then return end
	nextDrip = now + 0.05
	for _, e in ipairs(heads) do
		local left = IsValid(e) and e:GetNW2Float("rem_head_bleed", 0) - now or 0
		if left > 0 and not e:IsDormant() then
			local k = math.Clamp(left / BLEED_TIME, 0, 1)
			if math.random() < 0.15 + k * 0.85 then
				local m = e:GetBoneMatrix(e:GetNW2Int("rem_head_bone", 0))
				if m then
					local out = -m:GetAngles():Forward() -- кость головы смотрит к макушке, срез - снизу
					local vel = e:GetVelocity() * 0.5 + out * (20 + 50 * k * k) + VectorRand(-10, 10)
					local size = 1.2 + k * 1.3
					hg.addBloodPart(m:GetTranslation() + out, vel, nil, size, size, k > 0.6, false, e)
				end
			end
		end
	end
end)

-- новая голова - сжать сразу, не дожидаясь скана
hook.Add("NetworkEntityCreated", "rem_decap_heads", function(e)
	if not IsValid(e) or e:GetClass() ~= "prop_ragdoll" then return end
	timer.Simple(0, function()
		if IsValid(e) and e:GetNW2Bool("rem_head", false) then Setup(e) end
	end)
end)
