# -*- coding: utf-8 -*-
"""Игровой ассистент Мия — прототип.

Окно + текстовый чат. Следит за events.log игры, на новые события реагирует
живой репликой от Gemini. Память (разговор + состояние мира) сохраняется на
диск и переживает выкл/вкл. Голос и микрофон — потом; сейчас чистый мозг.

Запуск:  pythonw assistant.pyw   (или python assistant.py для консоли с логами)
"""
import os, time, random, threading
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtCore import Qt, QObject, QThread, QTimer, Signal, Slot, QSize, QPointF
from PySide6.QtGui import QFont, QIcon, QPixmap, QPainter, QColor, QBrush, QPen, QAction, QPolygonF
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QLineEdit, QPushButton, QScrollArea, QFrame, QSystemTrayIcon, QMenu,
    QDialog, QFormLayout, QSpinBox, QDoubleSpinBox, QPlainTextEdit, QComboBox
)

import config as C
import brain as B
import voice as V
import screenshot as S


# =========================================================== защита от двойного запуска
# Один голос — один процесс. Если открыть второе окно, пока живо старое (зависло, в трее),
# получается два голоса вразнобой. Держим именованный локальный сервер: новый запуск
# находит старый, велит ему закрыться и забирает управление себе (новейший побеждает).
INSTANCE_KEY = "MiaPalworldAssistant.single"

def take_over_single_instance():
    """Есть живой экземпляр — говорим ему «умри» и ждём, пока освободит имя. Затем стартуем сами."""
    sock = QLocalSocket()
    sock.connectToServer(INSTANCE_KEY)
    if sock.waitForConnected(300):
        sock.write(b"QUIT")
        sock.flush()
        sock.waitForBytesWritten(500)
        sock.disconnectFromServer()
        time.sleep(0.7)          # даём старому заткнуть голос, прибрать потоки и отпустить сервер
    QLocalServer.removeServer(INSTANCE_KEY)   # снести протухшее имя, если старый умер грязно


# =========================================================== мозг в отдельном потоке
class BrainWorker(QObject):
    """Живёт в своём QThread: фильтрует события, зовёт Gemini, не морозит окно."""
    replied = Signal(str, str, float)   # (что случилось, реплика Мии, латентность сек)
    idled   = Signal(str, float)        # реплика-заполнитель тишины (без события) + латентность
    spoke   = Signal(float)             # чистое время озвучки (сек) — дописать в пузырь
    released = Signal()                 # пачку отбросили (протухла/фильтр) — говорить не будем, освободить буфер

    def __init__(self, memory):
        super().__init__()
        self.state = B.WorldState()
        self.dispatcher = B.Dispatcher()
        self.recent_replies = []
        self.memory = memory
        self.voice_on = C.VOICE_ON
        self.gui = None   # окно; ставится в _start_brain — чтобы не озвучивать поверх защищённого
        # карта игры от летописца — держим строкой в памяти (с диска, если осталась с прошлого раза)
        self.game_map = B.load_chronicle()
        # восстановить состояние мира из памяти
        st = memory.get("state", {})
        self.state.last_pal = st.get("last_pal")
        self.state.money = st.get("money")
        self.state.level = st.get("level")
        for e in memory.get("conversation", [])[-C.RECENT_REPLIES:]:
            if e.get("reply"):
                self.recent_replies.append(e["reply"])
        # время последнего super-события (для тихой зоны после босса/рейда/редкого)
        self._last_high_prio = 0.0
        # время последней поимки/убийства пала — короткое окно, в котором мусор (лут)
        # не перебивает реакцию, а другая поимка/убийство/событие проходит (динамика)
        self._last_catch = 0.0
        # время поимки СЧАСТЛИВОГО (редкого) пала — жёсткая зона: несколько секунд
        # реакцию не перебивает НИЧТО (даже сундук/статуя-super), кроме нового счастливого
        # пала и прямого обращения игрока (игрок, 27.07)
        self._last_lucky = 0.0

    @Slot(str)
    def set_chronicle(self, text):
        """Летописец пересобрал карту — подхватываем один раз, в памяти (не на каждое событие)."""
        if text:
            self.game_map = text

    @Slot(list, float, bool)
    def handle(self, lines, stamp, manual=False):
        try:
            self._handle(lines, stamp, manual)
        except Exception as e:
            # раньше любая ошибка тут молча убивала обработку — игрок видел «ничего
            # не происходит». Теперь ошибка всплывает пузырём, а не глохнет.
            import traceback; traceback.print_exc()
            self.replied.emit("\n".join(lines), f"(ошибка обработки: {e})", 0.0)

    def _handle(self, lines, stamp, manual=False):
        now = time.monotonic()
        # Протухло, пока стояли в очереди, — выкидываем (не комментируем прошлое).
        # НО ручную отправку («Отправить») не роняем никогда: игрок ждёт ответ явно.
        if not manual and now - stamp > C.STALE_SEC:
            self.released.emit()   # иначе _speaking залипнет True навсегда — Мия онемеет
            return
        texts = []
        for line in lines:
            _, text = B.parse_line(line)
            if not text:
                continue
            # мусор чужого сервера (серверный автомат + чат чужих игроков) — молчим:
            # не зовём модель, не пачкаем историю мира. Ручной ввод не трогаем.
            if not manual and B.ignore_event(text):
                continue
            texts.append(text)
        # Одна гибель игрока = до 4 строк из разных каналов мода + мусор «сам себя
        # убил» + болванка-убийца. Схлопываем в ОДНУ «ИГРОК УМЕР[, убийца: X]»,
        # чтобы Мия не называла трёх убийц за одну смерть (игрок, 31.07).
        texts = B.collapse_deaths(texts)
        # Поймали пала — лут с него падает в инвентарь ТОЙ ЖЕ секундой. Для игрока это
        # один момент, а не отдельная новость, поэтому в такой пачке лут кулдауном
        # мелочи не душим: иначе из двух дропов доезжал один, а то и ни одного.
        has_catch = any("ПОЙМАН ПАЛ" in t for t in texts)
        has_kill  = any("ПАЛ УБИТ" in t for t in texts)
        # Вскрыли сундук — содержимое сыплется в инвентарь той же секундой. Как и с
        # поимкой, это ОДИН момент: лут кулдауном не душим, иначе добыча не доедет.
        has_chest = any("ОТКРЫТ СУНДУК" in t for t in texts)
        kept = []
        for text in texts:
            # Смена сервера/мира: старые уровень, деньги и палы остались ТАМ.
            # Чистим картину мира, иначе Мия спрашивает про пала с прошлого сервера.
            if "ЗАХОД В МИР" in text:
                self.state.last_pal = None
                self.state.money = None
                self.state.level = None
                self.state.recent = []
            self.state.update(text)
            # ручной ввод не душим кулдауном спама — он всегда должен долетать
            if (manual or (has_catch and B.is_loot(text))
                    or (has_chest and (B.is_loot(text) or "ДЕНЬГИ" in text))
                    or self.dispatcher.keep(text)):
                kept.append(text)
        if not kept:
            self.released.emit()   # всё отфильтровано (спам/пусто) — освободить буфер
            return

        # Пассивки пала — делаем ДО special, чтоб legendary попали туда
        gold, legendary = [], []
        for t in kept:
            lvl, note, kind = B.passive_tier(t)
            if lvl < 2:
                continue
            nm = B.pal_name(t) or "пал"
            if kind == "bad":
                gold.append(f"{nm} — с ПЛОХОЙ пассивкой-дебаффом «{note}»: это НЕ удача, а невезуха "
                            f"(чем выше уровень — тем хуже для пала), постебись или посочувствуй")
            elif lvl >= 3:
                legendary.append(t)
            else:
                gold.append(f"{nm} — с золотой (2★) пассивкой «{note}», хороший экземпляр")

        # Super-события — безусловный приоритет. Включают рейд (баг Евы: раньше летел как chatter).
        special = [t for t in kept
                   if "ЛЕВЕЛАП" in t or "ОЧКИ" in t or "БОСС" in t.upper() or "РЕЙД" in t.upper()
                   or "РЕДКИЙ" in t.upper() or "★" in t or "ЭФФИГ" in t.upper()
                   or "ФРУКТ" in t.upper()
                   or "РАЗГОВОР С NPC" in t     # редкое и важное — не терять в пачке (игрок, 26.07)
                   or "СУНДУК" in t.upper() or "ТОРГОВЕЦ" in t.upper()   # деревня и лут — не мелочь
                   or "СТАТУЯ ТЕЛЕПОРТА" in t   # первая активация статуи: +опыт и кусок карты
                   or "КЛЕТК" in t.upper()      # освобождение пала из клетки — редкое, не перебивать (игрок, 27.07)
                   or "ЗАХОД В МИР" in t        # смена сервера — сказать обязательно
                   or B.classify(t)[1] == 3
                   or t in legendary]

        # Счастливый (редкий) пал в этой пачке — крупная удача, его реакцию бережём жёстко.
        # Легендарная пассивка (III+) по инструкции «круче даже блестящего» — значит и её
        # реакцию бережём тихой зоной так же, как счастливого пала: следующий пал её не
        # перебивает (игрок, 31.07: поймал Гумосса с «Плавание III», реакцию смыл поток).
        has_lucky = (any("ПОЙМАН ПАЛ" in t and "РЕДКИЙ" in t.upper() for t in kept)
                     or bool(legendary))
        # Жёсткая зона счастливого пала: LUCKY_QUIET_SEC после его поимки НИЧТО не перебивает
        # его реакцию — даже сундук/статуя (они super и иначе проскочили бы тихую зону).
        # Исключение — новый счастливый пал и прямое обращение игрока (игрок, 27.07).
        in_lucky_quiet = (now - self._last_lucky) < getattr(C, "LUCKY_QUIET_SEC", 12)

        # Тихая зона: 25 сек после super-события мелкий лут не перебивает реакцию.
        # Пример: поймали босса → подобрали дерево → дерево молчит, не глушит восторг.
        in_quiet = (now - self._last_high_prio) < 25
        # Короткое окно после поимки/убийства пала: мусор (лут с земли) НЕ перебивает
        # её реакцию, но другая поимка/убийство/событие проходит — это динамика (игрок, 27.07).
        in_catch_quiet = (now - self._last_catch) < getattr(C, "CATCH_QUIET_SEC", 15)

        if manual:
            # Прямое обращение игрока (поле ввода ИЛИ чат игры) — берём как есть, БЕЗ
            # фильтров приоритета и тихой зоны. Иначе сообщение, набранное сразу после
            # босса/рейда, отсеивалось бы как «мелочь» и Мия молчала бы в ответ на чат.
            block = "\n".join(kept[-5:])
        elif in_lucky_quiet and not has_lucky:
            # Только что поймали счастливого пала — держим паузу: НИЧЕГО (даже сундук,
            # статуя, лут) не рвёт его реакцию. Новый счастливый пал сюда не попадает
            # (has_lucky) — он важнее и перебивает. Молчим, буфер освобождаем.
            self.released.emit()
            return
        elif special:
            # Есть super: block = только главное; мелочь в той же пачке не перебивает
            self._last_high_prio = now
            if has_lucky:
                self._last_lucky = now   # запускаем жёсткую зону защиты счастливого
            block = "\n".join(special[-3:])
        elif in_quiet:
            # Тихая зона: пропускаем рутинный лут, берём только mid-уровень (поимки, смерти)
            mid = [t for t in kept
                   if B.classify(t)[1] >= 2 and "ПОЛУЧЕН ПРЕДМЕТ" not in t]
            if not mid:
                self.released.emit()   # только мусор в тихой зоне — молчим, но буфер освобождаем
                return   # состояние мира уже обновлено
            block = "\n".join(mid[-3:])
        elif in_catch_quiet and not (has_catch or has_kill):
            # Идёт реакция на недавнюю поимку/убийство, а сейчас пришёл только мусор.
            # Мусор (лут) выкидываем — не перебивает; всё остальное (сундук, статуя и т.п.)
            # пропускаем. Свежая поимка/убийство сюда не попадает — она перебивает (динамика).
            nonloot = [t for t in kept if not B.is_loot(t)]
            if not nonloot:
                self.released.emit()   # только мусор — молчим, реакция на пала не рвётся
                return
            block = "\n".join(nonloot[-3:])
        elif has_catch:
            # Сама поимка не должна выпасть из окна, если следом насыпалось много лута
            catch = [t for t in kept if "ПОЙМАН ПАЛ" in t]
            rest = [t for t in kept if "ПОЙМАН ПАЛ" not in t]
            block = "\n".join(catch[-1:] + rest[-3:])
        else:
            block = "\n".join(kept[-3:])    # штатный режим: последние 3

        # ★БОСС (альфа/полевой босс) — крупная добыча, акцентом ПЕРЕД пассивками.
        # Имя тянем прямо из строки: pal_name() понимает только «ПОЙМАН ПАЛ»,
        # а метка босса приходит ещё и с «ПАЛ УБИТ».
        boss = []
        for t in kept:
            if "★БОСС" not in t:
                continue
            nm = t.split("★БОСС", 1)[1].split("[")[0].strip() or "босс"
            verb = "поймали" if "ПОЙМАН" in t else ("завалили" if "УБИТ" in t else "встретили")
            boss.append(verb + " " + nm)
        if boss:
            block += ("\n\nЭТО БОСС — " + ", ".join(boss[-2:]) + ". Не рядовой пал: альфа-босс, "
                      "сильно выше уровнем, огромный запас HP, за ПЕРВУЮ победу над ним дают "
                      "очко древних технологий. Отметь это ПЕРВЫМ ДЕЛОМ и порадуйся вместе с "
                      "игроком («мы его сделали!»), а пассивки и прочее — уже потом.")

        # ★РЕДКИЙ (блестящий/shiny) пал — бурная эмоция отдельным акцентом
        rare = [B.pal_name(t) or "пал" for t in kept if "РЕДКИЙ" in t]
        if rare:
            block += ("\n\nОСОБАЯ УДАЧА — поймал ★РЕДКОГО (блестящего, shiny) пала: "
                      + ", ".join(rare[-2:]) + ". Это крупная редкость, ловится нечасто — "
                      "искренне обрадуйся, своими словами.")

        # ЛЕГЕНДАРНАЯ пассивка (III+) — максимальный восторг
        legend_names = []
        for t in legendary:
            nm = B.pal_name(t) or "пал"
            lp = B.legendary_passives(t)
            legend_names.append(f"{nm} — легендарная пассивка «{', '.join(lp)}»" if lp else nm)
        if legend_names:
            block += ("\n\nЛЕГЕНДАРНАЯ УДАЧА — у пала пассивка ВЫСШЕГО ранга (III+), редчайшая "
                      "находка, круче даже блестящего! " + "; ".join(legend_names[-2:]) + ". "
                      "Это ТОТ САМЫЙ случай, когда искренний восторг уместен и НУЖЕН — не "
                      "приземляй его самоиронией, как рядовую поимку. Обязательно назови "
                      "пассивку вслух по имени, подчеркни, что она ЛЕГЕНДАРНАЯ и редкая (не "
                      "рядовая прокачка), и по-настоящему порадуйся крупной удаче своими "
                      "словами — без заготовленных восклицаний и без бахвальства силой.")

        if gold:
            block += ("\n\nОТДЕЛЬНО ВАЖНО — у пойманного пала особая пассивка, обыграй её "
                      "(хорошую — восторженно, дебафф — со стёбом): " + "; ".join(gold[-2:]))

        # Лут с пойманного пала: падает в инвентарь в ту же секунду — это часть поимки,
        # а не отдельная новость. Даём его припиской, чтобы вошло в ОДНУ фразу
        # (и не потерялось, когда block занят боссом/редким).
        if has_catch:
            drops = [t.split(":", 1)[1].strip() for t in kept if B.is_loot(t) and ":" in t]
            if drops:
                block += ("\n\nВМЕСТЕ С ПОИМКОЙ с этого пала упал лут: " + ", ".join(drops[-4:])
                          + ". Это ОДИН момент, а не два события — про пала и добычу скажи "
                          "ОДНОЙ фразой, лут вскользь. Названия предметов приходят "
                          "по-английски — называй их по-русски.")

        # Лут из сундука: содержимое сыплется в инвентарь той же секундой (строки
        # «ПОЛУЧЕН ПРЕДМЕТ» и «💰 ДЕНЬГИ»). Но в режиме super block = только строка
        # «ОТКРЫТ СУНДУК», и добыча из него выпадала — Мия говорила «сундук» и умолкала.
        # Возвращаем содержимое припиской, ровно как для лута с пойманного пала.
        if has_chest and not has_catch:
            drops = [t.split(":", 1)[1].strip() for t in kept if B.is_loot(t) and ":" in t]
            money = next((t.split("ДЕНЬГИ", 1)[1].strip() for t in kept if "ДЕНЬГИ" in t), "")
            if money:
                drops.append("монеты " + money)
            if drops:
                block += ("\n\nВНУТРИ СУНДУКА была добыча: " + ", ".join(drops[-5:])
                          + ". Это ОДИН момент — про сундук и что в нём лежало скажи ОДНОЙ "
                          "фразой, добычу назови. Названия предметов приходят по-английски "
                          "— называй их по-русски.")

        # Поймали/убили пала прямо сейчас — открываем окно, в котором следующий
        # мусор (лут) не перебьёт эту реакцию (другая поимка/событие — перебьёт).
        if has_catch or has_kill:
            self._last_catch = now

        history = self.state.history(exclude=len(kept))   # что было ДО этой пачки
        t0 = time.monotonic()
        reply = B.ask_gemini(block, self.state.summary(), self.recent_replies,
                             history, self.game_map, manual=manual)
        latency = time.monotonic() - t0        # сколько модель реально думала

        is_error = reply.startswith("[ERR")   # ошибка API — показать в пузыре, но не озвучивать
        # Битую реплику ([ERR 429/пусто/таймаут]) НЕ пускаем в память и в «недавние реплики»:
        # иначе она уедет в промпт списком «не повторяй эти реплики» и навсегда осядет в
        # memory.json. Показываем её только пузырём (ниже), учёт памяти — лишь для удачных.
        if not is_error:
            self.recent_replies.append(reply)
            self.recent_replies = self.recent_replies[-C.RECENT_REPLIES:]

            self.memory["conversation"].append(
                {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "event": block,
                 "reply": reply, "lat": round(latency, 2)})
            self.memory["conversation"] = self.memory["conversation"][-200:]
            self.memory["state"] = {"last_pal": self.state.last_pal, "money": self.state.money,
                                    "level": self.state.level}
            B.save_memory(self.memory)

        self.replied.emit(block, reply, latency)
        if manual and not is_error:
            B.append_chat_log(block, reply)   # ручной разговор → в chat.log для летописца
        # Защита от гонки: если СЕЙЧАС звучит важное (личный ответ игроку / разбор скриншота),
        # событие НЕ забивает его своей озвучкой — иначе поколение речи в voice.py молча
        # оборвёт активную речь. Реплика показана в пузыре, но голосом её не даём, и состояние
        # не трогаем (им владеет защищённая речь — её spoke сам освободит буфер).
        gui = self.gui
        protected = gui is not None and gui._speaking_manual and not manual
        if self.voice_on and not is_error and not protected:
            V.speak(reply, on_timed=self.spoke.emit)
        elif protected:
            pass                   # уступаем канал важной речи, буфер держит её spoke
        else:
            self.spoke.emit(0.0)   # голос выключен или ошибка — буфер освобождаем сразу

    @Slot()
    def idle_filler(self):
        try:
            self._idle_filler()
        except Exception:
            import traceback; traceback.print_exc()   # не роняем мозг-поток из-за заполнителя

    def _idle_filler(self):
        """Затишье в игре — вбрасываем живую реплику сами (повод из пула, опора на карту/историю)."""
        t0 = time.monotonic()
        reply = B.ask_idle(self.state.summary(), self.state.history(),
                           self.game_map, self.recent_replies)
        latency = time.monotonic() - t0
        if not reply:
            return
        self.recent_replies.append(reply)
        self.recent_replies = self.recent_replies[-C.RECENT_REPLIES:]
        self.memory["conversation"].append(
            {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "",
             "reply": reply, "lat": round(latency, 2)})
        self.memory["conversation"] = self.memory["conversation"][-200:]
        B.save_memory(self.memory)
        self.idled.emit(reply, latency)
        gui = self.gui
        protected = gui is not None and gui._speaking_manual   # звучит важное — не лезем поверх
        if self.voice_on and not protected:
            V.speak(reply, on_timed=self.spoke.emit)
        elif protected:
            pass                   # уступаем канал, буфер держит важную речь
        else:
            self.spoke.emit(0.0)   # голос выключен — буфер освобождаем сразу

    @Slot()
    def wipe(self):
        """Очистить мир: сброс состояния сессии в памяти процесса (файлы чистит окно).
        Знания об игре (знания.md) и настройки НЕ трогаем — это не «мир», а насовсем."""
        self.state = B.WorldState()
        self.recent_replies = []
        self.game_map = ""
        self._last_high_prio = 0.0
        self._last_catch = 0.0
        self.memory["conversation"].clear()
        if isinstance(self.memory.get("state"), dict):
            self.memory["state"].clear()
        else:
            self.memory["state"] = {}
        B._CHAT_CACHE["mtime"] = 0.0      # чат стёрт — не отдавать старые слова из кэша
        B._CHAT_CACHE["lines"] = []
        B.save_memory(self.memory)        # перезаписать memory.json пустым

    @Slot(str)
    def note_scene(self, desc):
        """Разбор скриншота (F8) от vision-модели — кладём в память как контекст обстановки,
        чтоб Мия «помнила», что видела на экране, и цеплялась за это в реакциях. Идёт в
        мозг-потоке (очередью из GUI) — без гонок с обычными записями памяти."""
        if not desc:
            return
        self.recent_replies.append(desc)
        self.recent_replies = self.recent_replies[-C.RECENT_REPLIES:]
        self.memory["conversation"].append(
            {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "[скриншот]",
             "reply": desc, "lat": 0.0})
        self.memory["conversation"] = self.memory["conversation"][-200:]
        B.save_memory(self.memory)


# =========================================================== разбор скриншота в своём потоке
class VisionWorker(QObject):
    """Отдельная модель разбирает снимок экрана (F8) в СВОЁМ потоке — реактивную Мию не
    тормозит. Тяжёлое (сжатие картинки + запрос к Gemini) целиком тут; в GUI уходит
    только готовый текст разбора."""
    ready = Signal(str)   # готовый разбор -> в GUI (озвучка + пузырь + память)

    def __init__(self):
        super().__init__()
        self.game_map = B.load_chronicle()

    @Slot(str)
    def set_context(self, text):
        """Летописец освежил карту — держим её как фон для разбора снимка."""
        if text:
            self.game_map = text

    @Slot(str, str)
    def run(self, path, focus=""):
        try:
            desc = B.describe_screenshot(path, focus, "", self.game_map)
        except Exception:
            import traceback; traceback.print_exc(); desc = ""
        if desc:
            self.ready.emit(desc)


# =========================================================== летописец в своём потоке
class ChroniclerWorker(QObject):
    """Раз в N минут сжимает весь лог в короткую карту игры (game_map.md).
    Реактивную Мию не трогает — только освежает контекст. Gemini зовёт ТОЛЬКО когда
    лог реально вырос: не рос — карта та же, токены не жжём."""
    updated = Signal(str)

    def __init__(self):
        super().__init__()
        self._last_size = -1
        self.timer = None

    @Slot()
    def start_loop(self):
        self.timer = QTimer()
        self.timer.timeout.connect(self.run)
        self.timer.start(C.CHRONICLE_EVERY_MS)
        self.run()          # холодный старт: сразу строим карту из уже накопленного лога

    @Slot()
    def run(self):
        try:
            size = os.path.getsize(C.LOG_FILE)
        except OSError:
            return          # лога ещё нет (игра не запущена) — тихо ждём следующего тика
        if size == self._last_size:
            return          # лог не рос — карта не изменилась, Gemini не дёргаем
        self._last_size = size
        summary = B.build_chronicle()
        if summary:
            self.updated.emit(summary)


# =========================================================== пульсирующая эмблема
class PulseEmblem(QWidget):
    """Волны вокруг ядра — «режим активен», как у Ари.
    Следим → мятные кольца расходятся; пауза → тихое серое ядро без волн."""
    def __init__(self, parent=None, size=34):
        super().__init__(parent)
        self.setFixedSize(size, size)
        self.setStyleSheet("background: transparent; border: none;")
        self._color = QColor(C.ACCENT)
        self._active = False
        self._time = 0
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._animate)
        self._timer.setInterval(30)

    def set_active(self, on, hex_color=None):
        if hex_color:
            self._color = QColor(hex_color)
        self._active = on
        if on and not self._timer.isActive():
            self._time = 0
            self._timer.start()
        elif not on:
            self._timer.stop()
        self.update()

    def _animate(self):
        self._time += 1
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        c = self.width() / 2
        if self._active:                      # расходящиеся волны — только в активном режиме
            base = self.width() * 0.22
            grow = self.width() * 0.28
            for i in range(3):
                phase = (self._time + i * 20) % 60 / 60.0
                r = base + phase * grow
                col = QColor(self._color); col.setAlpha(int(180 * (1 - phase)))
                p.setPen(QPen(col, 2 - phase)); p.setBrush(Qt.NoBrush)
                p.drawEllipse(QPointF(c, c), r, r)
        core = self._color if self._active else QColor(C.MUTED)   # ядро — всегда
        p.setPen(Qt.NoPen); p.setBrush(QBrush(core))
        cr = self.width() * 0.16
        p.drawEllipse(QPointF(c, c), cr, cr)


# =========================================================== окно настроек ⚙
class SettingsDialog(QDialog):
    """Крутилки на лету: длина реплики, живость, тайминги, доп. к характеру.
    Меняет config (C.*) сразу — без перезапуска — и сохраняет в settings.json."""
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Настройки Мии")
        self.setMinimumWidth(440)
        self.setStyleSheet(f"""
            QDialog {{ background: {C.BG}; }}
            QLabel {{ color: {C.TEXT}; background: transparent; font-size: 13px; }}
            QSpinBox, QDoubleSpinBox, QPlainTextEdit, QComboBox {{
                background: {C.BG2}; color: {C.TEXT}; border: 1px solid #2c333d;
                border-radius: 6px; padding: 6px 8px; font-size: 14px;
            }}
            QSpinBox::up-button, QSpinBox::down-button,
            QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{
                width: 26px;
            }}
            QSpinBox:focus, QDoubleSpinBox:focus, QPlainTextEdit:focus, QComboBox:focus {{ border: 1px solid {C.ACCENT}; }}
            QComboBox::drop-down {{ border: none; width: 22px; }}
            QComboBox QAbstractItemView {{
                background: {C.BG2}; color: {C.TEXT}; border: 1px solid {C.ACCENT};
                selection-background-color: {C.BTN_BG}; selection-color: {C.ACCENT}; outline: none;
            }}
            QToolTip {{ background: {C.BG2}; color: {C.TEXT};
                        border: 1px solid {C.ACCENT}; border-radius: 6px; padding: 5px 8px; }}
            QPushButton#outline {{
                background: {C.BTN_BG}; color: {C.BTN_TEXT}; border: 1px solid {C.BTN_BORDER};
                border-radius: 6px; padding: 8px 18px; }}
            QPushButton#outline:hover {{ background: {C.BTN_HOVER}; border: 1px solid {C.BTN_HOVER_BORDER}; }}
            QPushButton#outline:pressed {{ background: {C.BTN_PRESS}; }}
            QPushButton#danger {{
                background: {C.BTN_ACT_BG}; color: {C.BTN_ACT_TEXT}; border: 1px solid {C.BTN_ACT_BORDER};
                border-radius: 6px; padding: 8px 18px; }}
            QPushButton#danger:hover {{ background: {C.BTN_ACT_HOVER}; }}
            QPushButton#danger:pressed {{ background: {C.BTN_ACT_BG}; }}
        """)
        lay = QVBoxLayout(self); lay.setContentsMargins(20, 18, 20, 18); lay.setSpacing(14)
        form = QFormLayout(); form.setSpacing(12); form.setLabelAlignment(Qt.AlignRight)

        self.model = QComboBox()
        for label, mid in getattr(C, "MODEL_CHOICES", [("Gemini 2.5 Flash", "gemini-2.5-flash")]):
            self.model.addItem(label, mid)
        cur = getattr(C, "MODEL", "gemini-2.5-flash")
        idx = self.model.findData(cur)
        if idx < 0:                       # текущей нет в списке — добавим как есть
            self.model.addItem(cur, cur); idx = self.model.count() - 1
        self.model.setCurrentIndex(idx)
        self.model.setToolTip("Модель Gemini для реакций. Новее → осмысленнее, Flash-Lite → быстрее и дешевле.")
        form.addRow("Модель:", self.model)

        self.words = QSpinBox(); self.words.setRange(5, 80)
        self.words.setValue(int(getattr(C, "REPLY_WORDS", 18)))
        self.words.setToolTip("Примерная длина реплики в словах. Меньше → короче и резче.")
        form.addRow("Длина реплики (слов):", self.words)

        self.temp = QDoubleSpinBox(); self.temp.setRange(0.0, 2.0); self.temp.setSingleStep(0.05)
        self.temp.setValue(float(getattr(C, "TEMPERATURE", 1.15)))
        self.temp.setToolTip("Живость: 0.3 — сухо и предсказуемо, ~1.5 — дерзко и непредсказуемо.")
        form.addRow("Живость (температура):", self.temp)

        self.stale = QSpinBox(); self.stale.setRange(2, 30)
        self.stale.setValue(int(getattr(C, "STALE_SEC", 6)))
        self.stale.setToolTip("Событие старше стольких секунд не комментируем — чтоб не говорить о прошлом.")
        form.addRow("Протухание события (сек):", self.stale)

        self.cool = QSpinBox(); self.cool.setRange(0, 120)
        self.cool.setValue(int(getattr(C, "CHATTER_COOLDOWN_SEC", 25)))
        self.cool.setToolTip("Мелкий спам (подбор с пола и т.п.) — не чаще раза в N секунд.")
        form.addRow("Пауза для мелочи (сек):", self.cool)

        self.recent = QSpinBox(); self.recent.setRange(3, 300)
        self.recent.setValue(int(getattr(C, "RECENT_EVENTS", 10)))
        self.recent.setToolTip("Сколько последних событий держать в контексте (память сюжета).")
        form.addRow("Помнить событий:", self.recent)

        self.idle = QDoubleSpinBox(); self.idle.setRange(0.5, 15.0); self.idle.setSingleStep(0.5)
        self.idle.setSuffix(" мин")
        self.idle.setValue(round(int(getattr(C, "IDLE_MIN_SEC", 90)) / 60.0, 1))
        self.idle.setToolTip("Тишина в игре дольше этого — Мия сама вбрасывает реплику.\n"
                             "Точный порог берётся со случайным разбросом (до +40%), чтоб не по будильнику.")
        form.addRow("Пауза тишины:", self.idle)
        lay.addLayout(form)

        from PySide6.QtWidgets import QCheckBox
        self.buf_check = QCheckBox("Буфер событий (без перебивок)")
        self.buf_check.setStyleSheet(f"color: {C.TEXT}; font-size: 13px;")
        self.buf_check.setChecked(bool(getattr(C, "EVENT_BUFFER", True)))
        self.buf_check.setToolTip(
            "Включён — события копятся пока Мия говорит, выходят одним пакетом (без самоперебивок).\n"
            "Выключен — старый режим: каждое событие перебивает предыдущее немедленно."
        )
        lay.addWidget(self.buf_check)

        lbl = QLabel("Доп. к характеру (тон, стиль) — пиши свободно:")
        lay.addWidget(lbl)
        self.extra = QPlainTextEdit(); self.extra.setFixedHeight(80)
        self.extra.setPlainText(getattr(C, "EXTRA_PROMPT", ""))
        self.extra.setPlaceholderText("напр.: будь язвительнее / поменьше мата / говори как спортивный комментатор")
        lay.addWidget(self.extra)

        btns = QHBoxLayout(); btns.addStretch()
        cancel = QPushButton("Отмена"); cancel.setObjectName("outline")
        cancel.setCursor(Qt.PointingHandCursor); cancel.clicked.connect(self.reject)
        apply_ = QPushButton("Применить"); apply_.setObjectName("outline")
        apply_.setCursor(Qt.PointingHandCursor); apply_.clicked.connect(self.accept)
        btns.addWidget(cancel); btns.addWidget(apply_)
        lay.addLayout(btns)

        # --- чистый лист: стереть память сессии/карту/чат, знания и настройки не трогаем ---
        sep = QFrame(); sep.setFrameShape(QFrame.HLine)
        sep.setStyleSheet("background:#2c333d; max-height:1px; border:none;")
        lay.addWidget(sep)
        wipe_row = QHBoxLayout()
        wlbl = QLabel("Начать с чистого листа (знания об игре останутся):")
        wlbl.setStyleSheet(f"color:{C.MUTED};font-size:12px;")
        wlbl.setWordWrap(True)
        wipe = QPushButton("Очистить мир"); wipe.setObjectName("danger")
        wipe.setCursor(Qt.PointingHandCursor); wipe.clicked.connect(self._confirm_wipe)
        wipe_row.addWidget(wlbl, 1); wipe_row.addWidget(wipe)
        lay.addLayout(wipe_row)

    def _confirm_wipe(self):
        """Спросить и, если да, попросить окно очистить мир. Настройки при этом не применяем."""
        from PySide6.QtWidgets import QMessageBox
        box = QMessageBox(self)
        box.setWindowTitle("Очистить мир?")
        box.setIcon(QMessageBox.Warning)
        box.setText("Начать с чистого листа?")
        box.setInformativeText(
            "Сотру память этой сессии, карту игры и историю ручного чата, обнулю лог "
            "событий игры. Знания об игре и настройки останутся.\n\nЭто не откатить.")
        box.setStandardButtons(QMessageBox.Yes | QMessageBox.Cancel)
        box.setDefaultButton(QMessageBox.Cancel)
        box.button(QMessageBox.Yes).setText("Очистить")
        box.button(QMessageBox.Cancel).setText("Отмена")
        box.setStyleSheet(
            f"QMessageBox{{background:{C.BG};}} QLabel{{color:{C.TEXT};background:transparent;}} "
            f"QPushButton{{background:{C.BTN_BG};color:{C.BTN_TEXT};border:1px solid {C.BTN_BORDER};"
            f"border-radius:6px;padding:6px 16px;}} "
            f"QPushButton:hover{{background:{C.BTN_HOVER};}}")
        if box.exec() == QMessageBox.Yes:
            parent = self.parent()
            if parent is not None and hasattr(parent, "_wipe_world"):
                parent._wipe_world()
            self.reject()      # закрыть настройки без применения крутилок — мир уже очищен

    def values(self):
        return {
            "MODEL": self.model.currentData(),
            "REPLY_WORDS": self.words.value(),
            "TEMPERATURE": round(self.temp.value(), 2),
            "STALE_SEC": self.stale.value(),
            "CHATTER_COOLDOWN_SEC": self.cool.value(),
            "RECENT_EVENTS": self.recent.value(),
            "IDLE_MIN_SEC": int(self.idle.value() * 60),
            "IDLE_MAX_SEC": int(self.idle.value() * 60 * 1.4),
            "EXTRA_PROMPT": self.extra.toPlainText().strip(),
            "EVENT_BUFFER": self.buf_check.isChecked(),
        }


# =========================================================== поле ввода с микрофоном внутри
# Типичные фразы-фантомы, которые whisper выдумывает на тишине/шуме (титры из обучающих данных).
_PHANTOMS = ("субтитр", "корректор", "редактор субтитров", "продолжение следует",
             "спасибо за просмотр", "amara.org", "dimatorzok", "субтитры создавал",
             "субтитры делал", "продолжение в следующей серии", "до новых встреч")

def _strip_phantoms(text):
    """Если распознанное — целиком типичный галлюцинаторный титр whisper, гасим его."""
    low = text.lower()
    if any(bad in low for bad in _PHANTOMS):
        for bad in _PHANTOMS:
            low = low.replace(bad, "")
        if len(low.strip(" .,-—")) < 8:     # кроме фантома почти ничего не осталось → мусор
            return ""
    return text


def _mic_icon(color):
    """Рисуем иконку микрофона сами (эмодзи 🎤 не всегда есть в системном шрифте — «не пишется»)."""
    pm = QPixmap(44, 44); pm.fill(Qt.transparent)
    p = QPainter(pm); p.setRenderHint(QPainter.RenderHint.Antialiasing)
    col = QColor(color)
    p.setPen(QPen(col, 3, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
    p.setBrush(QBrush(col))
    p.drawRoundedRect(16, 8, 12, 19, 6, 6)          # капсула микрофона
    p.setBrush(Qt.NoBrush)
    p.drawArc(11, 12, 22, 22, 200 * 16, 140 * 16)   # дуга-держатель
    p.drawLine(22, 32, 22, 36)                        # ножка
    p.drawLine(16, 36, 28, 36)                        # подставка
    p.end()
    return QIcon(pm)


class MicLineEdit(QLineEdit):
    """Поле ввода со встроенной кнопкой-микрофоном (справа, внутри поля). Рация: держи и говори."""
    def __init__(self, on_press, on_release, parent=None):
        super().__init__(parent)
        self.mic = QPushButton(self)
        self.mic.setCursor(Qt.PointingHandCursor)
        self.mic.setFixedSize(30, 30)
        self.mic.setIcon(_mic_icon(C.MUTED)); self.mic.setIconSize(QSize(22, 22))
        self.mic.setStyleSheet("QPushButton{border:none;background:transparent;}")
        self.mic.setToolTip("Рация: держи и говори, отпусти — текст встанет в поле (Enter отправит)")
        self.mic.pressed.connect(on_press)
        self.mic.released.connect(on_release)
        self.setTextMargins(0, 0, 34, 0)             # освобождаем текст из-под кнопки
    def resizeEvent(self, e):
        super().resizeEvent(e)
        self.mic.move(self.width() - self.mic.width() - 5,
                      (self.height() - self.mic.height()) // 2)
    def set_recording(self, on):
        self.mic.setIcon(_mic_icon(C.ACCENT if on else C.MUTED))


# =========================================================== окно
class Assistant(QMainWindow):
    to_brain  = Signal(list, float, bool)   # (строки, отметка времени, ручная отправка?)
    to_idle   = Signal()
    mic_text  = Signal(str)   # распознанный текст -> поле ввода (из потока записи в GUI)
    mic_status = Signal(str)  # статус диктовки (говори/распознаю/ошибка)
    shot_taken = Signal(str)  # сделан скриншот -> путь (или "" при ошибке), в GUI-поток
    to_vision  = Signal(str, str)  # (путь снимка, фокус-указание игрока) -> vision-поток
    to_note    = Signal(str)  # разбор снимка -> мозг-поток на запись в память
    to_wipe    = Signal()     # «Очистить мир» -> мозг-поток сбрасывает состояние сессии

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Мия · игровой ассистент  (Palworld)")
        self.resize(560, 720)
        self.setWindowFlag(Qt.WindowStaysOnTopHint, True)   # всегда поверх игры

        self.memory = B.load_memory()
        self._pos = 0
        self._buf = ""
        self._merge_buf = []     # окно склейки связанных событий (левелап + очки)
        self._watching = False
        self._quitting = False
        self._bubbles = []       # пузыри mia/event — ширину тянем за окном

        self._chron_shown = False

        # двойной буфер: пока голос говорит, события копятся и уходят одним пакетом.
        # Инициализируем ДО _start_brain/таймеров: мозг-поток (BrainWorker._handle) и _tick
        # читают эти флаги, и корректность не должна держаться лишь на том, что Qt-таймеры
        # молчат до app.exec() — любая перестановка запуска иначе дала бы AttributeError.
        self._speaking = False         # True — озвучка идёт прямо сейчас
        self._speaking_manual = False  # True — сейчас говорит ЛИЧНЫЙ ответ игроку (чат/микро/поле)
        self._speaking_since = 0.0     # когда встал флаг занятости — для сторожа от залипания
        self._pending  = []            # события, накопленные пока говорила
        self._pending_vision = []      # разборы скриншотов (F8), ждущие очереди — не теряются
        self._vision_focus = ""        # последнее указание игрока (чат/поле/микро) — фокус для F8
        self._vision_focus_at = 0.0    # когда оно прозвучало (свежесть ограничена VISION_FOCUS_SEC)

        self._build_ui()
        self._build_tray()
        self._start_brain()
        self._start_chronicler()
        self._start_vision()
        self._restore_history()

        self.poll = QTimer(self)
        self.poll.timeout.connect(self._tick)
        self.poll.start(C.POLL_MS)

        # заполнение тишины: если в игре давно ничего не происходит — Мия сама заговорит.
        # _last_activity сбрасывается на любом реальном событии; порог — случайный (разброс).
        self._last_activity = time.monotonic()
        self._pick_idle_target()
        self.idle_timer = QTimer(self)
        self.idle_timer.timeout.connect(self._idle_check)
        self.idle_timer.start(getattr(C, "IDLE_CHECK_MS", 5000))

        # слежка сразу при старте (после моих перезапусков не остаётся на «Паузе»)
        if getattr(C, "WATCH_ON_START", False):
            self._toggle_watch()

        # сторож от немоты: раз в 5с проверяет, не завис ли _speaking навсегда
        self.speak_watchdog = QTimer(self)
        self.speak_watchdog.timeout.connect(self._speaking_watchdog)
        self.speak_watchdog.start(5000)

        # микрофон-рация: диктовка -> whisper (offline) -> поле ввода
        self._recording = False
        self._audio = []
        self._whisper = {}
        self.mic_text.connect(self._put_voice_text)
        self.mic_status.connect(lambda s: self._set_status(s, C.ACCENT))
        threading.Thread(target=self._load_whisper, daemon=True).start()

        # глобальная горячая клавиша скриншота (работает поверх игры, не как Qt-шорткат)
        self.shot_taken.connect(self._on_shot)
        self._start_hotkey()

    # ---------------------------------------------------------- интерфейс
    def _build_ui(self):
        self.setStyleSheet(f"""
            QMainWindow, QWidget {{ background: {C.BG}; }}
            QLabel {{ color: {C.TEXT}; background: transparent; }}
            QToolTip {{
                background: {C.BG2}; color: {C.TEXT};
                border: 1px solid {C.ACCENT}; border-radius: 6px; padding: 5px 8px;
            }}
            QLineEdit {{
                background: {C.BG2}; color: {C.TEXT}; border: 1px solid #2c333d;
                border-radius: 6px; padding: 10px 12px; font-size: 14px;
            }}
            QLineEdit:focus {{ border: 1px solid {C.ACCENT}; }}
            /* зелёный пузырь Ari_Vision: рамка тёмно-зелёная, шрифт бледно-зелёный,
               фон тёмно-зелёный — три разных цвета, ни капли мятного.
               Только #outline: «Пауза/Игра» и «Отправить». */
            QPushButton#outline {{
                background: {C.BTN_BG}; color: {C.BTN_TEXT}; border: 1px solid {C.BTN_BORDER};
                border-radius: 6px; padding: 0px 16px;
            }}
            QPushButton#outline:hover {{ background: {C.BTN_HOVER}; border: 1px solid {C.BTN_HOVER_BORDER}; }}
            QPushButton#outline:pressed {{ background: {C.BTN_PRESS}; }}
            /* активная «Игра» — красный стиль «Активировать Ari»: бордовый фон, розовая рамка */
            QPushButton#outline_active {{
                background: {C.BTN_ACT_BG}; color: {C.BTN_ACT_TEXT}; border: 1px solid {C.BTN_ACT_BORDER};
                border-radius: 6px; padding: 0px 16px;
            }}
            QPushButton#outline_active:hover {{ background: {C.BTN_ACT_HOVER}; border: 1px solid {C.BTN_ACT_BORDER}; }}
            QPushButton#outline_active:pressed {{ background: {C.BTN_ACT_BG}; }}
            /* динамик — не пузырь: без рамки и заливки, только цветная иконка */
            QPushButton#icon {{
                background: transparent; border: none; padding: 4px;
            }}
            QPushButton#icon:hover {{ background: transparent; }}
            QPushButton#icon:pressed {{ background: transparent; }}
            QScrollArea {{ border: none; }}
        """)

        root = QWidget(); self.setCentralWidget(root)
        lay = QVBoxLayout(root); lay.setContentsMargins(0, 0, 0, 0); lay.setSpacing(0)

        # шапка
        head = QWidget(); head.setObjectName("head")
        head.setStyleSheet(f"QWidget#head {{ background:{C.BG2}; }}")
        head.setFixedHeight(58)                    # фикс высоты — эмблема не растягивает шапку
        hl = QHBoxLayout(head); hl.setContentsMargins(16, 3, 16, 3); hl.setSpacing(10)
        self.emblem = PulseEmblem(head, size=51)   # живой индикатор «слежу» — волны как у Ари
        title = QLabel("Мия"); title.setStyleSheet(f"color:{C.ACCENT};font-size:18px;")
        self.status = QLabel(); self.status.setMinimumWidth(72)
        self.status.setStyleSheet(f"color:{C.MUTED};font-size:13px;")
        self.model_lbl = QLabel(f"·  {C.MODEL}"); self.model_lbl.setStyleSheet(f"color:{C.MUTED};font-size:12px;")
        hl.addWidget(self.emblem); hl.addWidget(title); hl.addWidget(self.status)
        hl.addWidget(self.model_lbl); hl.addStretch()
        # настройки — шестерёнка (длина реплик, живость, тайминги, тон — крутить на лету)
        self.cfg_btn = QPushButton("⚙")
        self.cfg_btn.setObjectName("icon")
        self.cfg_btn.setFixedSize(34, 34)
        self.cfg_btn.setStyleSheet(f"font-size:18px;color:{C.BTN_TEXT};")
        self.cfg_btn.setCursor(Qt.PointingHandCursor)
        self.cfg_btn.setToolTip("Настройки: длина реплик, живость, тайминги, тон")
        self.cfg_btn.clicked.connect(self._open_settings)
        hl.addWidget(self.cfg_btn)
        # переключатель движка озвучки: 11L (ElevenLabs) ⇄ Gem (Gemini TTS) — сравнить скорость
        self.engine_btn = QPushButton()
        self.engine_btn.setObjectName("outline")
        self.engine_btn.setFixedSize(60, 30)       # шире (надпись влезает) + ниже
        self.engine_btn.setCursor(Qt.PointingHandCursor)
        self.engine_btn.clicked.connect(self._toggle_engine)
        self._refresh_engine_btn()
        hl.addWidget(self.engine_btn)
        # голос — иконка динамика (вкл/перечёркнут), по умолчанию вкл
        self.voice_btn = QPushButton()
        self.voice_btn.setObjectName("icon")
        self.voice_btn.setFixedSize(40, 36)
        self.voice_btn.setIconSize(QSize(20, 20))
        self.voice_btn.setCursor(Qt.PointingHandCursor)
        self.voice_btn.clicked.connect(self._toggle_voice)
        self._refresh_voice_btn()
        hl.addWidget(self.voice_btn)
        # режим характера: Дерзкая (дома) ⇄ Свой (компаньон за игрока, для чужого сервера)
        self.mode_btn = QPushButton()
        self.mode_btn.setObjectName("outline")
        self.mode_btn.setFixedSize(84, 30)
        self.mode_btn.setCursor(Qt.PointingHandCursor)
        self.mode_btn.clicked.connect(self._toggle_mode)
        self._refresh_mode_btn()
        hl.addWidget(self.mode_btn)
        self.watch_btn = QPushButton("Пауза")      # не слежу → «Пауза», слежу → «Игра»
        self.watch_btn.setObjectName("outline")    # обведённая кнопочка (мятная рамка)
        self.watch_btn.setFixedSize(84, 30)        # фикс ширины (не прыгает) + ниже по высоте
        self.watch_btn.setCursor(Qt.PointingHandCursor)
        self.watch_btn.clicked.connect(self._toggle_watch)
        hl.addWidget(self.watch_btn)
        lay.addWidget(head)

        # лента
        self.scroll = QScrollArea(); self.scroll.setWidgetResizable(True)
        self.feed = QWidget(); self.feed.setStyleSheet(f"background:{C.BG};")
        self.feed_lay = QVBoxLayout(self.feed)
        self.feed_lay.setContentsMargins(14, 14, 14, 14); self.feed_lay.setSpacing(10)
        self.feed_lay.addStretch()
        self.scroll.setWidget(self.feed)
        lay.addWidget(self.scroll, 1)

        # ввод (тестовое событие или сообщение Мии)
        bottom = QWidget(); bl = QHBoxLayout(bottom); bl.setContentsMargins(14, 10, 14, 14)
        # поле ввода с микрофоном-рацией ВНУТРИ (иконка справа, не эмодзи)
        self.inp = MicLineEdit(self.start_mic, self.stop_mic)
        self.inp.setPlaceholderText("тестовое событие (напр. «ПОЙМАН ПАЛ: Гумосс») — Enter")
        self.inp.returnPressed.connect(self._send_manual)
        send = QPushButton("Отправить"); send.setObjectName("outline"); send.setCursor(Qt.PointingHandCursor)
        send.setFixedHeight(42)            # без верт. padding кнопка бы схлопнулась — задаём высоту явно
        send.clicked.connect(self._send_manual)
        bl.addWidget(self.inp, 1); bl.addWidget(send)
        lay.addWidget(bottom)

        self._set_status("○ не слежу", C.MUTED)

        self._add_system("Привет! Я тут. Нажми «Пауза» (станет «Игра») — и я начну "
                         "комментировать всё, что в ней происходит. Или кинь тестовое "
                         "событие в поле снизу, чтоб проверить меня без игры.")

    # ---------------------------------------------------------- пузыри
    def _bubble(self, text, kind, latency=None):
        """kind: 'mia' | 'event' | 'system'. latency — сек, мелким бледным в конец пузыря Мии."""
        row = QHBoxLayout()
        lbl = QLabel(text); lbl.setWordWrap(True)
        lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
        if kind == "mia":
            import html
            lbl.setTextFormat(Qt.RichText)
            lbl._safe = html.escape(text).replace("\n", "<br>")   # чистый текст реплики
            lbl._lat  = latency    # время мозга (Gemini)
            lbl._tts  = None       # время озвучки — дорисуется, когда голос отработает
            self._render_mia(lbl)
            self._last_mia = lbl   # к нему привяжем время озвучки
            lbl.setStyleSheet(f"background:{C.BUBBLE};color:{C.TEXT};border-radius:6px;"
                              f"padding:11px 14px;font-size:14px;")
            lbl.setFixedWidth(self._bubble_w())
            self._bubbles.append(lbl)
            row.addWidget(lbl); row.addStretch()
        elif kind == "event":
            lbl.setStyleSheet(f"color:{C.MUTED};font-size:12px;padding:8px 12px;"
                              f"background:{C.BUBBLE_FILL};border:1px solid {C.BUBBLE_LINE};"
                              f"border-radius:6px;")
            lbl.setFixedWidth(self._bubble_w())
            self._bubbles.append(lbl)
            row.addStretch(); row.addWidget(lbl)
        else:  # system
            lbl.setStyleSheet(f"color:{C.MUTED};font-size:13px;font-style:italic;padding:8px 12px;"
                              f"background:{C.BUBBLE_FILL};border:1px solid {C.BUBBLE_LINE};"
                              f"border-radius:6px;")
            row.addWidget(lbl); row.addStretch()
        holder = QWidget(); holder.setLayout(row)
        self.feed_lay.insertWidget(self.feed_lay.count() - 1, holder)
        QTimer.singleShot(30, lambda: self.scroll.verticalScrollBar().setValue(
            self.scroll.verticalScrollBar().maximum()))

    def _render_mia(self, lbl):
        """Дорисовать хвост пузыря Мии: время мозга и (если есть) время озвучки — мелким бледным."""
        meta = ""
        if getattr(lbl, "_lat", None) is not None:
            meta += f"&nbsp;&nbsp;{lbl._lat:.1f} с"
        if getattr(lbl, "_tts", None) is not None:
            meta += f"&nbsp;·&nbsp;🔊 {lbl._tts:.1f} с"
        tail = (f"<span style='color:{C.MUTED};font-size:11px;'>{meta}</span>") if meta else ""
        lbl.setText(lbl._safe + tail)

    def _on_spoke(self, sec):
        """Голос отработал — дописываем время озвучки и сбрасываем накопленный буфер."""
        lbl = getattr(self, "_last_mia", None)
        if lbl is not None:
            lbl._tts = sec
            self._render_mia(lbl)
        self._speaking = False
        self._speaking_manual = False   # личный ответ договорён — защита снята, буфер выпускаем
        self._flush_pending()

    @Slot()
    def _on_released(self):
        """Мозг отбросил пачку (протухла/фильтр/тихая зона) и говорить не будет — снимаем
        флаг занятости и выпускаем накопленное. Без этого буфер завис бы навсегда — Мия немела."""
        self._speaking = False
        self._speaking_manual = False
        self._flush_pending()

    def _flush_pending(self):
        """Голос освободился — выпускаем накопленное. Приоритет: сперва отложенный разбор
        скриншота (F8 — сознательная просьба, важнее событий), потом уже игровые события."""
        if self._pending_vision:
            self._speak_vision(self._pending_vision.pop(0))
            return
        if not self._pending:
            return
        lines = self._pending[:]
        self._pending.clear()
        self._speaking = True
        self._speaking_manual = False   # это накопленные ИГРОВЫЕ события, не личный ответ
        self._speaking_since = time.monotonic()
        self.to_brain.emit(lines, time.monotonic(), False)

    def _speaking_watchdog(self):
        """Страховка от немоты: если _speaking застрял True дольше порога (потеряли spoke,
        мозг завис на сети и т.п.) — принудительно освобождаем буфер, чтоб Мия не онемела.
        Личный ответ (поиск в сети + длинная речь) живёт дольше — ему даём больший запас,
        чтоб сторож не оборвал его на полуслове и не пустил поверх событие."""
        limit = 120 if self._speaking_manual else 25
        if self._speaking and self._speaking_since and \
           time.monotonic() - self._speaking_since > limit:
            self._speaking = False
            self._speaking_manual = False
            self._flush_pending()

    def _bubble_w(self):
        return max(260, int(self.width() * 0.74))   # широкие пузыри, тянутся за окном

    def resizeEvent(self, e):
        super().resizeEvent(e)
        w = self._bubble_w()
        for lbl in self._bubbles:
            lbl.setFixedWidth(w)

    def _add_system(self, t): self._bubble(t, "system")

    def _set_status(self, text, color):
        self._status_text = text
        self.status.setText(text.lstrip("●○ ").strip())   # ●/○ теперь рисует эмблема
        self.status.setStyleSheet(f"color:{color};font-size:13px;")
        if "не слежу" in text:
            self.emblem.set_active(False)
        elif "жду" in text:
            self.emblem.set_active(True, "#e0b04a")
        else:
            self.emblem.set_active(True, C.ACCENT)

    # ---------------------------------------------------------- трей
    def _make_icon(self):
        pm = QPixmap(32, 32); pm.fill(Qt.transparent)
        p = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
        p.setBrush(QBrush(QColor(C.ACCENT))); p.setPen(Qt.NoPen)
        p.drawEllipse(2, 2, 28, 28)
        p.setPen(QColor("#0c1116")); f = QFont("Segoe UI", 14, QFont.Bold); p.setFont(f)
        p.drawText(pm.rect(), Qt.AlignCenter, "М")
        p.end()
        return QIcon(pm)

    def _build_tray(self):
        self.tray = QSystemTrayIcon(self._make_icon(), self)
        self.tray.setToolTip("Мия · игровой ассистент")
        menu = QMenu()
        act_show = QAction("Показать", self); act_show.triggered.connect(self._show_from_tray)
        act_quit = QAction("Выход", self); act_quit.triggered.connect(self._real_quit)
        menu.addAction(act_show); menu.addSeparator(); menu.addAction(act_quit)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._tray_click)
        self.tray.show()

    def _tray_click(self, reason):
        if reason == QSystemTrayIcon.Trigger:      # левый клик по иконке
            self._show_from_tray()

    def _hide_to_tray(self):
        self.hide()
        self.tray.showMessage("Мия свернулась", "Я в трее — кликни иконку, чтоб вернуть.",
                              self._make_icon(), 2000)

    def _show_from_tray(self):
        self.showNormal(); self.raise_(); self.activateWindow()

    def _real_quit(self):
        self._quitting = True
        self.close()
        QApplication.instance().quit()   # quitOnLastWindowClosed=False — иначе процесс завис бы без окна (зомби)

    @Slot()
    def _on_takeover_request(self):
        """Стартует новый экземпляр и просит нас уйти — уступаем, чтоб не было двух голосов."""
        conn = self._instance_server.nextPendingConnection()
        if conn is not None:
            conn.close()
        V.stop()                         # мгновенно глушим голос, дальше говорит новый
        self._real_quit()

    # ------------------------------------------------ настройки ⚙
    def _open_settings(self):
        dlg = SettingsDialog(self)
        if dlg.exec() != QDialog.Accepted:
            return
        for k, v in dlg.values().items():
            setattr(C, k, v)          # применяется на лету — worker читает C.* из своего потока
        B.save_settings()             # переживёт перезапуск
        self._pick_idle_target()      # новая пауза тишины — сразу в силу, не ждём события
        self.model_lbl.setText(f"·  {C.MODEL}")   # надпись в шапке — сразу показать выбранную модель
        self._add_system(f"— настройки применены: модель {C.MODEL}, реплика ~{C.REPLY_WORDS} слов, "
                         f"живость {C.TEMPERATURE} —")

    # ------------------------------------------------ очистить мир (чистый лист)
    def _wipe_world(self):
        """Начать с чистого листа: стереть память сессии, карту игры и ручной чат,
        обнулить лог событий игры (если его не держит запущенная игра). Знания об игре
        (знания.md) и настройки остаются. Зовётся из ⚙ после подтверждения."""
        V.stop()                        # заткнуть голос
        self._speaking = False
        self._speaking_manual = False
        self._pending.clear()
        self._pending_vision.clear()
        self._buf = ""
        self._merge_buf = []

        # состояние сессии в памяти процесса + перезапись пустого memory.json — в мозг-потоке
        self.to_wipe.emit()

        # файлы мира: карта и ручной чат — удаляем (пересоздадутся сами)
        for path in (C.CHRONICLE_FILE, C.CHAT_LOG_FILE):
            try:
                if os.path.exists(path):
                    os.remove(path)
            except Exception:
                pass

        # лог событий: обнуляем, если файл свободен; держит игра — просто читаем с конца
        ev_cleared = False
        try:
            if os.path.exists(C.LOG_FILE):
                with open(C.LOG_FILE, "r+", encoding="utf-8") as f:
                    f.truncate(0)
                ev_cleared = True
        except Exception:
            ev_cleared = False
        try:
            cur = 0 if ev_cleared else (os.path.getsize(C.LOG_FILE)
                                        if os.path.exists(C.LOG_FILE) else 0)
        except Exception:
            cur = 0
        self._pos = cur                          # реактивная Мия — только новое
        if hasattr(self, "chron_worker"):
            self.chron_worker._last_size = cur   # летописец пересоберёт карту, лишь когда лог вырастет

        # чистим ленту на экране и стартуем отсчёт тишины заново
        self._clear_feed()
        self._chron_shown = False
        self._bump_activity()
        note = "— мир очищен: память сессии, карта игры и ручной чат сброшены"
        note += (", лог событий обнулён —" if ev_cleared
                 else " (лог держит игра — читаю его с текущего момента) —")
        self._add_system(note)

    def _clear_feed(self):
        """Убрать все пузыри из ленты (растяжка в конце остаётся) — чистый лист на экране."""
        while self.feed_lay.count() > 1:     # последний элемент — addStretch()
            item = self.feed_lay.takeAt(0)
            w = item.widget()
            if w is not None:
                w.setParent(None)
                w.deleteLater()
        self._bubbles.clear()
        self._last_mia = None

    # ------------------------------------------------ режим характера (Дерзкая ⇄ Свой)
    def _toggle_mode(self):
        C.COMPANION_MODE = not getattr(C, "COMPANION_MODE", False)
        B.save_settings()                 # переживёт перезапуск
        self._refresh_mode_btn()          # _system_prompt() читает C.COMPANION_MODE на лету
        if C.COMPANION_MODE:
            self._add_system("— режим «Свой»: полностью за тебя, без вредности и подъёбов "
                             "(для чужого сервера — к чужим доброжелательна) —")
        else:
            self._add_system("— режим «Кайф»: расслабон, без спешки и бухтежа, мат "
                             "свободнее (соло-игра дома) —")

    def _refresh_mode_btn(self):
        comp = getattr(C, "COMPANION_MODE", False)
        self.mode_btn.setText("Свой" if comp else "Кайф")
        self.mode_btn.setToolTip(
            "Характер: компаньон, полностью за тебя, без вредности (чужой сервер) — клик → Кайф" if comp
            else "Характер: расслабон, не гонит и не бухтит, мат свободнее (соло дома) — клик → компаньон за тебя")

    # ------------------------------------------------ движок озвучки (11L ⇄ Gem)
    def _toggle_engine(self):
        C.TTS_ENGINE = "gemini" if getattr(C, "TTS_ENGINE", "eleven") == "eleven" else "eleven"
        self._refresh_engine_btn()
        B.save_settings()             # выбор движка переживёт перезапуск

    def _refresh_engine_btn(self):
        gem = getattr(C, "TTS_ENGINE", "eleven") == "gemini"
        self.engine_btn.setText("Gem" if gem else "11L")
        self.engine_btn.setToolTip(
            "Озвучка: Gemini TTS (свой ключ, дешевле) — клик → ElevenLabs" if gem
            else "Озвучка: ElevenLabs (быстрый, платный) — клик → Gemini TTS")

    # ---------------------------------------------------------- голос
    def _toggle_voice(self):
        # до старта мозг-потока храним состояние в C.VOICE_ON, потом в worker
        if hasattr(self, "worker"):
            self.worker.voice_on = not self.worker.voice_on
            on = self.worker.voice_on
        else:
            on = not self._voice_on_ui
        self._voice_on_ui = on
        self._refresh_voice_btn()
        if not on:
            V.stop()

    def _refresh_voice_btn(self):
        on = getattr(self, "_voice_on_ui", C.VOICE_ON)
        self._voice_on_ui = on
        self.voice_btn.setIcon(self._speaker_icon(on))
        self.voice_btn.setToolTip("Голос включён — клик, чтобы выключить" if on
                                  else "Голос выключен — клик, чтобы включить")

    def _speaker_icon(self, on):
        """Монохромная иконка динамика: on — с волнами, off — перечёркнут."""
        pm = QPixmap(40, 40); pm.fill(Qt.transparent)
        p = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
        col = QColor(C.BTN_TEXT if on else C.MUTED)
        p.setBrush(QBrush(col)); p.setPen(Qt.NoPen)
        # корпус динамика (прямоугольник + рупор-трапеция)
        body = QPolygonF([QPointF(8, 15), QPointF(15, 15), QPointF(22, 8),
                          QPointF(22, 32), QPointF(15, 25), QPointF(8, 25)])
        p.drawPolygon(body)
        pen = QPen(col); pen.setWidth(2); pen.setCapStyle(Qt.RoundCap)
        p.setPen(pen); p.setBrush(Qt.NoBrush)
        if on:                               # звуковые волны
            p.drawArc(20, 12, 10, 16, -60 * 16, 120 * 16)
            p.drawArc(20, 7,  18, 26, -55 * 16, 110 * 16)
        else:                                # перечёркнут
            slash = QPen(QColor("#d15a5a")); slash.setWidth(3); slash.setCapStyle(Qt.RoundCap)
            p.setPen(slash); p.drawLine(24, 11, 34, 29)
        p.end()
        return QIcon(pm)

    def _restore_history(self):
        conv = self.memory.get("conversation", [])
        if conv:
            self._add_system(f"— вспомнила прошлую сессию ({len(conv)} реплик) —")
        for e in conv[-12:]:
            if e.get("event"):
                self._bubble("⟶ " + e["event"].replace("\n", " · "), "event")
            if e.get("reply"):
                self._bubble(e["reply"], "mia", e.get("lat"))

    # ---------------------------------------------------------- мозг-поток
    def _start_brain(self):
        self.thread = QThread(self)
        self.worker = BrainWorker(self.memory)
        self.worker.gui = self   # чтобы мозг-поток не забивал озвучкой события живой важный ответ
        self.worker.moveToThread(self.thread)
        self.to_brain.connect(self.worker.handle)
        self.to_idle.connect(self.worker.idle_filler)
        self.to_note.connect(self.worker.note_scene)   # разбор снимка -> в память (мозг-поток)
        self.to_wipe.connect(self.worker.wipe)          # «Очистить мир» -> сброс состояния сессии
        self.worker.replied.connect(self._on_reply)
        self.worker.idled.connect(self._on_idle)
        self.worker.spoke.connect(self._on_spoke)
        self.worker.released.connect(self._on_released)
        self.thread.start()

    def _start_vision(self):
        """Отдельный поток разбора скриншотов — крутится параллельно мозгу, его не тормозит."""
        self.vis_thread = QThread(self)
        self.vis_worker = VisionWorker()
        self.vis_worker.moveToThread(self.vis_thread)
        self.to_vision.connect(self.vis_worker.run)     # F8 -> разбор снимка
        self.vis_worker.ready.connect(self._on_vision)  # готовый разбор -> озвучка + память
        # карта игры от летописца — фон для разбора снимка (летописец уже поднят)
        self.chron_worker.updated.connect(self.vis_worker.set_context)
        self.vis_thread.start()

    @Slot(str, str, float)
    def _on_reply(self, event_block, reply, latency):
        self._bubble("⟶ " + event_block.replace("\n", " · "), "event")
        self._bubble(reply, "mia", latency)

    @Slot(str, float)
    def _on_idle(self, reply, latency):
        # заполнитель тишины — только пузырь Мии, без строки-события
        self._bubble(reply, "mia", latency)

    # ---------------------------------------------------------- летописец-поток
    def _start_chronicler(self):
        self.chron_thread = QThread(self)
        self.chron_worker = ChroniclerWorker()
        self.chron_worker.moveToThread(self.chron_thread)
        # новая карта → реактивная Мия подхватывает её в память (кросс-поточно, очередью)
        self.chron_worker.updated.connect(self.worker.set_chronicle)
        self.chron_worker.updated.connect(self._on_chronicle)
        self.chron_thread.started.connect(self.chron_worker.start_loop)
        self.chron_thread.start()

    @Slot(str)
    def _on_chronicle(self, text):
        # разово отмечаем, что карта заработала; дальше молча обновляется в фоне
        if not self._chron_shown:
            self._chron_shown = True
            self._add_system("— составила карту игры (обновляю раз в 15 мин, "
                             "держу в контексте) —")

    # ---------------------------------------------------------- заполнение тишины
    def _pick_idle_target(self):
        lo = getattr(C, "IDLE_MIN_SEC", 240)
        hi = max(lo, getattr(C, "IDLE_MAX_SEC", 420))
        self._idle_target = random.uniform(lo, hi)   # случайный порог — не по будильнику

    def _bump_activity(self):
        """Реальное событие в игре — сбрасываем счётчик тишины и берём новый порог."""
        self._last_activity = time.monotonic()
        self._pick_idle_target()

    def _idle_check(self):
        if not self._watching or not getattr(C, "IDLE_FILLER", True):
            return
        if time.monotonic() - self._last_activity < self._idle_target:
            return
        self._bump_activity()          # чтоб не сыпать заполнители подряд
        self.to_idle.emit()            # мозг-поток сам сходит в Gemini и вернёт реплику

    # ---------------------------------------------------------- слежка за логом
    def _restyle_watch_btn(self):
        # «Пауза» (не следим) — зелёная обводка; «Игра» (следим) — красный активный стиль
        self.watch_btn.setObjectName("outline_active" if self._watching else "outline")
        self.watch_btn.style().unpolish(self.watch_btn)
        self.watch_btn.style().polish(self.watch_btn)

    def _toggle_watch(self):
        if self._watching:
            self._watching = False
            self.watch_btn.setText("Пауза")
            self._restyle_watch_btn()
            self._set_status("○ не слежу", C.MUTED)
            return
        # включаемся всегда, даже если игра ещё не запущена и лога нет:
        # _tick сам подхватит файл, как только мод его создаст
        self._buf = ""
        self._merge_buf = []
        self._watching = True
        self._bump_activity()          # начинаем отсчёт тишины с этого момента
        self.watch_btn.setText("Игра")
        self._restyle_watch_btn()
        if os.path.exists(C.LOG_FILE):
            self._pos = os.path.getsize(C.LOG_FILE)   # только новое, историю не переигрываем
            self._set_status("● слежу", C.ACCENT)
        else:
            self._pos = 0
            self._set_status("● жду лог", "#e0b04a")

    def _tick(self):
        if not self._watching:
            return
        if not os.path.exists(C.LOG_FILE):
            if getattr(self, "_status_text", "") != "● жду лог":
                self._set_status("● жду лог", "#e0b04a")   # игра ещё не создала лог — ждём
            return
        if getattr(self, "_status_text", "") != "● слежу":
            self._set_status("● слежу", C.ACCENT)          # лог появился — активная слежка
        try:
            size = os.path.getsize(C.LOG_FILE)
            if size < self._pos:          # лог обнулили (новая сессия) — начинаем с конца
                self._pos = 0
            if size == self._pos:
                return
            with open(C.LOG_FILE, "rb") as f:
                f.seek(self._pos)
                chunk = f.read()
                self._pos = f.tell()
        except Exception:
            return
        self._buf += chunk.decode("utf-8", errors="ignore")
        lines = self._buf.split("\n")
        self._buf = lines.pop()           # последний кусок без \n — недописанная строка
        lines = [l for l in lines if l.strip()]
        if lines:
            self._bump_activity()     # в игре что-то произошло — тишина сброшена
            # Строки «ЧАТ | <имя>: текст» — это игрок пишет Мие ИЗ ИГРОВОГО ЧАТА.
            # Это прямое обращение, а не событие: гоним его тем же приоритетным каналом,
            # что и поле ввода (manual=True) — без кулдауна, развёрнуто, с приоритетом.
            chat_lines, game_lines = [], []
            for l in lines:
                idx = l.find("ЧАТ |")
                if idx != -1:
                    head = l[:idx]                       # "[время] " — оставляем метку
                    rest = l[idx + len("ЧАТ |"):]        # " <ник>: текст"
                    if ":" in rest:
                        sender, msg = rest.split(":", 1)
                        sender, msg = sender.strip(), msg.strip()
                    else:
                        sender, msg = "", rest.strip()
                    if msg:
                        player = getattr(C, "PLAYER_NAME", "Ari").lower()
                        if sender.lower() == "system":
                            # СЕРВЕРНЫЙ бот-автомат (приветствия, прогрессия, объявления,
                            # «You are now an Admin» и т.п.). Это НЕ игрок и НЕ про игрока:
                            # «you/ты/Ari» в таких строках — дежурный серверный текст.
                            game_lines.append(head + f"СИСТЕМА СЕРВЕРА | {msg}")
                        elif not sender or sender.lower() == player:
                            # это ОЛЕГ пишет Мие из игрового чата — прямое обращение
                            chat_lines.append(head + msg)   # "[время] текст" — без «ЧАТ | Ari:»
                            self._set_vision_focus(msg)     # вдруг следом F8 — фокус на это
                        else:
                            # ЧУЖОЙ игрок в мультиплеере — не обращение к Мие. Гоним обычным
                            # потоком событий с пометкой «ЧАТ ИГРОКА | Имя:»: classify её узнает
                            # (не задушит кулдауном), а промпт велит перевести и прокомментировать.
                            game_lines.append(head + f"ЧАТ ИГРОКА | {sender}: {msg}")
                else:
                    game_lines.append(l)

            if chat_lines:
                # чат игрока перебивает текущую озвучку события — у обращения приоритет
                if self._speaking:
                    V.stop()
                    self._pending.clear()
                self._speaking = True
                self._speaking_manual = True   # это личный ответ — защищён от перебоя событиями
                self._speaking_since = time.monotonic()
                self.to_brain.emit(chat_lines, time.monotonic(), True)

            if game_lines:
                game_lines = self._merge_window(game_lines)
                if game_lines:
                    self._send_game(game_lines)

    # ------------------------------------------------- склейка связанных событий
    def _merge_window(self, lines):
        """Левелап и очки технологий игра пишет ДВУМЯ строками с разницей в доли
        секунды, но для игрока это ОДНО событие: раньше первая фраза начинала
        звучать и тут же обрывалась второй. Теперь на такую пачку открываем окно
        MERGE_MS и всё, что придёт за это время, уходит мозгу разом — одной фразой.
        Возвращает строки для немедленной отправки ([] — придержали)."""
        if self._merge_buf:                    # окно уже открыто — досыпаем в него
            self._merge_buf.extend(lines)
            return []
        # Те же две-в-одном пары: левелап+очки и поимка пала+лут с него.
        pair = any(("ЛЕВЕЛАП" in l or "ОЧКИ" in l or "ПОЙМАН ПАЛ" in l
                    or "ОТКРЫТ СУНДУК" in l) for l in lines)
        if not pair:
            return lines
        # смерть/низкое HP ждать нельзя — это рефлекс, там важны миллисекунды
        if any(B.classify(B.parse_line(l)[1] or "")[1] == 3 for l in lines):
            return lines
        self._merge_buf = list(lines)
        QTimer.singleShot(getattr(C, "MERGE_MS", 1500), self._flush_merge)
        return []

    def _flush_merge(self):
        """Окно склейки закрылось — отдаём накопленное одной пачкой."""
        lines, self._merge_buf = self._merge_buf, []
        if lines and self._watching:
            self._send_game(lines)

    def _send_game(self, game_lines):
        """Отдать пачку игровых событий мозгу (с учётом буфера и приоритета речи)."""
        if self._speaking_manual:
            # Мия отвечает ЛИЧНО игроку — событие не перебивает НИКОГДА (даже без буфера),
            # ждёт в буфере и выйдет, когда она договорит. Это главный приоритет.
            self._pending.extend(game_lines)
        elif getattr(C, "EVENT_BUFFER", True) and self._speaking:
            self._pending.extend(game_lines)   # буфер включён и голос занят → копим
        else:
            # Буфер выключен: НЕ глушим текущую речь заранее. Отдаём событие мозгу —
            # если он выдаст реплику, её V.speak сам перебьёт старую (смена поколения).
            # А если событие отфильтруется (мелочь под кулдауном / тихая зона) — старая
            # речь спокойно доиграет. Так уходит баг «оборвал озвучку, а новую не сказал»:
            # перебивка теперь случается ровно тогда, когда есть чем перебить.
            self._speaking = True
            self._speaking_since = time.monotonic()
            self.to_brain.emit(game_lines, time.monotonic(), False)

    # ---------------------------------------------------------- фокус для F8
    def _set_vision_focus(self, text):
        """игрок что-то указал (чат/поле/микро) — запоминаем как возможный фокус для F8:
        нажмёт снимок в ближайшие VISION_FOCUS_SEC — разбор ответит именно на это указание."""
        text = (text or "").strip()
        if text:
            self._vision_focus = text
            self._vision_focus_at = time.monotonic()

    def _current_vision_focus(self):
        """Свежее указание игрока для разбора снимка ('' если давно ничего не говорил)."""
        if self._vision_focus and (time.monotonic() - self._vision_focus_at
                                   <= getattr(C, "VISION_FOCUS_SEC", 45)):
            return self._vision_focus
        return ""

    # ---------------------------------------------------------- ручной ввод
    def _send_manual(self):
        t = self.inp.text().strip()
        if not t:
            return
        self.inp.clear()
        self._set_vision_focus(t)   # вдруг следом F8 — разбор учтёт это указание
        # оформляем как событие с текущим временем
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {t}"
        self._bump_activity()
        # личный ответ игроку: перебиваем текущую озвучку события и ставим защиту от перебоя,
        # чтоб прилетевшее событие не оборвало Мию на полуслове (как чат из игры)
        if self._speaking:
            V.stop()
            self._pending.clear()
        self._speaking = True
        self._speaking_manual = True
        self._speaking_since = time.monotonic()
        self.to_brain.emit([line], time.monotonic(), True)   # ручная отправка — не глушить

    # ---------------------------------------------------------- микрофон-рация
    def _load_whisper(self):
        """Грузим модель распознавания в фоне (base, cpu, int8, offline) — один раз при старте."""
        try:
            from faster_whisper import WhisperModel
            self._whisper["model"] = WhisperModel("base", device="cpu", compute_type="int8")
        except Exception as e:
            self._whisper["err"] = str(e)

    def start_mic(self):
        """Нажал кнопку (рация) — пошла запись с микрофона."""
        if self._whisper.get("model") is None:
            self.mic_status.emit("🎤 модель ещё грузится, секунду…" if "err" not in self._whisper
                                 else "🎤 распознавание недоступно: " + self._whisper["err"][:50])
            return
        if self._recording:
            return
        self._recording = True
        self._audio = []
        self.inp.set_recording(True)
        self.mic_status.emit("🎤 говори… (отпусти — стоп)")
        threading.Thread(target=self._record_loop, daemon=True).start()

    def stop_mic(self):
        """Отпустил кнопку — стоп записи, распознаю, текст ложится в поле ввода."""
        if not self._recording:
            return
        self._recording = False
        self.inp.set_recording(False)
        self.mic_status.emit("🎤 распознаю…")
        threading.Thread(target=self._transcribe, daemon=True).start()

    def _record_loop(self):
        try:
            import sounddevice as sd
            import numpy as np
            with sd.InputStream(samplerate=16000, channels=1, dtype="float32", blocksize=1024) as st:
                while self._recording:
                    chunk, _ = st.read(1024)
                    self._audio.append(chunk.copy())
        except Exception as e:
            self._recording = False
            self.mic_status.emit(f"🎤 микрофон недоступен: {str(e)[:50]}")

    def _transcribe(self):
        try:
            import numpy as np
            if not self._audio:
                self.mic_status.emit("🎤 пусто — ничего не услышала")
                return
            audio = np.concatenate(self._audio, axis=0).flatten()
            # 1) шумовой порог: молчал или тихий фон — НЕ гоним в whisper. Именно на тишине
            #    он выдумывает титры («субтитры… корректор…»). Нет речи — нет запроса.
            dur = len(audio) / 16000.0
            rms = float(np.sqrt(np.mean(audio ** 2))) if len(audio) else 0.0
            peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
            if dur < 0.3 or rms < 0.008 or peak < 0.03:
                self.mic_status.emit("🎤 тихо — не расслышала, скажи ещё раз")
                return
            # 2) VAD режет паузы, temperature=0 и без «памяти» — галлюцинации не наматываются
            kw = dict(language="ru", beam_size=5, temperature=0.0,
                      condition_on_previous_text=False, no_speech_threshold=0.6)
            try:
                segments, _ = self._whisper["model"].transcribe(
                    audio, vad_filter=True,
                    vad_parameters=dict(min_silence_duration_ms=400), **kw)
            except Exception:
                segments, _ = self._whisper["model"].transcribe(audio, **kw)  # без VAD (не скачался)
            # 3) выкидываем сегменты-фантомы (высокая вероятность «речи тут нет»)
            parts = [s.text for s in segments if getattr(s, "no_speech_prob", 0.0) < 0.6]
            text = _strip_phantoms(" ".join(parts).strip())
            if text:
                self.mic_text.emit(text)
            else:
                self.mic_status.emit("🎤 не разобрала, попробуй ещё")
        except Exception as e:
            self.mic_status.emit(f"🎤 сбой распознавания: {str(e)[:50]}")

    def _put_voice_text(self, text):
        """Распознанное кладу в поле ввода (не отправляю — глянешь/поправишь, Enter отправит)."""
        cur = self.inp.text().strip()
        self.inp.setText((cur + " " + text).strip() if cur else text)
        self.inp.setFocus()
        # вернуть статус в норму: при слежке _tick сам выставит «слежу» на ближайшем тике,
        # на паузе исправляем вручную (там _tick выходит сразу и статус диктовки повис бы)
        if not self._watching:
            self._set_status("○ не слежу", C.MUTED)

    # ---------------------------------------------------------- скриншот по хоткею
    def _start_hotkey(self):
        """Вешаем глобальную клавишу (по умолчанию F8): снимок экрана -> наша папка.
        Глобальная — ловится даже когда фокус в игре, в отличие от Qt-шортката."""
        try:
            import keyboard
            keyboard.add_hotkey(getattr(C, "SHOT_HOTKEY", "f8"), self._hotkey_shot)
        except Exception:
            import traceback; traceback.print_exc()   # не критично — просто без скриншотов

    def _hotkey_shot(self):
        """Зовётся из потока-слушателя keyboard: снимаем и уводим путь в GUI-поток сигналом."""
        try:
            import shutter; shutter.play()   # звук затвора — сразу, до снимка
        except Exception:
            pass
        try:
            path = S.grab_and_save()
        except Exception:
            path = None
        self.shot_taken.emit(path or "")

    @Slot(str)
    def _on_shot(self, path):
        if path:
            self._add_system(f"📸 скриншот сохранён: {os.path.basename(path)}")
            # если игрок только что что-то указал (чат/поле/микро) — разбор ответит на это
            self.to_vision.emit(path, self._current_vision_focus())   # параллельно мозгу
        else:
            self._add_system("📸 не удалось снять экран (в эксклюзивном полноэкранном "
                             "бывает чёрный кадр — переключи игру в режим «без рамки»)")

    @Slot(str)
    def _on_vision(self, desc):
        """Vision-модель разобрала снимок: пузырь + память, и озвучка с высоким приоритетом.
        F8 — сознательная просьба игрока: разбор НЕ должен ни перебиваться, ни теряться.
        Если сейчас звучит другое важное (личный ответ / другой разбор) — встаём в очередь
        и озвучимся после; игровое событие/затишье — перебиваем, разбор важнее."""
        self._bubble(desc, "mia")
        self.to_note.emit(desc)         # запись в память -> мозг-поток (без гонок)
        if self._speaking_manual:
            self._pending_vision.append(desc)   # канал занят важным — ждём очереди, не теряемся
            return
        self._speak_vision(desc)

    def _speak_vision(self, desc):
        """Озвучить разбор скриншота с высоким приоритетом (событие его не перебьёт)."""
        if self._speaking:
            V.stop()                    # звучало лишь событие — разбор важнее, перебиваем
            self._pending.clear()
        self._speaking = True
        self._speaking_manual = True
        self._speaking_since = time.monotonic()
        if self.worker.voice_on:
            V.speak(desc, on_timed=self.worker.spoke.emit)
        else:
            self.worker.spoke.emit(0.0)  # голос выключен — сразу освобождаем буфер

    def closeEvent(self, e):
        # крестик прячет в трей, а не закрывает; настоящий выход — через меню трея
        if not self._quitting:
            e.ignore()
            self._hide_to_tray()
            return
        V.stop()
        try:
            import keyboard; keyboard.unhook_all()   # снять глобальный хоткей
        except Exception:
            pass
        self.tray.hide()
        self.thread.quit(); self.thread.wait(1500)
        self.chron_thread.quit(); self.chron_thread.wait(1500)
        self.vis_thread.quit(); self.vis_thread.wait(1500)
        super().closeEvent(e)


if __name__ == "__main__":
    import sys
    B.load_settings()                      # поднять сохранённые крутилки до старта окна
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)   # живём в трее, крестик не убивает
    app.setFont(QFont("Segoe UI", 10))
    take_over_single_instance()            # был живой экземпляр — вырубили его, теперь мы единственные
    w = Assistant()
    server = QLocalServer()                # слушаем: если запустят ещё один — он попросит нас уйти
    server.listen(INSTANCE_KEY)
    w._instance_server = server
    server.newConnection.connect(w._on_takeover_request)
    w.show()
    sys.exit(app.exec())
