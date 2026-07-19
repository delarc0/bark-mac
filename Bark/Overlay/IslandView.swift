import SwiftUI

// The notch "Dynamic Island": a black shape fused with the physical cutout.
// The top `notchHeight` sits behind the camera housing (invisible against the
// black notch); content lives in the chin that hangs below. Always black on
// black regardless of appearance, so it blends into the cutout in any theme.
struct IslandView: View {
    @ObservedObject var model: OverlayModel

    let notchHeight: CGFloat
    let chinDepth: CGFloat
    var width: CGFloat

    private var accent: Color { BarkPalette.lime }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black)

            VStack(spacing: 0) {
                // Behind the camera housing: nothing, it's the bare notch.
                Color.clear.frame(height: notchHeight)
                HStack(spacing: 8) {
                    indicator
                }
                .frame(height: chinDepth)
            }
        }
        .frame(width: width, height: notchHeight + chinDepth)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.state {
        case .recording:
            PulseDot(color: BarkPalette.recordingRed, size: 7)
            EQBars(color: accent, maxHeight: 18)
        case .transcribing:
            Spinner(color: accent, size: 15)
        case .downloading(let fraction):
            Spinner(color: accent, size: 14)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(BarkPalette.bodyOnDark)
        case .idle:
            EmptyView()
        }
    }
}
