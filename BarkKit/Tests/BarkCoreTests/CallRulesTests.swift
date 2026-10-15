import BarkCore
import Testing

struct BlockAlignerTests {
    static let block = BlockAligner.blockSize

    /// A source whose samples are 1, 2, 3, ... (negated for them), so padding zeros, order and
    /// duplicates are all visible.
    struct Source {
        let sign: Float
        var next = 1
        mutating func take(_ count: Int) -> [Float] {
            defer { next += count }
            return (next ..< next + count).map { sign * Float($0) }
        }
    }

    struct Run {
        var aligner: BlockAligner
        var me = Source(sign: 1)
        var them = Source(sign: -1)
        var outMe: [Float] = []
        var outThem: [Float] = []
        var gaps: [CallSide] = []
        var pairs = 0

        init(paired: Bool = true) { aligner = BlockAligner(paired: paired) }

        mutating func feed(_ side: CallSide, _ count: Int) {
            let samples = side == .me ? me.take(count) : them.take(count)
            collect(aligner.append(samples, from: side))
        }

        mutating func flush() { collect(aligner.flush()) }

        mutating func collect(_ outputs: [BlockAligner.Output]) {
            for output in outputs {
                switch output {
                case .block(let m, let t):
                    #expect(t.isEmpty || t.count == m.count)
                    outMe += m
                    outThem += t
                    pairs += 1
                case .gap(let side):
                    gaps.append(side)
                }
            }
        }
    }

    /// A tiny deterministic generator, so a failing interleaving can be replayed.
    struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test(arguments: [1, 7, 42, 1_234])
    func arbitraryChunksComeOutWholeAndInOrder(seed: UInt64) {
        var run = Run()
        var rng = LCG(state: seed)
        // Both sources stay within a quarter second of each other, chunk sizes 1 to 2400.
        while run.me.next < 160_000 {
            let side: CallSide = run.me.next - run.them.next > 4_000 ? .them
                : run.them.next - run.me.next > 4_000 ? .me
                : rng.next(2) == 0 ? .me : .them
            run.feed(side, 1 + rng.next(2_400))
        }
        let blocks = run.pairs
        run.flush()
        #expect(run.gaps.isEmpty)
        #expect(blocks > 90)
        #expect(run.outMe.filter { $0 != 0 } == (1 ..< run.me.next).map(Float.init))
        #expect(run.outThem.filter { $0 != 0 } == (1 ..< run.them.next).map { -Float($0) })
        #expect(run.outMe.count == run.outThem.count)
    }

    @Test func fullBlocksOnlyUntilFlush() {
        var run = Run()
        run.feed(.me, 1_000)
        run.feed(.them, 2_000)
        #expect(run.pairs == 0)
        run.feed(.me, 700)
        #expect(run.pairs == 1)
        #expect(run.outMe == (1 ... 1_600).map(Float.init))
        run.flush()
        #expect(run.outMe.count == 2_000)
        #expect(run.outMe.suffix(300).allSatisfy { $0 == 0 })
        #expect(run.outThem.suffix(400).allSatisfy { $0 != 0 })
    }

    @Test func lagUnderASecondIsNotAGap() {
        var run = Run()
        run.feed(.them, 100)
        run.feed(.me, 16_000)
        run.feed(.them, 15_900)
        #expect(run.gaps.isEmpty)
        #expect(run.outThem.allSatisfy { $0 != 0 })
        #expect(run.pairs == 10)
    }

    @Test func dropoutIsPaddedAndReportedOnce() {
        var run = Run()
        run.feed(.me, 8_000)
        run.feed(.them, 8_000)
        // Them goes quiet for three seconds while me keeps running, in 100 ms chunks.
        for _ in 0 ..< 30 { run.feed(.me, 1_600) }
        #expect(run.gaps == [.them])
        // Padding keeps blocks flowing without waiting for them.
        #expect(run.outMe.count == 8_000 + 48_000)
        #expect(run.outThem.suffix(48_000).allSatisfy { $0 == 0 })
        run.feed(.them, 1_600)
        run.feed(.me, 1_600)
        #expect(run.gaps == [.them])
        // Back again: its next samples follow the padding, aligned with me's.
        #expect(Array(run.outThem.suffix(1_600)) == (8_001 ... 9_600).map { -Float($0) })
        // A second dropout is a second report.
        for _ in 0 ..< 12 { run.feed(.me, 1_600) }
        #expect(run.gaps == [.them, .them])
    }

    @Test func aSourceThatNeverStartsIsAGap() {
        var run = Run()
        for _ in 0 ..< 11 { run.feed(.them, 1_600) }
        #expect(run.gaps == [.me])
        #expect(run.outThem.count == 17_600)
        #expect(run.outMe.allSatisfy { $0 == 0 })
    }

    @Test func aLateStartIsPaddedAtItsStart() {
        var run = Run()
        run.feed(.me, 3_200)
        run.feed(.them, 1_600)
        #expect(run.pairs == 2)
        #expect(run.outThem.prefix(1_600).allSatisfy { $0 == 0 })
        #expect(Array(run.outThem.suffix(1_600)) == (1 ... 1_600).map { -Float($0) })
        // Only the first chunk is padded: later lag waits for the source instead.
        run.feed(.me, 3_200)
        run.feed(.them, 1_600)
        #expect(run.outThem.filter { $0 == 0 }.count == 1_600)
    }

    @Test func micOnlyBlocksCarryNoThem() {
        var run = Run(paired: false)
        run.feed(.me, 5_000)
        run.feed(.them, 5_000)
        #expect(run.pairs == 3)
        #expect(run.outThem.isEmpty)
        run.flush()
        #expect(run.outMe == (1 ... 5_000).map(Float.init))
        #expect(run.gaps.isEmpty)
    }
}

struct TapSilenceTests {
    static let zeros = [Float](repeating: 0, count: 1_600)

    @Test func fiveSecondsOfZerosWhilePlayingFiresOnce() {
        var watch = TapSilence()
        let fired = (0 ..< 80).map { _ in watch.observe(Self.zeros, sourcePlaying: true) }
        #expect(fired.filter { $0 }.count == 1)
        #expect(fired.firstIndex(of: true) == 49)
    }

    @Test func zerosWhileTheAppIsNotPlayingAreAQuietCall() {
        var watch = TapSilence()
        for _ in 0 ..< 80 { let fired = watch.observe(Self.zeros, sourcePlaying: false); #expect(!fired) }
        // Playing again restarts the count.
        for _ in 0 ..< 49 { let fired = watch.observe(Self.zeros, sourcePlaying: true); #expect(!fired) }
    }

    @Test func anySignalResetsIt() {
        var watch = TapSilence()
        for _ in 0 ..< 49 { _ = watch.observe(Self.zeros, sourcePlaying: true) }
        var signal = Self.zeros
        signal[800] = 0.0001
        let early = watch.observe(signal, sourcePlaying: true)
        #expect(!early)
        for _ in 0 ..< 49 { let fired = watch.observe(Self.zeros, sourcePlaying: true); #expect(!fired) }
        let fired = watch.observe(Self.zeros, sourcePlaying: true)
        #expect(fired)
    }
}

struct CallAppsTests {
    static func process(_ bundleID: String?, input: Bool = false, output: Bool = false) -> AudioProcess {
        AudioProcess(objectID: 1, pid: 1, bundleID: bundleID, runningInput: input, runningOutput: output)
    }

    @Test(arguments: [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap.helper", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.hnc.Discord.helper.Renderer", "Discord"),
        ("com.google.Chrome.helper.renderer", "Google Chrome"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac.helper", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser.helper", "Brave"),
    ])
    func classifiesByBundleIDRoot(bundleID: String, name: String) {
        #expect(CallApps.app(bundleID: bundleID)?.name == name)
    }

    @Test func aRootMatchesOnlyWholeComponents() {
        #expect(CallApps.app(bundleID: "com.google.Chromeish") == nil)
        #expect(CallApps.app(bundleID: "com.microsoft.teams2")?.bundleIDs.first == "com.microsoft.teams2")
        #expect(CallApps.app(bundleID: "COM.GOOGLE.CHROME")?.name == "Google Chrome")
        #expect(CallApps.app(bundleID: "com.spotify.client") == nil)
        #expect(CallApps.app(bundleID: nil) == nil)
    }

    @Test func browsersCaptureAllTabsAndCallAppsDoNot() {
        #expect(CallApps.app(bundleID: "com.google.Chrome")?.capturesAllTabs == true)
        #expect(CallApps.app(bundleID: "com.apple.Safari")?.capturesAllTabs == true)
        #expect(CallApps.app(bundleID: "us.zoom.xos")?.capturesAllTabs == false)
    }

    @Test func aCallNeedsAudioInputFromACallAppOrBrowser() {
        #expect(CallApps.likelyCall([Self.process("us.zoom.xos", output: true)]) == nil)
        #expect(CallApps.likelyCall([Self.process("com.spotify.client", input: true)]) == nil)
        #expect(CallApps.likelyCall([Self.process("us.zoom.xos", input: true)])?.name == "Zoom")
        #expect(CallApps.likelyCall([Self.process("com.google.Chrome.helper", input: true)])?.name == "Google Chrome")
        #expect(CallApps.likelyCall([]) == nil)
    }

    @Test func aCallAppBeatsABrowserHoldingTheMic() {
        let processes = [Self.process("com.google.Chrome.helper", input: true),
                         Self.process("com.microsoft.teams2", input: true, output: true)]
        #expect(CallApps.likelyCall(processes)?.name == "Microsoft Teams")
    }

    @Test func aTapTakesEveryProcessOfTheApp() {
        let processes = [Self.process("com.tinyspeck.slackmacgap"), Self.process("com.tinyspeck.slackmacgap.helper", output: true),
                         Self.process("com.google.Chrome.helper")]
        let slack = CallApps.app(bundleID: "com.tinyspeck.slackmacgap")!
        #expect(CallApps.processes(of: slack, in: processes).count == 2)
    }
}
