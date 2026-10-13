import AVFoundation
@testable import BarkCapture
import Foundation
import Testing

struct ResamplerTests {
    /// A buffer of `seconds` at `rate` with a 440 Hz tone at `amplitude[c]` on channel c.
    static func buffer(rate: Double, amplitudes: [Float], seconds: Double = 0.1, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(amplitudes.count))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for i in 0 ..< Int(frames) {
            let s = Float(sin(2 * Double.pi * 440 * Double(i) / rate))
            for (c, a) in amplitudes.enumerated() {
                if interleaved { data[0][i * amplitudes.count + c] = s * a } else { data[c][i] = s * a }
            }
        }
        return buffer
    }

    static func samples(_ output: MonoResampler.Output?) -> (samples: [Float], peak: Float)? {
        if case .samples(let samples, let peak) = output { return (samples, peak) }
        return nil
    }

    @Test(arguments: [false, true])
    func multichannelInterfaceIsNotDigitalZero(interleaved: Bool) throws {
        let resampler = try #require(MonoResampler(inputRate: 48_000, channels: 12))
        var amplitudes = [Float](repeating: 0, count: 12)
        amplitudes[0] = 0.3
        var out: [Float] = []
        for _ in 0 ..< 5 {
            out += try #require(Self.samples(resampler.process(Self.buffer(rate: 48_000, amplitudes: amplitudes, interleaved: interleaved)))).samples
        }
        #expect(abs(out.count - 8_000) < 300)
        #expect((out.map(abs).max() ?? 0) > 0.2)
    }

    @Test func voiceChannelWinsOverLoopback() throws {
        let resampler = try #require(MonoResampler(inputRate: 48_000, channels: 4))
        let out = try #require(Self.samples(resampler.process(Self.buffer(rate: 48_000, amplitudes: [0.1, 0, 0, 0.9]))))
        // Channel 0 alone, not the 1.0 sum with the loopback.
        #expect(abs(out.peak - 0.1) < 0.01)
    }

    @Test func rateChangeStopsConversionOnce() throws {
        let resampler = try #require(MonoResampler(inputRate: 44_100, channels: 1))
        let changed = Self.buffer(rate: 48_000, amplitudes: [0.3])
        guard case .rateChanged = resampler.process(changed) else {
            Issue.record("a 48 kHz buffer on a 44.1 kHz capture must not be converted")
            return
        }
        #expect(resampler.process(changed) == nil)
    }

    @Test func silenceStaysSilentWithZeroPeak() throws {
        let resampler = try #require(MonoResampler(inputRate: 16_000, channels: 1))
        let out = try #require(Self.samples(resampler.process(Self.buffer(rate: 16_000, amplitudes: [0]))))
        #expect(out.peak == 0)
    }
}
