-- Алкоголь в организме. Выпитое сначала в желудке (org.alcoholStomach), потом всасывается в кровь (org.alcohol, промилле),
-- печень потихоньку выводит (больная печень - медленнее, а пьянство её добивает).
-- Что делает (промилле):
--   любое  - расширяет сосуды (sv_vessels.lua: тепло уходит быстрее - в холоде замёрзнешь, раны кровят сильнее),
--            притупляет боль (immediatepain.lua) и страх;
--   ~0.5+  - на экране плывёт, качает, взгляд гуляет, походку ведёт (cl_alcohol.lua, sh_alcohol.lua);
--   2.2+   - тошнит, рвёт (выблеванное из желудка уже не всосётся); без сознания на спине - можно захлебнуться;
--   3.2+   - отключка;
--   4.2+   - отравление: дыхание угнетается, без помощи - смерть.
local A = {
	absorb = 0.02,       -- промилле в секунду из желудка в кровь
	eliminate = 0.0035,  -- промилле в секунду выводит здоровая печень
	painRelief = 0.12,   -- на промилле (до 0.4 боли)
	vomitStart = 2.2,
	otrub = 3.2,
	deadly = 4.2,
}
hg.organism.AlcoholConfig = A

local drunkPhrases = {
	"Whoa... the floor is moving...",
	"I feel... *hic*... great...",
	"Everything's spinning a bit...",
}
local sickPhrases = {
	"I'm gonna be sick...",
	"Ugh... my stomach...",
	"Too much... way too much...",
}

function hg.organism.Alcohol(owner, org, timeValue)
	local st, bac = org.alcoholStomach or 0, org.alcohol or 0
	if st <= 0 and bac <= 0 then
		if org.alcoholSent and org.alcoholSent ~= 0 and IsValid(owner) then
			org.alcoholSent = 0
			owner:SetNW2Float("rem_bac", 0)
		end
		return
	end

	if st > 0 then
		local a = math.min(st, timeValue * A.absorb)
		st, bac = st - a, bac + a
	end
	local liverMul = math.Clamp(1 - (org.liver or 0), 0.2, 1)
	bac = math.max(bac - timeValue * A.eliminate * liverMul, 0)
	org.alcoholStomach, org.alcohol = st, bac

	if org.alive ~= false then
		-- пьяному не так страшно
		if org.fear and org.fear > -1 then org.fear = math.max(org.fear - timeValue * 0.08 * math.min(bac, 2), -1) end
		-- долгое тяжёлое опьянение бьёт по печени
		if bac > 2 and org.liver then org.liver = math.min(org.liver + timeValue * (bac - 2) / 4000, 1) end

		-- тошнота и рвота
		if bac > A.vomitStart then
			org.alcoholVomit = (org.alcoholVomit or 0) + timeValue * (bac - A.vomitStart) * 0.035 * math.Rand(0.5, 1.5)
			if org.alcoholVomit > 1 and hg.organism.Vomit then
				org.alcoholVomit = 0
				if org.isPly and not org.otrub then owner:Notify(table.Random(sickPhrases), true, "alcohol", 0) end
				local blood = org.blood
				hg.organism.Vomit(owner)
				org.blood = blood -- Vomit отнимает кровь (рвота кровью), тут рвёт просто выпитым
				org.alcoholStomach = org.alcoholStomach * 0.3
			end
		end

		if bac > A.otrub then
			org.needotrub = true
			org.consciousness = math.min(org.consciousness or 1, 0.2)
		end

		if bac > A.deadly and org.o2 and org.o2[1] then
			org.o2[1] = math.max(org.o2[1] - timeValue * (bac - A.deadly) * 1.5, 0)
		end

		if org.isPly and not org.otrub and bac > 0.8 and bac < A.vomitStart and (org.alcoholNotify or 0) < CurTime() then
			org.alcoholNotify = CurTime() + math.Rand(60, 120)
			owner:Notify(table.Random(drunkPhrases), true, "alcohol", 0)
		end
	end

	if IsValid(owner) and owner:IsPlayer() then
		local r = math.Round(bac, 2)
		if math.abs(r - (org.alcoholSent or 0)) >= 0.03 or (r == 0 and org.alcoholSent ~= 0) then
			org.alcoholSent = r
			owner:SetNW2Float("rem_bac", r)
		end
	end
end
