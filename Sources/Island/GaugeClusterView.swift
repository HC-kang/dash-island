import AppKit
import SwiftUI

/// Center-aligned account widgets + always-visible add when under cap.
/// Drag to reorder (widget-style lift); release outside the island to remove.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true

    @State private var draggingID: AccountID?
    @State private var dragTranslation: CGSize = .zero
    @State private var isOutsideDropZone = false
    @State private var rowFrame: CGRect = .zero

    private static let maxWidgets = IslandModel.maxItems
    private static let gap: CGFloat = IslandModel.cellGap

    var body: some View {
        ZStack {
            if showEmptyAdd {
                CenteredAddButton { adapter in
                    AccountChromeActions.beginAdd(adapter: adapter)
                }
            } else {
                widgetRow
            }

            if showAdd {
                trailingAdd
            }

            if isOutsideDropZone, draggingID != nil {
                outsideRemoveHint
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ClusterFrameKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
        .onPreferenceChange(ClusterFrameKey.self) { rowFrame = $0 }
    }

    private var widgetRow: some View {
        let shown = Array(widgets.prefix(Self.maxWidgets))
        return HStack(spacing: Self.gap) {
            ForEach(shown) { model in
                AccountWidget(
                    model: model,
                    isDragging: draggingID == model.id,
                    isDropTarget: allowsEditing && draggingID != nil && draggingID != model.id
                )
                .opacity(draggingID == model.id ? 0.92 : 1)
                .zIndex(draggingID == model.id ? 30 : 0)
                .offset(draggingID == model.id ? dragTranslation : .zero)
                .gesture(allowsEditing ? dragGesture(for: model.id) : nil)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.84), value: widgets.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var trailingAdd: some View {
        HStack {
            Spacer(minLength: 0)
            Menu {
                VendorMenuItems { adapter in
                    AccountChromeActions.beginAdd(adapter: adapter)
                }
            } label: {
                GlassPlusLabel(size: 32, symbolSize: 14)
            }
            .menuStyle(.borderlessButton)
            .help("Add account")
            .accessibilityLabel("Add account")
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        // Keep + above drag previews but clickable.
        .zIndex(5)
    }

    private var outsideRemoveHint: some View {
        VStack {
            Spacer()
            Label("Release to remove", systemImage: "trash")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(Color.red.opacity(0.62)))
                .padding(.bottom, 2)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - Drag

    private func dragGesture(for id: AccountID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = id
                }
                guard draggingID == id else { return }
                dragTranslation = value.translation
                let outside = isOutsideIsland(value.location)
                if outside != isOutsideDropZone {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isOutsideDropZone = outside
                    }
                }
                if !outside {
                    reorderIfNeeded(dragged: id, finger: value.location)
                }
            }
            .onEnded { value in
                let outside = isOutsideIsland(value.location)
                let dragged = id
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    dragTranslation = .zero
                    draggingID = nil
                    isOutsideDropZone = false
                }
                if outside {
                    confirmRemove(id: dragged)
                }
            }
    }

    /// Outside the island black body (global coords) → remove candidate.
    private func isOutsideIsland(_ globalPoint: CGPoint) -> Bool {
        // Prefer the Dash Island borderless window frame.
        let islandWindows = NSApp.windows.filter {
            $0.contentView is NSHostingView<IslandRootView> || String(describing: type(of: $0)).contains("Borderless")
        }
        let win = islandWindows.first ?? NSApp.windows.first(where: { $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue })
        guard let win else {
            // Fallback: outside the measured cluster row.
            return !rowFrame.insetBy(dx: -24, dy: -40).contains(globalPoint)
        }
        // Black body ≈ top portion of window; use full window with small pad —
        // leaving the window entirely is the clear "desktop drop" gesture.
        return !win.frame.insetBy(dx: -6, dy: -6).contains(globalPoint)
    }

    private func reorderIfNeeded(dragged: AccountID, finger: CGPoint) {
        // Map finger X to index within the centered row frame.
        guard rowFrame.width > 0, !widgets.isEmpty else { return }
        let n = widgets.count
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap
        let leading = rowFrame.midX - rowW / 2
        let localX = finger.x - leading
        var index = Int((localX / stride).rounded(.down))
        index = min(max(0, index), n - 1)
        let target = widgets[index].id
        guard target != dragged else { return }
        try? AccountStore.shared.move(id: dragged, before: target)
    }

    private func confirmRemove(id: AccountID) {
        let label = AccountStore.shared.accounts.first(where: { $0.id == id })?.label ?? "this account"
        let alert = NSAlert()
        alert.messageText = "Remove \(label)?"
        alert.informativeText = "This removes the account from Dash Island and deletes its stored credentials."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? AccountStore.shared.remove(id: id)
        }
    }
}

private struct ClusterFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Demo data

@MainActor
enum DemoWidgets {
    static var isForced: Bool {
        ProcessInfo.processInfo.environment["DASHISLAND_DEMO"] == "1"
    }

    static func isEnabled(accountsEmpty: Bool) -> Bool {
        _ = accountsEmpty
        return isForced
    }

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
