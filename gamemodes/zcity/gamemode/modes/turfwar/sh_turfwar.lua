local MODE = MODE

-- Битва банд: Bloodz против Groove. Вариант раунда - ближний бой или огнестрел.
MODE.name = "turfwar"
MODE.PrintName = "Turf War"

MODE.VARIANT_MELEE = 1
MODE.VARIANT_GUNS = 2

MODE.VariantNames = {
	[MODE.VARIANT_MELEE] = "Melee",
	[MODE.VARIANT_GUNS] = "Firearms",
}

-- варианты в админ-меню (F6): ключ уходит в MODE:SetMenuOption
MODE.MenuOptions = {
	{"random", "Random"},
	{"melee", "Melee"},
	{"guns", "Firearms"},
}
