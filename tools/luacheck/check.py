# Проверка синтаксиса GMod Lua во всех файлах (или в указанных): переводит GMod-расширения (!=, &&, ||, !, //, /* */,
# continue) в обычный Lua с учётом строк и комментариев и разбирает luaparser'ом (pip install luaparser).
# Запуск из корня репозитория: python3 tools/luacheck/check.py            - все .lua из git
#                              python3 tools/luacheck/check.py файл.lua ...  - только эти
import sys, re
from luaparser import ast

def convert(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # длинные строки/комментарии [[ ]] / [=[ ]=]
        if src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
                out.append('\n' * src[i:j].count('\n')); i = j; continue
            j = src.find('\n', i); j = n if j < 0 else j
            i = j; continue
        if src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j
            i = j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append('\n' * src[i:j].count('\n')); i = j; continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(src[i:j]); i = j; continue
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == '\\': j += 1
                elif src[j] == '\n': break
                j += 1
            out.append(src[i:j + 1]); i = j + 1; continue
        if src.startswith('!=', i): out.append('~='); i += 2; continue
        if src.startswith('&&', i): out.append(' and '); i += 2; continue
        if src.startswith('||', i): out.append(' or '); i += 2; continue
        if c == '!': out.append(' not '); i += 1; continue
        out.append(c); i += 1
    s = ''.join(out)
    s = re.sub(r'\bcontinue\b', 'goto continue_', s)
    return s

import subprocess
files = sys.argv[1:] or subprocess.run(['git', 'ls-files', '*.lua'], capture_output=True, text=True).stdout.split()
bad = 0
for p in files:
    try:
        src = open(p, encoding='utf-8-sig', errors='replace').read()
        ast.parse(convert(src))
    except Exception as e:
        msg = str(e).split('\n')[0][:160]
        print('FAIL', p, msg); bad += 1
print('checked', len(files), 'bad', bad)
# единственное известное срабатывание - gamemodes/zcity/gamemode/libraries/rtv/sv_rtv.lua (COMMANDS.кем): LuaJIT такие имена
# понимает, это не ошибка
