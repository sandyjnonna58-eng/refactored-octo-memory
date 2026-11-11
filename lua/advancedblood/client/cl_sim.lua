-- Central simulation loop and render entry point (the simulation manager).
-- One Think hook drives every simulation on one fixed tick (target abl_sim_hz, 165 Hz): wound
-- emission, droplets and world runoff; body-surface flow once per rendered frame (it reads the
-- body pose, which only changes per frame), at the same rates. Each object steps at the rate its
-- priority allows (see ABL.Sim in cl_lod.lua): near, visible blood every tick, far blood every
-- few ticks with a longer step. Renderers interpolate between an object's last two states, so
-- motion stays smooth at any frame rate. One render hook draws everything in batches. No
-- per-droplet hooks, timers or entities exist anywhere. Every section reports its time to the
-- profiler (cl_profiler.lua).

ABL.NoJIT()
local C, L = ABL.Config, ABL.LOD
local Sim = ABL.Sim
local Prof = ABL.Prof

ABL.Timing = ABL.Timing or { sim = 0, draw = 0, body = 0, emit = 0, flow = 0, drops = 0, runoff = 0, pools = 0, src = 0, misc = 0 }
local TM = ABL.Timing
local nextPrune = 0

local function Ema(key, v) TM[key] = (TM[key] or 0) * 0.92 + v * 0.08 end

function ABL.ClearAll(keepDecals)
	if ABL.Drops then ABL.Drops.Clear() end
	if ABL.Pools then ABL.Pools.Clear() end
	if ABL.Runoff then ABL.Runoff.Clear() end
	if ABL.FlowWorld then ABL.FlowWorld.Clear() end
	if ABL.Stains then ABL.Stains.Clear() end
	if ABL.Ground then ABL.Ground.Clear() end
	-- (the sources first: what their bodies still held is written off in the books, and the books
	-- are reset after that, not before)
	if ABL.Sources then ABL.Sources.ClearAll() end
	if ABL.Film then ABL.Film.Clear() end
	if ABL.FlowCore then ABL.FlowCore.Clear() end
	if ABL.Wounds then ABL.Wounds.Clear() end
	if ABL.Surface then ABL.Surface.Clear() end
	if ABL.Render then ABL.Render.ClearLight() ABL.Render.Discard() end
	if not keepDecals then RunConsoleCommand("r_cleardecals") end
end

hook.Add("Think", "ABL_Sim", function()
	Prof.Frame()
	if not ABL.Enabled() then return end
	-- one-off body mesh builds are time-sliced separately and not counted against the governor
	ABL.BodyMesh.RunJobs(1.5)
	-- (and the layout of the blood film on a surface model, once per model: cl_filmchart.lua)
	ABL.FilmChart.RunJobs(1)
	Prof.MemBegin()
	Prof.Heap()
	local t0 = SysTime()
	L.UpdateView()
	ABL.Sources.Update()
	Prof.Heap("sources")
	local t1 = SysTime()
	Ema("src", (t1 - t0) * 1000)
	Prof.Add("sim.sources", t1 - t0)

	local ft = FrameTime()
	if ft > 0 then
		if ft > C.MAX_FRAME then ft = C.MAX_FRAME end
		Sim.acc = Sim.acc + ft
		-- ticks owed this frame. At a low frame rate the count is capped and each tick stretched
		-- (up to C.MAX_TICK), so the cost per frame stays bounded while blood keeps real time.
		local h = 1 / Sim.rate
		local steps = math.floor(Sim.acc / h + 1e-6)
		if steps > C.MAX_STEPS then
			steps = C.MAX_STEPS
			h = math.min(Sim.acc / steps, C.MAX_TICK)
		end
		-- a hard stop well above the budget: a pathological frame drops its backlog instead of
		-- spiralling (the governor lowers the rate for the next frames)
		local hard = C.cl.budget:GetFloat() * 4
		local te, tf, td, tr = 0, 0, 0, 0
		local flowH = 0
		local ran = 0
		for _ = 1, steps do
			Sim.acc = Sim.acc - h
			Sim.t = Sim.t + h
			Sim.tick = Sim.tick + 1
			local a = SysTime()
			ABL.Emission.Step(h)
			Prof.Heap("emission")
			local b = SysTime()
			flowH = flowH + h
			ABL.Drops.Step(h)
			Prof.Heap("droplets")
			local d = SysTime()
			ABL.Runoff.Step(h)
			ABL.FlowWorld.Step(h)
			Prof.Heap("runoff")
			local e = SysTime()
			te, td, tr = te + (b - a), td + (d - b), tr + (e - d)
			ran = ran + 1
			if (e - t0) * 1000 > hard then break end
		end
		-- overloaded (or the hard stop): drop the backlog instead of spiralling
		if Sim.acc > h then Sim.acc = Sim.acc % h end
		if Sim.acc < 0 then Sim.acc = 0 end
		Sim.steps = Sim.steps * 0.9 + ran * 0.1
		-- body-surface flow reads the body pose, which only changes once per rendered frame: it steps
		-- (at its tier rate, up to the tick rate) at most once per frame, over the time of all ticks
		if flowH > 0 then
			local f0 = SysTime()
			ABL.Flow.Step(flowH)
			Prof.Heap("bodyflow")
			local f1 = SysTime()
			ABL.FlowCore.Step(flowH)
			Prof.Heap("flowcore")
			local f2 = SysTime()
			-- (the film on bodies steps on its own grid of the game's time: cl_film.lua)
			ABL.Film.Step()
			Prof.Heap("film")
			tf = SysTime() - f0
			-- (parts of sim.bodyflow, not sections beside it: the total must not count them twice)
			Prof.Add("sub.flowcore", f2 - f1)
			Prof.Add("sub.film", SysTime() - f2)
		end
		Ema("emit", te * 1000) Ema("flow", tf * 1000) Ema("drops", td * 1000) Ema("runoff", tr * 1000)
		Prof.Add("sim.emission", te) Prof.Add("sim.bodyflow", tf) Prof.Add("sim.droplets", td) Prof.Add("sim.runoff", tr)

		local p0 = SysTime()
		ABL.Pools.Think()
		Prof.Heap("pools")
		local m0 = SysTime()
		Ema("pools", (m0 - p0) * 1000)
		Prof.Add("sim.pools", m0 - p0)
		ABL.Emission.DepositThink()
		local ma = SysTime()
		ABL.Wounds.Think()
		local mb = SysTime()
		ABL.Transfer.Think()
		local mc = SysTime()
		ABL.Ground.Think()
		Prof.Heap("misc")
		local m1 = SysTime()
		Ema("misc", (m1 - m0) * 1000)
		Prof.Add("sim.misc", m1 - m0)
		Prof.Add("sub.misc.deposit", ma - m0) Prof.Add("sub.misc.wounds", mb - ma) Prof.Add("sub.misc.transfer", mc - mb) Prof.Add("sub.misc.ground", m1 - mc)
	end
	local now = RealTime()
	if now > nextPrune then
		nextPrune = now + 0.25
		ABL.Drops.PruneParticles()
	end
	local ms = (SysTime() - t0) * 1000
	Prof.MemEnd()
	Ema("sim", ms)
	-- body blood drawn by the character renderer during the previous frame
	Ema("body", ABL.Flow.drawAcc or 0)
	ABL.Flow.drawAcc = 0
	L.Governor(ms + TM.draw + TM.body + (TM.paint or 0), ms)
end)

-- Pool canvases are repainted before the frame renders (render-target passes, outside the 3D
-- view), within a small per-frame budget (cl_pools.lua P.Paint).
hook.Add("PreRender", "ABL_PoolPaint", function()
	if not ABL.Enabled() then return end
	local t0 = SysTime()
	Prof.Heap()
	ABL.Pools.Paint()
	Prof.Heap("poolpaint")
	local t1 = SysTime()
	-- (and the canvases of the film on bodies: cl_filmdraw.lua)
	ABL.FilmDraw.Paint()
	Prof.Heap("filmpaint")
	local t2 = SysTime()
	Ema("paint", (t2 - t0) * 1000)
	Prof.Add("draw.poolpaint", t1 - t0)
	Prof.Add("draw.filmpaint", t2 - t1)
end)

-- Drawn before translucent entities so glass/water still render over blood behind them; opaque
-- models (bodies) are already set up, so body-surface blood uses this frame's bones.
hook.Add("PreDrawTranslucentRenderables", "ABL_Draw", function(depth, skybox, skybox3d)
	if depth or skybox or skybox3d then return end
	if not ABL.Enabled() then return end
	local R = ABL.Render
	-- blood is not drawn into water reflections / render-target cameras (cost, not needed)
	if not L.CaptureView() then return end
	Prof.MemBegin()
	Prof.Heap()
	local t0 = SysTime()
	L.ApplyView()
	R.SetCamera(EyePos(), EyeAngles())
	-- layer 1: ground impact stains, then fresh stain overlays on walls (all under pools)
	ABL.Ground.Draw()
	local t1 = SysTime()
	ABL.Stains.Draw()
	R.Flush()
	Prof.Heap("draw stains")
	local t2 = SysTime()
	-- layer 2: pools and runoff streaks (static meshes)
	ABL.Pools.Draw()
	Prof.Heap("draw pools")
	local t3 = SysTime()
	ABL.Runoff.Draw()
	ABL.FlowWorld.Draw()
	Prof.Heap("draw runoff")
	local t4 = SysTime()
	-- layer 3: body-surface blood (reports itself as draw.body) and airborne droplets
	ABL.Flow.Draw()
	Prof.Heap()
	local t5 = SysTime()
	ABL.Drops.Draw()
	local t6 = SysTime()
	R.Flush()
	Prof.Heap("draw droplets")
	local t7 = SysTime()
	Prof.MemEnd()
	Prof.Add("draw.ground", t1 - t0) Prof.Add("draw.wallstains", t2 - t1) Prof.Add("draw.pools", t3 - t2)
	Prof.Add("draw.runoff", t4 - t3) Prof.Add("draw.droplets", t6 - t5) Prof.Add("draw.flush", t7 - t6)
	-- (body blood drawn in the fallback path is inside this hook: not counted twice in TM.draw)
	Ema("draw", ((t7 - t0) - (t5 - t4)) * 1000)
end)

hook.Add("PostCleanupMap", "ABL_Cleanup", function()
	ABL.ClearAll(true)
end)

hook.Add("ShutDown", "ABL_Shutdown", function()
	if ABL.Pools then ABL.Pools.Clear() end
	if ABL.Runoff then ABL.Runoff.Clear() end
	if ABL.FlowWorld then ABL.FlowWorld.Clear() end
end)

-- Toggling the client switch frees everything immediately.
cvars.AddChangeCallback("abl_cl_enabled", function(_, _, new)
	if new == "0" then ABL.ClearAll(true) end
end, "ABL_Toggle")

concommand.Add("abl_clear", function()
	ABL.ClearAll(false)
	ABL.Print("cleared all blood state")
end)
