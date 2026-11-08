import AVFoundation
import Foundation

/// A meeting stream's audio as captured: raw 16 kHz mono 16-bit little-endian PCM.
public enum PCM {
    public static let sampleRate = 16_000

    /// Whole samples in the file; a torn last write can leave half of one.
    public static func sampleCount(_ url: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        return size / 2
    }

    /// Up to `count` samples from sample `start`, as float.
    public static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start * 2))
        let data = try handle.read(upToCount: count * 2) ?? Data()
        return data.withUnsafeBytes { raw in
            (0 ..< data.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    /// Up to `count` samples from sample `start` of an archived stream, as float.
    public static func readArchive(_ caf: URL, from start: Int, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: caf, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard start < file.length, count > 0 else { return [] }
        file.framePosition = AVAudioFramePosition(start)
        let frames = AVAudioFrameCount(min(Int64(count), file.length - Int64(start)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw StoreError("cannot read \(caf.lastPathComponent)")
        }
        try file.read(into: buffer, frameCount: frames)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Compresses `pcm` to Apple Lossless in a CAF file at `caf`, checks the CAF holds every sample,
    /// then deletes the PCM. Streams in blocks; a 90-minute stream never sits in memory.
    public static func archive(_ pcm: URL, to caf: URL) throws {
        let frames = try sampleCount(pcm)
        try? FileManager.default.removeItem(at: caf)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let output = try AVAudioFile(forWriting: caf, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = output.processingFormat
        let input = try FileHandle(forReadingFrom: pcm)
        defer { try? input.close() }
        let block = 1 << 16
        var written = 0
        while written < frames {
            let count = min(block, frames - written)
            guard let data = try input.read(upToCount: count * 2), data.count == count * 2,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw StoreError("short read archiving \(pcm.lastPathComponent)")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            data.withUnsafeBytes { raw in
                buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: count)
            }
            try output.write(from: buffer)
            written += count
        }
        output.close()
        let archived = try AVAudioFile(forReading: caf).length
        guard archived == AVAudioFramePosition(frames) else {
            try? FileManager.default.removeItem(at: caf)
            throw StoreError("\(caf.lastPathComponent) holds \(archived) frames, the PCM \(frames); PCM kept")
        }
        try FileManager.default.removeItem(at: pcm)
    }
}

/// Appends one stream's audio to its PCM file as it is captured. write(2) puts every chunk in the
/// OS cache at once, so a crash of Bark loses nothing; fsync every 2 s of audio bounds what a
/// power loss or kernel panic can take.
public final class PCMWriter {
    public static let syncInterval = 2 * PCM.sampleRate
    private let handle: FileHandle
    private var unsynced = 0
    /// Samples in the file.
    public private(set) var count: Int

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw StoreError("cannot create \(url.path)")
            }
        }
        handle = try FileHandle(forWritingTo: url)
        count = Int(try handle.seekToEnd() / 2)
        // Drop a torn half sample so appends stay aligned.
        try handle.truncate(atOffset: UInt64(count * 2))
    }

    deinit { try? handle.close() }

    public func append(_ samples: [Float]) throws {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let value = Int16(max(-32768, min(32767, (sample * 32768).rounded())))
                raw.storeBytes(of: value.littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Disk full: the file still takes the block as silence (a sparse extension needs no free
            // space), so the timeline after it stays where the segmenter has it.
            let end = UInt64((count + samples.count) * 2)
            if (try? handle.truncate(atOffset: end)) != nil, (try? handle.seek(toOffset: end)) != nil {
                count += samples.count
            }
            throw error
        }
        count += samples.count
        unsynced += samples.count
        if unsynced >= Self.syncInterval {
            try handle.synchronize()
            unsynced = 0
        }
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
