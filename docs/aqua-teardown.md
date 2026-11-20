# Aqua Voice 0.22.5 teardown (2026-11-19)

Source: `/Applications/Aqua Voice.app` (bundle id `com.electron.aqua-voice`). Static analysis only; Aqua was not run.
No Aqua code, assets, endpoints or credentials are used in Speak. Speak is a clean-room native rebuild of the dictation behaviour.

## Evidence

- REA `analyze_javascript_application` on `app.asar` (sha256 `106ae8e0…52e7`): parent evidence
  `ev_160fad93bf495a39a08b9c75e956e43afd619711c6e3683f4275e7cf5f9e81da`. 192 files inventoried. The two main
  webpack bundles (main 3.9 MB, renderer 5.5 MB) exceeded the analyzer's 1 GiB heap, so they were read directly
  from the extracted asar.
- REA recorded 4 asar-integrity contradictions on the native `.node` modules (liquid glass, share picker, window chrome,
  translate camera). Their bytes differ from the asar header hashes. That is unexplained: possibly a post-pack re-sign.

## Architecture (observed)

- **Shell:** Electron ~42.10 with Electron Forge, webpack, React 18 and Radix. Squirrel auto-update. Sentry and PostHog for telemetry.
- **Native helper:** `Resources/resources/AquaMacOSBridge.app` (Swift, LSUIElement), 11 MB, plus the bundled
  `AquaFluidAudio.framework` (31 MB). The symbols show `CGEventTap` hotkeys (Cancel, PasteLast, PickUpPen,
  RecordMeeting), `GlobeSystemActionController` and `SystemGlobeFnUsageController` (it rewrites the 🌐 key's system
  action), `PasteChangeApplier` and `Clipboard` with an `avoidClipboardHistory` option, and AX text scraping including
  `GoogleDocsCaretContextProbe`, Chromium caret mapping, and a "Codex-style" accessibility-tree projection used for
  computer control.
- **Audio:** `assets/audio-processor.js` is an AudioWorklet that runs at 16 kHz in 100 ms chunks. It uses
  `internalBuffer.push(...input)` and `slice()` on every render quantum, so it reallocates constantly. Audio is encoded
  with `opusscript` (WASM).
- **ASR:** `wss://realtime.aquavoice.com` with a `token` query parameter and protocols such as `live_stream_captions`.
  Message types include `refinement`, `timing_details`, `set_streaming` and `live_stream_translation_*`. History
  re-transcription re-uploads the WAV. The REST API is `core.aquavoice.com` / `api.aquavoice.com`.
- **Non-dictation features (dropped in Speak):** meetings (92 IPC channels: calendar, people, folders, notes, PDF
  export, sharing); "pen" screen annotation overlay ("Draw on your screen and share a screenshot"); screenshots;
  realtime translation; a virtual camera system extension; MCP; a CLI; a mobile tie-in; stats cards.

## What Speak changes and why

1. **No Electron.** All the dictation work happens natively already, so the Chromium layer is pure overhead (572 MB → 1.3 MB).
2. **On-device ASR (SpeechAnalyzer, macOS 26).** Removes the network round trip, the account, the outage risk and the privacy exposure.
   Vocabulary biasing goes through `AnalysisContext.contextualStrings`.
3. **Zero-loss start.** Audio is queued into the analyzer's input stream before the analyzer finishes starting, and
   the model is retained for the life of the process (`modelRetention: .processLifetime`).
4. **Insertion.** Speak tries a direct AX `kAXSelectedTextAttribute` write first, verified by character count, and
   skips it for Chromium/Electron/terminal apps. Otherwise it pastes with the `org.nspasteboard.TransientType` marker
   and restores the clipboard.
5. **Gesture machine.** Hold, double-tap and Esc, plus chord detection, so `fn+arrow` never dictates. Unit tested.
6. **Deterministic cleanup** instead of a server LLM pass: fillers, scratch that, new line/paragraph, replacements, sentence casing, and
   caret-aware spacing and capitalization (SmartJoin).
