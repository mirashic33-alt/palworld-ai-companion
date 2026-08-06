# -*- coding: utf-8 -*-
"""Звук затвора фотоаппарата при скриншоте (F8).

Играем через pyaudio — ТОЧНО тот механизм, что работает в образце Ari_Vision
(`_play_camera_click`), который у Олега всегда звучал. sounddevice и winsound
в живом ассистенте молчали (канал занят озвучкой / SND_PURGE), а pyaudio
открывает свой выходной поток и звучит надёжно.

Синтез — как в образце (тон 3 кГц + быстрое затухание), но двойной удар
«клак-клак», как затвор зеркалки (зеркало вверх — зеркало вниз).
"""
import threading


def _play():
    try:
        import numpy as np
        import pyaudio

        sr = 44100

        def one(dur, freq, amp):
            n = int(sr * dur)
            t = np.linspace(0, dur, n, False)
            wave = np.sin(2 * np.pi * freq * t)
            env = np.exp(-t * 60)          # быстрое затухание, как в образце
            return (wave * env * amp).astype(np.int16)

        c1 = one(0.08, 2600, 30000)                     # первый удар (ниже, громче)
        gap = np.zeros(int(sr * 0.05), dtype=np.int16)  # пауза ~50 мс
        c2 = one(0.06, 3200, 22000)                     # второй удар (выше, тише)
        click = np.concatenate([c1, gap, c2])

        pa = pyaudio.PyAudio()
        stream = pa.open(format=pyaudio.paInt16, channels=1, rate=sr, output=True)
        stream.write(click.tobytes())
        stream.stop_stream()
        stream.close()
        pa.terminate()
    except Exception as e:
        print(f"[shutter] {e}")   # не критично, но теперь ошибка ВИДНА


def play():
    """Проиграть щелчок затвора. Не блокирует — играем на daemon-потоке."""
    threading.Thread(target=_play, daemon=True).start()
