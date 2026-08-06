# -*- coding: utf-8 -*-
"""Голос Мии для игрового ассистента — ElevenLabs Flash v2.5 (быстрый, живой).

Не Edge TTS: тот звучит роботом. Здесь — тот же голос, которым Мия говорит в
телеге (Victoria), но на модели Flash — она заточена под низкую задержку.

Приём звука: просим у ElevenLabs сырой PCM, оборачиваем в WAV-заголовок и играем
через winsound (встроен в Windows-Python, кодеки не нужны). Бонус: PlaySound с
SND_ASYNC сам обрывает предыдущую реплику — новое событие перебивает старое,
как живой комментатор, а не автоответчик.
"""
import os, re, struct, base64, tempfile, threading, time, winsound, requests
import config as C


def _key() -> str:
    # Ключ ElevenLabs: сперва из окружения ELEVEN_API_KEY, иначе из файла eleven.key рядом с config.
    return (os.environ.get("ELEVEN_API_KEY")
            or open(C.ELEVEN_KEY_FILE, encoding="utf-8").read().strip())


def _clean(text: str) -> str:
    """Готовим текст к голосу: режем маркеры, код, markdown, эмодзи — чтоб читалась речь."""
    text = re.sub(r"\[\[.*?\]\]", "", text)                 # наши маркеры [[ФОТО:..]]
    text = re.sub(r"`{1,3}.*?`{1,3}", "", text, flags=re.DOTALL)
    text = re.sub(r"\*{1,3}(.*?)\*{1,3}", r"\1", text)
    text = re.sub(r"[\U00010000-\U0010ffff]", "", text)     # эмодзи
    text = re.sub(r"[\U00002600-\U000027BF]", "", text)     # значки
    return text.strip()


def _pcm_to_wav(pcm: bytes, sr: int) -> bytes:
    """Оборачиваем сырой 16-bit mono PCM в минимальный WAV-заголовок (44 байта)."""
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


_TMP = os.path.join(tempfile.gettempdir(), "mia_speak.wav")
_lock = threading.Lock()

# «Поколение» речи: каждый speak() берёт свой номер, stop()/новый speak() двигает
# счётчик. Прерванный поток видит, что номер сменился, и тихо уходит — не трогая
# состояние новой реплики. Так перебивка (режим без буфера) не ломает синхронизацию.
_gen = 0
_gen_lock = threading.Lock()


def _synth_eleven(speech: str):
    """ElevenLabs Flash → (pcm_bytes, sr) или None. Самый быстрый, платный."""
    url = (f"https://api.elevenlabs.io/v1/text-to-speech/{C.ELEVEN_VOICE}"
           f"?output_format=pcm_{C.ELEVEN_SR}")
    body = {
        "text": speech[:2000],
        "model_id": C.ELEVEN_MODEL,
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.8,
                           "style": 0.2, "use_speaker_boost": True, "speed": 1.05},
    }
    r = requests.post(url, json=body,
                      headers={"xi-api-key": _key(), "Content-Type": "application/json"},
                      timeout=30)
    if r.status_code != 200:
        return None
    return r.content, C.ELEVEN_SR


def _synth_gemini(speech: str):
    """Gemini TTS через тот же GEMINI_API_KEY → (pcm_bytes, sr) или None.
    Генеративный движок: чуть думает, зато без второго ключа и дешевле."""
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not key:
        return None
    style = getattr(C, "GEMINI_TTS_STYLE", "") or ""
    body = {
        "contents": [{"parts": [{"text": (style + speech)[:2000]}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {
                "voiceName": C.GEMINI_TTS_VOICE}}},
        },
    }
    url = ("https://generativelanguage.googleapis.com/v1beta/models/"
           f"{C.GEMINI_TTS_MODEL}:generateContent")
    r = requests.post(url, headers={"x-goog-api-key": key}, json=body, timeout=40)
    if r.status_code != 200:
        return None
    parts = r.json().get("candidates", [{}])[0].get("content", {}).get("parts", [])
    for p in parts:
        data = p.get("inlineData", {}).get("data")
        if data:
            return base64.b64decode(data), C.GEMINI_TTS_SR
    return None


def _synth_and_play(text: str, on_timed=None, gen: int = 0):
    dt = 0.0
    play_dur = 0.0
    try:
        speech = _clean(text)
        if not speech:
            return
        engine = getattr(C, "TTS_ENGINE", "eleven")
        t0 = time.monotonic()
        try:
            res = _synth_gemini(speech) if engine == "gemini" else _synth_eleven(speech)
        except Exception:
            res = None
        dt = time.monotonic() - t0            # чистое время синтеза — для счётчика в пузыре
        if not res:
            return
        pcm, sr = res
        wav = _pcm_to_wav(pcm, sr)
        play_dur = len(pcm) / float(sr * 2)   # длительность аудио (16-bit mono): 2 байта/сэмпл
        if gen != _gen:                       # нас успели перебить ещё на синтезе — не играем
            return
        with _lock:
            with open(_TMP, "wb") as f:
                f.write(wav)
            # SND_ASYNC — НЕ блокирует поток и прерывается новым PlaySound / SND_PURGE.
            # Это возвращает перебивку: V.stop() из другого потока реально глушит речь.
            winsound.PlaySound(_TMP, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
    except Exception:
        play_dur = 0.0
    # Ждём конец реального воспроизведения — но ПРЕРЫВАЕМО: если пришло новое
    # поколение (stop или новая реплика), выходим сразу и НЕ зовём on_timed —
    # состоянием _speaking теперь владеет новая реплика, старая его не трогает.
    end = time.monotonic() + play_dur
    while time.monotonic() < end:
        if gen != _gen:
            return
        time.sleep(0.05)
    if gen == _gen and on_timed:
        try:
            on_timed(dt)
        except Exception:
            pass


def speak(text: str, on_timed=None):
    """Озвучить реплику в фоне — не морозит ни окно, ни мозг-поток.
    on_timed(секунды) — необяз. колбэк с чистым временем синтеза (для счётчика в пузыре)."""
    global _gen
    with _gen_lock:
        _gen += 1
        g = _gen
    threading.Thread(target=_synth_and_play, args=(text, on_timed, g), daemon=True).start()


def stop():
    """Оборвать текущую речь (перебивка / выход): двигаем поколение и глушим звук."""
    global _gen
    with _gen_lock:
        _gen += 1        # инвалидируем текущую речь — её поток уйдёт, не тронув состояние
    try:
        winsound.PlaySound(None, winsound.SND_PURGE)
    except Exception:
        pass
