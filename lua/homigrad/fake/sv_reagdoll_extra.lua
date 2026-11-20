-- Дополнительные живые реакции регдолла - по мотивам мода Artagdoll [WIP], который прислал пользователь (его код,
-- анимации и звуки не брали - свой код поверх sv_reagdoll.lua: тот же учёт тел R, те же Shadow/Align/BodyFrame,
-- вызывается из его Think через hg.ReagExtra).
--  1) выстрел в голову насмерть (пуля/дробь, смерть за 0.7 с) - тело не хватается за рану и не оседает, а одно из:
--     обмяк сразу / обмякает за 1-2 с / короткое окоченение (конечности вытягиваются) / децеребрационная поза
--     (руки и ноги вытянуты, предплечья повёрнуты внутрь, кисти согнуты, голова назад, дрожь) 2.5..4.5 с;
--  2) кувырок: тело несётся по земле быстрее ~380 - катится по ходу движения, живой в сознании поджимается;
--  3) вода: живой в сознании, голова под водой - тянет руки вверх, бьёт ногами, голову к поверхности;
--  4) корчи: живой в сознании лежит с сильной болью (боль > ~50%) - подтягивает и выпрямляет колени, ворочается;
--  5) ползком: живой в сознании лежит на животе, жмёт W, руки свободны - подтягивается руками по очереди;
--  6) пальцы мёртвого тела - расслабленно полусогнуты (у децеребрации - сжаты);
--  7) гримаса боли на лице - NW2 rem_grimace (0..1 от боли), рисует cl_reagdoll_face.lua.
-- Квары: rem_reag_headshot, rem_reag_tumble, rem_reag_drown, rem_reag_writhe, rem_reag_crawl, rem_reag_fingers
-- (все 1); общий выключатель - rem_reag.
local cvHS = CreateConVar("rem_reag_headshot", "1", FCVAR_ARCHIVE, "Special death reactions to a fatal headshot (limp, stiffen, decerebrate)", 0, 1)
local cvTumble = CreateConVar("rem_reag_tumble", "1", FCVAR_ARCHIVE, "A body thrown along the ground rolls over", 0, 1)
local cvDrown = CreateConVar("rem_reag_drown", "1", FCVAR_ARCHIVE, "Conscious ragdoll with the head under water struggles to the surface", 0, 1)
local cvWrithe = CreateConVar("rem_reag_writhe", "1", FCVAR_ARCHIVE, "Conscious ragdoll in strong pain writhes on the ground", 0, 1)
local cvCrawl = CreateConVar("rem_reag_crawl", "1", FCVAR_ARCHIVE, "Lying on the stomach, W crawls forward on the arms", 0, 1)
local cvFingers = CreateConVar("rem_reag_fingers", "1", FCVAR_ARCHIVE, "Dead bodies' fingers curl naturally", 0, 1)
-- по просьбе: мёртвое тело - как у Z-City, без наших посмертных реакций (выстрел в голову, кувырок, пальцы)
local cvDead = CreateConVar("rem_reag_dead", "0", FCVAR_ARCHIVE, "Our reactions also on dead bodies (headshot posture, tumble, fingers)", 0, 1)

local cvHSKind = CreateConVar("rem_reag_headshot_kind", "", FCVAR_ARCHIVE, "Test: force the headshot reaction (drop / limp / stiffen / decerebrate), empty = random")
local HS_WINDOW = 0.7 -- смерть не позже стольких секунд после попадания в голову
local up = Vector(0, 0, 1)

-- Сломан позвоночник (Z-City: sv_bone spine1/2/3, пороги hg.organism.fake_spine*) - парализованное не двигаем.
-- Баг (скрин пользователя): упал, сломал позвоночник - кувырок/корчи тянули ноги к груди и крутили корпус, тело
-- выворачивало ногами за голову. 0 - цел, 1 - ноги (поясница), 2 - ниже груди, 3 - шея: всё.
function hg.SpineCut(org)
	if not org then return 0 end
	local O = hg.organism or {}
	if O.FractureTolerant and O.FractureTolerant(org) then return 0 end
	if (org.spine3 or 0) >= (O.fake_spine3 or 0.5) then return 3 end
	if (org.spine2 or 0) >= (O.fake_spine2 or 1) then return 2 end
	if (org.spine1 or 0) >= (O.fake_spine1 or 1) then return 1 end
	return 0
end

-- попадание пулей/дробью в голову: запоминаем время и направление
hook.Add("HomigradDamage", "rem_reag_extra", function(ply, dmg, hitgroup, ent)
	if hitgroup ~= HITGROUP_HEAD or not dmg:IsDamageType(DMG_BULLET + DMG_BUCKSHOT) then return end
	if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
	if not IsValid(ply) or not ply:IsPlayer() then return end
	ply.remHSHit = {t = CurTime(), dir = dmg:GetDamageForce():GetNormalized()}
end)

-- ================= пальцы =================
-- сгиб пальцев: тот же знак, что у хвата Z-City (sv_control: Finger*1 Angle(0, -45, 0) у обеих рук)
local function Fingers(rag, curl)
	for _, side in ipairs({"L", "R"}) do
		for i = 1, 4 do
			for seg, k in pairs({[""] = 0.5, ["1"] = 1, ["2"] = 0.8}) do
				local b = rag:LookupBone("ValveBiped.Bip01_" .. side .. "_Finger" .. i .. seg)
				if b then rag:ManipulateBoneAngles(b, Angle(0, -curl * k * (0.85 + i * 0.05), 0)) end
			end
		end
		local t = rag:LookupBone("ValveBiped.Bip01_" .. side .. "_Finger01")
		if t then rag:ManipulateBoneAngles(t, Angle(0, -curl * 0.4, 0)) end
	end
end

-- ================= 1) выстрел в голову =================
local function StartHeadshot(st, rag, now, hit)
	local H = hg.Reag
	local r = math.random()
	local kind = r < 0.3 and "drop" or r < 0.55 and "limp" or r < 0.8 and "stiffen" or "decerebrate"
	local forced = cvHSKind:GetString()
	if forced == "drop" or forced == "limp" or forced == "stiffen" or forced == "decerebrate" then kind = forced end
	local dur = kind == "drop" and 0 or kind == "limp" and math.Rand(1, 2)
		or kind == "stiffen" and math.Rand(0.4, 0.8) or math.Rand(2.5, 4.5)
	st.hs = {kind = kind, start = now, dur = dur}
	-- руки к ране не тянет, не оседает, не цепляется
	st.holds, st.bal, st.guard = {}, nil, nil
	for side in pairs(st.grab) do H.Release(st, side) end
	-- голову откидывает по ходу пули
	local head = H.Phys(rag, 10)
	if head and hit and hit.dir then head:AddVelocity(hit.dir * math.Rand(80, 160)) end
	if kind == "decerebrate" and cvFingers:GetBool() then Fingers(rag, 55) st.fingersDone = true end
	H.Dbg("headshot reaction", kind, math.Round(dur, 1))
end

local LIMB_ARMS = {{side = "L", sg = -1}, {side = "R", sg = 1}}
local LIMB_LEGS = {{thigh = 11, calf = 12, foot = 14, amp = "llegamputated"}, {thigh = 8, calf = 9, foot = 13, amp = "rlegamputated"}}

local function ApplyHeadshot(st, rag, now)
	local hs = st.hs
	local t = now - hs.start
	-- пока реакция идёт - ни держания раны, ни оседания (Track/Think их могли снова поставить)
	st.holds, st.bal = {}, nil
	if t > hs.dur then return end
	if hs.kind == "drop" or hs.kind == "limp" then return end -- обмяк: просто ничего не делаем

	local H = hg.Reag
	local f, r, u = H.BodyFrame(rag)
	if not f then return end
	local org = st.org
	local fade = hs.kind == "decerebrate" and math.Clamp((hs.dur - t) / (hs.dur * 0.3), 0, 1) or 1
	local tremor = hs.kind == "decerebrate" and (1 + math.sin(now * 23) * 0.35) or 1
	local gain, blend = 9 * tremor, 0.35 * fade

	for _, a in ipairs(LIMB_ARMS) do
		local arm = H.ARM[a.side]
		if not (org and org[arm.amp]) then
			local up_, fore, hand = H.Phys(rag, arm.upper), H.Phys(rag, arm.fore), H.Phys(rag, arm.hand)
			-- окоченение: руки в стороны и вниз; децеребрация: вдоль тела вниз
			local dir = hs.kind == "stiffen" and (-u * 0.5 + r * (a.sg * 0.9)) or (-u + r * (a.sg * 0.15) + f * 0.1)
			dir:Normalize()
			if up_ then H.Align(up_, dir, gain, blend) end
			if fore then
				H.Align(fore, dir, gain, blend)
				-- предплечье повёрнуто внутрь (пронация) - вращение вокруг своей оси
				if hs.kind == "decerebrate" then fore:AddAngleVelocity(Vector(a.sg * 260 * fade * tremor, 0, 0) * 0.1) end
			end
			-- кисть согнута к ладони
			if hand then
				local hdir = hs.kind == "decerebrate" and (dir - f * 0.9) or dir
				hdir:Normalize()
				H.Align(hand, hdir, gain * 0.7, blend)
			end
		end
	end
	for _, L in ipairs(LIMB_LEGS) do
		if not (org and org[L.amp]) then
			for _, n in ipairs({L.thigh, L.calf}) do
				local p = H.Phys(rag, n)
				if p then H.Align(p, -u, gain, blend) end
			end
			local foot = H.Phys(rag, L.foot)
			if foot and hs.kind == "decerebrate" then H.Align(foot, -u, gain * 0.6, blend) end
		end
	end
	-- голова запрокинута
	if hs.kind == "decerebrate" then
		local head = H.Phys(rag, 10)
		if head then
			local d = u - f * 0.7
			d:Normalize()
			H.Align(head, d, gain * 0.5, blend * 0.6)
		end
	end
end

-- ================= 2) кувырок =================
local function ApplyTumble(st, rag, now, dt, conscious, ctrl)
	local H = hg.Reag
	local pelvis, spine = H.Phys(rag, 0), H.Phys(rag, 1)
	if not (pelvis and spine) then return end
	local v = pelvis:GetVelocity()
	local vh = Vector(v.x, v.y, 0)
	local speed = vh:Length()
	local tb = st.tumble
	if not tb then
		if speed < 380 or now < (st.tumbleNext or 0) then return end
		local pos = pelvis:GetPos()
		local tr = util.TraceLine({start = pos, endpos = pos - Vector(0, 0, 45), filter = {rag, st.ply}, mask = MASK_SOLID})
		if not tr.Hit then return end
		tb = {untilT = now + math.Rand(1.2, 2.4)}
		st.tumble = tb
		st.tumbleNext = now + 4
		H.Dbg("tumble", math.Round(speed))
	end
	if now > tb.untilT or speed < 120 then st.tumble = nil return end
	-- катится по ходу: ось = вверх x направление (как шар по земле)
	local d = vh / speed
	local axis = up:Cross(d)
	local w = math.min(speed / 9 * 57, 700) * math.Clamp((tb.untilT - now) / 0.6, 0, 1)
	-- сломанный позвоночник: корпус не докручиваем - таз и грудь крутило в разные стороны, тело выворачивало
	if hg.SpineCut(st.org) >= 1 then w = 0 end
	for _, p in ipairs({pelvis, spine}) do
		local want = p:WorldToLocalVector(axis * w)
		p:AddAngleVelocity((want - p:GetAngleVelocity()) * 0.08)
	end
	-- в сознании поджимается: руки к голове, колени к груди (что парализовано - не поджимает)
	local cut = hg.SpineCut(st.org)
	if conscious and not ctrl and cut < 3 then
		local f, r, u, _, sp, head = H.BodyFrame(rag)
		if f then
			local k = H.Str(st)
			local hp = head:GetPos()
			for side, a in pairs(H.ARM) do
				if not (st.org and st.org[a.amp]) and not st.holds[side] and not st.grab[side] then
					local sg = side == "R" and 1 or -1
					H.Shadow(rag, a.hand, hp + f * 4 + r * (4 * sg), 120 * k, 18 * k)
				end
			end
			local pz = pelvis:GetPos()
			for _, L in ipairs({{calf = 9, amp = "rlegamputated", sg = 1}, {calf = 12, amp = "llegamputated", sg = -1}}) do
				if cut == 0 and not (st.org and st.org[L.amp]) then H.Shadow(rag, L.calf, pz + f * 12 + r * (4 * L.sg), 30 * k, 12 * k) end
			end
		end
	end
end

-- ================= 3) вода =================
local function HeadInWater(rag, H)
	local head = H.Phys(rag, 10)
	if not head then return nil end
	local pos = head:GetPos()
	if bit.band(util.PointContents(pos), CONTENTS_WATER) == 0 then return nil end
	return head, pos
end

local function ApplyDrown(st, rag, now, busyL, busyR)
	local H = hg.Reag
	local head, hp = HeadInWater(rag, H)
	if not head then st.drownT = nil return false end
	st.drownT = st.drownT or now
	local t = now - st.drownT
	local k = H.Str(st) * math.Clamp(1 - t / 25, 0.3, 1) -- устаёт
	local f, r = H.BodyFrame(rag)
	if not f then return true end
	-- руки по очереди вверх, к поверхности
	for side, a in pairs(H.ARM) do
		local busy = (side == "L" and busyL) or (side == "R" and busyR)
		if not busy and not (st.org and st.org[a.amp]) and not st.holds[side] then
			local sg = side == "R" and 1 or -1
			local ph = math.sin(now * 5 + (sg > 0 and 0 or math.pi))
			H.Shadow(rag, a.hand, hp + up * (22 + ph * 12) + r * (14 * sg) + f * (ph * 6), 140 * k, 20 * k)
		end
	end
	-- голову к поверхности, ноги бьют
	head:AddVelocity(up * 90 * k * FrameTime() * 10)
	if hg.SpineCut(st.org) >= 1 then return true end -- ноги парализованы
	for i, n in ipairs({8, 11}) do
		local p = H.Phys(rag, n)
		if p then p:AddAngleVelocity(Vector(0, math.sin(now * 9 + i * math.pi) * 380 * k, 0) * 0.15) end
	end
	return true
end

-- ================= 4) корчи от боли =================
local function ApplyWrithe(st, rag, now, dt)
	local org = st.org
	local pain = org and org.pain or 0
	if pain < 60 then st.writhe = nil return end
	local cut = hg.SpineCut(org)
	if cut >= 2 then st.writhe = nil return end -- ниже груди не чувствует - не корчится
	local H = hg.Reag
	local f, r, u, pelvis, spine = H.BodyFrame(rag)
	if not f then return end
	local pz = pelvis:GetPos()
	local tr = util.TraceLine({start = pz, endpos = pz - Vector(0, 0, 30), filter = {rag, st.ply}, mask = MASK_SOLID})
	if not tr.Hit then return end
	local w = st.writhe or {phase = math.Rand(0, 6), seed = math.Rand(0, 6)}
	st.writhe = w
	local k = math.Clamp((pain - 60) / 60, 0.2, 1) * H.Str(st)
	w.phase = w.phase + dt * (0.8 + pain / 150)
	-- колени: то подтягивает, то выпрямляет (по очереди)
	for i, L in ipairs({{calf = 9, amp = "rlegamputated", sg = 1}, {calf = 12, amp = "llegamputated", sg = -1}}) do
		if cut == 0 and not (org and org[L.amp]) then
			local bend = (math.sin(w.phase + i * 1.7) + 1) * 0.5
			H.Shadow(rag, L.calf, pz + f * (4 + bend * 12) - u * (16 - bend * 10) + r * (5 * L.sg), 18 * k, 10 * k)
		end
	end
	-- ворочается с боку на бок
	local roll = math.sin(w.phase * 0.6 + w.seed) * 45 * k
	spine:AddAngleVelocity((spine:WorldToLocalVector(u * roll) - spine:GetAngleVelocity()) * 0.05)
end

-- ================= 5) ползком =================
local function ApplyCrawl(st, rag, now, ply, busyL, busyR)
	if busyL or busyR or not IsValid(ply) or ply.FakeRagdoll ~= rag or not ply:KeyDown(IN_FORWARD) then st.crawl = nil return end
	local org = st.org
	if org and (org.otrub or org.canmove == false) then return end
	local H = hg.Reag
	local f, r, u, pelvis, spine, head = H.BodyFrame(rag)
	if not f then return end
	if f:Dot(-up) < 0.35 then st.crawl = nil return end -- не на животе
	-- куда ползёт - куда смотрит макушка
	local dir = Vector(u.x, u.y, 0)
	if dir:LengthSqr() < 0.01 then return end
	dir:Normalize()
	local c = st.crawl or {start = now}
	st.crawl = c
	local k = H.Str(st)
	local cycle = (now - c.start) / 1.1
	local hp = head:GetPos()
	for side, a in pairs(H.ARM) do
		if not (org and org[a.amp]) then
			local sg = side == "R" and 1 or -1
			-- одна рука тянется вперёд, другая подтягивает к груди
			local reach = (math.sin(cycle * math.pi * 2 + (sg > 0 and 0 or math.pi)) + 1) * 0.5
			local target = hp + dir * (6 + reach * 18) + r * (9 * sg) - up * 6
			H.Shadow(rag, a.hand, target, 90 * k, 16 * k)
		end
	end
	-- тело подтягивается рывками, когда рука гребёт
	local pull = math.max(math.sin(cycle * math.pi * 4), 0)
	for _, p in ipairs({spine, pelvis}) do
		local v = p:GetVelocity()
		local want = dir * (20 + pull * 30)
		p:AddVelocity(Vector(want.x - v.x, want.y - v.y, 0) * 0.08)
	end
end

-- ================= общий вызов из sv_reagdoll.lua =================
function hg.ReagExtra(st, rag, now, dt, ply, ctrl, busyL, busyR)
	if not hg.Reag then return end
	local org = st.org
	local conscious = st.alive and not (org and org.otrub)

	-- мёртвое тело - как у Z-City (rem_reag_dead 0)
	if not st.alive and not cvDead:GetBool() then return end
	-- тело отдано моду Artagdoll (compat/sh_artagdoll.lua) - реакции его, наши не тянут то же тело
	if rag.remArtag then return end

	if not st.alive then
		if not st.hsChecked then
			st.hsChecked = true
			local hit = IsValid(ply) and ply.remHSHit
			if cvHS:GetBool() and hit and math.abs((st.deathT or now) - hit.t) < HS_WINDOW then StartHeadshot(st, rag, now, hit) end
		end
		if st.hs then ApplyHeadshot(st, rag, now) end
		if cvFingers:GetBool() and not st.fingersDone and now - (st.deathT or now) > 0.4 then
			st.fingersDone = true
			Fingers(rag, math.Rand(18, 32))
		end
	end

	if cvTumble:GetBool() then ApplyTumble(st, rag, now, dt, conscious, ctrl) end
	if not conscious or ctrl then return end
	if hg.SpineCut(org) >= 3 then return end -- сломана шея: не двигается совсем

	if cvDrown:GetBool() and ApplyDrown(st, rag, now, busyL, busyR) then return end
	if st.air == 0 and not st.bal and not st.guard and not st.tumble then
		if cvCrawl:GetBool() then ApplyCrawl(st, rag, now, ply, busyL, busyR) end
		if cvWrithe:GetBool() and not st.crawl and not hg.Reag.Moving(ply) then ApplyWrithe(st, rag, now, dt) end
	end
end

-- ================= 7) гримаса боли (для клиента) =================
timer.Create("rem_reag_grimace", 0.25, 0, function()
	for _, ply in player.Iterator() do
		local org = ply.organism
		local v = 0
		if ply:Alive() and org and not org.otrub then v = math.Clamp(((org.pain or 0) - 15) / 85, 0, 1) end
		v = math.Round(v, 2)
		if math.abs(ply:GetNW2Float("rem_grimace", 0) - v) >= 0.05 or (v == 0 and ply:GetNW2Float("rem_grimace", 0) ~= 0) then
			ply:SetNW2Float("rem_grimace", v)
		end
	end
end)

hook.Add("PlayerSpawn", "rem_reag_extra", function(ply) if OverrideSpawn then return end ply.remHSHit = nil end)
