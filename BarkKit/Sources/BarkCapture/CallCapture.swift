import BarkCore
import Foundation

/// A meeting's audio: the mic as me and, in a call, the tapped system audio as them, paired into
/// aligned 100 ms blocks (BlockAligner) so MeetingSession can time both streams by sample count.
/// A source that drops out is reported as a gap and padded with silence while the other runs.
@MainActor
public final class CallCapture {
    public enum Mode: Sendable, Equatable {
        /// Mic as me, the tapped system audio as them.
        case call(SystemAudioTap.Target)
        /// Mic only. Blocks carry an empty `them`: with no second source there is nothing to keep
        /// aligned, and a them stream of silence would be stored and segmented for nothing.
        case inPerson
    }

    public enum Event: Sendable, Equatable {
        /// 1600 samples each side (the last block at stop may be shorter); `them` is empty in person.
        case audio(me: [Float], them: [Float])
        /// A source stopped delivering for over a second; its side is padded with silence from here.
        case gap(reason: String)
        /// The tap has delivered only digital zero for 5 s while the tapped app reports it is
        /// playing: system audio capture is most likely not granted.
        case tapSilent
        /// The mic's state over the last 3 s, sent when it changes.
        case micHealth(InputHealth)
    }

    static let healthTicks = 3

    private let mic = MicCapture()
    private let tap = SystemAudioTap()
    private var aligner = BlockAligner()
    private var silence = TapSilence()
    private var tapping = false
    private var tapPlaying = false
    private var micFrames = 0
    private var micPeak: Float = 0
    private var health: InputHealth?
    private var continuation: AsyncStream<Event>.Continuation?
    private var stopping = false
    private var feeds: [Task<Void, Never>] = []
    private var monitor: Task<Void, Never>?

    public init() {}

    nonisolated public var micLevel: Float { mic.level }
    nonisolated public var tapLevel: Float { tap.level }

    /// Starts the mic (echo cancellation on unless `echoCancellation` is false) and, in a call, the
    /// tap. Throws when either cannot start; nothing is left running then.
    public func start(mode: Mode, micUID: String?, echoCancellation: Bool = true) throws -> AsyncStream<Event> {
        precondition(continuation == nil, "stop() the running capture first")
        let micStream = try mic.start(deviceUID: micUID, voiceProcessing: echoCancellation)
        var tapStream: AsyncStream<[Float]>?
        if case .call(let target) = mode {
            do {
                tapStream = try tap.start(target)
            } catch {
                mic.stop()
                throw error
            }
        }
        tapping = tapStream != nil
        tapPlaying = tapping && tap.targetIsPlaying
        aligner = BlockAligner(paired: tapping)
        silence = TapSilence()
        micFrames = 0
        micPeak = 0
        health = nil
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        feeds = [Task { for await chunk in micStream { self.receive(chunk, from: .me) } }]
        if let tapStream {
            feeds.append(Task { for await chunk in tapStream { self.receive(chunk, from: .them) } })
        }
        monitor = Task { [weak self] in
            var tick = 0
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.poll(judgeHealth: tick % Self.healthTicks == 0)
            }
        }
        return stream
    }

    /// Stops both sources, delivers everything they captured (the tail padded to equal length)
    /// and ends the stream.
    public func stop() async {
        guard let continuation, !stopping else { return }
        stopping = true
        monitor?.cancel()
        monitor = nil
        mic.stop()
        if tapping { tap.stop() }
        for feed in feeds { await feed.value }
        feeds = []
        for output in aligner.flush() { emit(output, to: continuation) }
        continuation.finish()
        self.continuation = nil
        stopping = false
    }

    private func receive(_ samples: [Float], from side: CallSide) {
        guard let continuation else { return }
        switch side {
        case .me:
            micFrames += samples.count
            micPeak = samples.reduce(micPeak) { max($0, abs($1)) }
        case .them:
            if silence.observe(samples, sourcePlaying: tapPlaying) { continuation.yield(.tapSilent) }
        }
        for output in aligner.append(samples, from: side) { emit(output, to: continuation) }
    }

    private func emit(_ output: BlockAligner.Output, to continuation: AsyncStream<Event>.Continuation) {
        switch output {
        case .block(let me, let them): continuation.yield(.audio(me: me, them: them))
        case .gap(.me): continuation.yield(.gap(reason: "microphone stopped delivering audio"))
        case .gap(.them): continuation.yield(.gap(reason: "system audio stopped delivering audio"))
        }
    }

    private func poll(judgeHealth: Bool) {
        guard let continuation, !stopping else { return }
        if tapping { tapPlaying = tap.targetIsPlaying }
        guard judgeHealth else { return }
        let now = InputHealth.classify(frames: micFrames, peak: micPeak)
        micFrames = 0
        micPeak = 0
        if now != health {
            health = now
            continuation.yield(.micHealth(now))
        }
    }
}
