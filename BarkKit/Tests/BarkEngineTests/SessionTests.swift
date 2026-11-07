import BarkCore
@testable import BarkEngine
import Foundation
import Testing

struct WorkerTests {
    @Test func timedOutJobIsAbandoned() async throws {
        let worker = MLXWorker()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TranscriberError.self) {
            try await worker.run(timeout: 0.1) { Thread.sleep(forTimeInterval: 1); return 1 }
        }
        #expect(clock.now - start < .milliseconds(900))
        #expect(try await worker.run(timeout: 5) { 2 } == 2) // queued behind the abandoned job, then runs
    }

    @Test func everyTranscriberSharesOneQueueAndGate() async {
        let a = Transcriber(general: URL(filePath: "/a"), swedish: nil, vad: URL(filePath: "/a"))
        let b = Transcriber(general: URL(filePath: "/b"), swedish: nil, vad: URL(filePath: "/b"))
        #expect(await a.worker === b.worker)
        #expect(await a.gate === b.gate)
    }
}

struct SessionTests {
    @Test func sessionBeforeStartThrows() async {
        let transcriber = Transcriber(general: URL(filePath: "/nonexistent"), swedish: nil, vad: URL(filePath: "/nonexistent"))
        await #expect(throws: TranscriberError.self) { try await transcriber.makeSession(language: .auto) }
    }

    /// A missing Silero model is an error, never a download: start() fails before any model loads.
    @Test func missingSileroFailsWithoutFetching() async {
        let transcriber = Transcriber(general: URL(filePath: "/nonexistent"), swedish: nil, vad: URL(filePath: "/nonexistent"))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: (any Error).self) { try await transcriber.start() }
        #expect(clock.now - start < .seconds(2))
    }

    @Test(.enabled(if: Fixtures.vadInstalled))
    func sileroLoadsFromTheGivenFolder() throws {
        _ = try Transcriber.loadVAD(Fixtures.vadFolder)
    }

    @Test(.enabled(if: Fixtures.clipsInstalled))
    func cancelAbandonsTheDictation() async throws {
        let session = try await Fixtures.transcriber.value.makeSession(language: .explicit("en"))
        let audio = try Fixtures.clip("long-en")
        await session.feed(Array(audio.prefix(audio.count / 2)))
        await session.cancel()
        await session.cancel()
        await session.feed(Array(audio.suffix(audio.count / 2)))
        let result = await session.finish()
        #expect(result.text == "" && result.segments.isEmpty && result.model == nil)
        // The transcriber is free for the next dictation.
        let next = try await Fixtures.transcriber.value.makeSession(language: .explicit("en"))
        await next.feed(try Fixtures.clip("fleurs-en"))
        #expect(await !next.finish().text.isEmpty)
    }

    @Test(.enabled(if: Fixtures.modelsInstalled))
    func noSpeechIsEmpty() async throws {
        let session = try await Fixtures.transcriber.value.makeSession(language: .auto)
        var noise = [Float](repeating: 0, count: 16_000 * 3)
        for i in stride(from: 0, to: noise.count, by: 7) { noise[i] = 0.0005 }
        for offset in stride(from: 0, to: noise.count, by: 1_600) {
            await session.feed(Array(noise[offset ..< offset + 1_600]))
        }
        let result = await session.finish()
        #expect(result.text == "")
        #expect(result.segments.isEmpty)
        #expect(result.model == nil && result.detection == nil)
    }

    @Test(.enabled(if: Fixtures.modelsInstalled))
    func finishWithoutAudioIsEmpty() async throws {
        let result = await (try await Fixtures.transcriber.value.makeSession(language: .explicit("sv"))).finish()
        #expect(result.text == "" && result.model == nil)
    }

    @Test(.enabled(if: Fixtures.clipsInstalled), arguments: [("fleurs-sv", "sv"), ("fleurs-en", "en")])
    func detection(_ set: String, _ language: String) async throws {
        let ranked = try await Fixtures.transcriber.value.detectLanguage(Fixtures.clip(set))
        #expect(ranked.count == 100)
        #expect(ranked.first?.language == language)
        #expect(ranked.first!.probability > 0.85)
        #expect(abs(ranked.reduce(0) { $0 + $1.probability } - 1) < 0.01)
    }

    @Test(.enabled(if: Fixtures.clipsInstalled))
    func autoEnglishStaysOnGeneral() async throws {
        let session = try await Fixtures.transcriber.value.makeSession(language: .auto)
        await session.feed(try Fixtures.clip("fleurs-en"))
        let result = await session.finish()
        #expect(result.model == .general && result.language == "en")
        #expect(result.detection?.language == "en")
        #expect(result.text.split(separator: " ").count > 5)
    }

    /// FLEURS en 1700 opens with a 0.6 s click Silero passes ("Thank you." alone), 1666 ends with a
    /// 0.5 s breath ("you" alone). Joined to the speech beside them, both vanish.
    @Test(.enabled(if: Fixtures.clipsInstalled), arguments: ["1666", "1700"])
    func shortBlipJoinsItsNeighbour(_ id: String) async throws {
        let session = try await Fixtures.transcriber.value.makeSession(language: .explicit("en"))
        await session.feed(try Fixtures.clip("fleurs-en", id))
        let result = await session.finish()
        #expect(result.segments.allSatisfy { $0.audioSeconds >= 1 })
        #expect(!result.text.hasPrefix("Thank you") && !result.text.hasSuffix(" You"))
    }

    /// The re-decode for cut-short segments must transcribe a clean clip like the plain decode does.
    @Test(.enabled(if: Fixtures.clipsInstalled))
    func timestampedDecodeAgreesOnACleanClip() async throws {
        let transcriber = try await Fixtures.transcriber.value
        let audio = try Fixtures.clip("fleurs-en", "1660")
        let plain = try await transcriber.transcribe(audio, on: .general, language: "en")
        let timestamped = try await transcriber.transcribeTimestamped(audio, on: .general, language: "en")
        let words = { (text: String) in Set(text.lowercased().split(whereSeparator: { !$0.isLetter })) }
        let shared = words(plain.text).intersection(words(timestamped.text)).count
        #expect(Double(shared) >= 0.9 * Double(words(plain.text).count))
        #expect(!timestamped.text.contains("<|"))
    }

    @Test(.enabled(if: Fixtures.clipsInstalled))
    func longDictationIsCutUnder30Seconds() async throws {
        let audio = try Fixtures.clip("long-sv")
        #expect(audio.count > 30 * 16_000)
        let session = try await Fixtures.transcriber.value.makeSession(language: .explicit("sv"))
        for offset in stride(from: 0, to: audio.count, by: 1_600) {
            await session.feed(Array(audio[offset ..< min(offset + 1_600, audio.count)]))
        }
        let result = await session.finish()
        #expect(result.segments.count >= 2)
        #expect(result.segments.allSatisfy { $0.audioSeconds <= SegmentCut.maxSeconds + 0.5 && !$0.failed })
        // No Swedish model loaded: the session falls back to general.
        #expect(result.model == .general && result.language == "sv")
        #expect(result.text.split(separator: " ").count > 50)
    }
}
