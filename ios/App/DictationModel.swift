import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Same pipeline as the Mac app: on-device SpeechAnalyzer -> TextCleaner ->
/// Apple Intelligence grammar (or optional Claude) -> clipboard + keyboard.
@MainActor
final class DictationModel: ObservableObject {
    enum Phase { case preparing, ready, recording, finishing, failed }

    @Published var phase: Phase = .preparing
    @Published var status = "Preparing…"
    @Published var live = ""
    @Published var result = ""
    @Published var level: CGFloat = 0
    @Published var lastMs: Int?
    @Published var recent: [SharedStore.Item] = SharedStore.recent()

    @AppStorage("smartGrammar") var smartGrammar = true
    @AppStorage("removeFillers") var removeFillers = true
    @AppStorage("autoCopy") var autoCopy = true
    @AppStorage("aiPolish") var aiPolish = false

    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private var session: DictationSession?
    private var pressStart: Date?

    var isRecording: Bool { phase == .recording }
    var grammarNote: String? { SmartGrammar.shared.unavailableReason }

    init() {
        engine.onStateChange = { [weak self] s in
            guard let self else { return }
            switch s {
            case .idle: break
            case .preparing(let m): self.status = m; self.phase = .preparing
            case .ready: self.status = "Ready — on-device"; if self.phase == .preparing { self.phase = .ready }
            case .failed(let m): self.status = m; self.phase = .failed
            }
        }
    }

    func prepare() async {
        _ = await AVAudioApplication.requestRecordPermission()
        _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        if smartGrammar { SmartGrammar.shared.prewarm() }
        let ai = (smartGrammar && SmartGrammar.shared.isAvailable) || (aiPolish && Keychain.apiKey != nil)
        await engine.prepare(aiPunctuation: ai)
    }

    func reloadEngine() { Task { await prepare() } }

    // MARK: gestures — press and hold = push-to-talk; quick tap = hands-free, tap again to finish

    func pressBegan() {
        if isRecording { return }
        pressStart = Date()
        start()
    }

    func pressEnded() {
        guard let t = pressStart else {   // tap while hands-free
            if isRecording { finish() }
            return
        }
        pressStart = nil
        if Date().timeIntervalSince(t) > 0.4 { finish() }   // held: push-to-talk
        // short tap: keep listening (hands-free)
    }

    func start() {
        guard phase == .ready, let s = engine.makeSession(vocabulary: []) else { return }
        do {
            let av = AVAudioSession.sharedInstance()
            try av.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try av.setActive(true, options: [])
            try audio.start(target: s.format)
        } catch {
            s.cancel(); status = "Mic error: \(error.localizedDescription)"; return
        }
        s.onPartial = { [weak self] text in Task { @MainActor in self?.live = text } }
        audio.onLevel = { [weak self] v in Task { @MainActor in self?.level = CGFloat(v) } }
        audio.attach { [weak s] buf in s?.feed(buf) }
        session = s
        live = ""
        phase = .recording
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func finish() {
        guard let s = session else { return }
        session = nil
        pressStart = nil
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .finishing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let t0 = Date()
        Task {
            let raw = await s.finish()
            var o = TextCleaner.Options()
            o.removeFillers = removeFillers
            var text = TextCleaner(options: o).clean(raw)
            var byClaude = false
            if !text.isEmpty, aiPolish, let p = try? await Polisher.polish(text, appName: nil) { text = p; byClaude = true }
            if !text.isEmpty, !byClaude, smartGrammar, let fixed = await SmartGrammar.shared.correct(text) { text = fixed }
            else if !text.isEmpty, !byClaude, engine.aiPunctuation, let last = text.last, !".!?…:;\"”)".contains(last) { text += "." }
            lastMs = Int(Date().timeIntervalSince(t0) * 1000)
            phase = .ready
            live = ""
            guard !text.isEmpty else { return }
            result = text
            SharedStore.add(text)
            recent = SharedStore.recent()
            if autoCopy { UIPasteboard.general.string = text }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func cancel() {
        session?.cancel(); session = nil
        audio.stop()
        phase = .ready
        live = ""
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
