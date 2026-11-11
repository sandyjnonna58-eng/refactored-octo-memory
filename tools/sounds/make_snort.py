# Звук "занюхнуть дорожку" для weapon_rem_meth: два коротких резких вдоха носом - шум, пропущенный через
# полосовой фильтр, с огибающей. Свой, сгенерированный. Запуск: python3 tools/sounds/make_snort.py
import math, os, random, struct, wave

SR = 44100
random.seed(7)

def sniff(dur, f_lo, f_hi, amp):
    n = int(SR * dur)
    out = []
    # двухполюсный полосовой фильтр (резонанс в середине полосы), частота плавно растёт - вдох "набирает силу"
    y1 = y2 = 0.0
    for i in range(n):
        t = i / n
        fc = f_lo + (f_hi - f_lo) * t
        r = 0.97
        w = 2 * math.pi * fc / SR
        a1, a2 = -2 * r * math.cos(w), r * r
        x = random.uniform(-1, 1)
        y = x - a1 * y1 - a2 * y2
        y2, y1 = y1, y
        env = math.sin(math.pi * min(t / 0.25, 1) / 2) * (1 - t) ** 0.6  # быстрый набор, спад
        out.append(y * env * amp)
    return out

samples = sniff(0.16, 1800, 3200, 0.05) + [0.0] * int(SR * 0.05) + sniff(0.42, 1500, 4200, 0.07) + [0.0] * int(SR * 0.08)
peak = max(abs(s) for s in samples) or 1
samples = [s / peak * 0.8 for s in samples]
path = os.path.join(os.path.dirname(__file__), '..', '..', 'sound', 'rem_drugs', 'snort.wav')
with wave.open(path, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<h', int(s * 32767)) for s in samples))
print('ok', os.path.normpath(path))
