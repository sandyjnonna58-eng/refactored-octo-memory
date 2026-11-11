-- Инсульт (sv_stroke.lua): кадр замирает, потом медленно оживает; звучит rem_lobotomy.ogg
local fade_time = 2
local stroke_sound = "sound/rem_lobotomy.ogg"

local freezeRT = GetRenderTarget("rem_stroke_freeze", ScrW(), ScrH())
local freezeMat = CreateMaterial("rem_stroke_freeze_mat", "UnlitGeneric", {
	["$basetexture"] = freezeRT:GetName(),
	["$translucent"] = 1,
	["$vertexalpha"] = 1,
	["$vertexcolor"] = 1,
})

local freezeEnd = 0
local needCapture = false
local station

net.Receive("rem_stroke", function()
	freezeEnd = CurTime() + net.ReadFloat()
	needCapture = true

	if IsValid(station) then station:Stop() end
	sound.PlayFile(stroke_sound, "noblock", function(chan)
		if not IsValid(chan) then return end
		station = chan
		chan:Play()
	end)
end)

hook.Add("RenderScreenspaceEffects", "rem_stroke", function()
	local now = CurTime()
	if now > freezeEnd + fade_time then return end

	if not LocalPlayer():Alive() then
		freezeEnd = 0
		return
	end

	-- первый кадр после инсульта запоминаем и дальше показываем его
	if needCapture then
		needCapture = false
		render.CopyRenderTargetToTexture(freezeRT)
	end

	local alpha = now < freezeEnd and 1 or 1 - (now - freezeEnd) / fade_time
	freezeMat:SetFloat("$alpha", math.Clamp(alpha, 0, 1))

	-- изредка кадр дёргается, как зависшая картинка
	local jitter = math.random(30) == 1 and math.random(-3, 3) or 0
	render.SetMaterial(freezeMat)
	render.DrawScreenQuadEx(jitter, 0, ScrW(), ScrH())
end)
