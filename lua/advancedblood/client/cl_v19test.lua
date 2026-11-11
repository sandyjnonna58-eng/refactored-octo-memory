-- Client half of phase 19's scenes (server/sv_v19test.lua; developer tool, inert unless the test
-- harness is running, see cl_selftest.lua). What phase 19 changed is judged by reading the picture
-- and the canvases back: numbers that can be judged log PASS or FAILED (tools/harness/harness.ps1
-- greps them), the rest is logged beside the pictures.
--   v19begin, v19end  what the scenes change (convars, C.V19) kept and put back; a watch on canvases
--                     that stay in their first painting ("snap") for longer than they should
--   v19stats          the film's outline counters since the last asking (its outline's, its liquid's)
--                     and the in-between pictures made for the films nearest the eye
--   v19paint          what painting costs over a few seconds, with the bleeding bodies near the eye
--   v19mark           the camera on a body's newest wound opening (kept for the probe "opening")
--   v19burst          a burst of PNG frames of the middle of the screen (cl_selftest.lua's burst)
--   v19probe          read back: kind "b2" (the liquid's surface at twice the size), "copy" (an exact
--                     copy of a canvas), "ratio" (the liquid against the stain in a run), "opening"
--                     (the blood in a wound's opening), "pool" (a pool against the film where they
--                     join), "pendant" (a drop that hangs against the film beside it)
--   v19dolly          the camera drawn along a line from a body or toward it, the passes its film is
--                     drawn with counted, and how much its liquid's brightness steps where they change
-- Every access to what phase 19 adds elsewhere (D.stats.enterL, D.stats.lerps, D.b2Bad, the canvases'
-- B2 and previous pictures, ABL.FilmPendant, C.V19) is guarded: what is not there is said so.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local C = ABL.Config
local K = C.Film
local floor, min, max, sqrt, abs = math.floor, math.min, math.max, math.sqrt, math.abs

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

-- A number that can be judged: PASS or FAILED. judge false: logged as a reference only (J(on): nil,
-- judged, when on; false when not).
local function J(on) if on then return nil end return false end
local function Check(ok, what, detail, judge)
	if judge == false then
		Log(string.format("v19 %s (for comparison): %s", what, detail))
	else
		Log(string.format("%s v19 %s: %s", ok and "PASS" or "FAILED", what, detail))
	end
end

local function Luma(r, g, b) return 0.299 * r + 0.587 * g + 0.114 * b end
-- (a pixel of blood: red well over green and blue)
local function Bloody(r, g, b) return r >= 12 and r >= 1.6 * g and r >= 1.6 * b end
local function Median(list, n)
	if n == 0 then return nil end
	table.sort(list, function(a, b) return a < b end)
	if n % 2 == 1 then return list[(n + 1) / 2] end
	return 0.5 * (list[n / 2] + list[n / 2 + 1])
end

------------------------------------------------------------------------------------------
-- What the scenes change, kept and put back
------------------------------------------------------------------------------------------
local CVARS = { "abl_liquid_v19", "abl_film_full_near", "abl_film_gloss", "abl_film_layers", "abl_film_smooth" }
-- (the parts of phase 19 that can be switched, as sh_config.lua's C.V19 names them)
local PARTS = { "split", "b2", "surface", "ease", "depthTone", "feather", "lerp", "waves", "fade", "pendPaint", "touchByChange", "touchLiquidEdge",
	"fullIsWall", "pendant", "pendSpawn", "dropHyst", "poolModelLight", "poolDepthColour", "poolNoTint", "poolEdgePx", "woundBlotFade", "woundFade", "bindAtDeath" }
local keptCv, keptV19
local snapWatch

local function SetV19(key, v)
	local V = C.V19
	if not V then return end
	keptV19 = keptV19 or {}
	if keptV19[key] == nil then keptV19[key] = { v = V[key] } end
	V[key] = v
end

-- (what a look of v19look set, put back: H.v19look)
local keptLook
local function LookBack()
	if not keptLook then return end
	for k, v in pairs(keptLook.v19) do C.V19[k] = v.v end
	for k, v in pairs(keptLook.film) do C.Film[k] = v.v end
	keptLook = nil
end

local function PutBack()
	if keptCv then
		-- (set at once where it can be: a command is only queued, and a game being quit runs no more
		-- of them before its settings are saved. All of these are made in Lua, which SetString needs.)
		for name, v in pairs(keptCv) do
			local cv = GetConVar(name)
			if not (cv and cv.SetString and pcall(cv.SetString, cv, v)) then RunConsoleCommand(name, v) end
		end
		keptCv = nil
	end
	if keptV19 and C.V19 then
		for key, e in pairs(keptV19) do C.V19[key] = e.v end
	end
	keptV19 = nil
end
-- (a game that is quit in the middle of a scene keeps its convars: abl_liquid_v19 is saved with the
-- client's own settings)
hook.Add("ShutDown", "ABL_V19TestPutBack", PutBack)

local function V19On(name) return C.V19On ~= nil and C.V19On(name) end

function H.v19begin(t)
	keptCv = keptCv or {}
	for _, name in ipairs(CVARS) do
		if keptCv[name] == nil then
			local cv = GetConVar(name)
			if cv then keptCv[name] = cv:GetString() end
		end
	end
	-- (the watch on canvases in their first painting: how long each has been in it while its film is drawn)
	snapWatch = { acc = setmetatable({}, { __mode = "k" }), worst = 0, what = "none", slow = false }
	local on, off = {}, {}
	for _, name in ipairs(PARTS) do
		if C.V19 and C.V19[name] ~= nil then
			if V19On(name) then on[#on + 1] = name else off[#off + 1] = name end
		end
	end
	local D = ABL.FilmDraw
	local cv = GetConVar("abl_liquid_v19")
	Log(string.format("v19begin %s | abl_liquid_v19 %s | on: %s | off: %s | B2 turned off by its probe %s | pendants %s | render.CopyTexture %s",
		tostring(t.name), cv and cv:GetString() or "?", #on > 0 and table.concat(on, " ") or "none", #off > 0 and table.concat(off, " ") or "none",
		D and tostring(D.b2Bad or false) or "?", (ABL.FilmPendant and ABL.FilmPendant.Draw) and "there" or "not there", tostring(render.CopyTexture ~= nil)))
end

local UnwrapOverlay
local dolly
local readers = {}

function H.v19end(t)
	local w = snapWatch
	snapWatch = nil
	if w then
		Check(w.worst <= 2, "snap", string.format("the longest a canvas stayed in its first painting while its film was drawn: %.2f s (%s)%s; 2 s allowed",
			w.worst, w.what, w.slow and ", the game's time slowed meanwhile" or ""))
	end
	if UnwrapOverlay then UnwrapOverlay() end
	dolly = nil
	for i = #readers, 1, -1 do readers[i] = nil end
	LookBack()
	PutBack()
	Log("v19end " .. tostring(t and t.name))
end

hook.Add("Think", "ABL_V19SnapWatch", function()
	local w = snapWatch
	if not w then return end
	local rt = RealTime()
	local dt = math.min(RealFrameTime(), 0.1)
	local slow = game.GetTimeScale and game.GetTimeScale() < 0.99
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s and s.tx and s.drawT and rt - s.drawT < 0.1 then
			for k, tx in pairs(s.tx) do
				if type(tx) == "table" then
					-- (only a canvas taken under phase 19's rule for it has snapT: one taken with
					-- abl_liquid_v19 0, in a scene's other half, keeps the old rule and is not judged here)
					if tx.snap and tx.snapT then
						local a = (w.acc[tx] or 0) + dt
						w.acc[tx] = a
						if a > w.worst then
							w.worst = a
							w.what = string.format("map %s of %s", tostring(s.ch and s.ch.mats[k] and s.ch.mats[k].name or k), tostring(src.body))
							if slow then w.slow = true end
						end
					else
						w.acc[tx] = nil
					end
				end
			end
		end
	end
end)

------------------------------------------------------------------------------------------
-- Counters
------------------------------------------------------------------------------------------
-- The film's outline counters since the last asking (this or cl_filmtest.lua's filmstats: both
-- start them again), the liquid's own (phase 19, cl_filmdraw.lua), and the in-between pictures made.
function H.v19stats(t)
	local D = ABL.FilmDraw
	local ds = D and D.stats
	if not ds then Log("v19stats: no film painter") return end
	local films, near, nearKnown, filling, full = 0, 0, false, 0, 0
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s then
			films = films + 1
			if s.v19near ~= nil then nearKnown = true end
			if s.v19near then near = near + 1 end
			if s.filling then filling = filling + 1 end
			if s.fullLook then full = full + 1 end
		end
	end
	local liquid = ds.enterL ~= nil and string.format("%d rose, %d fell, the most %.3f", ds.enterL or 0, ds.leaveL or 0, ds.jumpL or 0) or "not counted in this build"
	local pf, pfPeak = ABL.Prof.Get("draw.filmpaint")
	local pl = ABL.Prof.Get("draw.filmpaint.lerp")
	local cv = GetConVar("abl_liquid_v19")
	Log(string.format("v19stats %s | abl_liquid_v19 %s | the film's outline: %d texels rose past it, %d fell back, the most a texel changed %.3f | the liquid's: %s | in-between pictures made %s | painting %.3f ms a frame (%.3f at the most, %.3f of it in-between pictures), all painting %.3f ms | films %d: drawn in full %d, near %s, still filling %d | B2 off by its probe %s",
		tostring(t.name), cv and cv:GetString() or "?", ds.enter or 0, ds.leave or 0, ds.jump or 0, liquid, ds.lerps ~= nil and tostring(ds.lerps) or "not counted in this build",
		pf, pfPeak, pl, ABL.Timing.paint or 0, films, full, nearKnown and tostring(near) or "?", filling, tostring(D.b2Bad or false)))
	ds.enter, ds.leave, ds.jump = 0, 0, 0
	if ds.enterL ~= nil then ds.enterL, ds.leaveL, ds.jumpL = 0, 0, 0 end
	if ds.lerps ~= nil then ds.lerps = 0 end
end

-- What painting costs (ABL.Timing.paint: the pools' and the films' canvases, smoothed) over t.secs
-- seconds, and the bleeding bodies within t.near units of the eye. t.limit: PASS when no more on
-- average, with t.bodies of them there at least.
local paintRun
-- A camera on the place of a body's film where the most blood waits to drop (s.out): from the side
-- the skin faces there, level, t.dist units off, t.fov wide. Without such a place, t.fallback is
-- passed to H.v19mark. (The film's own camera framed the side of a sleeve away from its run in run p19b.)
function H.v19pendcam(t)
	local src = SourceOf(t.ent)
	local s = src and src.film
	local best, bv = nil, 0
	if s and s.out then
		for c, v in pairs(s.out) do
			if v > bv and (s.outT == nil or (s.outT[c] or 0) >= 0) then best, bv = c, v end
		end
	end
	if not (best and src.pose and s.tt and s.tt[best]) then
		Log("v19pendcam: nothing waits to drop on " .. tostring(src and src.body))
		if t.fallback then H.v19mark(t.fallback) end
		return
	end
	local was = src.pose.frame
	src.pose:Begin(FrameNumber())
	local x, y, z, nx, ny, nz = src.pose:Point(s.tt[best], s.bu[best], s.bv[best])
	if was ~= nil then src.pose:Begin(was) end
	local p = Vector(x, y, z)
	-- (level: the skin's way out with its up part taken away, or a side of it where it faces up or down)
	local h = Vector(nx, ny, 0)
	if h:LengthSqr() < 0.04 then h = Vector(-ny, nx, 0) end
	if h:LengthSqr() < 0.01 then h = Vector(1, 0, 0) end
	h:Normalize()
	local d = t.dist or 9
	local eye = p + h * d + Vector(0, 0, d * 0.12)
	local tr = util.TraceLine({ start = p + h * 1.5, endpos = eye, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit then eye = tr.HitPos - h * 1.5 end
	H.view({ pos = eye, ang = (p - Vector(0, 0, 0.3) - eye):Angle(), fov = t.fov or 40, znear = 1 })
	Log(string.format("v19pendcam %s: cell %d, %.3f ml waiting, at %s, the eye %.1f units off", tostring(src.body), best, bv, tostring(p), eye:Distance(p)))
end

-- A look of the liquid's wet surface for the rest of the scene: t.v19 = { C.V19 key = value } (put back
-- at v19end), t.film = { C.Film key = value } (put back by H.clear), then every canvas's highlight
-- materials take the exponent and every film is painted anew (what a key changes in the painting, the
-- shine of a place, shows only in what is painted after it).
function H.v19wet(t)
	for k, v in pairs(t.v19 or {}) do SetV19(k, v) end
	for k, v in pairs(t.film or {}) do C.Film[k] = v end
	local D = ABL.FilmDraw
	local exp = C.V19.phongExp or C.Film.phongExp
	for _, c in ipairs(D and D.canvases or {}) do
		if c.shine then c.shine:SetFloat("$phongexponent", exp) end
		if c.lit then c.lit:SetFloat("$phongexponent", exp) end
	end
	if D and D.Repaint then D.Repaint() end
	Log(string.format("v19wet %s: phongExp %s, phongBoost %s, flatShine %s, rim %s, soakShine %s, deepScale %s", tostring(t.name),
		tostring(C.V19.phongExp), tostring(C.V19.phongBoost), tostring(C.V19.flatShine), tostring(C.V19.rim), tostring(C.Film.soakShine), tostring(C.V19.deepScale)))
end

-- One look of several of a scene (v19_stripeset): the values of C.V19 and C.Film in t.v19 and t.film,
-- each set over what the look before it set (put back first, LookBack), all of them put back at v19end
-- and, for C.Film, at the harness's clear. Blood already on a body keeps what its cells were made with:
-- the scene clears it before each look.
function H.v19look(t)
	LookBack()
	keptLook = { v19 = {}, film = {} }
	local said = {}
	for k, v in pairs(t.v19 or {}) do
		if keptLook.v19[k] == nil then keptLook.v19[k] = { v = C.V19[k] } end
		C.V19[k] = v
		said[#said + 1] = "V19." .. k .. " " .. tostring(v)
	end
	for k, v in pairs(t.film or {}) do
		if keptLook.film[k] == nil then keptLook.film[k] = { v = C.Film[k] } end
		C.Film[k] = v
		said[#said + 1] = "Film." .. k .. " " .. tostring(v)
	end
	table.sort(said)
	Log(string.format("v19look %s: %s", tostring(t.name), #said > 0 and table.concat(said, ", ") or "as configured"))
end

-- One part of phase 19 set for the rest of the scene (put back at v19end): { name, value }.
function H.v19set(t)
	if not (t and t.name) then return end
	SetV19(t.name, tonumber(t.value) or t.value)
	Log(string.format("v19set %s = %s", tostring(t.name), tostring(C.V19 and C.V19[t.name])))
end

function H.v19paint(t)
	paintRun = { t = t, t0 = RealTime(), n = 0, sum = 0, most = 0, fsum = 0, bodies = 0 }
end
hook.Add("Think", "ABL_V19Paint", function()
	local r = paintRun
	if not r then return end
	local v = ABL.Timing.paint or 0
	r.n = r.n + 1
	r.sum = r.sum + v
	if v > r.most then r.most = v end
	r.fsum = r.fsum + (ABL.Prof.Get("draw.filmpaint"))
	-- (bodies that bleed onto their films within the distance, the most seen at once)
	local nb = 0
	for _, src in ipairs(ABL.Sources.list) do
		if src.film and (src.dist or 1e9) < (r.t.near or 150) then
			for _, wd in ipairs(src.woundList) do
				if (wd.flow or 0) > 0 then nb = nb + 1 break end
			end
		end
	end
	if nb > r.bodies then r.bodies = nb end
	if RealTime() - r.t0 < (r.t.secs or 4) then return end
	paintRun = nil
	local t = r.t
	local mean = r.sum / math.max(r.n, 1)
	local detail = string.format("%.3f ms a frame on average over %d frames (%.3f at the most; the films' own %.3f), %d bleeding bodies within %d units",
		mean, r.n, r.most, r.fsum / math.max(r.n, 1), r.bodies, t.near or 150)
	if t.limit then
		local enough = r.bodies >= (t.bodies or 0)
		Check(enough and mean <= t.limit, "paint " .. tostring(t.name), detail .. string.format(" (%.2f ms allowed with %d of them)", t.limit, t.bodies or 0) .. (enough and "" or ": too few bodies"))
	else
		Check(true, "paint " .. tostring(t.name), detail, false)
	end
end)

------------------------------------------------------------------------------------------
-- Cameras and bursts
------------------------------------------------------------------------------------------
local marks = {}
-- The camera on the newest wound opening of entity t.ent, from t.dist units, t.tilt degrees off its
-- normal: set once, it does not follow.
function H.v19mark(t)
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then Log("v19mark: no source for " .. tostring(t.ent)) return end
	local best
	for _, mk in ipairs(src.marks or {}) do
		if (mk.cav or mk.hole) and mk.m == src.mesh and mk.tri and (not best or mk.born > best.born) then best = mk end
	end
	if not best then
		Log("v19mark: no wound opening on " .. tostring(src.body))
		-- (t.fallback: the camera of H.filmcam's arguments instead, so that the shot is of the film)
		if t.fallback and H.filmcam then H.filmcam(t.fallback) end
		return
	end
	if src.pose.mesh ~= src.mesh or best.tri > src.mesh.nt then Log("v19mark: its body has another surface model now") return end
	marks[t.ent] = best
	local was = src.pose.frame
	src.pose:Begin(FrameNumber())
	local x, y, z, nx, ny, nz = src.pose:Point(best.tri, best.u, best.v)
	if was ~= nil then src.pose:Begin(was) end
	local p, n = Vector(x, y, z), Vector(nx, ny, nz)
	local s2 = n:Cross(Vector(0, 0, 1))
	if s2:LengthSqr() < 0.01 then s2 = Vector(1, 0, 0) end
	s2:Normalize()
	local up2 = s2:Cross(n)
	local ti = math.rad(t.tilt or 28)
	local eye = p + (n * math.cos(ti) + (s2 * 0.6 + up2 * 0.8) * math.sin(ti)) * (t.dist or 11)
	local tr = util.TraceLine({ start = p + n * 1.5, endpos = eye, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit then eye = tr.HitPos - (eye - p):GetNormalized() * 1.5 end
	-- (t.below: units below the opening that the camera looks at, so that the run under it is in the picture)
	local at = p - Vector(0, 0, t.below or 0)
	H.view({ pos = eye, ang = (at - eye):Angle(), fov = t.fov or 34, znear = 1 })
	Log(string.format("v19mark %s: %s at %s, opening %s units, the eye %.1f units off", tostring(src.body), tostring(best.kind), tostring(p),
		best.cav and best.cav.R0 and string.format("%.2f", best.cav.R0) or "?", eye:Distance(p)))
end

-- A burst of PNG frames of a t.w x t.h part in the middle of the screen (what the cameras look at).
function H.v19burst(t)
	local w, h = t.w or 400, t.h or 400
	H.poolburst({ name = t.name, frames = t.frames or 60, every = t.every or 1, x = floor(ScrW() * 0.5 - w * 0.5), y = floor(ScrH() * 0.5 - h * 0.5), w = w, h = h, png = true })
end

------------------------------------------------------------------------------------------
-- Reading the picture back
------------------------------------------------------------------------------------------
-- A reader's project(r) runs in the 3D view of the player's picture (where Vector:ToScreen is that
-- view's), its read(r, ok) in the same frame's PostRender, after the finished picture is captured
-- (ok: the capture did not fail). read returns true to be called again in the next frame.
-- (the player's own view, not the water's mirrored one nor a camera's: as cl_lod.lua tells them)
local function MainView()
	local vs = render.GetViewSetup()
	if not vs then return false end
	if vs.width and vs.height and (vs.width ~= ScrW() or vs.height ~= ScrH()) then return false end
	local rt = render.GetRenderTarget()
	if rt and string.find(string.lower(rt:GetName()), "_rt_water", 1, true) then return false end
	return true
end

hook.Add("PostDrawTranslucentRenderables", "ABL_V19Project", function(depth, sky, sky3d)
	if depth or sky or sky3d or not readers[1] then return end
	if not MainView() then return end
	local f = FrameNumber()
	for i = #readers, 1, -1 do
		local r = readers[i]
		if r.project then
			local ok, err = pcall(r.project, r)
			if ok then r.pf = f else
				Log("CLIENT ERROR in v19 reader " .. tostring(r.kind) .. ": " .. tostring(err))
				table.remove(readers, i)
			end
		end
	end
end)

hook.Add("PostRender", "ABL_V19Read", function()
	if not readers[1] then return end
	local f = FrameNumber()
	local any = false
	for i = 1, #readers do
		if readers[i].pf == f then any = true break end
	end
	if not any then
		-- (no view of the player's in a while: nothing can be read)
		local rt = RealTime()
		for i = #readers, 1, -1 do
			local r = readers[i]
			if rt - r.t0 > 4 then
				Log(string.format("v19 probe %s: the picture could not be read (no view)", tostring(r.kind)))
				table.remove(readers, i)
			end
		end
		return
	end
	local ok = pcall(render.CapturePixels)
	for i = #readers, 1, -1 do
		local r = readers[i]
		if r.pf == f then
			local good, again = pcall(r.read, r, ok)
			if not good then Log("CLIENT ERROR in v19 reader " .. tostring(r.kind) .. ": " .. tostring(again)) again = false end
			if not again then table.remove(readers, i) end
		end
	end
end)

local projV = Vector()
-- Where world point (x, y, z) is on the screen, and whether it is there.
local function Screen(x, y, z)
	projV:SetUnpacked(x, y, z)
	local sc = projV:ToScreen()
	local sx, sy = floor(sc.x), floor(sc.y)
	return sx, sy, sc.visible and sx >= 1 and sy >= 1 and sx < ScrW() - 1 and sy < ScrH() - 1
end
-- The mean of the (2k + 1) x (2k + 1) pixels round (x, y) of the captured picture.
local function MeanAt(x, y, k)
	local sr, sg, sb, n = 0, 0, 0, 0
	local W, Hh = ScrW(), ScrH()
	for yy = y - k, y + k do
		for xx = x - k, x + k do
			if xx >= 0 and yy >= 0 and xx < W and yy < Hh then
				local r, g, b = render.ReadPixel(xx, yy)
				if r then sr, sg, sb, n = sr + r, sg + g, sb + b, n + 1 end
			end
		end
	end
	if n == 0 then return nil end
	return sr / n, sg / n, sb / n
end

-- The pose as it is drawn in this frame, for the film's places on the screen, in the 3D view (where
-- it has been read for drawing already); sim: as the simulation reads it, anywhere else (as
-- cl_filmtest.lua's filmcam does). And as it was after.
local function PoseBegin(src, sim)
	local was = src.pose.frame
	src.pose:Begin(sim and FrameNumber() or -FrameNumber())
	return was
end
local function PoseEnd(src, was) if was ~= nil then src.pose:Begin(was) end end
local function CellPoint(src, s, c)
	local x, y, z, nx, ny, nz = src.pose:Point(s.tt[c], s.bu[c], s.bv[c])
	return x + nx * 0.05, y + ny * 0.05, z + nz * 0.05, nx, ny, nz
end
-- (a place on the body faces the eye)
local function Faces(x, y, z, nx, ny, nz)
	local e = EyePos()
	return (e.x - x) * nx + (e.y - y) * ny + (e.z - z) * nz > 0.05
end

-- The film's cells inside a run of liquid (liquid all round) and inside the stain (stained all round,
-- no liquid on them or beside them).
local function Cells(src)
	local s = src.film
	if not s or s.m ~= src.mesh or src.pose.mesh ~= src.mesh then return nil end
	local h, k, sd, ab = s.h, s.k, s.sd, s.ab
	local hi, lo, show = K.topHi or 0.004, K.topLo or 0.0015, K.showMin or 0.0012
	local nbs = { s.nb1, s.nb2, s.nb3, s.nb4 }
	local liq, stain = {}, {}
	for c = 1, s.n do
		local w = h[c] + k[c]
		local all = w + sd[c] + ab[c]
		local inside = true
		if w >= 2 * hi then
			for i = 1, 4 do
				local j = nbs[i] and nbs[i][c]
				if not j or j <= 0 or h[j] + k[j] < hi then inside = false break end
			end
			if inside then liq[#liq + 1] = c end
		elseif w < 0.5 * lo and all >= 4 * show then
			for i = 1, 4 do
				local j = nbs[i] and nbs[i][c]
				if not j or j <= 0 or h[j] + k[j] >= lo or h[j] + k[j] + sd[j] + ab[j] < 2 * show then inside = false break end
			end
			if inside then stain[#stain + 1] = c end
		end
	end
	return s, liq, stain
end

-- ratio: in the middle of a run, the liquid's red against the stain's beside it (the white sweater
-- in the sun: 0.80 to 0.92; at 0.58 it was the "dark stripe" of sh_config.lua's palette notes).
local function ProbeRatio(t, src)
	local tag = tostring(t.tag or t.ent)
	local s, liq, stain = Cells(src)
	if not s then Check(false, "ratio " .. tag, "not measured: no film on the body (or not on the surface model it has now)", t.judge) return end
	if #liq == 0 or #stain == 0 then
		Check(false, "ratio " .. tag, string.format("not measured: %d liquid cells inside a run, %d stained cells inside the stain", #liq, #stain), t.judge)
		return
	end
	local was = PoseBegin(src, true)
	-- (the middle of the run: its cells nearest the middle of all of them, each with the stained cell
	-- nearest to it, within 3 units)
	local px, py, pz = {}, {}, {}
	local cx, cy, cz = 0, 0, 0
	for i = 1, #liq do
		local x, y, z = CellPoint(src, s, liq[i])
		px[i], py[i], pz[i] = x, y, z
		cx, cy, cz = cx + x, cy + y, cz + z
	end
	cx, cy, cz = cx / #liq, cy / #liq, cz / #liq
	local order = {}
	for i = 1, #liq do order[i] = i end
	table.sort(order, function(a, b)
		return (px[a] - cx) ^ 2 + (py[a] - cy) ^ 2 + (pz[a] - cz) ^ 2 < (px[b] - cx) ^ 2 + (py[b] - cy) ^ 2 + (pz[b] - cz) ^ 2
	end)
	local sx, sy, sz = {}, {}, {}
	for j = 1, #stain do sx[j], sy[j], sz[j] = CellPoint(src, s, stain[j]) end
	PoseEnd(src, was)
	local pairsL, pairsS = {}, {}
	for n = 1, math.min(#order, 24) do
		local i = order[n]
		local bj, bd = nil, 9
		for j = 1, #stain do
			local d = (sx[j] - px[i]) ^ 2 + (sy[j] - py[i]) ^ 2 + (sz[j] - pz[i]) ^ 2
			if d < bd then bj, bd = j, d end
		end
		if bj then
			pairsL[#pairsL + 1] = liq[i]
			pairsS[#pairsS + 1] = stain[bj]
		end
	end
	if #pairsL == 0 then
		Check(false, "ratio " .. tag, string.format("not measured: no stained cell within 3 units of the run's middle (%d liquid, %d stained cells)", #liq, #stain), t.judge)
		return
	end
	readers[#readers + 1] = {
		kind = "ratio", t0 = RealTime(), lx = {}, ly = {}, lv = {}, kx = {}, ky = {}, kv = {},
		project = function(r)
			local w = PoseBegin(src)
			for i = 1, #pairsL do
				local x, y, z, nx, ny, nz = CellPoint(src, s, pairsL[i])
				local a, b, vis = Screen(x, y, z)
				r.lx[i], r.ly[i], r.lv[i] = a, b, vis and Faces(x, y, z, nx, ny, nz)
				x, y, z, nx, ny, nz = CellPoint(src, s, pairsS[i])
				a, b, vis = Screen(x, y, z)
				r.kx[i], r.ky[i], r.kv[i] = a, b, vis and Faces(x, y, z, nx, ny, nz)
			end
			PoseEnd(src, w)
		end,
		read = function(r, ok)
			if not ok then Check(false, "ratio " .. tag, "not measured: the picture could not be captured", t.judge) return false end
			local ratios, n = {}, 0
			local sl, ss = 0, 0
			for i = 1, #pairsL do
				if r.lv[i] and r.kv[i] then
					local lr = MeanAt(r.lx[i], r.ly[i], 1)
					local kr = MeanAt(r.kx[i], r.ky[i], 1)
					if lr and kr and kr > 4 then
						n = n + 1
						ratios[n] = lr / kr
						sl, ss = sl + lr, ss + kr
					end
				end
			end
			local m = Median(ratios, n)
			if not m then Check(false, "ratio " .. tag, string.format("not measured: none of %d pairs of places is seen", #pairsL), t.judge) return false end
			Check(m >= 0.80 and m <= 0.92, "ratio " .. tag, string.format("the liquid's red against the stain's beside it in the middle of the run: %.3f (median of %d pairs of places; red %.1f against %.1f on average); 0.80 to 0.92 wanted",
				m, n, sl / n, ss / n), t.judge)
			return false
		end,
	}
end

-- opening: the blood in a wound's opening, against its ground (the dark the opening is cleared to:
-- 34 times the light there, cl_woundfx.lua) and against the film beside it. Between 1.4 times the
-- one and 0.8 times the other.
local function ProbeOpening(t, src)
	local tag = tostring(t.tag or t.ent)
	local mk = marks[t.ent]
	if mk and mk.m ~= src.mesh then mk = nil end
	if not mk then
		for _, m in ipairs(src.marks or {}) do
			if (m.cav or m.hole) and m.m == src.mesh and m.tri and (not mk or m.born > mk.born) then mk = m end
		end
	end
	if not mk or src.pose.mesh ~= src.mesh or mk.tri > src.mesh.nt then Check(false, "opening " .. tag, "not measured: no wound opening on the body", t.judge) return end
	local R0 = mk.cav and mk.cav.R0
	if not R0 then Check(false, "opening " .. tag, "not measured: the opening has no size (no recess)", t.judge) return end
	readers[#readers + 1] = {
		kind = "opening", t0 = RealTime(),
		project = function(r)
			local w = PoseBegin(src)
			local x, y, z, nx, ny, nz = src.pose:Point(mk.tri, mk.u, mk.v)
			PoseEnd(src, w)
			local sd = Vector(nx, ny, nz):Cross(Vector(0, 0, 1))
			if sd:LengthSqr() < 0.01 then sd = Vector(1, 0, 0) end
			sd:Normalize()
			local a, b, vis = Screen(x + nx * 0.02, y + ny * 0.02, z + nz * 0.02)
			local a2, b2 = Screen(x + sd.x * R0, y + sd.y * R0, z + sd.z * R0)
			r.x, r.y, r.vis = a, b, vis and Faces(x, y, z, nx, ny, nz)
			r.rp = sqrt((a2 - a) ^ 2 + (b2 - b) ^ 2)
			r.wx, r.wy, r.wz, r.nx, r.ny, r.nz = x, y, z, nx, ny, nz
		end,
		read = function(r, ok)
			if not ok or not r.vis then Check(false, "opening " .. tag, "not measured: " .. (ok and "the opening is not seen" or "the picture could not be captured"), t.judge) return false end
			local rp = r.rp
			if rp < 3 then Check(false, "opening " .. tag, string.format("not measured: the opening is %.1f pixels across on the screen", rp * 2), t.judge) return false end
			local W, Hh = ScrW(), ScrH()
			local inR, outA, outB = 0.55 * rp, 1.6 * rp, 3.2 * rp
			local so, no, sf, nf = 0, 0, 0, 0
			local R = math.ceil(outB)
			for yy = r.y - R, r.y + R do
				for xx = r.x - R, r.x + R do
					if xx >= 0 and yy >= 0 and xx < W and yy < Hh then
						local d = sqrt((xx - r.x) ^ 2 + (yy - r.y) ^ 2)
						if d <= inR or (d >= outA and d <= outB) then
							local cr, cg, cb = render.ReadPixel(xx, yy)
							if cr then
								if d <= inR then so, no = so + cr, no + 1
								elseif Bloody(cr, cg, cb) then sf, nf = sf + cr, nf + 1 end
							end
						end
					end
				end
			end
			if no == 0 or nf < 10 then Check(false, "opening " .. tag, string.format("not measured: %d pixels in the opening, %d of film beside it", no, nf), t.judge) return false end
			-- (the light the wound's mark is drawn under: what its form kept, or the place's own)
			local lr = mk.flr
			if not lr and ABL.Render and ABL.Render.Light then lr = ABL.Render.Light(r.wx + r.nx * 2, r.wy + r.ny * 2, r.wz + r.nz * 2) end
			lr = lr or 1
			local ground = min(255, 34 * lr)
			local open, film = so / no, sf / nf
			Check(open >= 1.4 * ground and open <= 0.8 * film, "opening " .. tag, string.format("the opening's red %.1f (%d pixels, %.0f across) against its ground %.1f (34 times the light %.2f) and the film beside it %.1f (%d pixels): wanted %.1f to %.1f",
				open, no, rp * 2, ground, lr, film, nf, 1.4 * ground, 0.8 * film), t.judge)
			return false
		end,
	}
end

-- pool: where the film of a lying body meets its pool, the two side by side on the screen, with the
-- light each is lit by there (R.Light, and phase 19's R.ModelLight). For the pictures; not judged.
local function ProbePool(t, src)
	local tag = tostring(t.tag or t.ent)
	local s = src.film
	if not s or s.m ~= src.mesh or src.pose.mesh ~= src.mesh then Log("v19 probe pool " .. tag .. ": no film") return end
	local wetC = {}
	for c = 1, s.n do
		if s.h[c] + s.k[c] >= (K.topLo or 0.0015) then wetC[#wetC + 1] = c end
	end
	if #wetC == 0 then Log("v19 probe pool " .. tag .. ": no liquid on the body") return end
	local centre = IsValid(src.body) and src.body:WorldSpaceCenter() or Vector(0, 0, 0)
	readers[#readers + 1] = {
		kind = "pool", t0 = RealTime(),
		project = function(r)
			-- (the lowest place of its liquid that is seen: where it goes over to the floor)
			local w = PoseBegin(src)
			local x, y, z, nx, ny, nz
			for i = 1, #wetC do
				local a1, a2, a3, b1, b2, b3 = CellPoint(src, s, wetC[i])
				if (not z or a3 < z) and Faces(a1, a2, a3, b1, b2, b3) then
					local _, _, vis = Screen(a1, a2, a3)
					if vis then x, y, z, nx, ny, nz = a1, a2, a3, b1, b2, b3 end
				end
			end
			if not z then
				local a1, a2, a3, b1, b2, b3 = CellPoint(src, s, wetC[1])
				x, y, z, nx, ny, nz = a1, a2, a3, b1, b2, b3
			end
			PoseEnd(src, w)
			r.fx, r.fy, r.fvis = Screen(x, y, z)
			r.fvis = r.fvis and Faces(x, y, z, nx, ny, nz)
			-- (the floor under it, two units further out from the body)
			local tr = util.TraceLine({ start = Vector(x, y, z + 2), endpos = Vector(x, y, z - 40), mask = MASK_SOLID_BRUSHONLY })
			local out = Vector(x - centre.x, y - centre.y, 0)
			if out:LengthSqr() < 0.01 then out = Vector(1, 0, 0) end
			out:Normalize()
			local q = (tr.Hit and tr.HitPos or Vector(x, y, z - 2)) + out * 2 + Vector(0, 0, 0.2)
			r.px, r.py, r.pvis = Screen(q.x, q.y, q.z)
			r.q, r.f, r.fn = q, Vector(x, y, z), Vector(nx, ny, nz)
		end,
		read = function(r, ok)
			if not ok then Log("v19 probe pool " .. tag .. ": the picture could not be captured") return false end
			local fr, fg, fb, pr, pg, pb
			if r.fvis then fr, fg, fb = MeanAt(r.fx, r.fy, 2) end
			if r.pvis then pr, pg, pb = MeanAt(r.px, r.py, 2) end
			local R = ABL.Render
			local function L3(f, ...)
				if not f then return "-" end
				local ok2, a, b, c = pcall(f, ...)
				return ok2 and a and string.format("%.2f %.2f %.2f", a, b, c) or "-"
			end
			Log(string.format("v19 probe pool %s: the film's lowest liquid %s, the pool beside it on the floor %s | film/pool brightness %s | light: R.Light at the pool %s, R.ModelLight there %s, R.ModelLight at the film %s",
				tag, fr and string.format("%.0f %.0f %.0f", fr, fg, fb) or "not seen", pr and string.format("%.0f %.0f %.0f", pr, pg, pb) or "not seen",
				(fr and pr) and string.format("%.2f", Luma(fr, fg, fb) / math.max(Luma(pr, pg, pb), 1)) or "-",
				L3(R and R.Light, r.q.x, r.q.y, r.q.z + 2), L3(R and R.ModelLight, r.q.x, r.q.y, r.q.z, 0, 0, 1),
				L3(R and R.ModelLight, r.f.x, r.f.y, r.f.z, r.fn.x, r.fn.y, r.fn.z)))
			return false
		end,
	}
end

-- pendant: the drops that hang where blood waits to leave the body (cl_filmpendant.lua). The same
-- frozen picture with them and without them (C.V19.pendant 0 for a few frames): the pixels that
-- differ are the drops; the film beside them is the blood round those pixels in the picture
-- without. For the pictures; not judged.
local function ProbePendant(t, src)
	local tag = tostring(t.tag or t.ent)
	local s = src.film
	if not s or not s.out or s.m ~= src.mesh or src.pose.mesh ~= src.mesh then Log("v19 probe pendant " .. tag .. ": no film") return end
	if not (C.V19 and C.V19.pendant ~= nil) then Log("v19 probe pendant " .. tag .. ": no C.V19.pendant in this build") return end
	local cells, vols, sum = {}, {}, 0
	for c, v in pairs(s.out) do
		if type(c) == "number" and type(v) == "number" and v > 0 then
			cells[#cells + 1] = c
			sum = sum + v
		end
	end
	if #cells == 0 then Log("v19 probe pendant " .. tag .. ": no blood waits to drop") return end
	for i = 1, #cells do vols[cells[i]] = s.out[cells[i]] end
	table.sort(cells, function(a, b) return vols[a] > vols[b] end)
	for i = #cells, 7, -1 do cells[i] = nil end
	readers[#readers + 1] = {
		kind = "pendant", t0 = RealTime(), stage = 1, ax = {}, ay = {}, on = {}, off = {},
		project = function(r)
			if r.stage == 2 and FrameNumber() < r.wait then r.skip = true return end
			r.skip = false
			if r.stage == 1 then
				local w = PoseBegin(src)
				local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
				local rp = 8
				for i = 1, #cells do
					local x, y, z = CellPoint(src, s, cells[i])
					local a, b, vis = Screen(x, y, z)
					if vis then
						r.ax[#r.ax + 1], r.ay[#r.ay + 1] = a, b
						x0, y0, x1, y1 = min(x0, a), min(y0, b), max(x1, a), max(y1, b)
						local a2, b2 = Screen(x + 0.8, y, z)
						local a3, b3 = Screen(x, y, z - 0.8)
						rp = max(rp, abs(a2 - a), abs(b3 - b))
					end
				end
				PoseEnd(src, w)
				rp = min(rp, 60)
				r.rp = rp
				local W, Hh = ScrW(), ScrH()
				r.x0, r.y0 = max(0, floor(x0 - rp)), max(0, floor(y0 - rp))
				r.x1, r.y1 = min(W - 1, floor(x1 + rp)), min(Hh - 1, floor(y1 + rp))
				-- (no more than 300 x 300 pixels: round the fullest)
				if r.x1 - r.x0 > 300 or r.y1 - r.y0 > 300 then
					local a, b = r.ax[1] or 0, r.ay[1] or 0
					r.x0, r.y0, r.x1, r.y1 = max(0, a - 150), max(0, b - 150), min(W - 1, a + 150), min(Hh - 1, b + 150)
				end
			end
		end,
		read = function(r, ok)
			if r.skip then return true end
			if not ok or #r.ax == 0 then
				if r.stage == 2 then C.V19.pendant = r.was end
				Log("v19 probe pendant " .. tag .. ": " .. (ok and "none of the places is seen" or "the picture could not be captured"))
				return false
			end
			local dst = r.stage == 1 and r.on or r.off
			local n = 0
			for yy = r.y0, r.y1 do
				for xx = r.x0, r.x1 do
					local cr, cg, cb = render.ReadPixel(xx, yy)
					dst[n + 1], dst[n + 2], dst[n + 3] = cr or 0, cg or 0, cb or 0
					n = n + 3
				end
			end
			if r.stage == 1 then
				-- (the same frame without them, three frames on)
				local V = C.V19
				r.was = V.pendant
				SetV19("pendant", 0)
				r.stage, r.wait = 2, FrameNumber() + 3
				return true
			end
			C.V19.pendant = r.was
			local np, sr, sg, sb, nf, fr, fg, fb = 0, 0, 0, 0, 0, 0, 0, 0
			local w = r.x1 - r.x0 + 1
			local on, off = r.on, r.off
			local rp2 = r.rp * r.rp
			for i = 1, #on, 3 do
				-- (only near a place where a drop hangs)
				local p = (i - 1) / 3
				local xx, yy = r.x0 + p % w, r.y0 + floor(p / w)
				local near = false
				for j = 1, #r.ax do
					if (xx - r.ax[j]) ^ 2 + (yy - r.ay[j]) ^ 2 <= rp2 then near = true break end
				end
				if near then
					local d = abs(on[i] - off[i]) + abs(on[i + 1] - off[i + 1]) + abs(on[i + 2] - off[i + 2])
					if d > 24 then
						np = np + 1
						sr, sg, sb = sr + on[i], sg + on[i + 1], sb + on[i + 2]
					elseif Bloody(off[i], off[i + 1], off[i + 2]) then
						nf = nf + 1
						fr, fg, fb = fr + off[i], fg + off[i + 1], fb + off[i + 2]
					end
				end
			end
			if np == 0 then
				Log(string.format("v19 probe pendant %s: %d cells wait to drop (%.3f ml), %d of them seen: nothing of the picture changes without the drops (not drawn, or under a pixel)", tag, #cells, sum, #r.ax))
				return false
			end
			local pl, fl = Luma(sr / np, sg / np, sb / np), nf > 0 and Luma(fr / nf, fg / nf, fb / nf) or 0
			Log(string.format("v19 probe pendant %s: %d cells wait to drop (%.3f ml), %d seen | the hanging drops: %d pixels, %.0f %.0f %.0f | the film beside them: %d pixels, %s | the drops %s as bright as the film (red %s)",
				tag, #cells, sum, #r.ax, np, sr / np, sg / np, sb / np, nf, nf > 0 and string.format("%.0f %.0f %.0f", fr / nf, fg / nf, fb / nf) or "none",
				fl > 0 and string.format("%.2f times", pl / fl) or "-", nf > 0 and string.format("%.2f times", (sr / np) / math.max(fr / nf, 1)) or "-"))
			return false
		end,
	}
end

------------------------------------------------------------------------------------------
-- Reading the canvases back (in a render hook, outside the 3D view)
------------------------------------------------------------------------------------------
-- Texels (x0, y0) .. (x0 + w - 1, y0 + h - 1) of target tex into o.r, o.g, o.b, o.a (one list each,
-- row by row; an alpha that cannot be read is -1).
local function ReadRT(tex, x0, y0, w, h, o)
	render.PushRenderTarget(tex)
	local ok, err = pcall(function()
		render.CapturePixels()
		local n = 0
		for y = y0, y0 + h - 1 do
			for x = x0, x0 + w - 1 do
				local r, g, b, a = render.ReadPixel(x, y)
				n = n + 1
				o.r[n], o.g[n], o.b[n], o.a[n] = r or -1, g or -1, b or -1, a or -1
			end
		end
	end)
	render.PopRenderTarget()
	if not ok then error(err, 0) end
	return o
end
local function NewRead() return { r = {}, g = {}, b = {}, a = {} } end

-- The canvas in use of the film nearest the eye that has target `need` (a texel of it written).
local function Canvas(need)
	local D = ABL.FilmDraw
	local best, bd
	for i = 1, D and #D.canvases or 0 do
		local c = D.canvases[i]
		if not c.free and c.painted and c[need] and c.mp then
			local d = c.owner and c.owner.src and c.owner.src.dist or 1e9
			if not bd or d < bd then best, bd = c, d end
		end
	end
	return best
end

-- The part of a canvas where its map lies (with the border round it): what holds anything.
local function MapBox(c)
	local S, G = K.canvas, K.border
	local mp = c.mp
	local w, h = min(S, (mp.W or S) + 2 * G), min(S, (mp.H or S) + 2 * G)
	return 0, 0, w, h
end

local function Dec(v)
	local c = v / 255
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end
local function Enc(l)
	if l <= 0 then return 0 end
	if l >= 1 then return 255 end
	return 255 * (l <= 0.0031308 and 12.92 * l or 1.055 * l ^ (1 / 2.4) - 0.055)
end

-- b2: B2 against B, texel by texel, where the liquid's surface is not level. Each texel of B2 is
-- meant to be the mean of B's bytes read at four places round it (a normal map is read raw: its
-- bytes are averaged, not their light). Where the two ways differ by 3 or more, B2 says which it is.
local function ProbeB2(t)
	local D = ABL.FilmDraw
	-- (B2 that its own probe turned off is not read by the materials: whatever it holds, b2 failed)
	if D and D.b2Bad then Check(false, "b2", "B2 was turned off for the session by its own probe (D.b2Bad): the liquid's surface is read from B as before", t.judge) return end
	local c = Canvas("b2")
	if not c then
		Check(false, "b2", "not measured: " .. (V19On("b2") and "no canvas in use has a B2" or "b2 is off (abl_liquid_v19 or C.V19.b2)"), J(V19On("b2") and t.judge ~= false))
		return
	end
	-- (while B goes from its last picture to its new one, B2 is made from both on purpose: asked
	-- again in a later frame, 60 frames at the most)
	if c.lr and c.lr.b and c.lr.b.open then
		t.tries = (t.tries or 0) + 1
		if t.tries < 60 then return "again" end
		Check(false, "b2", "not measured: B's interpolation stayed open", t.judge)
		return
	end
	local S = K.canvas
	local x0, y0, w, h = MapBox(c)
	local B = ReadRT(c.b, x0, y0, w, h, NewRead())
	-- (where it is not level: the middle of those texels, and 24 x 24 texels round it)
	local sx, sy, n = 0, 0, 0
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x + 1
			if abs(B.r[i] - 128) + abs(B.g[i] - 128) + abs(B.b[i] - 255) > 6 then sx, sy, n = sx + x, sy + y, n + 1 end
		end
	end
	if n < 8 then Check(false, "b2", string.format("not measured: %d texels of B are not level", n), t.judge) return end
	local cx, cy = floor(sx / n), floor(sy / n)
	local wx0, wy0 = max(1, cx - 12), max(1, cy - 12)
	local wx1, wy1 = min(w - 2, cx + 12), min(h - 2, cy + 12)
	local B2 = ReadRT(c.b2, (x0 + wx0) * 2, (y0 + wy0) * 2, (wx1 - wx0 + 1) * 2, (wy1 - wy0 + 1) * 2, NewRead())
	local w2 = (wx1 - wx0 + 1) * 2
	local TAP = 0.5 / sqrt(3)
	local off = K.smoothOff or 0
	local function Bil(arr, fx, fy, light)
		-- (B read at canvas texel coordinates fx, fy, between its texels; light: in linear light)
		fx, fy = fx - 0.5, fy - 0.5
		local ix, iy = floor(fx), floor(fy)
		local ax, ay = fx - ix, fy - iy
		local s = 0
		for j = 0, 1 do
			for i = 0, 1 do
				local xx, yy = min(max(ix + i - x0, 0), w - 1), min(max(iy + j - y0, 0), h - 1)
				local v = arr[yy * w + xx + 1]
				if light then v = Dec(v) end
				s = s + v * (i == 0 and 1 - ax or ax) * (j == 0 and 1 - ay or ay)
			end
		end
		return s
	end
	local all, eAll, nd, eByte, eLight, bias, eA = 0, 0, 0, 0, 0, 0, 0
	for j2 = 4, (wy1 - wy0 + 1) * 2 - 5 do
		for i2 = 4, w2 - 5 do
			local gx, gy = (x0 + wx0) * 2 + i2, (y0 + wy0) * 2 + j2
			local m = j2 * w2 + i2 + 1
			for ch = 1, 2 do
				local arr = ch == 1 and B.r or B.g
				local meas = ch == 1 and B2.r[m] or B2.g[m]
				local byte, lin = 0, 0
				for tp = 1, 4 do
					local fx = (gx + 0.5) / 2 + off + (tp % 2 == 1 and -TAP or TAP)
					local fy = (gy + 0.5) / 2 + off + (tp <= 2 and -TAP or TAP)
					byte = byte + 0.25 * Bil(arr, fx, fy, false)
					lin = lin + 0.25 * Bil(arr, fx, fy, true)
				end
				local light = Enc(lin)
				all, eAll = all + 1, eAll + abs(meas - byte)
				if abs(byte - light) >= 3 then
					nd = nd + 1
					eByte, eLight, bias = eByte + abs(meas - byte), eLight + abs(meas - light), bias + (meas - byte)
				end
			end
			if B2.a[m] >= 0 and B.a[1] >= 0 then
				local byte = 0
				for tp = 1, 4 do
					local fx = (gx + 0.5) / 2 + off + (tp % 2 == 1 and -TAP or TAP)
					local fy = (gy + 0.5) / 2 + off + (tp <= 2 and -TAP or TAP)
					byte = byte + 0.25 * Bil(B.a, fx, fy, false)
				end
				eA = eA + abs(B2.a[m] - byte)
			end
		end
	end
	local mAll = all > 0 and eAll / all or 99
	local ok = mAll <= 1.5 and (nd < 10 or eByte < eLight)
	Check(ok, "b2", string.format("canvas %d (%s): B2 against B's bytes averaged, off by %.2f on average over %d values (shine %.2f); where averaging the bytes and averaging their light differ by 3 or more (%d values) off by %.2f from the bytes (%+.2f) and by %.2f from the light; 1.5 at most, and nearer the bytes, wanted | B2 turned off by its probe: %s",
		c.id, tostring(c.mp and c.mp.name), mAll, all, all > 0 and eA / (all / 2) or 0, nd, nd > 0 and eByte / nd or 0, nd > 0 and bias / nd or 0, nd > 0 and eLight / nd or 0, tostring(D.b2Bad or false)), t.judge)
end

-- b2pair: what this build of the game does with the two parameters B2 is made with ($gammacolorread
-- and $linearwrite on UnlitGeneric, the SDK's, not documented for Garry's Mod), apart from the
-- painter: a pair of texels 62 | 193 and a block of 128, written into a target of a canvas's size
-- and kind, made twice the size by the same four taps (of 64, 64, 64 and 63) through a material with
-- both, and read back. Averaged as bytes the two texels that lie across the pair's middle come to
-- 127.5 between them (averaged as light, some 144), and 128 stays 128. Within 3 and 1 of that.
local pairRT = {}
local function ProbeB2Pair(t)
	local S = K.canvas
	local S2 = S * 2
	local FLAGS = bit.bor(4, 8, 256, 512)
	if not pairRT.src then
		-- (made once under names of their own and kept, as every target and material is)
		pairRT.src = GetRenderTargetEx("abl_v19test_pair", S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		pairRT.dst = GetRenderTargetEx("abl_v19test_pair2", S2, S2, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, FLAGS, 0, IMAGE_FORMAT_RGBA8888)
		pairRT.mat = CreateMaterial("abl_v19test_pairup", "UnlitGeneric", { ["$basetexture"] = pairRT.src:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
			["$ignorez"] = 1, ["$nocull"] = 1, ["$gammacolorread"] = 1, ["$linearwrite"] = 1 })
	end
	local SRGB = ABL.FilmDraw and ABL.FilmDraw.SRGB
	if not SRGB then Check(false, "b2pair", "not measured: no D.SRGB", t.judge) return end
	-- (drawing into a target; the render state is put back whatever happens in fn)
	local function Into(tex, fn)
		render.PushRenderTarget(tex)
		cam.Start2D()
		render.OverrideAlphaWriteEnable(true, true)
		render.OverrideColorWriteEnable(true, true)
		local ok, err = pcall(fn)
		render.SetScissorRect(0, 0, 0, 0, false)
		render.OverrideBlend(false)
		render.OverrideColorWriteEnable(false, true)
		render.OverrideAlphaWriteEnable(false, true)
		cam.End2D()
		render.PopRenderTarget()
		if not ok then error(err, 0) end
	end
	-- the texels, as D.Cell writes them (each colour given so that it is stored as it is meant)
	Into(pairRT.src, function()
		render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
		render.Clear(128, 128, 255, 0, false, false)
		draw.NoTexture()
		local function Put(x, y, w, h, v)
			surface.SetDrawColor(SRGB[v], SRGB[128], SRGB[255], 255)
			surface.DrawRect(x, y, w, h)
		end
		Put(96, 96, 4, 12, 128)
		Put(100, 96, 1, 12, 62)
		Put(101, 96, 1, 12, 193)
		Put(102, 96, 4, 12, 128)
		Put(120, 96, 8, 12, 128)
	end)
	local w0 = ReadRT(pairRT.src, 99, 100, 4, 1, NewRead())
	-- the four taps, as D.Smooth lays them, over the part that holds the texels
	Into(pairRT.dst, function()
		render.SetScissorRect(180, 180, 270, 230, true)
		surface.SetMaterial(pairRT.mat)
		local TAP = 0.5 / sqrt(3)
		local du = 0.5 / S
		local k = 1 / (1 - 2 * du)
		local off = (K.smoothOff or 0) / S
		for tp = 1, 4 do
			local wgt = tp == 4 and 63 or 64
			surface.SetDrawColor(wgt, wgt, wgt, wgt)
			render.OverrideBlend(true, BLEND_ONE, tp == 1 and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD, BLEND_ONE, tp == 1 and BLEND_ZERO or BLEND_ONE, BLENDFUNC_ADD)
			local ox = (tp % 2 == 1 and -TAP or TAP) / S + off
			local oy = (tp <= 2 and -TAP or TAP) / S + off
			surface.DrawTexturedRectUV(0, 0, S2, S2, (ox - du) * k, (oy - du) * k, (1 + ox - du) * k, (1 + oy - du) * k)
		end
	end)
	-- (the pair's middle is at x 101 of the target: between the fine texels 201 and 202; rows 200 ..
	-- 207 lie inside the written rows; the block of 128 at 240 ..)
	local R = ReadRT(pairRT.dst, 199, 202, 6, 2, NewRead())
	local F = ReadRT(pairRT.dst, 242, 202, 4, 2, NewRead())
	local a, b = (R.r[3] + R.r[9]) * 0.5, (R.r[4] + R.r[10]) * 0.5
	local mid = (a + b) * 0.5
	local flat, flatMost = 0, 0
	for i = 1, 8 do
		flat = flat + F.r[i] / 8
		flatMost = max(flatMost, abs(F.r[i] - 128), abs(F.g[i] - 128))
	end
	Check(abs(mid - 127.5) <= 3 and flatMost <= 1, "b2pair", string.format("written %d %d | %d %d (stored), made twice the size: the two across the middle %.1f and %.1f, %.1f between them (127.5 as bytes, about 144 as light); a block of 128 comes back %.1f (off by %d at the most) | the row: %d %d %d %d %d %d",
		w0.r[1], w0.r[2], w0.r[3], w0.r[4], a, b, mid, flat, flatMost, R.r[1], R.r[2], R.r[3], R.r[4], R.r[5], R.r[6]), t.judge)
end

-- copy: render.CopyTexture, which the painter copies a canvas's pictures with before a step (its
-- previous pictures, phase 19's lerp), from a canvas in use into a target of the same size and
-- kind: is the copy the same texel for texel (no sampling, no gamma)?
local copyRT = {}
local function ProbeCopy(t)
	local D = ABL.FilmDraw
	-- (canvases lent a set of previous pictures now: c.lset, cl_filmdraw.lua's lerp)
	local pool = 0
	for i = 1, D and #D.canvases or 0 do
		local c = D.canvases[i]
		if c.lset or c.ap or c.lp or c.bp then pool = pool + 1 end
	end
	if not render.CopyTexture then
		Log(string.format("v19 probe copy: this build has no render.CopyTexture (the painter copies by drawing); %d canvas(es) hold previous pictures", pool))
		return
	end
	local c = Canvas("a")
	if not c then Check(false, "copy", "not measured: no canvas in use", t.judge) return end
	local S = K.canvas
	local x0, y0, w, h = MapBox(c)
	local parts, bad, total = {}, 0, 0
	for _, which in ipairs({ "a", "b", "l" }) do
		local src = c[which]
		if src then
			local dst = copyRT[which]
			if not dst then
				-- (made once under a name of its own and kept, as every target is)
				dst = GetRenderTargetEx("abl_v19test_copy_" .. which, S, S, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)
				copyRT[which] = dst
			end
			local ok, err = pcall(render.CopyTexture, src, dst)
			if not ok then
				parts[#parts + 1] = which .. ": the copy failed (" .. tostring(err) .. ")"
				bad = bad + 1
			else
				local A = ReadRT(src, x0, y0, w, h, NewRead())
				local Bc = ReadRT(dst, x0, y0, w, h, NewRead())
				local diff, most, filled = 0, 0, 0
				for i = 1, w * h do
					local d = max(abs(A.r[i] - Bc.r[i]), abs(A.g[i] - Bc.g[i]), abs(A.b[i] - Bc.b[i]), abs(A.a[i] - Bc.a[i]))
					if d > 0 then diff = diff + 1 end
					if d > most then most = d end
					if A.a[i] > 0 then filled = filled + 1 end
				end
				total = total + w * h
				bad = bad + diff
				parts[#parts + 1] = string.format("%s: %d of %d texels differ (by %d at the most; %d hold something)", which, diff, w * h, most, filled)
			end
		end
	end
	Check(bad == 0 and total > 0, "copy", string.format("canvas %d, render.CopyTexture into a target of the same size and kind: %s | %d canvas(es) hold previous pictures now", c.id, table.concat(parts, "; "), pool), t.judge)
end

local rtJobs = {}
hook.Add("PreRender", "ABL_V19ReadCanvas", function()
	local t = rtJobs[1]
	if not t then return end
	table.remove(rtJobs, 1)
	local fn = (t.kind == "b2" and ProbeB2) or (t.kind == "b2pair" and ProbeB2Pair) or ProbeCopy
	local ok, res = pcall(fn, t)
	if not ok then
		Log("CLIENT ERROR in v19probe " .. tostring(t.kind) .. ": " .. tostring(res))
	elseif res == "again" then
		rtJobs[#rtJobs + 1] = t
	end
end)

function H.v19probe(t)
	local kind = t.kind
	if kind == "b2" or kind == "b2pair" or kind == "copy" then rtJobs[#rtJobs + 1] = t return end
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then
		Check(false, tostring(kind) .. " " .. tostring(t.tag), "not measured: no source for entity " .. tostring(t.ent), (kind == "ratio" or kind == "opening") and t.judge or false)
		return
	end
	if kind == "ratio" then ProbeRatio(t, src)
	elseif kind == "opening" then ProbeOpening(t, src)
	elseif kind == "pool" then ProbePool(t, src)
	elseif kind == "pendant" then ProbePendant(t, src)
	else Log("v19probe: no such kind " .. tostring(kind)) end
end

------------------------------------------------------------------------------------------
-- The dolly: the camera drawn along a line, the film's passes counted
------------------------------------------------------------------------------------------
-- Which passes the film of the body watched is drawn with in a frame, as bits (D.Overlay is handed
-- them by D.Source): wrapped only while a dolly runs.
local PASSBIT = { stain = 1, deep = 2, liq = 4, shine = 8, lit = 16, plain = 32, old = 64, soft = 128, try = 256, tryUnder = 512 }
local PASSNAMES = { "stain", "deep", "liq", "shine", "lit", "plain", "old", "soft", "try", "tryUnder" }
local watchBody, passSig, passFrame
local overlay0
local function WrapOverlay()
	local D = ABL.FilmDraw
	if overlay0 or not D or type(D.Overlay) ~= "function" then return overlay0 ~= nil end
	overlay0 = D.Overlay
	D.Overlay = function(ent, ch, layers, passes, np, ...)
		if ent == watchBody and type(passes) == "table" and type(np) == "number" then
			local sig = 0
			for i = 1, np do sig = bit.bor(sig, PASSBIT[passes[i]] or 1024) end
			passSig, passFrame = sig, FrameNumber()
		end
		return overlay0(ent, ch, layers, passes, np, ...)
	end
	return true
end
function UnwrapOverlay()
	if overlay0 and ABL.FilmDraw then ABL.FilmDraw.Overlay = overlay0 end
	overlay0, watchBody = nil, nil
end
local function SigNames(sig)
	if sig == 0 then return "nothing" end
	local out = {}
	for i = 1, #PASSNAMES do
		if bit.band(sig, PASSBIT[PASSNAMES[i]]) ~= 0 then out[#out + 1] = PASSNAMES[i] end
	end
	if bit.band(sig, 1024) ~= 0 then out[#out + 1] = "other" end
	return table.concat(out, "+")
end

local dollyV, dollyEye = Vector(), Vector()
-- t.center, t.dir (along the floor): the camera from t.d0 to t.d1 units over t.secs seconds (real
-- time), t.el degrees above the floor, looking at the centre. The film of entity t.ent: which passes
-- it is drawn with in each frame, and how bright the places of its liquid are on the screen.
-- t.judge: PASS when the brightness steps by less than 3 % at every change of the passes.
function H.v19dolly(t)
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then Log("v19dolly: no source for " .. tostring(t.ent)) return end
	if dolly then Log(string.format("v19dolly: %s is left unfinished", tostring(dolly.t.name))) end
	local s = src.film
	local cells = {}
	if s and s.m == src.mesh then
		-- (the places of its liquid, at most 160 of them, spread over it)
		local list = {}
		for c = 1, s.n do
			if s.h[c] + s.k[c] >= 2 * (K.topHi or 0.004) then list[#list + 1] = c end
		end
		local step = math.max(1, math.ceil(#list / 160))
		for i = 1, #list, step do cells[#cells + 1] = list[i] end
	end
	if not WrapOverlay() then Log("v19dolly: the film's passes cannot be watched in this build (no D.Overlay)") end
	watchBody = src.body
	local dir = Vector(t.dir.x, t.dir.y, 0)
	dir:Normalize()
	-- (a dolly asked for while one runs takes its place; the reader of each reads its own)
	local rec = { t = t, src = src, s = s, cells = cells, t0 = RealTime(), dir = dir, el = math.rad(t.el or 20), sx = {}, sy = {}, sv = {},
		frames = 0, lastSig = nil, lastL = nil, switches = {}, base = {}, nb = 0, done = false, near = nil, nearFlips = 0 }
	dolly = rec
	readers[#readers + 1] = {
		kind = "dolly", t0 = RealTime(),
		project = function(r)
			local d = dolly
			if d ~= rec or not d.s then return end
			local w = PoseBegin(d.src)
			for i = 1, #d.cells do
				local x, y, z, nx, ny, nz = CellPoint(d.src, d.s, d.cells[i])
				local a, b, vis = Screen(x, y, z)
				d.sx[i], d.sy[i], d.sv[i] = a, b, vis and Faces(x, y, z, nx, ny, nz)
			end
			PoseEnd(d.src, w)
		end,
		read = function(r, ok)
			local d = dolly
			if d ~= rec then return false end
			if not ok then return not d.done end
			-- (how bright the liquid's places are in this frame)
			local sum, n = 0, 0
			for i = 1, #d.cells do
				if d.sv[i] then
					local cr, cg, cb = render.ReadPixel(d.sx[i], d.sy[i])
					if cr then sum, n = sum + Luma(cr, cg, cb), n + 1 end
				end
			end
			local L = n > 0 and sum / n or nil
			local sig = passFrame == FrameNumber() and passSig or 0
			-- (the camera of this frame: where the dolly put it before the frame was drawn)
			local dist = dollyEye:Distance(d.t.center)
			d.frames = d.frames + 1
			if d.lastSig ~= nil and sig ~= d.lastSig then
				local step = (L and d.lastL and d.lastL > 1) and abs(L - d.lastL) / d.lastL or nil
				d.switches[#d.switches + 1] = { d = dist, from = d.lastSig, to = sig, step = step, L0 = d.lastL, L1 = L }
			elseif L and d.lastL and d.lastL > 1 then
				-- (from one frame to the next without a change of passes: the camera's own motion)
				d.nb = d.nb % 60 + 1
				d.base[d.nb] = abs(L - d.lastL) / d.lastL
			end
			-- (and the film's own choice, where it says it: phase 19's near with its hysteresis)
			local s = d.src.film
			if s and s.v19near ~= nil then
				if d.near ~= nil and s.v19near ~= d.near then d.nearFlips = d.nearFlips + 1 end
				d.near = s.v19near
			end
			d.lastSig, d.lastL = sig, L
			return not d.done
		end,
	}
	Log(string.format("v19dolly %s: from %d to %d units over %.1f s, %d places of its liquid watched", tostring(t.name), t.d0, t.d1, t.secs, #cells))
end

hook.Add("Think", "ABL_V19Dolly", function()
	local d = dolly
	if not d then return end
	local t = d.t
	if d.done then
		-- (the frame after the last: the numbers)
		dolly = nil
		local parts, worst = {}, 0
		for _, e in ipairs(d.switches) do
			parts[#parts + 1] = string.format("%s -> %s at %.0f units (%s)", SigNames(e.from), SigNames(e.to), e.d, e.step and string.format("%.1f %%", e.step * 100) or "not seen")
			if e.step and e.step > worst then worst = e.step end
		end
		local bl, bn = {}, 0
		for i = 1, #d.base do bn = bn + 1 bl[bn] = d.base[i] end
		local base = Median(bl, bn) or 0
		local detail = string.format("%d frames, %d change(s) of the passes: %s | the liquid's brightness from frame to frame otherwise %.2f %% (median of the last %d) | phase 19's near flipped %d time(s)",
			d.frames, #d.switches, #parts > 0 and table.concat(parts, "; ") or "none", base * 100, bn, d.nearFlips)
		if t.judge and #d.cells > 0 then
			Check(worst < 0.03, "dolly " .. tostring(t.name), detail .. string.format(" | the largest step at a change %.1f %%, under 3 %% wanted", worst * 100))
		elseif #d.cells == 0 then
			Check(false, "dolly " .. tostring(t.name), "not measured: no liquid on the film | " .. detail, J(t.judge))
		else
			Check(true, "dolly " .. tostring(t.name), detail, false)
		end
		UnwrapOverlay()
		return
	end
	local k = (RealTime() - d.t0) / t.secs
	if k >= 1 then k, d.done = 1, true end
	local dist = t.d0 + (t.d1 - t.d0) * k
	local c = t.center
	local ce, se = math.cos(d.el), math.sin(d.el)
	dollyEye:SetUnpacked(c.x + d.dir.x * dist * ce, c.y + d.dir.y * dist * ce, c.z + dist * se)
	dollyV:SetUnpacked(c.x - dollyEye.x, c.y - dollyEye.y, c.z - dollyEye.z)
	H.view({ pos = dollyEye, ang = dollyV:Angle(), fov = t.fov or 60 })
end)
