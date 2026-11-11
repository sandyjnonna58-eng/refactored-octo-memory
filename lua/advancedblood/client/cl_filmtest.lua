-- Client half of the blood film's tests (developer tool). Inert unless the test harness is running
-- (garrysmod/data/abl_selftest.txt, see cl_selftest.lua): which model a character's blood has, a
-- camera on its film, the film's numbers in the harness log, and its look changed for a picture.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local D, FM, FC = ABL.FilmDraw, ABL.Film, ABL.FlowCore
local C = ABL.Config
local K = C.Film
local floor, min, max = math.floor, math.min, math.max

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

-- The film (film = true) or the streams of the flow core for one character.
function H.filmmode(t)
	local ent = Entity(t.ent or 0)
	if IsValid(ent) then ent.ablNoFilm = (not t.film) and true or nil end
	Log(string.format("filmmode %s: %s", tostring(ent), t.film and "film" or "flow core"))
end

-- The film's look for the pictures that follow: t.k values of C.Film (t.palette: of its palette),
-- t.phong = { exponent, boost } for the highlight, t.tint = { r, g, b } its colour (white when left
-- out). Everything is painted anew.
function H.filmlook(t)
	for k, v in pairs(t.k or {}) do K[k] = v end
	for k, v in pairs(t.palette or {}) do K.palette[k] = v end
	if t.phong then
		local tint = t.tint or { 1, 1, 1 }
		for _, c in ipairs(D.canvases) do
			for _, m in ipairs({ c.lit, c.shine }) do
				m:SetInt("$phongexponent", t.phong[1])
				m:SetFloat("$phongboost", t.phong[2])
				m:SetVector("$phongtint", Vector(tint[1], tint[2], tint[3]))
				m:Recompute()
			end
		end
	end
	D.Repaint()
	Log(string.format("filmlook %s%s", tostring(t.name), t.phong and string.format(": highlight exponent %s boost %s%s", tostring(t.phong[1]), tostring(t.phong[2]),
		t.tint and string.format(" tint %s %s %s", tostring(t.tint[1]), tostring(t.tint[2]), tostring(t.tint[3])) or "") or ""))
end

-- The canvases' materials by another recipe (cl_filmdraw.lua, D.Try), for the pictures that follow:
-- what this build of the game makes of a material's parameters. No preset: their own again.
function H.filmtry(t)
	D.Try(t.preset, t.under, function(line) Log("filmtry " .. line) end)
	Log(string.format("filmtry %s%s", tostring(t.preset or "(the film's own materials)"), t.under and (" over " .. t.under) or ""))
end

-- (ignore: the body looked at and its owner. The middle of a film that reaches round a trunk lies
-- inside the body: a line to it that ends on the body's own boxes is no blocked view. Counted as
-- one, every side of a standing body was "blocked" and its pictures were taken from straight above:
-- run fl0_baseline, scene bleed_stand.)
local function Sees(eye, look, ignore)
	local tr = util.TraceLine({ start = eye, endpos = look, mask = MASK_SHOT, filter = ignore })
	if tr.StartSolid then return false end
	return not tr.Hit or tr.HitPos:DistToSqr(look) < 16
end

-- Camera on the film of entity t.ent, as near as shows all of it (no nearer than t.min, no farther
-- than t.max), from where its surface faces. t.low: on the lowest place blood has reached. t.bone:
-- on that bone of the body (t.lift units above it), from the side t.yaw. A body with no film yet is
-- looked at where its first wound is.
function H.filmcam(t)
	local src = SourceOf(t.ent)
	if not src or not IsValid(src.body) then Log("filmcam: no source for entity " .. tostring(t.ent)) return end
	local s = src.film
	local pose = src.pose
	pose:Begin(FrameNumber())
	local mn, mx, nrm = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9), Vector(0, 0, 0)
	local n, low = 0, nil
	if s and s.m == src.mesh then
		local step = math.max(1, floor(s.n / 500))
		for c = 1, s.n, step do
			if s.h[c] + s.k[c] + s.sd[c] + s.ab[c] > K.showMin then
				local x, y, z, nx, ny, nz = pose:Point(s.tt[c], s.bu[c], s.bv[c])
				mn.x, mn.y, mn.z = min(mn.x, x), min(mn.y, y), min(mn.z, z)
				mx.x, mx.y, mx.z = max(mx.x, x), max(mx.y, y), max(mx.z, z)
				nrm.x, nrm.y, nrm.z = nrm.x + nx, nrm.y + ny, nrm.z + nz
				if not low or z < low.z then low = Vector(x, y, z) end
				n = n + 1
			end
		end
	end
	if n == 0 then
		local wd = src.woundList[1]
		local ok, x, y, z, nx, ny, nz
		if wd then ok, x, y, z, nx, ny, nz = ABL.Emission.WoundFrame(src, wd) end
		if not ok then Log("filmcam: no film and no wound on " .. tostring(src.body)) return end
		mn, mx, nrm = Vector(x, y, z), Vector(x, y, z), Vector(nx, ny, nz)
		low = Vector(x, y, z)
	end
	local centre = (mn + mx) * 0.5
	local extent = (mx - mn):Length()
	if t.low then centre, extent = low + Vector(0, 0, t.drop or 2), 0 end
	local onBone = false
	if t.bone then
		-- (on a bone of the body instead of on the middle of its film: a head with wounds on more than
		-- one side has the middle of its film inside it, or on the chest below)
		local b = src.body:LookupBone(t.bone)
		local bp = b and src.body:GetBonePosition(b)
		if bp then centre, extent, onBone = bp + Vector(0, 0, t.lift or 0), 0, true end
	end
	local out = Vector(nrm.x, nrm.y, 0)
	local lift = 0
	if out:LengthSqr() < 0.15 * math.max(nrm:LengthSqr(), 1e-6) then
		-- (it faces up or down: looked at from the side and from above, never from under the floor)
		out = Vector(1, 0.3, 0)
		lift = 0.9
	end
	out:Normalize()
	out = (out + Vector(0, 0, lift)):GetNormalized()
	-- (t.yaw: from that side instead, a little from above)
	if t.yaw then out = Angle(t.pitch or -12, t.yaw, 0):Forward() end
	-- (t.turn: from where the film faces, turned by that many degrees round the body: 90 is from its
	-- side, where what hangs at an edge and what falls from it stands clear of the body; t.pitch:
	-- from that many degrees above)
	if t.turn then
		local a = Vector(out.x, out.y, 0):Angle()
		out = Angle(-(t.pitch or 8), a.y + t.turn, 0):Forward()
	end
	-- (t.wound: on the body's first wound instead of on the middle of its film)
	if t.wound then
		local wd = src.woundList[t.wound == true and 1 or t.wound]
		local ok, x, y, z
		if wd then ok, x, y, z = ABL.Emission.WoundFrame(src, wd) end
		if ok then centre, extent = Vector(x, y, z), 0 end
	end
	local side = out:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 0.01 then side = Vector(0, 1, 0) end
	side:Normalize()
	local dist = math.Clamp(extent * (t.fit or 1.05) + (t.pad or 8), t.min or 12, t.max or 80)
	if t.dist then dist = t.dist end
	local eye = centre + out * dist + side * (t.side or 0.22) * dist + Vector(0, 0, t.up or 2)
	local moved = ""
	if t.sun == "say" then
		-- (only told: how the sun stands to the film)
		local info = util.GetSunInfo()
		local nn = nrm:GetNormalized()
		local sd = info and info.direction
		if sd then moved = string.format(" (the film faces %s; the sun is %.0f degrees off its normal)", tostring(nn), math.deg(math.acos(math.Clamp(nn:Dot(sd), -1, 1)))) end
	elseif t.sun then
		-- (from where the sun is mirrored in the film: its highlight at the brightest it gets)
		local info = util.GetSunInfo()
		local nn = nrm:GetNormalized()
		local sd = info and info.direction
		local mir = sd and (nn * (2 * nn:Dot(sd)) - sd)
		-- (that place may lie below the film, for one that stands upright under a high sun: it is
		-- taken while it is clear of the ground)
		local at = mir and centre + mir:GetNormalized() * dist
		local ground = util.TraceLine({ start = centre, endpos = centre - Vector(0, 0, 400), mask = MASK_SOLID_BRUSHONLY })
		if mir and nn:Dot(sd) > 0.05 and at.z > (ground.Hit and ground.HitPos.z or -1e9) + 4 then
			eye = at
			moved = string.format(" (from where the sun is mirrored: sun %s, the film faces %s)", tostring(sd), tostring(nn))
		else
			moved = string.format(" (no place where the sun is mirrored: sun %s, the film faces %s)", tostring(sd), tostring(nn))
		end
	end
	if onBone then
		-- (the place looked at lies inside the body: nothing to see it by, the side is as asked for)
		moved = moved .. string.format(" (on the bone %s)", tostring(t.bone))
	elseif not Sees(eye, centre, { src.body, src.owner }) then
		local base = Vector(out.x, out.y, 0):Angle().y
		local found
		for _, el in ipairs({ 40, 65 }) do
			for _, az in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
				local e = centre + Angle(-el, base + az, 0):Forward() * dist
				if Sees(e, centre, { src.body, src.owner }) then
					eye, found = e, true
					moved = string.format(" (view blocked: from %d degrees up, turned %d)", el, az)
					break
				end
			end
			if found then break end
		end
		if not found then
			eye = centre + Vector(0.1, 0, 1) * dist
			moved = " (view blocked on every side: from straight above)"
		end
	end
	H.view({ pos = eye, ang = (centre - eye):Angle(), fov = t.fov })
	Log(string.format("filmcam %s: %d places with blood, %.1f units across, centre %s, from %.0f units%s%s", tostring(src.body), n, extent, tostring(centre), dist, t.low and " (the lowest place)" or "", moved))
end

-- The camera turns its back on what it looks at for t.secs seconds and turns to it again; the first
-- t.frames frames from the one it looks at it again are a burst of pictures named t.burst. The log
-- says what each film held of canvases before, while it was away, and in that first frame.
function H.awayview(t)
	local pos, ang = EyePos(), EyeAngles()
	local function Canvases()
		local n, films = 0, 0
		for _, src in ipairs(ABL.Sources.list) do
			local s = src.film
			if s then
				films = films + 1
				for _ in pairs(s.cv or {}) do n = n + 1 end
			end
		end
		return n, films
	end
	local n0 = Canvases()
	H.view({ pos = pos, ang = Angle(ang.p, ang.y + 180, 0) })
	timer.Simple((t.secs or 7) - 0.3, function()
		local n1 = Canvases()
		timer.Simple(0.3, function()
			local n2, films = Canvases()
			Log(string.format("awayview %s: %d film(s) with %d canvas(es) before, %d after %.1f s away, %d as the camera turns back",
				tostring(t.burst), films, n0, n1, (t.secs or 7) - 0.3, n2))
			H.poolburst({ name = t.burst, frames = t.frames or 16, every = 1, x = 480, y = 60, w = 960, h = 960, quality = 90 })
			H.view({ pos = pos, ang = ang })
		end)
	end)
end

-- The film in numbers: the books and what is found, what the films cost since the last asking, and
-- for every body what its film holds and how far it reaches.
local lastT, lastFrame
function H.filmstats(t)
	local bk = FC.Books
	local err, dAir, dSurf, dPool, air, surf, pool = FC.Audit()
	Log(string.format("film %s | books: released %.3f = airborne %.3f + surface %.3f + pool %.3f + absorbed %.3f + clotted %.3f + dried %.3f + lost %.3f | unbooked %.4f ml",
		tostring(t.name), bk.released, bk.airborne, bk.surface, bk.pool, bk.absorbed, bk.clotted, bk.dried, bk.lost, err))
	Log(string.format("   audit: found airborne %.3f (books off by %.4f)  surface %.3f (off by %.4f)  pool %.3f (off by %.4f)", air, dAir, surf, dSurf, pool, dPool))
	local films, cells, wet, act = FM.Counts()
	local p, ds = FM.prof, D.stats
	local used, made = D.Usage()
	local now, fn = RealTime(), FrameNumber()
	local dtw = lastT and (now - lastT) or 0
	local frames = lastFrame and math.max(fn - lastFrame, 1) or 1
	lastT, lastFrame = now, fn
	local chans = FC.Counts()
	Log(string.format("   films %d, cells %d (with blood %d, running %d), streams of the flow core %d | since last (%.1f s, %d frames): %d steps, %.4f ms a frame, %d cells looked at (%.2f us each), %d aged | painted %d texel writes in %d frames, %.4f ms a frame | %.2f passes over a body a frame, drawing %.3f ms a frame (smoothed) | canvases %d in use, %d made (limit %d), taken away %d, none to be had %d | frame %.2f ms | drops %d, pools %d",
		films, cells, wet, act, chans, dtw, frames, p.steps, p.step / frames, p.looked, p.looked > 0 and p.step / p.looked * 1000 or 0, p.aged,
		ds.texels, ds.paints, ds.ms / frames, ds.passes / frames, (ABL.Prof.Get("sub.body.film")), used, made, D.Limit(), ds.stolen or 0, ds.starved or 0,
		(ABL.selfFt and ABL.selfFt() or 0) * 1000, ABL.Drops.Count(), ABL.Pools.Count()))
	Log(string.format("   outline since last: %d texels rose past it, %d fell back under it, the most a texel's share changed in one painting %.3f | left the bodies %.3f ml", ds.enter or 0, ds.leave or 0, ds.jump or 0, p.left or 0))
	Log(string.format("   waves since last: %d paintings, %d texels written, %.4f ms a frame | drawn as %s",
		ds.ripples or 0, ds.ripTexels or 0, (ds.ripMs or 0) / frames, D.Layered() and "two layers" or "one layer, as before"))
	-- (how the liquid's surface changed from one painting of its waves to the next: the tilt of a
	-- texel's surface, as an angle)
	local rn = ds.ripN or 0
	Log(string.format("   the liquid's surface from one wave step to the next: %d texel steps, tilt changed by %.2f degrees on average, %.1f at the most, %.1f%% of the steps went the other way from the step before",
		rn, rn > 0 and math.deg(math.atan(ds.ripSum / rn)) or 0, math.deg(math.atan(math.sqrt(ds.ripMost or 0))), rn > 0 and 100 * ds.ripBack / rn or 0))
	for k in pairs(p) do p[k] = 0 end
	ds.texels, ds.paints, ds.ms, ds.passes, ds.enter, ds.leave, ds.jump = 0, 0, 0, 0, 0, 0, 0
	ds.ripples, ds.ripTexels, ds.ripMs = 0, 0, 0
	ds.ripN, ds.ripSum, ds.ripMost, ds.ripBack = 0, 0, 0, 0
	D.measure = true
	for _, src in ipairs(ABL.Sources.list) do
		for _, wd in ipairs(src.woundList) do
			Log(string.format("   wound %s value %.3f flow %.4f ml/s profile %s clot %.2f | film cell %s, opening of %d cells, dripped straight off %.3f",
				tostring(wd.id), wd.sev or 0, wd.flow or 0, wd.profile and wd.profile.name or "-", wd.clotK or 1, tostring(wd.fcell), wd.fopen and #wd.fopen or 0, wd.dripAcc or 0))
		end
		local s = src.film
		local m = src.mesh
		local ch = m and m.chart
		Log(string.format("   body %s (%s): lod %s, %.0f units away, film %s, flow core streams %d, chart %s",
			tostring(src.body), tostring(IsValid(src.body) and src.body:GetModel() or "?"), tostring(src.lod), src.dist or -1, s and "yes" or "no", src.fc and #src.fc.chans or 0,
			ch and (ch.ready and string.format("ready, %.0f%% of the surface%s", (ch.share or 0) * 100, ch.ok and "" or " (too little: flow core)") or (ch.failed and "FAILED" or "building")) or "none"))
		if s then
			local b = s.bk
			local held = FM.Held(s)
			local q = FM.Measure(s)
			local cv = 0
			for _ in pairs(s.cv or {}) do cv = cv + 1 end
			Log(string.format("     fed %.3f = wet on it %.3f + in the cloth %.3f + dried %.3f + left %.3f (unbooked %.4f) | held %.3f (books off by %.4f) | cells %d, with blood %d, running %d, waiting for paint %d, texels on their way %d | shown %d cells, %.1f units^2: liquid %.2f ml, in cloth %.2f, dried %.2f | canvases %d%s",
				b.fed, b.surface, b.absorbed, b.dried, b.left, b.fed - b.surface - b.absorbed - b.dried - b.left, held, b.surface - held, s.n, s.wetN, s.na, s.qn + (s.un or 0), s.animN or 0,
				q.cells, q.area, q.liquid, q.soaked, q.dried, cv, s.rest and " | at rest" or ""))
			for _, e in pairs(q.maps) do
				Log(string.format("     %s: %d cells, %.1f x %.1f units of its texture, rows %.2f units wide on average (sd %.2f, widest %.2f) over %d rows",
					e.name, e.cells, (e.x1 - e.x0 + 1) * e.cell, (e.y1 - e.y0 + 1) * e.cell, e.wMean, e.wSd, e.wMax, e.rowsN))
			end
			-- (what each of its canvases lies on, how much of it is liquid, and how its flow is known)
			for k, c in pairs(s.cv or {}) do
				local tx = s.tx and s.tx[k]
				local _, base, bump, _, real = D.Cloth(src.body, s.ch.mats[k].slot or 0)
				-- (a material with no relief of its own gives the engine's "error" texture for one: phase 19,
				-- C.V19.clothRelief, then draws the stain with the body's own flat normal)
				local relief = bump and (real == false and "the engine's error texture" or "found") or "none"
				Log(string.format("     canvas on %s: the body's material there %s (texture %s, relief %s) | texels inside the liquid's outline %d | rim smoothed over %.3f of the field | the texture is %.2f bright on average there: %.2f of it shows in the stain, drawn at %.2f",
					s.ch.mats[k].name, tostring(c.cloth), base and "found" or "none", relief, tx and tx.liq or 0, c.softW or 0, c.mean or -1, c.showF or -1, c.gain or -1))
			end
			local moving, fast, known = 0, 0, 0
			for i = 1, s.na do
				local c = s.act[i]
				if s.sp[c] > 0.05 then moving = moving + 1 end
				if s.sp[c] > fast then fast = s.sp[c] end
			end
			for c = 1, s.n do
				if s.dx[c] * s.dx[c] + s.dy[c] * s.dy[c] > 0.04 then known = known + 1 end
			end
			Log(string.format("     flow: %d places run (the fastest %.2f cells a second), %d places know which way blood has crossed them | waves painted: %s",
				moving, fast, known, s.rip and "yes" or "no"))
		end
	end
end
