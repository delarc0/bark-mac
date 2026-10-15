import AVFoundation
import BarkCapture
import BarkCore
import Foundation

// The S4 desk test on BarkCapture: records a call through CallCapture exactly as a meeting will
// (mic with or without echo cancellation as me, the process tap as them, aligned 100 ms blocks)
// and writes me.wav and them.wav (16 kHz mono), printing levels once a second and every event.
// --app takes a bundle ID (a known call app's helpers are tapped with it) or 'all' for a global
// tap without this process. --list prints the audio processes and the likely call, nothing else.
// Recording triggers the microphone and system audio capture prompts on first use.

let usage = """
    usage: capture-probe --app <bundle-id|all> --seconds N --out <dir> [--aec 0|1]
           capture-probe --list
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

var args: [String: String] = [:]
var argv = CommandLine.arguments.dropFirst()
while let flag = argv.popFirst() {
    guard flag.hasPrefix("--") else { fail(usage) }
    if flag == "--list" {
        args["list"] = "1"
        continue
    }
    guard let value = argv.popFirst() else { fail(usage) }
    args[String(flag.dropFirst(2))] = value
}

func describe(_ process: AudioProcess) -> String {
    let flags = (process.runningInput ? "in " : "   ") + (process.runningOutput ? "out" : "   ")
    let app = process.app.map { "  [\($0.name)\($0.capturesAllTabs ? ", all tabs" : "")]" } ?? ""
    return "\(String(format: "%6d", process.pid))  \(flags)  \(process.bundleID ?? "-")\(app)"
}

if args["list"] == "1" {
    for process in AudioApps.running() { print(describe(process)) }
    print("likely call: \(AudioApps.likelyCall()?.name ?? "none")")
    exit(0)
}

guard let app = args["app"], let seconds = Double(args["seconds"] ?? ""), seconds > 0, let outPath = args["out"] else { fail(usage) }
let aec = (args["aec"] ?? "1") != "0"

let target: SystemAudioTap.Target
if app == "all" {
    target = .global
} else {
    let processes = AudioApps.running()
    let matched = CallApps.app(bundleID: app).map { CallApps.processes(of: $0, in: processes) }
        ?? processes.filter { CallApp(name: app, bundleIDs: [app]).owns($0.bundleID) }
    guard !matched.isEmpty else { fail("No audio process for \(app); is it in a call? (capture-probe --list)") }
    print("tapping:")
    for process in matched { print(describe(process)) }
    target = .processes(matched.map(\.pid))
}

let out = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
let meFile = try AVAudioFile(forWriting: out.appending(path: "me.wav"), settings: settings,
                             commonFormat: .pcmFormatFloat32, interleaved: false)
let themFile = try AVAudioFile(forWriting: out.appending(path: "them.wav"), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)

func write(_ samples: [Float], to file: AVAudioFile) throws {
    guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

struct Level {
    var sumSquares: Double = 0
    var peak: Float = 0
    var count = 0
    mutating func add(_ samples: [Float]) {
        for s in samples {
            sumSquares += Double(s * s)
            peak = max(peak, abs(s))
        }
        count += samples.count
    }
    var text: String {
        guard count > 0 else { return "     -      " }
        let rms = (sumSquares / Double(count)).squareRoot()
        return String(format: "%6.1f dBFS pk %.3f", 20 * log10(max(rms, 1e-9)), peak)
    }
}

let capture = CallCapture()
let events = try capture.start(mode: .call(target), micUID: nil, echoCancellation: aec)
print("recording \(seconds) s, echo cancellation \(aec ? "on" : "off"), into \(out.path)")
Task {
    try? await Task.sleep(for: .seconds(seconds))
    await capture.stop()
}

var blocks = 0
var gaps = 0
var tapSilent = false
var me = Level()
var them = Level()
for await event in events {
    switch event {
    case .audio(let meSamples, let themSamples):
        try write(meSamples, to: meFile)
        try write(themSamples, to: themFile)
        me.add(meSamples)
        them.add(themSamples)
        blocks += 1
        if blocks % 10 == 0 {
            print(String(format: "%5.1f s  me %@  them %@", Double(blocks) / 10, me.text, them.text))
            me = Level()
            them = Level()
        }
    case .gap(let reason):
        gaps += 1
        print("event: gap, \(reason)")
    case .tapSilent:
        tapSilent = true
        print("event: tap silent while the app plays (system audio capture not granted?)")
    case .micHealth(let health):
        print("event: mic \(health)")
    }
}
print(String(format: "done: %.1f s per stream, %d gaps, tap silent: %@", Double(meFile.length) / 16_000, gaps, tapSilent ? "yes" : "no"))
