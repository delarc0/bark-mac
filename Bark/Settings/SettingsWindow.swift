import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView(settings: AppSettings.shared))
        let window = NSWindow(contentViewController: host)
        window.title = "Bark Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 380))
        window.center()
        super.init(window: window)

        // present() flips to .regular so the window can come forward; without
        // this, closing Settings leaves Bark as a permanent Dock app.
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
}
