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
  они в `.gitignore` (`materials/rem_wd_private`, `sound/rem_wd_private`, `materials/rem_drinks_private`,
  `sound/rem_rage_private`),
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
- Алкоголь, никотин, привыкание, сосуды, рвота: `lua/homigrad/organism/tier_1/modules/` (`sv_alcohol`, `sv_nicotine`,
  `sv_addiction`, `sv_vessels`, `sv_vomit` и их `cl_`). Напитки - `weapon_hg_vodka` (база) и наследники, сигареты -
  `weapon_hg_cigarettes`.
- Тейкдауны, камера FC, лечение FC, бросок ножа (E + ПКМ): `lua/homigrad/takedowns`, `fccamera`, `fcheal`, `meleethrow`.
- Ярость (3 стадии, копится от угроз: смотрят с оружием, целятся, фак, «умри»; удар - рывок и x2, без удара не выше 2-й):
  `modules/sv_rage.lua` и `cl_rage.lua` (музыка по стадиям из приватного `sound/rem_rage_private/anger.mp3`,
  куски 0-59 / 58-117 / 117-конец), плитка «anger» с описанием в `cl_health_indicator.lua`.
