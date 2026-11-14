-- Основа пистолетов из паков Мастерской «Sandstorm SWEPs» в виде оружия Z-City (homigrad_base через Browning Hi-Power -
-- мировая модель в руке без отдельной анимированной модели). Модели/звуки - из пака (качается с сервера), в сборке - Lua.
-- Сами стволы - weapon_rem_sand_*.lua, их пишет tools/sandstorm/make.py.
SWEP.Base = "weapon_browninghp"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.Category = "Sandstorm (Z-City)"
SWEP.Author = "Insurgency: Sandstorm (модели - пак Мастерской)"
SWEP.WepSelectIcon2 = Material("null") -- своих иконок в паках нет (не наследуем чужую от шаблона)
SWEP.IconOverride = ""
SWEP.availableAttachments = {}
SWEP.SandKind = "pistol"

-- у Browning свои кости и материалы модели - для чужой модели ничего не трогаем
function SWEP:ModelCreated(model) end
function SWEP:DrawPost() end
