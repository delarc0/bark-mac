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
    private let panel: NSPanel
    private let model = OverlayModel()
    private let settings = AppSettings.shared
    private var fadeTask: Task<Void, Never>?
    private var voicePollTimer: Timer?
    private var intendedState: OverlayModel.State = .idle
    private var lastSpeechAt: Date?

    private let speakThreshold: Float = 0.03
    private var didRevealDuringSession = false
    // Bumped on every reveal; a pending fade-out completion from a previous hide
    // must not order the panel out after a rapid re-press has revealed it again.
    private var hideGeneration = 0

    init() {
        // Nominal only: NSHostingView drives the panel size from the SwiftUI
        // content's intrinsic size (OverlayView carries its own transparent
        // margin so the shadow never clips at the window edge).
        let rect = NSRect(x: 0, y: 0, width: 220, height: 160)
        let panel = NSPanel(
            contentRect: rect,
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
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: OverlayView(model: model, settings: AppSettings.shared))
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentView?.bounds ?? rect
        panel.contentView = host

        self.panel = panel
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

    // MARK: - Voice-gated reveal

    private func startVoicePolling() {
        stopVoicePolling()
        lastSpeechAt = nil
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
        positionBottomCenter()
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
        let panel = self.panel
        let generation = hideGeneration
        fadeTask = Task { [weak self] in
            if fadeDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fadeDelay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.hideGeneration == generation else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.hideGeneration == generation else { return }
                        panel.orderOut(nil)
                        self.model.state = .idle
                    }
                })
            }
        }
    }

    private func positionBottomCenter() {
        panel.layoutIfNeeded()
        let size = panel.frame.size
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
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
