-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "FAMAS F1"
SWEP.Instructions = "Insurgency: Sandstorm. 5.56x45 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_famas.mdl"
SWEP.Primary.Ammo = "5.56x45 mm"
SWEP.Primary.ClipSize = 25
SWEP.Primary.DefaultClip = 25
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.06
SWEP.Primary.Damage = 35
SWEP.Primary.Force = 35
SWEP.Penetration = 11
SWEP.CustomShell = "556x45"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/famas/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/famas/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/famas/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/famas/foley/famas_foley_mag_out.ogg", "none", "sandstorm/famas/foley/famas_foley_mag_in.ogg", "sandstorm/famas/foley/famas_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, -0.048, -0.582)
SWEP.WorldAng = Angle(-0.069, -0.049, -178.218)
SWEP.LocalMuzzlePos = Vector(18.1, -1.308, -2.999)
SWEP.LocalMuzzleAng = Angle(0.071, 0.047, 178.218)
SWEP.ZoomPos = Vector(0, 1.23, 6.487)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(9.96, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 10
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
