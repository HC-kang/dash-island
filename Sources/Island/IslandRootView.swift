import SwiftUI

struct IslandRootView: View {
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared

    var body: some View {
        GaugeClusterView(widgets: widgets)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            // Extra bottom room so hover tooltips aren't clipped by the window.
            .padding(.bottom, 52)
            .background(islandBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var widgets: [WidgetViewModel] {
        // Empty accounts (or explicit DASHISLAND_DEMO=1) → demo gauges.
        // Real accounts → orchestrator live view models.
        if DemoWidgets.isEnabled(accountsEmpty: accountStore.accounts.isEmpty) {
            return DemoWidgets.make()
        }
        return orchestrator.widgets
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
