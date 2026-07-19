import SwiftUI

// The bottom-center pill. Shares its visual vocabulary (BarkPalette, EQBars,
// Spinner, PulseDot) with the notch island via Indicators.swift.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            indicator
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 46)
        .background(
            Capsule(style: .continuous)
                .fill(surface.opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
        )
        // NSHostingView sizes the panel to this view's intrinsic size, and it
        // sizes it ONCE — so the view must be constant and roomy: wide enough
        // for the widest pill (downloading, "· 99%") and padded enough that
        // the shadow fades out inside the window instead of clipping into a
        // hard rectangular plate around the pill.
        .frame(width: 420, height: 170)
    }

    private var isDark: Bool { settings.darkModeEnabled }

    private var surface: Color {
        isDark ? BarkPalette.panel : BarkPalette.paperRaised
    }

    // Lime lives on dark panels only; on paper the accent is forest (site rule).
    private var accent: Color {
        isDark ? BarkPalette.lime : BarkPalette.forest
    }

    private var labelColor: Color {
        isDark ? BarkPalette.bodyOnDark : BarkPalette.paperInk
    }

    private var hairline: Color {
        (isDark ? Color.white : Color.black).opacity(isDark ? 0.16 : 0.12)
    }

    // The red REC dot carries the recording state; the border stays a quiet
    // neutral hairline in every state so the dot does the talking.
    private var borderColor: Color { hairline }

    // Wordless. Recording = red REC dot + live audio bars (sound is happening).
    // Transcribing/downloading = spinner (computation, no sound) — a spinner
    // reads as "the machine is working"; bars would falsely imply live audio.
    // Only the download adds a number, because progress can be counted.
    @ViewBuilder
    private var indicator: some View {
        switch model.state {
        case .recording:
            PulseDot(color: BarkPalette.recordingRed)
            EQBars(color: accent)
        case .transcribing:
            Spinner(color: accent)
        case .downloading(let fraction):
            Spinner(color: accent)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.1)
                .foregroundStyle(labelColor)
        case .idle:
            EmptyView()
        }
    }
}
