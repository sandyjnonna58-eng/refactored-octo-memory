-- Profiler. Every module reports how long its part of a frame took (ABL.Prof.Add) and the
-- profiler keeps, per section, a smoothed value, the worst frame of the last few seconds and the
-- calls per frame; plus counts of what is alive, traces, decals, network traffic and Lua memory
-- (heap size, how much ABL allocates per second, garbage-collector cycles).
--   abl_profiler 1        on-screen panel
--   abl_profiler_dump     print the same report to the console and to data/abl_profile.txt
-- Reporting costs one table write per section per frame, so it is always on; the panel and the
-- memory sampling only run while abl_profiler is set (or the test harness asks for a report).

ABL.NoJIT()
ABL.Prof = ABL.Prof or {}
local P = ABL.Prof
local C = ABL.Config

P.cv = CreateClientConVar("abl_profiler", "0", false, false, "Show the AdvancedBlood profiler panel (per-section times, counts, memory).", 0, 1)

local acc, calls = {}, {}            -- this frame: seconds, calls
local ema, peak, peakT, cnt = {}, {}, {}, {}
local order = {}                     -- sections in first-seen order
local PEAK_WINDOW = 4                -- seconds a worst-frame value is held

function P.Add(key, seconds)
	local a = acc[key]
	if a then
		acc[key] = a + seconds
		calls[key] = calls[key] + 1
	else
		if ema[key] == nil then
			ema[key], peak[key], peakT[key], cnt[key] = 0, 0, 0, 0
			order[#order + 1] = key
		end
		acc[key], calls[key] = seconds, 1
	end
end

-- Work counters: how many of something a frame handled (vertices pushed, meshes rebuilt, ...).
local cAcc, cEma, cOrder = {}, {}, {}
function P.Count(key, n)
	local a = cAcc[key]
	if a then
		cAcc[key] = a + n
	else
		if cEma[key] == nil then cEma[key] = 0 cOrder[#cOrder + 1] = key end
		cAcc[key] = n
	end
end
function P.GetCount(key) return cEma[key] or 0 end

-- Memory: Lua heap (KB), allocation by ABL's own sections (KB/s) and collector cycles.
P.mem = { kb = 0, allocRate = 0, gcPerMin = 0, allocAcc = 0, gcCount = 0, lastKb = 0, t = 0 }
local mem = P.mem
local memOn = false
local memMark = 0

-- Bracket a stretch of ABL code: the heap growth in between is what it allocated (a collector
-- step in between shows up as a negative delta and is skipped).
function P.MemBegin()
	if memOn then memMark = collectgarbage("count") end
end
function P.MemEnd()
	if not memOn then return end
	local d = collectgarbage("count") - memMark
	if d > 0 then mem.allocAcc = mem.allocAcc + d end
end

-- Allocation by section (KB/s, while the memory sampling runs). P.Heap() marks the heap at the
-- start of a stretch of ABL code; P.Heap(key) books what it has grown by since the last mark to
-- that section and marks again (a collector step in between is a negative growth: skipped).
local heapMark, heapAcc, heapRate, heapOrder = 0, {}, {}, {}
function P.Heap(key)
	if not memOn then return end
	local kb = collectgarbage("count")
	if key then
		local d = kb - heapMark
		if d > 0 then
			if heapRate[key] == nil then heapRate[key] = 0 heapOrder[#heapOrder + 1] = key end
			heapAcc[key] = (heapAcc[key] or 0) + d
		end
	end
	heapMark = kb
end

-- Whole-frame statistics over the window since the last report (frame times of the game itself).
P.frame = { n = 0, sum = 0, worst = 0, over = 0 }

local lastFrameT = 0
function P.Frame()
	local now = RealTime()
	for i = 1, #order do
		local key = order[i]
		local a = acc[key]
		if a then
			local ms = a * 1000
			ema[key] = ema[key] * 0.92 + ms * 0.08
			cnt[key] = cnt[key] * 0.92 + calls[key] * 0.08
			if ms > peak[key] or now > peakT[key] then peak[key], peakT[key] = ms, now + PEAK_WINDOW end
			acc[key], calls[key] = nil, nil
		else
			-- a section that did not run this frame decays
			ema[key] = ema[key] * 0.92
			cnt[key] = cnt[key] * 0.92
			if now > peakT[key] then peak[key] = 0 end
		end
	end
	for i = 1, #cOrder do
		local key = cOrder[i]
		cEma[key] = cEma[key] * 0.92 + (cAcc[key] or 0) * 0.08
		cAcc[key] = nil
	end
	local f = P.frame
	if lastFrameT > 0 then
		local ft = now - lastFrameT
		f.n = f.n + 1
		f.sum = f.sum + ft
		if ft > f.worst then f.worst = ft end
		if ft > 1 / 30 then f.over = f.over + 1 end
	end
	lastFrameT = now
	memOn = P.cv:GetBool() or P.force
	P.heapOn = memOn
	if memOn and now > mem.t then
		local kb = collectgarbage("count")
		local dt = now - (mem.t - 1)
		if kb < mem.lastKb - 256 then mem.gcCount = mem.gcCount + 1 end
		mem.lastKb = kb
		mem.kb = kb
		mem.allocRate = mem.allocRate * 0.6 + (mem.allocAcc / math.max(dt, 0.25)) * 0.4
		mem.allocAcc = 0
		for i = 1, #heapOrder do
			local key = heapOrder[i]
			heapRate[key] = heapRate[key] * 0.6 + ((heapAcc[key] or 0) / math.max(dt, 0.25)) * 0.4
			heapAcc[key] = 0
		end
		mem.gcPerMin = mem.gcPerMin * 0.9 + (mem.gcCount * 60 / math.max(dt, 0.25)) * 0.1
		mem.gcCount = 0
		mem.t = now + 1
	end
end

function P.Get(key) return ema[key] or 0, peak[key] or 0 end

-- Sum of the smoothed times of all sections starting with `prefix`.
function P.Sum(prefix)
	local s, pk = 0, 0
	for i = 1, #order do
		local key = order[i]
		if string.sub(key, 1, #prefix) == prefix then s = s + ema[key] pk = pk + peak[key] end
	end
	return s, pk
end

function P.ResetFrameStats()
	local f = P.frame
	f.n, f.sum, f.worst, f.over = 0, 0, 0, 0
end

------------------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------------------
local function Counts()
	local L = ABL.LOD
	local wounds, blobs, segs, marks = 0, 0, 0, 0
	for _, src in ipairs(ABL.Sources.list) do
		wounds = wounds + #src.woundList
		blobs = blobs + #src.blobs
		segs = segs + (src.segCount or 0)
		marks = marks + (src.marks and #src.marks or 0)
	end
	return wounds, blobs, segs, marks, L
end

function P.Lines()
	local Sim, L = ABL.Sim, ABL.LOD
	local lines = {}
	local function Add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
	local simMs, simPk = P.Sum("sim.")
	local drawMs, drawPk = P.Sum("draw.")
	local f = P.frame
	Add("AdvancedBlood profiler   tick %.0f/%d Hz (%.1f ticks/frame)   LOD scale %.2f   budget %.1f ms", Sim.rate, Sim.Target(), Sim.steps, L.scale, C.cl.budget:GetFloat())
	Add("total: simulation %.2f ms (worst %.2f)   drawing %.2f ms (worst %.2f)   game frame %.1f ms avg, %.1f worst, %d of %d over 33 ms",
		simMs, simPk, drawMs, drawPk, f.n > 0 and f.sum / f.n * 1000 or 0, f.worst * 1000, f.over, f.n)
	for _, group in ipairs({ "sim.", "draw.", "sub." }) do
		local parts = {}
		for i = 1, #order do
			local key = order[i]
			if string.sub(key, 1, #group) == group and (ema[key] > 0.004 or peak[key] > 0.05) then
				parts[#parts + 1] = string.format("%s %.2f (%.2f)", string.sub(key, #group + 1), ema[key], peak[key])
			end
		end
		-- a few sections per line
		for i = 1, #parts, 5 do
			Add("  %s%s", i == 1 and (group == "sim." and "sim:  " or group == "draw." and "draw: " or "part: ") or "      ", table.concat(parts, "   ", i, math.min(i + 4, #parts)))
		end
	end
	if #cOrder > 0 then
		local parts = {}
		for i = 1, #cOrder do
			local key = cOrder[i]
			parts[#parts + 1] = string.format("%s %.1f", key, cEma[key])
		end
		for i = 1, #parts, 7 do
			Add("  %s%s", i == 1 and "per frame: " or "           ", table.concat(parts, "   ", i, math.min(i + 6, #parts)))
		end
	end
	local wounds, blobs, segs, marks = Counts()
	local D, G = ABL.Drops, ABL.Ground
	Add("alive: sources %d  wounds %d  body beads %d  streak segments %d  wound marks %d", #ABL.Sources.list, wounds, blobs, segs, marks)
	Add("       droplets %d/%d  particles %d  pools %d  rivulets %d  ground stains %d  wet overlays %d", D.Count(), L.Cap(C.cl.maxDrops), D.ParticleCount(), ABL.Pools.Count(), ABL.Runoff.Count(), G.Count(), ABL.Stains.Count())
	local nt = ABL.Debug and ABL.Debug.netTotals
	local el = nt and math.max(RealTime() - nt.start, 1) or 1
	Add("work:  traces %d/%d per frame  decals %d (%d refused)  pool repaints %d (%.2f ms each)  network %d events, %.2f kbit/s",
		L.traces, L.traceBudget, ABL.Stains.stats.decals, ABL.Stains.stats.rejected, ABL.Pools.stats.paints, ABL.Pools.stats.paintMs, nt and nt.count or 0, nt and nt.bits / el / 1000 or 0)
	-- the flow core: what is running, at what rate, and where all the blood is (books)
	local FC = ABL.FlowCore
	if FC then
		local chans, active, cells, heads = FC.Counts()
		local bk = FC.Books
		local sum = bk.airborne + bk.surface + bk.pool + bk.absorbed + bk.clotted + bk.dried + bk.lost
		Add("flow:  sources %d  streams %d (%d running)  flow cells %d of %d nodes  heads %d  droplets %d  pools %d  | flow core %.2f ms  flow drawing %.2f ms  at %.0f Hz",
			#ABL.Sources.list, chans, active, cells, FC.nodes, heads, D.Count(), ABL.Pools.Count(), ema["sub.flowcore"] or 0, ema["sub.body.flow"] or 0, f.n > 0 and f.n / math.max(f.sum, 1e-3) or 0)
		Add("blood: %.1f ml released = airborne %.2f + on surfaces %.2f + in pools %.2f + absorbed %.2f + clotted %.2f + dried %.2f + lost %.2f  (unbooked %.3f)",
			bk.released, bk.airborne, bk.surface, bk.pool, bk.absorbed, bk.clotted, bk.dried, bk.lost, bk.released - sum)
	end
	-- the film on bodies: how many bodies have one, its cells, and what it costs
	local FM, FMD = ABL.Film, ABL.FilmDraw
	if FM and FMD then
		local films, fcells, wet, act = FM.Counts()
		local used, made = FMD.Usage()
		Add("film:  bodies %d  cells %d of %d (%d with blood, %d running)  canvases %d in use, %d made of %d  | steps %.2f ms  painting %.2f ms  drawing %.2f ms",
			films, fcells, L.Cap(FM.cvCells), wet, act, used, made, FMD.Limit(), ema["sub.film"] or 0, ema["draw.filmpaint"] or 0, ema["sub.body.film"] or 0)
	end
	Add("memory: Lua heap %.1f MB   AdvancedBlood allocates %.0f KB/s   collector cycles %.1f per minute", mem.kb / 1024, mem.allocRate, mem.gcPerMin)
	if #heapOrder > 0 then
		local parts = {}
		for i = 1, #heapOrder do
			local key = heapOrder[i]
			if heapRate[key] >= 0.5 then parts[#parts + 1] = string.format("%s %.0f", key, heapRate[key]) end
		end
		for i = 1, #parts, 8 do
			Add("  %s%s", i == 1 and "allocates, KB/s: " or "                 ", table.concat(parts, "   ", i, math.min(i + 7, #parts)))
		end
	end
	-- compiled traces alive in this Lua state (all addons), and whether ABL's modules are compiled
	local ti = jit and jit.util and jit.util.traceinfo
	if ti then
		local n = 0
		for i = 1, 4096 do if ti(i) then n = n + 1 end end
		Add("jit: %d traces alive   AdvancedBlood modules %s", n, ABL.jitOff and "interpreted" or "compiled")
	end
	return lines
end

hook.Add("HUDPaint", "ABL_Profiler", function()
	if not P.cv:GetBool() then return end
	local lines = P.Lines()
	local w = 0
	surface.SetFont("DermaDefault")
	for _, l in ipairs(lines) do local tw = surface.GetTextSize(l) if tw > w then w = tw end end
	local x, y = 12, ScrH() * 0.12
	surface.SetDrawColor(0, 0, 0, 170)
	surface.DrawRect(x - 6, y - 6, w + 12, #lines * 15 + 12)
	for _, l in ipairs(lines) do
		draw.SimpleText(l, "DermaDefault", x, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		y = y + 15
	end
end)

concommand.Add("abl_profiler_dump", function()
	local lines = P.Lines()
	for _, l in ipairs(lines) do print(l) end
	file.Write("abl_profile.txt", table.concat(lines, "\n") .. "\n")
	print("written to garrysmod/data/abl_profile.txt")
end)
