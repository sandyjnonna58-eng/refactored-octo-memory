# Значки состояний в стиле Fading Vitality (свои рисунки, не из игры) -> materials/rem_affl/*.png
# Берёт белую основу из tools/affliction_icons/base (её делает make.py) и перерисовывает:
#   крупные пиксели (32x32, увеличено до 96), зерно, тёмная обводка, цветные акценты;
#   органы и предметы - закрашенные (третий элемент STYLE - цвет детали внутри, например красный порез) бледные пятна с тенью ("fill"), лица - тёмная клякса с белыми глазами ("face"),
#   знаки тревоги - цветная плашка с белым рисунком ("badge"), остальное - линии своего цвета ("line").
# Запуск из корня репозитория: python3 tools/affliction_icons/make_fv.py
import os, random
import numpy as np
from PIL import Image

HERE = os.path.dirname(__file__)
BASE = os.path.join(HERE, 'base')
OUT = os.path.join(HERE, '..', '..', 'materials', 'rem_affl')
N, SIZE = 32, 96

WHITE = (238, 232, 228)
STYLE = {
    'adrenaline': ('line', (255, 95, 95)),
    'alcohol': ('fill', (205, 140, 55)),
    'alcohol_wd': ('fill', (225, 165, 85)),
    'amputation': ('fill', (226, 182, 150), (200, 25, 25)),
    'anger': ('face', (255, 70, 60)),
    'arrhythmia': ('fill', (236, 210, 204), (205, 25, 25)),
    'vtach': ('fill', (236, 196, 190), (225, 20, 20)),
    'tachycardia': ('fill', (236, 214, 208), (215, 60, 40)),
    'bradycardia': ('fill', (220, 222, 232), (60, 90, 210)),
    'arterial': ('fill', (200, 18, 18)),
    'bleeding': ('fill', (205, 22, 22)),
    'blind': ('fill', (232, 226, 218)),
    'bloodloss': ('fill', (170, 20, 20)),
    'brain': ('fill', (228, 172, 182)),
    'burning': ('fill', (255, 140, 35)),
    'cardiac_arrest': ('fill', (232, 224, 218)),
    'cold': ('fill', (150, 200, 255)),
    'concussion': ('line', (255, 228, 140)),
    'critical': ('badge', (225, 25, 25)),
    'depression': ('line', (140, 160, 205)),
    'dislocation': ('fill', (236, 226, 200)),
    'fatigue': ('fill', (232, 226, 218)),
    'fear': ('face', WHITE),
    'fibrillation': ('line', (255, 120, 120)),
    'fracture': ('fill', (236, 226, 200)),
    'freezing': ('line', (170, 222, 255)),
    'gas': ('fill', (150, 172, 132)),
    'haste': ('line', WHITE),
    'heart': ('fill', (236, 226, 220)),
    'hot': ('fill', (255, 150, 40)),
    'hypoxia': ('line', (90, 172, 255)),
    'immobilized': ('fill', (236, 232, 222)),
    'incapacitated': ('line', WHITE),
    'infection': ('fill', (132, 182, 92)),
    'internal': ('fill', (226, 182, 150), (190, 18, 18)),
    'liver': ('fill', (160, 62, 56)),
    'lung_failure': ('fill', (214, 158, 170)),
    'lungs': ('fill', (220, 166, 176)),
    'nausea': ('face', (175, 222, 120)),
    'euphoria': ('face', (255, 120, 225)),
    'heroin_wd': ('fill', (226, 206, 178)),
    'meth_wd': ('fill', (200, 228, 255)),
    'nicotine': ('fill', (235, 225, 208)),
    'nicotine_wd': ('fill', (235, 225, 208)),
    'pain': ('face', WHITE),
    'panic': ('face', (185, 160, 255)),
    'painkillers': ('fill', (232, 232, 236)),
    'pressure_high': ('fill', (255, 140, 140)),
    'pressure_low': ('fill', (150, 190, 255)),
    'pulse': ('fill', (236, 222, 216)),
    'rage': ('line', (255, 80, 80)),
    'seizure': ('fill', (255, 222, 70)),
    'shock': ('line', WHITE),
    'skull': ('fill', (232, 226, 212)),
    'tremor': ('line', WHITE),
    'unconscious': ('line', (200, 222, 255)),
    'vessels_narrow': ('line', (150, 192, 255)),
    'vessels_wide': ('line', (255, 125, 125)),
    'wound': ('fill', (226, 182, 150), (190, 18, 18)),
}
INK = (16, 4, 4)


def neighbours(m):
    # пиксели, у которых есть сосед (4 стороны) из маски m
    out = np.zeros_like(m)
    out[1:, :] |= m[:-1, :]; out[:-1, :] |= m[1:, :]
    out[:, 1:] |= m[:, :-1]; out[:, :-1] |= m[:, 1:]
    return out


def exterior(stroke):
    # всё, до чего можно дойти от края картинки, не пересекая линий
    ext = np.zeros_like(stroke)
    stack = [(y, x) for y in range(N) for x in (0, N - 1)] + [(y, x) for x in range(N) for y in (0, N - 1)]
    while stack:
        y, x = stack.pop()
        if ext[y, x] or stroke[y, x]:
            continue
        ext[y, x] = True
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < N and 0 <= nx < N and not ext[ny, nx]:
                stack.append((ny, nx))
    return ext


def connected(seed, mask):
    # все пиксели маски, связанные с seed (8 сторон) - целый контур, а не только его внешний край
    out = np.zeros_like(mask)
    stack = list(zip(*np.nonzero(seed)))
    while stack:
        y, x = stack.pop()
        if out[y, x] or not mask[y, x]:
            continue
        out[y, x] = True
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ny, nx = y + dy, x + dx
                if 0 <= ny < N and 0 <= nx < N and not out[ny, nx] and mask[ny, nx]:
                    stack.append((ny, nx))
    return out


def make(name):
    style, col, *extra = STYLE.get(name, ('line', WHITE))
    dcol = extra[0] if extra else None  # свой цвет детали (порез, кровь внутри), иначе - темнее основного
    rnd = random.Random(name)
    a = np.asarray(Image.open(os.path.join(BASE, name + '.png')).convert('RGBA').resize((N, N), Image.BOX))[..., 3] / 255
    stroke = a > 0.3
    ext = exterior(stroke)
    inside = ~stroke & ~ext
    shape = stroke | inside
    ring = connected(stroke & neighbours(ext), stroke)  # внешний контур целиком
    detail = stroke & ~ring                             # глаза, рот, прожилки - отдельные линии внутри

    rgb = np.zeros((N, N, 3), float)
    alpha = np.zeros((N, N), float)
    yy, xx = np.mgrid[0:N, 0:N]
    grain = np.array([[rnd.uniform(-1, 1) for _ in range(N)] for _ in range(N)])
    light = 1.12 - 0.4 * (xx + yy) / (2 * N)  # свет сверху слева

    def paint(mask, color, shade=None, noise=0.1):
        k = (shade if shade is not None else 1) * (1 + grain * noise)
        for c in range(3):
            rgb[..., c] = np.where(mask, np.clip(color[c] * k, 0, 255), rgb[..., c])
        alpha[mask] = 1

    if style == 'line':
        paint(stroke, col, noise=0.12)
    elif style == 'fill':
        paint(shape, col, light, noise=0.16)
        paint(detail, dcol or tuple(c * 0.55 for c in col), light, noise=0.1)  # прожилки, доли, трещины - темнее
        paint(ring, tuple(c * 0.7 for c in col), light, noise=0.1)
    elif style == 'face':
        paint(shape, (40, 10, 10), light, noise=0.35)  # тёмная клякса
        paint(ring, (95, 22, 22), noise=0.2)
        paint(detail, col, noise=0.08)                 # глаза и рот
    elif style == 'badge':
        paint(shape, col, light, noise=0.18)
        paint(detail, WHITE, noise=0.05)

    # редкие тёмные крапинки - "грязь"
    specks = (np.array([[rnd.random() for _ in range(N)] for _ in range(N)]) < 0.05) & shape & ~detail
    rgb[specks] *= 0.7

    # тёмная обводка вокруг рисунка
    ink = neighbours(alpha > 0) & (alpha == 0)
    for c in range(3):
        rgb[..., c] = np.where(ink, INK[c], rgb[..., c])
    alpha[ink] = 0.85

    im = np.dstack([rgb, alpha * 255]).astype(np.uint8)
    Image.fromarray(im, 'RGBA').resize((SIZE, SIZE), Image.NEAREST).save(os.path.join(OUT, name + '.png'))


if __name__ == '__main__':
    names = sorted(f[:-4] for f in os.listdir(BASE) if f.endswith('.png'))
    for n in names:
        make(n)
    print(len(names), 'icons')
