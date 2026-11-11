# Уменьшает VTF 7.0-7.2 вдвое без перекодирования: у VTF мипмапы лежат от маленького к большому, поэтому достаточно
# отрезать последний (самый большой) уровень и поправить в заголовке ширину, высоту и число мипов.
# Только для одиночных текстур (1 кадр, 1 грань, глубина 1). Без аргумента --write - только проверка размеров.
# Запуск: python3 tools/vtf/halve.py [--write] файл.vtf ...
import struct, sys

BPP = {0: 4, 1: 4, 2: 3, 3: 3, 4: 2, 12: 4, 16: 4, 24: 8, 25: 8}  # байт на пиксель несжатых форматов
DXT = {13: 8, 14: 16, 15: 16}  # байт на блок 4x4


def level_size(fmt, w, h):
    if fmt in DXT:
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * DXT[fmt]
    return w * h * BPP[fmt]


def info(data):
    assert data[:4] == b'VTF\0', 'не VTF'
    vmaj, vmin, hsz = struct.unpack_from('<III', data, 4)
    assert vmaj == 7 and vmin <= 2, 'поддерживаются только VTF 7.0-7.2 (без ресурсов)'
    w, h, flags, frames, first = struct.unpack_from('<HHIHH', data, 16)
    fmt = struct.unpack_from('<i', data, 52)[0]
    mips = data[56]
    lowfmt = struct.unpack_from('<i', data, 57)[0]
    lw, lh = data[61], data[62]
    depth = struct.unpack_from('<H', data, 63)[0] if vmin >= 2 else 1
    faces = 6 if flags & 0x4000 else 1
    assert frames == 1 and faces == 1 and depth <= 1, 'только одиночная текстура'
    low = level_size(lowfmt, lw, lh) if lowfmt != -1 and lw and lh else 0
    levels = [level_size(fmt, max(1, w >> i), max(1, h >> i)) for i in range(mips)]
    return dict(hsz=hsz, w=w, h=h, fmt=fmt, mips=mips, low=low, levels=levels)


def main():
    write = '--write' in sys.argv
    for p in [a for a in sys.argv[1:] if a != '--write']:
        data = bytearray(open(p, 'rb').read())
        i = info(data)
        expect = i['hsz'] + i['low'] + sum(i['levels'])
        if expect != len(data):
            print('SKIP', p, 'размер не сходится', expect, len(data)); continue
        if i['mips'] < 2:
            print('SKIP', p, 'один мип'); continue
        new = data[:len(data) - i['levels'][0]]  # самый большой уровень - последний в файле
        struct.pack_into('<HH', new, 16, i['w'] // 2, i['h'] // 2)
        new[56] = i['mips'] - 1
        print('OK  ' if write else 'can ', p, f"{i['w']}x{i['h']} -> {i['w']//2}x{i['h']//2}", len(data), '->', len(new))
        if write:
            open(p, 'wb').write(new)


main()
