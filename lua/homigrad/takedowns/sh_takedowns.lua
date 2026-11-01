-- Тейкдауны мачете (анимации Far Cry 4 из аддона "BSMod Far Cry Takedowns", без самого BSMod).
-- Модели-шаблоны с анимациями лежат в контент-паке (не в репозитории):
--   models/fc4km/weapons/c_limbs_template.mdl          - скелет убивающего (анимации от первого лица)
--   models/fc4km/bsmodimations_zombie_template.mdl     - скелет жертвы
--   sound/fc4tkdwn_sfx/*.wav                           - звуки
-- Сами шаблоны не рисуются: кости игроков (и NPC) на время приёма берутся с них, мачете рисуется в правой руке.
-- Оружие с SWEP.Takedowns = true (мачете FC3):
--   E со спины - скрытное убийство; E за низким укрытием - через укрытие; E под уступом или с лестницы - стаскивание вниз;
--   из воды (по грудь) - утаскивание в воду с любой стороны; прыжок/падение с высоты на цель - сам, без E.
hg = hg or {}
hg.Takedown = hg.Takedown or {}
local TD = hg.Takedown

TD.PlyModel = "models/fc4km/weapons/c_limbs_template.mdl"
TD.TgtModel = "models/fc4km/bsmodimations_zombie_template.mdl"

-- глаза относительно кости головы (из вложения "eyes" c_limbs_template) - для камеры жертвы и итогового взгляда
TD.EyesPos = Vector(3.73, -4.49, 0)
TD.EyesAng = Angle(0, -80.1, -90)

-- сдвиг мачете от ValveBiped.Anim_Attachment_RH по умолчанию (рукоять там, где у ножа FC4), у оружия свой SWEP.TakedownOffset
TD.DefaultOffset = {Vector(3.81, -4.47, 2.93), Angle(0, 0, -90)}

-- ply/tgt - длительности анимаций убивающего и жертвы (кадры-1)/fps из моделей; snd - звуки (берётся случайный из тех, что есть);
-- blood - когда брызгает кровь
local S = {}
TD.Seq = S
local function def(names, ply, tgt, snd, blood)
	for _, n in ipairs(names) do S[n] = {ply = ply, tgt = tgt, snd = snd, blood = blood} end
end
def({"fc4_backA_machete"}, 2.08, 2.00, {"fc4_front_a1", "fc4_front_a2"}, {0.7})
def({"fc4_backB_machete"}, 2.08, 2.00, {"fc4_back_b1", "fc4_back_b2"}, {0.7})
def({"fc4_backC_machete"}, 2.08, 2.00, {"fc4_front_c1", "fc4_front_c2"}, {0.7})
def({"fc4_backD_machete"}, 2.50, 2.17, {"fc4_hvy_back"}, {0.6, 1.2})
def({"fc4_dfa_frontA_machete", "fc4_dfa_backA_machete"}, 2.33, 2.17, {"fc4_dfa1", "fc4_dfa2"}, {0.45, 0.9})
def({"fc4_dfa_frontB_machete", "fc4_dfa_backB_machete"}, 3.08, 2.33, {"fc4_hvy_dfa"}, {0.45, 1.1, 1.7})
def({"fc4_dfa_left_machete", "fc4_dfa_right_machete"}, 3.00, 2.67, {"fc4_dfa_side1", "fc4_dfa_side2"}, {0.6, 1.3})
def({"fc4_cover_front_machete", "fc4_cover_back_machete"}, 3.92, 3.67, {"fc4_cover"}, {1.6, 2.4})
def({"fc4_dfb_front_machete", "fc4_dfb_back_machete"}, 2.08, 1.83, {"fc4_dfb1", "fc4_dfb2"}, {1.0})
def({"fc4_water_front_machete", "fc4_water_back_machete"}, 5.50, 4.42, {"fc4_water"}, {3.0})
-- dfa_left/right у жертвы разной длины
S["fc4_dfa_left_machete"].tgt = 3.00

-- куда смотрит цель
function TD.TargetYaw(target)
	if target:IsPlayer() then return target:EyeAngles().y end
	return target:GetAngles().y
end

-- с какой стороны от цели стоит ply: front / left / back / right (как в BSMod: 0 - спереди, 180 - сзади)
function TD.Side(ply, target)
	local a = ((ply:GetPos() - target:GetPos()):Angle().y - TD.TargetYaw(target)) % 360
	if a <= 45 or a > 315 then return "front", a end
	if a <= 135 then return "left", a end
	if a <= 225 then return "back", a end
	return "right", a
end

-- поворот шаблона жертвы для стороны (анимации написаны "убивающий сзади")
TD.SideYaw = {front = 180, left = 270, back = 0, right = 90}

-- кто сейчас в приёме: [ent] = {td = данные приёма, role = "attacker"/"victim"}
TD.ByEnt = TD.ByEnt or {}

function TD.Get(ent)
	return TD.ByEnt[ent]
end

function TD.InTakedown(ent)
	return TD.ByEnt[ent] ~= nil
end

-- на время приёма оба не двигаются и ничего не жмут (камера у убивающего и жертвы идёт по анимации)
hook.Add("StartCommand", "rem_takedown_lock", function(ply, cmd)
	if not TD.ByEnt[ply] then return end
	cmd:ClearMovement()
	cmd:ClearButtons()
end)
