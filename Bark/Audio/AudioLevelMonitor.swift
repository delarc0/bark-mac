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
        sessionPeakStorage.withLock { if level > $0 { $0 = level } }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }

    // Loudest sample seen since the last resetSessionPeak(). A recording that
    // ends at exactly 0 never carried audio at all (a denied or dead mic gets
    // fed digital silence), which is a different failure from "too quiet".
    private let sessionPeakStorage = OSAllocatedUnfairLock(initialState: Float(0))

    var sessionPeak: Float {
        sessionPeakStorage.withLock { $0 }
    }

    func resetSessionPeak() {
        sessionPeakStorage.withLock { $0 = 0 }
    }
}
