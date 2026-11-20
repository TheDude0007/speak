import os
import sys
import traceback

# Windowed builds have no console: give print() somewhere to go, and never let an
# exception reach PyInstaller's modal error dialog (it blocks forever unattended).
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w")

try:
    from speak.__main__ import main
    code = main()
except SystemExit as e:
    code = e.code
except BaseException:
    tb = traceback.format_exc()
    out = os.environ.get("SPEAK_SELFTEST_OUT")
    try:
        from pathlib import Path
        from speak.engine import data_dir
        (Path(out) if out else data_dir() / "crash.log").write_text(tb, encoding="utf-8")
    except Exception:
        pass
    print(tb, file=sys.stderr)
    code = 1
sys.exit(code)
