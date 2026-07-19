import SwiftUI

struct IslandRootView: View {
    @ObservedObject private var accountStore = AccountStore.shared

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
        // Orchestrator lands in a later task; until then, demo fills the island.
        if DemoWidgets.isEnabled(accountsEmpty: accountStore.accounts.isEmpty) {
            return DemoWidgets.make()
        }
        // Real accounts exist but no live VMs yet — keep chrome empty rather than
        // mixing fake gauges with real account rows.
        return []
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
