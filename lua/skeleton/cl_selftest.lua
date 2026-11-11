-- Client half of the skeleton module's test scenes (developer tool). Inert unless the test harness
-- is running (lua/advancedblood/client/cl_selftest.lua). What it measures goes to the harness's
-- client log.

local SK = HemoSkeleton
SK.NoJIT()
if not SK.testRun then return end
local T = istable(ABL) and ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local G, D, V, CL, ST, R, P, M, C = SK.Geo, SK.Draw, SK.View, SK.CL, SK.Stock, SK.Rig, SK.Pose, SK.M, SK.Config
local BM = ABL.BodyMesh

local function L(fmt, ...) Log("skel: " .. string.format(fmt, ...)) end

local function Body(idx)
	local ent = Entity(idx or 0)
	if not IsValid(ent) then return nil end
	return SK.BodyOf(ent)
end

-- the registry on this side, against the server's
function H.skelreg(t)
	local bad = SK.Check()
	L("registry: %d bones, %d joints, sum %d (the server's: %d): %s; %d complaint(s)", #SK.BoneList, #SK.JointList, SK.Sum(), t.sum or -1, SK.Sum() == t.sum and "the same list on both sides" or "NOT the same", #bad)
	for _, s in ipairs(bad) do L("   %s", s) end
	local n = 0
	for _ in pairs(SK.FitData or {}) do n = n + 1 end
	L("fit tables for %d model(s); geometry %s", n, G.state)
end

-- How a list of models resolves: its bones looked up on a clientside copy.
function H.skelmodels(t)
	for _, path in ipairs(t.models) do
		if not file.Exists(path, "GAME") then
			L("model %s: no such file on this machine", path)
		else
			local cs = ClientsideModel(path)
			if IsValid(cs) then
				cs:SetNoDraw(true)
				cs:SetupBones()
				local prof = R.ResolveWith(path, function(name) return cs:LookupBone(name) end)
				local n = cs:GetBoneCount()
				cs:Remove()
				for i, line in ipairs(R.Describe(prof)) do L("model %s%s", i == 1 and string.format("(%d bones) ", n) or "   ", line) end
			end
		end
	end
end

-- The skeleton of a body against that body's own surface in the pose it is in. A corner of a unit,
-- carried to the world with the unit's matrix, is outside when it lies beyond the body's outermost
-- surface on the line that leads out through it from the axis of the animation bone that carries
-- the unit (from the middle of the head, for the head). The surface is the body's own mesh as it is
-- skinned now (the blood module's surface model: its outermost outward-facing surface on a line,
-- which is what a wound is put on; clothes are part of it).
local AXIS_TO = setmetatable({ pelvis = "spine_low", spine_top = "neck" }, { __index = P.CHILD })
local function Origin(body, prof, key)
	local idx = key and R.BoneOf(prof, key)
	local m = idx and body:GetBoneMatrix(idx)
	return m and m:GetTranslation() or nil
end
local function Axis(body, prof, key)
	-- (a part of a bone's load, the lower jaw or a pair of ribs, is looked at from its bone's axis)
	key = P.PART[key] or key
	if key == "head" then
		local m = prof.bone.head and body:GetBoneMatrix(prof.bone.head)
		if not m then return nil end
		local c = SK.Cranial.rest.c
		local p = Vector(M.Xf(M.Mul(M.FromMatrix(m), ST.rest.head), c[1], c[2], c[3]))
		return p, p
	end
	local a = Origin(body, prof, key)
	if not a then return nil end
	if string.sub(key, 1, 3) == "toe" then
		local f = Origin(body, prof, "foot" .. string.sub(key, 4))
		return a, f and (a + (a - f)) or a
	end
	return a, Origin(body, prof, AXIS_TO[key]) or a
end

local function Measure(body, useFit, every)
	local mesh = BM.Get(body)
	if not mesh or G.state ~= "ready" or G.coarse then return nil end
	local bp = BM.NewPose()
	bp:Bind(body, mesh)
	bp:Begin(FrameNumber())
	local was = P.noFit
	P.noFit = not useFit
	P.gen = P.gen + 1
	local pose = SK.PoseOf(body)
	if not pose then P.noFit = was P.gen = P.gen + 1 return nil end
	pose:Fresh()
	local n, o10, o25, o50, o100, open, worst, worstUnit = 0, 0, 0, 0, 0, 0, 0, "-"
	local byKey = {}
	for _, uid in ipairs(G.order) do
		local u = G.units[uid]
		local rows = pose:Carry(u.carry, u.c[1], u.c[2], u.c[3])
		-- the animation bone that carries most of it
		local key, kw = nil, -1
		for _, cw in ipairs(u.carry) do if cw[2] > kw then key, kw = cw[1], cw[2] end end
		local bone = R.BoneOf(pose.prof, key)
		local a, b = Axis(body, pose.prof, key)
		if rows and bone and a then
			local acc = byKey[key]
			if not acc then acc = { n = 0, o = 0 } byKey[key] = acc end
			local ab = b - a
			local ab2 = ab:LengthSqr()
			for i = 1, #u.pts, every or 3 do
				local p = u.pts[i]
				local w = Vector(M.Xf(rows, p[1], p[2], p[3]))
				-- the way out: from the nearest place on the axis through the corner
				local t = ab2 > 1e-6 and math.Clamp((w - a):Dot(ab) / ab2, 0, 1) or 0
				local d = w - (a + ab * t)
				local len = d:Length()
				n = n + 1
				acc.n = acc.n + 1
				if len > 0.2 then
					d = d / len
					local tri, uu, vv = BM.AnchorOuter(bp, bone, w.x, w.y, w.z, d.x, d.y, d.z, 6)
					if tri then
						local ax, ay, az, bx, by, bz, cx, cy, cz = bp:Tri(tri)
						local sx, sy, sz = ax + uu * (bx - ax) + vv * (cx - ax), ay + uu * (by - ay) + vv * (cy - ay), az + uu * (bz - az) + vv * (cz - az)
						local out = (w.x - sx) * d.x + (w.y - sy) * d.y + (w.z - sz) * d.z
						if out > 0.1 then o10 = o10 + 1 end
						if out > 0.25 then o25 = o25 + 1 end
						if out > 0.5 then o50 = o50 + 1 acc.o = acc.o + 1 end
						if out > 1 then o100 = o100 + 1 end
						if out > worst then worst, worstUnit = out, uid end
					else
						open = open + 1
					end
				end
			end
		end
	end
	P.noFit = was
	P.gen = P.gen + 1
	local keys = {}
	for key, acc in pairs(byKey) do if acc.o > 0 then keys[#keys + 1] = string.format("%s %.0f%%", key, 100 * acc.o / acc.n) end end
	table.sort(keys)
	local k = 100 / math.max(n, 1)
	return { n = n, o10 = o10 * k, o25 = o25 * k, o50 = o50 * k, o100 = o100 * k, open = open * k, worst = worst, worstUnit = worstUnit, keys = table.concat(keys, ", ") }
end
-- { ent, tag }: measured as soon as the body's surface model and the geometry are there.
function H.skelfit(t)
	local tries = 0
	local function Try()
		local body = Body(t.ent)
		if not IsValid(body) then L("fit %s: no body", tostring(t.tag)) return end
		G.Request()
		if G.state ~= "ready" then G.Step(20) end
		local a = Measure(body, false, t.every)
		local b = a and Measure(body, true, t.every)
		if not b then
			tries = tries + 1
			if tries < 60 then timer.Simple(0.1, Try) else L("fit %s: no measure (surface model %s, geometry %s)", tostring(t.tag), tostring(BM.Get(body) ~= nil), G.state) end
			return
		end
		local pose = SK.PoseOf(body)
		L("fit %s | %s | fit %s | corners %d | outside the body by more than 0.5: as it is %.1f %%, fitted %.1f %% | more than 0.1: %.1f -> %.1f %% | more than 0.25: %.1f -> %.1f %% | more than 1: %.1f -> %.1f %% | furthest %.2f -> %.2f (%s) | no surface on the way out: %.1f %% | where (fitted, >0.5): %s",
			tostring(t.tag), string.match(body:GetModel() or "?", "([^/]+)%.mdl$") or "?", pose and pose.fit.src or "?", b.n, a.o50, b.o50, a.o10, b.o10, a.o25, b.o25, a.o100, b.o100, a.worst, b.worst, b.worstUnit, b.open, b.keys ~= "" and b.keys or "nowhere")
	end
	Try()
end

-- What the view has under the crosshair, and what it shows.
function H.skelhover(t)
	local h = V.hover
	L("hover %s: %s%s | targets %d | geometry %s | watched %d | records taken %d", tostring(t.tag), h and h.id or "nothing", t.want and (h and h.id == t.want and " (as aimed)" or (" (aimed at " .. t.want .. ")")) or "",
		#V.targets, G.state, table.Count(CL.watched), CL.taken)
	if h and t.lines then for _, l in ipairs(V.BoneLines(h.body, h.id)) do L("   %s", l) end end
end

-- A body's record as this client has it.
function H.skelrec(t)
	local body = Body(t.ent)
	local rec = IsValid(body) and CL.Record(body)
	if not rec then L("record %s: none on this client for %s", tostring(t.tag), tostring(body)) return end
	local parts = {}
	local list = {}
	for idx in pairs(rec.bones) do list[#list + 1] = idx end
	table.sort(list)
	for _, idx in ipairs(list) do
		local e = rec.bones[idx]
		parts[#parts + 1] = string.format("%s=%s/%d%s", SK.BoneByIdx[idx].id, C.StateName[e.state], e.integrity, e.site and string.format("@%.2f", e.site) or "")
	end
	local js = {}
	for jid in pairs(rec.joints) do js[#js + 1] = jid end
	L("record %s: %s version %d, %d bone(s): %s%s", tostring(t.tag), tostring(body), rec.ver, rec.n, table.concat(parts, " "), #js > 0 and (" | joints: " .. table.concat(js, " ")) or "")
end

-- Where this client has some bones of a body, for the server's answer to be held against (the two
-- sides work out a pose each from the entity they have).
function H.skelwhere(t)
	local body = Body(t.ent)
	if not IsValid(body) then return end
	local pose = SK.PoseOf(body)
	if not pose then L("where %s: no pose", tostring(t.tag)) return end
	pose:Fresh()
	local list, sum, n = {}, 0, 0
	for id, sp in pairs(t.pos) do
		local x, y, z = pose:BonePos(id)
		if x then
			local d = math.sqrt((x - sp.x) ^ 2 + (y - sp.y) ^ 2 + (z - sp.z) ^ 2)
			sum, n = sum + d, n + 1
			list[#list + 1] = { id = id, d = d }
		end
	end
	table.sort(list, function(a, b) return a.d > b.d end)
	local top = {}
	for i = 1, math.min(5, #list) do top[i] = string.format("%s %.2f", list[i].id, list[i].d) end
	L("where %s: %d bones, server and client apart by %.2f units on average, the middle one by %.2f; furthest: %s", tostring(t.tag), n, sum / math.max(n, 1), list[math.ceil(#list / 2)] and list[math.ceil(#list / 2)].d or 0, table.concat(top, ", "))
	-- and the same paths through the body, asked here
	if t.segs then
		local same, differ, hitsHere, hitsThere, aimed, aimedHere = 0, 0, 0, 0, 0, 0
		for _, s in ipairs(t.segs) do
			local hits = SK.Trace(pose, s.a, s.b) or {}
			local here = {}
			for _, h in ipairs(hits) do here[h.id] = true hitsHere = hitsHere + 1 end
			-- the bone the path was aimed through: on it for the server, and for this client?
			local there = false
			for _, id in ipairs(s.ids) do if id == s.want then there = true end end
			if there then
				aimed = aimed + 1
				if here[s.want] then aimedHere = aimedHere + 1 end
			end
			local ok = true
			for _, id in ipairs(s.ids) do hitsThere = hitsThere + 1 if not here[id] then ok = false end here[id] = nil end
			if next(here) ~= nil then ok = false end
			if ok then same = same + 1 else differ = differ + 1 end
		end
		L("paths %s: %d paths aimed through a bone as the server has it: the server's skeleton has that bone on %d of them, and this client's has it on %d of those; every bone met is the same on both sides for %d of %d (the server's met %d bones in all, this client's %d)",
			tostring(t.tag), same + differ, aimed, aimedHere, same, same + differ, hitsThere, hitsHere)
	end
end

-- What the view costs: its drawing a frame over a stretch of time, and a thousand queries.
function H.skelperf(t)
	local frames, ms, units, bodies = 0, 0, 0, 0
	local t0 = RealTime()
	local ft = 0
	hook.Add("PostRender", "SK_TestPerf", function()
		local s = D.stats
		if s.frame == FrameNumber() then ms, units, bodies = ms + s.ms, units + s.units, bodies + s.bodies end
		frames = frames + 1
		ft = ft + FrameTime()
		if RealTime() - t0 >= (t.secs or 2) then
			hook.Remove("PostRender", "SK_TestPerf")
			L("cost %s: over %d frames (%.1f ms a frame): %.1f skeleton(s), %.0f units, %.2f ms of drawing a frame", tostring(t.tag), frames, 1000 * ft / math.max(frames, 1), bodies / math.max(frames, 1), units / math.max(frames, 1), ms / math.max(frames, 1))
		end
	end)
end

function H.skelquery(t)
	local body = Body(t.ent)
	local pose = IsValid(body) and SK.PoseOf(body)
	if not pose then return end
	pose:Fresh()
	local c = body:WorldSpaceCenter()
	local n, hits = t.n or 1000, 0
	local t0 = SysTime()
	for i = 1, n do
		-- (through the middle of the body, from any side)
		local d = VectorRand():GetNormalized()
		local a = c + d * 40 + VectorRand() * 8
		local b = c - d * 40 + VectorRand() * 8
		local h = SK.Trace(pose, a, b)
		hits = hits + #h
	end
	local ms = (SysTime() - t0) * 1000
	L("queries %s: %d paths through the middle of a body in %.1f ms (%.3f ms each), %.1f bones met a path; meshes %d, memory %.1f MB", tostring(t.tag), n, ms, ms / n, hits / n, #G.order, collectgarbage("count") / 1024)
end

function H.skelstate(t)
	local n = 0
	for _, u in pairs(G.units) do if u.mesh then n = n + 1 end end
	L("state %s: geometry %s (%s), %d meshes; view targets %d; watched %d; records here %d; lua memory %.1f MB", tostring(t.tag), G.state, G.note, n, #V.targets, table.Count(CL.watched), table.Count(CL.records), collectgarbage("count") / 1024)
end

-- what the brain module's atlas has under each skull bone
function H.skelbrain()
	if not SK.Brain.Available() then L("brain: the brain module is not loaded") return end
	local total = 0
	for _, id in ipairs(SK.BonesOf("skull")) do
		local under = SK.Brain.RegionsUnder(id)
		if #under > 0 then
			total = total + #under
			local lobes = {}
			for _, rid in ipairs(under) do local r = NeuroTrauma.Atlas.regions[rid] lobes[r.lobe] = (lobes[r.lobe] or 0) + 1 end
			local parts = {}
			for lobe, k in pairs(lobes) do parts[#parts + 1] = k .. " " .. lobe end
			table.sort(parts)
			L("brain: under the %s: %d cortical region(s) of the atlas (%s)", id, #under, table.concat(parts, ", "))
		end
	end
	local cortical = 0
	for _, r in pairs(NeuroTrauma.Atlas.regions) do if r.kind == "C" then cortical = cortical + 1 end end
	L("brain: %d of the atlas's %d cortical regions lie under a named skull bone", total, cortical)
end

-- A place on a bone of a body, in the world: the middle of the middle solid of its proxy, or for a
-- bone of the skull one of its seeds on the skull's outside; else its middle.
local function PointOn(pose, id)
	local st = ST.bones[id]
	local rows = st and pose:Bone(id)
	if not rows then return nil end
	local x, y, z = st.c[1], st.c[2], st.c[3]
	if istable(st.proxy) then
		local s = st.proxy[math.ceil(#st.proxy / 2)]
		if s[1] == "c" then x, y, z = (s[2] + s[5]) / 2, (s[3] + s[6]) / 2, (s[4] + s[7]) / 2 else x, y, z = s[2], s[3], s[4] end
	elseif st.proxy == "shell" then
		for _, sd in ipairs(ST.cranial.seeds) do
			if sd[1] == id then x, y, z = SK.Cranial.FromHead(sd[2], sd[3], sd[4]) break end
		end
	end
	return Vector(M.Xf(rows, x, y, z))
end

-- { ent, bone, dir (world: from the bone toward the camera), dist }: the test camera looks at a bone.
function H.skelaim(t)
	local body = Body(t.ent)
	local pose = IsValid(body) and SK.PoseOf(body)
	if not pose then L("aim: no pose for %s", tostring(body)) return end
	pose:Fresh()
	local p = PointOn(pose, t.bone)
	if not p then L("aim: no place for %s", tostring(t.bone)) return end
	local dir = Vector(t.dir.x, t.dir.y, t.dir.z)
	dir:Normalize()
	local cam = p + dir * (t.dist or 40)
	H.view({ pos = cam, ang = (p - cam):Angle() })
end
-- How often, and for what, the scene is drawn in one frame (the view draws in each pass that is
-- neither a depth pass nor the sky's).
function H.skelpasses(t)
	local frame, lines, frames = -1, {}, 0
	hook.Add("PostDrawTranslucentRenderables", "SK_TestPasses", function(depth, sky, sky3d)
		local f = FrameNumber()
		if f ~= frame then
			if #lines > 0 then
				frames = frames + 1
				if frames == 3 then
					hook.Remove("PostDrawTranslucentRenderables", "SK_TestPasses")
					L("passes %s: %d call(s) in one frame: %s | the view drew in %d of them; what is looked at was asked of %s", tostring(t.tag), #lines, table.concat(lines, " ; "), V.passes, tostring(V.eyeFrom))
					return
				end
			end
			frame, lines = f, {}
		end
		local rt = render.GetRenderTarget()
		-- (how far this drawing's eye is from the main view's: a reflection's is mirrored in the water)
		local eye = V.Eye()
		lines[#lines + 1] = string.format("depth %s sky %s target %s, its eye %.0f units from the main view's", tostring(depth), tostring(sky), rt and rt:GetName() or "the screen", EyePos():Distance(eye))
	end)
end

------------------------------------------------------------------------------------------
-- The head: the fitting view driven by a scene, and what can be measured of skull and brain
------------------------------------------------------------------------------------------
-- { ent, cam (side, front, back, top, quarter: the fitting view's own places, taken once and held by
-- the harness's camera, which owns the view in a test), dist, fov, follow (the camera goes with the
-- head's place, turned as it was when asked for), nofit (the fit off or on), log (a name: the view's
-- own lines into the log) }
local HV = SK.HeadView
local followCam
hook.Add("Think", "SK_TestHeadFollow", function()
	local f = followCam
	if not f then return end
	if not IsValid(f.body) then followCam = nil return end
	local c = HV.Frame(f.body)
	if c then H.view({ pos = c + f.off, ang = f.ang, fov = f.fov }) end
end)
function H.skelhead(t)
	local body = Body(t.ent)
	if not IsValid(body) then L("head: no body %s", tostring(t.ent)) return end
	HV.target, HV.pinned = body, true
	followCam = nil
	if t.nofit ~= nil then P.noFit = t.nofit and true or false P.gen = P.gen + 1 end
	if t.cam then
		local pos, ang = HV.CamAt(body, t.cam, t.dist)
		if pos then
			local fov = t.fov or C.HeadView.fov
			H.view({ pos = pos, ang = ang, fov = fov })
			if t.follow then
				local c = HV.Frame(body)
				followCam = { body = body, off = pos - c, ang = ang, fov = fov }
			end
		else
			L("head: no camera %s by %s", tostring(t.cam), tostring(body))
		end
	end
	if t.log then
		for _, l in ipairs(HV.Lines(body)) do L("head %s: %s", tostring(t.log), l) end
	end
end

-- { cmd, args }: a console command of the fitting view, with its arguments one by one; and what the
-- head's numbers are after it.
function H.skelheadcmd(t)
	RunConsoleCommand(t.cmd, unpack(t.args or {}))
	timer.Simple(0.2, function()
		local body = HV.target
		local pose = IsValid(body) and SK.PoseOf(body)
		if not pose then L("head command %s: no body", tostring(t.cmd)) return end
		local p = SK.HeadFit.For(pose.prof.model)
		L("head command %s %s: %s is now %s | skull side %.4f up %.4f, brain k %.4f u %.4f | the fit the pose holds has the skull's map: %s",
			tostring(t.cmd), table.concat(t.args or {}, " "), p.model, p.src, p.skull.side, p.skull.up, p.brain.k, p.brain.u,
			pose.fit.keys.head and string.format("%.4f across, %.4f moved along the bone", pose.fit.keys.head[11], pose.fit.keys.head[4]) or "none")
	end)
end

-- What the fitting view holds: its body, the bodies whose own drawing it has taken over, its switches.
function H.skelheadstate(t)
	local held = 0
	for _, e in ipairs(ents.GetAll()) do if e.SK_headOverride and e.RenderOverride == e.SK_headOverride then held = held + 1 end end
	local B3 = istable(NeuroTrauma) and NeuroTrauma.Brain3D
	L("head view %s: skel_head %s, show %s, body %s, cam %s | its body: %s | bodies whose drawing it holds: %d | the brain drawn by the brain module at: %s | its own drawing in heads: %.2f ms a frame for %s head(s) | geometry %s",
		tostring(t.tag), GetConVar("skel_head"):GetString(), GetConVar("skel_head_show"):GetString(), GetConVar("skel_head_body"):GetString(), GetConVar("skel_head_cam"):GetString(),
		tostring(HV.target), held, tostring(B3 and B3.worldFit), B3 and B3.worldMs or -1, tostring(B3 and B3.worldHeads), G.state)
end

-- The brain's own surface against the skull's, in a body's head as it is drawn. Rays from outside
-- inward find the brain's outside on the brain module's own surfaces (its own arithmetic, the meshes
-- that are drawn); each such place is carried into the head as the brain is drawn there
-- (sh_headfit.lua), from there back into the stock skull, and held against that skull's outside
-- less the thickness its bone is given. Only what faces the vault: the brain's underside lies on
-- the skull's base, which the shell does not say.
function H.skelbrainfit(t)
	local tries = 0
	local function Try()
		local body = Body(t.ent)
		local pose = IsValid(body) and SK.PoseOf(body)
		local BS = istable(NeuroTrauma) and NeuroTrauma.BrainSurf
		if not pose or not BS or not BS.Has("cortex") then
			tries = tries + 1
			if tries < 80 then timer.Simple(0.25, Try) else L("brain fit %s: no body, or the brain's surfaces are not built", tostring(t.tag)) end
			return
		end
		local HF, CR = SK.HeadFit, SK.Cranial
		local function Run(p, label)
			local m, k = p.m2, p.skull
			local det = m[1] * m[4] - m[2] * m[3]
			local n, wall, out, least, sum, at = 0, 0, 0, 1e9, 0, "-"
			for i = 0, 35 do
				for j = 0, 9 do
					local az, el = i / 36 * 2 * math.pi, math.rad(-8 + j * 10.5)
					local dx, dy, dz = math.cos(el) * math.sin(az), math.cos(el) * math.cos(az), math.sin(el)
					local hit = BS.Ray("cortex", "B", dx * 3, dy * 3, 0.15 + dz * 3, -dx, -dy, -dz)
					if hit and hit < 3 then
						local s, f, u = HF.Brain(p, dx * (3 - hit), dy * (3 - hit), 0.15 + dz * (3 - hit))
						-- the skull's fit undone: where that place is in the stock skull
						local ff, uu = f - k.fwd, u - k.up
						local qs, qf, qu = s / k.side, (m[4] * ff - m[2] * uu) / det, (-m[3] * ff + m[1] * uu) / det
						local bone = CR.FromDir(qs, qf, qu)
						local room = CR.Radius(qs, qf, qu) - math.sqrt(qs * qs + qf * qf + qu * qu)
						n = n + 1
						sum = sum + room
						if room < 0 then out = out + 1 end
						if bone and room < CR.Thick(bone) then wall = wall + 1 end
						if room < least then least, at = room, string.format("%s, %d degrees round from the face, %d up", tostring(bone), i * 10, -8 + j * 10.5) end
					end
				end
			end
			L("brain fit %s | %s | %s: brain %.3f units a mesh unit, centre %.2f toward the face and %.2f up, pitch %.1f | %d places on the brain's outside that face the vault: outside the skull's outside %d (%.1f %%), within the bone's thickness %d (%.1f %%); room to the skull's outside %.2f on the whole, least %.2f (%s)",
				tostring(t.tag), string.match(body:GetModel() or "?", "([^/]+)%.mdl$") or "?", label, p.brain.k, p.brain.f, p.brain.u, p.brain.pitch, n, out, 100 * out / math.max(n, 1), wall, 100 * wall / math.max(n, 1), sum / math.max(n, 1), least, at)
		end
		local p = HF.For(pose.prof.model)
		Run(p, "as it is drawn now (" .. p.src .. ")")
		-- the same skull with the brain where the brain module put it on its own: its own size at the frame's origin
		local was = { k = p.brain.k, f = p.brain.f, u = p.brain.u, pitch = p.brain.pitch }
		p.brain.k, p.brain.f, p.brain.u, p.brain.pitch = 0.86 * 3, 0, 0, 0
		Run(p, "the brain at the brain module's own place and size, in the same skull")
		p.brain.k, p.brain.f, p.brain.u, p.brain.pitch = was.k, was.f, was.u, was.pitch
	end
	Try()
end
