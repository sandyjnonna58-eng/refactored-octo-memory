-- Косой разрез тела (sv_meleehalve.lua -> sv_torsohalve.lua): у регдолла с NW2 "rem_cut" есть плоскость
-- разреза в осях кости (rem_cut_bone, едет вместе с телом). Рисуем в два прохода:
--   1) всё как обычно (hg.renderOverride: тело, одежда, аксессуары), но только по свою сторону плоскости;
--   2) по другую сторону - только само тело без туловища (кости туловища уводим в NaN - их треугольники
--      пропадают): так руки/ноги, оказавшиеся за плоскостью, не срезаются.
local TORSO = {"ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_Spine1",
	"ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Spine4"}
local NAN = Vector(0, 0, 0) / 0

local function Plane(ent)
	local bone = ent:GetNW2Int("rem_cut_bone", -1)
	if bone < 0 then return nil end
	local m = ent:GetBoneMatrix(bone)
	if not m then return nil end
	local pos, ang = m:GetTranslation(), m:GetAngles()
	local n = LocalToWorld(ent:GetNW2Vector("rem_cut_n", vector_up), angle_zero, vector_origin, ang)
	n:Normalize()
	n:Mul(ent:GetNW2Int("rem_cut_side", 1))
	local p = LocalToWorld(ent:GetNW2Vector("rem_cut_p", vector_origin), angle_zero, pos, ang)
	return n, n:Dot(p)
end

local function DrawCut(orig, self, ent, flags)
	local e = IsValid(ent) and ent or self
	if not IsValid(e) or not e:GetNW2Bool("rem_cut", false) or bit.band(flags, STUDIO_RENDER) ~= STUDIO_RENDER then
		return orig(self, ent, flags)
	end
	e:SetupBones()
	local n, d = Plane(e)
	if not n then return orig(self, ent, flags) end

	local oldClip = render.EnableClipping(true)
	render.PushCustomClipPlane(n, d)
	orig(self, ent, flags)
	render.PopCustomClipPlane()

	local saved = {}
	for _, name in ipairs(TORSO) do
		local b = e:LookupBone(name)
		if b then
			saved[b] = e:GetManipulateBonePosition(b)
			e:ManipulateBonePosition(b, NAN)
		end
	end
	e:InvalidateBoneCache()
	e:SetupBones()
	render.PushCustomClipPlane(-n, -d)
	e:DrawModel(flags)
	render.PopCustomClipPlane()
	for b, v in pairs(saved) do e:ManipulateBonePosition(b, v) end
	e:InvalidateBoneCache()
	e:SetupBones()
	render.EnableClipping(oldClip)
end

-- оборачиваем отрисовку тел Z-City (sh_utility.lua); проверка дешёвая, переобернёт, если её заменят
hook.Add("Think", "rem_torsocut_wrap", function()
	local cur = hg.renderOverride
	if not cur or cur == hg.__remCutWrapped then return end
	local wrapped = function(self, ent, flags) return DrawCut(cur, self, ent, flags) end
	hg.__remCutWrapped = wrapped
	hg.renderOverride = wrapped
end)
