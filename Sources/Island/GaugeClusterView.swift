import AppKit
import SwiftUI

/// Account widgets + trailing add.
/// - Drag **inside** the expanded panel → reorder (widget-style).
/// - Drag to the **strip below** the black panel (or fully off-window) → remove confirm.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    /// Expanded black body height (notch + content) for remove-zone math.
    var panelBlackHeight: CGFloat = 160

    @State private var draggingID: AccountID?
    @State private var dragTranslation: CGSize = .zero
    /// Finger is in the below-panel remove strip (or off-window).
    @State private var inRemoveZone = false
    @State private var clusterGlobalFrame: CGRect = .zero

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
        .onPreferenceChange(ClusterFrameKey.self) { clusterGlobalFrame = $0 }
        // Remove cue sits *under* the black panel, in the transparent overflow.
        .overlay(alignment: .bottom) {
            if draggingID != nil {
                removeStrip
                    .offset(y: 36)
                    .opacity(inRemoveZone ? 1 : 0.55)
                    .scaleEffect(inRemoveZone ? 1.04 : 0.98)
                    .animation(.easeOut(duration: 0.14), value: inRemoveZone)
            }
        }
    }

    private var widgetRow: some View {
        let shown = Array(widgets.prefix(Self.maxWidgets))
        return HStack(spacing: Self.gap) {
            ForEach(shown) { model in
                AccountWidget(
                    model: model,
                    isDragging: draggingID == model.id,
                    isDropTarget: allowsEditing
                        && draggingID != nil
                        && draggingID != model.id
                        && !inRemoveZone
                )
                .opacity(draggingID == model.id ? 0.9 : 1)
                .zIndex(draggingID == model.id ? 30 : 0)
                .offset(draggingID == model.id ? dragTranslation : .zero)
                .highPriorityGesture(allowsEditing ? dragGesture(for: model.id) : nil)
                .animation(
                    .interactiveSpring(response: 0.28, dampingFraction: 0.84),
                    value: widgets.map(\.id)
                )
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
        .zIndex(5)
        .opacity(draggingID == nil ? 1 : 0.25)
        .allowsHitTesting(draggingID == nil)
    }

    /// Lives below the expanded black body — teaches “throw away outside”.
    private var removeStrip: some View {
        Label("Release to remove", systemImage: "trash")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(inRemoveZone ? 0.72 : 0.42))
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .allowsHitTesting(false)
    }

    // MARK: - Drag

    private func dragGesture(for id: AccountID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil { draggingID = id }
                guard draggingID == id else { return }

                dragTranslation = value.translation
                let remove = isInRemoveZone(value.location)
                if remove != inRemoveZone {
                    inRemoveZone = remove
                }

                // Inside the panel → live reorder. Never delete here.
                if !remove {
                    reorderIfNeeded(dragged: id, fingerGlobal: value.location)
                }
            }
            .onEnded { value in
                let remove = isInRemoveZone(value.location)
                let dragged = id
                // Final reorder pass if still inside.
                if !remove {
                    reorderIfNeeded(dragged: dragged, fingerGlobal: value.location)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    dragTranslation = .zero
                    draggingID = nil
                    inRemoveZone = false
                }
                // Delete only when released in the below-panel / off-window zone.
                if remove {
                    confirmRemove(id: dragged)
                }
            }
    }

    /// Remove zone = below the black expanded body, or fully outside the island window.
    private func isInRemoveZone(_ globalPoint: CGPoint) -> Bool {
        guard let win = islandWindow() else {
            // Fallback: below the cluster row.
            return globalPoint.y < clusterGlobalFrame.minY - 8
                || globalPoint.y > clusterGlobalFrame.maxY + 28
                || globalPoint.x < clusterGlobalFrame.minX - 40
                || globalPoint.x > clusterGlobalFrame.maxX + 40
        }

        let wf = win.frame
        // Entirely off the window → remove.
        if !wf.insetBy(dx: -12, dy: -12).contains(globalPoint) {
            return true
        }

        // AppKit: y increases upward. Black body occupies the top `panelBlackHeight`.
        let blackBottomY = wf.maxY - panelBlackHeight
        // Transparent overflow under the black silhouette (plus a small band).
        return globalPoint.y < blackBottomY - 2
    }

    private func islandWindow() -> NSWindow? {
        NSApp.windows.first { $0 is BorderlessFloatingWindow }
    }

    private func reorderIfNeeded(dragged: AccountID, fingerGlobal: CGPoint) {
        guard !widgets.isEmpty else { return }
        let n = widgets.count
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap

        // Prefer cluster geometry; fall back to window mid.
        let midX: CGFloat
        if clusterGlobalFrame.width > 1 {
            midX = clusterGlobalFrame.midX
        } else if let win = islandWindow() {
            midX = win.frame.midX
        } else {
            return
        }

        let leading = midX - rowW / 2
        let localX = fingerGlobal.x - leading
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)

        // Desired final index for the dragged item.
        try? AccountStore.shared.move(id: dragged, toIndex: index)
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
