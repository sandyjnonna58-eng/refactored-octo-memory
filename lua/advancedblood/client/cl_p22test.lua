-- Client half of the scenes of phase 22 (server/sv_p22test.lua; developer tool, inert unless the test
-- harness is running). The scenes' cameras, figures and checks are cl_p21test.lua's; this file sets a
-- part of C.P22 for the scenes after it and puts it back.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log

-- The camera where the sun is mirrored in the meniscus of a pool at t.pos (C.P22.sunRim): on the
-- sun's side, so high that the half-way direction between the sun and the eye leans t.tilt degrees
-- (25) from upright, t.dist (60) units off. Logs the sun, the camera and what the pools near t.pos
-- have of it (p.sunAt, p.sunK, the way across).
function H.p22suncam(t)
	local sx, sy, sz = ABL.Render.SunDir()
	if not sx then Log("p22suncam: the map has no sun") return end
	local se = math.deg(math.asin(math.Clamp(sz, -1, 1)))
	local tilt = t.tilt or 25
	-- (sun and eye on one side: the half-way direction stands at the mean of their elevations)
	local ee = math.Clamp(2 * (90 - tilt) - se, 15, 85)
	local hl = math.sqrt(sx * sx + sy * sy)
	local hx, hy = hl > 1e-3 and sx / hl or 1, hl > 1e-3 and sy / hl or 0
	local d = t.dist or 60
	local ce, sn = math.cos(math.rad(ee)), math.sin(math.rad(ee))
	local pos = t.pos + Vector(hx * ce * d, hy * ce * d, sn * d)
	H.view({ pos = pos, ang = (t.pos - pos):Angle(), fov = 60 })
	Log(string.format("p22suncam: sun %.2f %.2f %.2f (%.0f degrees up), eye %.0f degrees up on its side, %d units off", sx, sy, sz, se, ee, d))
end

function H.p22sun(t)
	local n = 0
	for _, p in ipairs(ABL.Pools.list) do
		if (p.cx - t.pos.x) ^ 2 + (p.cy - t.pos.y) ^ 2 + (p.cz - t.pos.z) ^ 2 < (t.r or 40) ^ 2 then
			n = n + 1
			Log(string.format("p22sun %s: pool %s in the sun %s, rim share %s, way across %s %s", tostring(t.name), tostring(p.id or n),
				tostring(p.sunAt), p.sunK and string.format("%.2f", p.sunK) or "none", p.sunU and string.format("%.2f", p.sunU) or "-", p.sunV and string.format("%.2f", p.sunV) or "-"))
		end
	end
	if n == 0 then Log("p22sun " .. tostring(t.name) .. ": no pool near") end
end

-- A part of C.P22 (t.name) set to t.value, or put back as it was (t.restore); every pool is painted
-- again (a part that is read only while painting, such as sunRimBreak, changes nothing on its own).
local kept = {}
function H.p22set(t)
	local K = ABL.Config.P22
	if not K then return end
	local was = K[t.name]
	if t.restore then
		if kept[t.name] ~= nil then K[t.name], kept[t.name] = kept[t.name], nil end
	else
		if kept[t.name] == nil then kept[t.name] = was end
		K[t.name] = t.value
	end
	for _, p in ipairs(ABL.Pools.list or {}) do p.dirty = true end
	Log(string.format("p22set %s: %s (was %s)", tostring(t.name), tostring(K[t.name]), tostring(was)))
end
