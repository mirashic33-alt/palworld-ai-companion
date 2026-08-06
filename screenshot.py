# -*- coding: utf-8 -*-
"""Скриншот экрана по нашей горячей клавише — в нашу папку (не в папку Steam).

Шаг 1: просто снять экран и положить PNG в C.SHOT_DIR. Разбор снимка второй
моделью (vision) — отдельный следующий шаг, здесь его нет.
"""
import os, time
import config as C


def grab_and_save():
    """Снимок ВСЕГО основного экрана -> PNG в C.SHOT_DIR.
    Возвращает путь к файлу или None при ошибке.

    Замечание про полный экран: mss/PIL снимают экран через GDI — это надёжно
    работает в оконном и БЕЗрамочном полноэкранном режиме (borderless, в Palworld
    он по умолчанию). В ЭКСКЛЮЗИВНОМ полноэкранном может выйти чёрный кадр — тогда
    в игре надо переключить режим окна на «без рамки».
    """
    os.makedirs(C.SHOT_DIR, exist_ok=True)
    path = os.path.join(C.SHOT_DIR, time.strftime("shot_%Y-%m-%d_%H%M%S.png"))
    # основной путь — mss (быстрый)
    try:
        import mss, mss.tools
        with mss.mss() as sct:
            img = sct.grab(sct.monitors[1])   # [1] — основной монитор целиком
        mss.tools.to_png(img.rgb, img.size, output=path)
        return path
    except Exception:
        pass
    # запасной путь — PIL, если mss споткнулся
    try:
        from PIL import ImageGrab
        ImageGrab.grab().save(path)
        return path
    except Exception:
        return None
