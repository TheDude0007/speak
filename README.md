# Speak

Push-to-talk dictation for macOS 26. Hold a key, talk, let go — text appears at your cursor in any app.
Fully on-device. 1.3 MB.

## Use

| Gesture | Result |
|---|---|
| **Hold** the dictation key (default `fn`/🌐) | Records while held, types on release |
| **Double-tap** | Hands-free; tap once more to finish |
| **Esc** | Cancel, nothing typed |
| Brush the key once / use it in a shortcut (fn+←) | Ignored, nothing typed |

Spoken commands: **"new line"**, **"new paragraph"**, **"scratch that"** (deletes the previous sentence).
Fillers (um, uh, er, hmm) are removed. Custom words + replacements live in
`~/Library/Application Support/Speak/dictionary.json` (menu → *Edit dictionary*):

```json
{ "vocabulary": ["GEMNIsound", "Garchar"],          // biases recognition toward these spellings
  "replacements": { "gemini sound": "GEMNIsound" } } // spoken phrase -> exact output
```

## Build

```sh
swift test               # 11 core tests (hotkey gestures, text cleanup, smart joining)
scripts/build-app.sh     # release build, signs with your Apple Development cert, installs ~/Applications/Speak.app
build/Speak.app/Contents/MacOS/Speak --transcribe file.wav --realtime   # headless pipeline self-test + latency
```

## How it compares to Aqua Voice 0.22.5 (what Speak was reverse-engineered from)

Findings come from REA static analysis of `app.asar` (evidence `ev_160fad93…`), the extracted webpack bundles, and the
`AquaMacOSBridge` Swift helper's symbols. See `docs/aqua-teardown.md`.

| | Aqua Voice | Speak |
|---|---|---|
| Runtime | Electron 42 (Chromium + Node, 4 helper processes) + a Swift helper app (bridge) | One native Swift process |
| App size | 572 MB | 1.3 MB |
| Speech recognition | Streams audio to `wss://realtime.aquavoice.com` (cloud), account token required | Apple SpeechAnalyzer, on-device, offline, no account |
| Audio path | Web Audio worklet (array spread/slice copies every 128 samples) → Opus in WASM → websocket | AVAudioEngine tap → vDSP level → one AVAudioConverter → model |
| Latency after key-up | network round trip + server LLM "refinement" | ~40 ms measured (real-time-paced test) |
| First-word loss | — | none: audio buffers into the analyzer stream while it starts; model stays warm for the life of the process |
| Text insertion | clipboard paste via the bridge | Accessibility insert for native apps (clipboard untouched, undo works); otherwise a transient paste that clipboard managers skip, then the clipboard is restored |
| Hotkey tap | active event tap in the bridge | listen-only tap: can never block or delay your typing |
| Telemetry | Sentry + PostHog | none |
| Privacy | audio + screen context sent to server | nothing leaves the Mac; audio never written to disk |
| Scope | dictation + meetings, screen pen, screenshots, translation, virtual camera, MCP, CLI | dictation only |

Peak memory during a dictation: 22 MB RSS / 7 MB footprint (the model runs in macOS's shared speech service).

## Layout

```
Sources/SpeakCore/   HotkeyMachine (gesture state machine), TextCleaner, SmartJoin   — pure, tested
Sources/Speak/       main (menu bar + controller), SpeechEngine, AudioCapture, HotkeyTap, Inserter, HUD, Store
scripts/             build-app.sh, make-icon.swift
```
