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
- В игре изменения проверяет пользователь; у Claude - только проверка синтаксиса Lua: `python3 tools/luacheck/check.py [файлы]`
  (без аргументов - все .lua; нужен pip-пакет luaparser).
- Серверный профайлер `lua/autorun/00_remorse_profiler.lua` работает только если `rem_profiler_enabled 1` на старте карты
  (иначе ничего не оборачивает); разовый замер - `rem_profile_sv` / `rem_profile` (homigrad/sh_hookprofiler.lua).
- Чужой защищённый контент (видео, фото товаров, выдранные модели) - не в публичный репозиторий, а в приватные паки,
  они в `.gitignore` (`materials/rem_wd_private`, `sound/rem_wd_private`, `materials/rem_drinks_private`),
  раздаются через FastDL-циклы в `lua/homigrad/skills/sv_skills.lua`.
- Раздача при входе: игрок качает только текущую карту, аддоны Мастерской сервера (engine.GetAddons; аддоны-карты - только
  тот, где текущая карта) + `rem_workshop_extra`, и Lua (AddCSLuaFile - всегда целиком): `lua/autorun/server/rem_downloads.lua`.
  Отдельные файлы (resource.AddFile/AddSingleFile у всех аддонов) по умолчанию глушит `lua/autorun/!!rem_download_gate.lua`;
  `rem_download_loose 1` возвращает их и список файлов аддона `lua/rem_downloads/list.lua` (после добавления контента вне
  папок rem_* - перегенерировать `python3 tools/downloads/make.py`). Новые звуки/текстуры всё равно регистрировать
  `resource.AddSingleFile` - на случай включённой раздачи.
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
- Чужие модели игрока с другой кистью/пальцами: позы кисти (`hg.set_hold`/`set_holdrh`) и `hg.KeepFingerLengths` (cl_bones.lua,
  зовётся в fake/sh_render.lua после оружия) берут положение суставов пальцев из скелета самой модели, иначе пальцы рвутся.
  Модели без `$includemodel "models/m_anm.mdl"` не получают анимаций wOS DynaBase (пинок и т.п.) - T-поза.

## Где что (сделано в этом проекте)
- Мысли (печатаются по буквам, звук на каждую букву по состоянию: normal / bad / fast): `lua/homigrad/sh_notification.lua`,
  звуки `sound/rem_speech/`. Крики при боли 75%+ («ITHURTSITHURTS...») - `lua/homigrad/sh_status_messages.lua`.
- Экранные эффекты: `lua/homigrad/screenfx/` - `cl_screenfx.lua` (удар, вспышка, боль: пульсирует с сердцем, дрожит,
  наплыв при скачке боли), `cl_fading.lua` (засветка при кровопотере, туннель при уходе сознания).
- Таймер смерти «вихрь» (84 с, ничего не вращается, медленно растёт): `lua/homigrad/vortexdeath/`. Запускается (sv_organism.lua,
  `dying`) только без сознания и если: сердце стоит, крови < death_blood (2500) или мозг теряет клетки (повреждение само
  растёт >= death_brain_rate 0.15%/с уже death_brain_hold 2 с; скачки от попаданий не в счёт); тогда же incapacitated. Позвоночник/трахея и т.п. - только incapacitated, без таймера.
- Экран смерти и выбор звука смерти (`rem_deathsound`, настройка Gameplay -> «Death sound: heart stop»):
  `lua/autorun/client/cl_cdeath.lua`, настройки - `lua/initpost/menu-n-derma/derma/cl_menu_options.lua`.
- Панель состояний (плитки, как в Fading Vitality: ряд слева направо от панели силуэта, первым сердце «pulse» (бьётся
  с org.pulsethink; только при rem_ecg 0 - иначе пульс на ЭКГ), остальные в порядке появления (iconOrder), пропала плитка - следующие скользят к сердцу (tileSlotX);
  тяжёлые приподняты и светятся): `lua/homigrad/cl_health_indicator.lua`. Без сознания осмотр показывается сам, тускло
  (силуэт не темнее 0.45, поверх пульсирующая темнота 35-65%), выкл. - `rem_otrub_inspect 0`.
  Значки - в стиле Fading Vitality (свои рисунки): белая основа `tools/affliction_icons/base` (make.py из Tabler),
  стиль и цвета - `tools/affliction_icons/make_fv.py` -> `materials/rem_affl`. Новый значок: в make.py и в STYLE make_fv.py.
  Свои рисунки в make.py: hypoxia, liver, arrhythmia (сердце с красной рваной кардиограммой - деталь не должна касаться контура).
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
- Совместимость с отдельными аддонами «ULTRAKILL Weapons Pack» и «ULTRAKILL Coin Mechanics» (в репозиторий не кладём; движение
  и руки ULTRAKILL - убраны): `lua/homigrad/compat/sh_ultrakill.lua`. Оружие weapon_dredux_uk_* работает как оружие zcity:
  камера homigrad, вьюмодели (рука V1) нет - модель *_3rd.mdl держит аватар (SetHandPos ставит кисть перед глазами, руку
  дотягивает hg.DoTPIK, DrawWorldModel2 рисует по кости R_Hand - её зовёт fake/sh_render.lua); анимации SWEP - Anim():
  поза невидимой вьюмодели (зеркало + моды SCK) минус покой -> кисть аватара и кости weapon_* модели в руке (поправки осей - FIX). В рэгдолл с этим
  оружием нельзя - при падении убирается (поддержку рэгдолла убрали по просьбе). Вьюмодель и руки не рисуются (PreDrawViewModel,
  метка remUKGun). Поля навешиваются на таблицы оружия (PreRegisterSWEP + уже созданные).
  `hg.CameraYield(ply)` (там же, её зовёт `cl_camera.lua`) теперь только для Снейка. Монетки (ultrakill_toss_coin) кода не
  требуют: их урон - обычный TakeDamageInfo с позицией попадания.
- Lambda gore mod (связка `compat/sh_lambdagore.lua`) пробовали - убран по просьбе; расчленёнка только своя у Z-City.
- Ярость (3 стадии, растёт ТОЛЬКО от: удара игрока, жеста «фак», «фак»/fuck в чате; удар - рывок и x2, без удара не выше 2-й):
  `modules/sv_rage.lua` и `cl_rage.lua` (музыка по стадиям `sound/rem_rage/anger.mp3`, права у пользователя,
  куски 0-59 / 58-117 / 117-конец), плитка «anger» с описанием в `cl_health_indicator.lua`.
- Паника (`modules/sv_panic.lua`, `sh_panic.lua`, `cl_panic.lua`; выкл. - `rem_panic_enabled`, тест - `rem_panic_set`): org.panic 0..1
  копится медленно: при смерти (Danger: кровь, кислород, боль, сознание, сердце) - быстрее всего, от страха выше 0.45 -
  медленнее, понемногу за удары и смерть человека на глазах; ярость её гасит.
  С 0.35: чёрные плывущие края экрана (слои tunnel.png), музыка `sound/rem_panic/panic.mp3` (трек пользователя; уступает
  любой особой музыке - OtherMusic: Duck/Exempt других модулей, hg.CritMusicPlaying, PanicStation), дыхание чаще (cl_main.lua), прицел
  гуляет, мысли; кто-то внезапно появился - рефлекторный выстрел (NW2 rem_panic_fire + рывок прицела), непроизвольные шаги.
  С 0.7 - сам убегает от угрозы (rem_panic_flee_*). Действия тела - StartCommand в sh_panic.lua. Плитка "panic" в осмотре.
- Самоповреждение (позыв при депрессии, жми E чтобы сопротивляться - старая механика, мини-игру с ножом убрали по просьбе):
  `modules/sv_depression.lua`, `cl_suicideurges.lua`. Тест: `rem_depression_set [0..1]` (админ, позыв через ~2-12 с при
  депрессии >= 0.4), `selfharm` - позыв сразу (нужна депрессия >= 0.5 и нож).
- Последний бой (`lua/homigrad/lastbattle/`): во время таймера смерти попытка (шанс zb_lastbattle_chance + 1%/мин) каждые 30 с,
  на половине и в конце (RollLastBattle, org.lastBattleTimer), раз за жизнь; старт - Revive (сердце запускается, таймер
  смерти снят, FakeUp), заставка "Not like this." (cl_lastbattle.lua: темнота-туннель, красный текст, удар сердца, серая
  засветка), таймера на экране нет; в бою needotrub/needfake гасятся (и в sv_organism.lua перед org.otrub = ...),
  hg.Fake обёрнут - в рэгдолл не уронить, сердце не встаёт, боли нет. Команда `zb_lastbattle [stop] <ник>` / `!lastbattle`.
- Музыка при уходе сознания (`lua/homigrad/remaudio/cl_remaudio_fading.lua`): по близости отключки Near() (худшее из сознания,
  боли, крови, кислорода, стадии шока; эхо до 0.35, "издалека" с 0.6; тест - `rem_fadingmusic_test 0..1`) вся музыка
  (каналы RemAudio, RA.IsMusic - только явный список RA.MusicPatterns в cl_remaudio.lua; звуки эффектов туда не
  добавлять - эхо их удвоит) сначала с эхом (копии файла с задержкой, RA.Taps), потом
  "издалека" (RA.Global - общий множитель громкости в cl_remaudio.lua, playback rate 0.94, эхо гуще); otrub - трек гаснет
  за 1.2 с, хвост эха за 3 с; очнулся - возврат за 2.5 с.
- BloodMark (кровь AdvancedBlood) пробовали несколько раз - убран по просьбе; кровь своя у Z-City.
- Пробоины и воронки от взрывов (картинка - столкновения карты не меняются): `lua/homigrad/explosives/sh_craters.lua`,
  `hg.ExplosionCrater(pos, power)` (сервер -> net rem_crater -> клиент: трассы в 14 сторон, до 3 ближайших поверхностей
  карты, util.DecalEx; стена - рваная пробоина, мягкая земля - воронка, металл - копоть; обломки HL2 клиентскими пропами).
  Зовут: projectile_base (РПГ, power = BlastDamage/200), ent_hg_grenade (BlastDis/12), СВУ, SLAM, ExpTypes в sv_explosives.
  Текстуры - `tools/craters/make.py` (свой VTF-писатель BGRA8888) -> `materials/rem_crater`. Выкл.: rem_craters 0;
  обломки у игрока - rem_craters_debris 0..2. Сквозные (TryPortal: стена тоньше 40, выходная пробоина с другой стороны):
  hg.Craters.RenderPortals(origin, angles, fov) рисует мир за стеной в RT (render.RenderView + PushCustomClipPlane по
  дальней стороне), PostDrawOpaqueRenderables показывает его трафаретом в рваном отверстии. Зовёт камера Z-City
  (cl_camera.lua renderscene, во всех ветках), без неё - свой хук RenderScene. rem_crater_portals (сколько сразу, 0 - выкл.),
  rem_crater_portal_res (доля экрана).
- Сердце по SCAV Prototype (`modules/sv_pulse.lua`, звуки - `cl_main.lua` RemCardiacSounds): шкала фибрилляции `org.fib` 0..100
  (+ fibForced). Растёт 1%/с (4%/с при пульсе > 280), падает 0.75%/с. Запуск/рост: пульс > 200, давление < 78 (рост < 88),
  кислород < 50% (< 60%), температура < 28 (< 28.5), forced; плохое сердце держит потолок (повреждение >= 0.2, ишемия,
  перегрузка, кровь < 4.0 л: 20..60, шок 3+, гипертония). Пульс +fib, +4/% выше 75, +30/% выше 95; 100% или пульс < 20 -
  остановка. Стадии: > 15 аритмия, > 50 желудочковая тахикардия, > 75 фибрилляция желудочков. Старые поля совместимы
  (SyncFibIn/SyncFibOut): arrhythmia = fib/100, fibrillation = fib >= 75 - дефибриллятор, последний бой и т.п. работают.
  AddCardiacStress(x) = +x*60%; попадание в сердце - 90% сразу (sv_organs.lua). Аритмия 25..75 - сознание медленно уходит
  (cap за 45 с) + мысль; фибрилляция - через давление и кислород. Пороги отключки в sv_pain.lua прежние (0.3 / 0.38);
  удар по черепу 1x. Плитки: arrhythmia, vtach, fibrillation, cardiac_arrest, tachycardia (> 110) / bradycardia (< 60).
  Удар плохого сердца - на каждый удар по счётчику hg.ECG.beats (кардиограмма идёт в Think "rem_ecg" всегда),
  sound.PlayFile без глушения, музыка 25% (RA.Duck "rem_badheart"). Звуки `sound/rem_heart/`
  (Fading Vitality, без авторских прав по словам пользователя): heartbeat_bad.mp3, arrhythmia.mp3 - фон при аритмии.
  ЭКГ-монитор - верхняя часть панели осмотра (общий фон/рамка, cl_health_indicator.lua): `lua/homigrad/cl_ecg.lua`
  (hg.ECG.Draw: BPM / SpO2, светлая полоса с давлением; линия пиксельная - столбики min/max, новое справа ярче со свечением).
  Формы с примеров пользователя (SHAPE): fast (> 110), slow (< 60), normal, vt (fib > 50, треугольники), wave - аритмия
  (fib > 15) и фибрилляция (> 75: чаще, неровнее, слабеет), остановка/fib >= 99 - красная прямая; выкл. - `rem_ecg 0`.
- Разрубание пополам оружием ближнего боя (косой разрез): `organism/sv_meleehalve.lua` - удар по туловищу (DMG_SLASH, лопата
  и DMG_CLUB) -> шанс по оружию (CHANCE: мечи 12-15%, топоры, мачете, лопата, ножи ~1% и только после 6 ран туловища;
  каждая прошлая рана +20%, до x3; бросок - раз за взмах: MultiDmg1 бьёт каждый тик, SWING_GAP 0.6 с; урон только от
  самого оружия (inflictor); rem_halve_chance - множитель, rem_halve 0 - выкл.), заведённая бензопила с зажатой
  ЛКМ - наверняка через 5 с пиления. Разрез cut = {sx, sy, ex, ey} в координатах торса (hg.TorsoFrame: x - доля
  полуширины, y - доля высоты таз..плечи): начало - место удара, конец - случайно на другом боку, не ниже пояса.
  Разделение - `sv_torsohalve.lua` Z-City (hg.CutTorso / hg.AmputateTorso(..., cut)): в режиме cut верх прячет только
  ноги, таз едет жёстко за грудью (AddRigidParent), низ прячет руки и голову, грудь едет за тазом; обрубки повёрнуты по
  плоскости (CapOnPlane); плоскость - NW2 rem_cut_* в осях кости. Клиент `organism/cl_torsocut.lua` оборачивает
  hg.renderOverride: проход 1 - всё по свою сторону плоскости, проход 2 - тело без туловища (кости туловища в NaN) по
  другую сторону, чтобы не срезать руки/ноги за плоскостью. Тест: `rem_halve_test` (админ, на кого смотришь) или
  контекстное меню -> Amputate Limb -> Cut In Half (diagonal) (admintools/sh_player_properties.lua, id 6).
- Отрубленные конечности (`organism/sv_severedlimbs.lua` + `cl_severedlimbs.lua`): на хук Z-City OnAmputateLimb (любое
  отрубание: катана, сильный режущий удар, взрыв, придавило) - копия регдолла, видны только голень+стопа / предплечье+кисть
  (LIMB_BONE и потомки), остальные кости: на сервере ManipulateBoneScale 0, физ. кости без столкновений и каждый тик едут в
  начало конечности; на клиенте hg.RemLimbCollapse (cl_severedlimbs.lua, колбэк BuildBonePositions) ставит им всем нулевую
  матрицу в точке среза - иначе кожа между точками сжатия тянется чёрными треугольниками, а на ClientsideModel (в руке)
  ноль у родителя гасит саму конечность. COLLISION_GROUP_WEAPON - берётся руками/E, не мешает ходить. Кровь: NW2 rem_limb_bleed (45 с),
  клиент - hg.addBloodPart из среза (rem_limb_bone), удары о пол - util.Decal. Шапки/броня не копируются (Accessories none).
  rem_severed_limbs 0 - выкл., _life (300 с), _max (16). Катана: 5% отрубить конечность - раз за взмах (MultiDmg1 бьёт каждый тик).
  E на конечность (PlayerUse) -> предмет `weapon_rem_flesh` (в руке - ClientsideModel тела, видна только конечность,
  PlaceRoot ставит начало конечности к ладони): ЛКМ - укус (5), сытость +6, тошнота 0.22 + 0.05 за каждый укус за жизнь.
- Наркотики (`modules/sv_drugs.lua` + `cl_drugs.lua`, предметы `weapon_rem_heroin` / `_meth` / `_lsd` на основе
  `weapon_rem_drug_base`): org.heroin / meth / lsd (доза ~1, выводятся минутами, тик из sv_organism после никотина).
  Героин - analgesia, сон, передоз > 1.8 - кислород падает (налоксон выводит); мет - выносливость, пульс (org.remHRAdd ->
  sv_pulse.lua), паранойя, передоз > 2.5 - AddCardiacStress и жар; кислота - трип, > 2 бэд-трип (org.panic, страх).
  Привыкание героина и мета - виды в hg.Addiction.Kinds (свои effects и craving ломки, sv_addiction.lua их зовёт).
  Звук мета - свой sound/rem_drugs/snort.wav (tools/sounds/make_snort.py); НЕ player/breathe1.wav - он зациклен.
  NW2 rem_high («Веселье», плитка euphoria), rem_heroin / rem_meth / rem_lsd; плитки heroin_wd / meth_wd. Тест: rem_drug_set.
  Смерть / возрождение (PlayerDeath, PlayerSpawn, "Player Spawn") - ResetDrugs: наркотики, тошнота и их NW2 в ноль
  (организм Z-City тот же - иначе эффекты остаются); зависимость и ломка тоже сбрасываются при смерти (sv_addiction.lua ResetAddiction).
  "Reset organism" (контекстное меню, hg.organism.Clear -> хук "Org Clear") сбрасывает панику, наркотики, тошноту и ломку.
- Тошнота: стадии в sv_vomit.lua AddNausea (0.45 / 0.8 - мысль; плитка Queasy / Nauseous / About to vomit), экран -
  `modules/cl_nausea.lua` (зеленеет, плывёт, качает). От вида расчленёнки - `modules/sv_gorenausea.lua` (раз в секунду:
  конечности, разрубленные тела, без головы в поле зрения до 450; привыкание rem_goreTol до -90%; ярость и героин глушат;
  тошнота сама проходит 0.003/с); от плоти - weapon_rem_flesh; от героина и ломки - sv_drugs.lua. rem_gore_nausea 0 - выкл.
- Осколки (гранаты ent_hg_grenade, взрывы hg.PropExplosion / StartShrapnel в explosives/sv_explosives.lua, СВУ weapon_traitor_ied):
  попадание в стену / проп -> `hg.ShrapnelImpact` - короткая пуля Z-City (FireLuaBullets, урон 1) у места попадания: след и
  пробоина, её видят аддоны пробоин через EntityFireBullets / PostEntityFireBullets / callback. Лимит на взрыв `rem_frag_impacts`.
  GHM Ballistic Damage - отдельный аддон из Мастерской, обфусцирован, автор запрещает распространение и правку: в репозиторий
  не кладём и не трогаем; пули Z-City вызывают те же хуки, что пули движка. Наш RenderScene (cl_camera.lua) рисует кадр
  сам и глушит чужие RenderScene - CallOtherRenderScene зовёт их перед своим кадром (иначе в пробоине GHM пустота).
- Совместимость с InfMap (бесконечные карты): `lua/autorun/!zcity_infmap.lua` + `lua/zcity_infmap/`, описание в `INFMAP.md`.
  Работает только на картах InfMap, выключается `zc_infmap 0`. Новое net-сообщение с позицией - дописать в списки
  `lua/zcity_infmap/sh_net.lua`.
- ИИ-помощник Gemini AI (бесплатный API Google Gemini, ИИ пишет и выполняет серверный GLua): `lua/autorun/gemini_ai_init.lua`,
  `lua/gemini_ai/` (sv_core - запросы и выполнение кода, sv_commands - команды gemini_ai_* и !ai, cl_chat - окно и вкладка Q,
  cl_settings - Q -> Утилиты -> Gemini AI), энтити `gemini_ai_terminal` (Q -> Энтити -> Gemini AI, E - открыть чат).
  Ключ - только на сервере, `data/gemini_ai/config.json` (gemini_ai_setkey), лог кода - `data/gemini_ai/log.txt`.
  Связка с рекосом - `lua/gemini_ai/sv_compat_remorse.lua`: организм в контексте ИИ, помощники AI.Heal (hg.organism.Clear),
  AI.Ragdoll/GetUp (hg.Fake/FakeUp), AI.Stun, AI.Vomit, AI.Org, AI.Give. Чат: команды ловятся в HG_PlayerSay (ZChat) и
  глушатся в PlayerSay (ply.GeminiAI_Suppress), иначе !aikey с ключом ушёл бы в общий чат. Права: GeminiAI.Chat/Execute/Admin
  (CAMI, без него - superadmin). Описание и все команды - `GEMINI_AI.md`.
  ИИ-персонажи (`lua/gemini_ai/sv_character.lua`, окно `cl_character.lua`, энтити-спавнер `gemini_ai_character`):
  бот player.CreateNextBot + bot.GeminiChar. Мозг - таймер GeminiAI_CharBrain: восприятие (Perception: своё состояние
  по организму, кто рядом и виден, оружие на земле, услышанное, события, [РЕЖИССЁР]-приказы) -> Gemini (своя схема
  {say, action, target, thought}, модель gemini_ai_char_model, общий лимит char_rpm) -> ApplyDecision. Тело - StartCommand:
  A* по навмешу (без навмеша - по прямой), атака держит IN_ATTACK2 (оружие homigrad без прицеливания не стреляет),
  из регдолла встаёт hg.FakeUp. Речь - hook.Run("PlayerSay", bot) (ZChat подписывает именем) или bot:Say; ведущие !/. срезаются.
  Слух - HG_PlayerSay + PlayerSay (дубли отсекаются), ИИ-соседи будят друг друга только по имени (иначе бесконечная болтовня).
  Реальное время: opts.fast в GeminiAI.Request - thinkingConfig.thinkingBudget = 0 (модель без размышлений). На любой 400
  (кроме ключа/региона) запрос упрощается и повторяется: GeminiAI.ModelLevel[model] 1 - без fast, 2 - ещё и без
  responseSchema (JSON по инструкции); ответ Google пишется в консоль сервера. Проверка пути персонажей: gemini_ai_test char. Wake(char, delay): обращение (имя / смотрит на бота / ближе 350)
  - мысль сразу; занят - char.pending, после ответа думает снова. Облачка над головой и «...» - NW2 GeminiSay/GeminiSayTime/
  GeminiThinking/GeminiChar, рисует HUDPaint "GeminiAI_CharBubbles" в cl_character.lua.
  Провайдеры (gemini_ai_provider): gemini / deepseek / custom (OpenAI-совместимый: OpenRouter, Ollama...). GeminiAI.Request
  выбирает RequestGemini или RequestOpenAI (sv_core.lua); у OpenAI-формата схема ответа уходит текстом (SchemaHint) +
  response_format json_object (на 400 - повтор без него), <think> и ``` вырезаются в ParseJSONText. Ключи - API_KEYS[провайдер]
  в config.json (keys), старый key переносится в gemini. Модель - GeminiAI.ActiveModel(forChar) (sh_shared): у Gemini
  model/char_model, у DeepSeek ds_model, у custom custom_model; в запросах персонажей opts.char = true, не модель.
