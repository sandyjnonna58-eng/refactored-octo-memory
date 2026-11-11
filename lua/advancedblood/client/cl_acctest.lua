-- Client half of the accumulation scenes (phase 18, server/sv_acctest.lua; developer tool, inert
-- unless the test harness is running): what gathers where in the harness log (cl_accum.lua), checks
-- that log PASS or FAILED, a camera that stays fixed on where blood gathers, and footage recorded by
-- the game's own video writer.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local A = ABL.Accum
local min, max = math.min, math.max

local function SourceOf(idx)
	local ent = Entity(idx or 0)
	if not IsValid(ent) then return nil end
	local S = ABL.Sources
	local src = S.byKey[ent] or S.byBody[ent]
	if src then return src end
	for _, s in ipairs(S.list) do
		if s.owner == ent or s.key == ent or s.body == ent then return s end
	end
	return nil
end

-- What gathers where is measured (every film counts what crosses between its regions) from now on.
function H.acctrack(t)
	A.Track(t.on ~= false)
	A.err, A.errFlow = 0, 0
	Log("acctrack " .. (t.on ~= false and "on" or "off"))
end

-- The developer's view on (t.mode 1 or 2) or off (0).
function H.accview(t)
	RunConsoleCommand("abl_dev_acc", tostring(t.mode or 0))
	Log("accview " .. tostring(t.mode or 0))
end

local snaps = {}

-- One character's state as the checks compare it: its film's books and regions, and its pools.
local function Snap(now)
	local out = { t = now, films = {}, pools = {} }
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s then
			local regs = A.Regions(s)
			local top = regs[1]
			local area, held = 0, 0
			for _, r in ipairs(regs) do area, held = area + r.area, held + r.q end
			out.films[src.key] = { fed = s.bk.fed, held = held, area = area, top = top and top.q or 0, topArea = top and top.area or 0, topId = top and top.id or 0, n = #regs }
		end
	end
	for _, p in ipairs(ABL.Pools.list) do
		local info = A.Pool(p, now)
		if info then
			local key = p.owner or false
			local e = out.pools[key]
			if not e then e = { q = 0, area = 0, under = 0, underQ = 0, stained = 0, bodyCells = 0, inTot = 0, n = 0, wetVol = 0 } out.pools[key] = e end
			e.q, e.area, e.under, e.bodyCells, e.inTot, e.n, e.wetVol = e.q + info.q, e.area + info.area, e.under + info.under, e.bodyCells + info.bodyCells, e.inTot + info.inTot, e.n + 1, e.wetVol + info.vol
			e.stained, e.underQ = e.stained + info.stained, e.underQ + info.underQ
		end
	end
	return out
end

-- What gathers where now, for every character with blood: in the log, and kept under t.name for the
-- checks (H.acccheck).
function H.accstats(t)
	local now = CurTime()
	local name = tostring(t.name)
	local L = ABL.LOD
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		Log(string.format("acc %s | body %s (%s): %.0f units away, tier %s, blood routed by tier %s (%s), film %s, drawn in full %s | governor's scale %.2f",
			name, tostring(src.body), tostring(IsValid(src.body) and src.body:GetModel() or "?"), src.dist or -1, tostring(src.lod), tostring(src.flowLod),
			L.FlowOn(src) and "onto its film" or "not onto its film", s and "yes" or "no", s and tostring(s.fullLook) or "-", L.scale))
		for _, wd in ipairs(src.woundList) do
			Log(string.format("     wound %s flow %.3f ml/s | dripped straight off %.3f", tostring(wd.id), wd.flow or 0, wd.dripAcc or 0))
		end
		if s then
			local b = s.bk
			Log(string.format("     film books: fed %.3f = wet on it %.3f + in the cloth %.3f + dried %.3f + left %.3f (unbooked %.4f) | cells %d, running %d",
				b.fed, b.surface, b.absorbed, b.dried, b.left, b.fed - b.surface - b.absorbed - b.dried - b.left, s.n, s.na))
			local regs = A.Regions(s)
			local area, held = 0, 0
			for _, r in ipairs(regs) do area, held = area + r.area, held + r.q end
			Log(string.format("     film regions: %d, holding %.3f ml over %.1f units^2", #regs, held, area))
			for i = 1, min(#regs, 4) do
				local r = regs[i]
				Log(string.format("       R%d %s %s: %.3f ml, %+.3f ml/s | %d cells, %.1f units^2, %.2f mm deep on average, %.2f at most | in %.3f ml/s (%.3f from the wound or drops), out %.3f ml/s (%.3f off the body), soaked %.3f, dried %.3f | %d cells run",
					r.id, r.pooled and "holds" or "thin", r.state, r.q, r.rate or 0, r.n, r.area, r.dmean * 19.05, r.dmax * 19.05, r.inRate or 0, r.fromWound or 0, r.outRate or 0, r.leftRate or 0,
					r.soakRate or 0, r.dryRate or 0, r.running))
			end
		end
	end
	for i, p in ipairs(ABL.Pools.list) do
		local info = A.Pool(p, now)
		if info and i <= 8 then
			Log(string.format("     pool %d of %s: %s %.2f ml wet, %+.3f ml/s (arriving %.3f ml/s) | covers %.1f units^2 (%d cells of %.2f) | under a body: %d cells closed, %d of them with wet blood (%.2f ml), %d with dried or soaked-in blood, %d pushed out to its edge so far | in %.2f, out %.2f, dried %.2f, soaked %.2f, volume %.2f",
				p.id, tostring(p.owner), info.state, info.q, info.rate, info.inRate, info.area, info.cells, info.cell, info.bodyCells, info.under, info.underQ, info.stained, info.pushed, info.inTot, info.outTot, info.dried, info.soaked, info.vol))
		end
	end
	local ev = A.counts or {}
	Log(string.format("     left the bodies since tracking began: as drops %.3f ml, seeped onto the floor %.3f ml, landed on a body %.3f ml | the region books' largest error since the last report %.6f ml (%.3f ml moving)",
		ev.drop or 0, ev.seep or 0, ev.landed or 0, A.err, A.errFlow))
	-- (blood written off since tracking began, by the line of code that wrote it off)
	local lostAt = ABL.FlowCore.lostAt
	if lostAt and next(lostAt) then
		local parts = {}
		for k, e in pairs(lostAt) do parts[#parts + 1] = string.format("%s %.3f ml in %d", k, e.ml, e.n) end
		table.sort(parts)
		Log("     written off since tracking began: " .. table.concat(parts, "; "))
	end
	if A.Tracking() then
		if A.err > 0.001 then Log(string.format("FAILED acc books %s: a region's books are off by %.6f ml", name, A.err))
		else Log(string.format("PASS acc books %s: every region's books close (largest error %.6f ml)", name, A.err)) end
	end
	A.err, A.errFlow = 0, 0
	snaps[name] = Snap(now)
end

local function Check(ok, what, detail)
	Log(string.format("%s acc %s: %s", ok and "PASS" or "FAILED", what, detail))
end

-- A check of what changed between two reports (H.accstats names: t.from and t.to) of one character's
-- blood (t.ent: its entity): t.kind
--   "grow"    its pools together hold more and cover more, by t.k of their cover at least (t.minArea
--             units^2 more at the least)
--   "still"   its pools gained no more than t.most ml (the source has stopped and its liquid is at rest)
--   "beside"  no blood stands in a pool's cells under its body (t.to only)
--   "film"    its film still holds blood in regions, as much as t.k of what it held at t.from
function H.acccheck(t)
	local a, b = snaps[t.from or ""], snaps[t.to or ""]
	local src = SourceOf(t.ent)
	local key = src and src.key
	local name = string.format("%s %s..%s", tostring(t.kind), tostring(t.from), tostring(t.to))
	if not b or not key then Check(false, name, "no report " .. tostring(t.to) .. " or no character " .. tostring(t.ent)) return end
	local pb = b.pools[key] or { q = 0, area = 0, under = 0, bodyCells = 0, inTot = 0, n = 0 }
	if t.kind == "beside" then
		-- (most of the pools' wet blood lies beside the body, where it is seen; what stands under it
		-- seeped there from where it stood deeper than the body's step: PS.SetBody)
		local share = pb.q > 0 and (pb.underQ or 0) / pb.q or 0
		Check(share <= (t.most or 0.5), name, string.format("%d pool(s), %d cells under a body: %d of them with wet blood (%.2f ml of %.2f, %.0f%%; allowed %.0f%%), %d with dried or soaked-in blood, which stays",
			pb.n, pb.bodyCells, pb.under, pb.underQ or 0, pb.q, share * 100, (t.most or 0.5) * 100, pb.stained or 0))
		return
	end
	if not a then Check(false, name, "no report " .. tostring(t.from)) return end
	local pa = a.pools[key] or { q = 0, area = 0, under = 0, bodyCells = 0, inTot = 0, n = 0 }
	if t.kind == "grow" then
		local need = max(pa.area * (t.k or 0.2), t.minArea or 2)
		Check(pb.area >= pa.area + need and pb.inTot > pa.inTot, name, string.format("pools cover %.1f -> %.1f units^2 (wanted %.1f more), hold %.2f -> %.2f ml, received %.2f -> %.2f ml over %.1f s",
			pa.area, pb.area, need, pa.q, pb.q, pa.inTot, pb.inTot, b.t - a.t))
	elseif t.kind == "still" then
		local most = t.most or 0.3
		Check(pb.inTot - pa.inTot <= most, name, string.format("pools received %.3f ml (allowed %.3f) and hold %.2f -> %.2f ml over %.1f s", pb.inTot - pa.inTot, most, pa.q, pb.q, b.t - a.t))
	elseif t.kind == "film" then
		local fa, fb = a.films[key], b.films[key]
		if not fa or not fb then Check(false, name, "no film in one of the reports") return end
		Check(fb.held >= fa.held * (t.k or 0.5) and fb.n > 0, name, string.format("the film holds %.3f -> %.3f ml in %d -> %d region(s), %.1f -> %.1f units^2", fa.held, fb.held, fa.n, fb.n, fa.area, fb.area))
	end
end

-- The pools' colours for the pictures that follow (t.palette: entries of C.Pool.palette, as
-- { rim = {r, g, b}, body = {r, g, b} } or {r, g, b}); every pool is painted anew.
local poolPalette0
function H.poollook(t)
	local pal = ABL.Config.Pool.palette
	if not poolPalette0 then poolPalette0 = table.Copy(pal) end
	if t.reset then
		for k, v in pairs(poolPalette0) do pal[k] = table.Copy(v) end
	end
	for k, v in pairs(t.palette or {}) do pal[k] = v end
	for _, p in ipairs(ABL.Pools.list) do p.dirty, p.meshDirty = true, true end
	Log("poollook " .. tostring(t.name))
end

------------------------------------------------------------------------------------------
-- A camera that stays where it is put: on where the blood of a character gathers
------------------------------------------------------------------------------------------
local views = {}

-- The camera on where t.ent's blood gathers, from outside the body: its largest pool if it has one,
-- else the lowest place its film has reached; t.dist units away, t.elev degrees above the floor,
-- t.turn degrees round from straight out of the body. Kept as t.name (t.use = name: that view again).
function H.acccam(t)
	if t.use then
		local v = views[t.use]
		if not v then Log("acccam: no view " .. tostring(t.use)) return end
		H.view({ pos = v.pos, ang = v.ang, fov = v.fov })
		Log("acccam " .. tostring(t.use) .. " again")
		return
	end
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then Log("acccam: no source for " .. tostring(t.ent)) return end
	local body = src.body
	local centre = body:WorldSpaceCenter()
	local target, what
	-- (its largest pool)
	local best
	for _, p in ipairs(ABL.Pools.list) do
		if p.owner == src.key and (not best or p.vol > best.vol) then best = p end
	end
	if best and best.sim and t.pool ~= false then
		local g = best.sim
		local a = g.a
		local x, y, z = ABL.Pools.ToWorld(best, (g.i0 + (g.bx0 + g.bx1 + 1) * 0.5) * a, (g.j0 + (g.by0 + g.by1 + 1) * 0.5) * a, 0)
		target, what = Vector(x, y, z), string.format("its pool of %.1f ml", best.vol)
	end
	if not target then
		local s = src.film
		local low
		if s and s.m == src.mesh then
			src.pose:Begin(FrameNumber())
			for c = 1, s.n do
				if s.h[c] + s.k[c] > 0.004 then
					local x, y, z = src.pose:Point(s.tt[c], s.bu[c], s.bv[c])
					if not low or z < low.z then low = Vector(x, y, z) end
				end
			end
		end
		target, what = low or centre, low and "the lowest place its film has reached" or "its middle"
	end
	-- (from outside the body: from its middle through the target, and on)
	local out = target - centre
	out.z = 0
	if out:LengthSqr() < 1 then out = Vector(1, 0, 0) end
	out:Normalize()
	local a = out:Angle()
	a.y = a.y + (t.turn or 0)
	local el = math.rad(t.elev or 35)
	local dir = a:Forward()
	local d = t.dist or 60
	local look = target + Vector(0, 0, t.lift or 0)
	local pos = look + dir * math.cos(el) * d + Vector(0, 0, math.sin(el) * d)
	local ang = (look - pos):Angle()
	H.view({ pos = pos, ang = ang, fov = t.fov })
	if t.name then views[t.name] = { pos = pos, ang = ang, fov = t.fov } end
	Log(string.format("acccam %s: on %s at %s, from %.0f units, %.0f degrees up", tostring(t.name), what, tostring(look), d, t.elev or 35))
end

------------------------------------------------------------------------------------------
-- Footage: the game's own video writer (video.Record), from the view as it is
------------------------------------------------------------------------------------------
-- t.name: the file; t.secs: how long, in real time, every frame (t.lapse: one frame every t.lapse
-- seconds of game time instead, for t.secs seconds: a time lapse); t.w, t.h, t.fps.
local rec
function H.record(t)
	if rec then Log("record: one is already being made") return end
	if not video or not video.Record then Log("record: no video.Record in this build") return end
	local w, h = t.w or 960, t.h or 540
	local fps = t.fps or 30
	local writer, err = video.Record({ container = "webm", video = "vp8", audio = "vorbis", quality = t.quality or 60, bitrate = t.bitrate or 2000,
		fps = fps, lockfps = true, name = t.name or "abl_footage", width = w, height = h })
	if not writer then Log("record FAILED to start: " .. tostring(err)) return end
	pcall(function() writer:SetRecordSound(false) end)
	rec = { w = writer, t0 = CurTime(), r0 = RealTime(), secs = t.secs or 10, lapse = t.lapse, next = CurTime(), n = 0, fps = fps, name = t.name }
	Log(string.format("record %s: %dx%d at %d frames a second%s, for %.0f s", tostring(t.name), w, h, fps, t.lapse and string.format(", one frame every %.1f s of game time", t.lapse) or "", rec.secs))
end

hook.Add("PostRender", "ABL_AccRecord", function()
	local r = rec
	if not r then return end
	local now = CurTime()
	local done = (r.lapse and now - r.t0 > r.secs) or (not r.lapse and RealTime() - r.r0 > r.secs)
	if not done then
		if r.lapse then
			if now >= r.next then
				r.next = r.next + r.lapse
				r.w:AddFrame(1 / r.fps, true)
				r.n = r.n + 1
			end
		else
			r.w:AddFrame(FrameTime(), true)
			r.n = r.n + 1
		end
		return
	end
	rec = nil
	local ok, err = pcall(function() r.w:Finish() end)
	Log(string.format("record %s: %d frames over %.1f s of game time, %.1f s real time%s", tostring(r.name), r.n, now - r.t0, RealTime() - r.r0, ok and "" or (" | FAILED to finish: " .. tostring(err))))
end)
