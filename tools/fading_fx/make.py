# Текстуры для эффектов ухода сознания (lua/homigrad/screenfx/cl_fading.lua):
#   rem_fx/lids.png   - верхнее веко: чёрное сверху, нижний край дугой, с края свисают изогнутые тёмные ресницы
#                       (нижнее веко - та же картинка, перевёрнутая)
#   rem_fx/tunnel.png - туннель: чёрное по краям, мягкая прозрачная середина
# Запуск из корня репозитория: python3 tools/fading_fx/make.py
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "materials", "rem_fx")
random.seed(7)


def lid_edge(x, w, h):
    # край века дугой: в середине выше, к уголкам глаза ниже (прорезь - миндалём)
    t = (2 * x / w - 1)
    return h * (0.30 + 0.20 * t * t)


def make_lids():
    W, H = 1024, 512
    SS = 2  # рисуем в 2 раза крупнее, потом уменьшаем - сглаживание
    w, h = W * SS, H * SS
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)

    # само веко
    pts = [(0, 0), (w, 0)]
    for i in range(64, -1, -1):
        x = w * i / 64
        pts.append((x, lid_edge(x, w, h)))
    d.polygon(pts, fill=255)

    # ресницы: от края вниз и в сторону от середины, изгибаются, к концу тоньше
    for _ in range(150):
        x0 = random.uniform(-0.02, 1.02) * w
        y0 = lid_edge(min(max(x0, 0), w), w, h) - 4 * SS
        side = (x0 / w - 0.5) * 2  # -1 слева, 1 справа
        length = random.uniform(0.12, 0.34) * h * (1 - 0.35 * abs(side))
        ang = math.radians(90 + side * 55 + random.uniform(-14, 14))  # вниз, с наклоном наружу
        bend = math.radians((25 + random.uniform(0, 30)) * (1 if side >= 0 else -1) * -1)
        width = random.uniform(5, 10) * SS
        steps = 24
        prev = (x0, y0)
        for s in range(1, steps + 1):
            f = s / steps
            a = ang + bend * f * f
            x = prev[0] + math.cos(a) * length / steps
            y = prev[1] + math.sin(a) * length / steps
            wd = max(width * (1 - f) ** 1.3, 1)
            d.line([prev, (x, y)], fill=int(255 * (1 - 0.25 * f)), width=int(wd))
            prev = (x, y)

    img = img.filter(ImageFilter.GaussianBlur(1.6 * SS)).resize((W, H), Image.LANCZOS)
    a = np.array(img)
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[..., 0], rgba[..., 1], rgba[..., 2] = 8, 4, 4
    rgba[..., 3] = a
    Image.fromarray(rgba, "RGBA").save(os.path.join(OUT, "lids.png"))


def make_tunnel():
    N = 512
    y, x = np.mgrid[0:N, 0:N]
    r = np.hypot((x - N / 2 + 0.5) / (N / 2), (y - N / 2 + 0.5) / (N / 2))
    t = np.clip((r - 0.42) / (0.98 - 0.42), 0, 1)
    a = t * t * (3 - 2 * t)  # smoothstep
    rgba = np.zeros((N, N, 4), np.uint8)
    rgba[..., 3] = (a * 255).astype(np.uint8)
    Image.fromarray(rgba, "RGBA").save(os.path.join(OUT, "tunnel.png"))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    make_lids()
    make_tunnel()
    print("ok")
