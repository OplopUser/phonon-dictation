import AVFoundation

/// Records the microphone as 16 kHz mono and hands each block of samples to `onSamples`.
/// The first `muteSeconds` come through as silence, so the mic doesn't pick up the start sound.
final class Recorder {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let onSamples: ([Float]) -> Void
    private var samplesToMute: Int

    init(muteSeconds: Double = 0, onSamples: @escaping ([Float]) -> Void) {
        self.samplesToMute = Int(muteSeconds * Self.sampleRate)
        self.onSamples = onSamples
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        converter.downmix = true
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            var samples = self.convert(buffer)
            if self.samplesToMute > 0 {
                let count = min(self.samplesToMute, samples.count)
                samples.replaceSubrange(0..<count, with: repeatElement(0, count: count))
                self.samplesToMute -= count
            }
            self.onSamples(samples)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
