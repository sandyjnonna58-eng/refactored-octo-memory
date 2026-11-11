-- Client half of the tests of where a wound's blood comes from and where it goes (developer tool).
-- Inert unless the test harness is running (garrysmod/data/abl_selftest.txt, see cl_selftest.lua).
--
-- bleedorigin: for every wound that has a place in its body's film, where the blood on that body
-- lies as seen from the wound: how much of it within one, two and four units of the opening, how
-- far it reaches from there down the slope, up it and to the sides (in the pose the body has now,
-- against gravity as it is now), how far from the opening the nearest liquid is (a gap), and what
-- the wound's mark paints round the opening of itself.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local FM, C = ABL.Film, ABL.Config
local K = C.Film
local ML = C.ML_PER_CU
local sqrt, min, max, abs = math.sqrt, math.min, math.max, math.abs

local LIQ = 0.006      -- units: a layer this deep is liquid standing on the place (as the offline bench counts it)

local function Origin(src, wd, s)
	local pose = src.pose
	if not wd.tri or wd.tri > src.mesh.nt then return nil end
	local px, py, pz, nx, ny, nz = pose:Point(wd.tri, wd.u, wd.v)
	local gx, gy, gz, gmag = ABL.Gravity()
	gx, gy, gz = gx / gmag, gy / gmag, gz / gmag
	-- down along the skin at the wound (nothing where the skin is level there)
	local gn = gx * nx + gy * ny + gz * nz
	local dx, dy, dz = gx - nx * gn, gy - ny * gn, gz - nz * gn
	local dl = sqrt(dx * dx + dy * dy + dz * dz)
	local level = dl < 0.12
	if level then
		-- (level skin has no way down: measured along the body's own long axis instead)
		dx, dy, dz = ABL.Perp(nx, ny, nz)
		dl = 1
	end
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	local sx, sy, sz = ny * dz - nz * dy, nz * dx - nx * dz, nx * dy - ny * dx
	local o = { level = level, up = -gn, slope = math.deg(math.acos(math.Clamp(-gn, -1, 1))),
		n = 0, liq = 0, soak = 0, dried = 0, cells1 = 0, liq1 = 0, soak1 = 0, cells2 = 0, liq2 = 0, soak2 = 0, cells4 = 0, liq4 = 0, soak4 = 0,
		down = 0, upHill = 0, side = 0, ldown = 0, lup = 0, lside = 0, lcells = 0, gap = 1e9, deep = 0, deepAt = 0, far = 0 }
	local h, k, sd, ab, ar, tt, bu, bv = s.h, s.k, s.sd, s.ab, s.ar, s.tt, s.bu, s.bv
	for c = 1, s.n do
		local wet = h[c] + k[c]
		local Tt = wet + sd[c] + ab[c]
		if Tt > K.showMin then
			local x, y, z = pose:Point(tt[c], bu[c], bv[c])
			local rx, ry, rz = x - px, y - py, z - pz
			local d = sqrt(rx * rx + ry * ry + rz * rz)
			-- (blood further off than a body is long is another wound's, on a limb that lies beside this one)
			local along = rx * dx + ry * dy + rz * dz
			local across = abs(rx * sx + ry * sy + rz * sz)
			local a = ar[c] * ML
			o.n = o.n + 1
			o.liq, o.soak, o.dried = o.liq + wet * a, o.soak + ab[c] * a, o.dried + sd[c] * a
			if d <= 1 then o.cells1, o.liq1, o.soak1 = o.cells1 + 1, o.liq1 + wet * a, o.soak1 + ab[c] * a end
			if d <= 2 then o.cells2, o.liq2, o.soak2 = o.cells2 + 1, o.liq2 + wet * a, o.soak2 + ab[c] * a end
			if d <= 4 then o.cells4, o.liq4, o.soak4 = o.cells4 + 1, o.liq4 + wet * a, o.soak4 + ab[c] * a end
			if d > o.far then o.far = d end
			if along > o.down then o.down = along end
			if -along > o.upHill then o.upHill = -along end
			if across > o.side then o.side = across end
			if wet > LIQ then
				o.lcells = o.lcells + 1
				if along > o.ldown then o.ldown = along end
				if -along > o.lup then o.lup = -along end
				if across > o.lside then o.lside = across end
				if d < o.gap then o.gap = d end
				if wet > o.deep then o.deep, o.deepAt = wet, d end
			end
		end
	end
	local c0 = wd.fcell
	o.h0 = c0 and (h[c0] + k[c0]) or 0
	o.open = wd.fopen and #wd.fopen or 0
	return o
end

function H.bleedorigin(t)
	local now = CurTime()
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s and src.mesh == s.m and IsValid(src.body) and (not t.ent or src.body:EntIndex() == t.ent or (IsValid(src.owner) and src.owner:EntIndex() == t.ent)) then
			src.pose:Begin(FrameNumber())
			for _, wd in ipairs(src.woundList) do
				local o = wd.fstate == s and wd.fcell and Origin(src, wd, s)
				if o then
					local r = wd.rec
					Log(string.format("origin %s | wound %s (%s) value %.1f flow %.2f ml/s, released %.1f ml, %s old | skin there %.0f deg off level%s | film source %d cell(s), %.4f deep at the wound, deepest %.4f (%.1f units off)",
						tostring(t.name), tostring(wd.id), tostring(wd.role or "-"), wd.sev or 0, wd.flow or 0, r and r.released or -1, r and string.format("%.1f s", now - r.t0) or "?",
						o.slope, o.level and " (level: no way down)" or "", o.open, o.h0, o.deep, o.deepAt))
					Log(string.format("   blood on the body from this wound's place: %d cells, liquid %.2f ml, in cloth %.2f, dried %.2f | within 1 unit %d cells (%.2f + %.2f ml), 2 units %d (%.2f + %.2f), 4 units %d (%.2f + %.2f) | share of all its liquid within 2 units: %.0f %%",
						o.n, o.liq, o.soak, o.dried, o.cells1, o.liq1, o.soak1, o.cells2, o.liq2, o.soak2, o.cells4, o.liq4, o.soak4, o.liq > 0 and 100 * o.liq2 / o.liq or 0))
					Log(string.format("   reach from the wound: %.1f down the slope, %.1f up it, %.1f to the side (liquid: %.1f down, %.1f up, %.1f to the side; %d cells) | nearest liquid %.2f units from the wound",
						o.down, o.upHill, o.side, o.ldown, o.lup, o.lside, o.lcells, o.gap < 1e8 and o.gap or -1))
				end
				-- what the wound's mark paints round its opening of itself
				local mk = wd.mark
				if mk and mk.layers then
					local r = mk.rec
					local parts = {}
					for _, l in ipairs(mk.layers) do
						if l.kind == 3 or l.kind == 6 or l.kind == 7 then
							parts[#parts + 1] = string.format("%s %s half %.2f of %.2f", l.kind == 3 and "blood" or "soak", tostring(l.tex), l.half, l.half0)
						end
					end
					Log(string.format("   mark %s on %s: opening %.2f units, born %.1f s ago, released %.1f ml | painted round it: %s",
						tostring(mk.kind), mk.skin and "skin" or "cloth", mk.cav and mk.cav.R0 or -1, now - mk.born, r and r.released or -1, #parts > 0 and table.concat(parts, "; ") or "nothing"))
				end
			end
		end
	end
end

-- smoothprobe: the second picture of a film's canvas, which the body's materials read its
-- outlines from (cl_filmdraw.lua, D.Smooth): does it lie where the canvas itself does, and has
-- it the canvas's colours? One texel and a block of texels are written into a canvas of its own,
-- the second picture is made from it, and both are read back.
function H.smoothprobe()
	local D = ABL.FilmDraw
	hook.Add("PreRender", "ABL_SmoothProbe", function()
		hook.Remove("PreRender", "ABL_SmoothProbe")
		local S, G = K.canvas, K.border
		local c = D.Take({ cu = 1 / S, cv = 1 / S, u0 = 0, v0 = 0 }, { src = { dist = 0 } })
		if not c then Log("smoothprobe: no canvas to be had") return end
		if not c.a2 then
			Log("smoothprobe: the canvas has no second picture (abl_film_smooth 0)")
			D.Give(c)
			return
		end
		D.Begin(c, "a")
		D.Cell(100, 100, 200, 20, 20, 255)
		for y = 0, 7 do
			for x = 0, 7 do D.Cell(130 + x, 100 + y, 92, 10, 12, 200) end
		end
		D.End()
		D.Smooth(c, 0, 0, S, S)
		local function Read(tex, x0, y0, nx, ny)
			local rows = {}
			render.PushRenderTarget(tex)
			render.CapturePixels()
			for y = y0, y0 + ny - 1 do
				local row = {}
				for x = x0, x0 + nx - 1 do
					local r, g, b, a = render.ReadPixel(x, y)
					row[#row + 1] = { r or -1, g or -1, b or -1, a or -1 }
				end
				rows[#rows + 1] = row
			end
			render.PopRenderTarget()
			return rows
		end
		-- the one texel, at (102, 102) of the canvas: twelve by twelve texels of the second picture round it
		local tx, ty = 100 + G, 100 + G
		local rows = Read(c.a2, tx * 2 - 5, ty * 2 - 5, 12, 12)
		local hasA = rows[1][1][4] >= 0
		local ch = hasA and 4 or 1
		local sum, sx, sy = 0, 0, 0
		for j = 1, 12 do
			local line = {}
			for i = 1, 12 do
				local v = rows[j][i][ch]
				-- (by its red, where no alpha is to be read: less what the cleared canvas has)
				if not hasA then v = math.max(v - K.palette.wetBody[1], 0) end
				line[i] = string.format("%3d", rows[j][i][ch])
				sum, sx, sy = sum + v, sx + v * (tx * 2 - 5 + i - 1 + 0.5), sy + v * (ty * 2 - 5 + j - 1 + 0.5)
			end
			if j >= 4 and j <= 9 then Log("smoothprobe: second picture, row " .. (ty * 2 - 5 + j - 1) .. ": " .. table.concat(line, " ")) end
		end
		if sum > 0 then
			-- (the texel's middle is at (tx + 0.5) * 2 of the second picture)
			Log(string.format("smoothprobe: read by %s. One texel of the canvas at (%d, %d): in the second picture its weight lies %.3f texels of the canvas right of where it should and %.3f below (0: it lies where the canvas does); total %d (a texel of 255 spread over four: 1020)",
				hasA and "alpha" or "red (no alpha to be read)", tx, ty, (sx / sum - (tx + 0.5) * 2) / 2, (sy / sum - (ty + 0.5) * 2) / 2, sum))
		else
			Log("smoothprobe: nothing of the one texel is in the second picture")
		end
		-- the block: a texel in its middle, in the canvas and in the second picture
		local bx, by = 133 + G, 103 + G
		local pa = Read(c.a, bx, by, 1, 1)[1][1]
		local pb = Read(c.a2, bx * 2 + 1, by * 2 + 1, 1, 1)[1][1]
		Log(string.format("smoothprobe: inside a block written as 92 10 12, alpha 200: the canvas holds %d %d %d (%d), the second picture %d %d %d (%d)",
			pa[1], pa[2], pa[3], pa[4], pb[1], pb[2], pb[3], pb[4]))
		D.Give(c)
	end)
end

-- bleedview: the camera on a point, from a direction, with a field of view (a close look at a
-- place before anything is there to follow).
function H.bleedview(t)
	H.view({ pos = t.pos, ang = (t.look - t.pos):Angle(), fov = t.fov, znear = 1 })
end
