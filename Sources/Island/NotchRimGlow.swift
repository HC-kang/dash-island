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
    /// Highlight tint (defaults to white/silver).
    var accent: Color = .white

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
    /// Peak stops stay near full saturation so neon accents read hot, not washed.
    private func flowingGradient(phase: Double) -> AngularGradient {
        let start = Angle.degrees(phase * 360 - 90)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: accent.opacity(baseOpacity * 0.85), location: 0),
                .init(color: accent.opacity(baseOpacity), location: 0.32),
                .init(color: accent.opacity(min(1, peakOpacity * 0.7)), location: 0.46),
                .init(color: accent.opacity(min(1, peakOpacity)), location: 0.54),
                .init(color: accent.opacity(min(1, peakOpacity * 0.7)), location: 0.62),
                .init(color: accent.opacity(baseOpacity), location: 0.78),
                .init(color: accent.opacity(baseOpacity * 0.85), location: 1)
            ]),
            center: .center,
            angle: start
        )
    }
}
