-- Client half of the module's test scenarios (developer tool). Inert unless
-- garrysmod/data/abl_selftest.txt exists on this machine.

NeuroTrauma.NoJIT()
if not NeuroTrauma.testRun then return end
local NT = NeuroTrauma
local CL = NT.CL
local P = NT.Pose
local OUT = "abl_test/client_neuro.txt"

local function Log(s)
	file.CreateDir("abl_test")
	file.Append(OUT, string.format("%8.2f %s\n", CurTime(), s))
end

local function DumpRecords(tag)
	Log("dump " .. tostring(tag))
	local n = 0
	for ply, r in pairs(CL.records) do
		n = n + 1
		Log(string.format("   %s: version %d state %d overlays %d motor L %.2f R %.2f balance %.2f consciousness %.2f walking %d/15 posture %d seizure phase %d side %d pupils %.2f %.2f seed %d age %.2f",
			IsValid(ply) and ply:Nick() or "?", r.version or -1, r.state, r.overlays, r.motorL, r.motorR, r.balance, r.consciousness, r.moveQ, r.posture, r.seizurePhase, r.seizureSide, r.pupilL, r.pupilR, r.seed, CurTime() - r.t))
		Log(string.format("      detail %s: arm L %.2f R %.2f hand L %.2f R %.2f leg L %.2f R %.2f face L %.2f R %.2f coordination L %.2f R %.2f hand state L %d R %d gaze %d veer %d circulation %d category %d | level of detail %s",
			tostring(r.detail), r.armL, r.armR, r.handL, r.handR, r.legL, r.legR, r.faceL, r.faceR, r.coordL, r.coordR, r.handStateL, r.handStateR, r.gaze, r.veerQ, r.cardio, r.category, tostring(r.lod)))
	end
	Log(string.format("   %d records | messages taken %d, dropped as stale %d", n, CL.taken, CL.stale))
end

net.Receive("nt_test2", function()
	local cmd, arg = net.ReadString(), net.ReadString()
	if cmd == "panel" then
		RunConsoleCommand("neuro_debug", arg)
	elseif cmd == "dump" then
		DumpRecords(arg)
	end
end)

------------------------------------------------------------------------------------------
-- Measuring what the pose controller did to a body
------------------------------------------------------------------------------------------
local B = "ValveBiped.Bip01_"
local base = {}

-- positions of some bones in the body's own frame (forward, left, up), from the pelvis
local function Snapshot(ent)
	ent:InvalidateBoneCache()
	ent:SetupBones()
	local id = ent:LookupAttachment("eyes")
	local att = id and id > 0 and ent:GetAttachment(id)
	local pelvis = ent:LookupBone(B .. "Pelvis")
	local pm = pelvis and ent:GetBoneMatrix(pelvis)
	if not att or not pm then return nil end
	local ya = Angle(0, att.Ang.y, 0)
	local F, R, U = ya:Forward(), ya:Right(), ya:Up()
	local o = pm:GetTranslation()
	local snap = {}
	for _, name in ipairs({ "R_Forearm", "R_Hand", "L_Forearm", "L_Hand", "R_Foot", "L_Foot", "R_Toe0", "L_Toe0", "Head1", "Spine2", "R_Calf", "L_Calf" }) do
		local b = ent:LookupBone(B .. name)
		local m = b and ent:GetBoneMatrix(b)
		if m then
			local v = m:GetTranslation() - o
			snap[name] = Vector(v:Dot(F), -v:Dot(R), v:Dot(U))
		end
	end
	-- how far the fingertips are from the wrist: a closed hand brings them in
	for _, s in ipairs({ "R", "L" }) do
		local hand, tip = ent:LookupBone(B .. s .. "_Hand"), ent:LookupBone(B .. s .. "_Finger22")
		local hm, tm = hand and ent:GetBoneMatrix(hand), tip and ent:GetBoneMatrix(tip)
		if hm and tm then snap["tip" .. s] = (tm:GetTranslation() - hm:GetTranslation()):Length() end
	end
	return snap
end

local function Manip(ent, name)
	local b = ent:LookupBone(B .. name)
	if not b then return "-" end
	local a = ent:GetManipulateBoneAngles(b)
	return string.format("(%.0f %.0f %.0f)", a.p, a.y, a.r)
end

local H = {}

function H.pose_base(t)
	if IsValid(t.ent) then base[t.ent] = Snapshot(t.ent) end
end

function H.pose_measure(t)
	local ent = t.ent
	if not IsValid(ent) then Log("pose_measure: no entity") return end
	local s, b = Snapshot(ent), base[ent]
	local r = CL.records[ent]
	Log(string.format("pose [%s] record %s | level of detail %s | profile: %s", tostring(t.tag), r and "yes" or "no", tostring(r and r.lod),
		P.Profile(ent) and string.format("%d bones, fingers L %s R %s, toes L %s R %s", P.Profile(ent).count, tostring(P.Profile(ent).fingers.L), tostring(P.Profile(ent).fingers.R), tostring(P.Profile(ent).toes.L), tostring(P.Profile(ent).toes.R)) or "none"))
	if not s or not b then return end
	local function D(name) local d = s[name] - b[name] return string.format("%s (%+.1f %+.1f %+.1f)", name, d.x, d.y, d.z) end
	Log("   moved (forward, left, up): " .. D("R_Hand") .. " " .. D("L_Hand") .. " " .. D("R_Forearm") .. " " .. D("L_Forearm") .. " " .. D("R_Foot") .. " " .. D("L_Foot") .. " " .. D("Head1") .. " " .. D("Spine2"))
	Log(string.format("   fingertip to wrist: right %.1f (was %.1f), left %.1f (was %.1f)", s.tipR or -1, b.tipR or -1, s.tipL or -1, b.tipL or -1))
	Log("   layers: R_Clavicle " .. Manip(ent, "R_Clavicle") .. " L_Clavicle " .. Manip(ent, "L_Clavicle") .. " R_Forearm " .. Manip(ent, "R_Forearm") .. " L_Forearm " .. Manip(ent, "L_Forearm")
		.. " R_Hand " .. Manip(ent, "R_Hand") .. " L_Hand " .. Manip(ent, "L_Hand") .. " R_Finger1 " .. Manip(ent, "R_Finger1") .. " L_Finger1 " .. Manip(ent, "L_Finger1")
		.. " R_Calf " .. Manip(ent, "R_Calf") .. " L_Calf " .. Manip(ent, "L_Calf") .. " R_Foot " .. Manip(ent, "R_Foot") .. " L_Foot " .. Manip(ent, "L_Foot") .. " Spine1 " .. Manip(ent, "Spine1") .. " Head1 " .. Manip(ent, "Head1"))
	local flex = {}
	for _, name in ipairs({ "left_corner_depressor", "right_corner_depressor", "left_lid_droop", "right_lid_droop", "jaw_clencher", "half_closed" }) do
		local id = ent:GetFlexIDByName(name)
		if id then flex[#flex + 1] = string.format("%s %.2f", name, ent:GetFlexWeight(id)) end
	end
	Log("   face: " .. table.concat(flex, ", "))
end

function H.rag_measure(t)
	local ply = t.ent
	local rag = IsValid(ply) and P.RagOf(ply)
	if not IsValid(rag) then Log("rag_measure [" .. tostring(t.tag) .. "]: no ragdoll on the client") return end
	local s = Snapshot(rag)
	local r = CL.records[ply]
	Log(string.format("ragdoll [%s] record %s posture %s seizure phase %s | fingertip to wrist: right %.1f left %.1f | R_Finger1 %s L_Finger1 %s R_Finger0 %s R_Toe0 %s L_Toe0 %s",
		tostring(t.tag), r and "yes" or "no", tostring(r and r.posture), tostring(r and r.seizurePhase), s and s.tipR or -1, s and s.tipL or -1,
		Manip(rag, "R_Finger1"), Manip(rag, "L_Finger1"), Manip(rag, "R_Finger0"), Manip(rag, "R_Toe0"), Manip(rag, "L_Toe0")))
	local flex = {}
	for _, name in ipairs({ "left_corner_depressor", "right_corner_depressor", "jaw_clencher", "bite", "left_stretcher" }) do
		local id = rag:GetFlexIDByName(name)
		if id then flex[#flex + 1] = string.format("%s %.2f", name, rag:GetFlexWeight(id)) end
	end
	Log("   face: " .. table.concat(flex, ", "))
end

-- Fingers under a held weapon: over a run of drawn frames, does the layer hold or do two writers
-- take turns?
local flicker
function H.flicker(t)
	flicker = { ent = t.ent, left = t.frames or 30, tag = t.tag, yaws = {}, tips = {} }
end
hook.Add("PostPlayerDraw", "NT_TestFlicker", function(ply)
	local f = flicker
	if not f or ply ~= f.ent then return end
	local b = ply:LookupBone(B .. "R_Finger1")
	local hand, tip = ply:LookupBone(B .. "R_Hand"), ply:LookupBone(B .. "R_Finger12")
	local hm, tm = hand and ply:GetBoneMatrix(hand), tip and ply:GetBoneMatrix(tip)
	if b and hm and tm then
		f.yaws[#f.yaws + 1] = ply:GetManipulateBoneAngles(b).y
		f.tips[#f.tips + 1] = (tm:GetTranslation() - hm:GetTranslation()):Length()
	end
	f.left = f.left - 1
	if f.left <= 0 then
		flicker = nil
		local function Range(list)
			local lo, hi = math.huge, -math.huge
			for _, v in ipairs(list) do lo, hi = math.min(lo, v), math.max(hi, v) end
			return lo, hi
		end
		local ylo, yhi = Range(f.yaws)
		local tlo, thi = Range(f.tips)
		Log(string.format("flicker [%s] %d drawn frames: layer on the index knuckle between %.1f and %.1f degrees; fingertip to wrist between %.2f and %.2f units -> %s",
			tostring(f.tag), #f.yaws, ylo, yhi, tlo, thi, (thi - tlo) < 0.4 and "steady" or "NOT steady: two writers"))
	end
end)

-- Stale and reordered messages, fed to the receiver by hand.
function H.stale(t)
	local ply = t.ent
	local r = IsValid(ply) and CL.records[ply]
	if not r then Log("stale: no record of the bot on this client") return end
	local idx = ply:EntIndex()
	local v = r.version
	local stale0 = CL.stale
	local fields = {}
	for k, val in pairs(r) do if k ~= "cur" and k ~= "version" and k ~= "t" and k ~= "born" then fields[k] = val end end
	local function Try(name, version, present, expect)
		local took = CL.Take(idx, version % 256, present, table.Copy(fields))
		Log(string.format("   %-58s version %3d -> %s%s", name, version % 256, took and "taken" or "dropped", took == expect and "" or "   UNEXPECTED"))
		return took == expect
	end
	Log(string.format("stale: the client holds version %d of %s", v, ply:Nick()))
	local ok = true
	ok = Try("the same message again", v, true, false) and ok
	ok = Try("an older one that arrives late", v - 3, true, false) and ok
	ok = Try("the next one", v + 1, true, true) and ok
	ok = Try("the one before it, overtaken", v, true, false) and ok
	ok = Try("one from half a turn away (cannot be newer)", v + 1 + 128, true, false) and ok
	CL.records[ply].version = 250
	ok = Try("across the wrap of the counter (250 -> 3)", 3 + 256, true, true) and ok
	ok = Try("the record closes", 4, false, true) and ok
	ok = Try("a message from before the close arrives late", 3, true, false) and ok
	ok = Try("a new record after the close", 6, true, true) and ok
	Log(string.format("   %s | dropped as stale in this test: %d", ok and "PASS: every message was taken or dropped as it should be" or "FAIL", CL.stale - stale0))
	-- (the next real message of the server puts the record right)
	if CL.records[ply] then CL.records[ply].version = nil end
end

function H.self(t)
	local s = CL.self
	if not s then Log("self [" .. tostring(t.tag) .. "]: no losses") return end
	Log(string.format("self [%s]: field lost left up %.2f down %.2f, right up %.2f down %.2f | neglect L %.2f R %.2f | hearing lost %.2f | understanding lost %.2f reading lost %.2f | memory lost %.2f attention lost %.2f | sedation %.2f",
		tostring(t.tag), s.visUL, s.visLL, s.visUR, s.visLR, s.neglectL, s.neglectR, s.hearing, s.comprehension, s.reading, s.memory, s.attention, s.sedation))
end

function H.read(t)
	local other = player.GetBots()[1]
	local tbl = { t.text }
	local res = hook.Run("HG_OnPlayerChat", other, tbl, false, false, color_white, "Bot", false)
	Log(string.format("read: '%s' -> '%s'%s", t.text, tostring(tbl[1]), res and " (not shown)" or ""))
end

function H.posestats(t)
	local st = P.stats
	Log(string.format("pose controller [%s]: %d calls, %.1f bones per call, %.1f us per call, %.3f ms in total", tostring(t.tag), st.calls, st.bones / math.max(st.calls, 1), st.time / math.max(st.calls, 1) * 1e6, st.time * 1000))
	st.calls, st.bones, st.time = 0, 0, 0
	-- what this client knows of who lies
	local n, rag, nw, hidden = 0, 0, 0, 0
	local lods = { [0] = 0, 0, 0, 0, 0 }
	local near, far = math.huge, 0
	for ply in pairs(CL.records) do
		if IsValid(ply) then
			n = n + 1
			if IsValid(ply.FakeRagdoll) then rag = rag + 1 end
			if IsValid(ply:GetNWEntity("FakeRagdoll")) then nw = nw + 1 end
			if ply:GetNoDraw() or ply:GetRenderMode() == RENDERMODE_NONE then hidden = hidden + 1 end
			if not P.RagOf(ply) then
				local l = P.Level(ply)
				lods[l] = lods[l] + 1
				local d = EyePos():Distance(ply:GetPos())
				near, far = math.min(near, d), math.max(far, d)
			end
		end
	end
	Log(string.format("   records %d | ragdolled as Z-City's client field says %d, as the network variable says %d | player model hidden %d | frame time %.1f ms", n, rag, nw, hidden, RealFrameTime() * 1000))
	Log(string.format("   standing, by level of detail: 0: %d, 1: %d, 2: %d, 3: %d, 4: %d | from the camera %.0f to %.0f units", lods[0], lods[1], lods[2], lods[3], lods[4], near < math.huge and near or 0, far))
end

function H.dump(t) DumpRecords(t.tag) end

-- How many times this client drew a standing body for a character in a critical animation state.
function H.authority(t)
	if t.reset then P.stats.criticalStanding = 0 return end
	local n = P.stats.criticalStanding or 0
	Log(string.format("authority: a critical state on a body drawn standing in %d calls of the pose controller", n))
	net.Start("nt_test4")
	net.WriteString("authority")
	net.WriteTable({ frames = n })
	net.SendToServer()
end

-- Where to put the camera to look at a part of a body: from the bones as this client draws them.
function H.viewpart(t)
	local ent = t.ent
	if not IsValid(ent) then return end
	ent:SetupBones()
	local id = ent:LookupAttachment("eyes")
	local att = id and id > 0 and ent:GetAttachment(id)
	if not att then return end
	local ya = Angle(0, att.Ang.y, 0)
	local F, R = ya:Forward(), ya:Right()
	local function Bone(name)
		local b = ent:LookupBone(B .. name)
		local m = b and ent:GetBoneMatrix(b)
		return m and m:GetTranslation() or ent:GetPos()
	end
	local part, lying = t.part, t.lying
	local look, pos
	if part == "face" then
		look = att.Pos - att.Ang:Up() * 1.5
		pos = look + att.Ang:Forward() * 30
	elseif part == "handR" or part == "handL" then
		look = Bone(part == "handR" and "R_Hand" or "L_Hand") - Vector(0, 0, lying and 0 or 3)
		pos = lying and (look + Vector(3, 2, 22)) or (look + F * 17 + R * (part == "handR" and 9 or -9) + Vector(0, 0, 1))
	elseif part == "hands" then
		look = (Bone("R_Hand") + Bone("L_Hand")) * 0.5 - Vector(0, 0, 3)
		pos = look + F * 36
	elseif part == "feet" then
		look = (Bone("R_Foot") + Bone("L_Foot")) * 0.5
		pos = lying and (look + Vector(4, 3, 30)) or (look + F * 34 + R * 14 + Vector(0, 0, 12))
	else
		look = Bone("Spine1")
		pos = lying and (look + Vector(10, 6, 95)) or (look + F * 95 + R * 30 + Vector(0, 0, 8))
	end
	net.Start("nt_test3")
	net.WriteVector(pos)
	net.WriteVector(look)
	net.SendToServer()
end

------------------------------------------------------------------------------------------
-- What a body does as this client draws it, over some seconds: the last link of the chain from
-- an injury to the screen. Bone positions are taken every frame in the body's own frame (from
-- the pelvis: toward the front, the left, the head), and the result is sent back to the server,
-- where the checks are.
------------------------------------------------------------------------------------------
local motions = {}
local MNAMES = { "Pelvis", "Spine2", "Head1", "R_UpperArm", "L_UpperArm", "R_Forearm", "L_Forearm", "R_Hand", "L_Hand", "R_Thigh", "L_Thigh", "R_Calf", "L_Calf", "R_Foot", "L_Foot" }
local TRACKED = { "R_Hand", "L_Hand", "R_Foot", "L_Foot", "R_Calf", "L_Calf", "Head1" }

function H.motion(t)
	local ent = t.ent
	if IsValid(ent) and ent:IsPlayer() and P.RagOf(ent) then ent = P.RagOf(ent) end
	if not IsValid(ent) then
		Log("motion [" .. tostring(t.tag) .. "]: no body on the client")
		net.Start("nt_test4") net.WriteString(tostring(t.tag)) net.WriteTable({ missing = true }) net.SendToServer()
		return
	end
	local m = { ent = ent, tag = tostring(t.tag), t0 = CurTime(), untilT = CurTime() + (t.seconds or 2), n = 0, lo = {}, hi = {}, sum = {}, series = {}, acc = {} }
	for _, name in ipairs(TRACKED) do m.series[name] = {} end
	motions[#motions + 1] = m
end

local function AngleAt(a, b, c)
	local u, v = a - b, c - b
	if u:LengthSqr() < 0.01 or v:LengthSqr() < 0.01 then return 180 end
	u:Normalize() v:Normalize()
	return math.deg(math.acos(math.Clamp(u:Dot(v), -1, 1)))
end

local function Sample(m)
	local ent = m.ent
	ent:SetupBones()
	local pos = {}
	for _, name in ipairs(MNAMES) do
		local b = ent:LookupBone(B .. name)
		local mat = b and ent:GetBoneMatrix(b)
		if not mat then return end
		pos[name] = mat:GetTranslation()
	end
	local o = pos.Pelvis
	local up = pos.Spine2 - o
	if up:LengthSqr() < 1 then return end
	up:Normalize()
	local trunk = up
	-- (a body on its feet is measured against the world's upright, or a lean of the trunk would
	-- turn the frame with it and hide itself)
	if up.z > 0.7 then up = Vector(0, 0, 1) end
	local left = pos.L_UpperArm - pos.R_UpperArm
	left = left - up * left:Dot(up)
	if left:LengthSqr() < 0.01 then return end
	left:Normalize()
	local front = left:Cross(up)
	m.n = m.n + 1
	for _, name in ipairs(TRACKED) do
		local r = pos[name] - o
		local v = Vector(r:Dot(front), r:Dot(left), r:Dot(up))
		local lo, hi = m.lo[name], m.hi[name]
		if not lo then
			m.lo[name], m.hi[name], m.sum[name] = Vector(v), Vector(v), Vector(v)
		else
			lo.x, lo.y, lo.z = math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z)
			hi.x, hi.y, hi.z = math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z)
			m.sum[name]:Add(v)
		end
		local s = m.series[name]
		s[#s + 1] = v
	end
	-- the trunk in the world: how high the chest and the pelvis are, and how far the trunk is from upright
	local a = m.acc
	local function Acc(key, val)
		a[key] = (a[key] or 0) + val
		a[key .. "Lo"] = math.min(a[key .. "Lo"] or val, val)
		a[key .. "Hi"] = math.max(a[key .. "Hi"] or val, val)
	end
	local floor = math.huge
	for _, p in pairs(pos) do floor = math.min(floor, p.z) end
	Acc("chest", pos.Spine2.z - floor)
	Acc("pelvis", o.z - floor)
	Acc("lean", math.deg(math.acos(math.Clamp(trunk.z, -1, 1))))
	local head = pos.Head1 - pos.Spine2
	head:Normalize()
	Acc("headDroop", math.deg(math.acos(math.Clamp(head:Dot(trunk), -1, 1))))
	Acc("headTurn", math.deg(math.asin(math.Clamp(head:Dot(left), -1, 1))))
	-- where the face points, against the trunk: up or down (a hanging head is negative), and round
	-- to the left (positive) or the right
	local eyes = ent:LookupAttachment("eyes")
	local att = eyes and eyes > 0 and ent:GetAttachment(eyes)
	if att then
		local face = att.Ang:Forward()
		Acc("faceNod", math.deg(math.asin(math.Clamp(face:Dot(up), -1, 1))))
		Acc("faceTurn", math.deg(math.atan2(face:Dot(left), face:Dot(front))))
	end
	Acc("elbowR", AngleAt(pos.R_UpperArm, pos.R_Forearm, pos.R_Hand))
	Acc("elbowL", AngleAt(pos.L_UpperArm, pos.L_Forearm, pos.L_Hand))
	Acc("kneeR", AngleAt(pos.R_Thigh, pos.R_Calf, pos.R_Foot))
	Acc("kneeL", AngleAt(pos.L_Thigh, pos.L_Calf, pos.L_Foot))
	Acc("handChestR", pos.R_Hand:Distance(pos.Spine2))
	Acc("handChestL", pos.L_Hand:Distance(pos.Spine2))
	Acc("handHipR", pos.R_Hand:Distance(pos.R_Thigh))
	Acc("handHipL", pos.L_Hand:Distance(pos.L_Thigh))
	Acc("feetApart", pos.R_Foot:Distance(pos.L_Foot))
	Acc("sideways", (pos.Spine2 - o):Dot(Vector(-left.x, -left.y, 0)))
end

-- how often a point goes back and forth along the axis on which it moves most
local function Beat(series, lo, hi, seconds)
	local ext = hi - lo
	local axis = (ext.x >= ext.y and ext.x >= ext.z) and "x" or (ext.y >= ext.z and "y" or "z")
	local range = ext[axis]
	if range < 1 or #series < 6 then return 0 end
	local gate = range * 0.2
	local dir, turn, last = 0, 0, series[1][axis]
	for i = 2, #series do
		local v = series[i][axis]
		if dir >= 0 and v < last - gate then
			if dir > 0 then turn = turn + 1 end
			dir, last = -1, v
		elseif dir <= 0 and v > last + gate then
			if dir < 0 then turn = turn + 1 end
			dir, last = 1, v
		elseif (dir > 0 and v > last) or (dir < 0 and v < last) then
			last = v
		end
	end
	return turn / 2 / seconds
end

hook.Add("Think", "NT_TestMotion", function()
	if #motions == 0 then return end
	local now = CurTime()
	for i = #motions, 1, -1 do
		local m = motions[i]
		if not IsValid(m.ent) then
			table.remove(motions, i)
			net.Start("nt_test4") net.WriteString(m.tag) net.WriteTable({ missing = true }) net.SendToServer()
		else
			if not m.ent:IsDormant() then Sample(m) end
			if now >= m.untilT then
				table.remove(motions, i)
				local seconds = now - m.t0
				local out = { frames = m.n, seconds = seconds }
				if m.n < 3 then
					out.missing = true
				else
					for _, name in ipairs(TRACKED) do
						local ext = m.hi[name] - m.lo[name]
						out["range" .. name] = ext:Length()
						out["hz" .. name] = Beat(m.series[name], m.lo[name], m.hi[name], seconds)
						local mean = m.sum[name] / m.n
						out["mean" .. name] = { mean.x, mean.y, mean.z }
					end
					for k, v in pairs(m.acc) do
						if string.sub(k, -2) == "Lo" or string.sub(k, -2) == "Hi" then out[k] = v else out[k] = v / m.n end
					end
				end
				local function R(name) return string.format("%.0f (%.1f Hz)", out["range" .. name] or -1, out["hz" .. name] or 0) end
				Log(string.format("motion [%s] %.1f s, %d frames | moved: hands R %s L %s, feet R %s L %s, knees R %s L %s, head %s | chest above the lowest point %.0f (%.0f to %.0f) | elbows R %.0f L %.0f knees R %.0f L %.0f | trunk from upright %.0f, head from the trunk %.0f, tilted %.0f, face %.0f up and %.0f to the left | hands from the chest R %.0f L %.0f, from the hips R %.0f L %.0f | feet apart %.0f",
					m.tag, seconds, m.n, R("R_Hand"), R("L_Hand"), R("R_Foot"), R("L_Foot"), R("R_Calf"), R("L_Calf"), R("Head1"),
					out.chest or -1, out.chestLo or -1, out.chestHi or -1, out.elbowR or -1, out.elbowL or -1, out.kneeR or -1, out.kneeL or -1,
					out.lean or -1, out.headDroop or -1, out.headTurn or 0, out.faceNod or 0, out.faceTurn or 0, out.handChestR or -1, out.handChestL or -1, out.handHipR or -1, out.handHipL or -1, out.feetApart or -1))
				net.Start("nt_test4") net.WriteString(m.tag) net.WriteTable(out) net.SendToServer()
			end
		end
	end
end)

-- the brain as a body (cl_brain3d.lua): open the window as asked, and say what was built
function H.brain3d(t)
	local res = NT.Brain3D and NT.Brain3D.Test(t) or { missing = true }
	net.Start("nt_test4")
	net.WriteString(tostring(t.tag or "brain3d"))
	net.WriteTable(res or {})
	net.SendToServer()
end

-- what the engine does with a lit mesh made in Lua (cl_litprobe.lua)
function H.litprobe(t)
	if NT.LitProbe and NT.LitProbe.Run then NT.LitProbe.Run(t) end
end

net.Receive("nt_test3", function()
	local cmd = net.ReadString()
	local t = net.ReadTable()
	local f = H[cmd]
	if not f then Log("unknown test command " .. cmd) return end
	local ok, err = pcall(f, t)
	if not ok then Log("CLIENT ERROR in " .. cmd .. ": " .. tostring(err)) end
end)
