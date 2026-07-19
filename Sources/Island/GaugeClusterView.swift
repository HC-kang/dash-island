import SwiftUI

/// Center-aligned horizontal cluster of 0–5 account widgets, plus edge/empty add chrome.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    /// Live account count (not demo VMs). Drives add-chrome visibility.
    var accountCount: Int = 0
    /// When true, show centered `+` (empty, non-demo).
    var showEmptyAdd: Bool = false
    /// When true, show right-edge dwell chevron/`+` (1…4 accounts, non-demo).
    var showEdgeChrome: Bool = false

    private static let maxWidgets = IslandModel.maxItems
    private static let gap: CGFloat = IslandModel.cellGap

    var body: some View {
        ZStack {
            if showEmptyAdd {
                CenteredAddButton { adapter in
                    AccountChromeActions.beginAdd(adapter: adapter)
                }
            } else {
                let shown = Array(widgets.prefix(Self.maxWidgets))
                HStack(spacing: Self.gap) {
                    ForEach(shown) { model in
                        AccountWidget(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if showEdgeChrome {
                EdgeAddChrome { adapter in
                    AccountChromeActions.beginAdd(adapter: adapter)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                // Nudge into the padding zone without shifting the widget cluster.
                .padding(.trailing, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Demo data

@MainActor
enum DemoWidgets {
    /// Explicit `DASHISLAND_DEMO=1` only (empty accounts no longer auto-demo).
    static var isForced: Bool {
        ProcessInfo.processInfo.environment["DASHISLAND_DEMO"] == "1"
    }

    /// Whether the island should render fake view models.
    static func isEnabled(accountsEmpty: Bool) -> Bool {
        // `accountsEmpty` retained for call-site compatibility; ignored.
        _ = accountsEmpty
        return isForced
    }

    /// Demo count: env `DASHISLAND_DEMO_COUNT` ∈ {1,3,5}, else 3.
    static var count: Int {
        if let raw = ProcessInfo.processInfo.environment["DASHISLAND_DEMO_COUNT"],
           let n = Int(raw),
           [1, 3, 5].contains(n) {
            return n
        }
        return 3
    }

    static func make(count: Int? = nil) -> [WidgetViewModel] {
        let n = min(5, max(1, count ?? Self.count))
        return Array(samples.prefix(n))
    }

    private static let samples: [WidgetViewModel] = [
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "claude · home",
            tint: .claude,
            primaryFraction: 0.18,
            secondaryFraction: 0.12,
            centerPercent: 18,
            burnRatio: 0.0,
            hoverLines: ["5h  1.8k / 10k", "wk  12k / 100k"],
            errorCaption: nil
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "codex · team",
            tint: .codex,
            primaryFraction: 0.41,
            secondaryFraction: 0.55,
            centerPercent: 41,
            burnRatio: 1.0,
            hoverLines: ["5h  4.1k / 10k", "wk  55k / 100k"],
            errorCaption: nil
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            title: "claude · work",
            tint: .claude,
            primaryFraction: 0.72,
            secondaryFraction: 0.41,
            centerPercent: 72,
            burnRatio: 1.8,
            hoverLines: ["5h  7.2k / 10k", "wk  41k / 100k"],
            errorCaption: nil
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            title: "grok · play",
            tint: .grok,
            primaryFraction: 0.33,
            secondaryFraction: 0.28,
            centerPercent: 33,
            burnRatio: 0.4,
            hoverLines: ["5h  3.3k / 10k", "wk  28k / 100k"],
            errorCaption: nil
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
            title: "codex · side",
            tint: .codex,
            primaryFraction: 0.09,
            secondaryFraction: nil,
            centerPercent: 9,
            burnRatio: 0.0,
            hoverLines: ["5h  0.9k / 10k"],
            errorCaption: nil
        ),
    ]
}
