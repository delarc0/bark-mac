import AVFoundation
import BarkCore

/// Turns hardware buffers into 16 kHz mono Float32. One instance per capture format, used only on
/// the capture thread.
final class MonoResampler: @unchecked Sendable {
    enum Output {
        case samples([Float], peak: Float)
        /// The device changed rate under the tap; converting on would pitch-shift the rest.
        case rateChanged
    }

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let inputRate: Double
    private let monoFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var selector: ChannelSelector
    private var rateChangeReported = false

    init?(inputRate: Double, channels: Int) {
        // The converter only ever resamples mono: asked to downmix a multichannel interface it
        // returns digital zero without an error (a 12-channel Audient iD14, every input live).
        guard inputRate > 0, channels > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: Self.targetFormat) else { return nil }
        self.inputRate = inputRate
        monoFormat = mono
        self.converter = converter
        selector = ChannelSelector(channels: channels)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Output? {
        guard buffer.format.sampleRate == inputRate else {
            defer { rateChangeReported = true }
            return rateChangeReported ? nil : .rateChanged
        }
        guard let (mono, peak) = mixToMono(buffer) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.targetFormat.sampleRate / inputRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, error == nil, let data = out.floatChannelData?[0] else { return nil }
        return .samples(Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))), peak: peak)
    }

    /// The selected channel, or the sum of all until one qualifies. The peak is taken here, before
    /// the converter, so a hot signal reads as hot to the meter and the dead-input check.
    private func mixToMono(_ input: AVAudioPCMBuffer) -> (AVAudioPCMBuffer, Float)? {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames > 0, let source = input.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength),
              let dest = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = input.frameLength
        // An interleaved buffer exposes one pointer holding every channel.
        let interleaved = input.format.isInterleaved
        func sample(_ channel: Int, _ frame: Int) -> Float {
            interleaved ? source[0][frame * channels + channel] : source[channel][frame]
        }

        var peaks = [Float](repeating: 0, count: channels)
        for c in selector.candidates {
            for i in 0 ..< frames { peaks[c] = max(peaks[c], abs(sample(c, i))) }
        }
        if let channel = selector.update(peaks) {
            for i in 0 ..< frames { dest[i] = sample(channel, i) }
        } else {
            for i in 0 ..< frames { dest[i] = (0 ..< channels).reduce(0) { $0 + sample($1, i) } }
        }
        var peak: Float = 0
        for i in 0 ..< frames { peak = max(peak, abs(dest[i])) }
        return (mono, peak)
    }
}
