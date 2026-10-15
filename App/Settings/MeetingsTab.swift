import BarkCore
import Foundation
import SwiftUI

struct MeetingsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var hq: HQLink
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Row(label: "Keep audio") {
                Picker("", selection: $settings.audioRetention) {
                    Text("7 days").tag(AudioRetention.week)
                    Text("30 days").tag(AudioRetention.month)
                    Text("90 days").tag(AudioRetention.quarter)
                    Text("Forever").tag(AudioRetention.forever)
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            Note(text: "Transcripts and notes are always kept. Only the recorded audio is deleted.")
            Row(label: "Echo cancellation") {
                Toggle("Keep your speakers' sound out of the microphone", isOn: $settings.echoCancellation).toggleStyle(.switch)
            }
            Note(text: "Applies from the next meeting.")
            Divider()
            Row(label: "hq") {
                Text(status)
                    .foregroundStyle(hq.status == .needsReconnect ? .orange : .primary)
            }
            HStack(spacing: 8) {
                if hq.status != .connected {
                    Button("Connect to hq") { hq.connect() }
                        .disabled(hq.baseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if hq.status == .connected || hq.status == .needsReconnect {
                    Button("Disconnect") { hq.disconnect() }
                }
            }
            .padding(.leading, 128)
            if let problem = hq.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.leading, 128)
            } else {
                Note(text: "Finished meetings go to hq, where its agent writes the notes and tasks. Nothing is sent until you connect.")
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                Row(label: "hq address") {
                    TextField("https://hq.example.com", text: $hq.baseText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { hq.applyBase() }
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(.top, 4)
        .onAppear {
            hq.refresh()
            advanced = hq.status == .off
        }
    }

    private var status: String {
        switch hq.status {
        case .off: "Off"
        case .notConnected: hq.isPairing ? "Waiting for your approval in the browser…" : "Not connected"
        case .connected: "Connected to \(hq.host ?? "hq")"
        case .needsReconnect: "hq signed this Mac out. Connect again to keep sending meetings."
        }
    }
}

/// Bark 0.2's CoreML models in ~/Documents/huggingface, about 6 GB Bark no longer uses. Offered for
/// removal, never deleted silently. Looking only happens when the Model tab opens, since reading
/// Documents can bring up the Files and Folders prompt.
struct LegacyModelsRow: View {
    @State private var size: Int64?
    @State private var confirming = false

    var body: some View {
        Group {
            if let size {
                Divider()
                Row(label: "Old models") {
                    Button("Remove Old Bark Models…") { confirming = true }
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Note(text: "Bark 0.2 kept its voice models in Documents/huggingface. This version doesn't use them.")
            }
        }
        .task { size = await Task.detached { LegacyModels.size() }.value }
        .confirmationDialog("Remove the old Bark models?", isPresented: $confirming) {
            Button("Remove", role: .destructive) {
                Task {
                    size = await Task.detached {
                        LegacyModels.remove()
                        return LegacyModels.size()
                    }.value
                }
            }
        } message: {
            Text("Deletes Bark 0.2's two model folders in Documents/huggingface. Nothing else is touched.")
        }
    }
}

enum LegacyModels {
    static let folders = [
        "Documents/huggingface/models/argmaxinc/whisperkit-coreml",
        "Documents/huggingface/models/lab37/kb-whisper-coreml",
    ].map { URL.homeDirectory.appending(path: $0, directoryHint: .isDirectory) }

    /// Bytes on disk across the folders that exist; nil when neither does.
    static func size() -> Int64? {
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        return existing.reduce(Int64(0)) { total, folder in
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)?.compactMap { $0 as? URL } ?? []
            return total + files.reduce(Int64(0)) { sum, file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                return sum + (values?.isRegularFile == true ? Int64(values?.totalFileAllocatedSize ?? 0) : 0)
            }
        }
    }

    static func remove() {
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
