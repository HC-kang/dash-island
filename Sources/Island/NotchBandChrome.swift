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
    @State private var statusOpen = false

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

            // Trailing ear — last poll age; click opens per-source status.
            Button {
                statusOpen.toggle()
                if statusOpen {
                    NotificationCenter.default.post(name: .dashIslandRequestKey, object: nil)
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                            .shadow(color: statusColor.opacity(0.5), radius: isLoading ? 0 : 2)
                        Text(statusLabel(relativeTo: context.date))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(syncHot || statusOpen ? 0.88 : 0.52))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.white.opacity(statusOpen ? 0.55 : 0.28))
                            .rotationEffect(.degrees(statusOpen ? 180 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(syncHot || statusOpen ? 0.10 : 0))
                    )
                }
            }
            .buttonStyle(.plain)
            .onHover { h in
                syncHot = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Per-account fetch status")
            .popover(isPresented: $statusOpen, arrowEdge: .bottom) {
                FetchStatusPopover(
                    statuses: orchestrator.fetchStatuses,
                    loading: isLoading,
                    budgetCaption: orchestrator.budgetCaption,
                    onRefreshAll: {
                        orchestrator.refresh()
                    }
                )
            }
            .onChange(of: statusOpen) { open in
                NotificationCenter.default.post(
                    name: .dashIslandStatusPanelOpenChanged,
                    object: open
                )
            }
            .padding(.trailing, 10)
        }
        .frame(height: notchHeight)
        .onDisappear {
            if statusOpen {
                statusOpen = false
                NotificationCenter.default.post(
                    name: .dashIslandStatusPanelOpenChanged,
                    object: false
                )
            }
        }
    }

    private var effectiveUpdated: Date? {
        if DemoWidgets.isForced && AccountStore.shared.accounts.isEmpty {
            return Date().addingTimeInterval(-46)
        }
        return orchestrator.lastUpdated
    }

    private var isLoading: Bool {
        !(DemoWidgets.isForced && AccountStore.shared.accounts.isEmpty) && orchestrator.loading
    }

    private var statusColor: Color {
        if isLoading { return Color.white.opacity(0.35) }
        if orchestrator.fetchStatuses.contains(where: {
            if case .failure = $0.outcome { return true }
            return false
        }) {
            return Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.9)
        }
        if effectiveUpdated != nil { return IslandColor.liveTeal.opacity(0.9) }
        return Color.white.opacity(0.25)
    }

    private func statusLabel(relativeTo now: Date) -> String {
        if isLoading { return "polling…" }
        if let updated = effectiveUpdated {
            return Self.relativeFormatter.localizedString(for: updated, relativeTo: now)
        }
        return "— —"
    }
}

// MARK: - Status popover

private struct FetchStatusPopover: View {
    let statuses: [AccountFetchStatus]
    let loading: Bool
    var budgetCaption: String = ""
    var onRefreshAll: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources")
                    .font(Typography.settingsTitle)
                    .foregroundStyle(.white)
                Spacer()
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .colorScheme(.dark)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if !budgetCaption.isEmpty {
                Text(budgetCaption)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 4)
            }

            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 10)

            if statuses.isEmpty {
                Text("No accounts yet")
                    .font(Typography.settingsRow)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(14)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(statuses) { row in
                            statusRow(row, now: context.date)
                            if row.id != statuses.last?.id {
                                Rectangle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(height: 1)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
            }

            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.top, 4)

            Button(action: onRefreshAll) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text(loading ? "Polling…" : "Refresh all")
                        .font(Typography.settingsRow)
                }
                .foregroundStyle(.white.opacity(loading ? 0.4 : 0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .frame(width: 280)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private func statusRow(_ row: AccountFetchStatus, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VendorLogoBadge(vendorID: row.vendorID)
                .scaleEffect(0.9)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    outcomeDot(row.outcome)
                    Text(outcomeLabel(row.outcome))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(outcomeColor(row.outcome))
                }

                if let attempt = row.lastAttemptAt {
                    Text("requested \(Self.relativeFormatter.localizedString(for: attempt, relativeTo: now))")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                } else {
                    Text("not requested yet")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                if case .failure = row.outcome, let ok = row.lastSuccessAt {
                    Text("last ok \(Self.relativeFormatter.localizedString(for: ok, relativeTo: now))")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                if let cool = row.cooldownUntil, cool > now {
                    Text("cooldown \(Self.relativeFormatter.localizedString(for: cool, relativeTo: now))")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.35).opacity(0.85))
                } else if let next = row.nextDueAt {
                    let label = next <= now
                        ? "due now"
                        : "next \(Self.relativeFormatter.localizedString(for: next, relativeTo: now))"
                    Text(label)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func outcomeDot(_ outcome: AccountFetchStatus.Outcome) -> some View {
        Circle()
            .fill(outcomeColor(outcome))
            .frame(width: 6, height: 6)
    }

    private func outcomeLabel(_ outcome: AccountFetchStatus.Outcome) -> String {
        switch outcome {
        case .never: return "pending"
        case .success: return "ok"
        case .failure(let msg): return msg
        }
    }

    private func outcomeColor(_ outcome: AccountFetchStatus.Outcome) -> Color {
        switch outcome {
        case .never: return Color.white.opacity(0.35)
        case .success: return IslandColor.liveTeal.opacity(0.95)
        case .failure: return Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.95)
        }
    }
}

extension Notification.Name {
    static let dashIslandStatusPanelOpenChanged = Notification.Name("dashIslandStatusPanelOpenChanged")
}
