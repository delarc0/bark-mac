import AppKit
import CoreAudio
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            HotkeyTab(settings: settings)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }

            AudioTab(settings: settings)
                .tabItem { Label("Audio", systemImage: "mic") }

            ModelTab(settings: settings)
                .tabItem { Label("Model", systemImage: "cpu") }

            TextTab(settings: settings)
                .tabItem { Label("Text", systemImage: "text.alignleft") }
        }
        .frame(width: 520, height: 340)
        .padding(20)
        .tint(BarkPalette.neonGreen)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                if let icon = NSImage(named: "Icon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bark")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(BarkPalette.neonGreen)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            row("Bundle ID", Bundle.main.bundleIdentifier ?? "—")

            Divider()

            HStack {
                Text("Feedback sounds").frame(width: 140, alignment: .trailing)
                Toggle("Play start/stop chimes", isOn: $settings.soundsEnabled)
                    .toggleStyle(.switch)
                Spacer()
            }

            HStack {
                Text("Overlay pill").frame(width: 140, alignment: .trailing)
                Toggle("Show while speaking", isOn: $settings.overlayEnabled)
                    .toggleStyle(.switch)
                Spacer()
            }

            HStack {
                Text("Appearance").frame(width: 140, alignment: .trailing)
                Toggle("Dark overlay", isOn: $settings.darkModeEnabled)
                    .toggleStyle(.switch)
                    .disabled(!settings.overlayEnabled)
                Spacer()
            }

            HStack {
                Text("Launch at login").frame(width: 140, alignment: .trailing)
                Text("Requires signed build (coming in Phase 5)")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Spacer()
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .trailing).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Hotkey

private struct HotkeyTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HotkeyRecorder(settings: settings)

            Text("Hold this key anywhere to dictate. Release to transcribe and paste at the cursor.")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .padding(.leading, 92)

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

// MARK: - Audio

private struct AudioTab: View {
    @ObservedObject var settings: AppSettings
    @State private var devices: [AudioDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Input device").frame(width: 120, alignment: .trailing)
                Picker("", selection: selectionBinding) {
                    Text("System default").tag(String?.none)
                    Divider()
                    ForEach(devices) { d in
                        Text("\(d.name)  (\(d.inputChannels)ch @ \(Int(d.sampleRate))Hz)")
                            .tag(String?.some(d.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                Button("Refresh") { reload() }
            }

            Text("Bark downsamples to 16 kHz mono for Whisper regardless of source.")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .padding(.leading, 128)

            Spacer()
        }
        .padding(.top, 4)
        .onAppear { reload() }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { settings.inputDeviceUID },
                set: { settings.inputDeviceUID = $0 })
    }

    private func reload() {
        devices = AudioDeviceCatalog.listInputs()
    }
}

// MARK: - Model

private struct ModelTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Whisper model").frame(width: 120, alignment: .trailing)
                Picker("", selection: $settings.modelVariant) {
                    ForEach(AppSettings.availableModels, id: \.id) { model in
                        Text("\(model.label)  (~\(String(format: "%.2g", model.approxSizeGB)) GB)")
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Language").frame(width: 120, alignment: .trailing)
                Picker("", selection: languageBinding) {
                    Text("Auto").tag(String?.none)
                    Divider()
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.label).tag(String?.some(lang.code))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            Text("Model change takes effect on next launch (downloads on first use). Language applies immediately.")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .padding(.leading, 128)

            Divider()

            HStack {
                Text("Compute").frame(width: 120, alignment: .trailing)
                Toggle("Use CPU + GPU only (fixes hangs on some Macs)", isOn: $settings.computeCpuOnly)
                    .toggleStyle(.switch)
                Spacer()
            }

            Text("The Neural Engine path hangs on some chips (M1, M2 Max). Bark switches this on automatically if it detects a hang at launch. Takes effect on next launch.")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .padding(.leading, 128)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Streaming").frame(width: 120, alignment: .trailing)
                Toggle("Transcribe chunks while you speak (experimental)", isOn: $settings.streamingEnabled)
                    .toggleStyle(.switch)
                Spacer()
            }

            Text("Splits audio at natural pauses and transcribes earlier chunks in the background. Faster on longer dictations. Chunk seams may occasionally drop or duplicate a word.")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .padding(.leading, 128)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.top, 4)
    }

    private var languageBinding: Binding<String?> {
        Binding(get: { settings.language },
                set: { settings.language = $0 })
    }

    private let languages: [(code: String, label: String)] = [
        ("en", "English"),
        ("sv", "Swedish"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("nb", "Norwegian"),
        ("da", "Danish"),
        ("nl", "Dutch"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
    ]
}

// MARK: - Text

private struct TextTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clean up").frame(width: 120, alignment: .trailing)
                Toggle("Remove fillers, fix capitalization", isOn: $settings.cleanupEnabled)
                    .toggleStyle(.switch)
                Spacer()
            }
            Text("Strips um/uh/erm/hmm and capitalizes sentence starts before pasting.")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .padding(.leading, 128)

            Divider()

            HStack(alignment: .top) {
                Text("Replacements").frame(width: 120, alignment: .trailing)
                VocabularyEditor(settings: settings)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }
}

private struct VocabularyEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var draftFrom = ""
    @State private var draftTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let pairs = settings.vocabulary.sorted(by: { $0.key < $1.key })
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pairs, id: \.key) { pair in
                        HStack {
                            Text(pair.key)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 120, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                            Text(pair.value)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button(action: { remove(pair.key) }) {
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 6) {
                TextField("from", text: $draftFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit { add() }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("to", text: $draftTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(draftFrom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let k = draftFrom.trimmingCharacters(in: .whitespaces)
        let v = draftTo.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        var dict = settings.vocabulary
        dict[k] = v
        settings.vocabulary = dict
        draftFrom = ""
        draftTo = ""
    }

    private func remove(_ key: String) {
        var dict = settings.vocabulary
        dict.removeValue(forKey: key)
        settings.vocabulary = dict
    }
}
