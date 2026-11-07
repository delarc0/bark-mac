import BarkCore
import BarkStore
import CoreML
import FluidAudio
import Foundation
import os

public struct SpeakerReport: Sendable, Equatable {
    /// Speakers saved, Me included.
    public let speakers: Int
    /// Segments with words that got a speaker, out of `segments` (after splitting).
    public let attributed: Int
    public let segments: Int
    /// Segments cut where the speaker changes and re-decoded, and the pieces they became.
    public let split: Int
    public let pieces: Int
    /// Segments that held a change but kept their text whole: a piece failed or came back empty,
    /// or the pieces lost words.
    public let keptWhole: Int
    /// Seconds of audio diarized, every stream counted.
    public let audioSeconds: Double
    /// Diarizing and saving, model loading included.
    public let seconds: Double
}

/// Who said what, as a pass after a meeting is done (S5: pyannote community-1 through FluidAudio's
/// offline pipeline). Each stream that can hold several people is diarized on its own; a call's
/// mic is the user alone and is labelled Me without diarizing it. Every segment with words gets
/// the speaker with the most overlap; speakers are labelled Speaker 1...n in order of first
/// appearance, names left to the user. Given the Transcriber, a segment the turns show two
/// people in is cut where the speaker changes (BarkCore SegmentSplit) and its pieces re-decoded
/// with the segment's own model and language; when any piece fails or comes back empty, or the
/// pieces hold fewer words than the segment did, the segment is kept whole. Models load per meeting and are released after it; run one meeting at
/// a time.
public final class MeetingDiarizer: Sendable {
    /// What `models` must hold: Fluid Inference's Core ML conversion of pyannote community-1
    /// (CC-BY-4.0).
    public static let modelFiles = ModelNames.OfflineDiarizer.requiredModels.sorted()

    private let models: URL
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Diarizer")

    public init(models: URL) {
        self.models = models
    }

    public static func modelsPresent(in folder: URL) -> Bool {
        modelFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// How each stream of a meeting in `mode` is attributed. A mic shared by the room (in person,
    /// hybrid) is diarized like the call audio.
    public enum Role: Sendable, Equatable {
        case user
        case diarize
    }

    public static func role(of stream: MeetingStream, in mode: MeetingMode) -> Role {
        stream == .me && mode == .call ? .user : .diarize
    }

    /// Diarizes the done meeting `id`, splits segments that hold two people when `transcriber` is
    /// given, saves the speakers (which queues it for hq again) and marks diarization done; on an
    /// error it is marked failed and the transcript is untouched.
    @discardableResult
    public func run(_ id: UUID, store: MeetingStore, transcriber: Transcriber? = nil,
                    rule: SegmentSplit.Rule = SegmentSplit.Rule()) async throws -> SpeakerReport {
        let clock = ContinuousClock()
        let started = clock.now
        guard let meeting = try store.meeting(id), meeting.status == .done else { throw StoreError("meeting \(id) is not done") }
        try store.setDiarization(id, .running)
        do {
            let segments = try store.segments(id).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let streams = Set(segments.map(\.stream)).filter { Self.role(of: $0, in: meeting.mode) == .diarize }
            var turns: [MeetingStream: [SpeakerAttribution.Turn]] = [:]
            var audioSeconds = 0.0
            if !streams.isEmpty {
                let manager = try loadManager()
                for stream in streams.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let (streamTurns, seconds) = try await diarize(stream, of: id, store: store, manager: manager)
                    turns[stream] = streamTurns
                    audioSeconds += seconds
                }
            }
            var pieces: [Int64: [Segment]] = [:]
            var keptWhole = 0
            if let transcriber {
                for segment in segments where Self.role(of: segment.stream, in: meeting.mode) == .diarize {
                    let streamTurns = turns[segment.stream] ?? []
                    let windows = SegmentSplit.cutWindows(start: segment.start, end: segment.end, turns: streamTurns, rule: rule)
                    guard !windows.isEmpty, let id = segment.id else { continue }
                    if let split = try await split(segment, of: meeting.id, windows: windows, turns: streamTurns, rule: rule,
                                                   store: store, transcriber: transcriber) {
                        pieces[id] = split
                    } else {
                        keptWhole += 1
                    }
                }
            }
            let final = segments.flatMap { segment in segment.id.flatMap { pieces[$0] } ?? [segment] }
            let (labels, speakers) = Self.attribute(final, mode: meeting.mode, turns: turns)
            var assignments: [Int64: Int] = [:]
            var replacements: [Int64: [(segment: Segment, speaker: Int?)]] = [:]
            var index = 0
            for segment in segments {
                if let id = segment.id, let split = pieces[id] {
                    replacements[id] = split.enumerated().map { ($1, speakers[index + $0]) }
                    index += split.count
                } else {
                    if let id = segment.id, let speaker = speakers[index] { assignments[id] = speaker }
                    index += 1
                }
            }
            try store.saveSpeakers(id, labels: labels, assignments: assignments, replacing: replacements)
            let report = SpeakerReport(speakers: labels.count, attributed: speakers.compactMap { $0 }.count, segments: final.count,
                                       split: pieces.count, pieces: pieces.values.reduce(0) { $0 + $1.count }, keptWhole: keptWhole,
                                       audioSeconds: audioSeconds, seconds: (clock.now - started).seconds)
            log.info("Meeting \(id, privacy: .public): \(report.speakers) speakers, \(report.attributed)/\(report.segments) segments, \(report.split) split, \(report.keptWhole) kept whole, \(report.audioSeconds, format: .fixed(precision: 0)) s audio in \(report.seconds, format: .fixed(precision: 1)) s")
            return report
        } catch {
            try? store.setDiarization(id, .failed)
            throw error
        }
    }

    /// Labels, and for each of `segments` (those with words, in time order) its label's index or
    /// nil, given each diarized stream's turns. Me first when the user spoke, then Speaker n.
    static func attribute(_ segments: [Segment], mode: MeetingMode,
                          turns: [MeetingStream: [SpeakerAttribution.Turn]]) -> (labels: [String], speakers: [Int?]) {
        struct Key: Hashable {
            let stream: MeetingStream
            let speaker: Int
        }
        let keys: [Key?] = segments.map { segment in
            guard role(of: segment.stream, in: mode) == .diarize else { return nil }
            return SpeakerAttribution.speaker(start: segment.start, end: segment.end, in: turns[segment.stream] ?? [])
                .map { Key(stream: segment.stream, speaker: $0) }
        }
        let user = segments.contains { role(of: $0.stream, in: mode) == .user }
        let numbers = SpeakerAttribution.numbers(inOrderOfAppearance: keys.compactMap { $0 })
        let offset = user ? 1 : 0
        let labels = (user ? [SpeakerAttribution.userLabel] : []) + (0 ..< numbers.count).map { SpeakerAttribution.label($0 + 1) }
        let speakers = zip(segments, keys).map { segment, key -> Int? in
            role(of: segment.stream, in: mode) == .user ? 0 : key.map { offset + numbers[$0]! - 1 }
        }
        return (labels, speakers)
    }

    /// The segment's pieces, cut at the quietest point of each window and re-decoded with its own
    /// model and language; nil when it cannot be split without losing text.
    private func split(_ segment: Segment, of meeting: UUID, windows: [ClosedRange<Double>], turns: [SpeakerAttribution.Turn],
                       rule: SegmentSplit.Rule, store: MeetingStore, transcriber: Transcriber) async throws -> [Segment]? {
        guard let role = await transcriber.loadedRole(for: segment.model) else { return nil }
        let rate = Double(PCM.sampleRate)
        let first = Int((segment.start * rate).rounded())
        let audio = try store.readAudio(meeting, segment.stream, from: first, count: Int((segment.end * rate).rounded()) - first)
        let energy = SegmentSplit.energy(audio, rate: PCM.sampleRate)
        let cuts = windows.map { SegmentSplit.quietest(in: $0, energy: energy, origin: segment.start, hop: 0.01) }
        let ranges = SegmentSplit.pieces(start: segment.start, end: segment.end, cuts: cuts, rule: rule)
        guard ranges.count > 1 else { return nil }
        var pieces: [Segment] = []
        for range in ranges {
            let from = max(0, Int((range.lowerBound * rate).rounded()) - first)
            let to = min(audio.count, Int((range.upperBound * rate).rounded()) - first)
            let speech = turns.reduce(0.0) { $0 + max(0, min(range.upperBound, $1.end) - max(range.lowerBound, $1.start)) }
            let (result, redecoded) = await transcriber.decodeSegment(Array(audio[from ..< to]), speechSeconds: speech, on: role,
                                                                      language: segment.language, .background)
            guard let text = result?.text else { return nil }
            pieces.append(Segment(stream: segment.stream, start: range.lowerBound, end: range.upperBound, text: text,
                                  model: segment.model, language: segment.language, redecoded: redecoded))
        }
        return SegmentSplit.keepsText(whole: segment.text, pieces: pieces.map(\.text), rule: rule) ? pieces : nil
    }

    /// One stream's speaker turns, from its PCM while archiving has not finished (a CAF beside it
    /// may be cut short), else its archived audio.
    private func diarize(_ stream: MeetingStream, of id: UUID, store: MeetingStore,
                         manager: OfflineDiarizerManager) async throws -> ([SpeakerAttribution.Turn], Double) {
        let archived = store.archivedAudio(id, stream), raw = store.rawAudio(id, stream)
        if FileManager.default.fileExists(atPath: raw.path) {
            let source = try PCMSource(url: raw)
            let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
            return (Self.turns(result.segments), Double(source.sampleCount) / Double(PCM.sampleRate))
        } else if FileManager.default.fileExists(atPath: archived.path) {
            return try await Self.turns(file: archived, manager: manager)
        } else {
            throw StoreError("no audio for \(stream.rawValue) in meeting \(id)")
        }
    }

    /// An audio file's speaker turns, diarized exactly as an archived meeting stream (mlx-eval --diarize).
    public func turns(_ file: URL) async throws -> [SpeakerAttribution.Turn] {
        try await Self.turns(file: file, manager: loadManager()).turns
    }

    private static func turns(file: URL, manager: OfflineDiarizerManager) async throws -> (turns: [SpeakerAttribution.Turn], seconds: Double) {
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: file, targetSampleRate: PCM.sampleRate)
        defer { source.cleanup() }
        let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
        return (turns(result.segments), Double(source.sampleCount) / Double(PCM.sampleRate))
    }

    /// FluidAudio's string speaker ids as small integers, in order of first appearance.
    static func turns(_ segments: [TimedSpeakerSegment]) -> [SpeakerAttribution.Turn] {
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let numbers = SpeakerAttribution.numbers(inOrderOfAppearance: sorted.map(\.speakerId))
        return sorted.map {
            SpeakerAttribution.Turn(speaker: numbers[$0.speakerId]!, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// The models go in directly: FluidAudio's own loaders fetch a missing model from Hugging Face.
    private func loadManager() throws -> OfflineDiarizerManager {
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let options = MLModelConfiguration()
            options.computeUnits = units
            options.allowLowPrecisionAccumulationOnGPU = true
            return try MLModel(contentsOf: models.appending(path: name), configuration: options)
        }
        let names = ModelNames.OfflineDiarizer.self
        let loaded = OfflineDiarizerModels(
            segmentationModel: try model(names.segmentationPath, .all),
            // CPU is FluidAudio's own choice for the filterbank.
            fbankModel: try model(names.fbankPath, .cpuOnly),
            embeddingModel: try model(names.embeddingPath, .all),
            pldaRhoModel: try model(names.pldaRhoPath, .all),
            pldaPsi: try Self.pldaPsi(models.appending(path: names.pldaParameters)),
            compilationDuration: 0)
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: loaded)
        return manager
    }

    /// The PLDA psi tensor from plda-parameters.json: base64 little-endian float32.
    static func pldaPsi(_ url: URL) throws -> [Double] {
        struct File: Decodable {
            struct Tensor: Decodable { let data_base64: String }
            let tensors: [String: Tensor]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard let base64 = file.tensors["psi"]?.data_base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count % 4 == 0 else { throw StoreError("no PLDA psi in \(url.lastPathComponent)") }
        return data.withUnsafeBytes { raw in
            (0 ..< data.count / 4).map { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))) }
        }
    }
}

/// A stream's raw PCM, read in the windows the diarizer asks for.
private struct PCMSource: AudioSampleSource {
    let url: URL
    let sampleCount: Int

    init(url: URL) throws {
        self.url = url
        sampleCount = try PCM.sampleCount(url)
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        let start = max(0, offset)
        guard count > 0, start < sampleCount else { return }
        let samples = try PCM.read(url, from: start, count: min(count, sampleCount - start))
        destination.update(from: samples, count: samples.count)
    }
}
