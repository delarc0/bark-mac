import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    var indicator: OverlayIndicator?
}

/// The pill, bottom centre of the pointer's screen.
struct PillView: View {
    let model: OverlayModel
    let settings: AppSettings
    let level: @MainActor () -> Float

    var body: some View {
        HStack(spacing: 10) { indicator }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 46)
            .background(
                Capsule(style: .continuous)
                    .fill((dark ? BarkPalette.panel : BarkPalette.paperRaised).opacity(0.96))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder((dark ? Color.white : Color.black).opacity(dark ? 0.16 : 0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
            )
            // The hosting view sizes the panel once, so the frame is constant and roomy: wide
            // enough for the widest pill and padded so the shadow fades inside the window.
            .frame(width: 420, height: 170)
    }

    private var dark: Bool { settings.darkOverlay }
    // Lime lives on dark panels only; on paper the accent is forest.
    private var accent: Color { dark ? BarkPalette.lime : BarkPalette.forest }

    @ViewBuilder
    private var indicator: some View {
        switch model.indicator {
        case .recording:
            PulseDot(color: BarkPalette.recordingRed)
            EQBars(color: accent, level: level)
        case .transcribing:
            Spinner(color: accent)
        case .downloading(let fraction):
            Spinner(color: accent)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.1)
                .foregroundStyle(dark ? BarkPalette.bodyOnDark : BarkPalette.paperInk)
        case nil:
            EmptyView()
        }
    }
}

/// The notch island: black, fused with the camera cutout. The top `notchHeight` sits behind the
/// housing; the indicators live in the chin below it. Black in every theme so it reads as the
/// notch itself growing.
struct IslandView: View {
    let model: OverlayModel
    let level: @MainActor () -> Float
    let notchHeight: CGFloat
    let chinDepth: CGFloat
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
                .fill(.black)
            VStack(spacing: 0) {
                Color.clear.frame(height: notchHeight)
                HStack(spacing: 8) { indicator }
                    .frame(height: chinDepth)
            }
        }
        .frame(width: width, height: notchHeight + chinDepth)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.indicator {
        case .recording:
            PulseDot(color: BarkPalette.recordingRed, size: 7)
            EQBars(color: BarkPalette.lime, level: level, maxHeight: 18)
        case .transcribing:
            Spinner(color: BarkPalette.lime, size: 15)
        case .downloading(let fraction):
            Spinner(color: BarkPalette.lime, size: 14)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(BarkPalette.bodyOnDark)
        case nil:
            EmptyView()
        }
    }
}
