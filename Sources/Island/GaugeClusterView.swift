import AppKit
import SwiftUI

/// Slot grid (min 3). Drag = float on cursor + skeleton in **home** slot.
/// Order is frozen while dragging; committed once on release into a target slot.
/// Trash magnet below the panel absorbs deletes (no “drop on desktop”).
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    var panelBlackHeight: CGFloat = 160

    @State private var orderIDs: [AccountID] = []
    @State private var draggingID: AccountID?
    /// Fixed for the whole gesture — never reorder the row under the finger mid-drag.
    @State private var homeSlot: Int?
    @State private var dragGlobalPoint: CGPoint?
    @State private var targetSlot: Int?
    @State private var magnetizedToTrash = false
    @State private var clusterGlobalFrame: CGRect = .zero

    private static let maxSlots = IslandModel.maxItems
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap
    /// Trash sits under the black body; magnetic radius in points.
    private static let trashMagnetRadius: CGFloat = 56

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

            // Floating lift — must not be clipped by parent.
            if let id = draggingID,
               let model = modelByID[id],
               let point = dragGlobalPoint {
                floatingWidget(model: model, globalPoint: displayPoint(for: point))
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
            guard draggingID == nil else { return }
            orderIDs = ids
        }
        .onChange(of: draggingID) { id in
            NotificationCenter.default.post(name: .dashIslandDragActive, object: id != nil)
        }
        // Trash magnet — below black panel, outside content layout.
        .overlay(alignment: .bottom) {
            if draggingID != nil {
                trashTarget
                    .offset(y: 44)
                    .scaleEffect(magnetizedToTrash ? 1.18 : 1.0)
                    .opacity(magnetizedToTrash ? 1 : 0.65)
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: magnetizedToTrash)
            }
        }
    }

    private func syncOrderFromWidgets() {
        orderIDs = widgets.map(\.id)
    }

    /// When magnetized, snap the float to the trash center.
    private func displayPoint(for finger: CGPoint) -> CGPoint {
        if magnetizedToTrash, let trash = trashGlobalCenter() {
            return trash
        }
        return finger
    }

    // MARK: - Slots

    private var slotRow: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<slotCount, id: \.self) { index in
                slotCell(index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        let occupantID: AccountID? = index < orderIDs.count ? orderIDs[index] : nil
        let isHome = homeSlot == index && draggingID != nil
        let isTarget = targetSlot == index && draggingID != nil && !magnetizedToTrash

        ZStack {
            SlotSkeleton(
                highlighted: isHome || isTarget,
                empty: occupantID == nil || isHome
            )

            // Source stays mounted (opacity ~0) so DragGesture is not cancelled.
            if let oid = occupantID, let model = modelByID[oid] {
                AccountWidget(model: model, isDragging: false, isDropTarget: isTarget && oid != draggingID)
                    .opacity(oid == draggingID ? 0.001 : 1)
                    .gesture(allowsEditing ? dragGesture(for: oid) : nil)
            }
        }
        .frame(width: AccountWidget.cellSize, height: AccountWidget.cellSize + 8)
        .contentShape(Rectangle())
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

    private var trashTarget: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(magnetizedToTrash ? 0.55 : 0.28))
                .frame(width: magnetizedToTrash ? 48 : 40, height: magnetizedToTrash ? 48 : 40)
            Image(systemName: magnetizedToTrash ? "trash.fill" : "trash")
                .font(.system(size: magnetizedToTrash ? 18 : 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .shadow(color: Color.red.opacity(magnetizedToTrash ? 0.45 : 0.2), radius: magnetizedToTrash ? 12 : 6)
        .allowsHitTesting(false)
        .accessibilityLabel("Remove account")
    }

    private func floatingWidget(model: WidgetViewModel, globalPoint: CGPoint) -> some View {
        let origin = clusterGlobalFrame.origin
        // Guard against zero frame before first layout pass.
        let ox = clusterGlobalFrame.width > 1 ? origin.x : 0
        let oy = clusterGlobalFrame.width > 1 ? origin.y : 0
        let local = CGPoint(x: globalPoint.x - ox, y: globalPoint.y - oy)
        return AccountWidget(model: model, isDragging: true, isDropTarget: false)
            .scaleEffect(magnetizedToTrash ? 0.72 : 1.07)
            .opacity(magnetizedToTrash ? 0.85 : 1)
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .position(x: local.x, y: local.y)
            .zIndex(100)
            .allowsHitTesting(false)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: magnetizedToTrash)
    }

    // MARK: - Drag

    private func dragGesture(for id: AccountID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    if orderIDs.isEmpty { syncOrderFromWidgets() }
                    draggingID = id
                    homeSlot = orderIDs.firstIndex(of: id)
                    NotificationCenter.default.post(name: .dashIslandDragActive, object: true)
                }
                guard draggingID == id else { return }

                dragGlobalPoint = value.location
                let nearTrash = isNearTrash(value.location)
                magnetizedToTrash = nearTrash

                if nearTrash {
                    targetSlot = nil
                } else {
                    targetSlot = slotIndex(atGlobal: value.location)
                }
                // Do NOT reorder orderIDs mid-drag — that remounts cells and kills the gesture.
            }
            .onEnded { value in
                let nearTrash = isNearTrash(value.location)
                let dragged = id
                let dropSlot = nearTrash ? nil : (slotIndex(atGlobal: value.location) ?? targetSlot)

                let finalHome = homeSlot
                draggingID = nil
                homeSlot = nil
                dragGlobalPoint = nil
                targetSlot = nil
                magnetizedToTrash = false
                NotificationCenter.default.post(name: .dashIslandDragActive, object: false)

                if nearTrash {
                    confirmRemove(id: dragged)
                    syncOrderFromWidgets()
                    return
                }

                if let dropSlot, let from = finalHome ?? orderIDs.firstIndex(of: dragged) {
                    commitMove(id: dragged, from: from, to: dropSlot)
                }
            }
    }

    private func commitMove(id: AccountID, from: Int, to: Int) {
        guard from != to else { return }
        var next = orderIDs
        guard from < next.count else { return }
        let item = next.remove(at: from)
        let dest = min(max(0, to), next.count)
        next.insert(item, at: dest)
        orderIDs = next
        try? AccountStore.shared.applyOrder(next)
        // Keep demo visual order even if store ignores unknown ids.
        if DemoWidgets.isForced {
            // orderIDs already updated
        } else {
            syncOrderFromWidgets()
        }
    }

    private func slotIndex(atGlobal point: CGPoint) -> Int? {
        let n = slotCount
        guard n > 0 else { return nil }
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap
        let midX = clusterGlobalFrame.width > 1
            ? clusterGlobalFrame.midX
            : (islandWindow()?.frame.midX ?? point.x)
        let leading = midX - rowW / 2
        let localX = point.x - leading
        // Generous horizontal acceptance so edge slots work.
        guard localX >= -cell * 0.5, localX <= rowW + cell * 0.5 else { return nil }
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)
        if orderIDs.isEmpty { return index }
        return min(index, max(orderIDs.count - 1, 0))
    }

    private func trashGlobalCenter() -> CGPoint? {
        guard let win = islandWindow() else {
            // Fallback under cluster.
            return CGPoint(x: clusterGlobalFrame.midX, y: clusterGlobalFrame.maxY + 44)
        }
        let wf = win.frame
        // Center of trash overlay: midX of window, just below black body.
        let blackBottomY = wf.maxY - panelBlackHeight
        return CGPoint(x: wf.midX, y: blackBottomY - 22)
    }

    private func isNearTrash(_ globalPoint: CGPoint) -> Bool {
        guard let c = trashGlobalCenter() else { return false }
        let dx = globalPoint.x - c.x
        let dy = globalPoint.y - c.y
        return (dx * dx + dy * dy).squareRoot() <= Self.trashMagnetRadius
    }

    private func islandWindow() -> NSWindow? {
        NSApp.windows.first { $0 is BorderlessFloatingWindow }
    }

    private func confirmRemove(id: AccountID) {
        guard AccountStore.shared.accounts.contains(where: { $0.id == id }) else {
            orderIDs.removeAll { $0 == id }
            return
        }
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

extension Notification.Name {
    static let dashIslandDragActive = Notification.Name("dashIslandDragActive")
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
