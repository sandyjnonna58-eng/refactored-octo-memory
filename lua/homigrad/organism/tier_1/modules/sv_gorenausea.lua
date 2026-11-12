-- Тошнота от вида расчленёнки: раз в секунду смотрим, что игрок видит рядом (до 450 юнитов, в поле зрения, без стены
-- между): разрубленные пополам тела (sv_torsohalve.lua) и тела без головы.
-- Тошнота (sv_vomit.lua AddNausea) копится быстрее, чем больше этого видно. Привыкание: кто насмотрелся, того мутит
-- всё меньше (до -90%), без такого зрелища привычка медленно проходит. Не мутит без сознания, в ярости и под героином.
-- Первый взгляд на новую жуть - мысль. Тошнота сама понемногу проходит (NAUSEA_DECAY), если её ничего не держит.
local cvOn = CreateConVar("rem_gore_nausea", "1", FCVAR_ARCHIVE, "Seeing gore (halved or headless bodies) makes you nauseous", 0, 1)

local RANGE = 450
local RATE = 0.014           -- тошноты в секунду за одну "единицу" жути
local TOL_GROW = 0.0025      -- привыкание в секунду, пока смотришь
local TOL_DECAY = 1 / 1800   -- проходит за ~30 минут
local NAUSEA_DECAY = 0.003   -- тошнота проходит сама (в секунду)

local firstLook = {
	"Oh god...",
	"What the hell happened here...",
	"Don't look at it. Don't look at it.",
	"That's... a person...",
	"I think I'm going to be sick...",
	"Is that... an arm?",
}

-- сколько жути в сущности (0 - не жуть)
local function GoreWeight(ent)
	if not IsValid(ent) or not ent:IsRagdoll() then return 0 end
	if ent:GetNWBool("hgTorsoSevered", false) or ent:GetNWBool("hgTorsoLower", false) then return 2 end
	if ent.headexploded then return 1.5 end
	return 0
end

local function Sees(ply, ent, eye, fwd)
	local pos = ent:WorldSpaceCenter()
	local dir = pos - eye
	local dist = dir:Length()
	if dist > RANGE or dist < 1 then return false end
	if fwd:Dot(dir / dist) < 0.55 then return false end
	local tr = util.TraceLine({start = eye, endpos = pos, filter = {ply, ply.FakeRagdoll, ent}, mask = MASK_VISIBLE})
	return not tr.Hit
end

timer.Create("rem_gore_nausea", 1, 0, function()
	if not cvOn:GetBool() then return end
	local gore = {}
	for _, ent in ipairs(ents.FindByClass("prop_ragdoll")) do
		local w = GoreWeight(ent)
		if w > 0 then gore[#gore + 1] = {ent, w} end
	end

	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		if not ply:Alive() or not org then continue end
		ply.rem_goreTol = math.max((ply.rem_goreTol or 0) - TOL_DECAY, 0)

		local total = 0
		if #gore > 0 and not org.otrub then
			local eye, fwd = ply:EyePos(), ply:GetAimVector()
			ply.rem_goreSeen = ply.rem_goreSeen or setmetatable({}, {__mode = "k"})
			for _, g in ipairs(gore) do
				local ent = g[1]
				if ent ~= ply.FakeRagdoll and Sees(ply, ent, eye, fwd) then
					total = total + g[2]
					if not ply.rem_goreSeen[ent] then
						ply.rem_goreSeen[ent] = true
						if ply.Notify and math.random() < 0.5 * (1 - (ply.rem_goreTol or 0)) then
							ply:Notify(table.Random(firstLook), true, "rem_gore_look", 0)
						end
					end
				end
			end
		end

		local calm = (org.berserkActive2 and 1 or 0) + ply:GetNW2Float("rem_heroin", 0) -- ярость и героин глушат
		if total > 0 and calm < 1 then
			local tol = ply.rem_goreTol or 0
			if hg.organism.AddNausea then
				hg.organism.AddNausea(ply, org, RATE * math.min(total, 5) * (1 - tol) * (1 - calm))
			end
			ply.rem_goreTol = math.min(tol + TOL_GROW * math.min(total, 3), 0.9)
		elseif (org.nausea or 0) > 0 then
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
