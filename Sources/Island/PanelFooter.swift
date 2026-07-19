import AppKit
import SwiftUI

/// Hairline + chip + live sync status + settings gear (codex-island footer language).
struct PanelFooter: View {
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    var onOpenPrefs: () -> Void

    @State private var liveHovered = false
    @State private var gearHovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 18)

            HStack(spacing: 10) {
                gearButton

                Text("ACCOUNTS")
                    .font(Typography.chip)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                            )
                    )

                Spacer(minLength: 8)

                liveStatus
            }
            .frame(height: 24)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var gearButton: some View {
        Button(action: onOpenPrefs) {
            Image(systemName: "gearshape")
                .font(Typography.button)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(gearHovered ? 0.64 : 0.34))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .background {
                    Circle()
                        .fill(.white.opacity(gearHovered ? 0.08 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
        .help("Preferences")
        .accessibilityLabel("Preferences")
    }

    private var effectiveLastUpdated: Date? {
        if DemoWidgets.isForced {
            return Date().addingTimeInterval(-46)
        }
        return orchestrator.lastUpdated
    }

    private var isLoading: Bool {
        !DemoWidgets.isForced && orchestrator.loading
    }

    private var liveStatus: some View {
        Button {
            orchestrator.refresh()
        } label: {
            HStack(spacing: 6) {
                LiveDot(
                    active: effectiveLastUpdated != nil && !isLoading,
                    bumpToken: effectiveLastUpdated
                )
                if isLoading {
                    Text("Syncing…")
                        .font(Typography.label)
                        .foregroundStyle(.white.opacity(0.55))
                } else if let updated = effectiveLastUpdated {
                    Text("Synced")
                        .font(Typography.label)
                        .foregroundStyle(.white.opacity(liveHovered ? 0.85 : 0.55))
                    Text(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                        .font(Typography.bodyNumber)
                        .foregroundStyle(.white.opacity(liveHovered ? 0.95 : 0.72))
                } else {
                    Text("Idle")
                        .font(Typography.label)
                        .foregroundStyle(.white.opacity(liveHovered ? 0.7 : 0.4))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(liveHovered && !orchestrator.loading ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { h in
            liveHovered = h
            if h && !isLoading {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Refresh now")
        .accessibilityLabel(liveSpoken)
        .accessibilityHint("Click to refresh now")
    }

    private var liveSpoken: String {
        if isLoading { return "Syncing" }
        if let updated = effectiveLastUpdated {
            return "Synced \(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))"
        }
        return "Idle"
    }
}
