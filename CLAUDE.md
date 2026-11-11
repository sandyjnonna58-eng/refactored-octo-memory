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
- Таймер смерти «вихрь» (84 с, ничего не вращается, медленно растёт): `lua/homigrad/vortexdeath/`.
- Экран смерти и выбор звука смерти (`rem_deathsound`, настройка Gameplay -> «Death sound: heart stop»):
  `lua/autorun/client/cl_cdeath.lua`, настройки - `lua/initpost/menu-n-derma/derma/cl_menu_options.lua`.
- Панель состояний (плитки, как в Fading Vitality: ряд слева направо от панели силуэта, первым всегда сердце «pulse» (бьётся
  с org.pulsethink), остальные в порядке появления (iconOrder), пропала плитка - следующие скользят к сердцу (tileSlotX);
  тяжёлые приподняты и светятся): `lua/homigrad/cl_health_indicator.lua`.
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
- Совместимость с отдельными аддонами «ULTRAKILL Weapons Pack» и «ULTRAKILL Coin Mechanics» (в репозиторий не кладём; движение
  и руки ULTRAKILL - убраны): `lua/homigrad/compat/sh_ultrakill.lua`. Оружие weapon_dredux_uk_* работает как оружие zcity:
  камера homigrad, вьюмодели (рука V1) нет - модель *_3rd.mdl держит аватар (SetHandPos ставит кисть перед глазами, руку
  дотягивает hg.DoTPIK, DrawWorldModel2 рисует по кости R_Hand - её зовёт fake/sh_render.lua); анимации SWEP - Anim():
  поза невидимой вьюмодели (зеркало + моды SCK) минус покой -> кисть аватара и кости weapon_* модели в руке (поправки осей - FIX). В рэгдолл с этим
  оружием нельзя - при падении убирается (поддержку рэгдолла убрали по просьбе). Вьюмодель и руки не рисуются (PreDrawViewModel,
  метка remUKGun). Поля навешиваются на таблицы оружия (PreRegisterSWEP + уже созданные).
  `hg.CameraYield(ply)` (там же, её зовёт `cl_camera.lua`) теперь только для Снейка. Монетки (ultrakill_toss_coin) кода не
  требуют: их урон - обычный TakeDamageInfo с позицией попадания.
- Совместимость с отдельным аддоном «Lambda gore mod» (в репозиторий не кладём - модели/звуки чужие, частью из L4D):
  `lua/homigrad/compat/sh_lambdagore.lua` (выкл. - `rem_lambdagore 0`). Своя логика Lambda (порча трупов по костям, разрез
  пополам, взрыв тела, живая расчленёнка NPC, кэш урона) под Z-City выключена (hook.Remove списка OFF) - разрыв пополам и
  взрыв тела у Z-City свои. От Lambda только картинка на OnAmputateLimb (руки - Forearm, ноги - Calf): оторванная часть
  падает рэгдоллом (LG.DropLimb: сервер - prop_ragdoll без отрисовки, клиент - bonemerge-копия с одеждой-сабматериалами,
  net rem_lgore_limb), от взрыва вместо целой - куски goremod_CustomGibs; кровь - хук noob_gore_make_limb_blood.
  Обрубки - Lambda (LG.Stump, bonemerge на плечо/бедро, клиент вешает на того, кем нарисован игрок, и на трупы,
  timer rem_lambdagore_stumps; FitStump - крупнее вокруг места отрыва и наружу: rem_lambdagore_stump_scale / _push);
  свой обрубок Z-City (cl_main.lua GoreCalc) при работающем Lambda не рисуется. Физика оторванной части у рэгдоллов
  (LG.HideLimbPhysics: CONTENTS_EMPTY, без столкновений, держится у места отрыва) - на отрыве и в Ragdoll_Create.
  BloodMark: оторванная конечность (организм) и кости с NaN-позицией (разрез пополам) - Z.BoneHidden / Z.BoneMatrix
  (sh_zcity.lua) и сжатие в Pose:Bone (cl_bodymesh.lua: оторванная - в точку отрыва, NaN - к родителю), иначе кровь
  течёт по невидимой руке / тянется лентой или в бесконечность.
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
- BloodMark - только кровь (AdvancedBlood из чужого аддона «[ZCITY] BloodMark»; модули травм головы/мозга, лёгких и скелета
  убраны по просьбе): `lua/autorun/advancedblood.lua` (ABL - кровь, раны, лужи, следы), код `lua/advancedblood/`, контент
  `materials/advancedblood`. Тестовые сценарии разработчика (*test*, selftest, hostile) из сборки убраны. Настройки по умолчанию
  снижены ради FPS (sh_config.lua: abl_quality 2 - без отражений в лужах, abl_budget_ms 1.5, abl_sim_hz 100, меньше лимитов;
  у игроков со старыми настройками применяются один раз, метка data/abl_perf_v1.txt). К homigrad цепляется после загрузки
  (InitPostEntity / HomigradRun) и ОБОРАЧИВАЕТ (не заменяет) наши хуки: "organism-think-client-blood" (cl_main.lua),
  "ResponsiveHits_..." (sv_util.lua, брызги крови - вместо них своя кровь). Хук с таким же именем у нас - сначала смотреть,
  не обёрнут ли он BloodMark. Файлы раздаются через rem_downloads. `tools/vtf/halve.py` - уменьшение VTF вдвое без перекодирования.
- Совместимость с InfMap (бесконечные карты): `lua/autorun/!zcity_infmap.lua` + `lua/zcity_infmap/`, описание в `INFMAP.md`.
  Работает только на картах InfMap, выключается `zc_infmap 0`. Новое net-сообщение с позицией - дописать в списки
  `lua/zcity_infmap/sh_net.lua`.
