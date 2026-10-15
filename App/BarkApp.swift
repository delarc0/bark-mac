import AppKit
import SwiftUI

@main
struct BarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "Icon") { NSApp.applicationIconImage = icon }
        menuBar = MenuBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Registered directly: under the SwiftUI lifecycle an opened URL may go to a scene instead.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// hq's pairing callback, bark://hq-connected. Settings opens on the result.
    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), MeetingLibrary.shared.hq.handle(url) else { return }
        SettingsWindowController.shared.present(tab: .meetings)
    }

    /// A meeting still recording is finished before quitting; past 15 s it is left for the next
    /// launch to recover from its audio.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let finishing = menuBar?.recorder.finishForQuit() else { return .terminateNow }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await finishing.value }
                group.addTask { try? await Task.sleep(for: .seconds(15)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
