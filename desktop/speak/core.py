"""Platform-independent logic. Mirrors Sources/SpeakCore (Swift) so every Speak
build cleans text and interprets the hotkey identically."""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# ---------------------------------------------------------------- hotkey machine


class HotkeyMachine:
    """Hold = push-to-talk. Double-tap = hands-free (tap again to finish).
    Single brush of the key = discarded. Other key while holding = cancel (chord). Esc = cancel."""

    IDLE, PRESSED, AWAIT_SECOND, HANDS_FREE = "idle", "pressed", "await", "handsfree"

    def __init__(self, hold_threshold: float = 0.28, double_tap_window: float = 0.32):
        self.hold_threshold = hold_threshold
        self.double_tap_window = double_tap_window
        self.state = self.IDLE
        self._since = 0.0

    def key_down(self, t: float) -> list:
        if self.state == self.IDLE:
            self.state, self._since = self.PRESSED, t
            return ["start"]
        if self.state == self.AWAIT_SECOND:
            self.state = self.HANDS_FREE
            return []
        if self.state == self.HANDS_FREE:
            self.state = self.IDLE
            return ["commit"]
        return []

    def key_up(self, t: float) -> list:
        if self.state != self.PRESSED:
            return []
        if t - self._since >= self.hold_threshold:
            self.state = self.IDLE
            return ["commit"]
        self.state = self.AWAIT_SECOND
        return [("schedule", self.double_tap_window)]

    def tap_timeout(self) -> list:
        if self.state != self.AWAIT_SECOND:
            return []
        self.state = self.IDLE
        return ["cancel"]

    def other_key(self) -> list:
        if self.state in (self.PRESSED, self.AWAIT_SECOND):
            self.state = self.IDLE
            return ["cancel"]
        return []

    def escape(self) -> list:
        if self.state == self.IDLE:
            return []
        self.state = self.IDLE
        return ["cancel"]

    def toggle(self) -> list:
        """External toggle (CLI / Wayland shortcut): start hands-free, or finish."""
        if self.state == self.IDLE:
            self.state = self.HANDS_FREE
            return ["start"]
        if self.state == self.HANDS_FREE:
            self.state = self.IDLE
            return ["commit"]
        return []

    def reset(self):
        self.state = self.IDLE


# ---------------------------------------------------------------- text cleaner

FILLERS = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm", "mhm"]


@dataclass
class CleanerOptions:
    remove_fillers: bool = True
    spoken_commands: bool = True
    replacements: dict = field(default_factory=dict)


def _sub(pattern: str, repl, s: str) -> str:
    return re.sub(pattern, repl, s)


class TextCleaner:
    def __init__(self, options: CleanerOptions | None = None):
        self.o = options or CleanerOptions()

    def clean(self, raw: str) -> str:
        s = raw
        if self.o.spoken_commands:
            s = self.scratch_that(s)
        if self.o.remove_fillers:
            s = self.remove_fillers(s)
        if self.o.replacements:
            s = self.apply_replacements(s)
        if self.o.spoken_commands:
            s = self.line_commands(s)
        return self.tidy(s)

    @staticmethod
    def remove_fillers(s: str) -> str:
        alt = "|".join(re.escape(f) for f in FILLERS)
        return re.sub(rf"(?i)(^|[\s,])(?:{alt})(?:[,.…]+)?(?=\s|$|[,.!?;:])", r"\1", s)

    def apply_replacements(self, s: str) -> str:
        for frm, to in sorted(self.o.replacements.items(), key=lambda kv: -len(kv[0])):
            words = frm.strip().split()
            if not words:
                continue
            pat = r"(?i)(?<![\w])" + r"[\s,]+".join(re.escape(w) for w in words) + r"(?![\w])"
            s = re.sub(pat, lambda _m, to=to: to, s)
        return s

    @staticmethod
    def scratch_that(s: str) -> str:
        pat = re.compile(r"(?i)[,.!?]?\s*\b(scratch that|delete that)\b[,.!?]?")
        while (m := pat.search(s)):
            before, after = s[: m.start()], s[m.end():]
            idx = max(before.rfind(c) for c in ".!?\n")
            s = (before[: idx + 1] if idx >= 0 else "") + after
        return s

    @staticmethod
    def line_commands(s: str) -> str:
        s = re.sub(r"(?i)\s*\bnew paragraph\b[,.!?]?\s*", "\n\n", s)
        s = re.sub(r"(?i)\s*\bnew line\b[,.!?]?\s*", "\n", s)
        return s

    @staticmethod
    def tidy(s: str) -> str:
        s = re.sub(r"[ \t]+", " ", s)
        s = re.sub(r" +([,.!?;:])", r"\1", s)
        s = re.sub(r",(?=[,.!?])", "", s)
        s = re.sub(r"([,;:])(?=[^\W\d_])", r"\1 ", s)
        s = re.sub(r" *\n *", "\n", s)
        s = re.sub(r"^[\s,;:]+", "", s)
        s = s.strip(" \t")
        return capitalize_sentences(s)


def capitalize_sentences(s: str) -> str:
    out, cap = [], True
    for ch in s:
        if cap and ch.isalpha():
            out.append(ch.upper())
            cap = False
            continue
        if ch in ".!?\n":
            cap = True
        elif not ch.isspace() and ch not in "\"'”’)":
            cap = False
        out.append(ch)
    return "".join(out)
