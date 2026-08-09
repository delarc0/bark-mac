import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case downloading(Double)
    }

    @Published var state: State = .idle
}

@MainActor
final class OverlayController {
    // Two skins share one model: the bottom-center pill and the notch island.
    // Which one reveals is decided per session in resolveSurface().
    private enum Surface {
        case pill
        case island(NotchGeometry)
    }

    private let pillPanel: NSPanel
    private let islandPanel: NSPanel
    private let islandHost: NSHostingView<IslandView>
    private let model = OverlayModel()
    private let settings = AppSettings.shared

    private let chinDepth: CGFloat = 36

    private var fadeTask: Task<Void, Never>?
    private var voicePollTimer: Timer?
    private var intendedState: OverlayModel.State = .idle

    private let speakThreshold: Float = 0.03
    private var didRevealDuringSession = false
    // Bumped on every reveal; a pending fade-out completion from a previous hide
    // must not order a panel out after a rapid re-press has revealed it again.
    private var hideGeneration = 0

    // Chosen once per session (while nothing is showing) and kept across state
    // transitions so a pointer move mid-dictation can't flip pill<->island.
    private var currentSurface: Surface?
    private var visiblePanel: NSPanel?

    init() {
        // Pill: nominal rect only — NSHostingView drives its size from the
        // SwiftUI content's intrinsic size (OverlayView carries its own frame).
        let pillRect = NSRect(x: 0, y: 0, width: 220, height: 160)
        pillPanel = Self.makePanel(contentRect: pillRect)
        let pillHost = NSHostingView(rootView: OverlayView(model: model, settings: AppSettings.shared))
        pillHost.autoresizingMask = [.width, .height]
        pillHost.frame = pillPanel.contentView?.bounds ?? pillRect
        pillPanel.contentView = pillHost

        // Island: sized explicitly per notch geometry at reveal time.
        let islandRect = NSRect(x: 0, y: 0, width: 200, height: 70)
        islandPanel = Self.makePanel(contentRect: islandRect)
        islandHost = NSHostingView(rootView: IslandView(model: model, notchHeight: 34, chinDepth: chinDepth, width: 200))
        islandHost.autoresizingMask = [.width, .height]
        islandHost.frame = islandPanel.contentView?.bounds ?? islandRect
        islandPanel.contentView = islandHost
    }

    private static func makePanel(contentRect: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        return panel
    }

    func show(_ state: OverlayModel.State) {
        intendedState = state
        switch state {
        case .recording:
            startVoicePolling()
        case .transcribing, .downloading:
            stopVoicePolling()
            if settings.overlayEnabled {
                model.state = state
                revealPanel()
            }
        case .idle:
            stopVoicePolling()
            hidePanel()
        }
    }

    func hide(after delay: TimeInterval = 0.3) {
        intendedState = .idle
        stopVoicePolling()
        hidePanel(fadeDelay: delay)
    }

    // MARK: - Surface routing

    private func resolveSurface() -> Surface {
        if settings.notchIslandEnabled, let notch = NotchGeometry.forPointerScreen() {
            return .island(notch)
        }
        return .pill
    }

    // MARK: - Voice-gated reveal

    private func startVoicePolling() {
        stopVoicePolling()
        didRevealDuringSession = false
        guard settings.overlayEnabled else { return }
        model.state = .recording
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickVoice() }
        }
        RunLoop.main.add(timer, forMode: .common)
        voicePollTimer = timer
    }

    private func stopVoicePolling() {
        voicePollTimer?.invalidate()
        voicePollTimer = nil
    }

    private func tickVoice() {
        guard intendedState == .recording, settings.overlayEnabled else { return }
        guard !didRevealDuringSession else { return }
        if AudioLevelMonitor.shared.level >= speakThreshold {
            didRevealDuringSession = true
            revealPanel()
        }
    }

    // MARK: - Panel show/hide

    private func revealPanel() {
        fadeTask?.cancel()
        fadeTask = nil
        hideGeneration += 1

        // Lock the surface for this session on the first reveal, keep it after.
        let surface = currentSurface ?? resolveSurface()
        currentSurface = surface

        let panel: NSPanel
        switch surface {
        case .pill:
            positionBottomCenter()
            panel = pillPanel
        case .island(let notch):
            layoutIsland(for: notch)
            panel = islandPanel
        }

        // Only one skin visible at a time.
        if let other = visiblePanel, other !== panel {
            other.orderOut(nil)
        }
        visiblePanel = panel

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }

    private func hidePanel(fadeDelay: TimeInterval = 0.2) {
        fadeTask?.cancel()
        let panel = visiblePanel
        let generation = hideGeneration
        fadeTask = Task { [weak self] in
            if fadeDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fadeDelay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.hideGeneration == generation else { return }
                guard let panel else {
                    self.model.state = .idle
                    self.currentSurface = nil
                    return
                }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.hideGeneration == generation else { return }
                        panel.orderOut(nil)
                        // A rapid re-press may already own the model; resetting
                        // here would blank the pill mid-recording.
                        if self.intendedState == .idle { self.model.state = .idle }
                        self.currentSurface = nil
                        self.visiblePanel = nil
                    }
                })
            }
        }
    }

    // MARK: - Positioning

    private func positionBottomCenter() {
        pillPanel.layoutIfNeeded()
        let size = pillPanel.frame.size
        // The screen with the pointer is where the user is typing; NSScreen.main
        // (key-window screen) is often a different display for a menu-bar app.
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        // The pill is centered in the panel; anchor its center where the old
        // 48pt panel put it (80pt origin + 24) so growing the panel for shadow
        // room doesn't move the pill on screen.
        let y = visible.minY + 104 - size.height / 2
        pillPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func layoutIsland(for notch: NotchGeometry) {
        // The island's top edge matches the notch width exactly, so it reads as
        // the notch itself growing a chin downward (never covers a menu item).
        let width = notch.width
        let height = notch.height + chinDepth
        islandHost.rootView = IslandView(
            model: model,
            notchHeight: notch.height,
            chinDepth: chinDepth,
            width: width
        )
        let screen = notch.screen.frame
        let x = screen.midX - width / 2
        let y = screen.maxY - height  // hangs from the very top of the screen
        islandPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
