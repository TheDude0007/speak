"""Speak for Windows & Linux: system-tray app. Hold the key, talk, let go."""
from __future__ import annotations

import json
import sys
import threading
import time
from datetime import datetime

import numpy as np

from .core import HotkeyMachine
from .engine import Engine, ProgressiveTranscriber, data_dir, download_models, models_present
from .io import Hotkey, Mic, beep, insert_text, wayland
from .pipeline import Pipeline
from .settings import KEYS, Settings, get_api_key, set_api_key

IPC_ADDR = ("127.0.0.1", 47321)
IPC_KEY = b"speak-local"


def _icon_image(color=(120, 160, 255)):
    from PIL import Image, ImageDraw

    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((2, 2, 62, 62), radius=14, fill=(24, 22, 48, 255))
    for i, h in enumerate([14, 26, 40, 26, 14]):
        x = 12 + i * 9
        d.rounded_rectangle((x, 32 - h // 2, x + 5, 32 + h // 2), radius=3, fill=color + (255,))
    return img


class SpeakApp:
    def __init__(self):
        self.settings = Settings.load()
        self.pipe = Pipeline(self.settings)
        self.machine = HotkeyMachine()
        self.mic = Mic()
        self.engine: Engine | None = None
        self.session: ProgressiveTranscriber | None = None
        self.status = "Starting…"
        self.last_ms = None
        self.icon = None
        self.hotkey: Hotkey | None = None
        self._tap_timer = None
        self._lock = threading.RLock()

    # ------------------------------------------------------------ lifecycle
    def run(self):
        import pystray

        self.icon = pystray.Icon("Speak", _icon_image(), "Speak", menu=self._menu())
        threading.Thread(target=self._boot, daemon=True).start()
        threading.Thread(target=self._ipc_server, daemon=True).start()
        self.icon.run()

    def _boot(self):
        try:
            if not models_present():
                download_models(lambda f, m: self._set_status(m))
            self._set_status("Loading speech model…")
            self.engine = Engine()
            _ = self.pipe.punct  # load punctuation model now
            self._set_status("Ready — on-device" + (" (use `speak --toggle` shortcut on Wayland)" if wayland() else ""))
            self._wire_hotkey()
        except Exception as e:  # pragma: no cover
            self._set_status(f"Error: {e}")

    def _set_status(self, s: str):
        self.status = s
        if self.icon:
            self.icon.title = f"Speak — {s}"
            self.icon.update_menu()

    def _wire_hotkey(self):
        if self.hotkey:
            self.hotkey.stop()
        self.hotkey = Hotkey(self.settings.hotkey,
                             on_down=lambda: self._dispatch(self.machine.key_down(time.monotonic())),
                             on_up=lambda: self._dispatch(self.machine.key_up(time.monotonic())),
                             on_other=lambda: self._dispatch(self.machine.other_key()),
                             on_escape=lambda: self._dispatch(self.machine.escape()))
        try:
            self.hotkey.start()
        except Exception as e:
            self._set_status(f"Hotkey unavailable ({e}); use `speak --toggle`")

    # ------------------------------------------------------------ gestures
    def _dispatch(self, actions):
        with self._lock:
            for a in actions:
                if a == "start":
                    self._begin()
                elif a == "commit":
                    self._commit()
                elif a == "cancel":
                    self._cancel()
                elif isinstance(a, tuple) and a[0] == "schedule":
                    if self._tap_timer:
                        self._tap_timer.cancel()
                    self._tap_timer = threading.Timer(a[1], lambda: self._dispatch(self.machine.tap_timeout()))
                    self._tap_timer.start()

    def _begin(self):
        if self.session or not self.engine:
            self.machine.reset()
            return
        self.session = ProgressiveTranscriber(self.engine)
        self.mic.on_audio = self.session.feed
        try:
            self.mic.start()
        except Exception as e:
            self.session = None
            self.machine.reset()
            self._set_status(f"Mic error: {e}")
            return
        if self.icon:
            self.icon.icon = _icon_image((255, 90, 90))
        if self.settings.sounds:
            beep(880)

    def _stop_mic(self):
        self.mic.stop()
        self.mic.on_audio = None
        if self.icon:
            self.icon.icon = _icon_image()

    def _commit(self):
        s, self.session = self.session, None
        if not s:
            return
        self._stop_mic()
        if self.settings.sounds:
            beep(660)

        def work():
            t0 = time.perf_counter()
            raw = s.finish()
            text = self.pipe.finish(raw)
            if text:
                insert_text(text, self.hotkey)
                self.last_ms = int((time.perf_counter() - t0) * 1000)
                self._history(text, raw)
                self._set_status(f"Ready — last: {self.last_ms} ms")
        threading.Thread(target=work, daemon=True).start()

    def _cancel(self):
        if self._tap_timer:
            self._tap_timer.cancel()
        if self.session:
            self.session = None
            self._stop_mic()

    def toggle(self):
        self._dispatch(self.machine.toggle())

    # ------------------------------------------------------------ history
    def _history(self, text, raw):
        if not self.settings.keep_history:
            return
        p = data_dir() / "history.json"
        try:
            items = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            items = []
        items.insert(0, {"date": datetime.now().isoformat(timespec="seconds"), "text": text, "raw": raw, "ms": self.last_ms})
        p.write_text(json.dumps(items[:200], indent=1, ensure_ascii=False), encoding="utf-8")

    def _recent(self):
        try:
            return json.loads((data_dir() / "history.json").read_text(encoding="utf-8"))[:10]
        except Exception:
            return []

    # ------------------------------------------------------------ IPC (--toggle)
    def _ipc_server(self):
        from multiprocessing.connection import Listener

        try:
            with Listener(IPC_ADDR, authkey=IPC_KEY) as l:
                while True:
                    with l.accept() as c:
                        if c.recv() == "toggle":
                            self.toggle()
        except OSError:
            pass  # another instance owns the port

    # ------------------------------------------------------------ menu
    def _menu(self):
        import pystray
        from pystray import Menu, MenuItem as Item

        def setting(name):
            def act(icon, item):
                setattr(self.settings, name, not getattr(self.settings, name))
                self.settings.save()
                if name == "claude_polish" and self.settings.claude_polish and not get_api_key():
                    self._ask_key()
            return Item(_TITLES[name], act, checked=lambda item: getattr(self.settings, name))

        def pick(key):
            def act(icon, item):
                self.settings.hotkey = key
                self.settings.save()
                self._wire_hotkey()
            return Item(KEYS[key], act, checked=lambda item: self.settings.hotkey == key, radio=True)

        def copy_item(entry):
            def act(icon, item):
                import pyperclip
                pyperclip.copy(entry["text"])
            t = entry["text"].replace("\n", " ")
            return Item(t[:60] + ("…" if len(t) > 60 else ""), act)

        return Menu(
            Item(lambda item: f"Speak — {self.status}", None, enabled=False),
            Menu.SEPARATOR,
            Item("Dictation key", Menu(*[pick(k) for k in KEYS])),
            Item("Hold to talk · double-tap for hands-free · Esc cancels", None, enabled=False),
            Menu.SEPARATOR,
            setting("remove_fillers"),
            setting("sounds"),
            setting("keep_history"),
            setting("claude_polish"),
            Item("Set Claude API key…", lambda i, it: self._ask_key()),
            Item("Edit replacements…", lambda i, it: _open(Settings.dictionary_path())),
            Menu.SEPARATOR,
            Item("Recent (click to copy)", Menu(lambda: [copy_item(e) for e in self._recent()] or [Item("Nothing yet", None, enabled=False)])),
            Menu.SEPARATOR,
            Item("Quit Speak", lambda i, it: (self._cancel(), i.stop())),
        )

    def _ask_key(self):
        def dialog():
            try:
                import tkinter as tk
                from tkinter import simpledialog

                root = tk.Tk(); root.withdraw()
                key = simpledialog.askstring("Speak", "Claude API key (stored in your system keychain).\nLeave blank to remove:", show="•")
                root.destroy()
                if key is not None:
                    set_api_key(key.strip() or None)
            except Exception:
                pass
        threading.Thread(target=dialog, daemon=True).start()


_TITLES = {
    "remove_fillers": "Remove filler words (um, uh)",
    "sounds": "Sounds",
    "keep_history": "Keep history",
    "claude_polish": "AI polish with Claude (sends text, not audio)",
}


def _open(path):
    import os
    import subprocess

    if sys.platform == "win32":
        os.startfile(path)  # noqa
    elif sys.platform == "darwin":
        subprocess.run(["open", str(path)])
    else:
        subprocess.run(["xdg-open", str(path)])


def send_toggle() -> int:
    from multiprocessing.connection import Client

    try:
        with Client(IPC_ADDR, authkey=IPC_KEY) as c:
            c.send("toggle")
        return 0
    except OSError:
        print("Speak is not running.", file=sys.stderr)
        return 1
