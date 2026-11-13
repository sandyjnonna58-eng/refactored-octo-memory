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
- Живые реакции регдолла (по мотивам мода ReAgdoll, который прислал пользователь; его код и ассеты не брали - свой код):
  `lua/homigrad/fake/sv_reagdoll.lua`. Учёт регдоллов: хук "Fake" (упал) и DoPlayerDeath (регдолл смерти; умер лёжа -
  переводится в мёртвого в Think). 1) хватается за свежую рану (org.wounds / arterialwounds, моложе 2 с; рука не раненая,
  не отрубленная) через hg.ShadowControl как ручное зажатие Z-City; в сознании 4..10 с, без сознания слабо, мёртвый - угасает
  9 с; 2) пытается устоять (ApplyBalance): упал от попадания стоя (рана < 1 с) - 2.5..5 с (x rem_reag_stand_time; меньше от
  боли, крови, сломанной/отрубленной ноги, без сознания - нет) таз тянется к прежней высоте + противовес тяжести, корпус и
  голова выпрямляются (Align: ось Forward кости к вертикали через AddAngleVelocity), бёдра/голени под себя и в сторону
  крена/движения (спотыкающиеся шаги по очереди), колени иногда подкашиваются на 0.2-0.4 с; за рану держится почти всегда;
  завалился (таз < 45% высоты, корпус лёг) - конец. Умер стоя - оседает 0.8..1.5 с; 3) в полёте машет руками/ногами (AddAngleVelocity), руки отдаёт fallCover Z-City перед
  землёй; 4) в полёте рука в сознании задела стену/край (не пол) - constraint.Ballsocket на 1.5..4 с (создаётся через
  timer.Simple(0) - не в колбэке), отпускает: прыжок, без сознания, смерть. Рукой, которой управляет игрок (ЛКМ/ПКМ/E,
  оружие, ConsLH/ConsRH, ручное зажатие), не двигаем. Квары: rem_reag, rem_reag_hold_chance (80), rem_reag_stagger,
  rem_reag_flail, rem_reag_grab, rem_reag_stand_time (1). Рана - по физике кости (не GetBonePosition: у тела смерти матрицы нулевые - тянуло
  руку вдаль и растягивало); дальше 28 от плеча - тянется насколько достаёт (не растягивая), живой подтягивает раненую
  ногу к рукам. Рука - свободная (weapon_hands_sh помечен ismelee, но руку не занимает; правой держит оружие - левой);
  рана жива, пока в списке есть рана с тем же временем [5] и костью [4] (Z-City пересобирает список - по ссылке рука отпускала). Оригинальный ReAgdoll вместе с Z-City ставить нельзя: свой
  регдолл при смерти поверх регдолла Z-City и ломание суставов (RemoveInternalConstraint) - тело разрывает.
  5) закрывается (ApplyGuard, rem_reag_guard): DMG_CLUB от рук/ног (инфликтор weapon_hands_sh / weapon_hg_coolhands или сам
  игрок - пинки, кулаки) или по голове - кисти на голову, предплечья перед лицом, лёжа колени к груди, 2..3.5 с от удара;
  тупое оружие по телу - держится за место удара (spot: физ. кость + местная точка, 2.5..5 с). Стоял - запоминается в
  ply.remReagHit, упал за 1 с - реагирует (и пробует устоять). Удар ловится хуком Z-City "HomigradDamage" (+ Post как
  запасной, раз за тик): одного PostEntityTakeDamage мало - Z-City перенаправляет урон игрока в регдолл и глушит его.
  Отладка - rem_reag_debug 1 (в консоль сервера: guard / holding / club hit). Перед/право/верх тела - BodyFrame по точкам костей.
  6) шёл/бежал и сбили (скорость игрока в хуке Fake / DoPlayerDeath или тела) - ApplyBalance с walk: тело тянет вперёд со
  скоростью шага (затухает), корпус чуть вперёд, ноги по очереди выносятся, шагающая сгибается; живой 1.2..2.6 с, убитый
  0.5..0.9 с. Общая сила всех реакций - rem_reag_strength (1.35) x характер тела st.mul (RollMul на жизнь, ply.remReagMul,
  сброс в PlayerSpawn): 25% слабые 0.35..0.7, 50% обычные 0.85..1.25, 25% очень сильные 1.6..2.4; от него и время стояния;
  rem_reag_variety 0 - всем 1. Руки/ноги тянет свой Shadow (ComputeShadowControl напрямую) - hg.ShadowControl делит силу
  на ragdoll.power (от боли почти 0). Блок (предплечья скрещены перед лицом) - только на само
  попадание кулаком/пинком/тупым по голове, 1.2..2 с (продлевается каждым ударом). Заранее на замах/ЛКМ/начало пинка
  (BlockNear) делали - убрано по просьбе. 7) огонь и ток (ApplyFireShock, rem_reag_fire): горит (IsOnFire регдолла/игрока или DMG_BURN 1.5 с) - катается
  вдоль оси тела (AddAngleVelocity вокруг BodyFrame up, смена стороны 0.9..1.6 с), руки хлопают по груди, ноги дёргаются;
  жмёт A/D - не мешаем. Судороги (рывки конечностей, к концу слабеют) - только во время эпилептического припадка
  (org.seizureActive до seizureEnd); сам ток судорог не даёт. DMG_SHOCK - эпилептический припадок (шанс rem_reag_epilepsy_chance 100,
  бросок раз в секунду): hg.organism.StartEpilepsy(owner, org, 20..40 с) в sv_organism.lua - обычный припадок Z-City
  (org.seizureActive: needfake, поза/тряска, вспышки и звук на клиенте), но длина org.remSeizureDur и без урона мозгу
  в конце (обычный - 90 с и смерть мозга). Огонь/ток ловит свой EntityTakeDamage (Z-City глушит урон огнём рано).
  Управление не перехватывается (rem_reag_lock 1, по умолчанию): пока идёт реакция (стоит, держит рану, блок, полёт,
  перекат, припадок) StartCommand "rem_reagdoll_lock" убирает только ЛКМ/ПКМ/R (руки у реакции); телом игрок двигает сам -
  WASD/прыжок/присед/бег/E/мышь работают: при WASD стояние не держит/не ведёт тело по горизонтали, в огне не катаем сами
  (Moving); при E спину/голову не выпрямляем, руки E не занимают. Старый вариант - реакции уступают любой кнопке (Controlling,
  rem_reag_yield 1, по умолчанию 0).
- Lambda gore mod (связка `compat/sh_lambdagore.lua`) пробовали - убран по просьбе; отрезание головы - sv_decap.lua на моделях Zippy.
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
- Разрубание пополам оружием ближнего боя: `organism/sv_meleehalve.lua` - удар по туловищу (CutFromHit: между поясом и
  плечами; DMG_SLASH, лопата и DMG_CLUB) -> шанс по оружию (CHANCE: мечи 12-15%, топоры, мачете, лопата, ножи ~1% и только
  после 6 ран туловища; каждая прошлая рана +20%, до x3; бросок - раз за взмах: MultiDmg1 бьёт каждый тик, SWING_GAP 0.6 с;
  урон только от самого оружия (inflictor); rem_halve_chance - множитель, rem_halve 0 - выкл.), заведённая бензопила с
  зажатой ЛКМ - наверняка через 5 с пиления. Разрез ровный, как у Z-City: hg.CutTorso в `sv_torsohalve.lua` (файл Z-City,
  добавлены эта функция и задержка 0.15 с в EnsureFakeAndSplit, если человек только что упал в регдолл: иначе обрубок
  цеплялся к ещё не вставшим костям и съезжал к плечу). Косой разрез (плоскость отсечения на клиенте) пробовали - рисовался с багами, убран по
  просьбе. Кости для CutFromHit - у регдолла по физике, у игрока после SetupBones (старые матрицы - удар не узнавался); пила считает
  5 с по человеку (упал в регдолл - не сначала). В консоль - [rem_halve]: удары, шанс, почему нет. Тест: `rem_halve_test` (админ, на кого смотришь); в меню - Amputate Limb -> Amputate Torso (это Z-City).
- Отрезание головы режущим оружием: `organism/sv_decap.lua` + `cl_decap.lua` - ножи, мачете, топоры, мечи, бензопила
  (CLASS_KIND + по имени класса). Z-City сносит голову с одного сильного удара (sv_input.lua, instant) - для этого оружия
  заблокировано (hg.RemDecapBlocks; и в отложенном взрыве головы мёртвого тела - таймер dmgstack в sv_input.lua,
  иначе после смерти голова взрывалась и удары дальше не считались); здесь: удар по голове/шее (HeadHit у Head1/Neck1), раз за взмах (пила - раз в 0.5 с),
  с 4-го удара шанс по виду (KIND_CHANCE: нож 20%, мачете 35%, топор 45%, меч 50%, пила 60%) -> hg.Decapitate (живого -
  Kill и через 0.15 с регдолл смерти). Модели и расстановка - Zippy's Gore Mod Enhanced (dismemberment.lua; модели
  пользователь прислал сам): голова - копия регдолла, видна только Head1 (сервер - scale 0 и физ. кости едут за головой,
  клиент - колбэк BuildBonePositions сжимает всё в точку среза), снизу рваный обрубок models/limbspartial/unistump (Zippy; FollowBone
  Head1, масштаб 3, угол 90,0,0 - ось вдоль кости, сдвиг -1.2,0,0 - HEAD_CAP_*); на теле Gib_RemoveBone(Head1), на шее headpartial5 (FollowBone Neck1, NeckCapPlace: угол/сдвиг по
  модели - мужская / женская / alyx, mossman; плюс NECK_DOWN 3.5 вниз по шее - у Zippy он торчал на месте головы), фонтан Z-City (addfountain), шапки/очки уходят с головой, шлем/маска
  падают. Голова: лишние кости без физики ещё и ManipulateBonePosition(-местное смещение) - к началу родителя, а
  физические каждый тик в начале головы: всё тело в одной точке у среза даже без клиентского колбэка (он у регдоллов,
  похоже, не всегда работает - воротник торчал вокруг головы). Разнообразие: срез Fallout NV на шее
  (models/mosi/fnv/props/character/headcap.mdl) встал боком на плечо - отключён (USE_FNV_NECK = false); на шее всегда
  обрубок L4D из Lambda (headpartial5 Zippy - только запасной: торчал над плечами) (models/noob_dev2323/gib/l4d/common_infected_w_neck.mdl, FollowBone Neck1,
  угол/сдвиг из giblist.lua мода; родная текстура битая - своя перекраска жёлтой materials/rem_gore/l4d_neck_wound.vtf,
  tools/gore/make_l4d_neck.py, vmt master_wound_cmapmaterial переписан на неё); под головой - всегда
  unistump (выбран пользователем из 12 вариантов Zippy; headcap Lambda убран - в присланном rar битый). Bonemerge - BonemergeProp: SetParent + Fire
  SetParentAttachment (как у Lambda / кишок Z-City), без точки крепления модель встаёт в таз. HeadHit - отрезок шея..макушка
  вдоль кости Head1, у регдолла по физике (матрицы костей регдолла на сервере бывают старые). В консоль - [rem_decap]:
  счёт ударов, промах шанса, отрезано / почему нет. У головы клиент ставит SetRenderClipPlane на 2 ниже начала кости
  головы (cl_decap.lua CLIP_BELOW) - иначе воротник торчит лоскутами вокруг головы. Ассеты - models/headpartial, models/gore,
  models/mosi (+ materials).
  Тест: rem_decap_test, меню Amputate Limb -> Cut Off Head (id 7). rem_decap 0 - выкл.
- Отрубленные конечности отдельными кусками (подбирать, есть - weapon_rem_flesh) делали - убраны по просьбе.
  Катана: 5% отрубить конечность - раз за взмах (MultiDmg1 бьёт каждый тик).
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
  `modules/cl_nausea.lua` (зеленеет, плывёт, качает); сама проходит 0.003/с (таймер rem_nausea_decay в sv_vomit.lua);
  от героина и ломки - sv_drugs.lua. Тошноту от вида расчленёнки (sv_gorenausea.lua) делали - убрана по просьбе.
- Осколки (гранаты ent_hg_grenade, взрывы hg.PropExplosion / StartShrapnel в explosives/sv_explosives.lua, СВУ weapon_traitor_ied):
  попадание в стену / проп -> `hg.ShrapnelImpact` - короткая пуля Z-City (FireLuaBullets, урон 1) у места попадания: след и
  пробоина, её видят аддоны пробоин через EntityFireBullets / PostEntityFireBullets / callback. Лимит на взрыв `rem_frag_impacts`.
  GHM Ballistic Damage - отдельный аддон из Мастерской, обфусцирован, автор запрещает распространение и правку: в репозиторий
  не кладём и не трогаем; пули Z-City вызывают те же хуки, что пули движка. Наш RenderScene (cl_camera.lua) рисует кадр
  сам и глушит чужие RenderScene - CallOtherRenderScene зовёт их перед своим кадром (иначе в пробоине GHM пустота).
- Совместимость с InfMap (бесконечные карты): `lua/autorun/!zcity_infmap.lua` + `lua/zcity_infmap/`, описание в `INFMAP.md`.
  Работает только на картах InfMap, выключается `zc_infmap 0`. Новое net-сообщение с позицией - дописать в списки
  `lua/zcity_infmap/sh_net.lua`.
- ИИ-помощник Gemini AI (lua/gemini_ai, энтити gemini_ai_terminal / gemini_ai_character, GEMINI_AI.md) - убран из сборки по просьбе.
