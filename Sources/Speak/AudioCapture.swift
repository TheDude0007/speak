import AVFoundation
import Accelerate

/// Microphone -> analyzer format, straight from the AVAudioEngine render thread.
/// (Aqua does this in a Web Audio worklet with array spread/slice copies per
/// 128-sample block, then Opus-encodes in WASM and ships it to a server. Here it is
/// one hardware-rate tap, one vDSP RMS, one AVAudioConverter call, zero network.)
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var running = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?   // 0...1, called on render thread

    func start(target: AVAudioFormat) throws {
        guard !running else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Speak", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        let needsConvert = inFormat != target
        converter = needsConvert ? AVAudioConverter(from: inFormat, to: target) : nil
        let ratio = target.sampleRate / inFormat.sampleRate

        // ~20 ms at 48 kHz: low latency without excess wakeups.
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let ch = buffer.floatChannelData?[0], let onLevel = self.onLevel {
                var rms: Float = 0
                vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
                // perceptual-ish mapping: -50 dBFS..-5 dBFS -> 0..1
                let db = 20 * log10(max(rms, 1e-7))
                onLevel(min(max((db + 50) / 45, 0), 1))
            }
            guard let converter = self.converter else {
                self.onBuffer?(buffer)
                return
            }
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
            if err == nil, out.frameLength > 0 { self.onBuffer?(out) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter?.reset()
        running = false
    }
}
