import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private let model = OnboardingModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Bark"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let root = OnboardingView(
            model: model,
            settings: AppSettings.shared,
            onFinish: { [weak self] in self?.finish() }
        )
        window.contentViewController = NSHostingController(rootView: root)

        // Same policy-restore as SettingsWindow: closing via the title-bar
        // button must not leave Bark as a permanent Dock app.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if !(NSApp.windows.contains { $0.isVisible && $0 !== window && $0.canBecomeKey }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        AppSettings.shared.onboardingCompleted = true
        close()
        // close() already triggers the willClose policy restore, which keeps the
        // Dock icon when another window (e.g. Settings) is still visible.
    }
}
