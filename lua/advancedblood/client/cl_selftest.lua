-- Client half of the automated test harness (developer tool).
-- Inert unless garrysmod/data/abl_selftest.txt exists on THIS machine, so a server can never
-- drive it on normal clients. Captures screenshots / stats into garrysmod/data/abl_test/.

ABL.NoJIT()
if not ABL.testRun then return end

file.CreateDir("abl_test")
local STATS = "abl_test/client_stats.txt"
local H = {}
local shotQueue = {}
local viewPos, viewAng, viewNear
local saved = {}
local drawPoints, drawDecalArrows

local function Log(s) file.Append(STATS, string.format("%8.2f %s\n", CurTime(), s)) end
-- (other test files of this addon add their own handlers: cl_flowtest.lua)
ABL.TestClient = { H = H, Log = Log }

net.Receive("abl_st", function()
	local cmd = net.ReadString()
	local t = net.ReadTable()
	if H[cmd] then
		local ok, err = pcall(H[cmd], t)
		if not ok then Log("CLIENT ERROR in " .. cmd .. ": " .. tostring(err)) end
	end
end)

-- Z-City renders its own view (RenderScene + CalcView); suspend those while the harness drives the camera.
-- What the JIT compiler of this Lua state is doing (all addons): traces started / completed /
-- aborted (by reason code) / flushes, counted while the harness runs.
local jitStat = { start = 0, stop = 0, abort = 0, flush = 0, codes = {} }
local function JitEvent(what, tr, func, pc, code)
	jitStat[what] = (jitStat[what] or 0) + 1
	if what == "abort" then jitStat.codes[code or -1] = (jitStat.codes[code or -1] or 0) + 1 end
end
local function JitReport()
	local parts = {}
	for code, n in pairs(jitStat.codes) do parts[#parts + 1] = string.format("#%s x%d", tostring(code), n) end
	table.sort(parts)
	local on, flags = "?", ""
	if jit and jit.status then
		local st = { jit.status() }
		on = tostring(st[1])
		flags = table.concat(st, " ", 2)
	end
	Log(string.format("   | jit %s (%s) %s: traces started %d completed %d aborted %d flushes %d | abort reasons %s",
		jit and jit.version or "?", jit and jit.arch or "?", on, jitStat.start, jitStat.stop, jitStat.abort, jitStat.flush, table.concat(parts, " ")))
	Log("   | jit flags " .. flags)
	jitStat.start, jitStat.stop, jitStat.abort, jitStat.flush, jitStat.codes = 0, 0, 0, 0, {}
end

-- The look the run began with (C.Film with its palette, and C.V19), put back between scenes: a scene
-- that changes the look and then fails (or forgets) left it changed for every scene after it. Kept
-- table by table and put back into the same tables, since other modules hold on to them (the
-- painter's own K.palette, for one). (What was not there at the start is left as it is: a module
-- may keep something of its own there.)
local lookKept
local function Keep(t, depth)
	local s = { ref = t, vals = {}, sub = {} }
	for k, v in pairs(t) do
		if type(v) == "table" and depth < 4 then s.sub[k] = Keep(v, depth + 1) else s.vals[k] = v end
	end
	return s
end
local function PutBack(s)
	local t = s.ref
	for k, v in pairs(s.vals) do t[k] = v end
	for k, sub in pairs(s.sub) do
		PutBack(sub)
		t[k] = sub.ref
	end
end

function H.begin()
	ABL.Prof.force = true
	file.Write(STATS, "")
	for _, pair in ipairs({ { "RenderScene", "jopa" }, { "CalcView", "homigrad-view" } }) do
		local ht = hook.GetTable()[pair[1]]
		if ht and ht[pair[2]] then
			saved[#saved + 1] = { pair[1], pair[2], ht[pair[2]] }
			hook.Remove(pair[1], pair[2])
		end
	end
	RunConsoleCommand("cl_drawhud", "0")
	RunConsoleCommand("abl_debug_hud", "0")
	if jit and jit.attach then pcall(jit.attach, JitEvent, "trace") end
	Log("begin " .. ScrW() .. "x" .. ScrH())
	-- (what an outline in a picture also depends on: the engine's own anti-aliasing turns an alpha
	-- tested cut into coverage, and HDR changes how bright everything is. "?": not to be read.)
	local parts = {}
	for _, name in ipairs({ "mat_antialias", "mat_aaquality", "mat_hdr_level", "mat_picmip", "abl_liquid_v19" }) do
		local cv = GetConVar(name)
		parts[#parts + 1] = name .. " " .. (cv and cv:GetString() or "?")
	end
	local hdr = render.GetHDREnabled and render.GetHDREnabled()
	Log("   | " .. table.concat(parts, ", ") .. " | HDR in use " .. (hdr == nil and "?" or tostring(hdr)))
	local C = ABL.Config
	lookKept = { film = C.Film and Keep(C.Film, 1), v19 = C.V19 and Keep(C.V19, 1) }
	-- What the JIT does to two kinds of loop in this Lua state: pure arithmetic, and a loop that calls
	-- an engine function every iteration (what blood rendering consists of). Each is timed in a
	-- freshly compiled chunk (JIT allowed) and in a copy with the JIT switched off.
	if jit and jit.off and CompileString then
		local src = [[
			local RealTime = RealTime
			local function arith(n) local s = 0 for i = 1, n do s = s + (i % 7) * 0.5 end return s end
			local function calls(n) local s = 0 for i = 1, n do s = s + RealTime() end return s end
			return arith, calls
		]]
		local res = {}
		for pass = 1, 2 do
			local chunk = CompileString(src, "abl_jitprobe" .. pass)
			if pass == 2 then jit.off(chunk, true) end
			local arith, calls = chunk()
			local t0 = SysTime()
			for _ = 1, 5 do arith(400000) end
			local t1 = SysTime()
			for _ = 1, 5 do calls(100000) end
			local t2 = SysTime()
			res[pass] = { (t1 - t0) * 1000, (t2 - t1) * 1000 }
		end
		Log(string.format("jit probe: arithmetic loop %.1f ms with JIT, %.1f ms interpreted | engine-call loop %.1f ms with JIT, %.1f ms interpreted",
			res[1][1], res[2][1], res[1][2], res[2][2]))
	end
end

function H.finish()
	for _, s in ipairs(saved) do hook.Add(s[1], s[2], s[3]) end
	saved = {}
	viewPos = nil
	RunConsoleCommand("cl_drawhud", "1")
	if jit and jit.attach then pcall(jit.attach, JitEvent) end
	Log("finish")
end

-- Z-City's own camera back for a while (a first-person picture of the host as the game shows
-- it), or away again.
function H.zview(t)
	for _, s in ipairs(saved) do
		if t.on then hook.Add(s[1], s[2], s[3]) else hook.Remove(s[1], s[2]) end
	end
	if t.on then viewPos = nil end
end

local viewFov
local followMark
function H.view(t) followMark = nil viewPos, viewAng, viewNear, viewFov = t.pos, t.ang, t.znear, t.fov end
-- Close-up of the newest wound mark of a kind ("entry" / "exit"): the camera looks at it along the
-- skin normal from t.dist units, a little off-axis. Logs where it is.
-- The camera on an arc round t.center for t.secs of game time: from angle t.a0 to t.a1 (degrees),
-- t.dist away and t.z above it, looking at it.
local orbit
function H.orbit(t)
	orbit = { c = t.center, d = t.dist, z = t.z, a0 = math.rad(t.a0), a1 = math.rad(t.a1), t0 = CurTime(), secs = t.secs }
end
hook.Add("Think", "ABL_SelfTestOrbit", function()
	local o = orbit
	if not o then return end
	local k = (CurTime() - o.t0) / o.secs
	if k >= 1 then k, orbit = 1, nil end
	local a = o.a0 + (o.a1 - o.a0) * k
	local eye = o.c + Vector(math.cos(a) * o.d, math.sin(a) * o.d, o.z)
	viewPos, viewAng = eye, (o.c - eye):Angle()
end)

-- t.follow: the camera goes with the mark from then on, set again every frame from where the
-- mark is on the body as it stands in that frame (a body that runs: a mark that slid over the
-- skin, or stayed behind, leaves the middle of the picture), until another view is asked for.
function H.viewmark(t, quiet)
	if not quiet then followMark = t.follow and t or nil end
	local best, bsrc
	for _, src in ipairs(ABL.Sources.list) do
		for _, mk in ipairs(src.marks or {}) do
			local kindOK = mk.kind == t.kind or (t.kind == "entry" and mk.kind == "graze")
			if kindOK and mk.m == src.mesh and (not t.newerThan or CurTime() - mk.born < t.newerThan) and (not best or mk.born > best.born) then best, bsrc = mk, src end
		end
	end
	if not best then
		if not quiet then Log("viewmark " .. tostring(t.kind) .. ": none") end
		return
	end
	-- (a body that has just become another entity: its pose is on its surface model from the next
	-- update of the sources on; the camera stays where it was until then)
	if bsrc.pose.mesh ~= bsrc.mesh then return end
	bsrc.pose:Begin(FrameNumber())
	local x, y, z, nx, ny, nz = bsrc.pose:Point(best.tri, best.u, best.v)
	local p, n = Vector(x, y, z), Vector(nx, ny, nz)
	-- (a mark that faces the ground is looked at from the side, and never from inside the world)
	local vn = Vector(n.x, n.y, math.max(n.z, 0.2))
	vn:Normalize()
	local side = vn:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 0.01 then side = Vector(1, 0, 0) end
	side:Normalize()
	local eye = p + vn * (t.dist or 14) + side * (t.dist or 14) * 0.35 + Vector(0, 0, 2)
	if t.tilt then
		-- (from a set angle off the wound's own normal, round it by t.spin: for looking into a
		-- wound from straight on and from the side)
		local n2 = Vector(n.x, n.y, n.z)
		local s2 = n2:Cross(Vector(0, 0, 1))
		if s2:LengthSqr() < 0.01 then s2 = Vector(1, 0, 0) end
		s2:Normalize()
		local up2 = s2:Cross(n2)
		local sp, ti = math.rad(t.spin or 0), math.rad(t.tilt)
		local lat = s2 * math.cos(sp) + up2 * math.sin(sp)
		eye = p + (n2 * math.cos(ti) + lat * math.sin(ti)) * (t.dist or 14)
	end
	local tr = util.TraceLine({ start = p + vn * 1.5, endpos = eye, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit then eye = tr.HitPos - (eye - p):GetNormalized() * 1.5 end
	viewPos, viewAng = eye, (p - eye):Angle()
	viewFov, viewNear = t.fov, t.fov and 1 or nil
	if quiet then return end
	-- (how far its form reaches over the skin, and how far the eye is: what a picture of it is measured by)
	local reach = 0
	if best.hole and ABL.WoundFX.Dev then
		local _, r = ABL.WoundFX.Dev.FormSize(best)
		reach = r
	end
	Log(string.format("viewmark %s at %s normal %s size %.2f, %d layers on %s (absorb %.2f), on %s | form reaches %.2f units, eye %.1f units off, fov %s", t.kind, tostring(p), tostring(n), best.S, #best.layers, best.skin and "skin" or "cloth", best.absorb or 1, tostring(bsrc.body),
		reach, eye:Distance(p), tostring(t.fov or 75)))
end
hook.Add("Think", "ABL_SelfTestFollowMark", function()
	if followMark then H.viewmark(followMark, true) end
end)
-- wfset: a value of C.WoundFX for the pictures that follow (the rim's pictures are made again with it)
function H.wfset(t)
	ABL.Config.WoundFX[t.key] = t.value
	if ABL.WoundFX.Form then ABL.WoundFX.Form.at = 0 end
end
function H.debug(t) RunConsoleCommand("abl_debug", tostring(t.mask or 0)) end
-- wound3d: the recess behind a wound's opening (cl_woundfx.lua). flip: which way round its
-- wall is seen; note: write into the log how many recesses were drawn since the last note, and
-- what each mark's recess is.
function H.wound3d(t)
	local W = ABL.WoundFX
	if t.flip ~= nil then W.cavFlip = t.flip and true or false end
	-- probe: the rim's light and shade read off the picture, of the next wound of that kind that is drawn
	if t.probe then W.probe = { kind = t.probe ~= true and t.probe or nil } end
	-- cmd: a console command of the wounds' own, run as a player would; report: the counts, into the log
	if t.cmd then RunConsoleCommand(t.cmd, t.arg) end
	-- drawn: what is drawn of the wounds in a frame from where the camera is (layers painted on
	-- skin, recesses), and how far the nearest mark is
	if t.drawn then
		local f0, l0, c0 = FrameNumber(), W.layersDrawn, W.cavDrawn
		timer.Simple(0.6, function()
			local n = math.max(FrameNumber() - f0, 1)
			local near, eye = math.huge, EyePos()
			for _, src in ipairs(ABL.Sources.list) do
				for _, mk in ipairs(src.marks or {}) do
					if mk.hitPos then near = math.min(near, mk.hitPos:Distance(eye)) end
				end
			end
			Log(string.format("wound3d drawn %s: %.1f layer(s) and %.1f recess(es) a frame; the nearest mark is %.0f units from the eye", tostring(t.drawn), (W.layersDrawn - l0) / n, (W.cavDrawn - c0) / n, near))
		end)
	end
	if t.report then
		local recs, marks, withCav, built, patches, kinds = W.Report()
		Log(string.format("wound3d report %s: %d record(s), %d mark(s) (%s), %d with a recess (%d built), %d patch mesh(es)", tostring(t.report), recs, marks, kinds, withCav, built, patches))
	end
	if t.note then
		local n = 0
		for _, src in ipairs(ABL.Sources.list) do
			for _, mk in ipairs(src.marks or {}) do
				local c = mk.cav
				if c then n = n + 1 end
				-- (each mark once: the list grows through a scene)
				if c and not mk.noted then
					mk.noted = true
					Log(string.format("wound3d %s: %s %s on %s, opening %.2f units, recess %.2f deep, leaning (%.2f %.2f), %s floor, frame %s, mesh %s | form %s%s | patch of %d triangle(s), half-size %.2f",
						tostring(t.note), mk.kind, tostring(mk.holeName),
						mk.skin and "skin" or "cloth", c.R0, c.D, c.kx, c.ky, c.pale and "bone" or "tissue", tostring(mk.frame ~= nil), tostring(c.mesh ~= nil),
						c.fout and "built" or (c.fbad and "not to be had" or "not built"),
						c.fH and string.format(", rim %.3f units high over a width of %.2f, %d places round, torn to %.2f, %d of the outside's places off the patch, built in %.1f ms", c.fH, c.fw, c.fNS or 0, c.ftears or 0, c.fmiss or 0, c.fms or 0) or "",
						mk.patch and mk.patch.n / 3 or 0, mk.S or 0))
					-- the light it is drawn under: what was used, and what the engine says falls
					-- on the place from six sides (and where the sun is)
					if mk.klx and mk.wnx then
						local s = string.format("wound3d %s:   lit from (%.2f %.2f %.2f), %.2f times the light from all round (%s); it faces (%.2f %.2f %.2f)", tostring(t.note), mk.klx, mk.kly, mk.klz, mk.klr,
							mk.klFit and "from the engine's account" or "the sun or from above", mk.wnx, mk.wny, mk.wnz)
						local kx, ky, kz, ratio, six = W.FitLight(mk.wax + mk.wnx * 2, mk.way + mk.wny * 2, mk.waz + mk.wnz * 2)
						if kx then
							s = s .. string.format(" | engine: +x %.3f -x %.3f +y %.3f -y %.3f +z %.3f -z %.3f -> from (%.2f %.2f %.2f), %.2f times", six[1], six[2], six[3], six[4], six[5], six[6], kx, ky, kz, ratio)
						else
							s = s .. " | engine: nothing of use"
						end
						local sx, sy, sz = ABL.Render.SunDir()
						if sx then s = s .. string.format(" | the sun is at (%.2f %.2f %.2f)", sx, sy, sz) end
						Log(s)
					end
				end
			end
		end
		local ts = render.GetToneMappingScaleLinear()
		Log(string.format("wound3d %s: %d mark(s) with a recess, %d recess draws and %d rim draws since the last note, abl_wound_3d %s, abl_wound_form %s, flipped %s, a frame %.2f ms on average, the body's blood and wounds %.3f ms of it (wounds %.3f); exposure scale %s",
			tostring(t.note), n, W.cavDrawn, W.reliefDrawn or 0, tostring(ABL.Config.cl.wound3d:GetBool()), tostring(ABL.Config.cl.woundForm:GetBool()), tostring(W.cavFlip), (ABL.selfFt and ABL.selfFt() or 0) * 1000,
			ABL.Prof.Get("draw.body") or 0, ABL.Prof.Get("sub.body.marks") or 0, ts and string.format("%.3f", ts.x) or "?"))
		W.cavDrawn = 0
		W.reliefDrawn = 0
	end
end
function H.clear()
	ABL.ClearAll(false)
	-- (the look the run began with, for the next scene: H.begin; the canvases' materials take it too)
	if lookKept then
		if lookKept.film then PutBack(lookKept.film) end
		if lookKept.v19 then PutBack(lookKept.v19) end
		local D = ABL.FilmDraw
		if D and D.Repaint then
			local ok, err = pcall(D.Repaint)
			if not ok then Log("clear: the film's materials were not set anew: " .. tostring(err)) end
		end
	end
end

-- frame time averaged over ~20 frames (a single frame after a screenshot capture is meaningless)
local ftAvg = 1 / 60
ABL.selfFt = function() return ftAvg end
hook.Add("Think", "ABL_SelfTestFrameTime", function()
	ftAvg = ftAvg * 0.95 + math.min(RealFrameTime(), 0.5) * 0.05
end)

hook.Add("CalcView", "ABL_SelfTestView", function(ply, pos, ang, fov)
	if viewPos then return { origin = viewPos, angles = viewAng, fov = viewFov or 75, drawviewer = false, znear = viewNear } end
end)

-- (t.png: the picture as abl_test/<name>.png, without the blocks and the smeared colour that JPEG
-- lays along a red outline on light cloth: for judging outlines. Larger, and slower to take.)
function H.shot(t) shotQueue[#shotQueue + 1] = t.png and { name = t.name, png = true } or t.name end

-- A burst: t.frames consecutive frames (or every t.every-th) of a part of the screen, as
-- abl_test/<name>_000.jpg and on (tools/harness/framediff.ps1 scores them). One at a time.
-- t.png: as <name>_000.png and on (tools/harness/steady.ps1 measures how steady they are).
local burst
local burstQueue = {}
function H.poolburst(t)
	burstQueue[#burstQueue + 1] = t
end

hook.Add("PostRender", "ABL_SelfTestBurst", function()
	if not burst and burstQueue[1] then
		-- (one at a time: a burst that is asked for while another runs begins when that one ends)
		local t = table.remove(burstQueue, 1)
		burst = { name = t.name, n = t.frames, k = 0, x = t.x or 560, y = t.y or 315, w = t.w or 800, h = t.h or 450, q = t.quality or 92,
			every = t.every or 1, skip = 0, t0 = CurTime(), r0 = RealTime(), last = CurTime(), dmax = 0, f0 = FrameNumber(), png = t.png and true or nil }
	end
	local b = burst
	if not b then return end
	b.skip = b.skip + 1
	if b.skip < b.every then return end
	b.skip = 0
	if b.png then
		-- (alpha false: the screen's own alpha is not the picture's, and a PNG would keep it)
		local data = render.Capture({ format = "png", alpha = false, x = b.x, y = b.y, w = b.w, h = b.h })
		if data then file.Write(string.format("abl_test/%s_%03d.png", b.name, b.k), data) end
	else
		local data = render.Capture({ format = "jpeg", quality = b.q, x = b.x, y = b.y, w = b.w, h = b.h })
		if data then file.Write(string.format("abl_test/%s_%03d.jpg", b.name, b.k), data) end
	end
	local now = CurTime()
	if b.k > 0 and now - b.last > b.dmax then b.dmax = now - b.last end
	b.last = now
	b.k = b.k + 1
	if b.k >= b.n then
		Log(string.format("burst %s: %d frames (every %d) of %dx%d%s, game time %.2f s, real time %.2f s, %.1f ms of game time between two on average, %.0f ms at most, %d frames rendered",
			b.name, b.k, b.every, b.w, b.h, b.png and " (png)" or "", now - b.t0, RealTime() - b.r0, (now - b.t0) / math.max(b.k - 1, 1) * 1000, b.dmax * 1000, FrameNumber() - b.f0))
		burst = nil
	end
end)

hook.Add("PostRender", "ABL_SelfTestCapture", function()
	if #shotQueue == 0 then return end
	local name = table.remove(shotQueue, 1)
	local data
	if type(name) == "table" then
		-- (H.shot's t.png)
		name = name.name
		data = render.Capture({ format = "png", alpha = false, x = 0, y = 0, w = ScrW(), h = ScrH() })
		if data then file.Write("abl_test/" .. name .. ".png", data) end
	else
		data = render.Capture({ format = "jpeg", quality = 90, x = 0, y = 0, w = ScrW(), h = ScrH() })
		if data then file.Write("abl_test/" .. name .. ".jpg", data) end
	end
	-- (the engine hands out no picture while the game's menu or its console is open)
	Log("shot " .. name .. (data and "" or (" FAILED" .. (gui.IsGameUIVisible() and " (the game's menu or console is open)" or ""))))
end)

function H.stats(t)
	local wounds, blobs, trails, anchored = 0, 0, 0, 0
	for _, src in ipairs(ABL.Sources.list) do
		wounds = wounds + #src.woundList
		blobs = blobs + #src.blobs
		trails = trails + (src.segCount or 0)
		for _, w in ipairs(src.woundList) do if w.tri then anchored = anchored + 1 end end
	end
	local TM = ABL.Timing
	local meshes = {}
	for k, m in pairs(ABL.BodyMesh.cache) do meshes[#meshes + 1] = k .. "=" .. (m.ready and (m.nt .. "t" .. (m.bindInverted and "/inv" or "")) or (m.failed and "FAILED" or "building")) end
	Log(string.format("stats %s | sources %d wounds %d anchored %d blobs %d trails %d | drops %d parts %d overlays %d pools %d runoff %d | decals %d rej %d | sim %.3fms draw %.3fms body %.3fms src %.3f emit %.3f flow %.3f drops %.3f runoff %.3f pools %.3f misc %.3f | lod %.2f | net %d events %.1f kbit | fps %.0f (frame %.1fms) | meshes %s",
		t.name, #ABL.Sources.list, wounds, anchored, blobs, trails, ABL.Drops.Count(), ABL.Drops.ParticleCount(), ABL.Stains.Count(), ABL.Pools.Count(), ABL.Runoff.Count(),
		ABL.Stains.stats.decals, ABL.Stains.stats.rejected, TM.sim, TM.draw, TM.body or 0, TM.src, TM.emit, TM.flow, TM.drops, TM.runoff, TM.pools, TM.misc, ABL.LOD.scale,
		ABL.Debug.netTotals.count, ABL.Debug.netTotals.bits / 1000, 1 / ftAvg, ftAvg * 1000, table.concat(meshes, ",")))
	local gs = ABL.Ground.stats
	Log(string.format("   ground stains %d (cap %d) placed %d removed %d shrunk %d merged %d skipped %d", ABL.Ground.Count(), ABL.LOD.Cap(ABL.Config.cl.maxGround), gs.placed, gs.removed, gs.shrunk, gs.merged, gs.skipped))
	local Sim = ABL.Sim
	local marks = 0
	for _, s in ipairs(ABL.Sources.list) do marks = marks + (s.marks and #s.marks or 0) end
	Log(string.format("   sim tick %.0f Hz (target %d) ticks/frame %.2f | wound marks %d | droplet traces %d", Sim.rate, Sim.Target(), Sim.steps, marks, ABL.Drops.prof.trs or 0))
	local ps, pb, psat, pslots = ABL.Pools.stats, ABL.Pools.Totals()
	local PCV = ABL.PoolCanvas
	Log(string.format("   pools %d stamps %d spatter %d slots %d page %s float %s (check %s) usage %.0f%% | created %d merged %d fed %d lobes %d sats %d necks %d clips %d | paints %d avg %.2fms (%.2fms/frame)",
		ABL.Pools.Count(), pb, psat, pslots, tostring(PCV.page), tostring(PCV.float), tostring(PCV.checkAlpha), PCV.Usage() * 100,
		ps.created, ps.merged, ps.fed, ps.lobes, ps.sats, ps.necks, ps.clips, ps.paints, ps.paintMs, TM.paint or 0))
	for i, p in ipairs(ABL.Pools.list) do
		if i > 12 then break end
		Log(string.format("     pool %s vol %.1f wet %.2f %s blobs %d clips %d slot %s canvas H %.1f dist %.0f vis %s%s", p.fam, p.vol, p.wet, p.look.wetMode, #p.blobs, #p.clips, p.slot and p.slot.size or "-", p.canvas and p.canvas.H or -1, p.dist or -1, tostring(p.vis), ABL.Pools.SimInfo(p)))
	end
	for _, src in ipairs(ABL.Sources.list) do
		Log(string.format("   src %s body %s lod %s imp %.2f flow %.2f alive %s pulse %s", tostring(src.key), tostring(src.body), tostring(src.lod), src.importance or 0, src.flowRate or 0, tostring(src.alive), tostring(src.pulse)))
	end
	for _, src in ipairs(ABL.Sources.list) do
		for _, wd in ipairs(src.woundList) do
			Log(string.format("     wound %s sev %.1f bone %s anchored %s profile %s bead %.3f hidden %s flow %.2f hydro %.2f clot %.2f", wd.id, wd.sev or 0, tostring(wd.bone), tostring(wd.tri ~= nil), wd.profile and wd.profile.name or "-", wd.bead and wd.bead.vol or 0, tostring(wd.hidden), wd.flow or 0, wd.hydro or 1, wd.clotK or 1))
		end
	end
	-- per bead: where it sits and how gravity splits on its triangle (why it moves or not)
	local gx, gy, gz, gmag = ABL.Gravity()
	for _, src in ipairs(ABL.Sources.list) do
		local m = src.mesh
		if m and IsValid(src.body) then
			for i, b in ipairs(src.blobs) do
				if i > 12 then break end
				if not b.dead and b.tri and b.tri <= m.nt then
					local _, _, _, _, _, _, _, _, _, nx, ny, nz = src.pose:Tri(b.tri)
					local gn = (gx * nx + gy * ny + gz * nz) / gmag
					local gt = math.sqrt(math.max(0, 1 - gn * gn))
					Log(string.format("       bead %d tri %d shell %s vol %.3f teth %s moving %s edge %s hang %.2f stuck %.1f age %.1f travel %.2f g.n %.2f g_t %.2f",
						i, b.tri, tostring(m.shell and m.shell[b.tri]), b.vol, tostring(b.tethered ~= nil), tostring(b.moving), tostring(b.atEdge), b.hangK or 0, b.stuckT or 0, b.age or 0, b.travel or 0, gn, gt))
				end
			end
		end
	end
	local fp, dp = ABL.Flow.prof, ABL.Drops.prof
	if fp and dp then
		Log(string.format("     prof bead steps %d %.2fms (%.1fus each) walk %.2fms bridge %d %.2fms seep %d %.2fms body draws %d | drop hitbox %d %.2fms traces %d %.2fms | frames %d",
			fp.steps, fp.step, fp.steps > 0 and fp.step / fp.steps * 1000 or 0, fp.walk, fp.bridges, fp.bridge, fp.seeps, fp.seep, fp.draws or 0, dp.hbs, dp.hb, dp.trs, dp.tr, FrameNumber() - (H.lastFrame or FrameNumber())))
		H.lastFrame = FrameNumber()
		Log(string.format("     prof body draw: live streaks %.2fms beads %.2fms stain builds %d %.2fms dupes %d",
			fp.dyn or 0, fp.beadDraw or 0, fp.builds or 0, fp.build or 0, fp.dupes or 0))
		for k in pairs(fp) do fp[k] = 0 end
		for k in pairs(dp) do dp[k] = 0 end
	end
	for _, p in ipairs(player.GetBots()) do
		Log(string.format("   bot %s pos %s camdist %.0f transmit %s notseen %s dormant %s nodraw %s rendermode %d alive %s fake %s",
			p:Nick(), tostring(p:GetPos()), viewPos and p:GetPos():Distance(viewPos) or -1, tostring(p.shouldTransmit), tostring(p.NotSeen), tostring(p:IsDormant()), tostring(p:GetNoDraw()), p:GetRenderMode(), tostring(p:Alive()), tostring(IsValid(p.FakeRagdoll))))
	end
	-- the profiler's view of the same moment; its frame-time window restarts
	if H.profile then H.profile({ name = t.name, reset = true }) end
end

function H.spray(t)
	-- (t.seed: the same drops at every run, for pictures that are to be compared)
	local rng = ABL.RNG(t.seed or (math.floor(CurTime() * 1000) + math.random(1, 100000)))
	local d = t.dir
	for _ = 1, t.count do
		local dx, dy, dz = ABL.Emission.Cone(rng, d.x, d.y, d.z, t.cone or 0.08)
		local s = t.speed * rng:Range(0.9, 1.1)
		local ox, oy = 0, 0
		if t.area then ox, oy = rng:Range(-t.area, t.area), rng:Range(-t.area, t.area) end
		-- (t.owner: whose blood it is to be, an entity)
		ABL.Drops.Spawn(t.pos.x + ox, t.pos.y + oy, t.pos.z, dx * s, dy * s, dz * s, t.vol * rng:Range(0.7, 1.3), nil, 0, 0, nil, t.owner)
	end
end

-- One of the pools' constants (ABL.Config.Pool) set from a scene, for comparing within one run.
function H.poolpoke(t)
	ABL.Config.Pool[t.key] = t.value
	Log(string.format("pool constant %s = %s", tostring(t.key), tostring(t.value)))
end

-- The pools by the character they belong to (a line "poolreport <name>"), what the limits did
-- since the map began, and, with t.ent, what runs on that character's body.
function H.poolreport(t)
	local P = ABL.Pools
	local st = P.stats
	local parts = {}
	for _, e in ipairs(P.Report()) do
		parts[#parts + 1] = string.format("%s: %d pool(s), %d wet, %.0f ml, widest %.1f", e.owner and tostring(e.owner) or "nobody's", e.n, e.wet, e.ml, e.widest)
	end
	local body = ""
	if t.ent ~= nil then
		local S = ABL.Sources
		local src = IsValid(t.ent) and (S.byKey[t.ent] or S.byBody[t.ent]) or nil
		local fc = src and src.fc
		body = string.format(" | on %s: %s", tostring(t.ent), src and string.format("%d stream(s), %d of them begun by drops, %.2f ml liquid on the body, surface model %s",
			fc and #fc.chans or 0, fc and (fc.landed or 0) or 0, fc and ABL.FlowCore.Held(fc) or 0, tostring(src.mesh ~= nil)) or "no source")
	end
	Log(string.format("poolreport %s | %d pools, %d drops in the air, %d stains on the ground, %d nodes of streams on the world, %d trail stains left on moved props | %s | made way %d, held as stains %d, gathered %d, at full width %d | caught on another body %d, flew on past a hull %d%s",
		tostring(t.name), P.Count(), ABL.Drops.Count(), ABL.Ground.Count(), ABL.FlowWorld.Nodes(), ABL.FlowWorld.left or 0,
		#parts > 0 and table.concat(parts, " ; ") or "none", st.recycled, st.held, st.gathered, st.capped,
		ABL.Drops.prof.caught or 0, ABL.Drops.prof.passed or 0, body))
end

function H.cvar(t) RunConsoleCommand(t.name, t.value) end
-- (the stains' mirror as on a map without cubemaps: the pattern sheen)
function H.groundnoenv(t) ABL.Ground.noEnv = t.on and true or nil end
function H.pooltone(t) Log("pool tone " .. tostring(t.name) .. ": exposure scale in the pools' pass " .. tostring(ABL.Pools.tone)) end
function H.sheeninfo(t)
	local ts = render.GetToneMappingScaleLinear()
	Log("sheen " .. tostring(t.name) .. ": " .. ABL.Ground.SheenInfo() .. " | exposure scale " .. tostring(ts))
end

-- How many table slots hang off each part of ABL: tables reached through its fields and through
-- the upvalues of its functions, each counted once, under the first part (by name) that
-- reaches it. A leak shows as a part that is larger at every reading.
local function Census()
	local seen = {}
	local getup, getinfo = debug and debug.getupvalue, debug and debug.getinfo
	seen[_G] = true
	if package and package.loaded then seen[package.loaded] = true end
	local Walk
	Walk = function(v, depth)
		if seen[v] then return 0 end
		seen[v] = true
		local n = 0
		if type(v) == "table" then
			for k, x in pairs(v) do
				n = n + 1
				if depth < 60 then
					local tk, tx = type(k), type(x)
					if tk == "table" or tk == "function" then n = n + Walk(k, depth + 1) end
					if tx == "table" or tx == "function" then n = n + Walk(x, depth + 1) end
				end
			end
		elseif getup and getinfo and getinfo(v, "S").what ~= "C" then
			for i = 1, 60 do
				local name, x = getup(v, i)
				if not name then break end
				local tx = type(x)
				if depth < 60 and (tx == "table" or tx == "function") then n = n + Walk(x, depth + 1) end
			end
		end
		return n
	end
	seen[ABL] = true
	local names = {}
	for k in pairs(ABL) do if isstring(k) then names[#names + 1] = k end end
	table.sort(names)
	local parts, total = {}, 0
	for _, k in ipairs(names) do
		local v = ABL[k]
		if istable(v) or isfunction(v) then
			local n = Walk(v, 1)
			total = total + n
			if n > 0 then parts[#parts + 1] = { k, n } end
		end
	end
	table.sort(parts, function(a, b) return a[2] > b[2] end)
	local out = {}
	for i = 1, math.min(#parts, 16) do out[i] = parts[i][1] .. " " .. parts[i][2] end
	return total, table.concat(out, ", ")
end

-- Profiler report into the stats file (t.name), optionally restarting the frame-time window.
function H.profile(t)
	ABL.Prof.force = true
	if t.name then
		Log("profile " .. t.name)
		for _, l in ipairs(ABL.Prof.Lines()) do Log("   | " .. l) end
		JitReport()
	end
	if t.floor then
		-- What is left when nothing is: the heap after a full collection (read at a moment it
		-- says where the collector happens to be), and what should be gone.
		collectgarbage("collect")
		collectgarbage("collect")
		local hooks = 0
		for _, tab in pairs(hook.GetTable()) do
			for id in pairs(tab) do
				if isstring(id) and string.sub(id, 1, 3) == "ABL" then hooks = hooks + 1 end
			end
		end
		-- (render targets are a fixed set made by name; what a pool takes is a slot of the page)
		local _, _, slots = ABL.Pools.Totals()
		Log(string.format("heap floor %s: %.1f MB | channels with strips %d | ABL hooks %d | pool canvas slots in use %d (%.0f %% of the page)", tostring(t.name),
			collectgarbage("count") / 1024, ABL.FlowDraw.bakes or 0, hooks, slots or -1, ABL.PoolCanvas.Usage() * 100))
		local total, parts = Census()
		Log(string.format("census %s: %d slots | %s", tostring(t.name), total, parts))
	end
	if t.reset then ABL.Prof.ResetFrameStats() end
end

-- The channels on all bodies by what the solver and the drawing do with them, and a few of
-- those that are still stepped at every frame with their figures.
function H.flowdump(t)
	local now = CurTime()
	local cls, order, sample = {}, {}, {}
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.fc
		for _, ch in ipairs(s and s.chans or {}) do
			local key
			if ch.dead then key = "dead"
			elseif ch.done then key = "dry (done)"
			elseif ch.head then key = "awake: has a head"
			elseif (ch.mobile or 0) >= 1e-4 then key = "awake: liquid"
			elseif ch.idleT > 1.5 then key = "idle"
			else key = "awake: no liquid, no head" end
			local e = cls[key]
			if not e then e = { 0, 0, 0 } cls[key] = e order[#order + 1] = key end
			e[1], e[2] = e[1] + 1, e[2] + ch.n
			if ch.bake then e[3] = e[3] + 1 end
			if string.sub(key, 1, 5) == "awake" and #sample < 8 then
				sample[#sample + 1] = string.format("   %s | nodes %d idle %.2f s mobile %.6f wettest %.2f fed %.1f s ago steps %d | wound %s parent %s joins %s inflow %s hold %.1f",
					key, ch.n, ch.idleT, ch.mobile or -1, ch.wetMax or -1, now - ch.fedT, ch.steps or 0, tostring(ch.wd ~= nil), tostring(ch.parentCh ~= nil),
					tostring(ch.joinCh ~= nil), tostring(ch.inflow), math.max((ch.bakeHold or 0) - RealTime(), 0))
			end
		end
	end
	table.sort(order)
	local parts = {}
	for _, key in ipairs(order) do parts[#parts + 1] = string.format("%s %d (%d nodes, %d with strips)", key, cls[key][1], cls[key][2], cls[key][3]) end
	Log("flowdump " .. tostring(t.name) .. ": " .. table.concat(parts, " | "))
	-- (the bodies: a run in which they are not in the detail tier has their blood in pools only)
	local bodies = {}
	for _, src in ipairs(ABL.Sources.list) do
		bodies[#bodies + 1] = string.format("lod %s %s dist %.0f mesh %s", tostring(src.lod), src.visible and "in view" or "not in view", src.dist or -1, src.mesh and "ready" or "none")
	end
	Log("   bodies: " .. table.concat(bodies, " | "))
	for _, l in ipairs(sample) do Log(l) end
end

-- What this build of the game allows (asked once, before code is written that relies on it):
-- a position given as three numbers, a matrix set from numbers, a static mesh built a second time.
function H.probemesh()
	hook.Add("PostDrawTranslucentRenderables", "ABL_ProbeMesh", function(_, sky)
		if sky then return end
		hook.Remove("PostDrawTranslucentRenderables", "ABL_ProbeMesh")
		local v = Vector(0, 0, -30000)
		render.SetColorMaterial()
		mesh.Begin(MATERIAL_TRIANGLES, 1)
		local okNum, errNum = pcall(mesh.Position, 0, 0, -30000)
		for _ = 1, 3 do
			mesh.Position(v)
			mesh.Color(0, 0, 0, 0)
			mesh.AdvanceVertex()
		end
		mesh.End()
		Log("probe mesh.Position(x, y, z): " .. tostring(okNum) .. " " .. tostring(errNum))
		Log("probe VMatrix.SetUnpacked: " .. tostring(Matrix().SetUnpacked ~= nil))
		local im = Mesh()
		local function Tri()
			mesh.Begin(im, MATERIAL_TRIANGLES, 1)
			for _ = 1, 3 do
				mesh.Position(v)
				mesh.Color(0, 0, 0, 0)
				mesh.AdvanceVertex()
			end
			mesh.End()
		end
		local ok1, err1 = pcall(Tri)
		Log("probe static mesh built: " .. tostring(ok1) .. " " .. tostring(err1))
		local ok2, err2 = pcall(Tri)
		Log("probe static mesh built a second time: " .. tostring(ok2) .. " " .. tostring(err2))
		im:Destroy()
	end)
end

-- What this build does with a lit, glossy material on a mesh made in Lua that lies on the world's
-- floor (asked before the drops' highlights are built on it): a row of domes with the outline of
-- a stain, each under one material. What shows a highlight, cut to the outline, with the
-- surroundings mirrored by the angle of view, is read off the pictures. t.view: where the eye is
-- (1 toward the sun, 2 the same from higher, 3 the sun behind the eye, 4 toward the sun, low).
local probeGloss
function H.probegloss(t)
	if t.view then
		local g = probeGloss
		if not g then return end
		local horiz = Vector(g.sun.x, g.sun.y, 0):GetNormalized()
		local c = g.center
		local eye
		if t.view == 1 then eye = c - horiz * 80 + Vector(0, 0, 56)
		elseif t.view == 2 then eye = c - horiz * 40 + Vector(0, 0, 86)
		elseif t.view == 3 then eye = c + horiz * 80 + Vector(0, 0, 56)
		else eye = c - horiz * 110 + Vector(0, 0, 22) end
		viewPos, viewAng, viewNear = eye, (c - eye):Angle(), nil
		return
	end
	local tr = util.TraceLine({ start = t.pos + Vector(0, 0, 20), endpos = t.pos - Vector(0, 0, 60), mask = MASK_SOLID_BRUSHONLY })
	local g = { center = tr.HitPos, stop = RealTime() + (t.secs or 30) }
	local sx, sy, sz = ABL.Render.Sun()
	g.sun = sx and Vector(sx, sy, sz) or Vector(0.4, 0.3, 0.86):GetNormalized()
	probeGloss = g
	Log(string.format("probe gloss: sun %s (toward it %.2f %.2f %.2f) | dev/flat_normal %s", tostring(sx ~= nil), g.sun.x, g.sun.y, g.sun.z,
		tostring(file.Exists("materials/dev/flat_normal.vtf", "GAME"))))
	local function Setup()
		local c = g.center
		local horiz = Vector(g.sun.x, g.sun.y, 0):GetNormalized()
		local side = Vector(-horiz.y, horiz.x, 0)
		local atlas = "advancedblood/ground/stainatlas"
		local cube = ABL.Render.Cubemap(c.x, c.y, c.z + 8)
		local serial = math.floor(SysTime() * 1000) % 100000
		local function Lit(name, extra)
			local kv = { ["$basetexture"] = atlas, ["$nocull"] = 1, ["$additive"] = 1, ["$color2"] = "[0 0 0]",
				["$phong"] = 1, ["$phongexponent"] = 20, ["$phongboost"] = 4, ["$phongfresnelranges"] = "[1 1 1]" }
			for k, v in pairs(extra or {}) do
				if v == false then kv[k] = nil else kv[k] = v end
			end
			return CreateMaterial("abl_pg_" .. name .. serial, "VertexLitGeneric", kv)
		end
		local FN = "dev/flat_normal"
		g.cols = {
			{ "unlit, the cubemap at 0.14 (as the stains are now)", cube and ABL.Ground.EnvMat(cube) or nil, env = true },
			{ "phong added, flat normal map", Lit("a", { ["$bumpmap"] = FN }) },
			{ "the same, the base texture's alpha as the highlight's mask", Lit("b", { ["$bumpmap"] = FN, ["$basemapalphaphongmask"] = 1 }) },
			{ "phong added, no normal map, base alpha as mask", Lit("c", { ["$basemapalphaphongmask"] = 1 }) },
			{ "as 3, and the cubemap by Fresnel", Lit("d", { ["$bumpmap"] = FN, ["$basemapalphaphongmask"] = 1, ["$envmap"] = cube or "env_cubemap",
				["$envmaptint"] = "[1 1 1]", ["$envmapfresnel"] = 1, ["$phongfresnelranges"] = "[0.02 0.3 1]" }) },
			{ "as 3, translucent in place of added", Lit("e", { ["$bumpmap"] = FN, ["$basemapalphaphongmask"] = 1, ["$additive"] = false, ["$translucent"] = 1 }) },
			{ "as 3, exponent 5, boost 2", Lit("f", { ["$bumpmap"] = FN, ["$basemapalphaphongmask"] = 1, ["$phongexponent"] = 5, ["$phongboost"] = 2 }) },
			{ "as 3, $alpha 0.3 set at the draw", Lit("g", { ["$bumpmap"] = FN, ["$basemapalphaphongmask"] = 1 }), alpha = 0.3 },
		}
		for i, col in ipairs(g.cols) do Log(string.format("probe gloss column %d: %s", i, col[1])) end
		Log("probe gloss cubemap: " .. tostring(cube))
		-- the dome: 5 units wide at its foot, 2 high, on the quad of atlas cell 8 (a drop)
		local A, HH, N = 5, 2, 20
		local Q = A / 0.53
		local u0, v0, u1, v1 = 6 / 2048, 1 / 4 + 6 / 1024, 1 / 8 - 6 / 2048, 2 / 4 - 6 / 1024
		local col = Color(88, 6, 11, 255)
		g.meshes = {}
		for k = 1, #g.cols do
			local base = c + side * ((k - (#g.cols + 1) / 2) * 15) + Vector(0, 0, 0.1)
			local rows = {}
			for j = 0, N do
				rows[j] = {}
				for i = 0, N do
					local x, y = (i / N * 2 - 1) * Q, (j / N * 2 - 1) * Q
					local rho2 = (x * x + y * y) / (A * A)
					local z, gx, gy = 0, 0, 0
					if rho2 < 1 then z, gx, gy = HH * (1 - rho2), -2 * HH * x / (A * A), -2 * HH * y / (A * A) end
					local n = Vector(-gx, -gy, 1):GetNormalized()
					local tg = (Vector(1, 0, 0) - n * n.x):GetNormalized()
					rows[j][i] = { pos = base + Vector(x, y, z), normal = n, u = u0 + (u1 - u0) * i / N, v = v0 + (v1 - v0) * j / N,
						userdata = { tg.x, tg.y, tg.z, 1 }, color = col }
				end
			end
			local tris = {}
			for j = 0, N - 1 do
				for i = 0, N - 1 do
					local a, b, cc, d = rows[j][i], rows[j + 1][i], rows[j + 1][i + 1], rows[j][i + 1]
					tris[#tris + 1] = a tris[#tris + 1] = b tris[#tris + 1] = cc
					tris[#tris + 1] = a tris[#tris + 1] = cc tris[#tris + 1] = d
				end
			end
			local m = Mesh()
			m:BuildFromTriangles(tris)
			g.meshes[k] = m
		end
		g.light = { { type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = -g.sun } }
	end
	hook.Add("PostDrawTranslucentRenderables", "ABL_ProbeGloss", function(_, sky)
		if sky then return end
		if RealTime() > g.stop then
			hook.Remove("PostDrawTranslucentRenderables", "ABL_ProbeGloss")
			for _, m in ipairs(g.meshes or {}) do m:Destroy() end
			probeGloss = nil
			return
		end
		if not g.meshes then
			local ok, err = pcall(Setup)
			if not ok then
				Log("probe gloss setup failed: " .. tostring(err))
				g.stop = 0
				return
			end
		end
		-- the body under every dome: the blood's own colour, cut by the outline
		render.SetMaterial(ABL.Mat.ground)
		for k = 1, #g.cols do g.meshes[k]:Draw() end
		for k, col in ipairs(g.cols) do
			local mat = col[2]
			if mat and col.env then
				mat:SetFloat("$alpha", 0.14)
				render.SetMaterial(mat)
				render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
				g.meshes[k]:Draw()
				render.OverrideBlend(false)
			elseif mat then
				if col.alpha then mat:SetFloat("$alpha", col.alpha) end
				render.SuppressEngineLighting(true)
				render.SetLightingOrigin(g.center)
				render.ResetModelLighting(0, 0, 0)
				render.SetLocalModelLights(g.light)
				render.SetMaterial(mat)
				g.meshes[k]:Draw()
				render.SetLocalModelLights()
				render.SuppressEngineLighting(false)
			end
		end
	end)
end

-- How often a frame the world is drawn in a view the blood is drawn into, and what those views
-- are (asked when a counter showed three times the meshes that exist).
function H.probeviews(t)
	local frames, calls, seen, left = {}, 0, {}, t.frames or 40
	hook.Add("PreDrawTranslucentRenderables", "ABL_ProbeViews", function(depth, sky, sky3d)
		local vs = render.GetViewSetup()
		local rt = render.GetRenderTarget()
		local key = string.format("depth %s sky %s sky3d %s | %dx%d fov %.0f znear %.1f | target %s | eye %s", tostring(depth), tostring(sky), tostring(sky3d),
			vs.width or -1, vs.height or -1, vs.fov or -1, vs.znear or -1, rt and rt:GetName() or "screen", tostring(vs.origin))
		local fn = FrameNumber()
		frames[fn] = (frames[fn] or 0) + 1
		calls = calls + 1
		if not seen[key] and table.Count(seen) < 12 then
			seen[key] = true
			Log("probe views: " .. key .. " | call " .. frames[fn] .. " of frame " .. fn)
		end
	end)
	hook.Add("PostRender", "ABL_ProbeViews", function()
		left = left - 1
		if left > 0 then return end
		hook.Remove("PreDrawTranslucentRenderables", "ABL_ProbeViews")
		hook.Remove("PostRender", "ABL_ProbeViews")
		local n, most = 0, 0
		for _, c in pairs(frames) do n = n + 1 most = math.max(most, c) end
		Log(string.format("probe views: %d calls of the hook in %d frames (most in one frame %d) | screen %dx%d", calls, n, most, ScrW(), ScrH()))
		local names = {}
		for name in pairs(hook.GetTable().RenderScene or {}) do names[#names + 1] = tostring(name) end
		Log("probe views: RenderScene hooks: " .. table.concat(names, ", "))
		names = {}
		for name in pairs(hook.GetTable().PreDrawTranslucentRenderables or {}) do names[#names + 1] = tostring(name) end
		Log("probe views: PreDrawTranslucentRenderables hooks: " .. table.concat(names, ", "))
	end)
end

-- How often a frame the blood on characters is asked for and drawn, by the view it is asked in.
-- The character renderer runs in every view of the world (the water's two as well); the counters
-- of F.DrawSource sit behind the guards that let one view through, so they cannot say what
-- arrives in front of them. Counted here in front of every guard: the calls of the hook the
-- character renderer fires, their time and what they allocate, and the calls of F.DrawSource.
function H.probebody(t)
	local F, FC = ABL.Flow, ABL.FlowCore
	local ht = hook.GetTable().PostDrawAppearance
	local real = ht and ht.ABL_BodyBlood
	if not real then Log("probe body " .. tostring(t.name) .. ": no hook ABL_BodyBlood on PostDrawAppearance") return end
	local left, frames = t.frames or 60, 0
	local views, asked, bloody, ms, kb, calls, drawn = {}, {}, {}, {}, {}, {}, {}
	local order = {}
	local function Target()
		local rt = render.GetRenderTarget()
		local k = rt and rt:GetName() or "screen"
		if not views[k] then
			views[k], asked[k], bloody[k], ms[k], kb[k], calls[k], drawn[k] = 0, 0, 0, 0, 0, 0, 0
			order[#order + 1] = k
		end
		return k
	end
	hook.Add("PreDrawTranslucentRenderables", "ABL_ProbeBody", function(depth, sky, sky3d)
		if depth or sky or sky3d then return end
		local k = Target()
		views[k] = views[k] + 1
	end)
	hook.Add("PostDrawAppearance", "ABL_BodyBlood", function(ent, ply)
		local k = Target()
		asked[k] = asked[k] + 1
		local src = IsValid(ent) and ABL.Sources.byBody and ABL.Sources.byBody[ent]
		if src and src.body == ent and ((src.segCount or 0) > 0 or #src.blobs > 0 or (src.marks and #src.marks > 0) or FC.Active(src) or ABL.Film.Active(src)) then
			bloody[k] = bloody[k] + 1
		end
		local m0 = collectgarbage("count")
		local t0 = SysTime()
		real(ent, ply)
		ms[k] = ms[k] + (SysTime() - t0) * 1000
		local d = collectgarbage("count") - m0
		if d > 0 then kb[k] = kb[k] + d end
	end)
	local draw = F.DrawSource
	F.DrawSource = function(src, body, immediate)
		local k = Target()
		calls[k] = calls[k] + 1
		if src.dsFrame ~= FrameNumber() then drawn[k] = drawn[k] + 1 end
		return draw(src, body, immediate)
	end
	hook.Add("PostRender", "ABL_ProbeBody", function()
		frames = frames + 1
		if frames < left then return end
		hook.Remove("PreDrawTranslucentRenderables", "ABL_ProbeBody")
		hook.Remove("PostRender", "ABL_ProbeBody")
		hook.Add("PostDrawAppearance", "ABL_BodyBlood", real)
		F.DrawSource = draw
		local nSrc, nBlood, nWet = 0, 0, 0
		for _, src in ipairs(ABL.Sources.list) do
			nSrc = nSrc + 1
			if (src.segCount or 0) > 0 or #src.blobs > 0 or (src.marks and #src.marks > 0) or FC.Active(src) or ABL.Film.Active(src) then nBlood = nBlood + 1 end
			if IsValid(src.body) and src.body:WaterLevel() > 0 then nWet = nWet + 1 end
		end
		Log(string.format("probe body %s: %d frames | characters with blood %d of %d sources, %d of them in water | a frame, by the view's target:", tostring(t.name), frames, nBlood, nSrc, nWet))
		for _, k in ipairs(order) do
			Log(string.format("probe body %s:   %-22s world views %.2f | hook calls %.2f, for a character with blood %.2f, %.4f ms, %.2f KB | DrawSource calls %.2f, drawn %.2f, refused as a second one %.2f",
				tostring(t.name), k, views[k] / frames, asked[k] / frames, bloody[k] / frames, ms[k] / frames, kb[k] / frames,
				calls[k] / frames, drawn[k] / frames, (calls[k] - drawn[k]) / frames))
		end
	end)
end

-- Pool gallery: pools of given families / volumes laid on the floor around t.pos, fully spread
-- (e.settle) or left to spread; e.drips adds that many drops falling in from height (lobes and
-- satellite spatter).
function H.pooldemo(t)
	local P = ABL.Pools
	for _, e in ipairs(t.list) do
		local pos = t.pos + Vector(e.dx or 0, e.dy or 0, 0)
		local tr = util.TraceLine({ start = pos + Vector(0, 0, 20), endpos = pos - Vector(0, 0, 40), mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit then
			local p = P.Create(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, tr.HitNormal.x, tr.HitNormal.y, tr.HitNormal.z, e.vol, ABL.Surface.FromTrace(tr), nil, e.age, "fam:" .. e.fam, 1, 0, 0)
			if p then
				ABL.FlowCore.Release("pool", e.vol)
				if e.settle ~= false then P.SettleRadii(p, 1) end
				local rng = ABL.RNG(e.vol * 7 + #e.fam)
				for _ = 1, e.drips or 0 do
					local a, d = rng:Next() * 6.283, rng:Range(0, 1) * math.sqrt(e.vol) * 0.6
					local x, y = tr.HitPos.x + math.cos(a) * d, tr.HitPos.y + math.sin(a) * d
					ABL.FlowCore.Release("pool", e.vol * 0.04)
					P.Feed(p, e.vol * 0.04, x, y, tr.HitPos.z, "impact", nil, nil, nil, 380)
					p.satT = 0
				end
			end
		end
	end
	Log("pooldemo " .. #t.list .. " pools")
end

-- Page texels of every pool's slot (canvas diagnostics).
function H.poolprobe()
	for i, p in ipairs(ABL.Pools.list) do
		if i > 8 then break end
		Log(string.format("   probe pool %s slot %s: %s", p.fam, p.slot and (p.slot.x .. "," .. p.slot.y .. "/" .. p.slot.size) or "-", ABL.PoolCanvas.Readback(p.slot)))
	end
end

-- The pool liquid on its own (cl_poolsim.lua, nothing drawn): is volume kept, where does a volume
-- come to rest, what does a step cost. Then (in a render hook) what bringing a lattice into a
-- render target costs.
local benchPending = false
function H.poolsim()
	local PS, ML = ABL.PoolSim, ABL.Config.ML_PER_CU
	local film = 0.085
	local function Ground(g, tilt) PS.SetGround(g, 1000, 2000, tilt or 0, 0) end
	local function Grid(a, n, amp, tilt)
		local g = PS.New(a, n, -n / 2, -n / 2)
		g.film, g.res, g.memK, g.amp = film, film * 0.25, 0.35, amp or 0.5
		Ground(g, tilt)
		return g
	end
	-- 1. volume: blood arriving at a point over 200 steps
	local g = Grid(0.4, 24)
	local put = 0
	for _ = 1, 200 do
		PS.Deposit(g, 0.1, -0.2, 0.004, 0)
		put = put + 0.004
		PS.Step(g, PS.STEP)
		if PS.Fit(g, 32) then Ground(g) end
	end
	Log(string.format("poolsim volume: put %.6f cu, held %.6f (difference %.2e) | lattice %d x %.2f, %d cells wet", put, PS.Volume(g), PS.Volume(g) - put, g.n, g.a, g.wetN))
	-- 2. rest: a volume poured at once, on a rough and on a smooth floor, level and tilted
	local function Rest(ml, amp, tilt)
		local cu = ml / ML
		local R = math.sqrt(cu / (math.pi * film))
		local a = PS.A0
		while 2.6 * R + 6 * a > a * 32 and a < PS.A_MAX do a = a * 2 end
		local n = math.Clamp(math.ceil(2.6 * R / a) + 6, 12, 32)
		n = n + n % 2
		g = Grid(a, n, amp, tilt)
		PS.Deposit(g, 0, 0, cu, 0)
		local steps, fits, t0 = 0, 0, SysTime()
		while steps < 8000 do
			if not PS.Step(g, PS.STEP) then break end
			steps = steps + 1
			if steps % 2 == 0 and PS.Fit(g, 32) then Ground(g, tilt) fits = fits + 1 end
		end
		local ms = (SysTime() - t0) * 1000
		local hmax, hsum, cnt = 0, 0, 0
		for c = 1, g.n * g.n do
			local t = g.h[c]
			if t > 0 then hmax, hsum, cnt = math.max(hmax, t), hsum + t, cnt + 1 end
		end
		local area = cnt * g.a * g.a
		local ext = {}
		for q = 0, 7 do ext[#ext + 1] = string.format("%.1f", PS.Extent(g, math.cos(q * math.pi / 4), math.sin(q * math.pi / 4))) end
		Log(string.format("poolsim rest %d ml pin %.1f tilt %.2f: %d steps (%.1f s of flow, %.1f ms, %d refits)%s | lattice %d x %.2f | area %.1f sq (one film: %.1f), radius %.2f (film radius %.2f), reach %s | layer mean %.3f max %.3f (film %.3f) | volume error %.1e",
			ml, amp, tilt or 0, steps, steps * PS.STEP, ms, fits, PS.Active(g) and " STILL MOVING" or "", g.n, g.a, area, cu / film, math.sqrt(area / math.pi), R,
			table.concat(ext, " "), cnt > 0 and hsum / cnt or 0, hmax, film, PS.Volume(g) - cu))
	end
	for _, ml in ipairs({ 5, 30, 90, 380 }) do
		Rest(ml, 0.5)
		Rest(ml, 0.2)
	end
	Rest(30, 0.5, 0.1)
	Rest(30, 0.5, 0.3)
	-- 2b. fed slowly at a point (2 ml/s for 15 s), as a wound feeds a pool: the outline it takes
	g = Grid(0.4, 14, 0.5)
	for k = 1, 600 do
		if k <= 300 then PS.Deposit(g, 0, 0, 0.1 / ML, k * PS.STEP) end
		PS.Step(g, PS.STEP)
		if k % 2 == 0 and PS.Fit(g, 32) then Ground(g) end
	end
	local ext = {}
	for q = 0, 15 do ext[#ext + 1] = string.format("%.1f", PS.Extent(g, math.cos(q * math.pi / 8), math.sin(q * math.pi / 8))) end
	Log(string.format("poolsim fed 30 ml over 15 s: lattice %d x %.2f, %d cells, reach in 16 directions %s%s", g.n, g.a, g.wetN, table.concat(ext, " "), PS.Active(g) and " (still moving)" or ""))
	-- 2c. time: a film left alone sets and dries (evaporation 0.00028 a second, clotting 60 s)
	g = Grid(0.4, 24, 0.5)
	PS.Deposit(g, 0, 0, 30 / ML, 0)
	for _ = 1, 400 do
		if not PS.Step(g, PS.STEP) then break end
	end
	local v0 = PS.Volume(g)
	local dried, line = 0, {}
	for sec = 1, 400 do
		dried = dried + PS.Age(g, sec, 1, 0.00028, 60)
		if sec == 30 or sec == 70 or sec == 150 or sec == 250 or sec == 330 or sec == 400 then
			line[#line + 1] = string.format("%d s: liquid %.2f set %.2f dried %.2f cu, wet cells %.0f%%..%.0f%%", sec, g.liq, g.gel, g.dep, g.wMin * 100, g.wMax * 100)
		end
	end
	Log(string.format("poolsim time (30 ml, %.3f cu): %s | wet + dried - start %.1e", v0, table.concat(line, " | "), PS.Volume(g) + dried - v0))
	-- 2d. edges: a ledge 2 units from the inlet and a stream line 3 units downhill
	g = Grid(0.4, 24, 0.5)
	PS.SetClips(g, { { u = 2, v = 0, mu = 1, mv = 0, ledge = true } })
	local fed = 0
	for k = 1, 800 do
		if k <= 400 then PS.Deposit(g, 0, 0, 0.1 / ML, k * PS.STEP) fed = fed + 0.1 / ML end
		PS.Step(g, PS.STEP)
	end
	Log(string.format("poolsim ledge: fed %.3f cu, on the floor %.3f, over the edge %.3f (difference %.1e), reach toward the edge %.2f", fed, PS.Volume(g) - g.outVol, g.outVol, PS.Volume(g) - fed, PS.Extent(g, 1, 0)))
	g = Grid(0.4, 24, 0.5, 0.2)
	PS.SetClips(g, {}, { u = 3, v = 0, mu = 1, mv = 0, exit = true })
	fed = 0
	for k = 1, 800 do
		if k <= 400 then PS.Deposit(g, 0, 0, 0.1 / ML, k * PS.STEP) fed = fed + 0.1 / ML end
		PS.Step(g, PS.STEP)
	end
	Log(string.format("poolsim slope 0.2 with a stream line: fed %.3f cu, on the floor %.3f, into the stream %.3f (difference %.1e)", fed, PS.Volume(g) - g.outVol, g.outVol, PS.Volume(g) - fed))
	-- 3. what a step costs while every cell moves
	local function Time(n)
		g = Grid(0.4, n)
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				PS.Splat(g, (g.i0 + i + 0.5) * 0.4, (g.j0 + j + 0.5) * 0.4, film * (1 + 2 * ((i * 7 + j * 13) % 10) / 10) * 0.16, 0)
			end
		end
		local k, t0 = 0, SysTime()
		for _ = 1, 30 do
			if not PS.Step(g, PS.STEP) then break end
			k = k + 1
		end
		local us = (SysTime() - t0) * 1e6 / math.max(k, 1)
		return string.format("%d^2 %.0f us a step (%.0f ns a cell, %d steps)", n, us, us * 1000 / (n * n), k)
	end
	Log("poolsim cost interpreted: " .. Time(16) .. ", " .. Time(24) .. ", " .. Time(32))
	if jit and jit.on and jit.off then
		for _, f in pairs(PS) do if isfunction(f) then jit.on(f, true) end end
		Time(24)
		Log("poolsim cost with the JIT: " .. Time(16) .. ", " .. Time(24) .. ", " .. Time(32))
		if ABL.jitOff then
			for _, f in pairs(PS) do if isfunction(f) then jit.off(f, true) end end
		end
	end
	benchPending = true
end

hook.Add("PostRender", "ABL_SelfTestPoolBench", function()
	if not benchPending then return end
	benchPending = false
	local ok, res = pcall(ABL.PoolCanvas.Bench, 32)
	Log(ok and res or ("pool canvas bench error " .. tostring(res)))
	if not ok then
		render.OverrideBlend(false)
		render.OverrideColorWriteEnable(false, true)
		render.OverrideAlphaWriteEnable(false, true)
	end
end)

-- Blood arriving on the floor at a steady rate (ml/s for t.secs seconds), as a wound above it or
-- a rivulet would bring it: at t.pos, or at every position of t.list. t.surf names a profile of
-- ABL.Config.Surfaces to use instead of what the floor is (the map has few materials).
local feeds = {}
function H.poolfeed(t)
	if t.stop then feeds = {} return end
	for _, pos in ipairs(t.list or { t.pos }) do
		-- (onto the floor or a prop, not onto whoever stands there)
		local tr = util.TraceLine({ start = pos + Vector(0, 0, 20), endpos = pos - Vector(0, 0, 60), mask = MASK_SOLID,
			filter = function(e) return not (e:IsPlayer() or e:IsNPC() or e:IsRagdoll()) end })
		if tr.Hit then
			feeds[#feeds + 1] = {
				pos = tr.HitPos, n = tr.HitNormal, surf = t.surf and ABL.Config.Surfaces[t.surf] or ABL.Surface.FromTrace(tr),
				ent = IsValid(tr.Entity) and tr.Entity or nil, rate = t.rate, till = CurTime() + t.secs, kind = t.kind or "seep", jitter = t.jitter or 0.15, owner = t.owner,
			}
		else
			Log("poolfeed: no floor under " .. tostring(pos))
		end
	end
end

hook.Add("Think", "ABL_SelfTestPoolFeed", function()
	if #feeds == 0 then return end
	local now, dt = CurTime(), FrameTime()
	for i = #feeds, 1, -1 do
		local f = feeds[i]
		if now > f.till then
			table.remove(feeds, i)
		elseif dt > 0 then
			local v = f.rate * dt
			ABL.FlowCore.Release("pool", v)
			ABL.Pools.Deposit(f.pos.x + math.Rand(-f.jitter, f.jitter), f.pos.y + math.Rand(-f.jitter, f.jitter), f.pos.z, f.n, v, f.surf, f.ent, f.kind, nil, nil, nil, nil, f.owner)
		end
	end
end)

-- A liquid pool's figures every t.every seconds for t.secs seconds (lines "poolwatch <name>").
-- depth: cells whose wet layer is a thin film (under 0.6 of a film), normal, deep (over 1.3).
-- down / up: the reach downhill and uphill from where the pool formed, on a slope.
-- dry: of the cells that hold a thin, a normal, a deep layer of blood in any state, how many
-- hold no liquid any more. t.pin: only the first liquid pool there is (the one being fed).
function H.poolwatch(t)
	local t0 = CurTime()
	local every = t.every or 1
	local PS = ABL.PoolSim
	local pin
	timer.Create("ABL_PoolWatch", every, math.ceil(t.secs / every), function()
		local now = CurTime()
		local shown = 0
		for _, p in ipairs(ABL.Pools.list) do
			local g = p.sim
			if g and t.pin and not pin then pin = p.id end
			if g and shown < (t.max or 4) and (not t.pin or p.id == pin) then
				shown = shown + 1
				local st = PS.Stats(g, now)
				local thin, mid, deep = 0, 0, 0
				local nT, nM, nD, dT, dM, dD = 0, 0, 0, 0, 0, 0
				for c = 1, g.n * g.n do
					local T = g.h[c] + g.k[c]
					if T > 0 then
						if T < g.film * 0.6 then thin = thin + 1 elseif T > g.film * 1.3 then deep = deep + 1 else mid = mid + 1 end
					end
					local all = T + g.s[c] + g.ab[c]
					if all > g.film * 0.02 then
						local dry = T <= 0 and 1 or 0
						if all < g.film * 0.6 then nT, dT = nT + 1, dT + dry elseif all > g.film * 1.3 then nD, dD = nD + 1, dD + dry else nM, dM = nM + 1, dM + dry end
					end
				end
				local slope = ""
				if p.slope > 0.003 then
					slope = string.format(" | down %.2f up %.2f", PS.Extent(g, p.du, p.dv), PS.Extent(g, -p.du, -p.dv))
				end
				Log(string.format("poolwatch %s %6.1f s | pool %d %s: wet %.2f ml, in %.1f out %.1f dried %.2f soaked %.2f | %d cells, %.1f sq | reach %.2f %.2f %.2f %.2f | layer %.3f / %.3f | speed %.2f / %.2f | liquid %d set %d dry %d | %s | lattice %d x %.2f | depth thin %d normal %d deep %d | dry thin %d/%d normal %d/%d deep %d/%d%s",
					t.name, now - t0, p.id, p.surf.name or "?", p.vol, p.inTot, p.outTot, p.driedTot, p.soakTot, g.wetN, g.wetN * g.a * g.a,
					PS.Extent(g, 1, 0), PS.Extent(g, -1, 0), PS.Extent(g, 0, 1), PS.Extent(g, 0, -1), st.hMean, st.hMax, st.uMean, st.uMax,
					st.liquid, st.set, st.dry + st.soaked, PS.Active(g) and "moving" or "at rest", g.n, g.a, thin, mid, deep, dT, nT, dM, nM, dD, nD, slope))
			end
		end
		if shown == 0 then Log(string.format("poolwatch %s %6.1f s | no liquid pool (%d pools)", t.name, now - t0, #ABL.Pools.list)) end
	end)
end

-- Shape lab: the same inflow on the same floor under a list of contact-line variants; the
-- fields go to abl_test/poollab.txt (tools/harness/poollab.py draws them).
function H.poollab()
	local PS, PCV, ML = ABL.PoolSim, ABL.PoolCanvas, ABL.Config.ML_PER_CU
	local Noise = PS.Noise
	local keepPin = PS.Pin
	local function N2(U, V) return 0.6 * Noise(U * 0.62, V * 0.62) + 0.4 * Noise(U * 0.17 + 31.7, V * 0.17 - 12.3) end
	local function N3(U, V) return 0.45 * Noise(U * 0.62, V * 0.62) + 0.3 * Noise(U * 0.17 + 31.7, V * 0.17 - 12.3) + 0.25 * Noise(U * 1.5 + 5.1, V * 1.5 + 9.7) end
	local PINS = {
		sq = function(U, V) local n = N2(U, V) return n * n end,
		lin = function(U, V) return math.Clamp((N2(U, V) - 0.3) / 0.5, 0, 1) end,
		raw = N2,
		sq3 = function(U, V) local n = N3(U, V) return n * n end,
		lin3 = function(U, V) return math.Clamp((N3(U, V) - 0.3) / 0.5, 0, 1) end,
	}
	local out = {}
	local film = 0.085
	local function Run(name, pin, amp, curve, o)
		o = o or {}
		PS.Pin = PINS[pin]
		local U0, V0 = o.U0 or 1000, o.V0 or 2000
		local g = PS.New(0.4, 14, -7, -7)
		g.film, g.res, g.memK, g.amp, g.tens = film, film * 0.275, 0.35, amp, curve
		local function Ground() PS.SetGround(g, U0, V0, o.tilt or 0, 0) end
		Ground()
		local rate, secs = o.rate or 2, o.secs or 20
		local feedSteps = secs / PS.STEP
		local t0 = SysTime()
		local steps = 0
		for k = 1, feedSteps + 1600 do
			if k <= feedSteps then PS.Deposit(g, 0, 0, rate * PS.STEP / ML, k * PS.STEP) end
			if not PS.Step(g, PS.STEP) and k > feedSteps then break end
			steps = k
			if k % 2 == 0 and PS.Fit(g, 40) then Ground() end
		end
		local nx, ny, pa = PCV.DevPatch(g, 0.65)
		local hs, cnt = 0, 0
		for c = 1, g.n * g.n do
			if g.h[c] > 0 then hs, cnt = hs + g.h[c], cnt + 1 end
		end
		out[#out + 1] = string.format("V %s %d %d %.2f", name, nx, ny, g.a)
		for row = 0, ny - 1 do
			local line = {}
			for col = 1, nx do line[col] = pa[row * nx + col] end
			out[#out + 1] = table.concat(line, " ")
		end
		Log(string.format("poollab %-22s %4d steps %5.1f ms | lattice %d x %.2f, %d cells, layer %.3f (film %.3f)%s", name, steps, (SysTime() - t0) * 1000, g.n, g.a, cnt, cnt > 0 and hs / cnt or 0, film, PS.Active(g) and " still moving" or ""))
	end
	PINS.now = keepPin
	for _, amp in ipairs({ 0.2, 0.4, 0.9, 1.2, 1.6 }) do
		for _, tens in ipairs({ 0.2, 0.35, 0.5 }) do
			Run(string.format("now_%.1f_t%.2f", amp, tens), "now", amp, tens)
		end
	end
	for _, v in ipairs({ { 1.2, 0.35 }, { 0.4, 0.35 } }) do
		Run(string.format("now_%.1f_t%.2f@B", v[1], v[2]), "now", v[1], v[2], { U0 = 1337.3, V0 = 421.7 })
		Run(string.format("now_%.1f_t%.2f@C", v[1], v[2]), "now", v[1], v[2], { U0 = -512.9, V0 = 88.1 })
		Run(string.format("now_%.1f_t%.2f@big", v[1], v[2]), "now", v[1], v[2], { rate = 6, secs = 25 })
		Run(string.format("now_%.1f_t%.2f@huge", v[1], v[2]), "now", v[1], v[2], { rate = 15, secs = 30 })
		Run(string.format("now_%.1f_t%.2f@4deg", v[1], v[2]), "now", v[1], v[2], { tilt = 0.07, rate = 2.5, secs = 10 })
		Run(string.format("now_%.1f_t%.2f@1deg", v[1], v[2]), "now", v[1], v[2], { tilt = 0.0175, rate = 2.5, secs = 12 })
	end
	PS.Pin = keepPin
	file.Write("abl_test/poollab.txt", table.concat(out, "\n") .. "\n")
	Log("poollab done (" .. #out .. " lines)")
end

-- The liquid under five frame clocks: the same inflow (4 ml/s for 12 s at one point of a rough
-- floor) with frames 1/30, 1/60, 1/120, 1/165 and 1/240 s long, the blood arriving frame by
-- frame and the pool taking its turns as a pool near the viewer does (cl_pools.lua, P.Think:
-- one as soon as 0.049 s have passed since the last). Area and volume at every second: what
-- differs between the columns is what the length of a frame alone does. No drawing, no game
-- clock: the machine's own frame rate does not come into it.
function H.poolclock()
	local PS, ML = ABL.PoolSim, ABL.Config.ML_PER_CU
	local film = 0.085
	local rates = { 30, 60, 120, 165, 240 }
	local rows = {}
	for ri, fps in ipairs(rates) do
		local g = PS.New(0.4, 14, -7, -7)
		g.film, g.res, g.memK, g.amp = film, film * 0.25, 0.35, 1.2
		local function Ground() PS.SetGround(g, 1000, 2000, 0, 0) end
		Ground()
		local dt = 1 / fps
		local last, nextT, mark = 0, 0, 1
		local row = {}
		for frame = 1, 20 * fps do
			local t = frame * dt
			if t <= 12 + 1e-9 then PS.Pour(g, 0, 0, 4 * dt / ML, t) end
			if t >= nextT then
				PS.Advance(g, t - last, 4, t)
				last, nextT = t, t + PS.STEP * 0.98
				if PS.Fit(g, 40) then Ground() end
			end
			if t >= mark - 1e-9 then
				row[mark] = { g.wetN * g.a * g.a, PS.Volume(g) * ML }
				mark = mark + 1
			end
		end
		rows[ri] = row
	end
	local worstA, worstV, atA, atV = 0, 0, 0, 0
	for s = 1, 20 do
		local a, v = {}, {}
		local a0, v0 = rows[2][s][1], rows[2][s][2]
		for ri = 1, #rates do
			a[ri], v[ri] = string.format("%.1f", rows[ri][s][1]), string.format("%.2f", rows[ri][s][2])
			if ri >= 2 then
				local da, dv = math.abs(rows[ri][s][1] - a0) / a0, math.abs(rows[ri][s][2] - v0) / v0
				if da > worstA then worstA, atA = da, s end
				if dv > worstV then worstV, atV = dv, s end
			end
		end
		Log(string.format("poolclock %2d s | area at 30 / 60 / 120 / 165 / 240 frames a second: %s sq | volume: %s ml", s, table.concat(a, " / "), table.concat(v, " / ")))
	end
	Log(string.format("poolclock | against 60 a second, 120 to 240: area differs by %.2f %% at most (at %d s), volume by %.3f %% (at %d s)", worstA * 100, atA, worstV * 100, atV))
end

-- The pools' log of what changes on screen (cl_pools.lua, P.Trace): t.on starts it, t.dump
-- writes its sum and the events that matter.
function H.pooltrace(t)
	local P = ABL.Pools
	if t.on then P.trace = {} return end
	local tr = P.trace
	if not tr then Log("pooltrace " .. tostring(t.dump) .. ": not collected") return end
	P.trace = nil
	local paints, gaps, gapMax, gapSum, dMax, dSum, grew, ms, msMax = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local lights, lms, lmsMax, slow = 0, 0, 0, 0
	-- (what the paints of one frame cost together: the worst frame)
	local fNow, fMs, fMax = -1, 0, 0
	-- What the pools cost a frame between t.t0 and t.t1 (game time since the trace began), the
	-- liquid's steps and the paints together: mean over all frames of that stretch, the frame
	-- that 99 of 100 stay under, the worst.
	if t.t0 and tr[1] then
		local T0 = tr[1].t
		local per, order, fa, fb, sims, pts = {}, {}, nil, nil, 0, 0
		for _, e in ipairs(tr) do
			local rel = e.t - T0
			if rel >= t.t0 and rel <= t.t1 and (e.kind == "paint" or e.kind == "light" or e.kind == "sim") then
				if not per[e.f] then
					per[e.f] = 0
					order[#order + 1] = e.f
				end
				per[e.f] = per[e.f] + (e.ms or 0)
				if e.kind == "sim" then sims = sims + (e.ms or 0) else pts = pts + (e.ms or 0) end
				fa, fb = fa or e.f, e.f
			end
		end
		if fa and fb > fa then
			local list = {}
			for q = 1, #order do list[q] = per[order[q]] end
			-- (frames in which the pools did nothing cost nothing)
			for _ = #order + 1, fb - fa + 1 do list[#list + 1] = 0 end
			table.sort(list)
			local nfr = #list
			Log(string.format("pooltrace %s | cost between %.0f and %.0f s: %d frames, steps %.3f ms a frame, paints %.3f, together %.3f on average, %.2f in 99 of 100 frames, %.2f in the worst",
				t.dump, t.t0, t.t1, nfr, sims / nfr, pts / nfr, (sims + pts) / nfr, list[math.max(1, math.floor(nfr * 0.99))], list[nfr]))
		end
	end
	for _, e in ipairs(tr) do
		if e.kind == "paint" or e.kind == "light" then
			if e.f ~= fNow then fNow, fMs = e.f, 0 end
			fMs = fMs + (e.ms or 0)
			if fMs > fMax then fMax = fMs end
			if (e.ms or 0) > 1 then
				slow = slow + 1
				if slow <= 6 then Log(string.format("pooltrace %s | frame %d: a %s paint of pool %d took %.2f ms (%s cells, slot %s)", t.dump, e.f, e.kind == "light" and "light" or "full", e.id, e.ms, tostring(e.cells), tostring(e.slot))) end
			end
		end
		if e.kind == "light" then
			lights, lms = lights + 1, lms + (e.ms or 0)
			if (e.ms or 0) > lmsMax then lmsMax = e.ms end
		elseif e.kind == "paint" then
			paints = paints + 1
			ms = ms + (e.ms or 0)
			if (e.ms or 0) > msMax then msMax = e.ms end
			if e.gap and e.gap > 0 then
				gaps, gapSum = gaps + 1, gapSum + e.gap
				if e.gap > gapMax then gapMax = e.gap end
			end
			if e.dcells and e.dcells > 0 and not e.first then
				grew, dSum = grew + 1, dSum + e.dcells
				if e.dcells > dMax then dMax = e.dcells end
			end
			if e.first then Log(string.format("pooltrace %s | pool %d first painted %d frames after it was made (%d cells at once)", t.dump, e.id, e.first, e.cells or 0)) end
			if e.coarser then Log(string.format("pooltrace %s | frame %d: pool %d on coarser cells (%.2f)", t.dump, e.f, e.id, e.cell or 0)) end
			if e.newSlot then Log(string.format("pooltrace %s | frame %d: pool %d moved to a canvas slot of %d", t.dump, e.f, e.id, e.slot)) end
			if e.sinceMerge then Log(string.format("pooltrace %s | pool %d repainted %d frames after it took another pool in", t.dump, e.id, e.sinceMerge)) end
		elseif e.kind == "merge" then
			Log(string.format("pooltrace %s | frame %d (%.2f s): pool %d took pool %d in (it was on screen: %s)", t.dump, e.f, e.t, e.id, e.small, tostring(e.smallDrawn)))
		elseif e.kind == "create" then
			Log(string.format("pooltrace %s | frame %d (%.2f s): pool %d made with %.2f ml", t.dump, e.f, e.t, e.id, e.vol or 0))
		end
	end
	local f0, f1 = tr[1] and tr[1].f or 0, tr[#tr] and tr[#tr].f or 0
	Log(string.format("pooltrace %s | %d events over %d frames | %d repaints (%.2f ms each, %.2f at most), %.1f frames between two of a pool on average, %d at most | repaints that showed new cells: %d, %.1f cells each, %d at most",
		t.dump, #tr, f1 - f0, paints, paints > 0 and ms / paints or 0, msMax, gaps > 0 and gapSum / gaps or 0, gapMax, grew, grew > 0 and dSum / grew or 0, dMax))
	Log(string.format("pooltrace %s | %d light paints (%.2f ms each, %.2f at most) | all paints: %.3f ms a frame over the %d frames, %.2f ms in the worst frame, %d paints over 1 ms",
		t.dump, lights, lights > 0 and lms / lights or 0, lmsMax, (ms + lms) / math.max(f1 - f0, 1), f1 - f0, fMax, slow))
end

-- Force every pool to a wetness (drying stages without waiting).
function H.pooldry(t)
	for _, p in ipairs(ABL.Pools.list) do ABL.Pools.DevDry(p, t.wet, t.dryT) end
end

-- Decal orientation check: four elongated stains that must point along the drawn arrows.
function H.decaltest(t)
	local arrows = {}
	local function Row(origin, n, dirs)
		for i, d in ipairs(dirs) do
			local p = origin + d.o
			ABL.Stains.Place("elong", 1, p.x, p.y, p.z, n.x, n.y, n.z, d.d.x, d.d.y, d.d.z, 14, 14, ABL.Config.Colors.decal, 255, nil, 30)
			arrows[#arrows + 1] = { p + n * 0.5, p + n * 0.5 + d.d * 9 }
		end
	end
	local f = t.floor + Vector(0, 0, 0.1)
	Row(f, Vector(0, 0, 1), {
		{ o = Vector(-22, 0, 0), d = Vector(1, 0, 0) }, { o = Vector(0, 22, 0), d = Vector(0, 1, 0) },
		{ o = Vector(22, 0, 0), d = Vector(-1, 0, 0) }, { o = Vector(0, -22, 0), d = Vector(0, -1, 0) },
	})
	local wn = t.wallNormal
	local side = wn:Cross(Vector(0, 0, 1))
	Row(t.wall, wn, {
		{ o = side * -24, d = Vector(0, 0, -1) }, { o = side * 0 + Vector(0, 0, 14), d = side },
		{ o = side * 24, d = Vector(0, 0, 1) }, { o = Vector(0, 0, -16), d = -side },
	})
	drawDecalArrows = arrows
	timer.Simple(25, function() drawDecalArrows = nil end)
	Log("decaltest placed")
end

-- Skinning sanity check: skinned mesh vertices must hug the entity's hitboxes.
function H.meshcheck(t)
	if t.ent == -1 then drawPoints = nil return end
	local ent = Entity(t.ent)
	if not IsValid(ent) then Log("meshcheck: invalid ent") return end
	local body = ABL.ZC.GetBody(ent)
	local m = ABL.BodyMesh.Get(body)
	if not m then
		-- build synchronously for the test
		for _ = 1, 400 do ABL.BodyMesh.RunJobs(50) m = ABL.BodyMesh.Get(body) if m then break end end
	end
	if not m then Log("meshcheck: mesh not ready") return end
	local pose = ABL.BodyMesh.NewPose()
	pose:Bind(body, m)
	pose:Begin(-1234)
	local hbs = ABL.BodyMesh.Hitboxes(body)
	local inside, total, sumD = 0, 0, 0
	local pts = {}
	for id = 1, m.nv, math.max(1, math.floor(m.nv / 1500)) do
		local x, y, z = pose:Vertex(id)
		total = total + 1
		pts[#pts + 1] = Vector(x, y, z)
		-- distance to the nearest hitbox (0 when inside)
		local best = math.huge
		for _, h in ipairs(hbs) do
			local inv = pose:BoneInv(h.bone)
			if inv then
				local lx, ly, lz = ABL.BodyMesh.Xform(inv, x, y, z)
				local dx = math.max(h.x0 - lx, 0, lx - h.x1)
				local dy = math.max(h.y0 - ly, 0, ly - h.y1)
				local dz = math.max(h.z0 - lz, 0, lz - h.z1)
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				if d < best then best = d end
			end
		end
		if best < 2.5 then inside = inside + 1 end
		sumD = sumD + best
	end
	drawPoints = pts
	-- sample structure for the log
	local meshes, binds = util.GetModelMeshes(body:GetModel(), 0, 0)
	local v1 = meshes and meshes[1] and meshes[1].triangles and meshes[1].triangles[1]
	local wkeys = ""
	if v1 and v1.weights and v1.weights[1] then for k, v in pairs(v1.weights[1]) do wkeys = wkeys .. k .. "=" .. tostring(v) .. " " end end
	Log(string.format("meshcheck %s: %d verts %d tris, sampled %d, near-hitbox %.1f%%, mean dist %.2f, bindInverted %s, binds[0] %s, weightKeys {%s}",
		body:GetModel(), m.nv, m.nt, total, inside / total * 100, sumD / total, tostring(m.bindInverted), tostring(binds and binds[0] ~= nil), wkeys))
end

------------------------------------------------------------------------------------------
-- Engine probe for render-target painting (pool canvases): blend ops, alpha writes, gamma on RT
-- round trips, float RTs, $distancealpha and per-draw material parameters. Results are logged
-- to abl_test/rtprobe.txt.
------------------------------------------------------------------------------------------
local probePending = false
function H.rtprobe() probePending = true end

local function RunProbe()
	local out = {}
	local function P(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
	for _, cv in ipairs({ "mat_queue_mode", "gmod_mcore_test", "mat_hdr_level", "mat_dxlevel", "mat_picmip" }) do
		local c = GetConVar(cv)
		P("cvar %s = %s", cv, c and c:GetString() or "?")
	end
	local flags = bit.bor(4, 8, 256, 512)
	local rtA = GetRenderTargetEx("abl_probe_a", 256, 256, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
	local rtB = GetRenderTargetEx("abl_probe_b", 256, 256, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
	local rtF = GetRenderTargetEx("abl_probe_f", 256, 256, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA16161616F)
	P("rtA %s %dx%d  rtF %s %dx%d", rtA:GetName(), rtA:Width(), rtA:Height(), rtF:GetName(), rtF:Width(), rtF:Height())

	local function Mat(name, kv)
		kv["$vertexcolor"] = 1 kv["$vertexalpha"] = 1 kv["$translucent"] = 1 kv["$ignorez"] = 1
		return CreateMaterial(name, "UnlitGeneric", kv)
	end
	local white = Mat("abl_probe_white", { ["$basetexture"] = "vgui/white" })
	local pv = Vector()
	local function Quad(mat, x, y, w, h, r, g, b, a, a2, u0, v0, u1, v1)
		render.SetMaterial(mat)
		mesh.Begin(MATERIAL_QUADS, 1)
		pv:SetUnpacked(x, y, 0) mesh.Position(pv) mesh.TexCoord(0, u0 or 0, v0 or 0) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
		pv:SetUnpacked(x + w, y, 0) mesh.Position(pv) mesh.TexCoord(0, u1 or 1, v0 or 0) mesh.Color(r, g, b, a2 or a) mesh.AdvanceVertex()
		pv:SetUnpacked(x + w, y + h, 0) mesh.Position(pv) mesh.TexCoord(0, u1 or 1, v1 or 1) mesh.Color(r, g, b, a2 or a) mesh.AdvanceVertex()
		pv:SetUnpacked(x, y + h, 0) mesh.Position(pv) mesh.TexCoord(0, u0 or 0, v1 or 1) mesh.Color(r, g, b, a) mesh.AdvanceVertex()
		mesh.End()
	end
	local function Blend(sc, dc, op, sa, da, opa) render.OverrideBlend(true, sc, dc, op, sa or sc, da or dc, opa or op) end
	local function Begin(rt)
		render.PushRenderTarget(rt)
		render.OverrideAlphaWriteEnable(true, true)
		cam.Start2D()
		cam.IgnoreZ(true)
	end
	local function Finish()
		cam.IgnoreZ(false)
		cam.End2D()
		render.OverrideBlend(false)
		render.OverrideColorWriteEnable(false, true)
		render.OverrideAlphaWriteEnable(false, true)
		render.SetScissorRect(0, 0, 0, 0, false)
		render.PopRenderTarget()
	end
	local function ReadRow(rt, label, pts, y)
		render.PushRenderTarget(rt)
		render.CapturePixels()
		local s = {}
		for _, x in ipairs(pts) do
			local r, g, b, a = render.ReadPixel(x, y)
			s[#s + 1] = string.format("[%d]%d,%d,%d,%s", x, r or -1, g or -1, b or -1, tostring(a))
		end
		render.PopRenderTarget()
		P("%s: %s", label, table.concat(s, " "))
	end

	-- A: blend-op cells in row 0..15 (x = 16 * cell + 8 to read)
	Begin(rtA)
	render.Clear(0, 0, 0, 0)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(white, 0, 0, 16, 16, 64, 128, 192, 100)                -- c0: plain write
	Quad(white, 16, 0, 16, 16, 100, 100, 100, 100)              -- c1: 100 + 100
	Quad(white, 32, 0, 16, 16, 200, 200, 200, 200)              -- c2: 200 - 50
	Quad(white, 48, 0, 16, 16, 60, 60, 60, 60)                  -- c3: 60 * 2
	Quad(white, 64, 0, 16, 16, 200, 200, 200, 200)              -- c4: 200 * 0.5
	Quad(white, 80, 0, 16, 16, 90, 90, 90, 90)                  -- c5: max(90, 150)
	Quad(white, 96, 0, 16, 16, 30, 60, 90, 120)                 -- c6: alpha-only write 222
	Quad(white, 112, 0, 16, 16, 128, 128, 128, 128)             -- c7: 50% gray, a 128 (gamma check)
	Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	Quad(white, 16, 0, 16, 16, 100, 100, 100, 100)
	Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_REVERSE_SUBTRACT)
	Quad(white, 32, 0, 16, 16, 50, 50, 50, 50)
	Blend(BLEND_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD, BLEND_DST_ALPHA, BLEND_ONE, BLENDFUNC_ADD)
	Quad(white, 48, 0, 16, 16, 255, 255, 255, 255)
	Blend(BLEND_DST_COLOR, BLEND_ZERO, BLENDFUNC_ADD, BLEND_DST_ALPHA, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(white, 64, 0, 16, 16, 128, 128, 128, 128)
	Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_MAX)
	Quad(white, 80, 0, 16, 16, 150, 40, 150, 40)
	render.OverrideColorWriteEnable(true, false)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(white, 96, 0, 16, 16, 255, 255, 255, 222)
	render.OverrideColorWriteEnable(false, true)
	-- per-draw material parameter change within one frame
	local pm = Mat("abl_probe_param", { ["$basetexture"] = "vgui/white" })
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	pm:SetVector("$color", Vector(1, 0, 0)) Quad(pm, 0, 32, 16, 16, 255, 255, 255, 255)
	pm:SetVector("$color", Vector(0, 1, 0)) Quad(pm, 16, 32, 16, 16, 255, 255, 255, 255)
	pm:SetVector("$color", Vector(0, 0, 1)) Quad(pm, 32, 32, 16, 16, 255, 255, 255, 255)
	-- scissor: a big quad clipped to x 64..96
	render.SetScissorRect(64, 32, 96, 48, true)
	Quad(white, 48, 32, 64, 16, 255, 255, 255, 255)
	render.SetScissorRect(0, 0, 0, 0, false)
	-- horizontal alpha gradient 0 -> 255 over x 0..256 (rows 64..96), rgb white
	Quad(white, 0, 64, 256, 32, 255, 255, 255, 0, 255)
	-- horizontal rgb gradient via vertex colours is not possible per corner here; use alpha only
	Finish()
	ReadRow(rtA, "A ops (c0 w64/128/192/100, c1 200, c2 150, c3 120, c4 100, c5 150/90/150/90, c6 a222, c7 128)", { 8, 24, 40, 56, 72, 88, 104, 120 }, 8)
	ReadRow(rtA, "A param r,g,b / scissor 56 (no) 72 (yes) 104 (no)", { 8, 24, 40, 56, 72, 104 }, 40)
	ReadRow(rtA, "A gradient alpha", { 0, 32, 64, 96, 115, 128, 141, 160, 192, 224, 255 }, 80)

	-- B: sample A through a material (RT -> texture -> RT round trip), then $distancealpha variants
	local copyA = Mat("abl_probe_copy", { ["$basetexture"] = rtA:GetName() })
	local da1 = Mat("abl_probe_da1", { ["$basetexture"] = rtA:GetName(), ["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = 0.6, ["$edgesoftnessend"] = 0.4 })
	local da2 = Mat("abl_probe_da2", { ["$basetexture"] = rtA:GetName(), ["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = 0.52, ["$edgesoftnessend"] = 0.48 })
	local da3 = Mat("abl_probe_da3", { ["$basetexture"] = rtA:GetName(), ["$distancealpha"] = 1 })
	local da4 = Mat("abl_probe_da4", { ["$basetexture"] = rtA:GetName(), ["$distancealpha"] = 1, ["$softedges"] = 1, ["$edgesoftnessstart"] = 0.6, ["$edgesoftnessend"] = 0.4, ["$detail"] = "advancedblood/sprites/sheen", ["$detailscale"] = 1, ["$detailblendmode"] = 0 })
	Begin(rtB)
	render.Clear(0, 0, 0, 0)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(copyA, 0, 0, 256, 256, 255, 255, 255, 255)             -- full copy of A
	Quad(da1, 0, 100, 256, 16, 255, 255, 255, 255, nil, 0, 64 / 256, 1, 96 / 256)
	Quad(da2, 0, 120, 256, 16, 255, 255, 255, 255, nil, 0, 64 / 256, 1, 96 / 256)
	Quad(da3, 0, 140, 256, 16, 255, 255, 255, 255, nil, 0, 64 / 256, 1, 96 / 256)
	Quad(da1, 0, 160, 256, 16, 128, 64, 32, 128, nil, 0, 64 / 256, 1, 96 / 256)   -- vertex colour/alpha with DA
	Quad(da4, 0, 180, 256, 16, 255, 255, 255, 255, nil, 0, 64 / 256, 1, 96 / 256) -- DA + detail
	Finish()
	ReadRow(rtB, "B copy ops", { 8, 24, 40, 56, 72, 88, 104, 120 }, 8)
	ReadRow(rtB, "B copy gradient", { 0, 32, 64, 96, 115, 128, 141, 160, 192, 224, 255 }, 80)
	ReadRow(rtB, "B da1 0.4-0.6", { 0, 64, 96, 102, 108, 115, 122, 128, 134, 141, 148, 154, 160, 192, 255 }, 108)
	ReadRow(rtB, "B da2 0.48-0.52", { 0, 96, 115, 120, 123, 126, 128, 130, 133, 136, 141, 160, 255 }, 128)
	ReadRow(rtB, "B da3 hard", { 0, 96, 115, 120, 123, 126, 128, 130, 133, 136, 141, 160, 255 }, 148)
	ReadRow(rtB, "B da1 vc 128,64,32,128", { 0, 96, 115, 128, 141, 160, 255 }, 168)
	ReadRow(rtB, "B da4 +detail", { 0, 96, 115, 128, 141, 160, 255 }, 188)

	-- F: float RT, 0.8 + 0.8 = 1.6 (unclamped?), then * 0.5, copy into B at row 220
	Begin(rtF)
	render.Clear(0, 0, 0, 0)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(white, 0, 0, 64, 64, 204, 204, 204, 204)
	Blend(BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	Quad(white, 0, 0, 64, 64, 204, 204, 204, 204)
	Blend(BLEND_ZERO, BLEND_SRC_COLOR, BLENDFUNC_ADD, BLEND_ZERO, BLEND_SRC_ALPHA, BLENDFUNC_ADD)
	Quad(white, 0, 0, 64, 64, 128, 128, 128, 128)
	-- a gradient for precision: alpha 0..255 over 256 px, then scaled x 0.25 down and back up
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(white, 0, 128, 256, 32, 255, 255, 255, 0, 255)
	Finish()
	ReadRow(rtF, "F direct read", { 8, 32 }, 8)
	local copyF = Mat("abl_probe_copyf", { ["$basetexture"] = rtF:GetName() })
	Begin(rtB)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(copyF, 0, 220, 64, 16, 255, 255, 255, 255, nil, 0, 0, 0.25, 0.25)
	Finish()
	ReadRow(rtB, "B float copy (expect ~204 if unclamped, ~128 if clamped)", { 8, 32 }, 228)

	-- C: colour pipeline of the shipped textures and the filter pass.
	--   row 8:  the probe texture (quadrants 64 / 128 / 192 grey and 200,100,50) written as is
	--   row 40: grey 128 background, the probe texture multiplied in with the filter blend
	--   row 72: grey 128 background, filter blend set, then a static mesh built, then the draw
	--   row 104: grey 128 background, the filter blend with a static mesh (IMesh:Draw)
	local probe = Mat("abl_probe_tex", { ["$basetexture"] = "advancedblood/debug/probe" })
	local function FilterOn() Blend(BLEND_DST_COLOR, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD) end
	local rtC = GetRenderTargetEx("abl_probe_c", 256, 256, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
	local sm = Mesh()
	mesh.Begin(sm, MATERIAL_QUADS, 1)
	for k = 0, 3 do
		local x, y = (k == 1 or k == 2) and 128 or 0, k >= 2 and 112 or 96
		pv:SetUnpacked(x, y, 0) mesh.Position(pv) mesh.TexCoord(0, (k == 1 or k == 2) and 1 or 0, k >= 2 and 1 or 0) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
	end
	mesh.End()
	Begin(rtC)
	render.Clear(0, 0, 0, 0)
	Blend(BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	Quad(probe, 0, 0, 128, 16, 255, 255, 255, 255)
	Quad(white, 0, 32, 256, 96, 128, 128, 128, 255)
	FilterOn()
	Quad(probe, 0, 32, 128, 16, 255, 255, 255, 255)
	FilterOn()
	local tmp = Mesh()
	mesh.Begin(tmp, MATERIAL_QUADS, 1)
	for _ = 1, 4 do pv:SetUnpacked(0, 0, 0) mesh.Position(pv) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex() end
	mesh.End()
	tmp:Destroy()
	Quad(probe, 0, 64, 128, 16, 255, 255, 255, 255)
	render.SetMaterial(probe)
	FilterOn()
	sm:Draw()
	Finish()
	sm:Destroy()
	ReadRow(rtC, "C probe texture 64/128/192/200,100,50", { 16, 48, 80, 112 }, 8)
	ReadRow(rtC, "C filter over 128", { 16, 48, 80, 112, 200 }, 40)
	ReadRow(rtC, "C filter after mesh build", { 16, 48, 80, 112 }, 72)
	ReadRow(rtC, "C filter IMesh", { 16, 48, 80, 112 }, 104)

	file.Write("abl_test/rtprobe.txt", table.concat(out, "\n") .. "\n")
	Log("rtprobe done (" .. #out .. " lines)")
end

hook.Add("PostRender", "ABL_SelfTestProbe", function()
	if not probePending then return end
	probePending = false
	local ok, err = pcall(RunProbe)
	if not ok then
		Log("rtprobe error " .. tostring(err))
		render.OverrideBlend(false)
		render.OverrideAlphaWriteEnable(false, true)
	end
end)

hook.Add("PostDrawTranslucentRenderables", "ABL_SelfTestDraw", function(d, s)
	if d or s then return end
	if drawPoints then
		render.SetColorMaterial()
		for _, p in ipairs(drawPoints) do render.DrawBox(p, angle_zero, Vector(-0.15, -0.15, -0.15), Vector(0.15, 0.15, 0.15), Color(0, 255, 0)) end
	end
	if drawDecalArrows then
		for _, a in ipairs(drawDecalArrows) do
			render.DrawLine(a[1], a[2], Color(0, 255, 255), false)
			render.DrawWireframeSphere(a[2], 0.6, 4, 4, Color(0, 255, 255), false)
		end
	end
end)

-- Crash breadcrumbs (harness only): the name of each simulation / drawing phase is written to
-- abl_test/phase.txt before it runs, so after a native crash the file names the phase it died in.
-- Opt-in (garrysmod/data/abl_phases.txt): the writes slow every frame down.
do
	local phases = {
		{ ABL.Emission, "Step", "emission" }, { ABL.Flow, "Step", "flow" }, { ABL.Drops, "Step", "drops" },
		{ ABL.Runoff, "Step", "runoff" }, { ABL.Pools, "Think", "pools.think" }, { ABL.Pools, "Paint", "pools.paint" },
		{ ABL.Ground, "Draw", "ground.draw" }, { ABL.Stains, "Draw", "stains.draw" }, { ABL.Pools, "Draw", "pools.draw" },
		{ ABL.Runoff, "Draw", "runoff.draw" }, { ABL.Flow, "Draw", "flow.draw" }, { ABL.Drops, "Draw", "drops.draw" },
		{ ABL.Render, "Flush", "flush" }, { ABL.Flow, "DrawSource", "flow.source" }, { ABL.WoundFX, "Draw", "wounds.draw" },
	}
	for _, p in ipairs(file.Exists("abl_phases.txt", "DATA") and phases or {}) do
		local t, k, name = p[1], p[2], p[3]
		local orig = t[k]
		if orig and not t["_abl_orig_" .. k] then
			t["_abl_orig_" .. k] = orig
			t[k] = function(...)
				file.Write("abl_test/phase.txt", name .. " " .. FrameNumber())
				return orig(...)
			end
		end
	end
end

-- Wound mark diagnostics (harness only): every projectile hit and what it produced.
do
	local W = ABL.WoundFX
	if W and not W._abl_origOnHit then
		W._abl_origOnHit = W.OnHit
		W.OnHit = function(src, body, ev, r, entry, exitPos, rng)
			local mk, mx = W._abl_origOnHit(src, body, ev, r, entry, exitPos, rng)
			Log(string.format("   hit on %s bone %s (%s) hitgroup %s class %s dmg %s | mesh %s | %s mark %s, exit mark %s, pending %d | impact cos %.2f track %s%s",
				tostring(body), tostring(ev.bone), tostring(IsValid(body) and body:GetBoneName(ev.bone)), tostring(ev.hitgroup), tostring(ev.class), tostring(ev.damage),
				tostring(src.mesh ~= nil), mk and mk.kind or "entry", tostring(mk ~= nil), tostring(mx ~= nil), src.pendingMarks and #src.pendingMarks or 0,
				r.cosI or -1, r.trackLen and string.format("%.1f", r.trackLen) or "?", mk and (mk.skin and " on skin" or " on cloth") or ""))
			return mk, mx
		end
		W._abl_origThink = W.Think
		W.Think = function(src)
			local before = src.pendingMarks and #src.pendingMarks or 0
			W._abl_origThink(src)
			local after = src.pendingMarks and #src.pendingMarks or 0
			if after ~= before then Log(string.format("   pending marks placed on %s: %d -> %d, marks now %d", tostring(src.body), before, after, src.marks and #src.marks or 0)) end
		end
	end
end

-- The wound records of every character: what each holds, which of Z-City's wounds bleed through
-- it, and where the blood went.
function H.wounds(t)
	local WS = ABL.Wounds
	Log("wounds " .. tostring(t.name))
	for _, src in ipairs(ABL.Sources.list) do
		Log(string.format("   %s%s  pulse %.0f  flow %.2f ml/s (asked %.2f, %.0f %% external)  loss %s  | records %d  Z-City wounds %d  marks %d",
			tostring(src.key), (src.body and src.body ~= src.key) and (" as " .. tostring(src.body)) or (src.body and "" or " (no body)"), src.pulse or 0,
			src.flowRate or 0, src.flowNominal or 0, (src.flowShare or 1) * 100, src.lossRate and string.format("%.2f ml/s", src.lossRate) or "not measured",
			src.wrecs and #src.wrecs or 0, #src.woundList, src.marks and #src.marks or 0))
		for _, r in ipairs(src.wrecs or {}) do
			for _, l in ipairs(WS.Describe(r)) do Log("      " .. l) end
			Log(string.format("      at %s: entry %s  exit %s", r.boneName, r.lentry and string.format("%.1f %.1f %.1f", r.lentry.x, r.lentry.y, r.lentry.z) or "?", r.lexit and string.format("%.1f %.1f %.1f", r.lexit.x, r.lexit.y, r.lexit.z) or "-"))
			for _, wd in ipairs(r.wds) do
				Log(string.format("         bleeds through: %s as %s  sev %.1f  profile %s  flow %.2f ml/s%s%s", wd.id, tostring(wd.role), wd.sev, wd.profile and wd.profile.name or "?", wd.flow or 0,
					wd.mark and (" from the " .. wd.mark.kind .. " mark") or " (no mark)", wd.transect and " severed" or ""))
			end
		end
		for _, wd in ipairs(src.woundList) do
			if not wd.rec then Log(string.format("      unlinked Z-City wound %s (%.1f %.1f %.1f) sev %.1f flow %.2f age %.1f s", wd.id, wd.lx, wd.ly, wd.lz, wd.sev, wd.flow or 0, CurTime() - wd.born)) end
		end
		-- (where each mark is on the body's own surface: the same wound made a second time from
		-- what the server kept of it lies on the same triangle)
		for _, mk in ipairs(src.marks or {}) do
			if mk.kind ~= "soak" then
				local r = mk.rec
				Log(string.format("      mark: %s on %s, triangle %d (%.3f %.3f), %s, %.0f s old, wet %.2f clot %.2f dry %.2f bruise %.2f%s", mk.kind, tostring(IsValid(src.body) and src.body:GetBoneName(mk.bone) or mk.bone),
					mk.tri or -1, mk.u or 0, mk.v or 0, mk.skin and "skin" or "cloth", CurTime() - mk.born, r and r.wet or 0, r and r.clot or 0, r and r.dry or 0, r and r.bruise or 0,
					(r and r.replayed) and " | told of after the fact" or ""))
			end
		end
		for _, h in ipairs(src.pendingHits) do
			Log(string.format("      hit still waiting for its Z-City wound: %s (%.1f %.1f %.1f) as %s, %.1f s", tostring(h.boneName), h.lx, h.ly, h.lz, tostring(h.role), CurTime() - h.t))
		end
		for _, l in ipairs(WS.LedgerLines(src)) do Log("      " .. l) end
	end
end

-- resync: wounds this client was not there for (cl_events.lua, server/sv_woundstore.lua). ask:
-- the number of an entity to ask the server about now; stats: what has been asked and told.
function H.resync(t)
	local WY = ABL.WoundSync
	if not WY then Log("resync: no wound sync on this client") return end
	if t.ask then WY.Want(Entity(t.ask), true) end
	if t.stats then
		Log(string.format("resync %s: asked about %d bodies so far, told of %d wound(s), %d of them this client had already", tostring(t.stats), WY.stats.asked, WY.stats.told, WY.stats.had))
	end
end

-- hits as the client receives them, and ones that never became usable
ABL.TestLog = function(fmt, ...) Log(string.format(fmt, ...)) end
do
	local E = ABL.Emission
	if E and not E._abl_origOnHit then
		E._abl_origOnHit = E.OnHit
		E.OnHit = function(ev)
			Log(string.format("   received hit on %s (valid %s) bone %s%s", tostring(ev.body), tostring(IsValid(ev.body)), tostring(ev.bone),
				ev.replay and string.format(" | told of after the fact, %d s old", ev.age or 0) or ""))
			return E._abl_origOnHit(ev)
		end
	end
end
