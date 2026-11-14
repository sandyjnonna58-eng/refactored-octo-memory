-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "VHS-2"
SWEP.Instructions = "Insurgency: Sandstorm. 5.56x45 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_vhs2.mdl"
SWEP.Primary.Ammo = "5.56x45 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.071
SWEP.Primary.Damage = 35
SWEP.Primary.Force = 35
SWEP.Penetration = 11
SWEP.CustomShell = "556x45"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/vhs2/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/vhs2/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/vhs2/distant_01.ogg"
SWEP.WorldPos = Vector(4.5, -0.361, -0.345)
SWEP.WorldAng = Angle(5.396, 4.172, -178.654)
SWEP.LocalMuzzlePos = Vector(18.305, -2.274, -1.486)
SWEP.LocalMuzzleAng = Angle(-5.478, -4.062, 179.046)
SWEP.ZoomPos = Vector(0, 0.917, 6.512)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(10.01, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 10
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
