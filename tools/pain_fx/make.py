# Текстуры эффекта сильной боли (lua/homigrad/screenfx/cl_screenfx.lua, DrawPainOverlay) - по скриншоту пользователя
# (Fading Vitality): неподвижная картинка, ничего не анимируется.
#   rem_fx/pain_static.png - кольцо крупного серо-розового пиксельного шума по краям экрана (к центру редеет и
#                            пропадает), в нём красные завихрения (спиральные рукава к центру) и пара светлых рукавов;
#                            рисуется без сглаживания (крупные пиксели), растягивается на весь экран.
#   rem_fx/pain_spikes.png - тёмно-красные полупрозрачные клыки, свисающие с верхнего края шума; со сглаживанием.
# Запуск из корня репозитория: python3 tools/pain_fx/make.py [preview.png]
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "materials", "rem_fx")
rng = np.random.default_rng(20261119)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def polar(W, H):
    y, x = np.mgrid[0:H, 0:W].astype(np.float64)
    nx = (x + 0.5 - W / 2) / (W / 2)
    ny = (y + 0.5 - H / 2) / (H / 2)
    return np.hypot(nx, ny), np.arctan2(ny, nx)


def make_static(W=960, H=540):
    r, th = polar(W, H)
    # шум: светлые, средние, тёмные и красные пиксели (средний цвет по краям скриншота ~ (100, 70, 73))
    pal = np.array([[148, 118, 124], [100, 76, 80], [46, 30, 34], [140, 30, 40]], float)
    idx = rng.choice(4, size=(H, W), p=[0.35, 0.25, 0.35, 0.05])
    rgb = pal[idx]  # без разброса яркости - PNG сжимается в разы лучше
    lum = rgb.mean(2)

    # плотность шума: в середине чисто, к r ~ 1.05 (край экрана по эллипсу) - сплошной
    prof = smoothstep(0.36, 1.0, r)
    alpha = np.clip(prof * (0.78 + 0.32 * rng.random((H, W))), 0, 1)

    # спиральные рукава: theta(r) = theta0 + k * ln(r), начинаются у края шума, к центру сужаются
    scale = (W + H) / 4  # пикселей на единицу r (по эллипсу, в среднем)
    red = np.zeros((H, W))
    n = 34
    for i in range(n):
        th0 = 2 * np.pi * i / n + rng.uniform(-0.05, 0.05)
        k = rng.uniform(0.5, 1.0)
        r0 = rng.uniform(0.74, 0.95)              # где начинается
        wmax = rng.choice([3.0, 5.0, 7.0, 10.0, 14.0], p=[0.2, 0.3, 0.25, 0.15, 0.1])
        d = np.angle(np.exp(1j * (th - (th0 + k * np.log(np.maximum(r, 1e-3))))))
        dist = np.abs(d) * r * scale
        taper = smoothstep(r0, r0 + 0.18, r)       # тонкий кончик к центру
        width = wmax * (0.35 + 0.65 * taper) * (0.8 + 0.4 * smoothstep(0.9, 1.4, r))
        m = np.clip(width / 2 - dist + 0.5, 0, 1) * smoothstep(r0 - 0.02, r0 + 0.05, r)
        red = np.maximum(red, m * rng.uniform(0.7, 1.0))
    # светлые рукава (на скриншоте - бледная полоса по внутреннему краю шума справа сверху)
    pale = np.zeros((H, W))
    for th0, k, r0, wmax in [(-0.55, 1.3, 0.74, 14), (2.6, 1.2, 0.8, 9), (1.2, 1.1, 0.84, 7)]:
        d = np.angle(np.exp(1j * (th - (th0 + k * np.log(np.maximum(r, 1e-3))))))
        dist = np.abs(d) * r * scale
        m = np.clip(wmax / 2 - dist + 0.5, 0, 1) * smoothstep(r0, r0 + 0.1, r) * (1 - smoothstep(1.05, 1.3, r))
        pale = np.maximum(pale, m * 0.55)

    redrgb = np.stack([lum * 1.1 + 60, lum * 0.15, lum * 0.2], 2)
    rgb = rgb * (1 - red[..., None]) + redrgb * red[..., None]
    palergb = np.stack([lum * 0.5 + 120, lum * 0.5 + 105, lum * 0.5 + 108], 2)
    rgb = rgb * (1 - pale[..., None]) + palergb * pale[..., None]
    alpha = np.maximum(alpha, np.maximum(red * smoothstep(0.7, 0.95, r) * 0.95, pale * prof))

    alpha = np.round(alpha * 15) / 15  # 16 ступеней прозрачности - тоже ради размера файла
    out = np.dstack([np.clip(rgb, 0, 255), np.clip(alpha * 255, 0, 255)]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def make_spikes(W=1024, H=576):
    S = 3  # сглаживание: рисуем крупнее и уменьшаем
    img = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # клыки свисают с верхнего края шума (угол на эллипсе, длина в долях высоты, ширина в долях ширины, форма)
    spikes = [(-1.56, 0.26, 0.036, "tri"), (-1.38, 0.34, 0.030, "kite"), (-0.98, 0.30, 0.062, "kite"),
              (-1.95, 0.18, 0.028, "tri")]
    for ang, length, width, kind in spikes:
        bx = W / 2 + np.cos(ang) * 0.80 * W / 2
        by = H / 2 + np.sin(ang) * 0.80 * H / 2
        # вниз и чуть к центру
        dx, dy = (W / 2 - bx) * 0.25 / (W / 2), 1.0
        ln = np.hypot(dx, dy)
        dx, dy = dx / ln, dy / ln
        px, py = -dy, dx
        L, Wd = length * H, width * W
        pts_l, pts_r = [], []
        for t in np.linspace(0, 1, 40):
            if kind == "kite":
                f = (0.35 + 0.65 * t / 0.28) if t < 0.28 else (1 - (t - 0.28) / 0.72) ** 1.15
            else:
                f = (1 - t) ** 1.25
            cx, cy = bx + dx * L * t, by + dy * L * t
            pts_l.append(((cx + px * Wd / 2 * f) * S, (cy + py * Wd / 2 * f) * S))
            pts_r.append(((cx - px * Wd / 2 * f) * S, (cy - py * Wd / 2 * f) * S))
        poly = pts_l + pts_r[::-1]
        d.polygon(poly, fill=(105, 14, 20, 150))
        d.line(poly + [poly[0]], fill=(70, 8, 12, 165), width=S)
    img = img.filter(ImageFilter.GaussianBlur(S * 1.0)).resize((W, H), Image.LANCZOS)
    # верх клыков уходит в шум - мягко
    a = np.asarray(img).astype(float)
    r, _ = polar(W, H)
    a[..., 3] *= 1 - 0.6 * smoothstep(0.75, 0.95, r)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def preview(static, spikes, path):
    # проверка: серая «улица» под эффектом, как в игре (cl_screenfx: затемнение 0.3 + шум + клыки)
    W, H = 1242, 729
    y, x = np.mgrid[0:H, 0:W]
    bg = np.dstack([90 + 40 * (y < H * 0.45) - 25 * (x > W * 0.6)] * 3).astype(np.uint8)
    base = Image.fromarray(bg, "RGB").convert("RGBA")
    base.alpha_composite(Image.new("RGBA", (W, H), (0, 0, 0, int(255 * 0.3))))
    base.alpha_composite(static.resize((W, H), Image.NEAREST))
    base.alpha_composite(spikes.resize((W, H), Image.LANCZOS))
    base.convert("RGB").save(path)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    st, sp = make_static(), make_spikes()
    st.save(os.path.join(OUT, "pain_static.png"), optimize=True)
    sp.save(os.path.join(OUT, "pain_spikes.png"), optimize=True)
    if len(sys.argv) > 1:
        preview(st, sp, sys.argv[1])
    print("ok")
