"""Meaning-based punctuation for Windows/Linux.

Recognizers (Parakeet included) end a sentence wherever you pause to think:
"Speak will automatically. Insert a period…". We strip that pause-driven
punctuation and re-punctuate from the words alone with a 30 MB CNN-BiLSTM
punctuation + casing model (sherpa-onnx), ~10 ms per sentence on CPU."""
from __future__ import annotations

import re
import threading

from .engine import PUNCT_MODEL_NAME, model_dir_for

_SENT_END = ".!?"


class Repunctuator:
    def __init__(self):
        import sherpa_onnx

        d = model_dir_for(PUNCT_MODEL_NAME)
        cfg = sherpa_onnx.OnlinePunctuationConfig(
            sherpa_onnx.OnlinePunctuationModelConfig(
                cnn_bilstm=str(d / "model.int8.onnx"), bpe_vocab=str(d / "bpe.vocab"), num_threads=1
            )
        )
        self.p = sherpa_onnx.OnlinePunctuation(cfg)
        self._lock = threading.Lock()

    def __call__(self, text: str) -> str:
        return "\n".join(self._line(l) for l in text.split("\n"))

    def _line(self, line: str) -> str:
        if len(line.split()) < 3:
            return line
        # Words the recognizer capitalized mid-sentence are names/acronyms: keep them.
        keep_case = _mid_sentence_capitals(line)
        bare = re.sub(r"[.,!?;:…]", "", line).lower()
        bare = re.sub(r"\s+", " ", bare).strip()
        with self._lock:
            out = self.p.add_punctuation_with_case(bare)
        # Use the model for *where punctuation goes*; its casing is noisy, so re-case:
        # lowercase, then restore names/acronyms the recognizer capitalized, then "I".
        words = out.lower().split(" ")
        for i, w in enumerate(words):
            core = re.sub(r"[^\w'’-]", "", w)
            if core in keep_case:
                words[i] = w.replace(core, keep_case[core], 1)
            elif core == "i" or core.startswith(("i'", "i’")):
                words[i] = w.replace("i", "I", 1)
        out = " ".join(words).strip()
        out = re.sub(r"[,;:]$", "", out)
        if out and out[-1] not in _SENT_END:
            out += "."
        return out


def _mid_sentence_capitals(line: str) -> dict:
    keep = {}
    tokens = line.split()
    for i, tok in enumerate(tokens):
        core = re.sub(r"[^\w'’-]", "", tok)
        if not core or not core[0].isupper():
            continue
        prev = tokens[i - 1] if i else ""
        sentence_start = i == 0 or prev[-1:] in _SENT_END
        if not sentence_start or (len(core) > 1 and core.isupper()) or any(c.isdigit() for c in core):
            keep[core.lower()] = core
    return keep
