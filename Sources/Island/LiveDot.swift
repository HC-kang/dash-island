import SwiftUI

/// Breathing live-status dot — codex-island pattern (teal pulse when active).
struct LiveDot: View {
    let active: Bool
    var bumpToken: Date?

    @State private var syncBump: CGFloat = 1.0

    var body: some View {
        Group {
            if active {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.6 + 0.4 * (sin(phase * 2.6) * 0.5 + 0.5)
                    ZStack {
                        Circle()
                            .fill(IslandColor.liveTeal.opacity(0.9))
                        Circle()
                            .stroke(IslandColor.liveTeal, lineWidth: 1)
                            .scaleEffect(CGFloat(1 + pulse * 0.6))
                            .opacity(0.55 * (1 - pulse))
                    }
                    .frame(width: 6, height: 6)
                    .shadow(color: IslandColor.liveTeal.opacity(0.55), radius: 3)
                }
            } else {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .scaleEffect(syncBump)
        .onChange(of: bumpToken) { _ in
            withAnimation(.easeOut(duration: 0.14)) { syncBump = 1.18 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.18)) { syncBump = 1.0 }
            }
        }
        .accessibilityHidden(true)
    }
}
