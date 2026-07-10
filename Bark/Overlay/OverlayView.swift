import SwiftUI

enum BarkPalette {
    static let surfaceDark = Color(red: 0x1A / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
    static let surfaceLight = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF3 / 255.0)
    static let neonGreen = Color(red: 0x42 / 255.0, green: 0xFC / 255.0, blue: 0x93 / 255.0)
    static let recordingRed = Color(red: 0xFF / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0)
    static let amber = Color(red: 0xFF / 255.0, green: 0xD7 / 255.0, blue: 0x00 / 255.0)
    static let doneGreen = Color(red: 0x7A / 255.0, green: 0xFD / 255.0, blue: 0xB5 / 255.0)
    static let deepGreen = Color(red: 0x0A / 255.0, green: 0x8A / 255.0, blue: 0x42 / 255.0)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            indicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 96, minHeight: 40)
        .background(
            Capsule(style: .continuous)
                .fill(surface.opacity(0.92))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
        )
    }

    private var isDark: Bool { settings.darkModeEnabled }

    private var surface: Color {
        isDark ? BarkPalette.surfaceDark : BarkPalette.surfaceLight
    }

    private var accentGreen: Color {
        isDark ? BarkPalette.neonGreen : BarkPalette.deepGreen
    }

    private var accent: Color {
        switch model.state {
        case .recording: return accentGreen
        case .transcribing: return BarkPalette.amber
        case .idle: return accentGreen.opacity(0.5)
        }
    }

    private var borderColor: Color {
        switch model.state {
        case .recording: return accentGreen.opacity(0.35)
        case .transcribing: return BarkPalette.amber.opacity(0.25)
        case .idle: return (isDark ? Color.white : Color.black).opacity(0.06)
        }
    }

    private var borderWidth: CGFloat {
        model.state == .idle ? 1 : 1.5
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 8) {
                BreathingDot()
                EQBars(color: accentGreen)
            }
        case .transcribing:
            ThinkingDot()
        case .idle:
            EmptyView()
        }
    }
}

private struct EQBars: View {
    let color: Color
    private let barWeights: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 18
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 4

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
            .frame(height: maxHeight)
        }
    }

    private func heightFor(index: Int, t: Double, level: CGFloat) -> CGFloat {
        let weight = barWeights[index]
        let normalized = min(1.0, max(0.0, level / 0.25))
        let oscillation = 0.5 + 0.5 * sin(t * 5.0 + Double(index) * 0.9)
        // Silent: bars rest flat near minHeight. Speaking: they grow and oscillate.
        let baseline: CGFloat = 0.05
        let active = weight * normalized * (0.55 + 0.45 * CGFloat(oscillation))
        let driven = baseline + active
        return minHeight + (maxHeight - minHeight) * driven
    }
}

private struct BreathingDot: View {
    @State private var phase: CGFloat = 1

    var body: some View {
        Circle()
            .fill(BarkPalette.recordingRed)
            .frame(width: 10, height: 10)
            .scaleEffect(phase)
            .opacity(0.6 + 0.4 * phase)
            .shadow(color: BarkPalette.recordingRed.opacity(0.7), radius: 7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    phase = 0.7
                }
            }
    }
}

private struct ThinkingDot: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        Circle()
            .fill(BarkPalette.amber)
            .frame(width: 10, height: 10)
            .opacity(0.45 + 0.55 * phase)
            .shadow(color: BarkPalette.amber.opacity(0.6), radius: 5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}
