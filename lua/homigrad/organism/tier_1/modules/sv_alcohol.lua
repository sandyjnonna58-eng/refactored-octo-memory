-- Алкоголь в организме. Выпитое сначала в желудке (org.alcoholStomach), потом всасывается в кровь (org.alcohol, промилле),
-- печень потихоньку выводит (больная печень - медленнее, а пьянство её добивает).
-- Привыкание (sv_addiction.lua): у пьющего "действующее" опьянение меньше реального - до -40% (толерантность),
-- зато без выпивки начинается ломка.
-- Что делает (по действующему опьянению, промилле):
--   любое  - расширяет сосуды (sv_vessels.lua: тепло уходит быстрее - в холоде замёрзнешь, раны кровят сильнее),
--            притупляет боль (immediatepain.lua) и страх;
--   ~0.5+  - на экране плывёт, качает, взгляд гуляет, походку ведёт (cl_alcohol.lua, sh_alcohol.lua);
--   1.8+   - сильно мотает: на ходу бросает в стороны;
--   2.2+   - тошнит, рвёт (выблеванное из желудка уже не всосётся); без сознания на спине - можно захлебнуться;
--   2.5+   - на ходу может свалить с ног;
--   3.2+   - отключка;
--   4.2+   - отравление: дыхание угнетается, без помощи - смерть (тут толерантность помогает меньше).
local A = {
	absorb = 0.02,       -- промилле в секунду из желудка в кровь
	eliminate = 0.0035,  -- промилле в секунду выводит здоровая печень
	painRelief = 0.12,   -- на промилле (до 0.4 боли)
	tolerance = 0.4,     -- насколько привыкание снижает действие (при полной зависимости)
	lurchStart = 1.8,    -- с этого бросает в стороны на ходу
	fallStart = 2.5,     -- с этого может свалить с ног
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
local wastedPhrases = {
	"Can't... walk... straight...",
	"Who moved the ground...",
	"*hic* ...where am I going...",
}
local sickPhrases = {
	"I'm gonna be sick...",
	"Ugh... my stomach...",
	"Too much... way too much...",
}

local function Tolerance(owner)
	return hg.Addiction and hg.Addiction.Get and hg.Addiction.Get(owner, "alcohol") or 0
end

-- бросает в стороны и валит с ног (только на ходу, живых и в сознании)
local function Stagger(owner, org, eff, timeValue)
	if not owner:IsPlayer() or not owner:Alive() or org.otrub or IsValid(owner.FakeRagdoll) then return end
	if not owner:OnGround() or owner:GetVelocity():Length2D() < 40 then return end
	if eff > A.lurchStart and math.Rand(0, 1) < timeValue * (eff - A.lurchStart) * 0.9 then
		local side = owner:GetRight() * (math.random(2) == 1 and 1 or -1)
		owner:SetVelocity(side * math.Rand(140, 240) * math.min(eff - A.lurchStart + 0.4, 1.5) + owner:GetForward() * math.Rand(-60, 80))
		owner:ViewPunch(Angle(math.Rand(-4, 4), math.Rand(-6, 6), math.Rand(-10, 10)))
	end
	if eff > A.fallStart and hg.LightStunPlayer and math.Rand(0, 1) < timeValue * (eff - A.fallStart) * 0.12 * (owner:KeyDown(IN_SPEED) and 2.5 or 1) then
		hg.LightStunPlayer(owner, math.Rand(1.5, 3))
		if org.isPly then owner:Notify(table.Random(wastedPhrases), true, "alcohol", 0) end
	end
end

function hg.organism.Alcohol(owner, org, timeValue)
	local st, bac = org.alcoholStomach or 0, org.alcohol or 0
	if st <= 0 and bac <= 0 then
		if org.alcoholSent and org.alcoholSent ~= 0 and IsValid(owner) then
			org.alcoholSent = 0
			owner:SetNW2Float("rem_bac", 0)
			owner:SetNW2Float("rem_bac_eff", 0)
		end
		org.alcoholEff = 0
		return
	end

	if st > 0 then
		local a = math.min(st, timeValue * A.absorb)
		st, bac = st - a, bac + a
	end
	local liverMul = math.Clamp(1 - (org.liver or 0), 0.2, 1)
	bac = math.max(bac - timeValue * A.eliminate * liverMul, 0)
	org.alcoholStomach, org.alcohol = st, bac

	-- действующее опьянение с учётом привыкания
	local tol = Tolerance(owner)
	local eff = bac * (1 - A.tolerance * tol)
	org.alcoholEff = eff

	if org.alive ~= false then
		-- пьяному не так страшно
		if org.fear and org.fear > -1 then org.fear = math.max(org.fear - timeValue * 0.08 * math.min(eff, 2), -1) end
		-- долгое тяжёлое опьянение бьёт по печени (по реальному количеству)
		if bac > 2 and org.liver then org.liver = math.min(org.liver + timeValue * (bac - 2) / 4000, 1) end

		-- тошнота и рвота
		if eff > A.vomitStart then
			org.alcoholVomit = (org.alcoholVomit or 0) + timeValue * (eff - A.vomitStart) * 0.035 * math.Rand(0.5, 1.5)
			if org.alcoholVomit > 1 and hg.organism.Vomit then
				org.alcoholVomit = 0
				if org.isPly and not org.otrub then owner:Notify(table.Random(sickPhrases), true, "alcohol", 0) end
				local blood = org.blood
				hg.organism.Vomit(owner)
				org.blood = blood -- Vomit отнимает кровь (рвота кровью), тут рвёт просто выпитым
				org.alcoholStomach = org.alcoholStomach * 0.3
			end
		end

		if eff > A.otrub then
			org.needotrub = true
			org.consciousness = math.min(org.consciousness or 1, 0.2)
		end

		-- отравление: привыкание спасает меньше
		local poison = bac * (1 - A.tolerance * 0.5 * tol)
		if poison > A.deadly and org.o2 and org.o2[1] then
			org.o2[1] = math.max(org.o2[1] - timeValue * (poison - A.deadly) * 1.5, 0)
		end

		Stagger(owner, org, eff, timeValue)

		if org.isPly and not org.otrub and eff > 0.8 and eff < A.vomitStart and (org.alcoholNotify or 0) < CurTime() then
			org.alcoholNotify = CurTime() + math.Rand(60, 120)
			owner:Notify(table.Random(eff > A.lurchStart and wastedPhrases or drunkPhrases), true, "alcohol", 0)
		end
	end

	if IsValid(owner) and owner:IsPlayer() then
		local r, re = math.Round(bac, 2), math.Round(eff, 2)
		if math.abs(r - (org.alcoholSent or 0)) >= 0.03 or (r == 0 and org.alcoholSent ~= 0) then
			org.alcoholSent = r
			owner:SetNW2Float("rem_bac", r)
			owner:SetNW2Float("rem_bac_eff", re)
		end
	end
end
