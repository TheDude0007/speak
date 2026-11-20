import AVFoundation
import Speech

/// On-device transcription via macOS 26 SpeechAnalyzer.
/// The model is loaded once and retained for the life of the process, so every
/// dictation after launch starts warm. No audio ever leaves the machine.
final class SpeechEngine {
    enum State { case idle, preparing(String), ready, failed(String) }

    private(set) var state: State = .idle
    private(set) var locale: Locale = .current
    private(set) var analyzerFormat: AVAudioFormat?
    private var useSpeechTranscriber = true
    private var warmAnalyzer: SpeechAnalyzer?

    var onStateChange: ((State) -> Void)?

    private func set(_ s: State) {
        state = s
        DispatchQueue.main.async { self.onStateChange?(s) }
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    private func makeModule() -> any SpeechModule {
        if useSpeechTranscriber {
            return SpeechTranscriber(locale: locale,
                                     transcriptionOptions: [],
                                     reportingOptions: [.volatileResults, .fastResults],
                                     attributeOptions: [])
        }
        return DictationTranscriber(locale: locale,
                                    contentHints: [],
                                    transcriptionOptions: [.punctuation],
                                    reportingOptions: [.volatileResults, .frequentFinalization],
                                    attributeOptions: [])
    }

    static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    func prepare(preferred: Locale = .current) async {
        set(.preparing("Checking speech model…"))
        useSpeechTranscriber = SpeechTranscriber.isAvailable
        let resolved: Locale?
        if useSpeechTranscriber {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        } else {
            resolved = await DictationTranscriber.supportedLocale(equivalentTo: preferred)
        }
        guard let resolved else {
            set(.failed("Language \(preferred.identifier) is not supported on-device."))
            return
        }
        locale = resolved
        let module = makeModule()
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                set(.preparing("Downloading speech model (one time)…"))
                try await request.downloadAndInstall()
            }
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            // Warm-up: load the model now so the first key press has no cold start.
            let analyzer = SpeechAnalyzer(modules: [module], options: Self.options)
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            warmAnalyzer = analyzer
            set(.ready)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    func makeSession(vocabulary: [String]) -> DictationSession? {
        guard isReady, let analyzerFormat else { return nil }
        let module = makeModule()
        return DictationSession(module: module, format: analyzerFormat, vocabulary: vocabulary)
    }

    var engineName: String { useSpeechTranscriber ? "SpeechTranscriber" : "DictationTranscriber" }
}

/// One press-to-release dictation. Audio may be fed before the analyzer finishes
/// starting; the stream buffers it, so no leading syllables are lost.
final class DictationSession {
    let format: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var runTask: Task<Void, Never>!
    private var resultsTask: Task<Void, Never>!

    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""

    /// Called on an arbitrary thread with the full live transcript (final + volatile).
    var onPartial: ((String) -> Void)?

    init(module: any SpeechModule, format: AVAudioFormat, vocabulary: [String]) {
        self.format = format
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        analyzer = SpeechAnalyzer(modules: [module], options: SpeechEngine.options)

        let results: AsyncThrowingStream<(String, Bool), Error> = Self.results(of: module)
        resultsTask = Task { [weak self] in
            do {
                for try await (text, isFinal) in results {
                    self?.ingest(text, isFinal: isFinal)
                }
            } catch {}
        }

        let analyzer = self.analyzer
        runTask = Task {
            if !vocabulary.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(ctx)
            }
            try? await analyzer.start(inputSequence: stream)
        }
    }

    private static func results(of module: any SpeechModule) -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if let t = module as? SpeechTranscriber {
                        for try await r in t.results { cont.yield((String(r.text.characters), r.isFinal)) }
                    } else if let t = module as? DictationTranscriber {
                        for try await r in t.results { cont.yield((String(r.text.characters), r.isFinal)) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func ingest(_ text: String, isFinal: Bool) {
        lock.lock()
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        let live = Self.join(finalized, volatile)
        lock.unlock()
        onPartial?(live)
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b.trimmingCharacters(in: .whitespaces) }
        if b.isEmpty { return a }
        if a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
        return a + " " + b
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// End of speech: flush the model and return the final transcript.
    func finish() async -> String {
        continuation.finish()
        await runTask.value
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask.value
        return lock.withLock { Self.join(finalized, volatile) }
    }

    func cancel() {
        continuation.finish()
        let analyzer = self.analyzer
        let rt = resultsTask
        Task {
            await analyzer.cancelAndFinishNow()
            rt?.cancel()
        }
    }
}
