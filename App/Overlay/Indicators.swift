import AppKit
import SwiftUI

// lab37.tools design tokens, shared by the pill, the notch island and the menu bar.
enum BarkPalette {
    static let panel = Color(red: 0x1F / 255, green: 0x22 / 255, blue: 0x20 / 255)
    static let lime = Color(red: 0xC9 / 255, green: 0xF7 / 255, blue: 0x3A / 255)
    static let bodyOnDark = Color(red: 0xA8 / 255, green: 0xB0 / 255, blue: 0xAA / 255)
    static let paperRaised = Color(red: 0xFA / 255, green: 0xF9 / 255, blue: 0xF3 / 255)
    static let paperInk = Color(red: 0x40 / 255, green: 0x45 / 255, blue: 0x3C / 255)
    static let forest = Color(red: 0x14 / 255, green: 0x29 / 255, blue: 0x1D / 255)
    // Functional, not brand: a REC dot only reads as recording when it is red.
    static let recordingRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let transcribingAmber = Color(red: 0xFF / 255, green: 0xD7 / 255, blue: 0x00 / 255)
}

/// What the overlay shows. Wordless: the dot and bars mean sound is being taken, the spinner
/// means the machine is working, and only a download adds a number because it can be counted.
enum OverlayIndicator: Equatable {
    case recording
    case transcribing
    case downloading(Double)
}

/// Live bars driven by the mic level. Recording only.
struct EQBars: View {
    let color: Color
    let level: () -> Float
    var maxHeight: CGFloat = 22
    // The site's bar silhouette (5, 9, 14, 8, 12, 6, 10 of 14), centered so bars grow both ways.
    private let weights: [CGFloat] = [5, 9, 14, 8, 12, 6, 10].map { $0 / 14 }
    private let minHeight: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(level())
            HStack(alignment: .center, spacing: 3) {
                ForEach(weights.indices, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: height(i, t: t, level: level))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func height(_ index: Int, t: Double, level: CGFloat) -> CGFloat {
        let normalized = min(1, max(0, level / 0.25))
        let oscillation = 0.5 + 0.5 * sin(t * 5 + Double(index) * 0.9)
        // Silent: the bars rest near the minimum. Speaking: they grow and move.
        let active = weights[index] * normalized * (0.55 + 0.45 * CGFloat(oscillation))
        return minHeight + (maxHeight - minHeight) * (0.05 + active)
    }
}

/// Indeterminate spinner: computing, no sound implied.
struct Spinner: View {
    let color: Color
    var size: CGFloat = 17

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

/// The pulsing REC dot.
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
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { phase = 0 }
            }
    }
}
