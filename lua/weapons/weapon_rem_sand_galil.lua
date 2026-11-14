-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "Galil"
SWEP.Instructions = "Insurgency: Sandstorm. 5.56x45 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_galil.mdl"
SWEP.Primary.Ammo = "5.56x45 mm"
SWEP.Primary.ClipSize = 35
SWEP.Primary.DefaultClip = 35
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.092
SWEP.Primary.Damage = 35
SWEP.Primary.Force = 35
SWEP.Penetration = 11
SWEP.CustomShell = "556x45"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/galil/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/galil/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/galil/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/galil/foley/galil_foley_mag_out.ogg", "none", "sandstorm/galil/foley/galil_foley_mag_in.ogg", "sandstorm/galil/foley/galil_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, 0.07, 0.813)
SWEP.WorldAng = Angle(7.83, -96.136, -167.919)
SWEP.LocalMuzzlePos = Vector(26.307, 1.228, -1.116)
SWEP.LocalMuzzleAng = Angle(-6.32, 7.682, 167.074)
SWEP.ZoomPos = Vector(0, 1.348, 6.649)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(14.27, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 12
SWEP.Spray = {}
for i = 1, 35 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
