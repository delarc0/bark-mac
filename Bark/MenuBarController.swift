import AppKit
import CoreAudio
import os

@MainActor
final class MenuBarController: NSObject {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "MenuBar")
    private let statusItem: NSStatusItem
    private let recorder: AudioRecorder?
    private var selectedDeviceID: AudioDeviceID?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        recorder = try? AudioRecorder()
        super.init()
        configureButton()
        rebuildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = "Bark"
        button.toolTip = "Bark — local dictation"
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Bark"
        a.informativeText = message
        a.alertStyle = .informational
        NSApplication.shared.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
