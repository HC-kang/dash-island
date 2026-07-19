import AppKit
import SwiftUI

/// Fixed **slots** (default 3). Widgets sit in slots like macOS/iOS home-screen.
/// Drag lifts a floating copy onto the cursor; the home slot shows a gray skeleton.
///
/// Order is mutated only in local state while dragging — writing `AccountStore`
/// mid-drag rebuilds the row and cancels the gesture (freeze bug).
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    var panelBlackHeight: CGFloat = 160

    /// Stable order of account IDs for display (local while dragging).
    @State private var orderIDs: [AccountID] = []
    @State private var draggingID: AccountID?
    /// Slot index the drag started from (skeleton home).
    @State private var homeSlot: Int?
    @State private var dragGlobalPoint: CGPoint?
    @State private var inRemoveZone = false
    @State private var hoveredSlot: Int?
    @State private var clusterGlobalFrame: CGRect = .zero

    private static let maxSlots = IslandModel.maxItems
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap

    private var slotCount: Int {
        let filled = max(orderIDs.count, widgets.count)
        return max(Self.minSlots, min(Self.maxSlots, filled))
    }

    private var modelByID: [AccountID: WidgetViewModel] {
        Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
    }

    var body: some View {
        ZStack {
            slotRow

            if showEmptyAdd && draggingID == nil {
                CenteredAddButton { adapter in
                    AccountChromeActions.beginAdd(adapter: adapter)
                }
            }

            if showAdd && !showEmptyAdd && draggingID == nil {
                trailingAdd
            }

            if let id = draggingID,
               let model = modelByID[id],
               let point = dragGlobalPoint {
                floatingWidget(model: model, globalPoint: point)
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
        .onAppear { syncOrderFromWidgets() }
        .onChange(of: widgets.map(\.id)) { ids in
            // Don't clobber local order mid-drag.
            guard draggingID == nil else { return }
            orderIDs = ids
        }
        .overlay(alignment: .bottom) {
            if draggingID != nil {
                removeStrip
                    .offset(y: 36)
                    .opacity(inRemoveZone ? 1 : 0.5)
                    .scaleEffect(inRemoveZone ? 1.04 : 0.98)
                    .animation(.easeOut(duration: 0.14), value: inRemoveZone)
            }
        }
    }

    private func syncOrderFromWidgets() {
        orderIDs = widgets.map(\.id)
    }

    // MARK: - Slots

    private var slotRow: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<slotCount, id: \.self) { index in
                slotCell(index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Only animate slot occupancy when not dragging.
        .animation(
            draggingID == nil
                ? .interactiveSpring(response: 0.3, dampingFraction: 0.86)
                : nil,
            value: orderIDs
        )
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        let occupantID: AccountID? = index < orderIDs.count ? orderIDs[index] : nil
        let isHome = homeSlot == index && draggingID != nil
        let isHover = hoveredSlot == index && draggingID != nil && !inRemoveZone
        let showWidget = occupantID != nil && occupantID != draggingID

        ZStack {
            SlotSkeleton(
                highlighted: isHover || isHome,
                empty: occupantID == nil || isHome
            )

            if showWidget, let oid = occupantID, let model = modelByID[oid] {
                // Identity is tied to account id so reorder mid-session is fine
                // *after* drag; during drag this view is not the drag source's twin.
                AccountWidget(model: model, isDragging: false, isDropTarget: isHover)
                    .highPriorityGesture(allowsEditing ? dragGesture(for: oid) : nil)
            }
        }
        .frame(width: AccountWidget.cellSize, height: AccountWidget.cellSize + 8)
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
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .zIndex(5)
    }

    private var removeStrip: some View {
        Label("Release to remove", systemImage: "trash")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(inRemoveZone ? 0.72 : 0.4))
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .allowsHitTesting(false)
    }

    private func floatingWidget(model: WidgetViewModel, globalPoint: CGPoint) -> some View {
        let local = CGPoint(
            x: globalPoint.x - clusterGlobalFrame.minX,
            y: globalPoint.y - clusterGlobalFrame.minY
        )
        return AccountWidget(model: model, isDragging: true, isDropTarget: false)
            .scaleEffect(1.07)
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .position(x: local.x, y: local.y)
            .zIndex(100)
            .allowsHitTesting(false)
    }

    // MARK: - Drag (local order only)

    private func dragGesture(for id: AccountID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = id
                    homeSlot = orderIDs.firstIndex(of: id)
                    // Ensure orderIDs is populated.
                    if orderIDs.isEmpty { syncOrderFromWidgets() }
                }
                guard draggingID == id else { return }

                dragGlobalPoint = value.location
                let remove = isInRemoveZone(value.location)
                inRemoveZone = remove

                if remove {
                    hoveredSlot = nil
                    return
                }

                if let slot = slotIndex(atGlobal: value.location) {
                    hoveredSlot = slot
                    // Local reorder only — do NOT touch AccountStore here.
                    moveLocal(id: id, toIndex: slot)
                }
            }
            .onEnded { value in
                let remove = isInRemoveZone(value.location)
                let dragged = id

                if !remove, let slot = slotIndex(atGlobal: value.location) {
                    moveLocal(id: dragged, toIndex: slot)
                }

                let finalOrder = orderIDs
                draggingID = nil
                homeSlot = nil
                dragGlobalPoint = nil
                inRemoveZone = false
                hoveredSlot = nil

                if remove {
                    // Restore store order if we had local moves, then confirm remove.
                    // orderIDs may already reflect mid-drag moves — fine for index.
                    confirmRemove(id: dragged)
                    // After cancel, resync from store; after confirm store is updated.
                    syncOrderFromWidgets()
                } else {
                    // Commit local order once.
                    try? AccountStore.shared.applyOrder(finalOrder)
                    syncOrderFromWidgets()
                }
            }
    }

    /// Reorder `orderIDs` without publishing to the store.
    private func moveLocal(id: AccountID, toIndex: Int) {
        guard let from = orderIDs.firstIndex(of: id) else { return }
        let target = min(max(0, toIndex), max(orderIDs.count - 1, 0))
        guard from != target else { return }
        var next = orderIDs
        let item = next.remove(at: from)
        let insertAt = min(target, next.count)
        // Map "desired final index" after removal:
        var dest = target
        if from < target { dest = target } // after remove, indices after `from` shift left
        // Simpler: insert at `target` clamped to next.count
        dest = min(max(0, target), next.count)
        // When moving right, after remove the target index should be target (already shifted in array sense)
        // Example: [A B C D], move A to index 2 → remove A → [B C D], insert at 2 → [B C A D]
        if from < target {
            dest = min(target, next.count) // target in original; after remove, slot `target` is at index target-1... 
            // Standard: final position should be `target`
            // remove from `from`, then insert at `target` if target < from, else at `target` after shift = target (because we want index target in final array)
            // Final array index == target:
            // after remove, insert at: target if from > target else target (wait)
            // Swift Array move: 
            // let item = a.remove(at: from); a.insert(item, at: to) where `to` is index in the post-remove array for final position `to` when to < from, or for final position `to` when to > from insert at to-? 
            // If we want final index == T:
            // remove at F, then if F < T, insert at T-1? No:
            // [0:A,1:B,2:C], move 0 to 2: want [B,C,A]. remove 0 → [B,C], insert at 2 → [B,C,A]. insert index = 2 = T (T=2, F=0, F<T, insert at T? but count=2, insert at 2 = append. T after remove max is 2. insert(at:2) works. insert at T when F < T gives insert at 2 = end. Good.
            // [A,B,C] move 2 to 0: want [C,A,B]. remove 2 → [A,B], insert at 0 → [C,A,B]. insert = T = 0. Good.
            // [A,B,C] move 0 to 1: want [B,A,C]. remove 0 → [B,C], insert at 1 → [B,A,C]. insert = 1 = T. Good.
            dest = min(target, next.count)
        } else {
            dest = min(target, next.count)
        }
        next.insert(item, at: dest)
        if next != orderIDs {
            orderIDs = next
        }
    }

    private func slotIndex(atGlobal point: CGPoint) -> Int? {
        let n = slotCount
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap
        let midX = clusterGlobalFrame.width > 1
            ? clusterGlobalFrame.midX
            : (islandWindow()?.frame.midX ?? point.x)
        let leading = midX - rowW / 2
        let localX = point.x - leading
        guard localX >= -cell * 0.4, localX <= rowW + cell * 0.4 else { return nil }
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)
        // Cap to existing items range (can't land past last real item + empty only as empty).
        let maxFilled = max(orderIDs.count - 1, 0)
        return min(index, max(maxFilled, 0))
    }

    private func isInRemoveZone(_ globalPoint: CGPoint) -> Bool {
        guard let win = islandWindow() else {
            return globalPoint.y < clusterGlobalFrame.minY - 12
                || globalPoint.y > clusterGlobalFrame.maxY + 32
        }
        let wf = win.frame
        if !wf.insetBy(dx: -12, dy: -12).contains(globalPoint) {
            return true
        }
        let blackBottomY = wf.maxY - panelBlackHeight
        return globalPoint.y < blackBottomY - 2
    }

    private func islandWindow() -> NSWindow? {
        NSApp.windows.first { $0 is BorderlessFloatingWindow }
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
        syncOrderFromWidgets()
    }
}

// MARK: - Slot skeleton

struct SlotSkeleton: View {
    var highlighted: Bool = false
    var empty: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(highlighted ? 0.10 : 0.055),
                        Color.white.opacity(highlighted ? 0.06 : 0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(highlighted ? 0.22 : 0.08),
                        style: StrokeStyle(lineWidth: 1, dash: empty ? [5, 4] : [])
                    )
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(highlighted ? 0.12 : 0.06), lineWidth: 4)
                    .frame(width: 56, height: 56)
                    .offset(y: -6)
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
