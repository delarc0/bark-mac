import BarkCore
import Testing

struct ChannelSelectorTests {
    /// Per-buffer peaks for an 8-channel interface: `voice` on channel 0, `loopback` on channel 7.
    static func buffer(voice: Float, loopback: Float) -> [Float] {
        [voice, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001, loopback]
    }

    @Test func monoIsAlwaysChannelZero() {
        var selector = ChannelSelector(channels: 1)
        #expect(selector.update([0]) == 0)
    }

    @Test func sumsUntilAChannelReachesSpeechLevel() {
        var selector = ChannelSelector(channels: 8)
        #expect(selector.update(Self.buffer(voice: 0.005, loopback: 0.01)) == nil)
    }

    @Test func loopbackLosesToTheVoiceAndNeverWinsBack() {
        var selector = ChannelSelector(channels: 8)
        // Music on the loopback before anyone speaks.
        #expect(selector.update(Self.buffer(voice: 0.003, loopback: 0.4)) == 7)
        #expect(selector.update(Self.buffer(voice: 0.1, loopback: 0.4)) == 0)
        // Louder music afterwards changes nothing.
        #expect(selector.update(Self.buffer(voice: 0.004, loopback: 0.9)) == 0)
    }

    @Test func lowestQualifyingChannelBeatsTheLoudest() {
        var selector = ChannelSelector(channels: 4)
        #expect(selector.update([0.0, 0.05, 0.8, 0.0]) == 1)
    }

    @Test func aQuietVoiceLatchesOnItsRunningPeak() {
        var selector = ChannelSelector(channels: 2)
        #expect(selector.update([0.015, 0.0]) == nil)
        #expect(selector.update([0.021, 0.0]) == 0)
    }
}

struct InputHealthTests {
    @Test func noCallbacksIsTransientNotDead() {
        #expect(InputHealth.classify(frames: 0, peak: 0) == .noCallbacks)
    }

    @Test func digitalSilenceIsADeadInput() {
        #expect(InputHealth.classify(frames: 16_000, peak: 0) == .silent)
        #expect(InputHealth.classify(frames: 16_000, peak: 0.0004) == .silent)
    }

    @Test func roomNoiseIsALiveInput() {
        #expect(InputHealth.classify(frames: 16_000, peak: 0.002) == .ok)
    }
}

struct LegacySettingsTests {
    @Test func absentOrEmptyIsAuto() {
        #expect(LegacySettings.language(nil) == .auto)
        #expect(LegacySettings.language("") == .auto)
    }

    @Test func storedCodesCarryOver() {
        #expect(LegacySettings.language("sv") == .explicit("sv"))
        #expect(LegacySettings.language("en") == .explicit("en"))
    }

    @Test func norwegianBecomesWhispersCode() {
        #expect(LegacySettings.language("nb") == .explicit("no"))
    }
}
