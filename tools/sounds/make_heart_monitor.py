# Звуки кардиомонитора (свои, синтез) для сердца по SCAV (organism/tier_1/modules/cl_heart_alarm.lua):
#   sound/rem_heart/alarm.wav    - тревога (фибрилляция > 60%): 3 + 2 коротких сигнала, пауза, по кругу (2.4 с);
#   sound/rem_heart/flatline.wav - непрерывный тон остановки сердца (3.5 с, к концу гаснет).
# Запуск из корня репозитория: python3 tools/sounds/make_heart_monitor.py
import os
import wave

import numpy as np

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "sound", "rem_heart")


def tone(freq, dur, vol=0.5, fade=0.012):
    t = np.arange(int(SR * dur)) / SR
    # чуть «электронный» тон: синус + немного 3-й гармоники
    s = np.sin(2 * np.pi * freq * t) + 0.18 * np.sin(2 * np.pi * freq * 3 * t)
    env = np.ones_like(t)
    n = int(SR * fade)
    env[:n] = np.linspace(0, 1, n)
    env[-n:] = np.linspace(1, 0, n)
    return s * env * vol / 1.18


def silence(dur):
    return np.zeros(int(SR * dur))


def save(name, x):
    os.makedirs(OUT, exist_ok=True)
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def alarm():
    # как высокий приоритет у мониторов: 3 сигнала, короткая пауза, ещё 2, длинная пауза
    beep, gap = 0.13, 0.09
    parts = []
    for i in range(3):
        parts += [tone(960, beep), silence(gap)]
    parts.append(silence(0.2))
    for i in range(2):
        parts += [tone(960, beep), silence(gap)]
    x = np.concatenate(parts)
    return np.concatenate([x, silence(2.4 - len(x) / SR)])


def flatline():
    x = tone(1000, 3.5, 0.45, fade=0.02)
    t = np.arange(len(x)) / SR
    x *= np.clip((3.5 - t) / 0.8, 0, 1)  # последние 0.8 с гаснет
    return x


if __name__ == "__main__":
    save("alarm.wav", alarm())
    save("flatline.wav", flatline())
    print("ok")
