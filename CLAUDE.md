# Память проекта (для Claude Code)

Аддон Garry's Mod: режим «remorseism» на базе zcity / homigrad. Этот файл Claude Code читает сам в начале каждой
сессии - здесь то, что нужно знать, чтобы продолжить работу с того же места.

## Как работаем
- Отвечать пользователю по-русски.
- Каждое изменение - коммит прямо в `main` и push:
  `git fetch -q origin main && git rebase -q origin/main && git push -q -u origin main`.
  Исключение: локальная копия в `GarrysMod/garrysmod/addons/refactored-octo-memory-main` - распакованный zip без `.git`,
  там правим файлы напрямую, без коммитов и push.
- Комментарии в коде - по-русски, коротко: что делает и почему.
- В игре изменения проверяет пользователь; у Claude - только проверка синтаксиса Lua.
- Чужой защищённый контент (видео, фото товаров, выдранные модели) - не в публичный репозиторий, а в приватные паки,
  они в `.gitignore` (`materials/rem_wd_private`, `sound/rem_wd_private`, `materials/rem_drinks_private`),
  раздаются через FastDL-циклы в `lua/homigrad/skills/sv_skills.lua`.
- Новые звуки/текстуры - `resource.AddSingleFile` на сервере, иначе у игроков их не будет.
- Генераторы текстур - в `tools/` (Python + PIL), запуск из корня репозитория.

## Устройство
- Загрузчик homigrad (`IncludeDir`) по префиксам: `sv_` - сервер, `cl_` - клиент, `sh_` - оба. В папке `cl_` грузятся раньше `sh_`.
- Организм: `lua/homigrad/organism/tier_1/` (`sv_organism.lua` - тик; порядок: Alcohol -> Nicotine -> Addiction -> Vessels ->
  blood -> pain -> pulse). Клиенту уходит только часть полей (`sendtable` в `sv_organism.lua`: blood, pain, pulse,
  consciousness, otrub, adrenaline ...); свои значения - через NW2 (`rem_bac`, `rem_bac_eff`, `rem_vessels`, `rem_nicotine`,
  `rem_dep_*`, `rem_wd_*`, `rem_nausea`).
- `org.owner` у лежащего в регдолле - это регдолл; игрока брать через `hg.RagdollOwner` / `GetNWEntity("ply")`.
- Боль: 100% на экране = `org.pain` 120.

## Грабли
- `self.BaseClass` в оружии-наследнике указывает на само оружие -> бесконечная рекурсия и краш.
  Использовать `local Base = baseclass.Get("...")`.
- Первое лицо homigrad рисует своё тело (`drawviewer = true`), движок прячет вьюмодели - их надо рисовать самому.
- `pickupHuy` (sh_utility) сам выбирает подобранное оружие; чтобы не выбирал - `wep.DontEquipInstantly = true`.
- Кость руки ValveBiped R_Hand: x - к пальцам, -z - из ладони.

## Где что (сделано в этом проекте)
- Мысли (печатаются по буквам, звук на каждую букву по состоянию: normal / bad / fast): `lua/homigrad/sh_notification.lua`,
  звуки `sound/rem_speech/`. Крики при боли 75%+ («ITHURTSITHURTS...») - `lua/homigrad/sh_status_messages.lua`.
- Экранные эффекты: `lua/homigrad/screenfx/` - `cl_screenfx.lua` (удар, вспышка, боль: пульсирует с сердцем, дрожит,
  наплыв при скачке боли), `cl_fading.lua` (засветка при кровопотере, туннель при уходе сознания).
- Таймер смерти «вихрь» (84 с, ничего не вращается, медленно растёт): `lua/homigrad/vortexdeath/`.
- Экран смерти и выбор звука смерти (`rem_deathsound`, настройка Gameplay -> «Death sound: heart stop»):
  `lua/autorun/client/cl_cdeath.lua`, настройки - `lua/initpost/menu-n-derma/derma/cl_menu_options.lua`.
- Панель состояний (плитки, «прыгают» по тяжести, как в Fading Vitality): `lua/homigrad/cl_health_indicator.lua`.
  Значки - в стиле Fading Vitality (свои рисунки): белая основа `tools/affliction_icons/base` (make.py из Tabler),
  стиль и цвета - `tools/affliction_icons/make_fv.py` -> `materials/rem_affl`. Новый значок: в make.py и в STYLE make_fv.py.
- Алкоголь, никотин, привыкание, сосуды, рвота: `lua/homigrad/organism/tier_1/modules/` (`sv_alcohol`, `sv_nicotine`,
  `sv_addiction`, `sv_vessels`, `sv_vomit` и их `cl_`). Напитки - `weapon_hg_vodka` (база) и наследники, сигареты -
  `weapon_hg_cigarettes`.
- Тейкдауны, камера FC, лечение FC, бросок ножа (E + ПКМ): `lua/homigrad/takedowns`, `fccamera`, `fcheal`, `meleethrow`.
- Совместимость с отдельным аддоном «Metal Gear Solid V: Gameplay SWEP» (MGSVSnake, weapon_mgsv_*; в репозиторий не кладём -
  модели/звуки MGSV чужие): `lua/homigrad/compat/sh_mgsv.lua` - `hg.MGSV.Active(ply)`; пока Снейк в руках, homigrad уступает
  камеру (`cl_camera.lua`: renderscene и hook "homigrad-view"), отрисовку тела (`hg.renderOverride` в `sh_utility.lua`)
  и инерцию движения (`movement/sh_inertia.lua`). В регдолле/без сознания Снейк выключается. Схваченного CQC (`hg.MGSV.Held`)
  и регдоллы аддона (`hg.MGSV.IsRag`) рисует аддон/движок. Транквилизатор Снейка по организмам = дротик Z-city (5 DMG_CLUB, +5 tranquilizer).
  CQC по игрокам с организмом (`hg.MGSV.CQC`, Think "rem_mgsv_cqc" по последней фазе жертвы): броски/slam - только боль,
  нож (knf_kil) - горло как у тейкдауна (`hg.Takedown.CriticalInjuries`), удушение (choke_ed) - без сознания до 2 минут.
  OctoCamo (свой, без ассетов MGS): `compat/sh_mgsv_octocamo.lua` - строка в меню CAMO (mgsv_snake_drab 90, NW2 "rem_octo"),
  костюм перенимает текстуру только лёжа (пол) или упёршись в стену стоя/сидя (стена), 3 с неподвижно; рисуется через
  `MGSVSnake.DrawBody`; дисплейсменты (трава и т.п.) - по типу поверхности, запасные текстуры `materials/rem_octo`;
  картинки - `tools/octocamo/make.py`.
- Совместимость с отдельными аддонами ULTRAKILL (Weapons Pack, Movement Collection, Coin Mechanics; в репозиторий не кладём):
  `lua/homigrad/compat/sh_ultrakill.lua` - `hg.UK.Weapon(ply)` (оружие weapon_dredux_uk_*: камера движку, видна вьюмодель),
  `hg.UK.MoveOn(ply)` (ukmove_movement_enabled на сервере + выдано админом: `hg.UK.SetMove`, !ukmove / rem_ukmove <игрок|*> [1|0],
  сохраняется в data/zcity_ukmove.txt; хуки аддона обёрнуты - у кого не выдано, движение обычное homigrad).
  У кого движение ULTRAKILL работает - организм выключен (`org.remNoOrganism`): тик в `organism/tier_0/sv_tier_0.lua` пропускается,
  урон в `tier_1/sv_input.lua` идёт мимо организма обычным здоровьем; снятие - сброс `hg.organism.Clear`. Общая уступка камеры - `hg.CameraYield(ply)`
  (определена В КОНЦЕ sh_ultrakill.lua - не затереть при правках!). Руки ULTRAKILL Arms REVAMPED (VManip) - только у выданных
  (net-приёмники аддона обёрнуты; rem_ukarms_all 1 - у всех). ukmove_movement_enabled клиентам - GlobalBool "rem_ukmove_global".
- Ярость (3 стадии, копится от угроз: смотрят с оружием, целятся, фак, «умри»; удар - рывок и x2, без удара не выше 2-й):
  `modules/sv_rage.lua` и `cl_rage.lua` (музыка по стадиям `sound/rem_rage/anger.mp3`, права у пользователя,
  куски 0-59 / 58-117 / 117-конец), плитка «anger» с описанием в `cl_health_indicator.lua`.
- Совместимость с InfMap (бесконечные карты): `lua/autorun/!zcity_infmap.lua` + `lua/zcity_infmap/`, описание в `INFMAP.md`.
  Работает только на картах InfMap, выключается `zc_infmap 0`. Новое net-сообщение с позицией - дописать в списки
  `lua/zcity_infmap/sh_net.lua`.
