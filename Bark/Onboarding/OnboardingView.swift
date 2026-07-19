import AVFoundation
import AppKit
import SwiftUI
import os

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, mic, accessibility, hotkey, done
    }

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Onboarding")

    @Published var step: Step = .welcome
    @Published var micGranted: Bool
    @Published var micDenied: Bool
    @Published var axGranted: Bool

    private var pollTimer: Timer?

    init() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micGranted = micStatus == .authorized
        self.micDenied = micStatus == .denied || micStatus == .restricted
        self.axGranted = DictationCoordinator.hasAccessibilityPermission()
        log.info("Init: mic=\(self.micGranted, privacy: .public) ax=\(self.axGranted, privacy: .public)")
    }

    deinit { pollTimer?.invalidate() }

    func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        log.info("Polling started")
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let mic = micStatus == .authorized
        let denied = micStatus == .denied || micStatus == .restricted
        let ax = DictationCoordinator.hasAccessibilityPermission()
        if mic != micGranted {
            log.info("Mic flip: \(self.micGranted, privacy: .public) -> \(mic, privacy: .public) (raw=\(micStatus.rawValue, privacy: .public))")
            micGranted = mic
        }
        if denied != micDenied {
            micDenied = denied
        }
        if ax != axGranted {
            log.info("AX flip: \(self.axGranted, privacy: .public) -> \(ax, privacy: .public)")
            axGranted = ax
        }
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micGranted = granted
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        _ = DictationCoordinator.hasAccessibilityPermission(prompt: true)
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)

            Divider()

            controls
                .padding(16)
        }
        .frame(width: 560, height: 420)
        .tint(BarkPalette.lime)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            WelcomeStep()
        case .mic:
            MicStep(model: model)
        case .accessibility:
            AccessibilityStep(model: model)
        case .hotkey:
            HotkeyStep(settings: settings)
        case .done:
            DoneStep()
        }
    }

    private var controls: some View {
        HStack {
            StepDots(current: model.step)
            Spacer()
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
                    .keyboardShortcut(.cancelAction)
            }
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .welcome:
            Button("Get started") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .mic:
            HStack(spacing: 8) {
                if !model.micGranted {
                    if model.micDenied {
                        Button("Open System Settings") { model.openMicrophoneSettings() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Allow microphone") { model.requestMic() }
                            .buttonStyle(.bordered)
                    }
                }
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .accessibility:
            HStack(spacing: 8) {
                if !model.axGranted {
                    Button("Open System Settings") { model.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                }
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .hotkey:
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .done:
            Button("Finish") { onFinish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct StepDots: View {
    let current: OnboardingModel.Step
    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= current.rawValue ? BarkPalette.lime : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                if let icon = NSImage(named: "Icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bark")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundStyle(BarkPalette.lime)
                    Text("Local dictation for macOS.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Hold a hotkey, speak, and text appears at your cursor.")
                .font(.title3)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 10) {
                bullet("100% on-device — audio never leaves your Mac.")
                bullet("Apple Silicon–accelerated (Neural Engine + GPU).")
                bullet("Works in any text field across any app.")
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(BarkPalette.lime)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}

private struct MicStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Microphone access", systemImage: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Text("Bark needs your microphone to capture audio for local transcription.")
                .foregroundStyle(.secondary)
            statusRow
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.micGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.micGranted ? BarkPalette.lime : .secondary)
            Text(statusText)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusText: String {
        if model.micGranted { return "Microphone access granted." }
        if model.micDenied { return "Access denied. Enable Bark in System Settings → Privacy & Security → Microphone." }
        return "Not granted yet."
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Accessibility access", systemImage: "hand.raised.fill")
                .font(.system(size: 24, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Text("Bark listens for your hotkey and pastes transcribed text. macOS requires Accessibility permission for both.")
                .foregroundStyle(.secondary)
            Text("Open System Settings, toggle Bark on in Privacy & Security → Accessibility. Development builds may need an app restart for the grant to register.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("After an update the old entry can show as enabled but be dead. If the toggle doesn't take: remove Bark from the list with the minus button, then re-add it with plus.")
                .font(.callout)
                .foregroundStyle(.secondary)
            statusRow
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.axGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.axGranted ? BarkPalette.lime : .secondary)
            Text(model.axGranted ? "Accessibility access granted." : "Waiting for permission…")
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct HotkeyStep: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your hotkey", systemImage: "command")
                .font(.system(size: 24, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Text("Hold the hotkey below to record. Release to transcribe and paste.")
                .foregroundStyle(.secondary)
            HStack {
                Text(settings.hotkeyDisplayName)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text("You can change this any time in Settings → Hotkey.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DoneStep: View {
    @ObservedObject private var modelStatus = ModelStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("You're ready", systemImage: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Text("Bark lives in your menu bar. Click the icon any time to see settings, devices, and status.")
                .foregroundStyle(.secondary)
            modelStatusLine
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modelStatusLine: some View {
        switch modelStatus.state {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 180)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("Downloading the voice model (one time, ~1.5 GB). You can close this window — Bark is ready as soon as it finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .unloaded, .loading:
            Label("Preparing the voice model…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready:
            Label("Voice model ready — try it now", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(BarkPalette.lime)
        case .failed:
            Label("Model download failed — check your connection, then use Retry in the menu bar", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
