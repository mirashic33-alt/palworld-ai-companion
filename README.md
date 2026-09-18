# Mia · voice AI companion for Palworld

*[Русская версия](README.ru.md)*

A living AI companion that sits next to you while you play **Palworld**: it watches what
happens in the game, reacts out loud with a personality, hears you through the microphone,
sees your screen on a hotkey and remembers your previous sessions.

This is not a bot that reads the log out loud. The core idea is **dynamics, not statics**:
the model doesn't decide what to react to — a cheap dispatcher in plain code does. It
strangles spam, throws away stale events and hands the network only what is actually worth
saying, in short bursts. Every event gets its own reaction, not a template.

> ⚠️ Unofficial fan project. Palworld and all in-game names belong to Pocketpair, Inc.
> The project is not affiliated with the game and patches nothing inside it — it only reads
> an event log written by a separate UE4SS mod, and speaks its reactions.

---

## Features

- **Dispatcher brain** — filters the event stream: minor spam no more than once every N
  seconds, anything stale (older than a few seconds) is dropped, a burst is merged into one
  batch. A separate "world model" keeps track of what is going on right now.
- **Voice (mouth)** — speech through ElevenLabs Flash v2.5 (low latency) or Gemini TTS
  (same key, no second service). Switchable on the fly from the window.
- **Hearing (ears)** — push-to-talk: hold the key, speak → `faster-whisper` recognises your
  speech offline → the text goes to the companion. Free and private.
- **Vision (eyes)** — pressing **F8** sends a screenshot to a separate vision model, which
  gives a short tactical read of the situation without blocking the reactive voice line.
- **Memory** — survives a shutdown: `memory.json` (dialogue and world state), `game_map.md`
  (a compressed "map of the game" kept by a background chronicler), `game_memory.md`
  (session milestones), `знания.md` (a knowledge base about the game that fills itself
  from the internet).
- **Two personality modes** — "chill" (playing solo at home, relaxed tone) and "guest"
  (public server with live players, warm and polite tone). Switchable on the fly.
- **Liveliness** — high temperature plus a memory of recent lines with a ban on repeating
  itself: ten identical events get ten different reactions.

---

## Requirements

- **Windows** (audio is played through `winsound`, hotkeys are Windows-specific).
- **Python 3.10+**.
- **Palworld** + [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — for the event mod.
- A **Google Gemini** key (required) and an **ElevenLabs** key (optional, for that voice).

### Python dependencies

```
pip install PySide6 requests faster-whisper sounddevice numpy mss Pillow pyaudio
```

---

## Setup

### 1. API keys

**Gemini (required)** — read from an environment variable. Set it once:

```powershell
setx GEMINI_API_KEY "your-key-from-google-ai-studio"
```

(the key is free from [Google AI Studio](https://aistudio.google.com/apikey); the code also
understands `GOOGLE_API_KEY`). Restart your terminal after `setx`.

**ElevenLabs (optional, only for the ElevenLabs voice)** — two ways:
- the `ELEVEN_API_KEY` environment variable, **or**
- a file `eleven.key` next to `config.py` with the key on a single line.

Without an ElevenLabs key just switch the speech engine to `gemini` (button in the window
header, or `TTS_ENGINE = "gemini"` in `config.py`) — it runs on the same Gemini key.

### 2. The MiaEvents mod

The companion reads events from a log written by a UE4SS mod. Copy the **`MiaEvents`**
folder (included in this repository) into the UE4SS mods folder:

```
...\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods\MiaEvents\
```

The mod has to be enabled (in UE4SS that is either `mods.txt` or an `enabled.txt` file
inside the mod folder — it is already there). While you play, the mod writes events into
`events.log` in its own folder — that path is what `config.py` points to (`LOG_FILE`).

> The log path in `config.py` assumes a standard Steam install. If your Palworld lives
> somewhere else, fix `LOG_FILE` in `config.py`.

### 3. Your in-game name

Set `PLAYER_NAME` in `config.py` to your Palworld chat nickname. That is how the companion
tells **your** messages apart from other players in multiplayer.

---

## Running it

```
pythonw assistant.pyw
```

(run it as `python assistant.pyw` to see errors in the console if something is off.)

### Trying it right now, without the game

There is an input field at the bottom of the window — type a test event, for example
`ПОЙМАН ПАЛ: Гумосс` ("pal caught"), and hit Enter. The companion will react. That shows
you the brain and the voice without launching Palworld.

### With the game

Press the **«Игра»** ("Game") button, start Palworld with the MiaEvents mod enabled — and
the companion starts commenting on everything that happens.

---

## Settings

Some parameters are tuned **live from the window** (the ⚙ button): line length, temperature
(liveliness), Gemini model, speech engine, pauses, personality mode. They apply without a
restart and survive a shutdown (`settings.json`).

The rest lives in **`config.py`** with detailed comments: dispatcher timings, models for
vision and for the chronicler, the screenshot hotkey, voices, theme colours.

---

## Layout

| File / folder     | What it is                                                          |
|-------------------|---------------------------------------------------------------------|
| `assistant.pyw`   | The window (PySide6): log watching, microphone, screenshots, threads |
| `brain.py`        | The brain: dispatcher, world model, personality prompts, Gemini call |
| `voice.py`        | Speech: ElevenLabs Flash / Gemini TTS                                |
| `screenshot.py`   | Screen capture on F8 (mss, with a Pillow fallback)                   |
| `shutter.py`      | Microphone capture for speech recognition                            |
| `config.py`       | All settings and constants                                           |
| `знания.md`       | Knowledge base about the game (fills itself, editable by hand)       |
| `MiaEvents/`      | The UE4SS mod: writes game events into `events.log` (Lua)            |
| `скриншоты/`      | Where F8 screenshots land                                            |

The memory files (`memory.json`, `game_map.md`, `game_memory.md`) are created automatically
on first run.

---

## How it works (short version)

1. The **MiaEvents** mod hooks UE4SS onto the game's functions (pal caught, level up, death,
   chat, boss, chest…) and writes them as human-readable lines into `events.log`.
2. `assistant.pyw` tails that log, and the **dispatcher** in `brain.py` filters the stream
   and decides what deserves a reaction.
3. What survives goes to **Gemini** together with the personality prompt, and the answer
   goes to **speech**.
4. In parallel: the microphone (`faster-whisper`) gives voice input, F8 gives vision, a
   background chronicler compresses the log into a "map of the game", and everything is
   written to disk.

---

## A note on the language

The interface labels and the code comments are in Russian — this started as a personal
project. The setup above is all you need to run it; if anything inside is unclear, open an
issue and I'll translate that part.
