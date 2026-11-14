-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "AK Alpha"
SWEP.Instructions = "Insurgency: Sandstorm. 7.62x39 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_akalpha.mdl"
SWEP.Primary.Ammo = "7.62x39 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.088
SWEP.Primary.Damage = 50
SWEP.Primary.Force = 50
SWEP.Penetration = 15
SWEP.CustomShell = "762x39"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/akalpha/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/akalpha/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/akalpha/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/akalpha/foley/AlphaAK_foley_mag_out.ogg", "none", "sandstorm/akalpha/foley/AlphaAK_foley_mag_in.ogg", "sandstorm/akalpha/foley/AlphaAK_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, -0.538, -0.85)
SWEP.WorldAng = Angle(9.058, 5.896, -179.766)
SWEP.LocalMuzzlePos = Vector(22.934, -3.093, 0.886)
SWEP.LocalMuzzleAng = Angle(-9.034, -5.933, -179.298)
SWEP.ZoomPos = Vector(0, 0.74, 6.214)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(12.64, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 11
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.11, 0, 0) or Angle(-0.055, (i % 2 == 0) and 0.11 or -0.11, 0) end
