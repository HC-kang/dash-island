import SwiftUI

/// Hairline U-rim with a traveling highlight — light flowing along the edge.
struct NotchRimGlow: View {
    var bottomRadius: CGFloat
    /// Compact sits on the notch; expanded can be a hair softer.
    var lineWidth: CGFloat = 1.0
    var peakOpacity: Double = 0.85
    var baseOpacity: Double = 0.22
    /// Full loop duration (seconds).
    var period: TimeInterval = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period

            NotchRimPath(bottomRadius: bottomRadius)
                .stroke(
                    flowingGradient(phase: phase),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Highlight band sweeps around the U via rotating angular stops.
    private func flowingGradient(phase: Double) -> AngularGradient {
        // Map phase 0…1 → angle so the bright lobe travels continuously.
        let start = Angle.degrees(phase * 360 - 90)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color.white.opacity(baseOpacity), location: 0),
                .init(color: Color.white.opacity(baseOpacity), location: 0.35),
                .init(color: Color.white.opacity(peakOpacity * 0.55), location: 0.48),
                .init(color: Color.white.opacity(peakOpacity), location: 0.55),
                .init(color: Color.white.opacity(peakOpacity * 0.55), location: 0.62),
                .init(color: Color.white.opacity(baseOpacity), location: 0.75),
                .init(color: Color.white.opacity(baseOpacity), location: 1)
            ]),
            center: .center,
            angle: start
        )
    }
}
