"""Microphone, global hotkey and text insertion for Windows / Linux (X11 + Wayland fallbacks)."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time

import numpy as np

from .engine import SAMPLE_RATE

# ------------------------------------------------------------------ microphone


class Mic:
    """16 kHz mono float32 straight from PortAudio; blocks of 20 ms."""

    def __init__(self):
        self.stream = None
        self.on_audio = None   # callable(np.ndarray)
        self.level = 0.0

    def start(self):
        import sounddevice as sd

        def cb(indata, frames, t, status):
            x = indata[:, 0].copy()
            self.level = float(np.sqrt(np.mean(x * x)))
            if self.on_audio:
                self.on_audio(x)

        self.stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                                     blocksize=SAMPLE_RATE // 50, callback=cb)
        self.stream.start()

    def stop(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None


def beep(freq: float = 880, ms: int = 40, volume: float = 0.15):
    try:
        import sounddevice as sd

        t = np.arange(int(SAMPLE_RATE * ms / 1000)) / SAMPLE_RATE
        tone = (volume * np.sin(2 * np.pi * freq * t) * np.hanning(t.size)).astype(np.float32)
        sd.play(tone, SAMPLE_RATE, blocking=False)
    except Exception:
        pass


# ------------------------------------------------------------------ hotkey


class Hotkey:
    """Global key listener (pynput). Works on Windows and Linux/X11.
    Wayland blocks global key capture by design: bind a desktop shortcut to
    `speak --toggle` instead (see README)."""

    def __init__(self, key_name: str, on_down, on_up, on_other, on_escape):
        self.key_name = key_name
        self.on_down, self.on_up, self.on_other, self.on_escape = on_down, on_up, on_other, on_escape
        self._down = False
        self._listener = None
        self.suppress_until = 0.0  # ignore our own synthetic Ctrl+V

    def start(self):
        from pynput import keyboard

        target = getattr(keyboard.Key, self.key_name, None)

        def press(k):
            if time.monotonic() < self.suppress_until:
                return
            if k == target or (self.key_name == "alt_r" and k == getattr(keyboard.Key, "alt_gr", None)):
                if not self._down:
                    self._down = True
                    self.on_down()
            elif k == keyboard.Key.esc:
                self.on_escape()
            else:
                self.on_other()

        def release(k):
            if k == target or (self.key_name == "alt_r" and k == getattr(keyboard.Key, "alt_gr", None)):
                if self._down:
                    self._down = False
                    self.on_up()

        self._listener = keyboard.Listener(on_press=press, on_release=release)
        self._listener.daemon = True
        self._listener.start()

    def stop(self):
        if self._listener:
            self._listener.stop()
            self._listener = None


def wayland() -> bool:
    return sys.platform.startswith("linux") and bool(os.environ.get("WAYLAND_DISPLAY"))


# ------------------------------------------------------------------ insertion


def insert_text(text: str, hotkey: Hotkey | None = None):
    """Paste via clipboard (fast, Unicode-safe), then restore the user's clipboard.
    Falls back to synthesized typing if the clipboard isn't usable."""
    import pyperclip

    try:
        old = pyperclip.paste()
    except Exception:
        old = None
    try:
        pyperclip.copy(text)
    except Exception:
        return _type(text)

    if hotkey:
        hotkey.suppress_until = time.monotonic() + 0.3
    if wayland() and shutil.which("wtype"):
        subprocess.run(["wtype", "-M", "ctrl", "v", "-m", "ctrl"], check=False)
    elif wayland() and shutil.which("ydotool"):
        subprocess.run(["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], check=False)
    else:
        from pynput.keyboard import Controller, Key

        kb = Controller()
        with kb.pressed(Key.ctrl):
            kb.press("v")
            kb.release("v")

    if old is not None:
        def restore():
            time.sleep(0.4)
            try:
                if pyperclip.paste() == text:
                    pyperclip.copy(old)
            except Exception:
                pass
        threading.Thread(target=restore, daemon=True).start()


def _type(text: str):
    from pynput.keyboard import Controller

    Controller().type(text)
