from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .engine import data_dir

DEFAULT_KEY = "ctrl_r"
KEYS = {  # pynput Key names -> menu title
    "ctrl_r": "Right Ctrl",
    "alt_r": "Right Alt",
    "shift_r": "Right Shift",
    "caps_lock": "Caps Lock",
    "f8": "F8",
    "pause": "Pause/Break",
}


@dataclass
class Settings:
    hotkey: str = DEFAULT_KEY
    remove_fillers: bool = True
    sounds: bool = True
    claude_polish: bool = False
    keep_history: bool = True
    _path: Path = field(default=None, repr=False, compare=False)

    @staticmethod
    def path() -> Path:
        return data_dir() / "settings.json"

    @classmethod
    def load(cls) -> "Settings":
        try:
            raw = json.loads(cls.path().read_text())
            known = {k: v for k, v in raw.items() if k in cls.__dataclass_fields__ and not k.startswith("_")}
            return cls(**known)
        except Exception:
            return cls()

    def save(self):
        d = {k: v for k, v in asdict(self).items() if not k.startswith("_")}
        self.path().write_text(json.dumps(d, indent=2))

    @staticmethod
    def dictionary_path() -> Path:
        p = data_dir() / "dictionary.json"
        if not p.exists():
            p.write_text(json.dumps({"replacements": {"smiley face": "🙂"}}, indent=2, ensure_ascii=False))
        return p

    def replacements(self) -> dict:
        try:
            return dict(json.loads(self.dictionary_path().read_text(encoding="utf-8")).get("replacements", {}))
        except Exception:
            return {}


# ---- API key: OS credential store (Windows Credential Manager / Secret Service / Keychain)

_SERVICE, _ACCOUNT = "Speak", "anthropic-api-key"


def get_api_key() -> str | None:
    try:
        import keyring

        return keyring.get_password(_SERVICE, _ACCOUNT)
    except Exception:
        return None


def set_api_key(key: str | None) -> bool:
    try:
        import keyring

        if key:
            keyring.set_password(_SERVICE, _ACCOUNT, key)
        else:
            try:
                keyring.delete_password(_SERVICE, _ACCOUNT)
            except Exception:
                pass
        return True
    except Exception:
        return False
