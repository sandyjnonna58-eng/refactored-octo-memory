-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "M16A2"
SWEP.Instructions = "Insurgency: Sandstorm. 5.56x45 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_m16a2.mdl"
SWEP.Primary.Ammo = "5.56x45 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = false
SWEP.Primary.Wait = 0.075
SWEP.Primary.Damage = 35
SWEP.Primary.Force = 35
SWEP.Penetration = 11
SWEP.CustomShell = "556x45"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/m16a2/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/m16a2/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/m16a2/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/m16a2/foley/m16_foley_mag_out.ogg", "none", "sandstorm/m16a2/foley/m16_foley_mag_in.ogg", "sandstorm/m16a2/foley/m16_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, -0.403, 0.134)
SWEP.WorldAng = Angle(-2.554, 4.031, 176.907)
SWEP.LocalMuzzlePos = Vector(27.925, -2.586, -5.128)
SWEP.LocalMuzzleAng = Angle(2.762, -3.892, -177.091)
SWEP.ZoomPos = Vector(0, 0.875, 6.14)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(15.54, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 14
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
