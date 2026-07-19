import SwiftUI

struct IslandRootView: View {
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared

    var body: some View {
        GaugeClusterView(
            widgets: widgets,
            accountCount: accountStore.accounts.count,
            showEmptyAdd: showEmptyAdd,
            showEdgeChrome: showEdgeChrome
        )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            // Extra bottom room so hover tooltips aren't clipped by the window.
            .padding(.bottom, 52)
            .background(islandBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var widgets: [WidgetViewModel] {
        // Explicit DASHISLAND_DEMO=1 only → fake gauges.
        // Empty without demo env → empty + add UI (no auto-demo).
        if DemoWidgets.isForced {
            return DemoWidgets.make()
        }
        return orchestrator.widgets
    }

    /// Zero accounts, not demo: single centered `+`.
    private var showEmptyAdd: Bool {
        !DemoWidgets.isForced && accountStore.accounts.isEmpty
    }

    /// 1…4 accounts, not demo: right-edge dwell chevron → glass `+`.
    private var showEdgeChrome: Bool {
        !DemoWidgets.isForced
            && accountStore.accounts.count > 0
            && accountStore.accounts.count < AccountStore.maxAccounts
    }

    private var islandBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 26,
            bottomTrailingRadius: 26,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }
}
