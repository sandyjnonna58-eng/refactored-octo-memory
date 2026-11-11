-- Client half of the hostile scenes (developer tool; see server/sv_hostile.lua). Inert unless the
-- test harness is running (garrysmod/data/abl_selftest.txt). What it measures:
--   leakcheck  everything the blood system keeps alive (sources, channels, nodes, heads, drops,
--              pools, marks, static meshes, stale entity keys, the Lua heap after a full collection)
--              against a baseline taken earlier: what an action leaves behind;
--   scan       every number of the simulated state for NaN, infinity, absurd size and negative
--              volumes, and the surface state of every character for references to a mesh that is
--              no longer the character's;
--   errors     Lua errors raised while the scenes run, the addon's own counted apart.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local FC = ABL.FlowCore

------------------------------------------------------------------------------------------
-- Errors
------------------------------------------------------------------------------------------
local errAll, errOwn = 0, 0
hook.Add("OnLuaError", "ABL_HostileErrors", function(err, _, stack, name)
	errAll = errAll + 1
	local s = tostring(err)
	-- (an error raised inside an engine function names no file: the addon it is charged to, or the
	-- files on its stack, tell whose it is)
	local own = string.find(s, "advancedblood", 1, true) or string.find(s, "neurotrauma", 1, true) or name == "advancedblood"
	if not own and istable(stack) then
		for _, e in ipairs(stack) do
			local f = istable(e) and tostring(e.File or "") or ""
			if string.find(f, "advancedblood", 1, true) or string.find(f, "neurotrauma", 1, true) then own = true break end
		end
	end
	if own then
		errOwn = errOwn + 1
		if errOwn <= 30 then Log("LUA ERROR (addon) " .. s) end
	end
end)

------------------------------------------------------------------------------------------
-- What is alive
------------------------------------------------------------------------------------------
local ORDER = { "sources", "wounds", "records", "chans", "nodes", "heads", "wchans", "regions", "wheads", "beads", "segs", "drops", "parts",
	"pools", "rivulets", "marks", "pendMarks", "overlays", "ground", "wetCells", "meshes", "bodyMeshes", "staleKeys", "staleBodies", "heapKB" }

local function CountMeshesOf(ch)
	local n = 0
	local b = ch.bake
	if b then
		for _, r in ipairs(b.runs) do
			if r.mesh then n = n + 1 end
			if r.halo then n = n + 1 end
			if r.wet then n = n + 1 end
			if r.body then n = n + 1 end
			if r.sbody then n = n + 1 end
		end
	end
	return n
end

local function Snapshot()
	local S = ABL.Sources
	local s = {}
	for _, k in ipairs(ORDER) do s[k] = 0 end
	s.sources = #S.list
	s.nodes, s.heads = FC.nodes, FC.heads
	s.records = #ABL.Wounds.list
	for _, src in ipairs(S.list) do
		s.wounds = s.wounds + #src.woundList
		s.beads = s.beads + #src.blobs
		s.segs = s.segs + (src.segCount or 0)
		s.marks = s.marks + (src.marks and #src.marks or 0)
		s.pendMarks = s.pendMarks + (src.pendingMarks and #src.pendingMarks or 0)
		for _, mk in ipairs(src.marks or {}) do if mk.mesh then s.meshes = s.meshes + 1 end end
		for _, m in pairs(src.segMesh or {}) do if m then s.meshes = s.meshes + 1 end end
		for _, m in pairs(src.segGloss or {}) do if m then s.meshes = s.meshes + 1 end end
		if src.fc then
			s.chans = s.chans + #src.fc.chans
			for _, ch in ipairs(src.fc.chans) do s.meshes = s.meshes + CountMeshesOf(ch) end
		end
		if not IsValid(src.key) then s.staleKeys = s.staleKeys + 1 end
	end
	for ent in pairs(S.byBody) do if not IsValid(ent) then s.staleBodies = s.staleBodies + 1 end end
	for ent in pairs(S.byKey) do if not IsValid(ent) then s.staleKeys = s.staleKeys + 1 end end
	s.regions = #ABL.FlowWorld.regions
	s.wheads = ABL.FlowWorld.Count()
	for _, reg in ipairs(ABL.FlowWorld.regions) do
		s.wchans = s.wchans + #reg.fc.chans
		for _, ch in ipairs(reg.fc.chans) do s.meshes = s.meshes + CountMeshesOf(ch) end
	end
	s.drops, s.parts = ABL.Drops.Count(), ABL.Drops.ParticleCount()
	s.pools = ABL.Pools.Count()
	for _, p in ipairs(ABL.Pools.list) do if p.mesh then s.meshes = s.meshes + 1 end end
	s.rivulets = #ABL.Runoff.list
	for _, r in ipairs(ABL.Runoff.list) do
		if r.mesh then s.meshes = s.meshes + 1 end
		if r.gloss then s.meshes = s.meshes + 1 end
	end
	for _, c in ipairs(ABL.Runoff.archive) do
		if c.mesh then s.meshes = s.meshes + 1 end
		if c.gloss then s.meshes = s.meshes + 1 end
	end
	for _, c in ipairs(ABL.Stains.chunks) do
		if c.mesh then s.meshes = s.meshes + 1 end
		if c.gloss then s.meshes = s.meshes + 1 end
	end
	s.overlays = ABL.Stains.Count()
	s.ground = ABL.Ground.Count()
	s.wetCells = ABL.Surface.Count()
	s.bodyMeshes = table.Count(ABL.BodyMesh.cache)
	collectgarbage("collect")
	collectgarbage("collect")
	s.heapKB = math.floor(collectgarbage("count"))
	return s
end

local base = {}
-- t.base: remember this state under t.key; otherwise print the state and what changed since the
-- baseline of t.key.
function H.leakcheck(t)
	local s = Snapshot()
	local key = t.key or "default"
	if t.base then
		base[key] = s
	end
	local b = base[key]
	local parts = {}
	for _, k in ipairs(ORDER) do
		local d = b and not t.base and (s[k] - b[k]) or 0
		parts[#parts + 1] = d ~= 0 and string.format("%s %d (%+d)", k, s[k], d) or string.format("%s %d", k, s[k])
	end
	Log(string.format("leak %s%s | %s | dry world streams that made way so far %d | lua errors: addon %d, all %d", t.name or "?", t.base and " (baseline)" or "", table.concat(parts, "  "),
		ABL.FlowWorld.evicted or 0, errOwn, errAll))
end

------------------------------------------------------------------------------------------
-- Scan: NaN, infinity, absurd size, negative volumes, foreign meshes
------------------------------------------------------------------------------------------
local found, nBad, nNeg, nForeign

local function Note(kind, what)
	if kind == "bad" then nBad = nBad + 1 elseif kind == "neg" then nNeg = nNeg + 1 else nForeign = nForeign + 1 end
	if #found < 14 then found[#found + 1] = kind .. ": " .. what end
end

-- lim: what size is absurd for this number (nil: 1e7)
local function Num(x, what, lim)
	if x == nil then return end
	if type(x) ~= "number" then Note("bad", what .. " is a " .. type(x)) return end
	if x ~= x then Note("bad", what .. " is NaN") return end
	lim = lim or 1e7
	if x > lim or x < -lim then Note("bad", string.format("%s = %g", what, x)) end
end
local function Vol(x, what)
	Num(x, what, 1e5)
	if type(x) == "number" and x < -1e-6 then Note("neg", string.format("%s = %g", what, x)) end
end

local NODE_VOL = { "V", "F", "S", "D", "Cv", "hold" }
local NODE_NUM = { "age", "T", "sh", "mu", "h", "w", "wmax", "L", "Lc", "us", "wet" }

local function ScanChannel(ch, tag, mesh)
	local n = ch.n
	for _, k in ipairs(NODE_VOL) do
		local a = ch[k]
		for i = 1, n do Vol(a[i], tag .. "." .. k .. "[" .. i .. "]") end
	end
	for _, k in ipairs(NODE_NUM) do
		local a = ch[k]
		for i = 1, n do Num(a[i], tag .. "." .. k .. "[" .. i .. "]", 1e9) end
	end
	for i = 1, n do
		local a = ch.an[i]
		Num(a.px, tag .. ".an[" .. i .. "].px", 1e5) Num(a.py, tag .. ".an.py", 1e5) Num(a.pz, tag .. ".an.pz", 1e5)
		Num(a.nx, tag .. ".an.nx", 2) Num(a.ny, tag .. ".an.ny", 2) Num(a.nz, tag .. ".an.nz", 2)
		if mesh and a[4] ~= mesh then Note("foreign", tag .. " node " .. i .. " lies on another mesh") break end
		if mesh and a[1] > mesh.nt then Note("foreign", tag .. " node " .. i .. " names triangle " .. a[1] .. " of " .. mesh.nt) break end
	end
	local hd = ch.head
	if hd then
		Vol(hd.vol, tag .. ".head.vol") Vol(hd.film, tag .. ".head.film")
		Num(hd.vx, tag .. ".head.vx", 1e5) Num(hd.vy, tag .. ".head.vy", 1e5) Num(hd.vz, tag .. ".head.vz", 1e5)
		Num(hd.wx, tag .. ".head.wx", 1e5) Num(hd.wy, tag .. ".head.wy", 1e5) Num(hd.wz, tag .. ".head.wz", 1e5)
		Num(hd.bage, tag .. ".head.bage") Num(hd.hangK, tag .. ".head.hangK", 1e9)
		if mesh and hd.tri and hd.tri > mesh.nt then Note("foreign", tag .. " head names triangle " .. hd.tri .. " of " .. mesh.nt) end
	end
	Num(ch.rate, tag .. ".rate", 1e9) Num(ch.mobile, tag .. ".mobile", 1e5) Vol(ch.sinkAcc, tag .. ".sinkAcc")
end

local nCells = 0
function H.scan(t)
	found, nBad, nNeg, nForeign = {}, 0, 0, 0
	nCells = 0
	local bk = FC.Books
	for k, v in pairs(bk) do
		Num(v, "books." .. k)
		-- (a state of the books may be a hair under zero by rounding, never more)
		if v < -0.01 then Note("neg", string.format("books.%s = %.4f", k, v)) end
	end
	Vol(FC.stainWet, "stainWet")
	Num(FC.nodes, "FC.nodes") Num(FC.heads, "FC.heads")
	if FC.nodes < 0 then Note("neg", "FC.nodes = " .. FC.nodes) end
	if FC.heads < 0 then Note("neg", "FC.heads = " .. FC.heads) end
	local BM = ABL.BodyMesh
	for si, src in ipairs(ABL.Sources.list) do
		local tag = "src" .. si
		Num(src.bank, tag .. ".bank") Num(src.gov, tag .. ".gov") Num(src.flowNominal, tag .. ".flowNominal") Num(src.flowRate, tag .. ".flowRate")
		Num(src.press, tag .. ".press") Num(src.blood, tag .. ".blood") Num(src.lost, tag .. ".lost") Num(src.owed, tag .. ".owed") Num(src.advance, tag .. ".advance")
		Num(src.dist, tag .. ".dist", 1e10) Num(src.lbk, tag .. ".lbk")
		if src.ledger then for k, v in pairs(src.ledger) do Num(v, tag .. ".ledger." .. k) end end
		local m = src.mesh
		-- the mesh the source works with against the body it has now
		if m and IsValid(src.body) then
			local key = BM.KeyFor(src.body)
			if key ~= m.key then Note("foreign", string.format("%s works with the mesh of %s, its body is %s", tag, tostring(m.key), tostring(key))) end
			if src.pose.mesh ~= m then Note("foreign", tag .. " pose is bound to another mesh") end
		end
		for wi, wd in ipairs(src.woundList) do
			local wt = tag .. ".wound" .. wi
			Num(wd.flow, wt .. ".flow") Num(wd.noise, wt .. ".noise") Num(wd.phase, wt .. ".phase") Vol(wd.dripAcc, wt .. ".dripAcc")
			Vol(wd.deposit, wt .. ".deposit") Vol(wd.pourAcc, wt .. ".pourAcc") Vol(wd.gushAcc, wt .. ".gushAcc") Vol(wd.jetAcc, wt .. ".jetAcc")
			Num(wd.vx, wt .. ".vx", 1e5) Num(wd.vy, wt .. ".vy", 1e5) Num(wd.vz, wt .. ".vz", 1e5) Vol(wd.soak0, wt .. ".soak0")
			if m and wd.tri and wd.tri > m.nt then Note("foreign", wt .. " names triangle " .. wd.tri .. " of " .. m.nt) end
			if wd.mark and m and wd.mark.m ~= m and not wd.mark.gone then Note("foreign", wt .. " bleeds from a mark on another mesh") end
		end
		for bi, b in ipairs(src.blobs) do
			Vol(b.vol, tag .. ".bead" .. bi .. ".vol")
			Num(b.vx, tag .. ".bead.vx", 1e5) Num(b.vy, tag .. ".bead.vy", 1e5) Num(b.vz, tag .. ".bead.vz", 1e5)
			if m and b.tri and b.tri > m.nt then Note("foreign", tag .. ".bead" .. bi .. " names triangle " .. b.tri .. " of " .. m.nt) end
		end
		for mi, mk in ipairs(src.marks or {}) do
			if m and mk.m ~= m then Note("foreign", tag .. ".mark" .. mi .. " (" .. tostring(mk.kind) .. ") lies on another mesh") end
		end
		local s = src.fc
		if s then
			for k, v in pairs(s.bk) do Num(v, tag .. ".bk." .. k) end
			Num(s.nodes, tag .. ".nodes")
			for ci, ch in ipairs(s.chans) do
				if not ch.dead then ScanChannel(ch, tag .. ".ch" .. ci, m) end
			end
		end
	end
	for ri, reg in ipairs(ABL.FlowWorld.regions) do
		for k, v in pairs(reg.fc.bk) do Num(v, "reg" .. ri .. ".bk." .. k) end
		for ci, ch in ipairs(reg.fc.chans) do
			if not ch.dead then ScanChannel(ch, "reg" .. ri .. ".ch" .. ci, nil) end
		end
	end
	for di, d in ipairs(ABL.Drops.list) do
		local dt = "drop" .. di
		Vol(d.vol, dt .. ".vol")
		Num(d.x, dt .. ".x", 1e5) Num(d.y, dt .. ".y", 1e5) Num(d.z, dt .. ".z", 1e5)
		Num(d.vx, dt .. ".vx", 1e5) Num(d.vy, dt .. ".vy", 1e5) Num(d.vz, dt .. ".vz", 1e5)
	end
	for pi, p in ipairs(ABL.Pools.list) do
		local pt = "pool" .. pi
		Vol(p.vol, pt .. ".vol") Num(p.wet, pt .. ".wet", 2) Num(p.x, pt .. ".x", 1e5) Num(p.y, pt .. ".y", 1e5) Num(p.z, pt .. ".z", 1e5)
		Num(p.nx, pt .. ".nx", 2) Num(p.rad, pt .. ".rad", 1e4) Vol(p.runAcc, pt .. ".runAcc")
		for _, b in ipairs(p.blobs) do
			Vol(b.vol, pt .. ".stamp.vol") Num(b.u, pt .. ".stamp.u", 1e4) Num(b.v, pt .. ".stamp.v", 1e4) Num(b.r, pt .. ".stamp.r", 1e4) Num(b.hs, pt .. ".stamp.hs", 1e4)
		end
		-- a liquid pool: every cell of its lattice (what is on it, in each state), and what has
		-- crossed an edge
		local g = p.sim
		if g then
			nCells = nCells + g.n * g.n
			for c = 1, g.n * g.n do
				Vol(g.h[c], pt .. ".cell.liquid") Vol(g.k[c], pt .. ".cell.set") Vol(g.s[c], pt .. ".cell.dried") Vol(g.ab[c], pt .. ".cell.soaked")
				Num(g.sh[c], pt .. ".cell.shear", 1e9) Num(g.zf[c], pt .. ".cell.floor", 1e4) Num(g.tb[c], pt .. ".cell.born", 1e9)
			end
			Vol(g.outVol, pt .. ".outVol") Vol(g.outLoose, pt .. ".outLoose")
			for _, x in pairs(g.out) do Vol(x, pt .. ".out") end
		end
	end
	for ri, r in ipairs(ABL.Runoff.list) do
		Vol(r.vol, "rivulet" .. ri .. ".vol") Num(r.x, "rivulet.x", 1e5) Num(r.y, "rivulet.y", 1e5) Num(r.z, "rivulet.z", 1e5)
	end
	local err, dAir, dSurf, dPool = FC.Audit()
	Log(string.format("scan %s | not finite or absurd %d, negative %d, foreign mesh %d | books: unbooked %.4f, airborne off by %.4f, surface off by %.4f, pool off by %.4f | lua errors: addon %d, all %d | %d pools, %d lattice cells read%s",
		t.name or "?", nBad, nNeg, nForeign, err, dAir, dSurf, dPool, errOwn, errAll, #ABL.Pools.list, nCells, #found > 0 and ("\n            " .. table.concat(found, "\n            ")) or ""))
end

------------------------------------------------------------------------------------------
-- Frame rate: a fixed amount of time burnt every frame (t.ms; 0 or nil: off), or one stall (t.once)
------------------------------------------------------------------------------------------
local burnMs = 0
hook.Add("Think", "ABL_HostileBurn", function()
	if burnMs <= 0 then return end
	local t0 = SysTime()
	local lim = burnMs / 1000
	while SysTime() - t0 < lim do end
end)

local frames, frameT0 = 0, 0
hook.Add("Think", "ABL_HostileFrames", function() frames = frames + 1 end)

function H.burn(t)
	if t.once then
		local t0 = SysTime()
		while SysTime() - t0 < t.once / 1000 do end
		Log(string.format("stall of %d ms", t.once))
		return
	end
	burnMs = t.ms or 0
	frames, frameT0 = 0, RealTime()
	Log(string.format("burning %d ms per frame", burnMs))
end

-- frames per second since the last H.burn / H.fps
function H.fps(t)
	local dt = RealTime() - frameT0
	Log(string.format("fps %s | %.1f frames per second over %.1f s (sim tick %d Hz, %.2f ticks per frame, LOD scale %.2f)", t.name or "?", dt > 0 and frames / dt or 0, dt, ABL.Sim.rate, ABL.Sim.steps, ABL.LOD.scale))
	frames, frameT0 = 0, RealTime()
end

------------------------------------------------------------------------------------------
-- One stream in numbers (frame-rate comparison): how far the blood of entity t.ent has run and
-- what the body's books say.
------------------------------------------------------------------------------------------
function H.streamstat(t)
	local ent = Entity(t.ent or 0)
	local S = ABL.Sources
	local src = IsValid(ent) and (S.byKey[ent] or S.byBody[ent]) or nil
	if not src then Log("stream " .. tostring(t.name) .. " | no source") return end
	local s = src.fc
	local len, nodes, chans, heads = 0, 0, 0, 0
	if s then
		for _, ch in ipairs(s.chans) do
			if not ch.dead then
				chans = chans + 1
				nodes = nodes + ch.n
				if ch.head then heads = heads + 1 end
				local l = ch.dist[ch.n] or 0
				if l > len then len = l end
			end
		end
	end
	local b = s and s.bk or { fed = 0, surface = 0, absorbed = 0, clotted = 0, dried = 0, left = 0 }
	local l = src.ledger or {}
	Log(string.format("stream %s | longest channel %.2f u, %d channels, %d nodes, %d heads | fed %.3f = on it %.3f + absorbed %.3f + clotted %.3f + dried %.3f + left %.3f | wounds released %.3f ml (burst %.3f), flow now %.4f ml/s, governor %.2f, bank %.2f",
		t.name or "?", len, chans, nodes, heads, b.fed, b.surface, b.absorbed, b.clotted, b.dried, b.left, (l.bleed or 0) + (l.burst or 0), l.burst or 0, src.flowRate or 0, src.gov or 1, src.bank or -1))
end

------------------------------------------------------------------------------------------
-- White-box states that play reaches only rarely
------------------------------------------------------------------------------------------
-- The bank of entity t.ent empty and nothing asked for yet (a character that coughed blood up
-- before its first wound, with no report of the reservoir in between).
function H.emptybank(t)
	local ent = Entity(t.ent or 0)
	local S = ABL.Sources
	local src = IsValid(ent) and (S.byKey[ent] or S.byBody[ent]) or (IsValid(ent) and S.Ensure(ent)) or nil
	if not src then Log("emptybank: no source") return end
	src.bank, src.flowNominal, src.lossT, src.owed, src.bleedT0, src.nominalSeen = 0, 0, nil, 0, nil, 0
	Log("emptybank: bank of " .. tostring(ent) .. " emptied, nothing asked for")
end

-- Values that must be turned away where they enter: each call is made on its own, protected, and
-- what it raised is logged.
function H.badvalues(t)
	local nan, inf = 0 / 0, math.huge
	local p = t.pos
	local up = Vector(0, 0, 1)
	local surf = ABL.Config.Surfaces.default
	local calls = {
		{ "Drops.Spawn NaN volume", function() ABL.Drops.Spawn(p.x, p.y, p.z + 40, 0, 0, 0, nan, nil, 0, 0) end },
		{ "Drops.Spawn negative volume", function() ABL.Drops.Spawn(p.x, p.y, p.z + 40, 0, 0, 0, -1, nil, 0, 0) end },
		{ "Drops.Spawn huge volume", function() ABL.Drops.Spawn(p.x, p.y, p.z + 40, 0, 0, 0, 1e12, nil, 0, 0) end },
		-- (not turned away: slowed to the fastest a drop may be)
		{ "Drops.Spawn at 20 000 units a second", function() ABL.Drops.Spawn(p.x, p.y, p.z + 40, 20000, 0, 0, 0.05, nil, 0, 0) end },
		{ "Pools.Deposit NaN volume", function() ABL.Pools.Deposit(p.x, p.y, p.z, up, nan, surf, nil, "drip") end },
		-- (as its callers do: the blood is booked into the pools before it is handed over)
		{ "Pools.Deposit NaN position", function() FC.Release("pool", 1) ABL.Pools.Deposit(nan, p.y, p.z, up, 1, surf, nil, "drip") end },
		{ "Pools.Deposit infinite position", function() FC.Release("pool", 1) ABL.Pools.Deposit(inf, p.y, p.z, up, 1, surf, nil, "drip") end },
		{ "Runoff.Spawn NaN position", function() ABL.Runoff.Spawn(nan, p.y, p.z, 0, 1, 0, 0.5, surf) end },
		{ "Runoff.Spawn NaN volume", function() ABL.Runoff.Spawn(p.x, p.y, p.z + 30, 0, 1, 0, nan, surf) end },
		{ "Runoff.Deposit NaN", function() ABL.Runoff.Deposit(p.x, nan, p.z + 30, 0, 1, 0, 0.2, surf) end },
		{ "Surface.WetAdd NaN position", function() ABL.Surface.WetAdd(nan, p.y, p.z, 0.1, 30) end },
		{ "Stains.Place NaN position", function() ABL.Stains.Place("drop", 1, nan, p.y, p.z, 0, 0, 1, nil, nil, nil, 1, 1, ABL.Config.Colors.decal, 220, nil, 0) end },
	}
	local src = ABL.Sources.list[1]
	if src and src.woundList[1] then
		local wd = src.woundList[1]
		calls[#calls + 1] = { "Flow.Feed NaN volume", function() ABL.Flow.Feed(src, wd, nan) end }
		calls[#calls + 1] = { "Flow.Feed zero volume", function() ABL.Flow.Feed(src, wd, 0) end }
		calls[#calls + 1] = { "Flow.Feed negative volume", function() ABL.Flow.Feed(src, wd, -1) end }
		calls[#calls + 1] = { "Flow.AddAt NaN volume", function() ABL.Flow.AddAt(src, wd.bone or 0, p.x, p.y, p.z, nan, 0, 0, 0) end }
		calls[#calls + 1] = { "Flow.AddAt NaN position", function() ABL.Flow.AddAt(src, wd.bone or 0, nan, p.y, p.z, 0.05, 0, 0, 0) end }
		calls[#calls + 1] = { "Flow.AddAt bone -1", function() ABL.Flow.AddAt(src, -1, p.x, p.y, p.z, 0.05, 0, 0, 0) end }
		calls[#calls + 1] = { "Flow.Shake NaN speed", function() ABL.Flow.Shake(src, wd.bone or 0, nan, 0, 0, 1) end }
		calls[#calls + 1] = { "Flow.Shake NaN direction", function() ABL.Flow.Shake(src, wd.bone or 0, 400, nan, 0, 1) end }
		calls[#calls + 1] = { "Emission.Jolt NaN speed", function() ABL.Emission.Jolt(src, wd.bone or 0, nan, 0, 0, 1) end }
	end
	-- (positions that are not numbers reach the engine's traces, infinite ones the grid loops: last)
	calls[#calls + 1] = { "Drops.Spawn NaN position", function() ABL.Drops.Spawn(nan, p.y, p.z + 40, 0, 0, 0, 0.05, nil, 0, 0) end }
	calls[#calls + 1] = { "Drops.Spawn infinite velocity", function() ABL.Drops.Spawn(p.x, p.y, p.z + 40, inf, 0, 0, 0.05, nil, 0, 0) end }
	if src and src.woundList[1] then
		local wd = src.woundList[1]
		calls[#calls + 1] = { "Flow.AddAt infinite position", function() ABL.Flow.AddAt(src, wd.bone or 0, inf, p.y, p.z, 0.05, 0, 0, 0) end }
	end
	local raised = 0
	for _, c in ipairs(calls) do
		Log("   badvalues: " .. c[1])
		local ok, err = pcall(c[2])
		if not ok then
			raised = raised + 1
			Log("      raised: " .. tostring(err))
		end
	end
	Log(string.format("badvalues %s | %d calls with values that must be turned away, %d raised an error", t.name or "?", #calls, raised))
end

-- A value of the configuration for the scenes that follow (t.key of ABL.Config, t.value).
function H.poke(t)
	ABL.Config[t.key] = t.value
	Log(string.format("config %s = %s", tostring(t.key), tostring(t.value)))
end

-- Z-City puts its own wound think and particle function back (as when its files are loaded
-- again): the takeover is gone until ABL notices.
function H.unwrap()
	local CP = ABL.Compat
	if not CP.installed or not CP.origWoundThink then Log("unwrap: the takeover is not installed") return end
	hook.Add("Player-Ragdoll think", "organism-think-client-blood", CP.origWoundThink)
	hg.addBloodPart = CP.origAdd
	Log("unwrap: Z-City's own wound think and particle function put back")
end
function H.wrapstate(t)
	local CP = ABL.Compat
	local set = hook.GetTable()["Player-Ragdoll think"]
	local think = set and set["organism-think-client-blood"]
	Log(string.format("takeover %s | wound think wrapped %s, particle function wrapped %s", t.name or "?", tostring(think ~= nil and think == CP.wrapThink), tostring(istable(hg) and hg.addBloodPart == CP.wrapAdd)))
end

-- Drops that end on nothing: impacts with no surface normal (a trace that began inside something).
local zeroNormal, impacts = 0, 0
do
	local I = ABL.Impacts
	local orig = I.Handle
	I.Handle = function(d, tr)
		impacts = impacts + 1
		local n = tr.HitNormal
		if n.x == 0 and n.y == 0 and n.z == 0 then zeroNormal = zeroNormal + 1 end
		return orig(d, tr)
	end
end
function H.impactstat(t)
	Log(string.format("impacts %s | %d impacts on the world, %d of them without a surface normal", t.name or "?", impacts, zeroNormal))
	impacts, zeroNormal = 0, 0
end

-- Network traffic of the blood events since the last call.
local lastCount, lastBits, lastNetT = 0, 0, 0
function H.netstat(t)
	local st = ABL.Net.stats
	local now = RealTime()
	local dt = now - lastNetT
	Log(string.format("net %s | %d events, %d bytes in %.1f s (%.0f bytes/s, %.1f events/s)", t.name or "?", st.count - lastCount, math.ceil((st.bits - lastBits) / 8), dt,
		dt > 0 and (st.bits - lastBits) / 8 / dt or 0, dt > 0 and (st.count - lastCount) / dt or 0))
	lastCount, lastBits, lastNetT = st.count, st.bits, now
end

------------------------------------------------------------------------------------------
-- Z-City: one blood system on screen (scene hostile_zcity). What Z-City shows of its own since the
-- last call, what the takeover caught, and what ABL bleeds.
------------------------------------------------------------------------------------------
local zPrev = {}
function H.zcstat(t)
	local CP = ABL.Compat
	local st = CP.stat
	local function D(k)
		local v = st[k] or 0
		local d = v - (zPrev[k] or 0)
		zPrev[k] = v
		return d
	end
	local n1 = istable(hg) and istable(hg.bloodparticles1) and #hg.bloodparticles1 or -1
	local n2 = istable(hg) and istable(hg.bloodparticles2) and #hg.bloodparticles2 or -1
	local nw = 0
	for _, src in ipairs(ABL.Sources.list) do nw = nw + #src.woundList end
	local ent = Entity(t.ent or 0)
	local org = IsValid(ent) and istable(ent.organism) and ent.organism or nil
	local _, dup = CP.Status()
	Log(string.format("zcity %s | takeover %s | Z-City: particles on screen +%d particle-frames (in its lists now %d + %d), decals stamped +%d | with the takeover on: on screen +%d, decals +%d"
		.. " | caught: swallowed +%d, as drops +%d, clouds +%d, impacts +%d, squirts +%d, coughs +%d, burst blobs +%d, dropped from the lists +%d | ABL: %d bodies, %d wounds, %d drops, %d pools"
		.. " | client organism: %s | duplicate visual systems %d",
		t.name or "?", CP.Takeover() and "on" or "off", D("zDrawn"), n1, n2, D("zDecals"), D("leakDrawn"), D("leakDecals"),
		D("swallowed"), D("adopted"), D("clouds"), D("impacts"), D("squirts"), D("coughs"), D("bursts"), D("drained"),
		#ABL.Sources.list, nw, ABL.Drops.Count(), ABL.Pools.Count(),
		org and string.format("blood %.0f pulse %.0f", tonumber(org.blood) or -1, tonumber(org.pulse) or -1) or "-", dup))
end

-- Every bleeding body and its wounds: one wound of Z-City's is one wound here.
function H.zcsources(t)
	local Z = ABL.ZC
	for _, src in ipairs(ABL.Sources.list) do
		local v, a = Z.GetWoundLists(src.key)
		local stump = Z.StumpWounds(src.key)
		local ids = {}
		for _, wd in ipairs(src.woundList) do ids[#ids + 1] = (wd.synthetic and "own:" or "") .. tostring(wd.id) end
		Log(string.format("zcity sources %s | %s body %s | Z-City wounds %d + %d arterial%s | ABL wounds %d: %s", t.name or "?", tostring(src.key), tostring(src.body),
			v and #v or 0, a and #a or 0, stump and " + the neck of a headless body" or "", #src.woundList, table.concat(ids, "  ")))
	end
	if #ABL.Sources.list == 0 then Log("zcity sources " .. tostring(t.name) .. " | none") end
end

-- The report of abl_zcity_status, into the log (the server's part goes to the console).
function H.zcstatus(t)
	local lines, dup = ABL.Compat.Status()
	for _, l in ipairs(lines) do Log("zcity status " .. tostring(t.name) .. " | " .. l) end
	Log(string.format("zcity status %s | duplicates %d", tostring(t.name), dup))
	RunConsoleCommand("abl_zcity_status")
end

------------------------------------------------------------------------------------------
-- The first seconds of a wound (scene onset). Sampled once per frame from the moment asked for:
-- what the wounds of entity t.ent release (ml/s, as emitted), what has left them in all, what is
-- on the body, the fastest and the longest stream on it, the drops of that body in the air, and
-- the pools. Written as windows after the event: the hit when there is one, else the first frame
-- with a wound.
------------------------------------------------------------------------------------------
local onset
do
	local E = ABL.Emission
	local orig = E.OnHit
	E.OnHit = function(ev, ...)
		if onset and not onset.hitT then onset.hitT = SysTime() end
		return orig(ev, ...)
	end
end

local WINDOWS = { 0.1, 0.25, 0.5, 1, 2, 3, 4, 5 }
local SHOTS = { 0.03, 0.1, 0.25, 0.5, 1, 2 }

local function OnsetReport(o)
	local name = o.name
	local t0 = o.hitT or o.woundT
	if not t0 then Log("onset " .. name .. " | no hit and no wound was seen") return end
	Log(string.format("onset %s | event: %s; first wound of Z-City's %s after it; %d frames sampled (%.0f per second)", name,
		o.hitT and "hit" or "wound", o.woundT and string.format("%.0f ms", (o.woundT - t0) * 1000) or "never", #o.s, #o.s / math.max(o.s[#o.s].t - o.s[1].t, 0.001)))
	local from = 0
	local prev
	for _, s in ipairs(o.s) do
		if s.t <= t0 then prev = s end
	end
	local peakFlow, peakT = 0, 0
	for _, to in ipairs(WINDOWS) do
		if to > o.dur + 0.01 then break end
		local n, flow, fmax, vmax, dmax, hmax = 0, 0, 0, 0, 0, 0
		local last
		for _, s in ipairs(o.s) do
			local rt = s.t - t0
			if rt > from and rt <= to then
				n = n + 1
				flow = flow + s.flow
				if s.flow > fmax then fmax = s.flow end
				if s.flow > peakFlow then peakFlow, peakT = s.flow, rt end
				if s.dropV > vmax then vmax = s.dropV end
				if s.dropD > dmax then dmax = s.dropD end
				if s.headV > hmax then hmax = s.headV end
				last = s
			end
		end
		if last then
			local base = prev or o.s[1]
			Log(string.format("onset %s | %4.0f-%4.0f ms: flow %6.2f ml/s (peak %6.2f) | released +%.3f ml (in all %.3f) | on the body %.3f ml, longest stream %.2f u (+%.2f, %.1f u/s), fastest head %.1f u/s | in the air %d drops, fastest %.0f u/s, furthest %.0f u from the wound | pools %.3f ml | wounds %d, response %.2f, governor %.2f | level of detail %d, the source's rate %.2f ml/s, booked by all bodies +%.3f ml",
				name, from * 1000, to * 1000, flow / n, fmax, last.rel - base.rel, last.rel, last.body, last.len, last.len - base.len,
				(last.len - base.len) / math.max(last.t - base.t, 0.001), hmax, last.drops, vmax, dmax, last.pool, last.wounds, last.resp, last.gov,
				last.lod, last.rate, last.booked - base.booked))
			prev = last
		else
			Log(string.format("onset %s | %4.0f-%4.0f ms: no frame", name, from * 1000, to * 1000))
		end
		from = to
	end
	-- how the flow came up: when it first reached a tenth, half and nine tenths of its level at the
	-- end of the second second, and the highest it stood before that
	local ref, rn = 0, 0
	for _, s in ipairs(o.s) do
		local rt = s.t - t0
		if rt > 1.5 and rt <= 2 then ref, rn = ref + s.flow, rn + 1 end
	end
	ref = rn > 0 and ref / rn or 0
	local t10, t50, t90
	for _, s in ipairs(o.s) do
		local rt = s.t - t0
		if rt > 0 and ref > 0 then
			if not t10 and s.flow >= ref * 0.1 then t10 = rt end
			if not t50 and s.flow >= ref * 0.5 then t50 = rt end
			if not t90 and s.flow >= ref * 0.9 then t90 = rt end
		end
	end
	local function F(v) return v and string.format("%.0f ms", v * 1000) or "never" end
	-- the steepest change of the flow: from one frame to the next, and per tenth of a second
	-- (frames are not equally long from run to run), as shares of that level
	local jump, jumpT, lastFlow, lastT, steep, steepT = 0, 0, nil, nil, 0, 0
	for _, s in ipairs(o.s) do
		local rt = s.t - t0
		if rt > -0.05 then
			if lastFlow then
				local d = math.abs(s.flow - lastFlow)
				if d > jump then jump, jumpT = d, rt end
				local per = d / math.max(rt - lastT, 0.004) * 0.1
				if per > steep then steep, steepT = per, rt end
			end
			lastFlow, lastT = s.flow, rt
		end
	end
	Log(string.format("onset %s | level at 1.5-2 s %.2f ml/s; reached 10 %% at %s, 50 %% at %s, 90 %% at %s; highest %.2f ml/s (%.0f %% of the level) at %.0f ms; largest step between two frames %.2f ml/s (%.0f %% of the level) at %.0f ms; steepest change %.0f %% of the level per 100 ms at %.0f ms",
		name, ref, F(t10), F(t50), F(t90), peakFlow, ref > 0 and peakFlow / ref * 100 or 0, peakT * 1000, jump, ref > 0 and jump / ref * 100 or 0, jumpT * 1000,
		ref > 0 and steep / ref * 100 or 0, steepT * 1000))
end

hook.Add("Think", "ABL_HostileOnset", function()
	local o = onset
	if not o then return end
	local now = SysTime()
	local ent = Entity(o.ent)
	local S = ABL.Sources
	local src = IsValid(ent) and (S.byKey[ent] or S.byBody[ent]) or nil
	if src and src.migratedTo and IsValid(src.migratedTo) and S.byKey[src.migratedTo] then src = S.byKey[src.migratedTo] end
	if IsValid(ent) and ent:IsPlayer() and not ent:Alive() then
		local corpse = ABL.ZC.GetCorpse(ent)
		if corpse and S.byKey[corpse] then src = S.byKey[corpse] end
	end
	-- (the camera on the wounded part, wherever the body goes)
	if o.bone and IsValid(ent) then
		local body = ent
		if ent:IsPlayer() then
			body = ent:Alive() and ABL.ZC.GetBody(ent) or (ABL.ZC.GetCorpse(ent) or ent)
		end
		local bi = IsValid(body) and body:LookupBone(o.bone) or nil
		local m = bi and body:GetBoneMatrix(bi) or nil
		if m then
			local at = m:GetTranslation()
			-- (it follows with a little lag, so that a flinch does not shake the picture)
			o.eye = o.eye and LerpVector(math.min(1, FrameTime() * 6), o.eye, at) or at
			local eye = o.eye + o.off
			H.view({ pos = eye, ang = (o.eye - Vector(0, 0, o.down) - eye):Angle() })
		end
	end
	local s = { t = now, flow = 0, rel = o.rel or 0, body = 0, len = 0, headV = 0, drops = 0, dropV = 0, dropD = 0, pool = FC.Books.pool, wounds = 0, resp = 0, gov = 1, lod = -1, rate = 0, booked = FC.Books.released }
	if src then
		s.gov = src.gov or 1
		s.lod, s.rate = src.lod or -1, src.flowRate or 0
		for _, wd in ipairs(src.woundList) do
			s.flow = s.flow + (wd.flow or 0)
			s.wounds = s.wounds + 1
			if (wd.resp or 0) > s.resp then s.resp = wd.resp end
			if not o.at then
				local ok, x, y, z = ABL.Emission.WoundFrame(src, wd)
				if ok then o.at = { x, y, z } end
			end
		end
		if s.wounds > 0 and not o.woundT then o.woundT = now end
		local l = src.ledger
		if l then s.rel = (l.bleed or 0) + (l.burst or 0) end
		o.rel = s.rel
		local f = src.fc
		if f then
			s.body = f.bk.surface
			for _, ch in ipairs(f.chans) do
				if not ch.dead then
					local d = ch.dist[ch.n] or 0
					if d > s.len then s.len = d end
					local hd = ch.head
					if hd then
						local v = math.sqrt(hd.vx * hd.vx + hd.vy * hd.vy + hd.vz * hd.vz)
						if v > s.headV then s.headV = v end
					end
				end
			end
		end
		if not o.at and IsValid(src.body) then
			local c = src.body:WorldSpaceCenter()
			o.at0 = { c.x, c.y, c.z }
		end
		local at = o.at or o.at0
		for _, d in ipairs(ABL.Drops.list) do
			if d.src == src and not d.dead then
				s.drops = s.drops + 1
				local v = math.sqrt(d.vx * d.vx + d.vy * d.vy + d.vz * d.vz)
				if v > s.dropV then s.dropV = v end
				if at then
					local dd = math.sqrt((d.x - at[1]) ^ 2 + (d.y - at[2]) ^ 2 + (d.z - at[3]) ^ 2)
					if dd > s.dropD then s.dropD = dd end
				end
			end
		end
	end
	o.s[#o.s + 1] = s
	local t0 = o.hitT or o.woundT
	if t0 and o.shots then
		local k = o.shotK or 1
		if SHOTS[k] and now - t0 >= SHOTS[k] then
			o.shotK = k + 1
			H.shot({ name = string.format("o_%s_%04dms", o.name, SHOTS[k] * 1000) })
		end
	end
	if (t0 and now - t0 > o.dur) or now - o.startT > o.dur + 6 then
		onset = nil
		local ok, err = pcall(OnsetReport, o)
		if not ok then Log("onset " .. tostring(o.name) .. " | report failed: " .. tostring(err)) end
	end
end)

function H.onset(t)
	onset = { ent = t.ent or 0, name = t.name or "?", dur = t.dur or 3, shots = t.shots and true or false, s = {}, startT = SysTime(),
		bone = t.bone, off = t.off or Vector(22, -46, 4), down = t.down or 6 }
end
