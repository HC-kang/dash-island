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
    /// Sweep frame interval from `MotionPolicy`; `nil` draws a still rim.
    var frameInterval: TimeInterval? = nil

    /// Still rim: highlight parked at the bottom center (peak stop 0.54 → 90°).
    private static let restPhase = 0.96
    /// When the sweep started, so it departs from the parked highlight instead of
    /// jumping to a wall-clock phase.
    @State private var sweepStart = Date()

    var body: some View {
        Group {
            if let frameInterval {
                TimelineView(.animation(minimumInterval: frameInterval)) { context in
                    let elapsed = context.date.timeIntervalSince(sweepStart)
                    let phase = (Self.restPhase + elapsed / period).truncatingRemainder(dividingBy: 1)
                    rim(phase: phase)
                }
            } else {
                rim(phase: Self.restPhase)
            }
        }
        .onChange(of: frameInterval != nil) { moving in
            if moving { sweepStart = Date() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rim(phase: Double) -> some View {
        NotchRimPath(bottomRadius: bottomRadius)
            .stroke(
                flowingGradient(phase: phase),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
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

private struct IslandMotionKey: EnvironmentKey {
    static let defaultValue = MotionPolicy.Conditions()
}

extension EnvironmentValues {
    /// Low Power / occlusion state of the island window (see `IslandModel`).
    /// Views OR in their own `accessibilityReduceMotion`.
    var islandMotion: MotionPolicy.Conditions {
        get { self[IslandMotionKey.self] }
        set { self[IslandMotionKey.self] = newValue }
    }
}
