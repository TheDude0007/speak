import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser(prog="speak", description="Speak — on-device push-to-talk dictation.")
    ap.add_argument("--toggle", action="store_true", help="start/finish hands-free dictation in the running app (bind to a shortcut on Wayland)")
    ap.add_argument("--transcribe", metavar="WAV", help="headless self-test: run the full pipeline on a WAV file")
    ap.add_argument("--realtime", action="store_true", help="with --transcribe: feed audio at real speed")
    ap.add_argument("--download-models", action="store_true", help="download speech models and exit")
    a = ap.parse_args()

    if a.toggle:
        from .app import send_toggle
        return send_toggle()
    if a.transcribe:
        from .engine import selftest
        return selftest(a.transcribe, realtime=a.realtime)
    if a.download_models:
        from .engine import download_models
        download_models(lambda f, m: print(f"\r{m}            ", end="", flush=True))
        print()
        return 0
    from .app import SpeakApp
    SpeakApp().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
