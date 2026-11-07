-- Луч рикошетной пули (сервер - sv_ricochet.lua): красный след по точкам пути, отрезки появляются по очереди и гаснут.
local beamMat = Material("trails/laser")
local glowMat = Material("sprites/light_glow02_add")
local beams = {}
local LIFE = 0.9

net.Receive("rem_ricochet", function()
	local n = net.ReadUInt(6)
	local pts = {}
	for i = 1, n do pts[i] = net.ReadVector() end
	beams[#beams + 1] = {pts = pts, t0 = CurTime(), seg = net.ReadFloat()}
end)

hook.Add("PostDrawTranslucentRenderables", "rem_ricochet", function(depth, sky)
	if depth or sky or #beams == 0 then return end
	local now = CurTime()
	for i = #beams, 1, -1 do
		local b = beams[i]
		local total = (#b.pts - 1) * b.seg
		local age = now - b.t0
		if age > total + LIFE then
			table.remove(beams, i)
		else
			for s = 1, #b.pts - 1 do
				local born = (s - 1) * b.seg
				if age >= born then
					local a = math.Clamp(1 - (age - born) / LIFE, 0, 1)
					local p1, p2 = b.pts[s], b.pts[s + 1]
					-- отрезок "долетает" за своё время
					local k = math.Clamp((age - born) / b.seg, 0, 1)
					local pe = LerpVector(k, p1, p2)
					render.SetMaterial(beamMat)
					render.DrawBeam(p1, pe, 6 * a + 1, 0, 1, Color(255, 30, 30, 255 * a))
					render.SetMaterial(glowMat)
					render.DrawSprite(pe, 14 * a, 14 * a, Color(255, 60, 40, 200 * a))
				end
			end
		end
	end
end)
