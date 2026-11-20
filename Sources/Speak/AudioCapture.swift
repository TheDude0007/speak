import AVFoundation
import Accelerate

/// Microphone -> analyzer format, straight from the AVAudioEngine render thread.
/// (Aqua does this in a Web Audio worklet with array spread/slice copies per
/// 128-sample block, then Opus-encodes in WASM and ships it to a server. Here it is
/// one hardware-rate tap, one vDSP RMS, one AVAudioConverter call, zero network.)
///
/// Two modes:
/// * on-demand (default): the mic opens on key-down and closes on release.
/// * instant start: the mic stays open and the last ~0.5 s is kept in memory, so
///   speech that began a split second *before* the key press is captured too.
///   Nothing is stored or sent while idle; the macOS mic indicator stays on.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var running = false
    private var target: AVAudioFormat?

    private let lock = NSLock()
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    var prerollSeconds: Double = 0.5
    var keepPreroll = false

    var onLevel: ((Float) -> Void)?   // 0...1, called on render thread

    func start(target: AVAudioFormat) throws {
        if running, self.target == target { return }
        if running { stop() }
        self.target = target
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Speak", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        converter = inFormat != target ? AVAudioConverter(from: inFormat, to: target) : nil
        Log.write("audio: input \(inFormat) -> \(target), converter=\(converter != nil)")
        let ratio = target.sampleRate / inFormat.sampleRate

        // ~20 ms at 48 kHz: low latency without excess wakeups.
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let live = self.lock.withLock { self.consumer != nil }
            if live, let ch = buffer.floatChannelData?[0], let onLevel = self.onLevel {
                var rms: Float = 0
                vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
                let db = 20 * log10(max(rms, 1e-7))   // -50..-5 dBFS -> 0..1
                onLevel(min(max((db + 50) / 45, 0), 1))
            }
            var outBuf = buffer
            if let converter = self.converter {
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard err == nil, out.frameLength > 0 else { return }
                outBuf = out
            }
            self.route(outBuf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    private func route(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        if let consumer {
            lock.unlock()
            consumer(buf)
            return
        }
        if keepPreroll, let target {
            preroll.append(buf)
            prerollFrames += buf.frameLength
            let maxFrames = AVAudioFrameCount(target.sampleRate * prerollSeconds)
            while prerollFrames > maxFrames, let first = preroll.first {
                prerollFrames -= first.frameLength
                preroll.removeFirst()
            }
        }
        lock.unlock()
    }

    /// Start delivering audio to `consumer`, beginning with any buffered pre-roll.
    func attach(_ consumer: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let backlog = preroll
        preroll.removeAll(); prerollFrames = 0
        // Deliver backlog before going live; the render thread blocks on `lock` meanwhile, so order is preserved.
        for b in backlog { consumer(b) }
        self.consumer = consumer
        lock.unlock()
    }

    func detach() {
        lock.withLock {
            consumer = nil
            preroll.removeAll(); prerollFrames = 0
        }
    }

    func stop() {
        detach()
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter?.reset()
        running = false
    }
}
