/// The two sides of a call: the microphone (me) and the tapped system audio (them).
public enum CallSide: Sendable, Equatable {
    case me, them
}

/// Pairs two independently clocked 16 kHz sources into aligned blocks of equal length, so the two
/// meeting streams stay aligned by sample count (MeetingSession times each stream by its count).
///
/// Chunks arrive in any size and order. The clock is the other side's sample count: a side that
/// delivers nothing while the other delivers more than `gapAfter` samples has dropped out. It is
/// reported once, then padded with silence as the other side runs, until it delivers again. A
/// side's first chunk is padded at its start up to what the other side already holds, since both
/// end at the same moment. Every sample delivered comes out once, in order; padding only adds zeros.
/// A side that comes back with a backlog after a stall lands after its padding, later by that much.
public struct BlockAligner: Sendable {
    public enum Output: Sendable, Equatable {
        case block(me: [Float], them: [Float])
        /// That side delivered nothing for more than `gapAfter` samples of the other's audio.
        case gap(CallSide)
    }

    public static let blockSize = 1_600
    public static let gapAfter = 16_000

    private struct Side {
        var pending: [Float] = []
        var started = false
        /// Samples the other side delivered since this one last did.
        var idle = 0
        var inGap = false
    }

    private let paired: Bool
    private var me = Side()
    private var them = Side()

    /// `paired: false` is mic only: blocks carry an empty `them` and no gap is ever reported.
    public init(paired: Bool = true) {
        self.paired = paired
    }

    public mutating func append(_ samples: [Float], from side: CallSide) -> [Output] {
        guard !samples.isEmpty else { return [] }
        guard paired else {
            guard side == .me else { return [] }
            me.pending += samples
            return blocks()
        }
        var output: [Output] = []
        update(side) { this, other in
            if !this.started {
                this.started = true
                this.pending += [Float](repeating: 0, count: max(0, other.pending.count - this.pending.count - samples.count))
            }
            this.pending += samples
            this.idle = 0
            this.inGap = false
            other.idle += samples.count
            if other.idle > Self.gapAfter, !other.inGap {
                other.inGap = true
                output.append(.gap(side == .me ? .them : .me))
            }
            if other.inGap, other.pending.count < this.pending.count {
                other.pending += [Float](repeating: 0, count: this.pending.count - other.pending.count)
            }
        }
        return output + blocks()
    }

    /// Everything still held, the shorter side padded to the longer; the last pair may be shorter
    /// than a block.
    public mutating func flush() -> [Output] {
        var output = blocks()
        let length = max(me.pending.count, paired ? them.pending.count : 0)
        guard length > 0 else { return output }
        me.pending += [Float](repeating: 0, count: length - me.pending.count)
        if paired { them.pending += [Float](repeating: 0, count: length - them.pending.count) }
        output.append(.block(me: me.pending, them: paired ? them.pending : []))
        me.pending = []
        them.pending = []
        return output
    }

    private mutating func update(_ side: CallSide, _ body: (inout Side, inout Side) -> Void) {
        switch side {
        case .me: body(&me, &them)
        case .them: body(&them, &me)
        }
    }

    private mutating func blocks() -> [Output] {
        let size = Self.blockSize
        let available = paired ? min(me.pending.count, them.pending.count) : me.pending.count
        let count = available / size
        guard count > 0 else { return [] }
        let output = (0 ..< count).map { i in
            Output.block(me: Array(me.pending[i * size ..< (i + 1) * size]),
                         them: paired ? Array(them.pending[i * size ..< (i + 1) * size]) : [])
        }
        me.pending.removeFirst(count * size)
        if paired { them.pending.removeFirst(count * size) }
        return output
    }
}

/// Tells a denied system-audio capture from a quiet call: macOS feeds a tap digital zero when the
/// grant is missing, while the tapped app still reports that it is playing. 5 s of exact zeros
/// while the app plays points to the grant, not to a quiet call (S4 confirms on real calls).
public struct TapSilence: Sendable {
    public static let window = 5 * 16_000

    private var zeroRun = 0
    private var reported = false

    public init() {}

    /// Feed every tap chunk with whether the tapped processes report output running. Returns true
    /// once per silent stretch, when it reaches `window` samples.
    public mutating func observe(_ samples: [Float], sourcePlaying: Bool) -> Bool {
        guard !samples.isEmpty else { return false }
        guard samples.allSatisfy({ $0 == 0 }) else {
            zeroRun = 0
            reported = false
            return false
        }
        guard sourcePlaying else {
            zeroRun = 0
            return false
        }
        zeroRun += samples.count
        guard zeroRun >= Self.window, !reported else { return false }
        reported = true
        return true
    }
}

/// A process the audio system knows about, as Core Audio reports it.
public struct AudioProcess: Sendable, Equatable {
    /// The Core Audio process object, which a tap is built from.
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let runningInput: Bool
    public let runningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, runningInput: Bool, runningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.runningInput = runningInput
        self.runningOutput = runningOutput
    }

    public var app: CallApp? { CallApps.app(bundleID: bundleID) }
}

/// An app a call runs in. Its audio may come from helper processes, which share a bundle ID root
/// (`com.google.Chrome.helper` under `com.google.Chrome`).
public struct CallApp: Sendable, Hashable {
    public let name: String
    public let bundleIDs: [String]
    /// A browser: tapping it captures every tab, not just the call, and the UI has to say so.
    public let capturesAllTabs: Bool

    public init(name: String, bundleIDs: [String], capturesAllTabs: Bool = false) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.capturesAllTabs = capturesAllTabs
    }

    public func owns(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return bundleIDs.contains { root in
            let root = root.lowercased()
            return id == root || id.hasPrefix(root + ".")
        }
    }
}

public enum CallApps {
    /// Call apps first: when a call app and a browser both hold the mic, the call app is the call.
    public static let known: [CallApp] = [
        CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        CallApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        CallApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        // Call audio may run in avconferenced rather than FaceTime itself (unverified, S4 desk test).
        CallApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        CallApp(name: "Webex", bundleIDs: ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]),
        CallApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        CallApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], capturesAllTabs: true),
        // Safari's media plays in WebKit's GPU process, which every WebKit app shares.
        CallApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"], capturesAllTabs: true),
        CallApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], capturesAllTabs: true),
        CallApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], capturesAllTabs: true),
        // Firefox's content processes are not under its bundle ID.
        CallApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox", "org.mozilla.plugincontainer"], capturesAllTabs: true),
        CallApp(name: "Brave", bundleIDs: ["com.brave.Browser"], capturesAllTabs: true),
    ]

    public static func app(bundleID: String?) -> CallApp? {
        known.first { $0.owns(bundleID) }
    }

    /// A call is likely when a known call app or a browser is running audio input (Google Meet
    /// runs in a browser). Returns that app, a call app ahead of a browser.
    public static func likelyCall(_ processes: [AudioProcess]) -> CallApp? {
        let live = Set(processes.filter(\.runningInput).compactMap(\.app))
        return known.first { live.contains($0) }
    }

    /// Every process of `app`, helpers included: the set a per-app tap is built from.
    public static func processes(of app: CallApp, in processes: [AudioProcess]) -> [AudioProcess] {
        processes.filter { app.owns($0.bundleID) }
    }
}
