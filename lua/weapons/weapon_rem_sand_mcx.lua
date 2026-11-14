-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.PrintName = "MCX SPEAR LT"
SWEP.Instructions = "Insurgency: Sandstorm. 5.56x45 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_mcx.mdl"
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
SWEP.Primary.Sound = {"sandstorm/mcx/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/mcx/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/mcx/distant_01.ogg"
SWEP.WorldPos = Vector(4.5, -0.406, -0.296)
SWEP.WorldAng = Angle(-4.077, 3.978, 177.334)
SWEP.LocalMuzzlePos = Vector(23.073, -2.266, -5.066)
SWEP.LocalMuzzleAng = Angle(4.248, -3.795, -177.617)
SWEP.ZoomPos = Vector(0, 0.872, 6.62)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(12.92, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 11
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
