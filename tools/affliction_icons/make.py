# Белые значки состояний для плиток осмотра (lua/homigrad/cl_health_indicator.lua) -> materials/rem_affl/*.png
# Большинство - Tabler Icons (MIT, лицензия в materials/radialmenu_rem/LICENSE-tabler-icons.txt), O2 и печень нарисованы тут.
# Запуск: python3 tools/affliction_icons/make.py <папка tabler/icons/outline>
import io, os, re, sys
import cairosvg
from PIL import Image, ImageDraw, ImageFont

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'rem_affl')
os.makedirs(OUT, exist_ok=True)
SIZE = 96

TABLER = {
    'wound': 'cut', 'bleeding': 'droplet', 'arterial': 'droplets', 'bloodloss': 'droplet-half-2',
    'fracture': 'bone', 'dislocation': 'stretching', 'amputation': 'hand-off', 'skull': 'skull',
    'concussion': 'spiral', 'brain': 'brain', 'seizure': 'bolt', 'unconscious': 'zzz',
    'pain': 'mood-nervous', 'shock': 'activity', 'critical': 'alert-triangle',
    'arrhythmia': 'heart-rate-monitor', 'fibrillation': 'activity-heartbeat', 'cardiac_arrest': 'heart-off',
    'heart': 'heart-broken', 'pressure_low': 'gauge', 'pressure_high': 'gauge',
    'lungs': 'lungs', 'lung_failure': 'lungs-off', 'hot': 'temperature-plus', 'cold': 'temperature-minus',
    'freezing': 'snowflake', 'vessels_narrow': 'arrows-minimize', 'vessels_wide': 'arrows-maximize',
    'alcohol': 'bottle', 'nausea': 'mood-sick', 'fear': 'ghost-2', 'depression': 'cloud-rain',
    'adrenaline': 'heartbeat', 'haste': 'run', 'painkillers': 'pill', 'fatigue': 'battery-1',
    'blind': 'eye-off', 'burning': 'flame', 'gas': 'cloud-fog', 'infection': 'virus',
    'immobilized': 'link', 'incapacitated': 'wheelchair', 'internal': 'stethoscope', 'rage': 'swords',
    'nicotine': 'smoking', 'nicotine_wd': 'smoking-no', 'alcohol_wd': 'glass-off', 'tremor': 'hand-move',
    'implant_heart': 'heart-bolt', 'implant_lungs': 'lungs', 'implant_nanites': 'droplet-bolt',
    'implant_painblock': 'shield-check', 'implant_adrenal': 'battery-charging-2',
}

def tabler(name, out):
    svg = open(os.path.join(SRC, name + '.svg')).read()
    svg = svg.replace('currentColor', '#ffffff')
    svg = re.sub(r'stroke-width="[\d.]+"', 'stroke-width="2.1"', svg)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=SIZE - 16, output_height=SIZE - 16)
    icon = Image.open(io.BytesIO(png)).convert('RGBA')
    im = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    im.alpha_composite(icon, (8, 8))
    im.save(out)

def o2(out):
    S = 4
    im = Image.new('RGBA', (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    font = os.path.join(os.path.dirname(__file__), '..', '..', 'resource', 'fonts', 'ShareTechMono-Regular.ttf')
    big, small = ImageFont.truetype(font, 46 * S), ImageFont.truetype(font, 26 * S)
    d.text((10 * S, 20 * S), 'O', font=big, fill='white', stroke_width=S, stroke_fill='white')
    d.text((40 * S, 44 * S), '2', font=small, fill='white', stroke_width=S, stroke_fill='white')
    d.rectangle([58 * S, 34 * S, 84 * S, 39 * S], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

def liver(out):
    S = 4
    im = Image.new('RGBA', (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pts = [(14, 40), (22, 26), (40, 22), (62, 20), (80, 22), (86, 30), (80, 40), (66, 50), (52, 62), (42, 72), (34, 70), (24, 60), (16, 50)]
    d.line([(x * S, y * S) for x, y in pts + pts[:1]], fill='white', width=int(4.5 * S), joint='curve')
    d.line([(52 * S, 22 * S), (48 * S, 46 * S)], fill='white', width=int(3.5 * S))
    for x, y in pts:
        d.ellipse([(x - 2.2) * S, (y - 2.2) * S, (x + 2.2) * S, (y + 2.2) * S], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

def mark(path, plus):
    # значок "+" / "-" в правом верхнем углу (давление высокое / низкое)
    S = 4
    im = Image.open(path).convert('RGBA').resize((SIZE * S, SIZE * S), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    d.rectangle([66 * S, 12 * S, 90 * S, 17 * S], fill='white')
    if plus: d.rectangle([75.5 * S, 2.5 * S, 80.5 * S, 26.5 * S], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(path)

for key, name in TABLER.items():
    tabler(name, os.path.join(OUT, key + '.png'))
mark(os.path.join(OUT, 'pressure_high.png'), True)
mark(os.path.join(OUT, 'pressure_low.png'), False)
o2(os.path.join(OUT, 'hypoxia.png'))
liver(os.path.join(OUT, 'liver.png'))
print(len(TABLER) + 2, 'icons')
