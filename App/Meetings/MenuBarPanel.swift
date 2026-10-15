import AppKit
import SwiftUI

/// Something the menu bar wants to say: a call to record, or a problem with one button that fixes it.
struct PanelMessage {
    let title: String
    var detail: String?
    var action: (title: String, run: @MainActor () -> Void)?
    var dismissTitle = "Dismiss"
}

/// A small panel under the status item that never takes focus from the call, like a notification.
@MainActor
final class MenuBarPanel {
    private static let width: CGFloat = 320

    private let panel: NSPanel
    private let anchor: @MainActor () -> NSRect?
    private(set) var isShowingOffer = false

    init(anchor: @escaping @MainActor () -> NSRect?) {
        self.anchor = anchor
        panel = ClickablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
    }

    func show(_ message: PanelMessage, offer: Bool = false) {
        isShowingOffer = offer
        let view = PanelView(message: message) { [weak self] in self?.hide() }
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        panel.setFrame(frame(for: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        isShowingOffer = false
        panel.orderOut(nil)
    }

    /// Under the status item, kept on its screen.
    private func frame(for size: NSSize) -> NSRect {
        let item = anchor()
        let screen = item.flatMap { item in NSScreen.screens.first { NSPointInRect(NSPoint(x: item.midX, y: item.midY), $0.frame) } }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max((item?.midX ?? visible.maxX) - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: visible.maxY - size.height - 8, width: size.width, height: size.height)
    }

    fileprivate struct PanelView: View {
        let message: PanelMessage
        let dismiss: @MainActor () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.title).font(.headline)
                    if let detail = message.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button(message.dismissTitle, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    if let action = message.action {
                        Button(action.title) {
                            dismiss()
                            action.run()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.regular)
            }
            .padding(14)
            .frame(width: MenuBarPanel.width, alignment: .leading)
        }
    }
}

/// Borderless panels cannot become key by default, and a click on a window of an inactive app is
/// otherwise spent activating it: both would swallow the first click on a button.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
