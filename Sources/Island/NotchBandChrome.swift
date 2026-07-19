import AppKit
import SwiftUI

/// Controls that live in the expanded ears beside the physical notch —
/// not a codex-style bottom footer.
struct NotchBandChrome: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var onOpenPrefs: () -> Void

    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @State private var gearHot = false
    @State private var syncHot = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            // Leading ear — prefs
            Button(action: onOpenPrefs) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(gearHot ? 0.72 : 0.38))
                    .frame(width: 28, height: 22)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(gearHot ? 0.08 : 0))
                    )
            }
            .buttonStyle(.plain)
            .onHover { gearHot = $0 }
            .help("Preferences")
            .padding(.leading, 10)

            Spacer(minLength: 4)

            // Physical notch dead zone — leave empty
            Color.clear
                .frame(width: notchWidth, height: notchHeight)

            Spacer(minLength: 4)

            // Trailing ear — last poll age (paraphrased, not "Synced …")
            Button {
                orchestrator.refresh()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: statusColor.opacity(0.5), radius: isLoading ? 0 : 2)
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(syncHot ? 0.88 : 0.52))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(syncHot ? 0.07 : 0))
                )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .onHover { h in
                syncHot = h
                if h && !isLoading { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Refresh usage now")
            .padding(.trailing, 10)
        }
        .frame(height: notchHeight)
    }

    private var effectiveUpdated: Date? {
        if DemoWidgets.isForced { return Date().addingTimeInterval(-46) }
        return orchestrator.lastUpdated
    }

    private var isLoading: Bool {
        !DemoWidgets.isForced && orchestrator.loading
    }

    private var statusColor: Color {
        if isLoading { return Color.white.opacity(0.35) }
        if effectiveUpdated != nil { return IslandColor.liveTeal.opacity(0.9) }
        return Color.white.opacity(0.25)
    }

    private var statusLabel: String {
        if isLoading { return "polling…" }
        if let updated = effectiveUpdated {
            // Paraphrase: age only, no "Synced" prefix (codex-island language).
            return Self.relativeFormatter.localizedString(for: updated, relativeTo: Date())
        }
        return "— —"
    }
}
