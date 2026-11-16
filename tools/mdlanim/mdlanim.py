# Декодер анимаций Source MDL (v48/49): кости, animdesc, seqdesc, кадры -> локальные pos/quat костей.
# Смотрели анимации мода Artagdoll (models/AREAnims/model_anim.mdl) - compat/sh_artagdoll.lua. Список: python3 mdlanim.py <.mdl>
import struct, math

def cstr(d, o):
    return d[o:d.index(b'\0', o)].decode('latin1')

def half(h):
    s = (h >> 15) & 1; e = (h >> 10) & 0x1f; m = h & 0x3ff
    if e == 0: v = (m / 1024.0) * 2 ** -14
    elif e == 31: v = float('inf')
    else: v = (1 + m / 1024.0) * 2 ** (e - 15)
    return -v if s else v

def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw*bx + ax*bw + ay*bz - az*by, aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw, aw*bw - ax*bx - ay*by - az*bz)

def euler_to_quat(x, y, z):  # RadianEuler -> Quaternion (Source AngleQuaternion(RadianEuler))
    sr, cr = math.sin(x*0.5), math.cos(x*0.5)
    sp, cp = math.sin(y*0.5), math.cos(y*0.5)
    sy, cy = math.sin(z*0.5), math.cos(z*0.5)
    srXcp, crXsp = sr*cp, cr*sp
    qx = srXcp*cy - crXsp*sy
    qy = crXsp*cy + srXcp*sy
    crXcp, srXsp = cr*cp, sr*sp
    qz = crXcp*sy - srXsp*cy
    qw = crXcp*cy + srXsp*sy
    return (qx, qy, qz, qw)

def qrot(q, v):
    x, y, z, w = q
    # v' = q v q*
    ix = w*v[0] + y*v[2] - z*v[1]
    iy = w*v[1] + z*v[0] - x*v[2]
    iz = w*v[2] + x*v[1] - y*v[0]
    iw = -x*v[0] - y*v[1] - z*v[2]
    return (ix*w + iw*-x + iy*-z - iz*-y, iy*w + iw*-y + iz*-x - ix*-z, iz*w + iw*-z + ix*-y - iy*-x)

class MDL:
    def __init__(self, path):
        d = self.d = open(path, 'rb').read()
        assert d[:4] == b'IDST', 'not mdl'
        self.version = struct.unpack_from('<i', d, 4)[0]
        nb, bi = struct.unpack_from('<ii', d, 156)
        self.bones = []
        for i in range(nb):
            b = bi + i * 216
            ni, parent = struct.unpack_from('<ii', d, b)
            pos = struct.unpack_from('<3f', d, b + 32)
            quat = struct.unpack_from('<4f', d, b + 44)
            rot = struct.unpack_from('<3f', d, b + 60)
            posscale = struct.unpack_from('<3f', d, b + 72)
            rotscale = struct.unpack_from('<3f', d, b + 84)
            self.bones.append(dict(name=cstr(d, b + ni), parent=parent, pos=pos, quat=quat, rot=rot, posscale=posscale, rotscale=rotscale))
        na, ai = struct.unpack_from('<ii', d, 180)
        self.anims = []
        for i in range(na):
            a = ai + i * 100
            (base, ni, fps, flags, numframes, nmov, movi) = struct.unpack_from('<iifiiii', d, a)
            animblock, animindex = struct.unpack_from('<ii', d, a + 52)
            sectionindex, sectionframes = struct.unpack_from('<ii', d, a + 80)
            self.anims.append(dict(off=a, name=cstr(d, a + ni), fps=fps, flags=flags, frames=numframes,
                                   animblock=animblock, animindex=animindex, sectionindex=sectionindex, sectionframes=sectionframes))
        ns, si = struct.unpack_from('<ii', d, 188)
        self.seqs = []
        for i in range(ns):
            s = si + i * 212
            label = cstr(d, s + struct.unpack_from('<i', d, s + 4)[0])
            act = cstr(d, s + struct.unpack_from('<i', d, s + 8)[0])
            flags = struct.unpack_from('<i', d, s + 12)[0]
            numblends, animindexindex = struct.unpack_from('<ii', d, s + 56)
            groupsize = struct.unpack_from('<ii', d, s + 68)
            animidx = [struct.unpack_from('<h', d, s + animindexindex + 2*k)[0] for k in range(groupsize[0]*groupsize[1])]
            self.seqs.append(dict(name=label, act=act, flags=flags, anims=animidx))

    def _value(self, o, frame):
        d = self.d
        k = frame
        while True:
            valid, total = d[o], d[o + 1]
            if total == 0: return 0.0
            if k < total: break
            k -= total
            o += 2 * (valid + 1)
        if k < valid: return struct.unpack_from('<h', d, o + 2 * (k + 1))[0]
        return struct.unpack_from('<h', d, o + 2 * valid)[0]

    def _vals(self, vp, frame):
        offs = struct.unpack_from('<3h', self.d, vp)
        out = []
        for j in range(3):
            out.append(0.0 if offs[j] == 0 else self._value(vp + offs[j], frame))
        return out

    def frame_pose(self, ai, frame):
        """локальные (pos, quat) всех костей в кадре frame"""
        a = self.anims[ai]
        d = self.d
        pose = [(b['pos'], b['quat']) for b in self.bones]
        if a['animblock'] != 0:
            raise ValueError('external animblock')
        base = a['off']
        if a['sectionframes']:
            sec = frame // a['sectionframes']
            sb, so = struct.unpack_from('<ii', d, base + a['sectionindex'] + 8 * sec)
            o = base + so
            frame = frame - sec * a['sectionframes']
        else:
            o = base + a['animindex']
        delta = a['flags'] & 0x4
        while True:
            bone, flags, nxt = struct.unpack_from('<BBh', d, o)
            p = o + 4
            B = self.bones[bone]
            q = None; pos = None
            if flags & 0x20:  # RAWROT2 Quaternion64
                v = int.from_bytes(d[p:p+8], 'little')
                x = ((v) & 0x1fffff); y = ((v >> 21) & 0x1fffff); z = ((v >> 42) & 0x1fffff); wn = (v >> 63) & 1
                x = (x - 1048576) / 1048576.5; y = (y - 1048576) / 1048576.5; z = (z - 1048576) / 1048576.5
                w = math.sqrt(max(0.0, 1 - x*x - y*y - z*z)); w = -w if wn else w
                q = (x, y, z, w); p += 8
            elif flags & 0x02:  # RAWROT Quaternion48
                xs, ys, zw = struct.unpack_from('<HHH', d, p)
                x = (xs - 32768) / 32768.0; y = (ys - 32768) / 32768.0; z = ((zw & 0x7fff) - 16384) / 16384.0
                w = math.sqrt(max(0.0, 1 - x*x - y*y - z*z)); w = -w if (zw >> 15) else w
                q = (x, y, z, w); p += 6
            elif flags & 0x08:  # ANIMROT
                v = self._vals(p, frame)
                e = [v[j] * B['rotscale'][j] + (0 if delta else B['rot'][j]) for j in range(3)]
                q = euler_to_quat(*e); p += 6
            if flags & 0x01:  # RAWPOS
                pos = tuple(half(h) for h in struct.unpack_from('<3H', d, p)); p += 6
            elif flags & 0x04:  # ANIMPOS
                v = self._vals(p, frame)
                pos = tuple(v[j] * B['posscale'][j] + (0 if delta else B['pos'][j]) for j in range(3))
            cur = pose[bone]
            pose[bone] = (pos if pos is not None else cur[0], q if q is not None else cur[1])
            if nxt == 0: break
            o += nxt
        return pose

    def world(self, pose):
        out = []
        for i, b in enumerate(self.bones):
            pos, q = pose[i]
            if b['parent'] < 0:
                out.append((pos, q))
            else:
                pp, pq = out[b['parent']]
                rp = qrot(pq, pos)
                out.append(((pp[0]+rp[0], pp[1]+rp[1], pp[2]+rp[2]), qmul(pq, q)))
        return out

if __name__ == '__main__':
    import sys
    m = MDL(sys.argv[1])
    print('version', m.version, 'bones', len(m.bones))
    print([b['name'] for b in m.bones])
    for i, a in enumerate(m.anims):
        print('anim', i, a['name'], 'frames', a['frames'], 'fps', a['fps'], 'flags', hex(a['flags']), 'block', a['animblock'], 'sec', a['sectionframes'])
    for s in m.seqs:
        print('seq', s['name'], s['act'], 'anims', s['anims'])
