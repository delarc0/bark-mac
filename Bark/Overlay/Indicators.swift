import AppKit
import SwiftUI

// lab37.tools design tokens (globals.css). Shared by the pill and the notch island.
enum BarkPalette {
    static let panel = Color(red: 0x1F / 255.0, green: 0x22 / 255.0, blue: 0x20 / 255.0)
    static let lime = Color(red: 0xC9 / 255.0, green: 0xF7 / 255.0, blue: 0x3A / 255.0)
    static let bodyOnDark = Color(red: 0xA8 / 255.0, green: 0xB0 / 255.0, blue: 0xAA / 255.0)
    static let paperRaised = Color(red: 0xFA / 255.0, green: 0xF9 / 255.0, blue: 0xF3 / 255.0)
    static let paperInk = Color(red: 0x40 / 255.0, green: 0x45 / 255.0, blue: 0x3C / 255.0)
    static let forest = Color(red: 0x14 / 255.0, green: 0x29 / 255.0, blue: 0x1D / 255.0)
    // Functional, not brand: a REC dot only reads as recording when it's red.
    static let recordingRed = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
    static let transcribingAmber = Color(red: 0xFF / 255.0, green: 0xD7 / 255.0, blue: 0x00 / 255.0)

    // The menu bar draws with AppKit; same values so the status dot and the
    // pill cannot drift apart.
    static let recordingRedNS = NSColor(recordingRed)
    static let transcribingAmberNS = NSColor(transcribingAmber)
}

// Live audio bars, driven by the mic level. Recording only.
struct EQBars: View {
    let color: Color
    var maxHeight: CGFloat = 22
    // The site's bar silhouette (heights 5,9,14,8,12,6,10 of 14), centered so
    // bars grow symmetrically in both directions.
    private let barWeights: [CGFloat] = [5, 9, 14, 8, 12, 6, 10].map { $0 / 14.0 }
    private let minHeight: CGFloat = 4
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(AudioLevelMonitor.shared.level)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barWeights.count, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: heightFor(index: i, t: t, level: level))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
    }

    private func heightFor(index: Int, t: Double, level: CGFloat) -> CGFloat {
        let weight = barWeights[index]
        let normalized = min(1.0, max(0.0, level / 0.25))
        let oscillation = 0.5 + 0.5 * sin(t * 5.0 + Double(index) * 0.9)
        // Silent: bars rest flat near minHeight. Speaking: they grow and oscillate.
        let baseline: CGFloat = 0.05
        let active = weight * normalized * (0.55 + 0.45 * CGFloat(oscillation))
        return minHeight + (maxHeight - minHeight) * (baseline + active)
    }
}

// Indeterminate spinner: the honest signal for "computing", no sound implied.
struct Spinner: View {
    let color: Color
    var size: CGFloat = 17

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0) * 360
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
    }
}

// Pulsing dot. Red = recording.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 8

    @State private var phase: CGFloat = 1

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(0.5 + 0.5 * phase)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    phase = 0
                }
            }
    }
}
