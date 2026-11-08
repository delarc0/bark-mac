import AVFoundation
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, mic, accessibility, hotkey, done
    }

    var step = Step.welcome
    private(set) var micGranted = false
    private(set) var micDenied = false
    private(set) var axGranted = false
    @ObservationIgnored private var timer: Timer?

    init() { refresh() }

    func refresh() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = status == .authorized
        micDenied = status == .denied || status == .restricted
        axGranted = HotkeyMonitor.isTrusted
    }

    func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func advance() { step = Step(rawValue: step.rawValue + 1) ?? step }
    func back() { step = Step(rawValue: step.rawValue - 1) ?? step }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

struct OnboardingView: View {
    let model: OnboardingModel
    let settings: AppSettings
    let models: Models
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)
            Divider()
            controls.padding(16)
        }
        .frame(width: 560, height: 420)
        .tint(BarkPalette.lime)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .mic: MicStep(model: model)
        case .accessibility: AccessibilityStep(model: model)
        case .hotkey: HotkeyStep(settings: settings)
        case .done: DoneStep(models: models)
        }
    }

    private var controls: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= model.step.rawValue ? BarkPalette.lime : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if model.step != .welcome, model.step != .done {
                Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
            }
            primaryButtons
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        switch model.step {
        case .welcome:
            Button("Get started") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .mic:
            if model.micDenied {
                Button("Open System Settings") { SystemSettings.open(.microphone) }.buttonStyle(.bordered)
            } else if !model.micGranted {
                Button("Allow microphone") { model.requestMic() }.buttonStyle(.bordered)
            }
            continueButton
        case .accessibility:
            if !model.axGranted {
                Button("Open System Settings") { HotkeyMonitor.requestTrust() }.buttonStyle(.bordered)
            }
            continueButton
        case .hotkey:
            continueButton
        case .done:
            Button("Finish", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var continueButton: some View {
        Button("Continue") { model.advance() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
    }
}

private struct StatusRow: View {
    let done: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? BarkPalette.lime : .secondary)
            Text(text)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct StepTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 24, weight: .semibold))
            .labelStyle(.titleAndIcon)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
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
            VStack(alignment: .leading, spacing: 10) {
                bullet("100% on-device: audio never leaves your Mac.")
                bullet("Apple Silicon–accelerated (GPU).")
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
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Microphone access", symbol: "mic.fill")
            Text("Bark needs your microphone to capture audio for local transcription.")
                .foregroundStyle(.secondary)
            StatusRow(done: model.micGranted, text: model.micGranted ? "Microphone access granted."
                : model.micDenied ? "Access denied. Enable Bark in System Settings → Privacy & Security → Microphone."
                : "Not granted yet.")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessibilityStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Accessibility access", symbol: "hand.raised.fill")
            Text("Bark listens for your hotkey and pastes transcribed text. macOS requires Accessibility permission for both.")
                .foregroundStyle(.secondary)
            Text("Open System Settings, toggle Bark on in Privacy & Security → Accessibility. Development builds may need an app restart for the grant to register.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("After an update the old entry can show as enabled but be dead. If the toggle doesn't take: remove Bark from the list with the minus button, then re-add it with plus.")
                .font(.callout)
                .foregroundStyle(.secondary)
            StatusRow(done: model.axGranted, text: model.axGranted ? "Accessibility access granted." : "Waiting for permission…")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HotkeyStep: View {
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Your hotkey", symbol: "command")
            Text("Hold the hotkey below to record. Release to transcribe and paste.")
                .foregroundStyle(.secondary)
            HStack {
                Text(settings.hotkey.name)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
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
    let models: Models

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "You're ready", symbol: "sparkles")
            Text("Bark lives in your menu bar. Click the icon any time to see settings, devices, and status.")
                .foregroundStyle(.secondary)
            readiness
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var readiness: some View {
        if let download = models.download {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: download).frame(width: 180)
                    Text("\(Int(download * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Downloading the voice models (one time, \(models.downloadSize)). You can close this window: Bark is ready as soon as it finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch models.state {
                case .ready:
                    Label("Voice model ready: try it now", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(BarkPalette.lime)
                case .loading:
                    Label("Preparing the voice model…", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .failed:
                    Label("The voice model failed to load. Use Retry in the menu bar.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                case .missing:
                    EmptyView()
                }
                if !models.missing.isEmpty { missing }
            }
        }
    }

    @ViewBuilder
    private var missing: some View {
        Text("Not installed: \(models.missing.map { "\($0) (\(Models.size(of: $0)))" }.joined(separator: ", ")).")
            .font(.callout)
        if models.canDownload {
            HStack(spacing: 8) {
                Button("Download (\(models.downloadSize))") { models.downloadMissing() }
                if let error = models.downloadError {
                    Text("Download failed: \(error)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        } else {
            Text("These models are not published yet. On a development Mac, install them with BarkKit/scripts/dev-models.sh, then check again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check again") { models.load() }
        }
    }
}
