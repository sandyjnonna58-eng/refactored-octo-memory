-- Гримаса боли на лице (по мотивам Artagdoll, свой код): сервер шлёт NW2 rem_grimace 0..1 от боли (sv_reagdoll_extra.lua),
-- здесь - брови вниз и внутрь, прищур, щёки и верхняя губа вверх, губы растянуты. Только флексы, которые не трогает
-- Z-City (рот при голосе - jaw_drop/part/mouth_drop/lower_lip, моргание - blink/wrinkler/half_closed: cl_utility.lua).
-- На игроке и на его регдолле. rem_reag_face 0 - выкл.
local cvFace = CreateClientConVar("rem_reag_face", "1", true, false, "Pain grimace on faces", 0, 1)

local FLEX = {
	right_lowerer = 1, left_lowerer = 1,
	right_inner_raiser = 0.55, left_inner_raiser = 0.55,
	right_lid_tightener = 0.8, left_lid_tightener = 0.8,
	right_cheek_raiser = 0.6, left_cheek_raiser = 0.6,
	right_upper_raiser = 0.5, left_upper_raiser = 0.5,
	right_stretcher = 0.7, left_stretcher = 0.7,
	right_corner_depressor = 0.35, left_corner_depressor = 0.35,
}

-- номера флексов модели (кэш по модели)
local ids = {}
local function FlexIds(ent)
	local mdl = ent:GetModel()
	if not mdl then return nil end
	local t = ids[mdl]
	if t then return t end
	t = {}
	for name, k in pairs(FLEX) do
		local id = ent:GetFlexIDByName(name)
		if id then t[#t + 1] = {id, k} end
	end
	ids[mdl] = t
	return t
end

local function Apply(ent, v)
	if not IsValid(ent) then return end
	local t = FlexIds(ent)
	if not t then return end
	for _, f in ipairs(t) do ent:SetFlexWeight(f[1], f[2] * v) end
end

local smooth = {}
hook.Add("Think", "rem_reag_face", function()
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local on = cvFace:GetBool()
	local eye = lp:EyePos()
	local ft = FrameTime()
	for _, ply in player.Iterator() do
		local want = on and ply:GetNW2Float("rem_grimace", 0) or 0
		local cur = smooth[ply] or 0
		if want == 0 and cur == 0 then continue end
		cur = math.Approach(cur, want, ft * (want > cur and 3 or 1.2))
		if cur < 0.01 and want == 0 then cur = 0 end
		smooth[ply] = cur
		local rag = ply.FakeRagdoll
		local ent = IsValid(rag) and rag or ply
		if ent:GetPos():DistToSqr(eye) < 1500 * 1500 then
			Apply(ent, cur)
			if ent ~= ply then Apply(ply, cur) end
		end
	end
	for ply in pairs(smooth) do if not IsValid(ply) then smooth[ply] = nil end end
end)
