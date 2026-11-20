import AppKit
@preconcurrency import AVFoundation
import Speech
import ServiceManagement
import SpeakCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store.shared
    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private let tap = HotkeyTap()
    private let hud = HUD()
    private var machine = HotkeyMachine()
    private var session: DictationSession?
    private var tapTimer: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    private var engineStatus = "Starting…"
    private var lastLatencyMs: Int?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onStateChange = { [weak self] s in
            guard let self else { return }
            switch s {
            case .idle: self.engineStatus = "Idle"
            case .preparing(let m): self.engineStatus = m
            case .ready: self.engineStatus = "Ready — on-device (\(self.engine.locale.identifier))"; self.armInstantStart()
            case .failed(let m): self.engineStatus = "Speech error: \(m)"; self.hud.flash(m, seconds: 5)
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }
        reloadEngine()

        wireHotkey()
        if !Inserter.isTrusted {
            Inserter.promptForTrust()
            pollForTrust()
        }
        hud.model.showText = store.liveText
    }

    private func pollForTrust() {
        // Event taps can't be created until Accessibility is granted; retry quietly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if Inserter.isTrusted { self.wireHotkey() } else { self.pollForTrust() }
        }
    }

    private func wireHotkey() {
        tap.key = store.hotkey
        tap.onDown = { [weak self] in self?.dispatch { $0.keyDown(at: CACurrentMediaTime()) } }
        tap.onUp = { [weak self] in self?.dispatch { $0.keyUp(at: CACurrentMediaTime()) } }
        tap.onOtherKey = { [weak self] in self?.dispatch { $0.otherKeyDown() } }
        tap.onEscape = { [weak self] in self?.dispatch { $0.escape() } }
        tap.start()
    }

    private func dispatch(_ f: (inout HotkeyMachine) -> [HotkeyMachine.Action]) {
        for action in f(&machine) {
            switch action {
            case .start: beginDictation()
            case .commit: commitDictation()
            case .cancel: cancelDictation()
            case .scheduleTapTimeout(let dt):
                tapTimer?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.dispatch { $0.tapTimeout() } }
                tapTimer = w
                DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: w)
            }
        }
        if machine.state == .handsFree, session != nil, hud.model.mode == .listening {
            hud.model.mode = .handsFree
        }
    }

    // MARK: dictation

    private func beginDictation() {
        guard session == nil else { return }
        guard let s = engine.makeSession(vocabulary: store.dictionary().vocabulary) else {
            machine.reset()
            hud.flash(engineStatus)
            return
        }
        s.onPartial = { [weak self] text in self?.hud.pushText(text) }
        audio.onLevel = { [weak self] v in self?.hud.pushLevel(v) }
        do {
            try audio.start(target: s.format)
            audio.attach { [weak s] buf in s?.feed(buf) }
        } catch {
            s.cancel()
            machine.reset()
            hud.flash("Mic error: \(error.localizedDescription)")
            return
        }
        session = s
        setIcon(recording: true)
        hud.show(.listening)
        if store.sounds { play("Tink") }
    }

    private func commitDictation() {
        guard let s = session else { return }
        session = nil
        releaseMic()
        setIcon(recording: false)
        hud.show(.finishing, text: hud.model.text)
        let t0 = CACurrentMediaTime()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        Task { @MainActor in
            let raw = await s.finish()
            let cleaned = TextCleaner(options: store.cleanerOptions()).clean(raw)
            guard !cleaned.isEmpty else { hud.hide(); return }
            var polished = cleaned
            var polishedByClaude = false
            if store.aiPolish {
                hud.show(.finishing, text: "Polishing…")
                do { polished = try await Polisher.polish(cleaned, appName: app); polishedByClaude = true }
                catch { hud.pushText("AI polish skipped — using on-device grammar") }
            }
            if !polishedByClaude, store.smartGrammar, let fixed = await SmartGrammar.shared.correct(cleaned) {
                polished = fixed
            } else if !polishedByClaude, engine.aiPunctuation, let last = polished.last, !".!?…:;\"”)".contains(last) {
                polished += "."   // dictation engine leaves the final sentence open
            }
            var out = polished
            if store.smartSpacing { out = SmartJoin.adapt(cleaned, after: Inserter.textBeforeCaret()) }
            Inserter.insert(out)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            lastLatencyMs = ms
            store.add(.init(date: Date(), text: polished, raw: raw, latencyMs: ms, app: app))
            hud.hide(after: 0.05)
        }
    }

    private func cancelDictation() {
        tapTimer?.cancel()
        guard let s = session else { return }
        session = nil
        releaseMic()
        s.cancel()
        setIcon(recording: false)
        hud.hide()
    }

    private var wantsAIPunctuation: Bool {
        (store.smartGrammar && SmartGrammar.shared.isAvailable) || (store.aiPolish && Keychain.apiKey != nil)
    }

    private func reloadEngine() {
        let ai = wantsAIPunctuation
        if store.smartGrammar { SmartGrammar.shared.prewarm() }
        Task { await engine.prepare(aiPunctuation: ai) }
    }

    // MARK: mic modes

    private func releaseMic() {
        if store.instantStart { audio.detach() } else { audio.stop() }
    }

    /// Instant start: keep the mic open with a 0.5 s rolling pre-roll so the first
    /// syllable is never clipped, even if you start talking as you press the key.
    private func armInstantStart() {
        audio.keepPreroll = store.instantStart
        guard store.instantStart, session == nil, let fmt = engine.analyzerFormat else {
            if !store.instantStart, session == nil { audio.stop() }
            return
        }
        do { try audio.start(target: fmt) } catch { hud.flash("Mic error: \(error.localizedDescription)") }
    }

    // MARK: UI helpers

    private func play(_ name: String) {
        guard let snd = NSSound(named: NSSound.Name(name)) else { return }
        snd.volume = 0.25
        snd.play()
    }

    private func setIcon(recording: Bool) {
        let img = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Speak")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ sel: Selector?, key: String = "", state: Bool? = nil, obj: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let state { i.state = state ? .on : .off }
            i.representedObject = obj
            return i
        }
        let header = item("Speak — \(engineStatus)", nil)
        header.isEnabled = false
        menu.addItem(header)
        if !Inserter.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility access…", #selector(openAXSettings)))
        }
        if let ms = lastLatencyMs {
            let l = item("Last: \(ms) ms from key-up to text", nil); l.isEnabled = false
            menu.addItem(l)
        }
        menu.addItem(.separator())

        let keyMenu = NSMenu()
        for k in HotkeyKey.allCases {
            keyMenu.addItem(item(k.title, #selector(pickHotkey(_:)), state: k == store.hotkey, obj: k.rawValue))
        }
        let keyItem = item("Dictation key", nil); keyItem.submenu = keyMenu
        menu.addItem(keyItem)
        let hint = item("Hold to talk · double-tap for hands-free · Esc cancels", nil); hint.isEnabled = false
        menu.addItem(hint)
        if store.hotkey == .fn {
            menu.addItem(item("Stop 🌐 key opening emoji/dictation", #selector(fixGlobeKey)))
        }
        menu.addItem(.separator())

        let sg = item("Smart grammar & punctuation (on-device AI)", #selector(toggle(_:)), state: store.smartGrammar, obj: "smartGrammar")
        if let why = SmartGrammar.shared.unavailableReason { sg.title += " — \(why)"; sg.isEnabled = false }
        menu.addItem(sg)
        menu.addItem(item("Remove filler words (um, uh)", #selector(toggle(_:)), state: store.removeFillers, obj: "removeFillers"))
        menu.addItem(item("Smart spacing & capitals", #selector(toggle(_:)), state: store.smartSpacing, obj: "smartSpacing"))
        menu.addItem(item("Show live transcript", #selector(toggle(_:)), state: store.liveText, obj: "liveText"))
        menu.addItem(item("Sounds", #selector(toggle(_:)), state: store.sounds, obj: "sounds"))
        menu.addItem(item("Keep history", #selector(toggle(_:)), state: store.keepHistory, obj: "keepHistory"))
        menu.addItem(item("Edit dictionary & replacements…", #selector(openDictionary)))
        menu.addItem(.separator())
        menu.addItem(item("Instant start (mic stays ready)", #selector(toggle(_:)), state: store.instantStart, obj: "instantStart"))
        menu.addItem(item("AI polish with Claude (sends text, not audio)", #selector(toggle(_:)), state: store.aiPolish, obj: "aiPolish"))
        menu.addItem(item(Keychain.apiKey == nil ? "Set Claude API key…" : "Change Claude API key…", #selector(setAPIKey)))
        menu.addItem(.separator())

        let hist = NSMenu()
        if store.history.isEmpty {
            let e = item("Nothing yet", nil); e.isEnabled = false; hist.addItem(e)
        } else {
            for e in store.history.prefix(15) {
                let t = e.text.replacingOccurrences(of: "\n", with: " ")
                hist.addItem(item(t.count > 60 ? String(t.prefix(60)) + "…" : t, #selector(copyHistory(_:)), obj: e.text))
            }
            hist.addItem(.separator())
            hist.addItem(item("Clear history", #selector(clearHistory)))
        }
        let histItem = item("Recent (click to copy)", nil); histItem.submenu = hist
        menu.addItem(histItem)
        menu.addItem(item("Paste last transcript", #selector(pasteLast), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Open at login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Quit Speak", #selector(quit), key: "q"))
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = HotkeyKey(rawValue: raw) else { return }
        store.hotkey = k
        cancelDictation(); machine.reset()
        wireHotkey()
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let v = !store.bool(key, default: !["aiPolish", "instantStart"].contains(key))
        UserDefaults.standard.set(v, forKey: key)
        if key == "liveText" { hud.model.showText = v }
        if key == "instantStart" { armInstantStart() }
        if (key == "smartGrammar" || key == "aiPolish"), session == nil, wantsAIPunctuation != engine.aiPunctuation { reloadEngine() }
        if key == "aiPolish", v, Keychain.apiKey == nil { setAPIKey() }
    }

    @objc private func fixGlobeKey() {
        // Same system setting as Keyboard > "Press 🌐 key to: Do Nothing".
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
        try? p.run(); p.waitUntilExit()
        hud.flash("🌐 key set to “Do Nothing”. Log out/in if the emoji picker still appears.", seconds: 4)
    }

    @objc private func openAXSettings() {
        Inserter.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openDictionary() {
        _ = store.dictionary()
        NSWorkspace.shared.open(store.dictionaryURL)
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func pasteLast() {
        guard let t = store.history.first?.text else { return }
        // Let the menu close and focus return to the target app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Inserter.insert(t) }
    }

    @objc private func clearHistory() { store.clearHistory() }

    @objc private func setAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Used only for the optional AI polish. Stored in your macOS Keychain. Leave blank to remove."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.apiKey = key.isEmpty ? nil : key
        if key.isEmpty { store.aiPolish = false }
        if session == nil, wantsAIPunctuation != engine.aiPunctuation { reloadEngine() }
        hud.flash(key.isEmpty ? "API key removed" : "API key saved to Keychain")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { hud.flash("Login item: \(error.localizedDescription)") }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Headless self-test: `Speak --transcribe file.wav` runs the exact dictation
/// pipeline (session -> cleaner) on a file, fed in 20 ms chunks like the mic.
func runHeadless(_ path: String, realtime: Bool) async {
    let engine = SpeechEngine()
    let t0 = CACurrentMediaTime()
    await engine.prepare(aiPunctuation: SmartGrammar.shared.isAvailable)
    let tPrep = CACurrentMediaTime()
    guard engine.isReady, let session = engine.makeSession(vocabulary: Store.shared.dictionary().vocabulary) else {
        print("engine not ready: \(engine.state)"); exit(1)
    }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = session.format
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.02)
        while file.framePosition < file.length {
            let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
            try file.read(into: inBuf, frameCount: chunk)
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * target.sampleRate / file.processingFormat.sampleRate) + 64)!
            var fed = false
            conv.convert(to: out, error: nil) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return inBuf
            }
            session.feed(out)
            if realtime { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        let tEnd = CACurrentMediaTime()
        let raw = await session.finish()
        let tDone = CACurrentMediaTime()
        let cleaned = TextCleaner(options: Store.shared.cleanerOptions()).clean(raw)
        print("engine: \(engine.engineName) locale=\(engine.locale.identifier) format=\(target)")
        print("prepare: \(Int((tPrep - t0) * 1000)) ms   finalize after end-of-audio: \(Int((tDone - tEnd) * 1000)) ms")
        print("RAW:     \(raw)")
        print("CLEANED: \(cleaned)")
        SmartGrammar.shared.prewarm()
        let tG = CACurrentMediaTime()
        if let fixed = await SmartGrammar.shared.correct(cleaned) {
            print("GRAMMAR: \(fixed)   [\(Int((CACurrentMediaTime() - tG) * 1000)) ms]")
        } else {
            print("GRAMMAR: (no change / unavailable: \(SmartGrammar.shared.unavailableReason ?? "-"))")
        }
        exit(0)
    } catch {
        print("error: \(error)"); exit(1)
    }
}

if CommandLine.arguments.contains("--cmdv-keycode") {
    print("Cmd+V key code for current layout: \(Inserter.commandVKeyCode())")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let rt = CommandLine.arguments.contains("--realtime")
    Task { await runHeadless(path, realtime: rt) }
    dispatchMain()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
