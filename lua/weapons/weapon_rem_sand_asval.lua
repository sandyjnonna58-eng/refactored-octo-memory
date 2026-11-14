-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.PrintName = "AS VAL"
SWEP.Instructions = "Insurgency: Sandstorm. 9x39 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_asval.mdl"
SWEP.Primary.Ammo = "9x39 mm"
SWEP.Primary.ClipSize = 20
SWEP.Primary.DefaultClip = 20
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.067
SWEP.Primary.Damage = 42
SWEP.Primary.Force = 42
SWEP.Penetration = 15
SWEP.CustomShell = "762x39"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/asval/shot_supp_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/asval/shot_supp_01.ogg", 70, 95, 105}
SWEP.WorldPos = Vector(4.5, -0.666, 0.228)
SWEP.WorldAng = Angle(12.065, 6.246, -178.674)
SWEP.LocalMuzzlePos = Vector(23.6, -3.14, 1.205)
SWEP.LocalMuzzleAng = Angle(-12.136, -6.104, 179.984)
SWEP.ZoomPos = Vector(0, 0.612, 5.042)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(12.94, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 11
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.09, 0, 0) or Angle(-0.045, (i % 2 == 0) and 0.09 or -0.09, 0) end
