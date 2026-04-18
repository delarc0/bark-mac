import AppKit
import CoreAudio
import os

@MainActor
final class MenuBarController: NSObject {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "MenuBar")
    private let statusItem: NSStatusItem
    private let recorder: AudioRecorder?
    private let transcriber = Transcriber()
    private var selectedDeviceID: AudioDeviceID?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        recorder = try? AudioRecorder()
        super.init()
        configureButton()
        rebuildMenu()
        Task.detached { [transcriber, log] in
            do {
                let t0 = Date()
                try await transcriber.load()
                log.info("Eager load complete in \(Date().timeIntervalSince(t0), privacy: .public)s")
                await transcriber.warmup()
            } catch {
                log.error("Eager load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.toolTip = "Bark — local dictation"
        if let icon = Self.loadStatusIcon() {
            button.image = icon
        } else {
            button.title = "Bark"
        }
    }

    private static func loadStatusIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false
        return image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Bark v0.1", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(deviceMenuItem())

        let test = NSMenuItem(title: "Test Record 3s → /tmp/bark_test.wav",
                              action: #selector(testRecord),
                              keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let transcribe = NSMenuItem(title: "Test Record 3s → Transcribe",
                                    action: #selector(testTranscribe),
                                    keyEquivalent: "")
        transcribe.target = self
        menu.addItem(transcribe)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func deviceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let defaultID = AudioDeviceCatalog.defaultInputID()
        let systemDefaultItem = NSMenuItem(title: "System default", action: #selector(pickSystemDefault), keyEquivalent: "")
        systemDefaultItem.target = self
        systemDefaultItem.state = (selectedDeviceID == nil) ? .on : .off
        submenu.addItem(systemDefaultItem)
        submenu.addItem(.separator())

        for device in AudioDeviceCatalog.listInputs() {
            let item = NSMenuItem(
                title: "\(device.name)  (\(device.inputChannels)ch @ \(Int(device.sampleRate))Hz)",
                action: #selector(pickDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: device.id)
            let isSelected = selectedDeviceID == device.id ||
                (selectedDeviceID == nil && device.id == defaultID)
            item.state = isSelected ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func pickSystemDefault() {
        selectedDeviceID = nil
        rebuildMenu()
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        selectedDeviceID = AudioDeviceID(number.uint32Value)
        rebuildMenu()
    }

    @objc private func testRecord() {
        guard let recorder else {
            alert("AudioRecorder unavailable.")
            return
        }
        let deviceID = selectedDeviceID

        Task.detached { [weak self] in
            let result: String
            do {
                try recorder.start(deviceID: deviceID)
                recorder.beginRecording()
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                let samples = recorder.endRecording()
                recorder.stop()

                let url = URL(fileURLWithPath: "/tmp/bark_test.wav")
                try WAVWriter.write(samples: samples, sampleRate: AudioRecorder.targetSampleRate, to: url)
                result = "Recorded \(samples.count) samples (\(Double(samples.count) / AudioRecorder.targetSampleRate) s) → /tmp/bark_test.wav"
            } catch {
                result = "Record failed: \(error.localizedDescription)"
            }
            await MainActor.run { [weak self] in
                self?.alert(result)
            }
        }
    }

    @objc private func testTranscribe() {
        guard let recorder else {
            alert("AudioRecorder unavailable.")
            return
        }
        let deviceID = selectedDeviceID
        let transcriber = self.transcriber

        let log = self.log
        Task.detached { [weak self] in
            let result: String
            do {
                try recorder.start(deviceID: deviceID)
                recorder.beginRecording()
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                let samples = recorder.endRecording()
                recorder.stop()
                log.info("Captured samples: count=\(samples.count, privacy: .public) durationSec=\(Double(samples.count) / 16000.0, privacy: .public)")

                let t0 = Date()
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await transcriber.transcribe(samples: samples) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                        throw NSError(domain: "Transcriber", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Transcription timed out after 30s"])
                    }
                    guard let first = try await group.next() else { return "" }
                    group.cancelAll()
                    return first
                }
                log.info("Transcribe elapsed: \(Date().timeIntervalSince(t0), privacy: .public)s")
                result = text.isEmpty ? "(empty transcription)" : text
            } catch {
                result = "Failed: \(error.localizedDescription)"
            }
            await MainActor.run { [weak self] in
                self?.log.info("Transcription result: \(result, privacy: .public)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                self?.alert("Copied to clipboard:\n\n\(result)")
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Bark"
        a.informativeText = message
        a.alertStyle = .informational
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = .floating
        a.window.orderFrontRegardless()
        a.runModal()
        NSApp.setActivationPolicy(.accessory)
    }
}
