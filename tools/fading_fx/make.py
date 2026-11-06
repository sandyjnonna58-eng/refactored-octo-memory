# Текстура для эффекта ухода сознания (lua/homigrad/screenfx/cl_fading.lua):
#   rem_fx/tunnel.png - туннель: чёрное по краям, мягкая прозрачная середина
# Запуск из корня репозитория: python3 tools/fading_fx/make.py
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "materials", "rem_fx")


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
    make_tunnel()
    print("ok")
