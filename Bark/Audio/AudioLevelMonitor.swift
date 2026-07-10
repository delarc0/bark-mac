import Foundation
import os

/// Lock-free shared peak level for the overlay EQ bars to poll.
/// AudioRecorder writes from its audio-thread tap; SwiftUI reads at display rate.
final class AudioLevelMonitor: @unchecked Sendable {
    static let shared = AudioLevelMonitor()

    private let storage = OSAllocatedUnfairLock(initialState: Float(0))

    var level: Float {
        storage.withLock { $0 }
    }

    func report(_ level: Float) {
        storage.withLock { $0 = level }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }
}
