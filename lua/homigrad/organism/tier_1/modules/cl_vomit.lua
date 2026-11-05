-- Обычная рвота на клиенте (сервер - sv_vomit.lua): струя изо рта - желтовато-бурые капли и сгустки, падают
-- и оставляют лужи на полу
local colors = {Color(170, 150, 60), Color(150, 120, 50), Color(185, 165, 80), Color(130, 110, 45)}
local sprites = {"particle/particle_smokegrenade", "particle/smokesprites_0001", "particle/smokesprites_0003"}

local function Mouth(ent)
	local id = ent:LookupAttachment("mouth")
	local att = id and id > 0 and ent:GetAttachment(id)
	if att then return att.Pos, att.Ang:Forward() end
	local b = ent:LookupBone("ValveBiped.Bip01_Head1")
	local m = b and ent:GetBoneMatrix(b)
	if not m then return end
	local a = m:GetAngles()
	return m:GetTranslation() + a:Right() * 5 + a:Forward() * 1, a:Right()
end

local active = {}
net.Receive("rem_vomit", function()
	local ent, dur = net.ReadEntity(), net.ReadFloat()
	if not IsValid(ent) then return end
	active[ent] = {start = CurTime(), stop = CurTime() + dur, emitter = ParticleEmitter(ent:GetPos())}
end)

local function Splat(p, pos, normal)
	if math.random(3) ~= 1 then return end
	util.Decal("BeerSplash", pos + normal, pos - normal * 4)
end

hook.Add("Think", "rem_vomit_stream", function()
	local now = CurTime()
	for ent, v in pairs(active) do
		if not IsValid(ent) or now > v.stop then
			if v.emitter then v.emitter:Finish() end
			active[ent] = nil
			continue
		end
		if (v.next or 0) > now then continue end
		v.next = now + 0.02
		local pos, dir = Mouth(ent)
		if not pos or not v.emitter then continue end
		local strength = math.sin(math.Clamp((now - v.start) / (v.stop - v.start), 0, 1) * math.pi) -- рывком: сильнее в середине
		for i = 1, 3 do
			local p = v.emitter:Add(sprites[math.random(#sprites)], pos)
			if p then
				local col = colors[math.random(#colors)]
				p:SetVelocity((dir + VectorRand() * 0.18 + Vector(0, 0, -0.25)):GetNormalized() * math.Rand(60, 140) * (0.5 + strength))
				p:SetGravity(Vector(0, 0, -600))
				p:SetDieTime(math.Rand(0.6, 1.1))
				p:SetStartAlpha(235)
				p:SetEndAlpha(200)
				p:SetStartSize(math.Rand(0.6, 1.4))
				p:SetEndSize(math.Rand(1.2, 2.2))
				p:SetRoll(math.Rand(0, 360))
				p:SetColor(col.r, col.g, col.b)
				p:SetLighting(true)
				p:SetCollide(true)
				p:SetBounce(0.05)
				p:SetCollideCallback(Splat)
			end
		end
	end
end)

-- кнопка в C-меню (значки сверху слева): вызвать рвоту самому
list.Set("DesktopWindows", "RemVomit", {
	title = "Vomit",
	icon = "rem_misc/vomit.png",
	init = function(icon, window)
		if IsValid(window) then window:Remove() end
		RunConsoleCommand("rem_vomit")
	end,
})
