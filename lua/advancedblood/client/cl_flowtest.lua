-- Client half of the flow benchmarks (developer tool). Inert unless the test harness is running
-- (garrysmod/data/abl_selftest.txt, see cl_selftest.lua): cameras on a wound or on the front of its
-- stream, developer views, and the measurements of the flow itself written to the harness log.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local FC = ABL.FlowCore
local sqrt = math.sqrt

local function SourceOf(idx)
	local ent = Entity(idx or 0)
	if not IsValid(ent) then return nil end
	local S = ABL.Sources
	local src = S.byKey[ent] or S.byBody[ent]
	if src then return src end
	-- (a player lying as a ragdoll, or dead: the source is keyed by whatever carries the wounds)
	for _, s in ipairs(S.list) do
		if s.owner == ent or s.key == ent or s.body == ent then return s end
	end
	return nil
end

-- Is the point seen from the eye? (a limb, the floor or the body itself may be in the way)
local function Sees(eye, look)
	local tr = util.TraceLine({ start = eye, endpos = look, mask = MASK_SHOT })
	if tr.StartSolid then return false end
	return not tr.Hit or tr.HitPos:DistToSqr(look) < 16
end

-- Camera on a wound of entity t.ent: t.dist units out along the (flattened) skin normal, looking at a
-- point t.drop units below the wound. t.follow: look at the lowest point blood has reached instead.
function H.flowcam(t)
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then Log("flowcam: no source for entity " .. tostring(t.ent)) return end
	src.pose:Begin(FrameNumber())
	-- (a wound that has closed is still looked at where it was)
	local wd = src.woundList[t.wound or 1]
	local ok, x, y, z, nx, ny, nz
	if wd then
		ok, x, y, z, nx, ny, nz = ABL.Emission.WoundFrame(src, wd)
		if ok and wd.tri then src.testCam = { wd.tri, wd.u, wd.v, src.mesh } end
	end
	local ref = src.testCam
	if not ok and ref and ref[4] == src.mesh then
		x, y, z, nx, ny, nz = src.pose:Point(ref[1], ref[2], ref[3])
		ok = true
	end
	if not ok then Log("flowcam: no wound") return end
	local p = Vector(x, y, z)
	-- (a wound that faces up is looked at from the side and above, never from under the floor)
	local out = Vector(nx, ny, 0)
	local lift = 0
	if out:LengthSqr() < 0.15 then
		out = Vector(1, 0.3, 0)
		lift = 0.8
	end
	out:Normalize()
	out = (out + Vector(0, 0, lift)):GetNormalized()
	local side = out:Cross(Vector(0, 0, 1))
	side:Normalize()
	local look = p - Vector(0, 0, t.drop or 4)
	local target = p
	if t.follow and src.fc then
		local low
		local m = src.mesh
		for _, ch in ipairs(src.fc.chans) do
			if not ch.dead and ch.n > 0 and ch.an[1][4] == m then
				local hd = ch.head
				local q
				if hd and hd.placed then q = Vector(hd.wx, hd.wy, hd.wz) else q = Vector(src.pose:SkinPoint(ch.an[ch.n])) end
				if not low or q.z < low.z then low = q end
			end
		end
		if low then look, target = low + Vector(0, 0, t.drop or 0), low end
	end
	local dist = t.dist or 17
	local eye = look + out * dist + side * (t.side or 0.25) * dist + Vector(0, 0, t.up or 2)
	local moved = ""
	if not Sees(eye, target) then
		-- (a lying body: its own limbs are between the wound and where it faces. From above, from
		-- the nearest free direction.)
		local base = Vector(out.x, out.y, 0):Angle().y
		local found
		for _, el in ipairs({ 40, 65 }) do
			for _, az in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
				local e = look + Angle(-el, base + az, 0):Forward() * dist
				if Sees(e, target) then
					eye, found = e, true
					moved = string.format(" (view blocked: from %d degrees up, turned %d)", el, az)
					break
				end
			end
			if found then break end
		end
		if not found then
			eye = look + Vector(0.1, 0, 1) * dist
			moved = " (view blocked on every side: from straight above)"
		end
	end
	H.view({ pos = eye, ang = (look - eye):Angle() })
	Log(string.format("flowcam %s wound at %s normal %.2f %.2f %.2f, eye %s%s%s", tostring(src.body), tostring(p), nx, ny, nz, tostring(eye), t.follow and " (following the front)" or "", moved))
end

function H.flowview(t) RunConsoleCommand("abl_flow_view", tostring(t.view or 0)) end

-- abl_flow_core for the scenes that follow (the older model as a whole, and back).
function H.flowcore(t)
	RunConsoleCommand("abl_flow_core", t.on and "1" or "0")
	Log("abl_flow_core " .. (t.on and "1" or "0"))
end

-- Old bead model (legacy = true) or the flow core for one character.
function H.flowmode(t)
	local ent = Entity(t.ent or 0)
	if IsValid(ent) then ent.ablFlowLegacy = t.legacy and true or nil end
end

-- The flow in numbers: books, audit, and per channel the measures of a stream.
local lastT, lastSteps
function H.flowstats(t)
	local bk = FC.Books
	local err, dAir, dSurf, dPool, air, surf, pool = FC.Audit()
	Log(string.format("flow %s | books: released %.3f = airborne %.3f + surface %.3f + pool %.3f + absorbed %.3f + clotted %.3f + dried %.3f + lost %.3f | unbooked %.4f ml",
		t.name, bk.released, bk.airborne, bk.surface, bk.pool, bk.absorbed, bk.clotted, bk.dried, bk.lost, err))
	Log(string.format("   audit: found airborne %.3f (books off by %.4f)  surface %.3f (off by %.4f)  pool %.3f (off by %.4f)", air, dAir, surf, dSurf, pool, dPool))
	local chans, active, cells, heads, joined = FC.Counts()
	local p = FC.prof
	local now = RealTime()
	local dtw = lastT and (now - lastT) or 0
	Log(string.format("   channels %d (active %d, joined %d) nodes %d wet cells %d heads %d | since last: head steps %d %.2f ms, channel steps %d %.2f ms (%d node steps, %.2f us each), joins %d, spills %d, branches %d%s",
		chans, active, joined, FC.nodes, cells, heads, p.heads, p.head, p.chans, p.chan, p.nodeSteps, p.nodeSteps > 0 and p.chan / p.nodeSteps * 1000 or 0, p.joins, p.breaks, p.branches or 0,
		dtw > 0 and string.format(" | %.0f channel steps/s over %.1f s", p.chans / dtw / math.max(active, 1), dtw) or ""))
	lastT = now
	for k in pairs(p) do p[k] = 0 end
	-- channels on the world (walls, slopes, ceilings), per region
	for _, reg in ipairs(ABL.FlowWorld.regions) do
		local st = reg.fc
		local b = st.bk
		Log(string.format("   world region at %.0f %.0f %.0f (%.0f u away): %d channels, %d nodes | took %.3f = on it %.3f + absorbed %.3f + clotted %.3f + dried %.3f + left %.3f (unbooked %.4f)",
			reg.cx, reg.cy, reg.cz, reg.dist, #st.chans, st.nodes, b.fed, b.surface, b.absorbed, b.clotted, b.dried, b.left, b.fed - b.surface - b.absorbed - b.clotted - b.dried - b.left))
		for _, ch in ipairs(st.chans) do
			if not ch.dead then
				local q = FC.Measure(ch)
				local hd = ch.head
				Log(string.format("     wch %d: %d nodes %.1f u, wet %d (gaps %d) | width %.3f sd %.3f  height %.4f sd %.4f u | mobile %.4f ml head %.4f ml tip %.4f ml/s%s%s%s",
					ch.id, q.nodes, q.length, q.wet, q.gaps, q.width, q.widthSd, q.height, q.heightSd, q.mobile, q.head, q.tip,
					hd and (" | head " .. tostring(hd.state)) or (ch.joinCh and string.format(" | joins wch %d at node %d", ch.joinCh.id, ch.joinIdx) or (ch.sink and " | ends in a pool" or " | ended")),
					ch.parentCh and string.format(" | finger of wch %d", ch.parentCh.id) or "", ch.done and " | done" or ""))
			end
		end
	end
	for _, src in ipairs(ABL.Sources.list) do
		for _, wd in ipairs(src.woundList) do
			Log(string.format("   wound %s value %.3f flow %.4f ml/s profile %s clot %.2f", tostring(wd.id), wd.sev or 0, wd.flow or 0, wd.profile and wd.profile.name or "-", wd.clotK or 1))
		end
		local s = src.fc
		if s then
			local b = s.bk
			local held = FC.Held(s)
			Log(string.format("   body %s: fed %.3f = on it %.3f + absorbed %.3f + clotted %.3f + dried %.3f + left %.3f (unbooked %.4f) | held by channels %.3f (books off by %.4f) | nodes %d",
				tostring(src.body), b.fed, b.surface, b.absorbed, b.clotted, b.dried, b.left, b.fed - b.surface - b.absorbed - b.clotted - b.dried - b.left, held, b.surface - held, s.nodes))
			for _, ch in ipairs(s.chans) do
				if not ch.dead then
					local q = FC.Measure(ch)
					local hd = ch.head
					Log(string.format("     ch %d%s%s: %d nodes %.1f u, wet %d (gaps %d) | width %.3f sd %.3f  height %.4f sd %.4f u | mobile %.4f ml head %.4f ml tip %.4f ml/s | largest step %.3f u, turned %.2f rad over %.1f u, largest change per step: width %.4f height %.4f%s%s",
						ch.id, ch.wd and (" wound " .. tostring(ch.wd.id)) or "", ch.parentCh and string.format(" (branch of ch %d at node %d, share %.2f)", ch.parentCh.id, ch.parentIdx, ch.share) or "", q.nodes, q.length, q.wet, q.gaps, q.width, q.widthSd, q.height, q.heightSd, q.mobile, q.head, q.tip,
						ch.maxStep or 0, ch.turn or 0, ch.moved or 0, ch.wJump or 0, ch.hJump or 0,
						hd and string.format(" | head %s%s%s hang %.2f age %.0f s", hd.moving and "running" or "resting", hd.atEdge and " at an edge" or "", hd.stuckT > 1 and string.format(" (stuck %.0f s)", hd.stuckT) or "", hd.hangK, hd.bage) or (ch.joinCh and string.format(" | joins ch %d at node %d", ch.joinCh.id, ch.joinIdx) or " | ended"),
						ch.done and " | done" or ""))
					ch.maxStep, ch.wJump, ch.hJump = 0, 0, 0
				end
			end
		end
	end
end
