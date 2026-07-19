import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @ObservedObject private var preferences = PreferencesStore.shared

    @State private var prefsOpen = false
    @State private var collapseTask: Task<Void, Never>?

    private let bodyOutset: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            if model.state == .expanded {
                expandedChrome
                    .transition(.opacity)
                expandedContent
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else {
                compactChrome
                    .transition(.opacity)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.state)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.size.width)
        .onHover { handleHover($0) }
        .onAppear { syncExpandedItemCount() }
        .onChange(of: accountStore.accounts.count) { _ in syncExpandedItemCount() }
        .onChange(of: orchestrator.widgets.count) { _ in syncExpandedItemCount() }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandPrefsOpenChanged)) { note in
            let open = (note.object as? Bool) ?? PrefsWindowController.shared.isOpen
            prefsOpen = open
            if open {
                collapseTask?.cancel()
                model.setState(.expanded)
            } else if model.state == .expanded {
                scheduleCollapse()
            }
        }
    }

    private func openPrefs() {
        // Separate NSPanel — never `.sheet` on the island (that drags the HUD down).
        PrefsWindowController.shared.show()
    }

    private func syncExpandedItemCount() {
        if showEmptyAdd {
            model.setExpandedItemCount(0)
        } else {
            model.setExpandedItemCount(widgets.count)
        }
    }

    // MARK: - Compact

    private var compactChrome: some View {
        let nw = model.notch.width
        let nh = model.notch.height
        let bodyW = nw + bodyOutset * 2
        let bodyH = nh + bodyOutset
        let radius = cornerRadius(forHeight: bodyH)

        return ZStack {
            IslandShape(bottomRadius: radius)
                .fill(Color.black)
            NotchRimGlow(bottomRadius: radius, lineWidth: 1.0, peakOpacity: 0.88, baseOpacity: 0.20)
        }
        .frame(width: bodyW, height: bodyH)
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .contentShape(IslandShape(bottomRadius: radius))
        .onTapGesture {
            collapseTask?.cancel()
            model.setState(.expanded)
        }
        .accessibilityLabel("Dash Island")
        .accessibilityHint("Hover or click to show usage")
        .accessibilityValue(compactLabel)
    }

    // MARK: - Expanded (slim: gauges only + notch-ear chrome)

    private var expandedChrome: some View {
        let radius = min(26, cornerRadius(forHeight: model.notch.height) + 8)
        return ZStack {
            IslandShape(bottomRadius: radius)
                .fill(Color.black)
            NotchRimGlow(
                bottomRadius: radius,
                lineWidth: 0.95,
                peakOpacity: 0.72,
                baseOpacity: 0.16,
                period: 3.2
            )
        }
        .frame(width: model.size.width, height: model.blackHeight)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Ears around the physical notch: prefs · [notch] · poll age
            NotchBandChrome(
                notchWidth: model.notch.width,
                notchHeight: model.notch.height
            ) {
                openPrefs()
            }

            GaugeClusterView(
                widgets: widgets,
                accountCount: accountStore.accounts.count,
                showEmptyAdd: showEmptyAdd,
                showAdd: showAdd,
                allowsEditing: true,
                panelBlackHeight: model.blackHeight
            )
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .frame(width: model.size.width, height: model.blackHeight, alignment: .top)
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
    }

    private func cornerRadius(forHeight h: CGFloat) -> CGFloat {
        min(16, max(11, h * 0.40))
    }

    private var compactLabel: String {
        if DemoWidgets.isForced { return "Demo" }
        let n = accountStore.accounts.count
        if n == 0 { return "Dash Island" }
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    private var widgets: [WidgetViewModel] {
        if DemoWidgets.isForced { return DemoWidgets.make() }
        return orchestrator.widgets
    }

    private var showEmptyAdd: Bool {
        !DemoWidgets.isForced && accountStore.accounts.isEmpty
    }

    /// Trailing + whenever under the 5-account cap (demo hides it).
    private var showAdd: Bool {
        !DemoWidgets.isForced
            && accountStore.accounts.count < AccountStore.maxAccounts
    }

    private func handleHover(_ hovering: Bool) {
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            model.setState(.expanded)
        } else if !prefsOpen {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, !prefsOpen else { return }
            model.setState(.compact)
        }
    }
}
