import AppKit
import SwiftUI

/// A window of the menu bar app. Showing one turns Bark into a regular app so the window can come
/// forward; closing the last one turns it back, or Bark would stay in the Dock.
@MainActor
class AppWindowController: NSWindowController {
    init(title: String, styleMask: NSWindow.StyleMask = [.titled, .closable], content: some View) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = styleMask
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { $0.isVisible && $0 !== window && $0.canBecomeKey }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsWindowController: AppWindowController {
    static let shared = SettingsWindowController()

    private init() {
        super.init(title: "Bark Settings", styleMask: [.titled, .closable, .miniaturizable], content: SettingsView(settings: .shared))
    }

    func present() {
        bringForward()
    }
}

final class OnboardingWindowController: AppWindowController {
    static let shared = OnboardingWindowController()

    private let model: OnboardingModel

    private init() {
        let model = OnboardingModel()
        self.model = model
        super.init(title: "Welcome to Bark", content: OnboardingView(model: model, settings: .shared, models: .shared) {
            AppSettings.shared.onboardingCompleted = true
            OnboardingWindowController.shared.close()
        })
    }

    func present(at step: OnboardingModel.Step = .welcome) {
        model.step = step
        bringForward()
    }
}
