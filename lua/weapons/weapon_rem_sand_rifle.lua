-- Основа автоматов (и магазинных дробовиков Saiga / USAS) из паков «Sandstorm SWEPs» в виде оружия Z-City (через АШ-12 -
-- мировая модель, отъёмный магазин). Модели/звуки - из пака Мастерской, в сборке только Lua (tools/sandstorm/make.py).
SWEP.Base = "weapon_ash12"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.Category = "Sandstorm (Z-City)"
SWEP.Author = "Insurgency: Sandstorm (модели - пак Мастерской)"
SWEP.WepSelectIcon2 = Material("null") -- своих иконок в паках нет (не наследуем чужую от шаблона)
SWEP.IconOverride = ""
SWEP.availableAttachments = {}
SWEP.StartAtt = {}
SWEP.weight = 3
SWEP.DistSound = "ak74/ak74_dist.wav"
SWEP.PPSMuzzleEffect = "pcf_jack_mf_mrifle1"
SWEP.SandKind = "rifle"

function SWEP:ModelCreated(model) end

-- левая рука на перезарядке уходит к магазину и возвращается на цевьё (у АШ-12 так же, но со своими точками)
local reloadLH = Vector(0, 0.8, -4.7)
function SWEP:DrawPost()
	if not CLIENT then return end
	local idle = self.SandLHPos or self.LHPos
	self.LHPos = LerpVectorFT(0.2, self.LHPos, self.reload and reloadLH or idle)
end
