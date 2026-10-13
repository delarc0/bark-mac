#if SPARKLE
import AppKit
import Sparkle

/// Sparkle, Release builds only. Created at launch so scheduled checks run.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
#endif
