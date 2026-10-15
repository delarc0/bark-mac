import BarkCore
import BarkStore
import CoreML
import FluidAudio
import Foundation
import os

public struct SpeakerReport: Sendable, Equatable {
    /// Speakers saved, Me included.
    public let speakers: Int
    /// Segments with words that got a speaker, out of `segments`.
    public let attributed: Int
    public let segments: Int
    /// Seconds of audio diarized, every stream counted.
    public let audioSeconds: Double
    /// Diarizing and saving, model loading included.
    public let seconds: Double
}

/// Who said what, as a pass after a meeting is done (S5: pyannote community-1 through FluidAudio's
/// offline pipeline). Each stream that can hold several people is diarized on its own; a call's
/// mic is the user alone and is labelled Me without diarizing it. Every segment with words gets
/// the speaker with the most overlap; speakers are labelled Speaker 1...n in order of first
/// appearance, names left to the user. Models load per meeting and are released after it; run
/// one meeting at a time.
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

    /// Diarizes the done meeting `id`, saves its speakers (which queues it for hq again) and marks
    /// diarization done; on an error it is marked failed and the transcript is untouched.
    @discardableResult
    public func run(_ id: UUID, store: MeetingStore) async throws -> SpeakerReport {
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
            let (labels, assignments) = Self.attribute(segments, mode: meeting.mode, turns: turns)
            try store.saveSpeakers(id, labels: labels, assignments: assignments)
            let report = SpeakerReport(speakers: labels.count, attributed: assignments.count, segments: segments.count,
                                       audioSeconds: audioSeconds, seconds: (clock.now - started).seconds)
            log.info("Meeting \(id, privacy: .public): \(report.speakers) speakers, \(report.attributed)/\(report.segments) segments, \(report.audioSeconds, format: .fixed(precision: 0)) s audio in \(report.seconds, format: .fixed(precision: 1)) s")
            return report
        } catch {
            try? store.setDiarization(id, .failed)
            throw error
        }
    }

    /// Labels and the segment-to-label assignments for `segments` (those with words, in time
    /// order), given each diarized stream's turns. Me first when the user spoke, then Speaker n.
    static func attribute(_ segments: [Segment], mode: MeetingMode,
                          turns: [MeetingStream: [SpeakerAttribution.Turn]]) -> (labels: [String], assignments: [Int64: Int]) {
        struct Key: Hashable {
            let stream: MeetingStream
            let speaker: Int
        }
        var keys: [(segment: Int64, key: Key)] = []
        var user: [Int64] = []
        for segment in segments {
            guard let id = segment.id else { continue }
            if role(of: segment.stream, in: mode) == .user {
                user.append(id)
            } else if let speaker = SpeakerAttribution.speaker(start: segment.start, end: segment.end, in: turns[segment.stream] ?? []) {
                keys.append((id, Key(stream: segment.stream, speaker: speaker)))
            }
        }
        let numbers = SpeakerAttribution.numbers(inOrderOfAppearance: keys.map(\.key))
        var labels = user.isEmpty ? [] : [SpeakerAttribution.userLabel]
        let offset = labels.count
        labels += (0 ..< numbers.count).map { SpeakerAttribution.label($0 + 1) }
        var assignments: [Int64: Int] = [:]
        for id in user { assignments[id] = 0 }
        for (segment, key) in keys { assignments[segment] = offset + numbers[key]! - 1 }
        return (labels, assignments)
    }

    /// One stream's speaker turns, from its archived audio or, when archiving failed, its PCM.
    private func diarize(_ stream: MeetingStream, of id: UUID, store: MeetingStore,
                         manager: OfflineDiarizerManager) async throws -> ([SpeakerAttribution.Turn], Double) {
        let archived = store.archivedAudio(id, stream), raw = store.rawAudio(id, stream)
        if FileManager.default.fileExists(atPath: archived.path) {
            return try await Self.turns(file: archived, manager: manager)
        } else if FileManager.default.fileExists(atPath: raw.path) {
            let source = try PCMSource(url: raw)
            let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
            return (Self.turns(result.segments), Double(source.sampleCount) / Double(PCM.sampleRate))
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
