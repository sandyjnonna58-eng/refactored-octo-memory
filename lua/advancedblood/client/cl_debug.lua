-- Developer mode. Entirely inert unless abl_debug / abl_debug_hud are set.
-- abl_debug bitmask:
--     1 wounds (position, outward normal, profile, flow)      2 droplet velocities
--     4 recent impacts (normal, splash parameter K, stain)    8 body flow (beads, gravity tangent)
--    16 runoff rivulets                                       32 pool outlines / probed extents
--    64 source LOD / importance                               128 network event log (console)
--   256 body mesh triangles around wounds                   512 wound records (track, classification,
--                                                              bleeding class, state, blood-volume ledger)
--  1024 what becomes of each wound and of each character's blood, and why, in the console as it
--       happens (cl_trace.lua; abl_trace prints what there is now and the last events at any time)

ABL.NoJIT()
ABL.Debug = ABL.Debug or {}
local DB = ABL.Debug
local C, L = ABL.Config, ABL.LOD

local colW, colN, colD, colI, colB, colG, colR, colP = Color(255, 220, 0), Color(0, 200, 255), Color(255, 80, 80), Color(255, 255, 255), Color(255, 0, 255), Color(0, 255, 0), Color(255, 140, 0), Color(80, 160, 255)

DB.netLog = {}
DB.netTotals = { count = 0, bits = 0, start = RealTime() }
function DB.LogNet(kind, bits, ev)
	DB.netTotals.count = DB.netTotals.count + 1
	DB.netTotals.bits = DB.netTotals.bits + bits
	if bit.band(C.cl.debug:GetInt(), 128) ~= 0 then
		MsgC(Color(255, 120, 120), string.format("[ABL net] %s %d bits\n", kind, bits))
	end
end

local function V(x, y, z) return Vector(x, y, z) end
local texts = {}

local function Text3D(pos, str, col, dy)
	texts[#texts + 1] = { pos, str, col, dy or 0 }
end

hook.Add("PostDrawTranslucentRenderables", "ABL_Debug3D", function(depth, sky, sky3d)
	if depth or sky or sky3d then return end
	local mask = C.cl.debug:GetInt()
	if mask == 0 then return end
	render.SetColorMaterial()
	local gx, gy, gz, gmag = ABL.Gravity()

	for _, src in ipairs(ABL.Sources.list) do
		local body = src.body
		if IsValid(body) then
			if bit.band(mask, 1) ~= 0 then
				for _, wd in ipairs(src.woundList) do
					local ok, x, y, z, nx, ny, nz = ABL.Emission.WoundFrame(src, wd)
					if ok then
						local p = V(x, y, z)
						render.DrawWireframeSphere(p, 0.6 + math.min(wd.sev / 20, 1.5), 6, 6, wd.arterial and colD or colW, false)
						render.DrawLine(p, p + V(nx, ny, nz) * 4, colN, false)
						local prof = wd.profile and wd.profile.name or "?"
						Text3D(p + V(0, 0, 2), string.format("%s %.2f ml/s%s", prof, ABL.Emission.Rate(src, wd), wd.tri and "" or " (no anchor)"), colW)
					end
				end
			end
			if bit.band(mask, 8) ~= 0 and src.mesh then
				for _, b in ipairs(src.blobs) do
					if not b.dead then
						local px, py, pz, nx, ny, nz = src.pose:Point(b.tri, b.u, b.v)
						local p = V(px, py, pz)
						local gn = gx * nx + gy * ny + gz * nz
						local tx, ty, tz = gx - nx * gn, gy - ny * gn, gz - nz * gn
						render.DrawWireframeSphere(p, 0.25 + b.vol ^ 0.33 * 0.5, 5, 5, b.tethered and colW or colB, false)
						render.DrawLine(p, p + V(tx, ty, tz) / gmag * 3, colG, false)
						render.DrawLine(p, p + V(nx, ny, nz) * 1.5, colN, false)
						if b.atEdge then render.DrawWireframeSphere(p, 0.8, 4, 4, colR, false) end
					end
				end
			end
			if bit.band(mask, 256) ~= 0 and src.mesh then
				local m = src.mesh
				for _, wd in ipairs(src.woundList) do
					if wd.tri then
						local list = { wd.tri, m.n1[wd.tri], m.n2[wd.tri], m.n3[wd.tri] }
						for _, t in ipairs(list) do
							if t and t > 0 then
								local ax, ay, az, bx, by, bz, cx, cy, cz = src.pose:Tri(t)
								render.DrawLine(V(ax, ay, az), V(bx, by, bz), colP, false)
								render.DrawLine(V(bx, by, bz), V(cx, cy, cz), colP, false)
								render.DrawLine(V(cx, cy, cz), V(ax, ay, az), colP, false)
							end
						end
					end
				end
			end
			if bit.band(mask, 512) ~= 0 then
				-- wound records: the projectile's track through the body, what the record holds, and
				-- where the blood that left this body is now
				local WS = ABL.Wounds
				for _, r in ipairs(src.wrecs or {}) do
					local mk, mx = r.entryMark, r.exitMark
					local p1, p2
					if mk and src.mesh and mk.m == src.mesh then p1 = V(src.pose:Point(mk.tri, mk.u, mk.v)) end
					if mx and src.mesh and mx.m == src.mesh then p2 = V(src.pose:Point(mx.tri, mx.u, mx.v)) end
					local b = src.pose:Bone(r.bone)
					if not p1 and b and r.lentry then
						local l = r.lentry
						p1 = V(b[1] * l.x + b[2] * l.y + b[3] * l.z + b[4], b[5] * l.x + b[6] * l.y + b[7] * l.z + b[8], b[9] * l.x + b[10] * l.y + b[11] * l.z + b[12])
					end
					if p1 then
						local dir
						if b and r.ldir then
							local l = r.ldir
							dir = V(ABL.Norm(b[1] * l.x + b[2] * l.y + b[3] * l.z, b[5] * l.x + b[6] * l.y + b[7] * l.z, b[9] * l.x + b[10] * l.y + b[11] * l.z))
						end
						render.DrawWireframeSphere(p1, 0.35, 6, 6, colW, false)
						if dir then render.DrawLine(p1 - dir * 6, p1, colG, false) end
						if p2 then
							render.DrawLine(p1, p2, colI, false)
							render.DrawWireframeSphere(p2, 0.45, 6, 6, colP, false)
							if dir then render.DrawLine(p2, p2 + dir * 5, colG, false) end
						elseif dir and r.pen == ABL.Wound.PEN_RETAINED then
							-- a retained projectile: somewhere along the line, inside
							local stop = p1 + dir * 4
							render.DrawLine(p1, stop, colD, false)
							render.DrawWireframeSphere(stop, 0.25, 4, 4, colD, false)
						end
						local lines = WS.Describe(r)
						for k = 1, #lines do Text3D(p1, lines[k], k == 1 and colW or colI, (k - 1) * 13 - #lines * 13 - 8) end
					end
				end
				if src.ledger or src.lost then
					local ll = WS.LedgerLines(src)
					for k = 1, #ll do Text3D(body:WorldSpaceCenter() + V(0, 0, 46), ll[k], colG, (k - #ll) * 13) end
				end
			end
			if bit.band(mask, 64) ~= 0 then
				Text3D(body:WorldSpaceCenter() + V(0, 0, 40), string.format("LOD %s  imp %.2f  d %.0f  flow %.2f ml/s  blobs %d segs %d%s",
					C.LODNames[src.lod] or "?", src.importance or 0, src.dist or 0, src.flowRate or 0, #src.blobs, src.segCount or 0, src.mesh and "" or " (mesh pending)"), colI)
			end
		end
	end

	if bit.band(mask, 2) ~= 0 then
		for _, d in ipairs(ABL.Drops.list) do
			local p = V(d.x, d.y, d.z)
			render.DrawLine(p, p + V(d.vx, d.vy, d.vz) * 0.03, colD, false)
		end
	end
	if bit.band(mask, 4) ~= 0 then
		local now = CurTime()
		for _, r in pairs(ABL.Impacts.recent) do
			if now - r.t < 6 then
				local p = V(r.x, r.y, r.z)
				render.DrawLine(p, p + V(r.nx, r.ny, r.nz) * 3, colN, false)
				Text3D(p + V(r.nx, r.ny, r.nz) * 3.5, string.format("%s K=%.0f", r.kind, r.K), colI)
			end
		end
	end
	if bit.band(mask, 16) ~= 0 then
		for _, list in ipairs({ ABL.Runoff.list, ABL.FlowWorld.list }) do
			for _, r in ipairs(list) do
				local p = V(r.x, r.y, r.z)
				render.DrawWireframeSphere(p, 0.4 + math.max(r.vol, 0) ^ 0.33, 5, 5, colR, false)
				Text3D(p + V(r.nx, r.ny, r.nz) * 2, string.format("%s %.3f ml", r.state, r.vol), colR)
			end
		end
	end
	if bit.band(mask, 32) ~= 0 then
		-- pool stamps (reach circles by kind), wall / ledge clip lines, canvas squares
		ABL.Pools.DebugDraw(Text3D)
	end
end)

hook.Add("HUDPaint", "ABL_DebugHUD", function()
	if #texts > 0 then
		for _, t in ipairs(texts) do
			local s = t[1]:ToScreen()
			if s.visible then draw.SimpleTextOutlined(t[2], "DermaDefault", s.x, s.y + t[4], t[3], TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black) end
		end
		texts = {}
	end
	if not C.cl.debugHud:GetBool() then return end
	local TM = ABL.Timing
	local wounds, blobs, trails = 0, 0, 0
	for _, src in ipairs(ABL.Sources.list) do wounds = wounds + #src.woundList blobs = blobs + #src.blobs trails = trails + (src.segCount or 0) end
	local nt = DB.netTotals
	local el = math.max(RealTime() - nt.start, 1)
	local lines = {
		string.format("AdvancedBlood %s  quality %d  LOD scale %.2f", ABL.VERSION, C.cl.quality:GetInt(), L.scale),
		string.format("sim %.2f ms (emit %.2f flow %.2f drops %.2f runoff %.2f pools %.2f)  draw %.2f ms  budget %.1f", TM.sim, TM.emit, TM.flow, TM.drops, TM.runoff, TM.pools, TM.draw, C.cl.budget:GetFloat()),
		string.format("sources %d  wounds %d  blobs %d  streak segments %d", #ABL.Sources.list, wounds, blobs, trails),
		string.format("droplets %d/%d  particles %d  overlays %d  pools %d  runoff %d", ABL.Drops.Count(), L.Cap(C.cl.maxDrops), ABL.Drops.ParticleCount(), ABL.Stains.Count(), ABL.Pools.Count(), ABL.Runoff.Count()),
		(function()
			local pb, ps, sl = ABL.Pools.Totals()
			return string.format("pool stamps %d  spatter %d  slots %d (page %d%% used)  repaint %.2f ms (%.2f ms/frame)", pb, ps, sl, math.floor(ABL.PoolCanvas.Usage() * 100), ABL.Pools.stats.paintMs, TM.paint or 0)
		end)(),
		string.format("traces %d/%d per frame  decals %d (rejected %d)  wet cells %d", L.traces, L.traceBudget, ABL.Stains.stats.decals, ABL.Stains.stats.rejected, ABL.Surface.Count()),
		string.format("net events %d  %.2f kbit/s avg  (%.1f kbit total)", nt.count, nt.bits / el / 1000, nt.bits / 1000),
	}
	local y = ScrH() * 0.3
	for _, l in ipairs(lines) do
		draw.SimpleTextOutlined(l, "DermaDefault", 12, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
		y = y + 15
	end
end)

concommand.Add("abl_debug_help", function()
	print([[abl_debug <mask>: 1 wounds, 2 droplets, 4 impacts, 8 body flow, 16 runoff, 32 pools, 64 LOD, 128 net log, 256 mesh triangles,
                  512 wound records (projectile track, classification, bleeding, age, blood-volume ledger),
                  1024 wound and blood events in the console as they happen (taken up, opened, held on the skin, hidden,
                  closing, removed, a new life, drawn or not: each with its reason)
abl_trace [n]     every character with blood and each of its wounds (place, hold, state, what happened to it last and why),
                  and the last n events (40); abl_trace_clear forgets the events
abl_film_bones 0|1  blood film drawn with the bones the body itself was drawn with (1), or as before (0), to compare
abl_debug_hud 1   statistics HUD
abl_flow_view <n> the flowing blood in false colour: 1 thickness, 2 velocity, 3 wetness, 4 age / clotting, 5 driving pressure,
                  6 mass, 7 surface normal, 8 flow path, 9 source (0 off)
abl_flow_core 0|1 blood on bodies and walls as a continuous liquid (1), or the older beads and streaks (0)
abl_flow_legacy 0|1   (needs abl_dev 1) the older model for the character under the crosshair, to compare
abl_profiler 1    profiler panel: flow counts, solver rate, the blood-volume books
abl_stats         print statistics
abl_zcity_status  Z-City: what of its blood visuals is taken over, what was caught, what still shows
abl_clear         remove all blood (client)
abl_spray <speed> <count> [ml]   (needs abl_dev 1) spray droplets along your aim for surface tests]])
end)

concommand.Add("abl_stats", function()
	local TM = ABL.Timing
	print(string.format("sources %d droplets %d particles %d overlays %d pools %d runoff %d blobs %d", #ABL.Sources.list, ABL.Drops.Count(), ABL.Drops.ParticleCount(), ABL.Stains.Count(), ABL.Pools.Count(), ABL.Runoff.Count(), ABL.Flow.count))
	print(string.format("sim %.3f ms draw %.3f ms LOD scale %.2f", TM.sim, TM.draw, L.scale))
	for k, m in pairs(ABL.BodyMesh.cache) do
		print("mesh", k, m.ready and ("ready " .. m.nv .. "v " .. m.nt .. "t") or (m.failed and "FAILED" or "building"))
	end
end)

-- Test sprayer for surface behaviour (walls, ceilings, slopes). Client-side only.
concommand.Add("abl_spray", function(ply, _, args)
	if not C.sv.dev:GetBool() then print("abl_spray requires abl_dev 1") return end
	local speed = tonumber(args[1]) or 250
	local count = tonumber(args[2]) or 20
	local vol = tonumber(args[3]) or 0.05
	local pos = ply:EyePos()
	local dir = ply:GetAimVector()
	local rng = ABL.RNG(math.floor(CurTime() * 1000))
	for _ = 1, count do
		local dx, dy, dz = ABL.Emission.Cone(rng, dir.x, dir.y, dir.z, 0.12)
		local s = speed * rng:Range(0.85, 1.15)
		ABL.Drops.Spawn(pos.x + dir.x * 8, pos.y + dir.y * 8, pos.z + dir.z * 8, dx * s, dy * s, dz * s, vol * rng:Range(0.6, 1.4), nil, 0, 0)
	end
end)
