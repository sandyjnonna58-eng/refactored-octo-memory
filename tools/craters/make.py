# Текстуры пробоин и воронок от взрывов (decals) -> materials/rem_crater/*.vtf + .vmt
# Свои рисунки, процедурно. VTF 7.2 BGRA8888 с мипами пишем сами (без внешних утилит).
# Запуск из корня репозитория: python3 tools/craters/make.py
import math, os, random, struct
from PIL import Image, ImageDraw, ImageFilter, ImageChops

OUT = 'materials/rem_crater'
S = 512


def noise(size, scale, seed):
    random.seed(seed)
    small = Image.new('L', (max(2, size // scale), max(2, size // scale)))
    small.putdata([random.randint(0, 255) for _ in range(small.size[0] * small.size[1])])
    return small.resize((size, size), Image.BICUBIC)


def blob(size, r, rough, seed, points=90):
    # неровный круг (рваный край)
    random.seed(seed)
    c = size / 2
    offs = [random.uniform(-1, 1) for _ in range(12)]
    pts = []
    for i in range(points):
        a = i / points * math.tau
        k = 1 + sum(offs[j] * rough / (j + 1) * math.sin((j + 2) * a + offs[-j]) for j in range(6))
        k += random.uniform(-rough, rough) * 0.12
        pts.append((c + math.cos(a) * r * k, c + math.sin(a) * r * k))
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def cracks(size, n, r0, r1, seed, width=3):
    random.seed(seed)
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    c = size / 2
    for _ in range(n):
        a = random.uniform(0, math.tau)
        r = r0
        x, y = c + math.cos(a) * r, c + math.sin(a) * r
        length = random.uniform(r1 * 0.6, r1)
        while r < length:
            a += random.uniform(-0.45, 0.45)
            step = random.uniform(8, 18)
            nx, ny = x + math.cos(a) * step, y + math.sin(a) * step
            d.line([(x, y), (nx, ny)], fill=255, width=max(1, int(width * (1 - r / length) + 1)))
            x, y = nx, ny
            r = math.hypot(x - c, y - c)
            if random.random() < 0.08:
                b = a + random.choice((-1, 1)) * random.uniform(0.6, 1.1)
                bx, by = x, y
                for _ in range(random.randint(2, 5)):
                    b += random.uniform(-0.4, 0.4)
                    nbx, nby = bx + math.cos(b) * 10, by + math.sin(b) * 10
                    d.line([(bx, by), (nbx, nby)], fill=200, width=1)
                    bx, by = nbx, nby
    return m


def radial(size, inner, outer):
    # 255 в центре до inner, к outer - 0
    m = Image.new('L', (size, size))
    c = size / 2
    px = m.load()
    for y in range(size):
        for x in range(size):
            r = math.hypot(x - c, y - c)
            t = (r - inner) / max(outer - inner, 1)
            px[x, y] = int(255 * min(max(1 - t, 0), 1))
    return m


def compose(kind, seed):
    random.seed(seed)
    n1 = noise(S, 8, seed)
    n2 = noise(S, 32, seed + 1)
    rgba = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # копоть вокруг - широкое мягкое пятно
    soot = ImageChops.multiply(radial(S, S * 0.12, S * 0.5), noise(S, 16, seed + 2).point(lambda v: 140 + v // 2))
    soot = soot.filter(ImageFilter.GaussianBlur(6))
    soot_col = (24, 20, 17) if kind != 'ground' else (20, 16, 12)
    rgba = Image.composite(Image.new('RGBA', (S, S), soot_col + (255,)), rgba, soot.point(lambda v: int(v * 0.85)))
    if kind == 'metal':
        # металл не пробивает - только опалённое пятно и мелкие вмятины
        dents = blob(S, S * 0.13, 0.25, seed + 3)
        rgba.paste((38, 32, 28, 235), mask=dents.filter(ImageFilter.GaussianBlur(3)))
        return rgba, soot
    # разбитый край (светлее - обнажённый материал), затем тёмный конус внутрь и чёрная дыра
    rim_r = S * (0.30 if kind != 'ground' else 0.34)
    rim = blob(S, rim_r, 0.22, seed + 4, 120)
    rim_col = (112, 104, 96) if kind == 'wall' else (78, 62, 46)
    rim_tex = Image.new('RGBA', (S, S), rim_col + (255,))
    shade = ImageChops.multiply(n1, n2).point(lambda v: 90 + v // 2)
    rim_tex = Image.merge('RGBA', [ImageChops.multiply(ch, shade) if i < 3 else ch for i, ch in enumerate(rim_tex.split())])
    rgba = Image.composite(rim_tex, rgba, rim.filter(ImageFilter.GaussianBlur(1.2)))
    cone = blob(S, rim_r * 0.72, 0.18, seed + 5, 120)
    cone_grad = radial(S, rim_r * 0.15, rim_r * 0.75)
    inner = Image.new('RGBA', (S, S), (30, 26, 22, 255) if kind == 'wall' else (26, 20, 14, 255))
    rgba = Image.composite(inner, rgba, ImageChops.multiply(cone, cone_grad.point(lambda v: 120 + v // 2)).filter(ImageFilter.GaussianBlur(2)))
    if kind == 'wall':
        hole = blob(S, rim_r * 0.42, 0.35, seed + 6, 70)
        rgba.paste((4, 4, 5, 255), mask=hole.filter(ImageFilter.GaussianBlur(0.8)))
        # трещины от пробоины по стене
        cr = cracks(S, 14, rim_r * 0.9, S * 0.48, seed + 7)
        rgba.paste((14, 12, 11, 230), mask=cr)
    else:
        pit = blob(S, rim_r * 0.5, 0.3, seed + 6, 70)
        rgba.paste((10, 8, 6, 245), mask=pit.filter(ImageFilter.GaussianBlur(3)))
        # выброшенная земля - комья по краю
        clods = Image.new('L', (S, S), 0)
        d = ImageDraw.Draw(clods)
        c = S / 2
        for _ in range(70):
            a = random.uniform(0, math.tau)
            r = random.uniform(rim_r * 0.95, S * 0.46)
            x, y = c + math.cos(a) * r, c + math.sin(a) * r
            s = random.uniform(2, 7) * (1 - r / (S * 0.5)) + 1
            d.ellipse([x - s, y - s, x + s, y + s], fill=255)
        rgba.paste((40, 30, 21, 240), mask=clods)
    return rgba, soot


def mips(img):
    out = [img]
    while img.size[0] > 1:
        img = img.resize((max(1, img.size[0] // 2), max(1, img.size[1] // 2)), Image.LANCZOS)
        out.append(img)
    return out


def write_vtf(path, img):
    levels = mips(img)
    hdr = bytearray(80)
    struct.pack_into('<4sIII', hdr, 0, b'VTF\0', 7, 2, 80)
    struct.pack_into('<HHI', hdr, 16, img.size[0], img.size[1], 0x2000 | 0x4 | 0x8)  # 8-bit alpha, clamp S/T
    struct.pack_into('<HH', hdr, 24, 1, 0)
    struct.pack_into('<fff', hdr, 32, 0.1, 0.1, 0.1)
    struct.pack_into('<f', hdr, 48, 1.0)
    struct.pack_into('<i', hdr, 52, 12)  # IMAGE_FORMAT_BGRA8888
    hdr[56] = len(levels)
    struct.pack_into('<i', hdr, 57, -1)  # без превью
    struct.pack_into('<BBH', hdr, 61, 0, 0, 1)
    data = bytearray(hdr)
    for lv in reversed(levels):  # от маленького к большому
        r, g, b, a = lv.split()
        data += Image.merge('RGBA', (b, g, r, a)).tobytes()
    open(path, 'wb').write(data)


VMT = '''"LightmappedGeneric"
{
	"$basetexture" "rem_crater/%s"
	"$decal" "1"
	"$decalscale" "1"
	"$translucent" "1"
	"$vertexcolor" "1"
	"$vertexalpha" "1"
}
'''

os.makedirs(OUT, exist_ok=True)
for name, kind, seed in (('crater_wall', 'wall', 11), ('crater_wall2', 'wall', 23), ('crater_ground', 'ground', 37), ('scorch_metal', 'metal', 51)):
    img, _ = compose(kind, seed)
    write_vtf(os.path.join(OUT, name + '.vtf'), img)
    open(os.path.join(OUT, name + '.vmt'), 'w', newline='\n').write(VMT % name)
    img.save('/tmp/claude-0/-home-user-refactored-octo-memory/6632cd12-8dad-51b4-a4e0-bf85779f6177/scratchpad/prev_%s.png' % name) if os.path.isdir('/tmp/claude-0') else None
    print(name, os.path.getsize(os.path.join(OUT, name + '.vtf')))
