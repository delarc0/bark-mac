import BarkCapture
import BarkCore
import Foundation

/// Detect and offer: looks for a call every 5 s while no meeting records. It only reports; the
/// user decides.
@MainActor
final class CallWatcher {
    static let interval: TimeInterval = 5

    var onChange: ((CallOffers.Change) -> Void)?
    private var offers = CallOffers()
    private var timer: Timer?

    func resume() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// While a meeting records. The call being recorded counts as offered, so it is not offered
    /// again when the meeting stops.
    func pause() {
        timer?.invalidate()
        timer = nil
        offers.markHandled(AudioApps.running())
    }

    private func poll() {
        let change = offers.observe(AudioApps.running(), appName: AudioApps.localizedName(forPID:))
        if change != .none { onChange?(change) }
    }
}
