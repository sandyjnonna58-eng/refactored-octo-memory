# Проверка синтаксиса GMod Lua и лимитов LuaJIT (60 upvalue / 200 локальных на функцию) во всех файлах (или в указанных): переводит GMod-расширения (!=, &&, ||, !, //, /* */,
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

# Лимиты LuaJIT, которые синтаксис не ловит, а в игре файл целиком не грузится: у функции больше 60 upvalue
# ("function at line N has more than 60 upvalues") или больше 200 локальных переменных одновременно.
from luaparser import astnodes as N
MAX_UPVALUES, MAX_LOCALS = 60, 200

class Limits:
    def __init__(self):
        self.funcs = []   # стек: [строка, set upvalue, число активных локальных, максимум]
        self.scopes = []  # стек: (индекс функции, dict имя -> id)
        self.problems = []
        self.ids = 0

    def declare(self, name):
        self.ids += 1
        self.scopes[-1][1][name] = self.ids
        f = self.funcs[-1]
        f[2] += 1
        f[3] = max(f[3], f[2])

    def ref(self, name):
        for fi, names in reversed(self.scopes):
            if name in names:
                for k in range(fi + 1, len(self.funcs)):  # все функции между объявлением и местом - захватывают
                    self.funcs[k][1].add(names[name])
                return

    def block(self, stmts, pre=None):
        fi = len(self.funcs) - 1
        self.scopes.append((fi, {}))
        if pre: pre()
        for st in stmts: self.node(st)
        self.funcs[fi][2] -= len(self.scopes[-1][1])
        self.scopes.pop()

    def func(self, node, args, body, extra=()):
        self.funcs.append([getattr(node, 'line', None) or '?', set(), 0, 0])
        def pre():
            for n in extra: self.declare(n)
            for a in args:
                if isinstance(a, N.Name): self.declare(a.id)
        self.block(body.body, pre)
        line, ups, _, mx = self.funcs.pop()
        if len(ups) > MAX_UPVALUES: self.problems.append('function at line %s: %d upvalues (> %d)' % (line, len(ups), MAX_UPVALUES))
        if mx > MAX_LOCALS: self.problems.append('function at line %s: %d locals (> %d)' % (line, mx, MAX_LOCALS))

    def node(self, n):
        if n is None: return
        if isinstance(n, list):
            for x in n: self.node(x)
            return
        if not isinstance(n, N.Node): return
        if isinstance(n, N.Name): self.ref(n.id); return
        if isinstance(n, N.LocalAssign):
            self.node(n.values)
            for t in n.targets: self.declare(t.id)
            return
        if isinstance(n, N.LocalFunction):
            self.declare(n.name.id); self.func(n, n.args, n.body); return
        if isinstance(n, N.Method):
            self.node(n.source); self.func(n, n.args, n.body, ('self',)); return
        if isinstance(n, N.Function):
            self.node(n.name); self.func(n, n.args, n.body); return
        if isinstance(n, N.AnonymousFunction):
            self.func(n, n.args, n.body); return
        if isinstance(n, N.Index):
            self.node(n.value)
            if n.notation != N.IndexNotation.DOT: self.node(n.idx)
            return
        if isinstance(n, N.Invoke):
            self.node(n.source); self.node(n.args); return
        if isinstance(n, N.Field):
            if n.between_brackets: self.node(n.key)
            self.node(n.value); return
        if isinstance(n, (N.Goto, N.Label)): return
        if isinstance(n, N.Fornum):
            self.node([n.start, n.stop, n.step])
            self.block(n.body.body, lambda: self.declare(n.target.id)); return
        if isinstance(n, N.Forin):
            self.node(n.iter)
            self.block(n.body.body, lambda: [self.declare(t.id) for t in n.targets]); return
        if isinstance(n, N.Repeat):
            def rep():
                pass
            fi = len(self.funcs) - 1
            self.scopes.append((fi, {}))
            for st in n.body.body: self.node(st)
            self.node(n.test)  # условие repeat видит локальные тела
            self.funcs[fi][2] -= len(self.scopes[-1][1])
            self.scopes.pop()
            return
        if isinstance(n, N.Block):
            self.block(n.body); return
        for k, v in vars(n).items():
            if k.startswith('_') or k in ('comments', 'line', 'start_char', 'stop_char', 'first_token', 'last_token', 'wrapped'): continue
            if isinstance(v, (N.Node, list)): self.node(v)

def check_limits(tree):
    L = Limits()
    L.funcs.append(['main chunk', set(), 0, 0])
    L.block(tree.body.body)
    if L.funcs[0][3] > MAX_LOCALS: L.problems.append('main chunk: %d locals (> %d)' % (L.funcs[0][3], MAX_LOCALS))
    return L.problems

import subprocess
files = sys.argv[1:] or subprocess.run(['git', 'ls-files', '*.lua'], capture_output=True, text=True).stdout.split()
bad = 0
for p in files:
    try:
        src = open(p, encoding='utf-8-sig', errors='replace').read()
        tree = ast.parse(convert(src))
        for prob in check_limits(tree):
            print('FAIL', p, prob); bad += 1
    except Exception as e:
        msg = str(e).split('\n')[0][:160]
        print('FAIL', p, msg); bad += 1
print('checked', len(files), 'bad', bad)
# единственное известное срабатывание - gamemodes/zcity/gamemode/libraries/rtv/sv_rtv.lua (COMMANDS.кем): LuaJIT такие имена
# понимает, это не ошибка
