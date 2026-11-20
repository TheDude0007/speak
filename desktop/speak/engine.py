"""On-device speech recognition: NVIDIA Parakeet TDT 0.6B v3 (int8) via sherpa-onnx.
25 European languages, punctuated + capitalized output, CPU only, no network after
the one-time model download."""
from __future__ import annotations

import os
import shutil
import sys
import tarfile
import threading
import time
import urllib.request
from pathlib import Path

import numpy as np

MODEL_NAME = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
PUNCT_MODEL_NAME = "sherpa-onnx-online-punct-en-2024-08-06"
MODELS = {
    MODEL_NAME: (f"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{MODEL_NAME}.tar.bz2",
                 ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]),
    PUNCT_MODEL_NAME: (f"https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/{PUNCT_MODEL_NAME}.tar.bz2",
                       ["model.int8.onnx", "bpe.vocab"]),
}
SAMPLE_RATE = 16000


def data_dir() -> Path:
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        d = base / "Speak"
    elif sys.platform == "darwin":
        d = Path.home() / "Library" / "Application Support" / "Speak-desktop"
    else:
        d = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "speak"
    d.mkdir(parents=True, exist_ok=True)
    return d


def model_dir_for(name: str) -> Path:
    """SPEAK_MODELS_DIR overrides where models live (CI caches, portable installs)."""
    root = os.environ.get("SPEAK_MODELS_DIR")
    return (Path(root) if root else data_dir()) / name


def model_dir() -> Path:
    return model_dir_for(MODEL_NAME)


def model_present(name: str = MODEL_NAME) -> bool:
    d = model_dir_for(name)
    return all((d / f).exists() for f in MODELS[name][1])


def models_present() -> bool:
    return all(model_present(n) for n in MODELS)


def download_models(progress=lambda frac, msg: None) -> None:
    """Stream-download + extract any missing model (~520 MB total, once)."""
    for name, (url, _files) in MODELS.items():
        if model_present(name):
            continue
        dest = model_dir_for(name).parent
        dest.mkdir(parents=True, exist_ok=True)
        tmp = dest / (name + ".tar.bz2.part")
        with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done = 0
            while chunk := r.read(1 << 20):
                f.write(chunk)
                done += len(chunk)
                if total:
                    progress(done / total * 0.95, f"Downloading {name.split('-')[3]} model… {done >> 20} / {total >> 20} MB")
        progress(0.96, "Unpacking…")
        staging = dest / (name + ".staging")
        shutil.rmtree(staging, ignore_errors=True)
        with tarfile.open(tmp, "r:bz2") as t:
            t.extractall(staging, filter="data")
        shutil.rmtree(model_dir_for(name), ignore_errors=True)
        (staging / name).rename(model_dir_for(name))
        shutil.rmtree(staging, ignore_errors=True)
        tmp.unlink(missing_ok=True)
    progress(1.0, "Models ready")


class Engine:
    def __init__(self, threads: int | None = None):
        import sherpa_onnx  # heavy import: defer until needed

        d = model_dir()
        self.rec = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(d / "encoder.int8.onnx"),
            decoder=str(d / "decoder.int8.onnx"),
            joiner=str(d / "joiner.int8.onnx"),
            tokens=str(d / "tokens.txt"),
            model_type="nemo_transducer",
            num_threads=threads or max(1, min(4, (os.cpu_count() or 2) - 1)),
        )
        self._lock = threading.Lock()
        # Warm-up: first inference allocates arenas; do it now, not on the user's first dictation.
        self.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))

    def transcribe(self, samples: np.ndarray) -> str:
        if samples.size < SAMPLE_RATE // 10:  # < 100 ms: nothing said
            return ""
        with self._lock:
            s = self.rec.create_stream()
            s.accept_waveform(SAMPLE_RATE, samples.astype(np.float32, copy=False))
            self.rec.decode_stream(s)
            return s.result.text.strip()


class ProgressiveTranscriber:
    """Short dictation is decoded in one pass on key-up (best context, ~0.2–0.4 s).
    Long hands-free dictation is decoded in ~20 s chunks *while you talk*, cut at a
    pause, so key-up latency stays flat. Chunk-boundary periods are harmless:
    punctuation is re-derived from meaning afterwards (punct.py)."""

    def __init__(self, engine: Engine, pause_s: float = 0.4, min_phrase_s: float = 20.0):
        self.engine = engine
        self.pause = int(pause_s * SAMPLE_RATE)
        self.min_phrase = int(min_phrase_s * SAMPLE_RATE)
        self.buf = np.zeros(0, dtype=np.float32)
        self.committed = 0      # samples already decoded
        self.texts: list[str] = []
        self._busy = threading.Lock()
        self.on_partial = None

    def feed(self, chunk: np.ndarray):
        self.buf = np.concatenate([self.buf, chunk])
        pending = self.buf.size - self.committed
        if pending < self.min_phrase + self.pause or self._busy.locked():
            return
        cut = self._find_pause(self.committed + self.min_phrase, self.buf.size)
        if cut is not None:
            seg = self.buf[self.committed:cut]
            self.committed = cut
            threading.Thread(target=self._decode, args=(seg,), daemon=True).start()

    def _find_pause(self, start: int, end: int):
        """Find the end of a quiet window (RMS well below speech level) after `start`."""
        win = self.pause
        if end - start < win:
            return None
        region = self.buf[start:end]
        speech_rms = float(np.sqrt(np.mean(region ** 2)) + 1e-9)
        hop = SAMPLE_RATE // 50
        for i in range(region.size - win, -1, -hop):
            w = region[i:i + win]
            if np.sqrt(np.mean(w ** 2)) < 0.25 * speech_rms:
                return start + i + win // 2
        return None

    def _decode(self, seg: np.ndarray):
        with self._busy:
            t = self.engine.transcribe(seg)
            if t:
                self.texts.append(t)
                if self.on_partial:
                    self.on_partial(" ".join(self.texts))

    def finish(self) -> str:
        with self._busy:  # wait for an in-flight phrase
            pass
        tail = self.buf[self.committed:]
        t = self.engine.transcribe(tail)
        if t:
            self.texts.append(t)
        return " ".join(self.texts).strip()


def read_wav(path: str) -> np.ndarray:
    """16-bit / float WAV -> mono float32 at 16 kHz (linear resample if needed)."""
    import wave

    with wave.open(path, "rb") as w:
        sr, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    if width == 2:
        x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif width == 4:
        x = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"unsupported sample width {width}")
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    if sr != SAMPLE_RATE:
        t_new = np.arange(0, len(x) * SAMPLE_RATE / sr) * sr / SAMPLE_RATE
        x = np.interp(t_new, np.arange(len(x)), x).astype(np.float32)
    return x


def selftest(wav: str, realtime: bool = True) -> int:
    from .pipeline import Pipeline

    t0 = time.perf_counter()
    if not models_present():
        download_models(lambda f, m: print(f"\r{m}            ", end="", flush=True))
        print()
    eng = Engine()
    pipe = Pipeline()
    t1 = time.perf_counter()
    x = read_wav(wav)
    pt = ProgressiveTranscriber(eng)
    step = SAMPLE_RATE // 50
    for i in range(0, x.size, step):
        pt.feed(x[i:i + step])
        if realtime:
            time.sleep(step / SAMPLE_RATE)
    t2 = time.perf_counter()
    raw = pt.finish()
    t3 = time.perf_counter()
    print(f"platform: {sys.platform}  audio: {x.size / SAMPLE_RATE:.1f}s")
    print(f"model load + warm-up: {int((t1 - t0) * 1000)} ms   key-up -> text: {int((t3 - t2) * 1000)} ms")
    t4 = time.perf_counter()
    final = pipe.finish(raw, polish=False)
    t5 = time.perf_counter()
    print(f"punctuation + cleanup: {int((t5 - t4) * 1000)} ms")
    print("RAW:  ", raw)
    print("FINAL:", final)
    out = os.environ.get("SPEAK_SELFTEST_OUT")  # windowed builds have no console
    if out:
        Path(out).write_text(f"key_up_ms={int((t3 - t2) * 1000)}\nRAW: {raw}\nFINAL: {final}\n", encoding="utf-8")
    return 0 if final else 1
