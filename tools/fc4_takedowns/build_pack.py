# Пак контента для тейкдаунов (lua/homigrad/takedowns) из аддона "BSMod Far Cry Takedowns":
#   python3 -I tools/fc4_takedowns/build_pack.py <папка аддона> <папка вывода>
# Копирует модели-шаблоны и звуки. Анимации и кости берутся из .mdl, поэтому шаблоны не рисуются;
# если .vtx у шаблона нет или он битый (0 байт), пишется пустой .vtx без геометрии (тот же checksum и структура
# частей тела), чтобы модель загрузилась. Обрезанные .wav чинятся (размеры в заголовке + короткое затухание), пустые пропускаются.
# Результат - в контент-пак сервера (models/ и sound/ рядом), в репозиторий не кладётся.
import os, sys, shutil, struct

def i32(b, o): return struct.unpack_from('<i', b, o)[0]

def empty_vtx(mdl_path):
    b = open(mdl_path, 'rb').read()
    checksum = i32(b, 8)
    nparts, pi = i32(b, 232), i32(b, 236)
    parts = []
    for p in range(nparts):
        po = pi + p * 16
        nm, mi = i32(b, po + 4), i32(b, po + 12)
        parts.append([i32(b, po + mi + m * 148 + 72) for m in range(nm)])  # nummeshes у каждой модели

    out = bytearray(36)
    bp_at = len(out); out += bytes(8 * len(parts))
    fix = []  # (позиция поля смещения, позиция структуры, на которую оно указывает)
    model_at = []
    for p, models in enumerate(parts):
        struct.pack_into('<i', out, bp_at + p * 8, len(models))
        fix.append((bp_at + p * 8 + 4, bp_at + p * 8, len(out)))
        model_at.append(len(out)); out += bytes(8 * len(models))
    lod_at = []
    for p, models in enumerate(parts):
        lod_at.append([])
        for m, nmesh in enumerate(models):
            mo = model_at[p] + m * 8
            struct.pack_into('<i', out, mo, 1)
            fix.append((mo + 4, mo, len(out)))
            lod_at[p].append(len(out)); out += bytes(12)
    for p, models in enumerate(parts):
        for m, nmesh in enumerate(models):
            lo = lod_at[p][m]
            struct.pack_into('<i', out, lo, nmesh)
            fix.append((lo + 4, lo, len(out)))
            out += bytes(9 * nmesh)  # меши без strip group - ничего не рисуется
    mat_at = len(out); out += bytes(8)
    for field, base, target in fix:
        struct.pack_into('<i', out, field, target - base)
    struct.pack_into('<iiHHiiiiii', out, 0, 7, 24, 53, 9, 3, checksum, 1, mat_at, len(parts), bp_at)
    return bytes(out)

def fix_wav(src, dst):
    d = bytearray(open(src, 'rb').read())
    if len(d) < 44 or d[:4] != b'RIFF': return False
    o = 12; data = None; fmt = None
    while o + 8 <= len(d):
        cid, sz = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        if cid == b'fmt ': fmt = struct.unpack_from('<HHIIHH', d, o + 8)
        if cid == b'data': data = o; break
        o += 8 + sz + (sz & 1)
    if data is None or fmt is None: return False
    have = len(d) - data - 8
    want = struct.unpack_from('<I', d, data + 4)[0]
    if have >= want:
        shutil.copyfile(src, dst); return True
    channels, bits = fmt[1], fmt[5]
    frame = channels * bits // 8
    have -= have % frame
    del d[data + 8 + have:]
    if bits == 16:  # затухание последних 60 мс, чтобы обрыв не щёлкал
        rate = fmt[2]
        n = min(have // frame, int(rate * 0.06))
        start = data + 8 + have - n * frame
        for k in range(n):
            g = 1 - (k + 1) / n
            for c in range(channels):
                pos = start + k * frame + c * 2
                s = struct.unpack_from('<h', d, pos)[0]
                struct.pack_into('<h', d, pos, int(s * g))
    struct.pack_into('<I', d, data + 4, have)
    struct.pack_into('<I', d, 4, len(d) - 8)
    open(dst, 'wb').write(d)
    print('  repaired truncated', os.path.basename(src), '%.2f of %.2f s' % (have / fmt[3], want / fmt[3]))
    return True

def main(src, dst):
    for rel in ['models/fc4km/bsmodimations_zombie_template', 'models/fc4km/weapons/c_limbs_template']:
        os.makedirs(os.path.join(dst, os.path.dirname(rel)), exist_ok=True)
        for ext in ['.mdl', '.vvd']:
            shutil.copyfile(os.path.join(src, rel + ext), os.path.join(dst, rel + ext))
        for ext in ['.dx80.vtx', '.dx90.vtx']:
            s = os.path.join(src, rel + ext)
            if os.path.exists(s) and os.path.getsize(s) > 0:
                shutil.copyfile(s, os.path.join(dst, rel + ext))
            else:
                open(os.path.join(dst, rel + ext), 'wb').write(empty_vtx(os.path.join(src, rel + '.mdl')))
                print('  wrote empty', rel + ext)
    sd = os.path.join(src, 'sound/fc4tkdwn_sfx'); dd = os.path.join(dst, 'sound/fc4tkdwn_sfx')
    os.makedirs(dd, exist_ok=True)
    for f in sorted(os.listdir(sd)):
        s = os.path.join(sd, f)
        if os.path.getsize(s) == 0 or not fix_wav(s, os.path.join(dd, f)):
            print('  skipped broken', f)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
