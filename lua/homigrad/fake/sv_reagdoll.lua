-- Живые реакции регдолла (по мотивам мода ReAgdoll, свой код поверх управления регдоллом Z-City - sv_control.lua):
--  1) хватается за рану: свежая рана (org.wounds / org.arterialwounds) -> свободная рука (не раненая, не отрубленная, не
--     занятая игроком) тянется к ней и держит; в сознании - 4..10 с, без сознания слабо, у мёртвого - угасает за DEATH_FADE;
--  2) пытается устоять: упал в регдолл стоя от попадания (рана моложе 1 с) - 2.5..5 с держит таз и корпус, ставит ноги
--     под себя, спотыкается, колени подкашиваются, держась за рану; потом падает. Умер стоя - оседает за 0.8..1.5 с;
--  3) машет руками и ногами в полёте (падение с высоты, отбросило); руки не трогаем, когда Z-City закрывается ими
--     перед землёй (fallCover в sv_control.lua);
--  4) цепляется рукой: в полёте/при падении рука в сознании задела стену или край - на 1.5..4 с держится (ballsocket);
--  5) закрывается: бьют руками/ногами (пинки, кулаки - инфликтор "руки") - руки прикрывают голову, колени к груди;
--     удар тупым оружием (DMG_CLUB) по телу - держится за место удара, по голове - тоже закрывается;
--  6) шёл/бежал и сбили - по инерции ещё идёт регдоллом: ноги шагают, тело тянет вперёд, потом падает.
-- Пока игрок сам управляет рукой (ЛКМ / ПКМ / E, оружие, свой захват ConsLH/ConsRH, ручное зажатие раны) - её не трогаем.
local cvOn = CreateConVar("rem_reag", "1", FCVAR_ARCHIVE, "Ragdoll reactions: hold wounds, stagger, flail, grab ledges", 0, 1)
local cvHold = CreateConVar("rem_reag_hold_chance", "80", FCVAR_ARCHIVE, "Chance (%) to grab a fresh wound", 0, 100)
local cvStagger = CreateConVar("rem_reag_stagger", "1", FCVAR_ARCHIVE, "Stagger before collapsing when shot down", 0, 1)
local cvFlail = CreateConVar("rem_reag_flail", "1", FCVAR_ARCHIVE, "Flail limbs while flying/falling", 0, 1)
local cvStrength = CreateConVar("rem_reag_strength", "1.35", FCVAR_ARCHIVE, "Strength multiplier for ragdoll reactions", 0.2, 3)
local cvVariety = CreateConVar("rem_reag_variety", "1", FCVAR_ARCHIVE, "Each person gets own reaction strength (weak / normal / very strong)", 0, 1)
local cvFire = CreateConVar("rem_reag_fire", "1", FCVAR_ARCHIVE, "Roll on the ground when burning, convulse from electric shock", 0, 1)
local cvEpi = CreateConVar("rem_reag_epilepsy_chance", "100", FCVAR_ARCHIVE, "Chance (%) that an electric shock starts an epileptic seizure", 0, 100)
local cvYield = CreateConVar("rem_reag_yield", "1", FCVAR_ARCHIVE, "Reactions give the ragdoll back while the player presses any control key", 0, 1)
local cvGuard = CreateConVar("rem_reag_guard", "1", FCVAR_ARCHIVE, "Cover the head when beaten with fists/kicks", 0, 1)
local cvStand = CreateConVar("rem_reag_stand_time", "1", FCVAR_ARCHIVE, "Multiplier for how long a shot person tries to stay on feet", 0, 5)
local cvGrab = CreateConVar("rem_reag_grab", "1", FCVAR_ARCHIVE, "Grab walls/ledges with a hand while falling", 0, 1)

local DEATH_FADE = 9      -- столько секунд мёртвый ещё держится за рану (слабее и слабее)
local DEATH_FLAIL = 1.2   -- после смерти ещё машет в полёте
local WOUND_FRESH = 2     -- рана свежая столько секунд (успел упасть в регдолл после попадания)

-- логические номера физ. костей Z-City (hg.realPhysNum переводит под модель)
local ARM = {
	L = {upper = 3, fore = 4, hand = 5, amp = "larmamputated"},
	R = {upper = 2, fore = 6, hand = 7, amp = "rarmamputated"},
}
local LEFT_ARM = {["ValveBiped.Bip01_L_UpperArm"] = true, ["ValveBiped.Bip01_L_Forearm"] = true, ["ValveBiped.Bip01_L_Hand"] = true, ["ValveBiped.Bip01_L_Clavicle"] = true}
local RIGHT_ARM = {["ValveBiped.Bip01_R_UpperArm"] = true, ["ValveBiped.Bip01_R_Forearm"] = true, ["ValveBiped.Bip01_R_Hand"] = true, ["ValveBiped.Bip01_R_Clavicle"] = true}
-- конечности для махания: номер, амплитуда (град/с), какой ампутацией выключается
local FLAIL = {
	{n = 2, a = 520, amp = "rarmamputated", arm = "R"}, {n = 3, a = 520, amp = "larmamputated", arm = "L"},
	{n = 6, a = 420, amp = "rarmamputated", arm = "R"}, {n = 4, a = 420, amp = "larmamputated", arm = "L"},
	{n = 8, a = 260, amp = "rlegamputated"}, {n = 11, a = 260, amp = "llegamputated"},
	{n = 9, a = 300, amp = "rlegamputated"}, {n = 12, a = 300, amp = "llegamputated"},
}

local cvDebug = CreateConVar("rem_reag_debug", "0", FCVAR_ARCHIVE, "Print ragdoll reaction triggers to the server console", 0, 1)
local function Dbg(...) if cvDebug:GetBool() then print("[rem_reag]", ...) end end
local R = {} -- [регдолл] = состояние
-- сила реакций: общая (rem_reag_strength) x своя у каждого человека (st.mul - слабый / обычный / очень сильный)
local function Str(st) return cvStrength:GetFloat() * (st and st.mul or 1) end

-- характер тела на эту жизнь: четверть - слабые (вялые, еле держатся), половина - обычные, четверть - очень сильные
-- (резко дёргаются, долго стоят, крепко держатся). rem_reag_variety 0 - у всех одинаково
local function RollMul()
	if not cvVariety:GetBool() then return 1 end
	local r = math.random()
	if r < 0.25 then return math.Rand(0.35, 0.7) end
	if r < 0.75 then return math.Rand(0.85, 1.25) end
	return math.Rand(1.6, 2.4)
end

local HANDS = {weapon_hands_sh = true, weapon_hg_coolhands = true}

local function Phys(rag, n)
	local num = hg.realPhysNum and hg.realPhysNum(rag, n) or n
	local p = rag:GetPhysicsObjectNum(num)
	return IsValid(p) and p or nil, num
end

local function Floppy(rag, num)
	local f = rag.hg_floppy_bones
	if not f then return false end
	local b = rag:TranslatePhysBoneToBone(num)
	return b and b >= 0 and f[rag:GetBoneName(b)] == true
end

-- тянуть кость к точке напрямую (hg.ShadowControl ещё делит силу на ragdoll.power - от боли руки почти не двигались)
local shadowP = {}
local function Shadow(rag, n, pos, speed, damp)
	local p, num = Phys(rag, n)
	if not p or Floppy(rag, num) or not pos then return end
	shadowP.secondstoarrive = 0.05
	shadowP.pos = pos
	shadowP.angle = p:GetAngles()
	shadowP.maxangular = 0
	shadowP.maxangulardamp = 0
	shadowP.maxspeed = speed
	shadowP.maxspeeddamp = damp
	shadowP.dampfactor = 0.8
	shadowP.teleportdistance = 0
	p:Wake()
	p:ComputeShadowControl(shadowP)
end

-- самая свежая рана (артериальная важнее при равном времени)
local function NewestWound(org)
	local best, bestT
	for _, list in ipairs({org.wounds, org.arterialwounds}) do
		if istable(list) then
			for _, w in pairs(list) do
				local t = istable(w) and tonumber(w[5])
				if t and (not bestT or t >= bestT) then best, bestT = w, t end
			end
		end
	end
	return best, bestT
end

-- рана ещё есть? Сравниваем по времени и кости, не по ссылке: Z-City может пересобрать список ран (тогда рука
-- отпускала рану через полсекунды). Перевязали / рана зажила - её нет в списке
local function WoundStillThere(org, w)
	if w.spot then return true end -- место удара тупым - держится по времени
	for _, list in ipairs({org.wounds, org.arterialwounds}) do
		if istable(list) then
			for _, x in pairs(list) do
				if x == w or (istable(x) and x[5] == w[5] and x[4] == w[4]) then return true end
			end
		end
	end
	return false
end

local function WoundBoneName(rag, w)
	if w.spot then return w.bone end
	local b = w[4]
	if isnumber(b) then return rag:GetBoneName(b) end
	return b
end

-- позиция раны - по физике кости (матрицы костей регдолла на сервере бывают старые, у свежего тела смерти - вообще
-- нулевые: рука тянулась к точке далеко от тела и растягивала регдолл). Кость без своей физики - от физ. родителя.
local function WoundPos(rag, w)
	if w.spot then
		local p = rag:GetPhysicsObjectNum(w.phys)
		return IsValid(p) and p:LocalToWorld(w.lpos) or nil
	end
	local b = w[4]
	if isstring(b) then b = rag:LookupBone(b) end
	if not isnumber(b) or b < 0 then return nil end
	local pb = rag:TranslateBoneToPhysBone(b)
	local phys = pb and pb >= 0 and rag:GetPhysicsObjectNum(pb)
	if not IsValid(phys) then return nil end
	local local_ = w[2] or vector_origin
	if rag:TranslatePhysBoneToBone(pb) ~= b then local_ = local_ * 0.5 end -- не та кость: смещение примерное, ближе к центру
	return phys:LocalToWorld(local_)
end

-- руки, которыми сейчас управляет игрок (их не трогаем)
local function BusyHands(st, rag)
	local ply, org = st.ply, st.org
	local L, Rr = IsValid(rag.ConsLH), IsValid(rag.ConsRH)
	if st.alive and IsValid(ply) then
		if org and org.manualHoldWound then return true, true end
		if ply:KeyDown(IN_USE) then return true, true end
		local wep = ply:GetActiveWeapon()
		local gun = IsValid(wep) and ishgweapon and ishgweapon(wep)
		-- "руки" Z-City (weapon_hands_sh) помечены ismelee - с пустыми руками правая свободна
		if gun or (IsValid(wep) and wep.ismelee and not HANDS[wep:GetClass()]) then Rr = true end
		if ply:KeyDown(IN_ATTACK) then L = true end
		if ply:KeyDown(IN_ATTACK2) then Rr = true end
	end
	return L, Rr
end

-- игрок сам управляет регдоллом (E, мышь, WASD, прыжок, присед, бег) - реакции отдают ему тело: управление Z-City
-- (руки на E/ЛКМ/ПКМ, ползание, корпус за камерой) иначе перебивалось. Ещё 0.6 с после отпускания - не дёргать туда-сюда
local CONTROL_KEYS = {IN_USE, IN_ATTACK, IN_ATTACK2, IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP, IN_DUCK, IN_SPEED, IN_WALK, IN_RELOAD}
local function Controlling(st, now)
	local ply = st.ply
	if not st.alive or not IsValid(ply) or not cvYield:GetBool() then return false end
	for _, k in ipairs(CONTROL_KEYS) do
		if ply:KeyDown(k) then st.ctrlUntil = now + 0.6 break end
	end
	return now < (st.ctrlUntil or 0)
end

-- ================= 1) хватается за рану =================
local function StartHold(st, rag, w, forced)
	if not forced and math.random(100) > cvHold:GetFloat() then return end
	local org = st.org
	local bone = WoundBoneName(rag, w) or ""
	local canL = not (org and org.larmamputated) and not LEFT_ARM[bone]
	local canR = not (org and org.rarmamputated) and not RIGHT_ARM[bone]
	if not canL and not canR then return end
	local arterial = w[7] ~= nil
	local useL, useR
	-- свободная рука важнее: правой держит оружие - хватается левой
	local busyL, busyR = BusyHands(st, rag)
	if canL and canR and busyL ~= busyR then canL, canR = not busyL, not busyR end
	if canL and canR then
		local d = math.random()
		if arterial or d > 0.66 then useL, useR = true, true elseif d > 0.33 then useL = true else useR = true end
	else
		useL, useR = canL, canR
	end
	Dbg("hold wound", bone, useL and "L" or "", useR and "R" or "")
	local now = CurTime()
	local dur = st.alive and math.Rand(4, 10) or DEATH_FADE
	if useL then st.holds.L = {w = w, untilT = now + dur, start = now} end
	if useR then st.holds.R = {w = w, untilT = now + dur, start = now} end
end

local function HoldStrength(st, now)
	if not st.alive then return math.Clamp(1 - (now - (st.deathT or now)) / DEATH_FADE, 0, 1) * 0.8 end
	local org = st.org
	if not org then return 1 end
	if org.otrub then return 0.35 end
	return math.Clamp(org.consciousness or 1, 0.4, 1)
end

local function ApplyHolds(st, rag, now, busyL, busyR)
	if not st.alive and now - (st.deathT or now) < 0.25 then return end -- тело смерти только создано - пусть встанет
	local s = HoldStrength(st, now)
	for side, h in pairs(st.holds) do
		local busy = (side == "L" and busyL) or (side == "R" and busyR) or (st.guard and st.alive)
		if now > h.untilT or s <= 0.02 or (st.org and (now - h.start) > 0.5 and not WoundStillThere(st.org, h.w)) then
			st.holds[side] = nil
		elseif not busy then
			local pos = WoundPos(rag, h.w)
			local a = ARM[side]
			local hand, handN = Phys(rag, a.hand)
			local fore = Phys(rag, a.fore)
			local upper = Phys(rag, a.upper)
			if pos and hand and fore and upper and not Floppy(rag, handN) and pos:DistToSqr(upper:GetPos()) < 70 * 70 then
				local fade = math.min((now - h.start) / 0.3, 1) -- рука тянется, а не прыгает
				local k = s * fade * (st.alive and 1 or 0.6) * Str(st) -- мёртвое тело - мягче
				-- рана дальше, чем достаёт рука (нога): тянется насколько достаёт (иначе растягивает руку), а живой
				-- подтягивает раненую ногу к рукам
				local up = upper:GetPos()
				local d = pos - up
				local far = d:Length() > 28
				local target = far and up + d:GetNormalized() * 28 or pos
				if far and st.alive then
					local bone = WoundBoneName(rag, h.w) or ""
					local calf = (string.find(bone, "R_", 1, true) and 9) or (string.find(bone, "L_", 1, true) and 12) or nil
					local spine = Phys(rag, 1)
					if calf and spine and (string.find(bone, "Thigh", 1, true) or string.find(bone, "Calf", 1, true) or string.find(bone, "Foot", 1, true)) then
						Shadow(rag, calf, spine:GetPos() + (pos - spine:GetPos()):GetNormalized() * 18, 30 * k, 12 * k)
					end
				end
				-- как ручное зажатие Z-City: плечо, предплечье, кисть - каждое к своей точке перед раной
				local function To(phys, off) local dd = target - phys:GetPos() return dd:LengthSqr() > 0.01 and target - dd:GetNormalized() * off or target end
				Shadow(rag, a.upper, To(upper, 14), 30 * k, 14 * k)
				Shadow(rag, a.fore, To(fore, 8), 85 * k, 16 * k)
				Shadow(rag, a.hand, To(hand, 3), 85 * k, 16 * k)
			end
		end
	end
end

-- ================= 2) пытается устоять =================
-- Упал от попадания стоя (или умер стоя): тело ещё борется - держит таз на прежней высоте, выпрямляет корпус и
-- голову, ноги ставит под себя (тянутся туда, куда его ведёт, - спотыкающиеся шаги), иногда колени подкашиваются
-- и он снова выпрямляется. Сил всё меньше - в конце оседает и падает. Живой в сознании - 2.5..5 с (меньше от боли,
-- крови, сломанной ноги), мёртвый - 0.8..1.5 с. Падает раньше, если всё же завалился (таз низко / корпус лёг).
local function Ground(rag, st, pos)
	local tr = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, 90), filter = {rag, st.ply}, mask = MASK_SOLID})
	return tr.Hit and tr.HitPos.z or nil
end

-- повернуть кость так, чтобы её ось (Forward) смотрела в dir: добавка угловой скорости (град/с, в осях кости)
local function Align(phys, dir, gain, blend)
	local a = phys:GetAngles():Forward()
	local c = a:Cross(dir)
	local sinA = c:Length()
	if sinA < 1e-4 then return end
	local ang = math.deg(math.asin(math.min(sinA, 1)))
	if a:Dot(dir) < 0 then ang = 180 - ang end
	local want = phys:WorldToLocalVector(c / sinA * math.min(ang * gain, 400))
	phys:AddAngleVelocity((want - phys:GetAngleVelocity()) * blend)
end

local function BalanceStrength(st)
	local org = st.org
	if not org then return 1 end
	local s = math.Clamp(org.consciousness or 1, 0, 1)
	s = s * (1 - math.Clamp(((org.pain or 0) - 40) / 120, 0, 0.6)) -- боль
	if org.blood and org.blood < 4000 then s = s * math.Clamp((org.blood - 2500) / 1500, 0.2, 1) end
	return s
end

local function StartBalance(st, rag, now, moveVel)
	if not cvStagger:GetBool() then return end
	local pelvis, spine = Phys(rag, 0), Phys(rag, 1)
	if not pelvis or not spine then return end
	local pv0 = pelvis:GetVelocity()
	if math.abs(pv0.z) > 220 or Vector(pv0.x, pv0.y, 0):Length() > 450 then return end -- отбросило (взрыв и т.п.) - сразу летит
	local gz = Ground(rag, st, pelvis:GetPos())
	local h0 = gz and pelvis:GetPos().z - gz
	if not h0 or h0 < 22 then return end -- не на ногах (лежит или в воздухе)
	local org = st.org
	if org and org.llegamputated and org.rlegamputated then return end
	local dur
	if st.alive then
		if org and org.otrub then return end -- без сознания - сразу мешком
		local legs = 1
		if org then
			if org.llegamputated or org.rlegamputated then legs = 0.3 end
			legs = legs * (1 - math.Clamp(((org.lleg or 0) + (org.rleg or 0)) * 0.35, 0, 0.7))
		end
		-- сильный стоит дольше, слабый валится почти сразу
		dur = math.Rand(2.5, 5) * math.Clamp(BalanceStrength(st), 0.35, 1) * legs * cvStand:GetFloat() * math.Clamp(st.mul or 1, 0.4, 1.7)
	else
		dur = math.Rand(0.8, 1.5)
	end
	if dur < 0.4 then return end
	st.bal = {start = now, dur = dur, h0 = math.min(h0, 42), buckleUntil = 0, nextBuckle = now + math.Rand(0.6, 1.6),
		nextSway = 0, stepPhase = math.Rand(0, 6)}
	-- куда толкнуло попадание - туда и шатнёт в начале
	local pv = pelvis:GetVelocity()
	pv.z = 0
	if pv:Length() > 15 then st.bal.push = pv:GetNormalized() end
	-- шёл/бежал, когда сбили: ещё идёт регдоллом по инерции (скорость игрока на момент падения или самого тела)
	local mv = moveVel and Vector(moveVel.x, moveVel.y, 0) or vector_origin
	if mv:Length() < pv:Length() then mv = pv end
	local sp = mv:Length()
	if sp > 50 then
		-- убитый на ходу делает ещё шаг-другой
		local walk = st.alive and math.Rand(1.2, 2.6) * math.Clamp(BalanceStrength(st), 0.5, 1) or math.Rand(0.5, 0.9)
		st.bal.walk = {dir = mv / sp, speed = math.min(sp, 230), dur = walk}
		st.bal.dur = math.max(st.bal.dur, walk + 0.8)
	end
end

local LEGS = {{thigh = 8, calf = 9, side = 1}, {thigh = 11, calf = 12, side = -1}}

local function ApplyBalance(st, rag, now, dt)
	local b = st.bal
	local pelvis, spine, head = Phys(rag, 0), Phys(rag, 1), Phys(rag, 10)
	if not pelvis or not spine or pelvis:GetVelocity():Length() > 400 or pelvis:GetPos():DistToSqr(spine:GetPos()) > 40 * 40 then
		st.bal = nil
		return
	end
	local t = (now - b.start) / b.dur
	local gz = Ground(rag, st, pelvis:GetPos())
	local h = gz and pelvis:GetPos().z - gz
	local up = Vector(0, 0, 1)
	local tilt = spine:GetAngles():Forward():Dot(up) -- 1 - стоит прямо, 0 - лёг
	-- всё: время вышло, повалился (таз низко, корпус лёг) или в воздухе
	if t >= 1 or not h or (now - b.start > 0.3 and (h < b.h0 * 0.45 or tilt < 0.25)) then
		st.bal = nil
		return
	end
	-- сила: живой держится почти до конца и быстро сдаёт, мёртвый слабеет сразу
	local k = st.alive and (t < 0.7 and 1 or 1 - (t - 0.7) / 0.3) * math.Clamp(BalanceStrength(st), 0.4, 1) or (1 - t) ^ 1.5
	-- колени подкашиваются на мгновение - и снова выпрямляется
	if st.alive and now >= b.nextBuckle and not (b.walk and now - b.start < b.walk.dur) then
		b.buckleUntil = now + math.Rand(0.2, 0.4)
		b.nextBuckle = now + math.Rand(0.8, 1.8)
	end
	if now < b.buckleUntil then k = k * 0.25 end
	if k <= 0.01 then return end
	local kf = math.min(k * Str(st), 3) -- сила (rem_reag_strength x характер тела)

	local g = physenv.GetGravity() * dt
	-- противовес тяжести (верх сильнее низа) + таз тянется к прежней высоте
	local lift = {[0] = 0.8, [1] = 0.95, [10] = 0.95, [8] = 0.55, [11] = 0.55, [9] = 0.35, [12] = 0.35}
	for n, m in pairs(lift) do
		local p = Phys(rag, n)
		if p then p:AddVelocity(-g * m * math.min(kf, 1)) end
	end
	local pv = pelvis:GetVelocity()
	local wantZ = math.Clamp((b.h0 * 0.95 - h) * 7, -60, 120)
	-- идёт по инерции: тело тянет вперёд со скоростью шага (затухает), иначе гасим сползание
	local w = b.walk
	local tw = w and (now - b.start) / w.dur
	local hx, hy = -pv.x * 0.04, -pv.y * 0.04
	if tw and tw < 1 then
		local want = w.dir * w.speed * (1 - tw * 0.7)
		hx, hy = (want.x - pv.x) * 0.12, (want.y - pv.y) * 0.12
		spine:AddVelocity(Vector(want.x - spine:GetVelocity().x, want.y - spine:GetVelocity().y, 0) * 0.08 * math.min(kf, 1.5))
	else
		tw = nil
	end
	pelvis:AddVelocity(Vector(hx * kf, hy * kf, (wantZ - pv.z) * math.min(0.3 * kf, 0.6)))

	-- корпус и голова - вертикально (при ходьбе - чуть вперёд, как при шаге)
	local spineUp = tw and (up + w.dir * 0.18):GetNormalized() or up
	Align(spine, spineUp, 5, math.min(0.25 * kf, 0.6))
	if head then Align(head, up, 4, math.min(0.2 * kf, 0.5)) end

	-- ноги под себя: бедро и голень смотрят вниз, чуть в сторону, куда клонится тело (ловит равновесие);
	-- при движении ноги по очереди выносятся вперёд - спотыкающиеся шаги
	local drift = Vector(pv.x, pv.y, 0)
	local speed = drift:Length()
	local lean = spine:GetPos() - pelvis:GetPos()
	lean.z = 0
	local catchDir = (drift * 0.012 + lean * 0.05)
	if catchDir:Length() > 0.6 then catchDir = catchDir:GetNormalized() * 0.6 end
	local right = spine:GetAngles():Right()
	right.z = 0
	if right:LengthSqr() > 0.01 then right:Normalize() end
	b.stepPhase = b.stepPhase + dt * math.Clamp(speed / 12, 2, tw and 11 or 9)
	local org = st.org
	for i, L in ipairs(LEGS) do
		if not (org and org[i == 1 and "rlegamputated" or "llegamputated"]) then
			local thigh, tn = Phys(rag, L.thigh)
			local calf = Phys(rag, L.calf)
			if thigh and calf and not Floppy(rag, tn) then
				local swing = math.sin(b.stepPhase + (i - 1) * math.pi) * math.Clamp(speed / 120, 0, tw and 0.6 or 0.35)
				local dir = -up + catchDir + right * (0.08 * L.side) + (speed > 1 and drift / speed or vector_origin) * swing
				dir:Normalize()
				Align(thigh, dir, 5, math.min(0.3 * kf, 0.6))
				-- голень: шагающая нога сгибается в колене (идёт назад), опорная - прямая
				local knee = tw and math.max(-swing, 0) * 0.8 or 0
				local cdir = (dir - up * 0.4) - (speed > 1 and drift / speed or vector_origin) * knee
				Align(calf, cdir:GetNormalized(), 5, math.min(0.3 * kf, 0.6))
			end
		end
	end

	-- покачивается: толчки корпуса (в сторону удара в начале), будто ловит равновесие
	if now >= b.nextSway then
		b.nextSway = now + math.Rand(0.25, 0.5)
		local v = VectorRand(-1, 1)
		v.z = 0
		v = v:GetNormalized() * 35
		if b.push and now - b.start < 0.6 then v = v + b.push * 60 end
		spine:AddVelocity(v * math.min(kf, 1.5))
	end
end

-- ================= 3) машет в полёте =================
local function ApplyFlail(st, rag, now, busyL, busyR, coverArms)
	local org = st.org
	local t = now - st.flailStart
	local strength = st.alive and 1 or math.Clamp(1 - (now - (st.deathT or now)) / DEATH_FLAIL, 0, 1)
	if strength <= 0 then return end
	for i, f in ipairs(FLAIL) do
		local skip = (org and org[f.amp]) or (f.arm == "L" and (busyL or coverArms or st.holds.L or st.grab.L or st.guard))
			or (f.arm == "R" and (busyR or coverArms or st.holds.R or st.grab.R or st.guard))
		if not skip then
			local p, num = Phys(rag, f.n)
			if p and not Floppy(rag, num) then
				local ph = st.flailPhase[i]
				local w = 7 + ph * 3
				local av = Vector(math.sin(t * w + ph * 6) * 0.35, math.sin(t * w * 0.8 + ph * 4) * 0.6, math.cos(t * w + ph * 9)) * f.a * strength * Str(st)
				p:AddAngleVelocity((av - p:GetAngleVelocity() * 0.25) * 0.12)
			end
		end
	end
end

-- ================= 4) цепляется рукой =================
local function Release(st, side)
	local c = st.grab[side]
	if c and IsValid(c.cons) then c.cons:Remove() end
	st.grab[side] = nil
end

local function TryGrab(rag, data)
	local st = R[rag]
	if not st or not cvGrab:GetBool() or not st.alive or not st.org or st.org.otrub then return end
	if (st.air or 0) < 0.15 and data.OurOldVelocity:Length() < 180 then return end -- не в полёте и не падает
	local hit = data.HitEntity
	if not IsValid(hit) and not (hit and hit:IsWorld()) then return end
	if IsValid(hit) and (hit:IsPlayer() or hit:IsNPC() or hit:IsRagdoll()) then return end
	if math.abs(data.HitNormal.z) > 0.6 then return end -- пол/потолок - не цепляемся, только стена и край
	local now = CurTime()
	for side, a in pairs(ARM) do
		local hand, handN = Phys(rag, a.hand)
		if hand and data.PhysObject == hand and not st.grab[side] and not st.holds[side] and (st.grabNext[side] or 0) < now
			and not st.org[a.amp] and not Floppy(rag, handN) then
			local busyL, busyR = BusyHands(st, rag)
			if (side == "L" and busyL) or (side == "R" and busyR) then return end
			st.grabNext[side] = now + 1.5
			local pos, hitPhys = data.HitPos, data.HitObject
			-- констрейнт нельзя создавать внутри колбэка столкновения
			timer.Simple(0, function()
				if not IsValid(rag) or R[rag] ~= st or st.grab[side] then return end
				local cons
				if hit:IsWorld() then
					cons = constraint.Ballsocket(rag, game.GetWorld(), handN, 0, pos, 9000, 0, 0)
				elseif IsValid(hit) and IsValid(hitPhys) then
					local bone2 = 0
					for i = 0, hit:GetPhysicsObjectCount() - 1 do if hit:GetPhysicsObjectNum(i) == hitPhys then bone2 = i break end end
					cons = constraint.Ballsocket(rag, hit, handN, bone2, hitPhys:WorldToLocal(pos), 6000, 0, 0)
				end
				if IsValid(cons) then
					local life = math.Rand(1.5, 4) * math.Clamp(st.org.consciousness or 1, 0.4, 1)
					st.grab[side] = {cons = cons, untilT = CurTime() + life}
				end
			end)
			return
		end
	end
end

local function UpdateGrabs(st, rag, now, busyL, busyR)
	for side, c in pairs(st.grab) do
		local busy = (side == "L" and busyL) or (side == "R" and busyR)
		local letGo = not IsValid(c.cons) or now > c.untilT or not st.alive or (st.org and st.org.otrub)
			or (IsValid(st.ply) and st.ply:KeyDown(IN_JUMP)) or busy
		if letGo then Release(st, side) end
	end
end

-- ================= 5) закрывается от ударов =================
-- перед/право/верх тела считаем по точкам (оси костей у разных моделей ведут себя по-разному)
local function BodyFrame(rag)
	local pelvis, spine, head = Phys(rag, 0), Phys(rag, 1), Phys(rag, 10)
	local lu, ru = Phys(rag, 3), Phys(rag, 2)
	if not (pelvis and spine and head and lu and ru) then return nil end
	local up = head:GetPos() - pelvis:GetPos()
	if up:LengthSqr() < 1 then return nil end
	up:Normalize()
	local right = ru:GetPos() - lu:GetPos()
	right = right - up * right:Dot(up)
	if right:LengthSqr() < 0.01 then return nil end
	right:Normalize()
	return up:Cross(right), right, up, pelvis, spine, head
end

local function StartGuard(st, now, dur, block)
	if not cvGuard:GetBool() or not st.alive then return end
	local untilT = now + (dur or math.Rand(1.2, 2))
	if st.guard then st.guard.untilT = math.max(st.guard.untilT, untilT) return end
	st.guard = {start = now, untilT = untilT, block = block}
end

local function ApplyGuard(st, rag, now, busyL, busyR)
	local g = st.guard
	if now > g.untilT or not st.alive then st.guard = nil return end
	local org = st.org
	local s = org and (org.otrub and 0.4 or math.Clamp(org.consciousness or 1, 0.5, 1)) or 1
	local k = s * math.min((now - g.start) / 0.06, 1) * Str(st) -- рывком, как блок
	local f, r, u, pelvis, spine, head = BodyFrame(rag)
	if not f then return end
	local hp = head:GetPos()
	-- блок: предплечья скрещены перед лицом, кисти у лба/висков, локти вперёд, плечи к груди
	for side, a in pairs(ARM) do
		local busy = (side == "L" and busyL) or (side == "R" and busyR)
		if not busy and not (org and org[a.amp]) then
			local sg = side == "R" and 1 or -1
			local _, handN = Phys(rag, a.hand)
			if not Floppy(rag, handN) then
				Shadow(rag, a.hand, hp + u * 3 - r * (2 * sg) + f * 6, 150 * k, 20 * k)
				Shadow(rag, a.fore, hp + f * 9 + r * (3 * sg) - u * 2, 150 * k, 20 * k)
				Shadow(rag, a.upper, spine:GetPos() + f * 7 + u * 4 + r * (7 * sg), 45 * k, 16 * k)
			end
		end
	end
	-- колени к груди (лёжа) - сжимается в комок
	local pz = pelvis:GetPos()
	local tr = util.TraceLine({start = pz, endpos = pz - Vector(0, 0, 30), filter = {rag, st.ply}, mask = MASK_SOLID})
	if tr.Hit and not st.bal then
		for i, L in ipairs({{calf = 9, amp = "rlegamputated", sg = 1}, {calf = 12, amp = "llegamputated", sg = -1}}) do
			if not (org and org[L.amp]) then
				Shadow(rag, L.calf, pz + f * 14 - u * 2 + r * (4 * L.sg), 25 * k, 12 * k)
			end
		end
	end
end

-- блок ставится только на само попадание (не заранее на замах/ЛКМ/начало пинка - так просил пользователь).
-- удар по человеку: кулаки/пинки - закрывается; тупое оружие - держится за место удара (по голове - закрывается)
local function NearestPhys(rag, pos)
	local best, bestD
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local p = rag:GetPhysicsObjectNum(i)
		if IsValid(p) then
			local d = p:GetPos():DistToSqr(pos)
			if not bestD or d < bestD then best, bestD = i, d end
		end
	end
	return best
end

local function OnBlunt(rag, st, pos, hands, now)
	local headN = select(2, Phys(rag, 10))
	local n = pos and NearestPhys(rag, pos)
	local onHead = n and n == headN
	if hands or onHead then
		StartGuard(st, now)
		Dbg("guard", hands and "fists/kick" or "blunt to head", tostring(rag))
		return
	end
	if not n or math.random(100) > cvHold:GetFloat() then Dbg("blunt hit, no hold (chance)") return end
	local p = rag:GetPhysicsObjectNum(n)
	local b = rag:TranslatePhysBoneToBone(n)
	local spot = {spot = true, phys = n, lpos = p:WorldToLocal(pos), bone = b and b >= 0 and rag:GetBoneName(b) or ""}
	StartHold(st, rag, spot, true)
	Dbg("blunt hit - holding", spot.bone)
	for _, h in pairs(st.holds) do if h.w == spot then h.untilT = now + math.Rand(2.5, 5) end end -- синяк - держится недолго
end

-- ================= 7) огонь и ток =================
-- горит (ragdoll:IsOnFire / урон огнём) - катается по земле вдоль оси тела, меняя сторону, руками сбивает пламя с груди,
-- ноги дёргаются; игрок сам катается A/D - не мешаем. Судороги - только во время эпилептического припадка
-- (org.seizureActive, система припадков Z-City; сам ток судорог не даёт - он только запускает припадок).
local LIMBS = {2, 3, 4, 6, 8, 9, 11, 12, 10}
local function ApplyFireShock(st, rag, now, dt, ply, ctrl)
	local org = st.org
	local burning = rag:IsOnFire() or (IsValid(ply) and ply:IsOnFire()) or now < (st.burnUntil or 0)
	if burning and cvFire:GetBool() and not (org and org.otrub) then
		local busy = ctrl
		local f, r, u, pelvis, spine = BodyFrame(rag)
		if f and not busy then
			if not st.roll or now > st.roll.untilT then
				st.roll = {dir = (st.roll and -st.roll.dir) or (math.random(2) == 1 and 1 or -1), untilT = now + math.Rand(0.9, 1.6)}
			end
			local k = math.min(Str(st), 2.5)
			local spin = u * (st.roll.dir * 260 * k) -- вокруг оси тела - перекат
			for _, p in ipairs({pelvis, spine}) do
				p:AddAngleVelocity((p:WorldToLocalVector(spin) - p:GetAngleVelocity()) * 0.08)
				p:AddVelocity(r * (st.roll.dir * 22 * k * dt * 10))
			end
			-- руки хлопают по груди, ноги дёргаются
			local t = now * 9
			local bL, bR = BusyHands(st, rag)
			if not bL and not (org and org.larmamputated) then Shadow(rag, 5, spine:GetPos() + f * (6 + math.sin(t) * 4) - r * 3, 90 * k, 14 * k) end
			if not bR and not (org and org.rarmamputated) then Shadow(rag, 7, spine:GetPos() + f * (6 + math.cos(t) * 4) + r * 3, 90 * k, 14 * k) end
			for _, n in ipairs({9, 12}) do
				local p = Phys(rag, n)
				if p then p:AddAngleVelocity(VectorRand(-1, 1) * 220 * k * dt * 10) end
			end
		end
	else
		st.roll = nil
	end
	if org and org.seizureActive and (org.seizureEnd or 0) > now then
		local left = org.seizureEnd - now
		local k = math.min(Str(st), 2.5) * math.Clamp(left / 3, 0.3, 1) -- к концу приступа слабеет
		for _, n in ipairs(LIMBS) do
			local p = Phys(rag, n)
			if p and math.random() < 0.6 then p:AddAngleVelocity(VectorRand(-1, 1) * 900 * k * dt * 10) end
		end
		local spine = Phys(rag, 1)
		if spine and math.random() < 0.15 then spine:AddVelocity(VectorRand(-1, 1) * 40 * k) end
	end
end

-- огонь и ток ловим отдельно: урон огнём по игроку в регдолле Z-City глушит раньше HomigradDamage.
-- Ток: с шансом rem_reag_epilepsy_chance - эпилептический припадок (система припадков Z-City, судороги - только в нём:
-- падает, бьётся, вспышки и звук на экране; hg.organism.StartEpilepsy - 20..40 с, не смертельный)
hook.Add("EntityTakeDamage", "rem_reagdoll_fire", function(target, dmg)
	if not cvOn:GetBool() or not IsValid(target) or not dmg:IsDamageType(DMG_BURN + DMG_SHOCK) then return end
	local now = CurTime()
	local ply = target:IsPlayer() and target or (target:IsRagdoll() and hg.RagdollOwner and hg.RagdollOwner(target)) or nil
	if dmg:IsDamageType(DMG_SHOCK) and IsValid(ply) and ply:Alive() and cvFire:GetBool() and (ply.remEpiNext or 0) < now then
		ply.remEpiNext = now + 1 -- ток бьёт каждый тик - бросок раз в секунду
		local org = ply.organism
		if org and not org.seizureActive and hg.organism.StartEpilepsy and math.random(100) <= cvEpi:GetFloat() then
			if hg.organism.StartEpilepsy(ply, org, math.Rand(20, 40)) then Dbg("epilepsy from shock", ply:Nick()) end
		end
	end
	local rag = target:IsRagdoll() and target or (target:IsPlayer() and target.FakeRagdoll) or nil
	local st = IsValid(rag) and R[rag]
	if not st or not st.alive then return end
	if dmg:IsDamageType(DMG_BURN) then st.burnUntil = now + 1.5 end
end)

-- ================= учёт регдоллов =================
local function Track(rag, ply, dead, moveVel)
	if not IsValid(rag) or not rag:IsRagdoll() then return end
	local now = CurTime()
	local st = R[rag]
	if not st then
		st = {ply = ply, holds = {}, grab = {}, grabNext = {}, air = 0, lastWound = 0, flailPhase = {}}
		-- характер тела - на всю жизнь человека (каждое падение чуть по-разному)
		local base = IsValid(ply) and ply.remReagMul
		if not base then
			base = RollMul()
			if IsValid(ply) then ply.remReagMul = base end
		end
		st.mul = base * math.Rand(0.9, 1.1)
		Dbg("body strength", IsValid(ply) and ply:Nick() or "?", math.Round(st.mul, 2))
		for i = 1, #FLAIL do st.flailPhase[i] = math.Rand(0, 1) end
		R[rag] = st
		rag:AddCallback("PhysicsCollide", function(e, data) TryGrab(e, data) end)
	end
	st.org = IsValid(ply) and ply.organism or rag.organism
	if dead then
		if st.alive == false then return end -- уже учли (умер, лёжа в регдолле)
		st.alive = false
		st.deathT = now
		for side in pairs(st.grab) do Release(st, side) end
		for _, h in pairs(st.holds) do h.untilT = now + DEATH_FADE end -- держит рану и мёртвым, угасая
	else
		st.alive = true
	end
	-- свежая рана: упал от попадания (или умер от него) - хватается и (если стоял) шатается
	local w, t = nil, nil
	if st.org then w, t = NewestWound(st.org) end
	if w and t > st.lastWound and now - t < WOUND_FRESH then
		st.lastWound = t
		-- пробует устоять, а свободной рукой - за рану (пока стоит - почти всегда)
		if now - t < 1 then StartBalance(st, rag, now, moveVel) end
		StartHold(st, rag, w, st.bal ~= nil and math.random() < 0.95)
	elseif IsValid(ply) and ply.remReagHit and now - ply.remReagHit.t < 1 then
		-- сбили без раны (кулак, пинок, дубинка) - тоже пробует устоять и закрывается / держится за ушиб
		local hit = ply.remReagHit
		ply.remReagHit = nil
		StartBalance(st, rag, now, moveVel)
		if not dead then OnBlunt(rag, st, hit.pos, hit.hands, now) end
	elseif dead and not st.bal then
		StartBalance(st, rag, now, moveVel) -- умер стоя без раны (кровопотеря, сердце) - тоже оседает
	end
end

hook.Add("PlayerSpawn", "rem_reagdoll", function(ply) ply.remReagMul = nil end) -- новая жизнь - новый характер

hook.Add("Fake", "rem_reagdoll", function(ply, rag)
	if not cvOn:GetBool() or not IsValid(ply) or not IsValid(rag) or ply:InVehicle() then return end
	local vel = ply:GetVelocity() -- шёл/бежал в момент падения - ещё пройдёт по инерции
	timer.Simple(0, function() if IsValid(rag) and IsValid(ply) then Track(rag, ply, false, vel) end end)
end)

hook.Add("DoPlayerDeath", "rem_reagdoll", function(ply)
	if not cvOn:GetBool() then return end
	local vel = ply:GetVelocity()
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		local rag = IsValid(ply.RagdollDeath) and ply.RagdollDeath or ply:GetNWEntity("RagdollDeath")
		if IsValid(rag) then Track(rag, ply, true, vel) end
	end)
end)

-- тупой удар (кулак, пинок, дубинка, бита): лежит - реагирует сразу; стоит - запоминаем, упадёт за 1 с - отреагирует.
-- Слушаем хук урона Z-City HomigradDamage (он есть на каждое попадание по человеку; Post-хук движка до регдолла
-- не доходил - Z-City сам перенаправляет и глушит урон) и Post как запасной; один удар - один раз.
local function OnClubHit(ent, ply, dmg)
	if not cvOn:GetBool() or not dmg:IsDamageType(DMG_CLUB) then return end
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	local now = CurTime()
	local tick = engine.TickCount()
	if ply.remReagTick == tick then return end
	ply.remReagTick = tick
	local wep = dmg:GetInflictor()
	local att = dmg:GetAttacker()
	-- руки/ноги: оружие "руки" или сам игрок (пинок из регдолла и т.п.)
	local hands = IsValid(wep) and (HANDS[wep:GetClass()] or wep:IsPlayer()) or (IsValid(att) and att:IsPlayer() and wep == att) or false
	if IsValid(att) and att:IsPlayer() and IsValid(wep) and wep == att:GetActiveWeapon() and HANDS[wep:GetClass()] then hands = true end
	local pos = dmg:GetDamagePosition()
	if pos == vector_origin then pos = nil end
	local rag = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or (IsValid(ent) and ent:IsRagdoll() and ent or nil)
	local st = IsValid(rag) and R[rag]
	if st and st.alive then
		OnBlunt(rag, st, pos, hands, now)
	else
		ply.remReagHit = {t = now, pos = pos, hands = hands}
		Dbg("club hit on standing", ply:Nick(), hands and "fists/kick" or "weapon")
	end
end

hook.Add("HomigradDamage", "rem_reagdoll", function(ply, dmg, hitgroup, ent)
	if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end -- fakePlayer
	OnClubHit(ent, ply, dmg)
end)

hook.Add("PostEntityTakeDamage", "rem_reagdoll", function(target, dmg)
	if not IsValid(target) then return end
	local ply = target:IsPlayer() and target or (target:IsRagdoll() and hg.RagdollOwner and hg.RagdollOwner(target)) or nil
	OnClubHit(target, ply, dmg)
end)

local lastThink = CurTime()
hook.Add("Think", "rem_reagdoll", function()
	local now = CurTime()
	local dt = math.Clamp(now - lastThink, 0, 0.1)
	lastThink = now
	if not cvOn:GetBool() then
		for rag, st in pairs(R) do
			if IsValid(rag) then for side in pairs(st.grab) do Release(st, side) end end
			R[rag] = nil
		end
		return
	end
	for rag, st in pairs(R) do
		local ply = st.ply
		if not IsValid(rag) then
			R[rag] = nil
			continue
		end
		if st.alive and IsValid(ply) and not ply:Alive() then
			-- умер в регдолле: держится за рану и мёртвым, угасая (DoPlayerDeath ниже сделает то же)
			st.alive, st.deathT = false, now
			if st.bal then st.bal.dur = math.min(st.bal.dur, now - st.bal.start + 0.8) end -- умер на ногах - оседает
			for side in pairs(st.grab) do Release(st, side) end
			for _, h in pairs(st.holds) do h.untilT = now + DEATH_FADE end
		end
		if st.alive and (not IsValid(ply) or ply.FakeRagdoll ~= rag) then
			-- встал (или регдолл больше не его) - отпускаем всё
			for side in pairs(st.grab) do Release(st, side) end
			R[rag] = nil
			continue
		end
		if not st.alive and now - (st.deathT or now) > DEATH_FADE + 1 then
			for side in pairs(st.grab) do Release(st, side) end
			R[rag] = nil
			continue
		end

		-- новая рана, пока лежит
		if st.org then
			local w, t = NewestWound(st.org)
			if w and t > st.lastWound and now - t < WOUND_FRESH then
				st.lastWound = t
				StartHold(st, rag, w)
			end
		end

		local busyL, busyR = BusyHands(st, rag)

		-- в воздухе?
		local pelvis = Phys(rag, 0)
		local coverArms = false
		if pelvis then
			local vel = pelvis:GetVelocity()
			local pos = pelvis:GetPos()
			local tr = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, 70), filter = {rag, ply}, mask = MASK_SOLID})
			local flying = not tr.Hit and (vel.z < -150 or vel:Length() > 500)
			if flying then
				if st.air == 0 then st.flailStart = now end
				st.air = st.air + dt
				-- перед землёй руками закрывается сам Z-City (fallCover) - руки ему
				local fall = -vel.z
				if st.alive and fall > 350 then
					local tr2 = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, fall), filter = {rag, ply}, mask = MASK_SOLID})
					coverArms = tr2.Hit
				end
				coverArms = coverArms or (st.alive and vel:LengthSqr() > 1000000)
			else
				st.air = 0
			end
		end

		-- игрок жмёт кнопки - управление его: стоять/шататься перестаёт, руки и ноги не трогаем
		-- (судороги при припадке остаются - там управления и так нет)
		local ctrl = Controlling(st, now)
		if ctrl and st.bal then st.bal = nil Dbg("player took control", tostring(rag)) end

		-- горит - катается, припадок - судороги
		if st.alive then ApplyFireShock(st, rag, now, dt, ply, ctrl) end
		if not ctrl then
			if st.bal then ApplyBalance(st, rag, now, dt) end
			ApplyHolds(st, rag, now, busyL, busyR)
			if st.guard then ApplyGuard(st, rag, now, busyL, busyR) end
			local conscious = st.alive and not (st.org and st.org.otrub)
			if cvFlail:GetBool() and st.air > 0.25 and (conscious or (not st.alive and now - (st.deathT or now) < DEATH_FLAIL)) then
				ApplyFlail(st, rag, now, busyL, busyR, coverArms)
			end
		else
			-- держание раны и блок по времени идут дальше: отпустил кнопки - рука вернётся к ране
			for side, h in pairs(st.holds) do if now > h.untilT then st.holds[side] = nil end end
			if st.guard and now > st.guard.untilT then st.guard = nil end
		end
		UpdateGrabs(st, rag, now, busyL or ctrl, busyR or ctrl)
	end
end)
