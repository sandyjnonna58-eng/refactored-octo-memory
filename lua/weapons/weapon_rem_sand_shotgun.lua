-- Основа помповых дробовиков из паков «Sandstorm SWEPs» в виде оружия Z-City (через M4 Super 90: патрон за патроном;
-- AutomaticDraw = false - после выстрела передёрнуть цевьё (R), как у M870 Z-City). Модели/звуки - из пака Мастерской.
SWEP.Base = "weapon_m4super"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.Category = "Sandstorm (Z-City)"
SWEP.Author = "Insurgency: Sandstorm (модели - пак Мастерской)"
SWEP.WepSelectIcon2 = Material("null") -- своих иконок в паках нет (не наследуем чужую от шаблона)
SWEP.IconOverride = ""
SWEP.AutomaticDraw = false
SWEP.SandKind = "shotgun"

function SWEP:ModelCreated(model) end
