-- Client half of the respiratory module's test scenes (developer tool). Inert unless the test
-- harness is running (lua/advancedblood/client/cl_selftest.lua) and has asked for a scene of this
-- module. What it measures goes to the harness's client log.

local RS = HemoRespiratory
RS.NoJIT()
if not RS.testRun or RS.Quiet then return end
local T = istable(ABL) and ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local C, CK, CL, RG, DR, LK = RS.Config, RS.Clock, RS.CL, RS.Rig, RS.Draw, RS.Link
local SK = HemoSkeleton
local M = SK.M
local abs, max, min = math.abs, math.max, math.min

local fails, checks = 0, 0
local function L(fmt, ...) Log("resp: " .. string.format(fmt, ...)) end
local function Check(ok, fmt, ...)
	checks = checks + 1
	if not ok then fails = fails + 1 end
	Log("resp: " .. (ok and "ok    " or "FAIL  ") .. string.format(fmt, ...))
	return ok
end

local function Body(t)
	local e = Entity(t.ent or -1)
	if not IsValid(e) then return nil end
	return e:IsPlayer() and SK.BodyOf(e) or e
end

------------------------------------------------------------------------------------------
-- Where the model's named corners stand on a body against that body's skeleton
------------------------------------------------------------------------------------------
local function Sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function Dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function Len(a) return math.sqrt(Dot(a, a)) end

-- For a pose (of a body, or the stock skeleton at rest) and a way to get a mark: the body's own
-- axes from its skeleton (to its left: from the right fifth rib to the left; up: from the twelfth
-- chest vertebra to the first), and every mark's place along them.
local function Frame(pose, markAt)
	local function B(id) local x, y, z = pose:BonePos(id) return x and { x, y, z } or nil end
	local function Mid(a, b) return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 } end
	local rl, rr, t1, t12, st, t7 = B("rib5_l"), B("rib5_r"), B("t1"), B("t12"), B("sternum"), B("t7")
	local r1l, r1r, r10l, r10r = B("rib1_l"), B("rib1_r"), B("rib10_l"), B("rib10_r")
	if not (rl and rr and t1 and t12 and st and t7 and r1l and r1r and r10l and r10r) then return nil, "the skeleton has no rib1, rib5, rib10 (left and right), t1, t12, t7 or sternum on this body" end
	local mid = Mid(rl, rr)
	local left = Sub(rl, rr)
	local wide = Len(left)
	left = { left[1] / wide, left[2] / wide, left[3] / wide }
	local up = Sub(t1, t12)
	local tall = Len(up)
	up = { up[1] / tall, up[2] / tall, up[3] / tall }
	-- forward: from the column to the sternum
	local fwd = Sub(st, t7)
	local deep = Len(fwd)
	fwd = { fwd[1] / deep, fwd[2] / deep, fwd[3] / deep }
	-- the ribs' own frame (the lungs go with the ribs, and a body model's ribs are fitted by themselves:
	-- its column and its sternum need not lie to them as they do in the stock skeleton): up from the
	-- tenth pair's middles to the first's, forward square to that and to the left
	local top, bot = Mid(r1l, r1r), Mid(r10l, r10r)
	local rup = Sub(top, bot)
	local rtall = Len(rup)
	rup = { rup[1] / rtall, rup[2] / rtall, rup[3] / rtall }
	local rf = { left[2] * rup[3] - left[3] * rup[2], left[3] * rup[1] - left[1] * rup[3], left[1] * rup[2] - left[2] * rup[1] }
	local rl2 = Len(rf)
	rf = { rf[1] / rl2, rf[2] / rl2, rf[3] / rl2 }
	local f = { wide = wide, tall = tall, deep = deep, rtall = rtall, marks = {} }
	for id in pairs(RS.RigData.marks) do
		local x, y, z = markAt(id)
		if x then
			local p = { x, y, z }
			f.marks[id] = { side = Dot(Sub(p, mid), left) / wide, level = Dot(Sub(p, t12), up) / tall, front = Dot(Sub(p, t7), fwd) / deep,
				rlevel = Dot(Sub(p, bot), rup) / rtall, rfront = Dot(Sub(p, mid), rf) / wide }
		end
	end
	return f
end

local IDENT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }
local restFrame
local function RestFrame()
	if restFrame then return restFrame end
	local pose = SK.Pose.Rest()
	local ctl = { dl = 0, dr = 0, fl = 1, fr = 1 }
	restFrame = Frame(pose, function(id) return RG.Mark(id, function() return IDENT end, ctl) end)
	return restFrame
end

local curPose
local function Skin(key) return curPose:Skin(key) end
local SIDES = { apex = true, base = true, side = true, front = true, back = true, hilum = true, dome = true }

-- Left and right, front and back, and the levels of things on a body, against the same in the
-- stock skeleton at rest. Returns how many checks failed.
local function PlaceCheck(body, tag, hold)
	local before = fails
	local pose, why = SK.PoseOf(body)
	if not Check(pose ~= nil, "%s: the body has a skeleton (%s)", tag, tostring(why or "")) then return 1 end
	pose:Fresh()
	curPose = pose
	local ctl = {}
	DR.Controls(body, hold, ctl)
	local f, bad = Frame(pose, function(id) return RG.Mark(id, Skin, ctl) end)
	curPose = nil
	local rf = RestFrame()
	if not Check(f ~= nil and rf ~= nil, "%s: the skeleton's ribs, column and sternum are found (%s)", tag, tostring(bad or "")) then return 1 end
	-- left is left
	local wrong = {}
	for id, m in pairs(f.marks) do
		local stem, s = string.match(id, "^(%a+)_([lr])$")
		if stem and SIDES[stem] then
			if (s == "l") ~= (m.side > 0) then wrong[#wrong + 1] = id end
		end
	end
	Check(#wrong == 0, "%s: every corner of the left lung, its root and its half of the diaphragm lies on the body's left, the right's on its right%s (the lungs' sides at %.2f and %.2f of the width between the fifth ribs' middles)",
		tag, #wrong > 0 and (" EXCEPT " .. table.concat(wrong, ", ")) or "", f.marks.side_l.side, f.marks.side_r.side)
	Check(abs(f.marks.carina.side) < 0.2 and abs(f.marks.trachea_top.side) < 0.2, "%s: the windpipe and its fork lie in the middle (%.2f, %.2f)", tag, f.marks.trachea_top.side, f.marks.carina.side)
	-- order from top to bottom
	local mk = f.marks
	Check(mk.trachea_top.level > mk.apex_l.level - 0.08 and mk.apex_l.level > mk.carina.level and mk.apex_r.level > mk.carina.level and mk.carina.level > mk.dome_r.level and mk.dome_r.level > mk.base_r.level - 0.02
		and mk.dome_l.level > mk.base_l.level - 0.02 and mk.base_r.level > mk.rim_low.level and mk.base_l.level > mk.rim_low.level,
		"%s: from the top: windpipe %.2f, the lungs' tops %.2f %.2f, the fork %.2f, the domes %.2f %.2f, the lungs' lowest corners %.2f %.2f, the diaphragm's lowest %.2f (0 the twelfth chest vertebra, 1 the first)",
		tag, mk.trachea_top.level, mk.apex_l.level, mk.apex_r.level, mk.carina.level, mk.dome_l.level, mk.dome_r.level, mk.base_l.level, mk.base_r.level, mk.rim_low.level)
	-- behind the sternum
	Check(mk.front_l.front < 1.02 and mk.front_r.front < 1.02 and mk.back_l.front > -0.6 and mk.back_r.front > -0.6,
		"%s: the lungs' foremost corners lie behind the sternum's middle (%.2f, %.2f of the way from the column to it), their hindmost beside the column (%.2f, %.2f)", tag, mk.front_l.front, mk.front_r.front, mk.back_l.front, mk.back_r.front)
	-- Against the stock skeleton at rest: has anything moved against the bones. The lungs and the
	-- diaphragm against the ribs (which carry them); the windpipe against the column and the sternum.
	local worst, which, sum, n = 0, "", 0, 0
	local aworst, awhich = 0, ""
	-- (while the body breathes, the lungs' bases, their roots and the domes are meant to move: left out then)
	local breathing = hold ~= 0
	for id, m in pairs(f.marks) do
		local r = rf.marks[id]
		local stem = string.match(id, "^(%a+)_")
		if r and not (breathing and (stem == "base" or stem == "dome" or stem == "hilum")) then
			if id == "trachea_top" or id == "carina" then
				local d = max(abs(m.side - r.side) * f.wide, abs(m.level - r.level) * f.tall, abs(m.front - r.front) * f.deep)
				if d > aworst then aworst, awhich = d, id end
			else
				local d = max(abs(m.side - r.side) * f.wide, abs(m.rlevel - r.rlevel) * f.rtall, abs(m.rfront - r.rfront) * f.wide)
				sum, n = sum + d, n + 1
				if d > worst then worst, which = d, id end
			end
		end
	end
	-- (What this number is: how far a corner lies from where a chest that was the stock one made evenly
	-- wider and taller would have it. Every pair of ribs has a fit of its own on a body model, so on
	-- the female models, whose cage tapers, a corner that goes with its own ribs is up to a unit from
	-- there: measured 0.86 to 1.03, against 0.4 on the male ones. The bound is set to catch a lung in
	-- the wrong place, a rib's spacing and more off; whether a lung's surface clears the ribs' is
	-- measured by the generator, on the models' own triangles.)
	Check(worst < 1.25, "%s: the lungs' and the diaphragm's corners against the same in the stock skeleton at rest, measured from this body's own ribs (the fifth pair across, the tenth to the first upward): the farthest off is %s by %.2f units, %.2f on average (ribs %.1f wide, %.1f tall here; %.1f, %.1f there)",
		tag, which, worst, n > 0 and sum / n or 0, f.wide, f.rtall, rf.wide, rf.rtall)
	L("%s: the windpipe against this body's column and sternum: %s is %.2f units from where it lies in the stock skeleton (chest %.1f tall, %.1f deep here; %.1f, %.1f there)", tag, awhich, aworst, f.tall, f.deep, rf.tall, rf.deep)
	return fails - before
end

------------------------------------------------------------------------------------------
local hookN = 0
local function EachFrame(secs, fn, done)
	hookN = hookN + 1
	local name = "RS_Test" .. hookN
	local till = CurTime() + secs
	hook.Add("Think", name, function()
		if CurTime() >= till then
			hook.Remove("Think", name)
			if done then done() end
			return
		end
		fn()
	end)
end

local function ModelEnts()
	local n = 0
	for _, e in ipairs(ents.GetAll()) do
		local m = e:GetModel()
		if m and string.find(m, "models/hemogen/", 1, true) and not string.find(m, "/dev/", 1, true) then n = n + 1 end
	end
	return n
end

local follow

function H.resp(t)
	local step = t.step
	if step == "check" then
		local bad = RS.CheckStructures()
		Check(#bad == 0, "structures: %d, sum %d, %d complaint(s)%s", #RS.StructList, RS.STRUCT_SUM, #bad, #bad > 0 and (": " .. table.concat(bad, "; ")) or "")
		local D = RS.RigData
		if not Check(istable(D), "the table of bones is there") then return end
		local ok = RG.Ready()
		Check(ok, "the models are made: %s %s", RG.state, RG.note)
		if not ok then return end
		for _, def in ipairs(D.models) do
			local e = RG.ents[def.id]
			local ent = e and e.ent
			Check(IsValid(ent) and ent:GetBoneCount() == #def.bones, "%s: %s, %d bones in the model, %d in the table; materials: %s", def.path, tostring(ent), IsValid(ent) and ent:GetBoneCount() or -1, #def.bones,
				IsValid(ent) and table.concat(ent:GetMaterials(), ", ") or "?")
			if IsValid(ent) then
				local missing = {}
				for _, mat in ipairs(ent:GetMaterials()) do
					local m = Material(mat)
					if m:IsError() then missing[#missing + 1] = mat end
				end
				Check(#missing == 0, "%s: every material is found%s", def.id, #missing > 0 and (" EXCEPT " .. table.concat(missing, ", ")) or "")
			end
		end
		local rf = RestFrame()
		if rf then
			local m = rf.marks
			L("the stock skeleton at rest: chest %.1f wide (between the fifth ribs' middles), %.1f tall (T12 to T1), %.1f deep (T7 to sternum); lungs' tops at level %.2f %.2f, lowest corners %.2f %.2f, fork %.2f, windpipe's top %.2f",
				rf.wide, rf.tall, rf.deep, m.apex_l.level, m.apex_r.level, m.base_l.level, m.base_r.level, m.carina.level, m.trachea_top.level)
		end
	elseif step == "place" or step == "inside" then
		local body = Body(t)
		if not Check(IsValid(body), "%s: the body is there", tostring(t.tag)) then return end
		PlaceCheck(body, tostring(t.tag), step == "place" and 0 or nil)
		if step == "place" then
			local pose = SK.PoseOf(body)
			L("%s: fit %s; the frame before: %d bod%s drawn, %d model(s), %.2f ms", tostring(t.tag), pose and pose.fit and tostring(pose.fit.src) or "?", DR.stats.last.bodies, DR.stats.last.bodies == 1 and "y" or "ies", DR.stats.last.models, DR.stats.last.ms)
		end
	elseif step == "clock" then
		local body = Body(t)
		local c = body and CL.ClockOf(body)
		if not Check(c ~= nil, "the client has the character's clock") then return end
		local now = CurTime()
		local mine = CK.PhaseAt(c, now)
		local theirs = (t.phase + t.rate / 60 * (now - t.t)) % 1
		local d = abs((mine - theirs + 0.5) % 1 - 0.5)
		Check(d < 0.03 and c.mode == t.mode and abs(c.rate - t.rate) < 1 and abs(c.depth - t.depth) < 0.11,
			"this client's clock against the server's, both brought to now: phase %.3f against %.3f (%.3f of a breath, %.0f ms apart); rate %.2f against %.2f, depth %.2f against %.2f; heard %.2f s ago, %d message(s) in all",
			mine, theirs, d, d * 60 / max(c.rate, 1) * 1000, c.rate, t.rate, c.depth, t.depth, RealTime() - c.got, CL.stats.clocks)
	elseif step == "trace" then
		-- the lungs' lowest corners, read each frame in the chest's own space
		local body = Body(t)
		if not IsValid(body) then return end
		local rowsT, rowsL, rowsR, rowsC = {}, {}, {}, {}
		local scale = {}
		local bone = body:LookupBone("ValveBiped.Bip01_Spine2")
		local live = CL.ClockOf(body)
		-- (the clock as it was when this began: the table itself goes on changing)
		local c0 = live and { rate = live.rate, depth = live.depth } or nil
		local ctl = {}
		local inv = {}
		EachFrame(t.secs, function()
			local pose = SK.PoseOf(body)
			if not pose then return end
			pose:Fresh()
			local chest = pose:Skin("spine_up")
			if not chest or not M.Inv(chest, inv) then return end
			curPose = pose
			DR.Controls(body, nil, ctl)
			local rx, ry, rz = RG.Mark("base_r", Skin, ctl)
			local lx, ly, lz = RG.Mark("base_l", Skin, ctl)
			curPose = nil
			local _, _, zr = M.Xf(inv, rx, ry, rz)
			local _, _, zl = M.Xf(inv, lx, ly, lz)
			local n = #rowsT + 1
			rowsT[n], rowsR[n], rowsL[n], rowsC[n] = CurTime(), zr, zl, (ctl.vl + ctl.vr) * 0.5 * min(ctl.depth, 1)
			local s = bone and body:GetManipulateBoneScale(bone)
			scale[n] = s and s.x or 1
		end, function()
			local n = #rowsT
			if n < 10 then Check(false, "%s: only %d frames", tostring(t.tag), n) return end
			local secs = rowsT[n] - rowsT[1]
			local loR, hiR, loL, hiL = 1e9, -1e9, 1e9, -1e9
			for i = 1, n do loR, hiR, loL, hiL = min(loR, rowsR[i]), max(hiR, rowsR[i]), min(loL, rowsL[i]), max(hiL, rowsL[i]) end
			-- the fastest it moved, and the largest change of speed from one frame to the next
			local vmax, jump, same = 0, 0, 0
			local pv
			for i = 2, n do
				local dt = rowsT[i] - rowsT[i - 1]
				if dt > 1e-5 then
					local v = (rowsR[i] - rowsR[i - 1]) / dt
					vmax = max(vmax, abs(v))
					if pv then jump = max(jump, abs(v - pv)) end
					pv = v
				end
				if abs((hiR - rowsR[i]) / max(hiR - loR, 1e-6) - (hiL - rowsL[i]) / max(hiL - loL, 1e-6)) < 1e-4 then same = same + 1 end
			end
			-- breaths counted: times the corner passes its middle going down
			local midR, breaths = (loR + hiR) / 2, 0
			for i = 2, n do if rowsR[i - 1] > midR and rowsR[i] <= midR then breaths = breaths + 1 end end
			local c = c0 or {}
			local rate, depth = c.rate or 0, c.depth or 1
			if t.loose then
				-- rate and depth were changing all the while: only that nothing jumps or jerks, against the
				-- fastest and deepest the clock was in that time
				local c1 = CL.ClockOf(body) or c
				local r1, d1 = max(rate, c1.rate or 0), max(depth, c1.depth or 1)
				local tr = RS.RigData.diaMax * min(d1 * C.Breath.quietDia, 1)
				local vw = tr * (math.pi / 2) / max((CK.Shares(r1)), 0.01) * r1 / 60
				L("%s: %d frames in %.2f s (%.0f a second); the clock went from %.1f a minute, depth %.2f to %.1f, %.2f; the right lung's lowest corner travelled %.3f units", tostring(t.tag), n, secs, n / secs, rate, depth, c1.rate or 0, c1.depth or 0, hiR - loR)
				Check(vmax < vw * 1.15 + 0.03, "%s: the fastest it moves is %.2f units a second (a breath in at the fastest and deepest of that time: %.2f): no jump", tostring(t.tag), vmax, vw)
				Check(jump < vw * 0.3 + 0.03, "%s: the largest change of its speed from one frame to the next is %.3f units a second: no jerk", tostring(t.tag), jump)
				return
			end
			-- what the rule says: the base's travel for this depth, and the fastest a breath in goes
			local travel = RS.RigData.diaMax * min(depth * C.Breath.quietDia, 1)
			local a = CK.Shares(rate)
			local vWant = travel * (math.pi / 2) / max(a, 0.01) * rate / 60
			L("%s: %d frames in %.2f s (%.0f a second); clock %.1f a minute, depth %.2f", tostring(t.tag), n, secs, n / secs, rate, depth)
			Check(abs((hiR - loR) - travel) < travel * 0.2 + 0.03, "%s: the right lung's lowest corner travels %.3f units (the rule for this depth: about %.3f), the left's %.3f", tostring(t.tag), hiR - loR, travel, hiL - loL)
			Check(abs(breaths - secs * rate / 60) <= 1.01, "%s: %d breath(s) in %.1f s (the clock's rate gives %.2f)", tostring(t.tag), breaths, secs, secs * rate / 60)
			Check(vmax < vWant * 1.15 + 0.03, "%s: the fastest it moves is %.2f units a second (a breath in at this rate and depth: %.2f): no jump", tostring(t.tag), vmax, vWant)
			Check(jump < vWant * 0.3 + 0.03, "%s: the largest change of its speed from one frame to the next is %.3f units a second: no jerk", tostring(t.tag), jump)
			Check(same < n * 0.9, "%s: the two lungs are not one movement drawn twice (in %d of %d frames they stand at the same share of their travel)", tostring(t.tag), same, n)
			-- Z-City's chest against the clock
			local pulse = istable(body.organism) and tonumber(body.organism.pulse) or 70
			local dev = 0
			for i = 2, n do dev = max(dev, abs(scale[i] - (1 + 0.05 * rowsC[i] * max(pulse / 70, 0.5)))) end
			L("%s: Z-City's chest bone against the clock's breath: largest difference of its scale %.4f (the whole movement is %.4f)", tostring(t.tag), dev, 0.05 * max(pulse / 70, 0.5) * min(depth, 1))
		end)
	elseif step == "follow" then
		if t.on then
			follow = Entity(t.ent)
			hook.Add("Think", "RS_TestFollow", function()
				local e = IsValid(follow) and SK.BodyOf(follow)
				local b = IsValid(e) and e:LookupBone("ValveBiped.Bip01_Spine2")
				local m = b and e:GetBoneMatrix(b)
				if not m then return end
				local c = m:GetTranslation()
				local pos = c + Vector(44, 16, 6)
				H.view({ pos = pos, ang = (c - pos):Angle() })
			end)
		else
			hook.Remove("Think", "RS_TestFollow")
			follow = nil
		end
	elseif step == "chest" then
		local body = Body(t)
		if not IsValid(body) then return end
		local bone = body:LookupBone("ValveBiped.Bip01_Spine2")
		local set0 = RS.Chest.stats.set
		local lo, hi, dev, n = 1e9, -1e9, 0, 0
		local ctl = {}
		EachFrame(t.secs, function()
			local s = bone and body:GetManipulateBoneScale(bone)
			if not s then return end
			DR.Controls(body, nil, ctl)
			local pulse = istable(body.organism) and tonumber(body.organism.pulse) or 70
			local want = 1 + 0.05 * (ctl.vl + ctl.vr) * 0.5 * min(ctl.depth, 1) * max(pulse / 70, 0.5)
			lo, hi, dev, n = min(lo, s.x), max(hi, s.x), max(dev, abs(s.x - want)), n + 1
		end, function()
			local set = RS.Chest.stats.set - set0
			local on = C.sv.chest:GetBool()
			if on then
				Check(set > n * 0.8 and dev < 0.006 and hi - lo > 0.01, "%s: Z-City's chest clock was set %d time(s) in %d frames; the chest bone's scale went from %.4f to %.4f and was never more than %.4f from what the breathing clock says", tostring(t.tag), set, n, lo, hi, dev)
			else
				Check(set == 0 and hi - lo > 0.01, "%s: Z-City's chest clock was set %d time(s) in %d frames: Z-City's own breath runs (the scale went from %.4f to %.4f; %.4f from the module's clock at the most)", tostring(t.tag), set, n, lo, hi, dev)
			end
		end)
	elseif step == "rec" then
		local body = Body(t)
		local r = body and CL.Record(body)
		if not Check(r ~= nil, "%s: the client has the record of %s", tostring(t.tag), tostring(body)) then return end
		L("%s: %s | airway %.2f%s | left %.2f/%.2f/%.2f can %.2f | right %.2f/%.2f/%.2f can %.2f | pleural air %.2f | could load %.2f | oxygen %.2f of %.2f | wants %.2f -> %.1f a minute, depth %.2f | brain %s | %d asked",
			tostring(t.tag), r.label, r.patency, r.blocked and (" BLOCKED:" .. tostring(r.why)) or "", r.damageL, r.breachL, r.collapseL, r.shareL, r.damageR, r.breachR, r.collapseR, r.shareR, r.pneumothorax, r.exchange, r.oxygen, r.ceiling,
			r.want, r.targetRate, r.targetDepth, r.control and string.format("%.2f pattern %d", r.control, r.pattern) or "none", r.mods)
	elseif step == "fill" then
		local body = Body(t)
		if not IsValid(body) then return end
		local ctl = {}
		local lo, hi = 1e9, -1e9
		EachFrame(0.5, function()
			DR.Controls(body, nil, ctl)
			local v = (ctl.vl + ctl.vr) * 0.5
			lo, hi = min(lo, v), max(hi, v)
		end, function()
			Check(abs(hi - t.want) < 0.03 and abs(lo - t.want) < 0.03, "%s: for half a second the breath stands between %.3f and %.3f of full (it should stand at %.2f)", tostring(t.tag), lo, hi, t.want)
		end)
	elseif step == "collapse" then
		local body = Body(t)
		if not IsValid(body) then return end
		local ctl = {}
		DR.Controls(body, 0, ctl)
		local pose = SK.PoseOf(body)
		if not pose then return end
		pose:Fresh()
		curPose = pose
		local f = Frame(pose, function(id) return RG.Mark(id, Skin, ctl) end)
		local whole = { dl = 0, dr = 0, fl = 1, fr = 1 }
		local g = Frame(pose, function(id) return RG.Mark(id, Skin, whole) end)
		curPose = nil
		if not f or not g then return end
		Check(ctl.fl < 0.3 and ctl.fr > 0.99 and f.marks.side_l.side < g.marks.side_l.side * 0.8 and abs(f.marks.side_r.side - g.marks.side_r.side) < 1e-4,
			"%s: the left lung stands at %.2f of its place and its side has come in from %.2f to %.2f of the chest's width; the right lung at %.2f, its side where it was (%.2f)", tostring(t.tag), ctl.fl, g.marks.side_l.side, f.marks.side_l.side, ctl.fr, f.marks.side_r.side)
		local r, gg, b = LK.Tint(ctl.rec and ctl.rec.damageL or 0, ctl.rec and ctl.rec.collapseL or 0)
		L("%s: the left lung's colour is taken down to %.2f %.2f %.2f of its own", tostring(t.tag), r, gg, b)
	elseif step == "life" then
		local e = Entity(t.ent or -1)
		if not IsValid(e) then L("%s: the entity is not there on this client", tostring(t.tag)) return end
		local body = e:IsPlayer() and SK.BodyOf(e) or e
		local owner = CL.OwnerOf(body)
		local c = CL.ClockOf(body)
		local ctl = {}
		DR.Controls(body, nil, ctl)
		L("%s: body %s (%s); its living character %s; clock %s; record %s; breath %.2f/%.2f -> diaphragm %.2f/%.2f, in place %.2f/%.2f; models %s, %d entit(ies) of them; %d bod(ies) drawn the frame before",
			tostring(t.tag), tostring(body), tostring(body:GetModel()), tostring(owner), c and string.format("%s %.1f a minute depth %.2f%s, heard %.1f s ago", CK.ModeName[c.mode], c.rate, c.depth, c.sym and " even" or "", RealTime() - c.got) or "none",
			CL.Record(body) and CL.Record(body).label or "none", ctl.vl, ctl.vr, ctl.dl, ctl.dr, ctl.fl, ctl.fr, RG.state, ModelEnts(), DR.stats.last.bodies)
		PlaceCheck(body, tostring(t.tag), nil)
	elseif step == "left" then
		local watched = table.Count(CL.watched)
		Check(ModelEnts() == 0 and next(RG.ents) == nil and watched == 0 and table.Count(CL.recs) == 0, "%s: %d entit(ies) of the models left, %d kept by the rig, %d bod(ies) still watched, %d record(s) kept",
			tostring(t.tag), ModelEnts(), table.Count(RG.ents), watched, table.Count(CL.recs))
		L("%s: %d clock(s) known; in all %d clock message(s) and %d record(s) heard; the models were made %d time(s); %d check(s) on this client so far, %d failed", tostring(t.tag), table.Count(CL.clocks), CL.stats.clocks, CL.stats.recs, RG.stats.made, checks, fails)
	elseif step == "gone" then
		L("the character that left (entity %d): its clock on this client is %s", t.idx, CL.clocks[t.idx] and "still kept" or "gone")
	elseif step == "perf" then
		local n, t0 = 0, SysTime()
		local calls0, set0 = RG.stats.calls, RS.Chest.stats.set
		local a = DR.stats.all
		local ms0, drawn0 = a.ms, a.bodies
		EachFrame(t.secs, function() n = n + 1 end, function()
			local secs = SysTime() - t0
			local ms, drawn = a.ms - ms0, a.bodies - drawn0
			L("perf, %s: %d frames in %.2f s: %.1f a second, %.2f ms a frame; of that the lung view %.3f ms a frame for %.1f bod(ies) drawn a frame (%.3f ms a body); bones handed to the engine %.1f time(s) a frame; Z-City's chest clock set %.1f time(s) a frame",
				tostring(t.tag), n, secs, n / secs, secs / n * 1000, ms / n, drawn / n, drawn > 0 and ms / drawn or 0, (RG.stats.calls - calls0) / n, (RS.Chest.stats.set - set0) / n)
		end)
	elseif step == "chestcost" then
		-- what setting Z-City's chest clock costs: the handler itself, called many times over
		local body = Body(t)
		local fn = (hook.GetTable()["Player-Ragdoll think"] or {})["RS_Chest"]
		if not IsValid(body) or not fn then L("chest handler: not there") return end
		local n = 20000
		local t0 = SysTime()
		for _ = 1, n do fn(body, body) end
		local per = (SysTime() - t0) / n * 1e6
		Check(per < 15, "setting Z-City's chest clock for one body costs %.2f microseconds (once for each body the game draws, each time it draws it)", per)
	end
end
