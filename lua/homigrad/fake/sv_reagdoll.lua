-- Живые реакции регдолла (по мотивам мода ReAgdoll, свой код поверх управления регдоллом Z-City - sv_control.lua):
--  1) хватается за рану: свежая рана (org.wounds / org.arterialwounds) -> свободная рука (не раненая, не отрубленная, не
--     занятая игроком) тянется к ней и держит; в сознании - 4..10 с, без сознания слабо, у мёртвого - угасает за DEATH_FADE;
--  2) пошатнулся и осел: упал в регдолл стоя от попадания (рана моложе 1 с) или умер стоя - первые 0.7..1.4 с тело
--     частично держит вес (верх сильнее низа) и покачивается, потом подкашивается - не валится мешком сразу;
--  3) машет руками и ногами в полёте (падение с высоты, отбросило); руки не трогаем, когда Z-City закрывается ими
--     перед землёй (fallCover в sv_control.lua);
--  4) цепляется рукой: в полёте/при падении рука в сознании задела стену или край - на 1.5..4 с держится (ballsocket).
-- Пока игрок сам управляет рукой (ЛКМ / ПКМ / E, оружие, свой захват ConsLH/ConsRH, ручное зажатие раны) - её не трогаем.
local cvOn = CreateConVar("rem_reag", "1", FCVAR_ARCHIVE, "Ragdoll reactions: hold wounds, stagger, flail, grab ledges", 0, 1)
local cvHold = CreateConVar("rem_reag_hold_chance", "80", FCVAR_ARCHIVE, "Chance (%) to grab a fresh wound", 0, 100)
local cvStagger = CreateConVar("rem_reag_stagger", "1", FCVAR_ARCHIVE, "Stagger before collapsing when shot down", 0, 1)
local cvFlail = CreateConVar("rem_reag_flail", "1", FCVAR_ARCHIVE, "Flail limbs while flying/falling", 0, 1)
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

local R = {} -- [регдолл] = состояние

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

local function WoundStillThere(org, w)
	for _, list in ipairs({org.wounds, org.arterialwounds}) do
		if istable(list) then
			for _, x in pairs(list) do if x == w then return true end end
		end
	end
	return false
end

local function WoundBoneName(rag, w)
	local b = w[4]
	if isnumber(b) then return rag:GetBoneName(b) end
	return b
end

local function WoundPos(rag, w)
	local b = w[4]
	if isstring(b) then b = rag:LookupBone(b) end
	if not isnumber(b) or b < 0 then return nil end
	local bp, ba = rag:GetBonePosition(b)
	if not bp then return nil end
	return (LocalToWorld(w[2] or vector_origin, w[3] or angle_zero, bp, ba))
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
		if gun or (IsValid(wep) and wep.ismelee) then Rr = true end
		if ply:KeyDown(IN_ATTACK) then L = true end
		if ply:KeyDown(IN_ATTACK2) then Rr = true end
	end
	return L, Rr
end

-- ================= 1) хватается за рану =================
local function StartHold(st, rag, w)
	if math.random(100) > cvHold:GetFloat() then return end
	local org = st.org
	local bone = WoundBoneName(rag, w) or ""
	local canL = not (org and org.larmamputated) and not LEFT_ARM[bone]
	local canR = not (org and org.rarmamputated) and not RIGHT_ARM[bone]
	if not canL and not canR then return end
	local arterial = w[7] ~= nil
	local useL, useR
	if canL and canR then
		local d = math.random()
		if arterial or d > 0.66 then useL, useR = true, true elseif d > 0.33 then useL = true else useR = true end
	else
		useL, useR = canL, canR
	end
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
	local s = HoldStrength(st, now)
	for side, h in pairs(st.holds) do
		local busy = (side == "L" and busyL) or (side == "R" and busyR)
		if now > h.untilT or s <= 0.02 or (st.org and (now - h.start) > 0.5 and not WoundStillThere(st.org, h.w)) then
			st.holds[side] = nil
		elseif not busy then
			local pos = WoundPos(rag, h.w)
			local a = ARM[side]
			local hand, handN = Phys(rag, a.hand)
			local fore = Phys(rag, a.fore)
			local upper = Phys(rag, a.upper)
			if pos and hand and fore and upper and not Floppy(rag, handN) then
				-- как ручное зажатие Z-City: плечо, предплечье, кисть - каждое к своей точке перед раной
				local fade = math.min((now - h.start) / 0.35, 1) -- рука тянется, а не прыгает
				local k = s * fade
				local function To(phys, off) local d = pos - phys:GetPos() return d:LengthSqr() > 0.01 and pos - d:GetNormalized() * off or pos end
				hg.ShadowControl(rag, a.upper, 0.06, nil, nil, nil, To(upper, 14), 18 * k, 12 * k)
				hg.ShadowControl(rag, a.fore, 0.06, nil, nil, nil, To(fore, 8), 55 * k, 14 * k)
				hg.ShadowControl(rag, a.hand, 0.06, nil, nil, nil, To(hand, 3), 55 * k, 14 * k)
			end
		end
	end
end

-- ================= 2) пошатнулся и осел =================
-- таз над землёй: стоя ~35-40, лёжа ~5-10
local function pos_z_above(pelvis, tr) return pelvis:GetPos().z - tr.HitPos.z end
local function StartStagger(st, rag, now)
	if not cvStagger:GetBool() then return end
	local pelvis = Phys(rag, 0)
	local spine = Phys(rag, 1)
	if not pelvis or not spine then return end
	if pelvis:GetVelocity():Length() > 260 then return end -- отбросило (взрыв и т.п.) - сразу летит
	local tr = util.TraceLine({start = pelvis:GetPos(), endpos = pelvis:GetPos() - Vector(0, 0, 60), filter = {rag, st.ply}, mask = MASK_SOLID})
	if not tr.Hit or pos_z_above(pelvis, tr) < 22 then return end -- не на ногах (лежит или в воздухе)
	st.stagger = {start = now, dur = math.Rand(0.7, 1.4), nextSway = 0}
end

local function ApplyStagger(st, rag, now, dt)
	local sg = st.stagger
	local t = (now - sg.start) / sg.dur
	if t >= 1 then st.stagger = nil return end
	local k = (1 - t) ^ 1.5 -- держит вес всё слабее - колени подкашиваются
	local g = physenv.GetGravity() * dt
	-- противовес тяжести: верх держится сильнее низа - сначала оседает, а не падает плашмя
	local lift = {[0] = 0.75, [1] = 0.95, [10] = 0.95, [8] = 0.5, [11] = 0.5, [9] = 0.35, [12] = 0.35}
	for n, m in pairs(lift) do
		local p = Phys(rag, n)
		if p then p:AddVelocity(-g * m * k) end
	end
	-- покачивается: короткие толчки корпуса в стороны (шаг, другой - и падает)
	if now >= sg.nextSway then
		sg.nextSway = now + math.Rand(0.18, 0.32)
		local spine = Phys(rag, 1)
		if spine then
			local v = VectorRand(-1, 1)
			v.z = 0
			spine:AddVelocity(v:GetNormalized() * 45 * k)
		end
	end
end

-- ================= 3) машет в полёте =================
local function ApplyFlail(st, rag, now, busyL, busyR, coverArms)
	local org = st.org
	local t = now - st.flailStart
	local strength = st.alive and 1 or math.Clamp(1 - (now - (st.deathT or now)) / DEATH_FLAIL, 0, 1)
	if strength <= 0 then return end
	for i, f in ipairs(FLAIL) do
		local skip = (org and org[f.amp]) or (f.arm == "L" and (busyL or coverArms or st.holds.L or st.grab.L))
			or (f.arm == "R" and (busyR or coverArms or st.holds.R or st.grab.R))
		if not skip then
			local p, num = Phys(rag, f.n)
			if p and not Floppy(rag, num) then
				local ph = st.flailPhase[i]
				local w = 7 + ph * 3
				local av = Vector(math.sin(t * w + ph * 6) * 0.35, math.sin(t * w * 0.8 + ph * 4) * 0.6, math.cos(t * w + ph * 9)) * f.a * strength
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

-- ================= учёт регдоллов =================
local function Track(rag, ply, dead)
	if not IsValid(rag) or not rag:IsRagdoll() then return end
	local now = CurTime()
	local st = R[rag]
	if not st then
		st = {ply = ply, holds = {}, grab = {}, grabNext = {}, air = 0, lastWound = 0, flailPhase = {}}
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
		StartHold(st, rag, w)
		if now - t < 1 then StartStagger(st, rag, now) end
	elseif dead and not st.stagger then
		StartStagger(st, rag, now) -- умер стоя без раны (кровопотеря, сердце) - тоже оседает
	end
end

hook.Add("Fake", "rem_reagdoll", function(ply, rag)
	if not cvOn:GetBool() or not IsValid(ply) or not IsValid(rag) or ply:InVehicle() then return end
	timer.Simple(0, function() if IsValid(rag) and IsValid(ply) then Track(rag, ply, false) end end)
end)

hook.Add("DoPlayerDeath", "rem_reagdoll", function(ply)
	if not cvOn:GetBool() then return end
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		local rag = IsValid(ply.RagdollDeath) and ply.RagdollDeath or ply:GetNWEntity("RagdollDeath")
		if IsValid(rag) then Track(rag, ply, true) end
	end)
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

		if st.stagger then ApplyStagger(st, rag, now, dt) end
		ApplyHolds(st, rag, now, busyL, busyR)
		local conscious = st.alive and not (st.org and st.org.otrub)
		if cvFlail:GetBool() and st.air > 0.25 and (conscious or (not st.alive and now - (st.deathT or now) < DEATH_FLAIL)) then
			ApplyFlail(st, rag, now, busyL, busyR, coverArms)
		end
		UpdateGrabs(st, rag, now, busyL, busyR)
	end
end)
