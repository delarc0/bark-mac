@testable import BarkEngine
import Foundation
import Synchronization
import Testing

struct ForegroundTests {
    /// Waits for a condition that another task makes true.
    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func dictationJumpsQueuedBackgroundWork() async throws {
        let worker = MLXWorker()
        let order = Mutex<[String]>([])
        let running = Mutex(false), release = Mutex(false)
        // A background piece already decoding: it finishes first.
        let busy = Task {
            try await worker.run(.background) {
                running.withLock { $0 = true }
                while !release.withLock({ $0 }) { usleep(1_000) }
                order.withLock { $0.append("busy") }
            }
        }
        try await eventually { running.withLock { $0 } }
        var tasks: [Task<Void, Error>] = []
        for (name, priority) in [("meeting", MLXWorker.Priority.background), ("dictation", .foreground), ("split", .background),
                                 ("dictation tail", .foreground)] {
            tasks.append(Task { try await worker.run(priority) { order.withLock { $0.append(name) } } })
            try await eventually { worker.queued == tasks.count }
        }
        release.withLock { $0 = true }
        try await busy.value
        for task in tasks { try await task.value }
        #expect(order.withLock { $0 } == ["busy", "dictation", "dictation tail", "meeting", "split"])
        #expect(worker.queued == 0)
    }

    @Test func backgroundWaitsWhileAnyDictationIsOpen() async throws {
        let gate = ForegroundGate()
        await gate.waitUntilClear()
        let first = UUID(), second = UUID()
        gate.open(first)
        gate.open(second)
        let passed = Mutex(false)
        let waiter = Task {
            await gate.waitUntilClear()
            passed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        gate.close(first)
        gate.close(first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!passed.withLock { $0 } && !gate.isClear)
        gate.close(second)
        await waiter.value
        #expect(passed.withLock { $0 } && gate.isClear)
    }

    /// Its own gate: other tests' dictations share the fixture transcriber and run in parallel.
    @Test(.enabled(if: Fixtures.modelsInstalled)) func aDictationHoldsTheGateUntilItEnds() async throws {
        let transcriber = try await Fixtures.transcriber.value
        let vad = try await transcriber.startedVAD()
        let gate = ForegroundGate()
        func session() -> DictationSession {
            DictationSession(transcriber: transcriber, gate: gate, vad: vad, choice: .explicit("en"), cleanup: true, vocabulary: [:])
        }
        let finished = session()
        #expect(!gate.isClear)
        await finished.feed([Float](repeating: 0, count: 8_000))
        _ = await finished.finish()
        #expect(gate.isClear)
        let cancelled = session()
        #expect(!gate.isClear)
        await cancelled.cancel()
        #expect(gate.isClear)
        // A dictation dropped without finish or cancel does not hold background work forever.
        do { _ = session() }
        try await eventually { gate.isClear }
    }
}
