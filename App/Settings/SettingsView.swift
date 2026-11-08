import AppKit
import BarkCapture
import BarkCore
import Observation
import SwiftUI

enum SettingsTab: Hashable {
    case general, hotkey, audio, model, text, meetings
}

@MainActor
@Observable
final class SettingsSelection {
    var tab = SettingsTab.general
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var selection: SettingsSelection
    let hq: HQLink

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            HotkeyTab(settings: settings)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
                .tag(SettingsTab.hotkey)
            AudioTab(settings: settings)
                .tabItem { Label("Audio", systemImage: "mic") }
                .tag(SettingsTab.audio)
            ModelTab(settings: settings)
                .tabItem { Label("Model", systemImage: "cpu") }
                .tag(SettingsTab.model)
            TextTab(settings: settings)
                .tabItem { Label("Text", systemImage: "text.alignleft") }
                .tag(SettingsTab.text)
            MeetingsTab(settings: settings, hq: hq, calendar: MeetingLibrary.shared.calendar)
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
                .tag(SettingsTab.meetings)
        }
        .frame(width: 560, height: 400)
        .padding(20)
        .tint(BarkPalette.lime)
    }
}

/// A right-aligned label and its control, the layout every tab uses.
struct Row<Content: View>: View {
    let label: String
    var width: CGFloat = 120
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label).frame(width: width, alignment: .trailing)
            content
            Spacer()
        }
    }
}

struct Note: View {
    let text: String
    var indent: CGFloat = 128
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.system(size: size))
            .padding(.leading, indent)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSImage(named: "Icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bark")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(BarkPalette.lime)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Bundle ID").frame(width: 140, alignment: .trailing).foregroundStyle(.secondary)
                Text(Bundle.main.bundleIdentifier ?? "").textSelection(.enabled)
                Spacer()
            }
            Divider()
            Row(label: "Feedback sounds", width: 140) {
                Toggle("Play start/stop chimes", isOn: $settings.soundsEnabled).toggleStyle(.switch)
            }
            Row(label: "Overlay", width: 140) {
                Toggle("Show while speaking", isOn: $settings.overlayEnabled).toggleStyle(.switch)
            }
            Row(label: "Notch", width: 140) {
                Toggle("Use the notch when available", isOn: $settings.notchIslandEnabled)
                    .toggleStyle(.switch)
                    .disabled(!settings.overlayEnabled)
            }
            Row(label: "Appearance", width: 140) {
                Toggle("Dark overlay", isOn: $settings.darkOverlay)
                    .toggleStyle(.switch)
                    .disabled(!settings.overlayEnabled)
            }
            Row(label: "Launch at login", width: 140) {
                Toggle("Start Bark when you log in", isOn: $settings.launchAtLogin).toggleStyle(.switch)
            }
            Spacer()
            // CC BY 4.0 asks for this credit; the model licences are in App/Resources/speaker-diarization/NOTICE.md.
            Text("Voice models: KB-Whisper by KBLab (Apache 2.0) and Whisper large-v3 by OpenAI (MIT). Speaker detection: pyannote speaker-diarization-community-1 (CC BY 4.0), run with FluidAudio.")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

private struct HotkeyTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HotkeyRecorder(settings: settings)
            Note(text: "Hold this key anywhere to dictate. Release to transcribe and paste at the cursor.", indent: 92, size: 12)
            Divider()
            Text("Tip: if your keyboard doesn't expose right-Option (some QMK/VIA layouts remap it), pick a different modifier or remap the key in your keyboard's firmware.")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.top, 4)
    }
}

private struct AudioTab: View {
    @Bindable var settings: AppSettings
    @State private var devices: [AudioInput] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Row(label: "Input device") {
                Picker("", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    Divider()
                    ForEach(devices) { device in
                        Text(device.label).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                Button("Refresh") { devices = AudioInputs.all() }
            }
            Note(text: "Bark downsamples to 16 kHz mono for Whisper regardless of source.", size: 12)
            Spacer()
        }
        .padding(.top, 4)
        .onAppear { devices = AudioInputs.all() }
    }
}

private struct ModelTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcription").frame(width: 120, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Swedish  →  kb-whisper-large")
                    Text("Everything else  →  whisper-large-v3")
                }
                .font(.system(size: 12, design: .monospaced))
                Spacer()
            }
            Row(label: "Language") {
                Picker("", selection: language) {
                    Text("Auto").tag(String?.none)
                    Divider()
                    ForEach(Languages.common, id: \.code) { Text($0.label).tag(String?.some($0.code)) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            Note(text: "Language applies immediately.", size: 12)
            Divider()
            Row(label: "Swedish model") {
                Toggle("Use kb-whisper-large for Swedish (~\(Models.size(of: Models.swedish)))", isOn: $settings.swedishModelEnabled).toggleStyle(.switch)
                    .onChange(of: settings.swedishModelEnabled) { Models.shared.load() }
            }
            Note(text: "KB-Whisper makes about a third fewer errors on Swedish (5.8% vs 9.4% measured on FLEURS). It loads in the background after launch; until it is ready, Swedish runs on whisper-large-v3.")
            LegacyModelsRow()
            Spacer()
        }
        .padding(.top, 4)
    }

    private var language: Binding<String?> {
        Binding(get: {
            if case .explicit(let code) = settings.language { code } else { nil }
        }, set: {
            settings.language = $0.map(LanguageChoice.explicit) ?? .auto
        })
    }
}

private struct TextTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Row(label: "Clean up") {
                Toggle("Remove fillers, fix capitalization", isOn: $settings.cleanupEnabled).toggleStyle(.switch)
            }
            Note(text: "Strips um/uh/erm/hmm and capitalizes sentence starts before pasting.")
            Divider()
            HStack(alignment: .top) {
                Text("Replacements").frame(width: 120, alignment: .trailing)
                ReplacementsEditor(settings: settings)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }
}

private struct ReplacementsEditor: View {
    @Bindable var settings: AppSettings
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let pairs = settings.vocabulary.sorted { $0.key < $1.key }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pairs, id: \.key) { pair in
                        HStack {
                            Text(pair.key)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 120, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.system(size: 10))
                            Text(pair.value).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button { settings.vocabulary[pair.key] = nil } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    if pairs.isEmpty {
                        Text("No replacements yet. Add pairs like westy → Westie below.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            HStack(spacing: 6) {
                TextField("from", text: $from)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit(add)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("to", text: $to)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let key = from.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        settings.vocabulary[key] = to.trimmingCharacters(in: .whitespaces)
        from = ""
        to = ""
    }
}
