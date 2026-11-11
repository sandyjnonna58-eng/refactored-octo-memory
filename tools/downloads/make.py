# Список файлов аддона, которые игроки скачивают при входе на сервер -> lua/rem_downloads/list.lua
# (его читает lua/autorun/server/rem_downloads.lua). Берёт всё из git в materials/ sound/ models/ resource/ particles/,
# кроме личного (rem_wd_private, rem_drinks_private) и лицензий. Папки materials/rem_* и sound/rem_* сервер вдобавок
# обходит сам, так что новое в них подхватится и без перезапуска скрипта.
# Запуск из корня репозитория: python3 tools/downloads/make.py
import subprocess

EXT = ('.vmt', '.vtf', '.png', '.jpg', '.mdl', '.vvd', '.vtx', '.phy', '.ani', '.wav', '.mp3', '.ogg', '.ttf', '.otf', '.pcf', '.dat')
SKIP = ('rem_wd_private', 'rem_drinks_private')

out = subprocess.run(['git', 'ls-files', '-z', 'materials', 'sound', 'models', 'resource', 'particles', 'data_static'],
                     capture_output=True, check=True).stdout.decode()
files = sorted(f for f in out.split('\0') if f.lower().endswith(EXT) and not any(s in f for s in SKIP))

with open('lua/rem_downloads/list.lua', 'w', encoding='utf-8', newline='\n') as fh:
    fh.write('-- Сгенерировано tools/downloads/make.py - руками не править\nreturn {\n')
    for f in files:
        fh.write('\t"%s",\n' % f.replace('\\', '/').replace('"', '\\"'))
    fh.write('}\n')
print(len(files), 'files')
