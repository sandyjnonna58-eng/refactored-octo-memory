# Текстура обрубка шеи из Lambda Gore Mod (L4D, common_infected_w_neck) для отрезания головы (organism/sv_decap.lua).
# Родная master_wound_cmap.vtf в присланном архиве обрезана - берём целую жёлтую master_wound_cmap_yellow.vtf того же мода
# и перекрашиваем в красный. Запуск: python3 tools/gore/make_l4d_neck.py <путь к master_wound_cmap_yellow.vtf>
# -> materials/rem_gore/l4d_neck_wound.vtf (BGRA8888, 512, с мипами)
import io, os, struct, sys
import numpy as np
from PIL import Image

def read_vtf(path):
	b = open(path, 'rb').read()
	w, h = struct.unpack_from('<HH', b, 16)
	fmt = struct.unpack_from('<i', b, 52)[0]
	sizes = {13: w * h // 2, 15: w * h, 14: w * h, 3: w * h * 3, 12: w * h * 4, 0: w * h * 4}
	data = b[-sizes[fmt]:]
	if fmt in (13, 14, 15):
		four = {13: b'DXT1', 14: b'DXT3', 15: b'DXT5'}[fmt]
		hdr = b'DDS ' + struct.pack('<7I', 124, 0x1007, h, w, len(data), 0, 0) + b'\0' * 44 \
			+ struct.pack('<2I4s5I', 32, 4, four, 0, 0, 0, 0, 0) + struct.pack('<5I', 0x1000, 0, 0, 0, 0)
		return Image.open(io.BytesIO(hdr + data))
	if fmt == 3: return Image.frombytes('RGB', (w, h), data, 'raw', 'BGR')
	if fmt == 12: return Image.frombytes('RGBA', (w, h), data, 'raw', 'BGRA')
	return Image.frombytes('RGBA', (w, h), data)

def write_vtf(path, img):
	levels = [img]
	while levels[-1].size[0] > 1:
		lv = levels[-1]
		levels.append(lv.resize((max(1, lv.size[0] // 2), max(1, lv.size[1] // 2)), Image.LANCZOS))
	hdr = bytearray(80)
	struct.pack_into('<4sIII', hdr, 0, b'VTF\0', 7, 2, 80)
	struct.pack_into('<HHI', hdr, 16, img.size[0], img.size[1], 0)
	struct.pack_into('<HH', hdr, 24, 1, 0)
	struct.pack_into('<fff', hdr, 32, 0.3, 0.05, 0.05)
	struct.pack_into('<f', hdr, 48, 1.0)
	struct.pack_into('<i', hdr, 52, 12)  # BGRA8888
	hdr[56] = len(levels)
	struct.pack_into('<i', hdr, 57, -1)
	struct.pack_into('<BBH', hdr, 61, 0, 0, 1)
	data = bytearray(hdr)
	for lv in reversed(levels):
		r, g, b, a = lv.convert('RGBA').split()
		data += Image.merge('RGBA', (b, g, r, a)).tobytes()
	open(path, 'wb').write(data)

src = read_vtf(sys.argv[1]).convert('RGB').resize((512, 512), Image.LANCZOS)
a = np.asarray(src).astype(np.float32)
lum = np.maximum(a[..., 0], a[..., 1])                     # жёлтое -> яркость
red = np.stack([lum * 0.95, a[..., 2] * 0.5 + lum * 0.08, a[..., 2] * 0.5 + lum * 0.08], -1)
out = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'rem_gore', 'l4d_neck_wound.vtf')
os.makedirs(os.path.dirname(out), exist_ok=True)
write_vtf(out, Image.fromarray(np.clip(red, 0, 255).astype(np.uint8)))
print('ok', os.path.normpath(out))
