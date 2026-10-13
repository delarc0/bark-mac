import AppKit
import SwiftUI

/// Two wordless skins on one model: the pill, or the notch island when the pointer's screen has
/// a notch and the setting is on. The surface is picked at the first reveal of a dictation and
/// kept until it hides, so a pointer move cannot swap skins mid-dictation.
@MainActor
final class OverlayController {
    private enum Surface {
        case pill
        case island(NotchGeometry)
    }

    private static let chinDepth: CGFloat = 36
    // The pill appears only once the user actually speaks.
    private static let speakingLevel: Float = 0.03

    private let settings: AppSettings
    private let level: @MainActor () -> Float
    private let model = OverlayModel()
    private let pillPanel = OverlayController.panel(NSRect(x: 0, y: 0, width: 420, height: 170))
    private let islandPanel = OverlayController.panel(NSRect(x: 0, y: 0, width: 200, height: 70))
    private var surface: Surface?
    private var visible: NSPanel?
    private var voiceTimer: Timer?
    // Bumped on every show: a fade-out that finishes after a quick re-press must not hide it.
    private var generation = 0

    init(settings: AppSettings, level: @escaping @MainActor () -> Float) {
        self.settings = settings
        self.level = level
        pillPanel.contentView = NSHostingView(rootView: PillView(model: model, settings: settings, level: level))
    }

    private static func panel(_ rect: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        return panel
    }

    func show(_ indicator: OverlayIndicator) {
        generation += 1
        stopVoiceTimer()
        guard settings.overlayEnabled else { return }
        model.indicator = indicator
        if indicator == .recording, visible == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.revealOnVoice() }
            }
            RunLoop.main.add(timer, forMode: .common)
            voiceTimer = timer
        } else {
            reveal()
        }
    }

    func hide() {
        stopVoiceTimer()
        guard let panel = visible else {
            model.indicator = nil
            surface = nil
            return
        }
        let current = generation
        // A short hold before fading, so the last state is seen rather than flashed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current else { return }
                        panel.orderOut(nil)
                        self.model.indicator = nil
                        self.surface = nil
                        self.visible = nil
                    }
                })
            }
        }
    }

    private func revealOnVoice() {
        guard level() >= Self.speakingLevel else { return }
        stopVoiceTimer()
        reveal()
    }

    private func stopVoiceTimer() {
        voiceTimer?.invalidate()
        voiceTimer = nil
    }

    private func reveal() {
        let surface = surface ?? (settings.notchIslandEnabled ? NotchGeometry.forPointerScreen().map(Surface.island) : nil) ?? .pill
        self.surface = surface
        let panel: NSPanel
        switch surface {
        case .pill:
            panel = pillPanel
            placePill()
        case .island(let notch):
            panel = islandPanel
            placeIsland(notch)
        }
        if let visible, visible !== panel { visible.orderOut(nil) }
        visible = panel
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Bottom centre of the screen holding the pointer: that is where the user is typing, and
    /// NSScreen.main is often another display for a menu bar app.
    private func placePill() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = pillPanel.frame.size
        let frame = screen.visibleFrame
        // The pill's centre sits 104 pt above the bottom of the visible frame.
        pillPanel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 104 - size.height / 2))
    }

    /// The island's top edge is exactly the notch width, so it reads as the notch growing a chin
    /// and never covers a menu item.
    private func placeIsland(_ notch: NotchGeometry) {
        let height = notch.height + Self.chinDepth
        islandPanel.contentView = NSHostingView(rootView: IslandView(model: model, level: level, notchHeight: notch.height,
                                                                     chinDepth: Self.chinDepth, width: notch.width))
        let screen = notch.screen.frame
        islandPanel.setFrame(NSRect(x: screen.midX - notch.width / 2, y: screen.maxY - height, width: notch.width, height: height),
                             display: true)
    }
}

/// The notch of a built-in display, from public APIs. Nil when the pointer's screen has none:
/// external displays, Macs without a notch, and a docked clamshell (the built-in display drops
/// out of NSScreen.screens).
struct NotchGeometry {
    let screen: NSScreen
    let height: CGFloat
    let width: CGFloat

    static func forPointerScreen() -> NotchGeometry? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.flatMap(NotchGeometry.init)
    }

    init?(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        // The auxiliary areas are the menu bar strips either side of the camera housing.
        let width = screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
        // Implausible geometry would draw a black slab across the menu bar; the pill is always
        // a correct fallback.
        guard top > 0, (100 ... 400).contains(width), (24 ... 60).contains(top) else { return nil }
        self.screen = screen
        height = top
        self.width = width
    }
}
