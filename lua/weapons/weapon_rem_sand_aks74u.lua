-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.PrintName = "AKS-74U"
SWEP.Instructions = "Insurgency: Sandstorm. 5.45x39 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_aks74u.mdl"
SWEP.Primary.Ammo = "5.45x39 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.086
SWEP.Primary.Damage = 35
SWEP.Primary.Force = 35
SWEP.Penetration = 11
SWEP.CustomShell = "545x39"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/aks74u/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/aks74u/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/aks74u/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/aks74u/foley/aks_foley_mag_out.ogg", "none", "sandstorm/aks74u/foley/aks_foley_mag_in.ogg", "sandstorm/aks74u/foley/aks_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, -0.612, 1.271)
SWEP.WorldAng = Angle(14.823, 6.218, -178.531)
SWEP.LocalMuzzlePos = Vector(19.516, -2.725, 0.198)
SWEP.LocalMuzzleAng = Angle(-14.893, -6.044, -179.869)
SWEP.ZoomPos = Vector(0, 0.666, 6.85)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(10.5, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 10
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.07, 0, 0) or Angle(-0.035, (i % 2 == 0) and 0.07 or -0.07, 0) end
