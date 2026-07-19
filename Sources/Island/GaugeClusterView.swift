import AppKit
import SwiftUI

/// Slot grid (min 3). Drag floats a copy; home slot shows skeleton.
/// Drop on another slot reorders. Drag near trash magnet to remove.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    var panelBlackHeight: CGFloat = 160

    @State private var orderIDs: [AccountID] = []
    @State private var draggingID: AccountID?
    @State private var homeSlot: Int?
    @State private var liftOrigin: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var targetSlot: Int?
    @State private var magnetizedToTrash = false
    @State private var clusterSize: CGSize = .zero

    private static let maxSlots = IslandModel.maxItems
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap
    /// Enter magnet inside this radius; exit only outside + hysteresis.
    private static let trashMagnetEnter: CGFloat = 72
    private static let trashMagnetExit: CGFloat = 96
    private static let dragSpace = "dashIsland.dragSpace"
    private static let cellH = AccountWidget.cellSize + 8
    private static let trashSize: CGFloat = 44
    /// Gap between slot row bottom and trash center.
    private static let trashOffsetY: CGFloat = 52

    private var slotCount: Int {
        let filled = max(orderIDs.count, widgets.count)
        return max(Self.minSlots, min(Self.maxSlots, filled))
    }

    private var modelByID: [AccountID: WidgetViewModel] {
        Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
    }

    /// Trash center in `dragSpace` — must match the drawn trash `position`.
    private var trashCenterLocal: CGPoint {
        let w = clusterSize.width > 1 ? clusterSize.width : 300
        return CGPoint(
            x: w / 2,
            y: Self.cellH + Self.trashOffsetY
        )
    }

    private var floatCenter: CGPoint {
        if magnetizedToTrash {
            return trashCenterLocal
        }
        return CGPoint(
            x: liftOrigin.x + dragTranslation.width,
            y: liftOrigin.y + dragTranslation.height
        )
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

            // Trash drawn IN this coordinate space (not overlay offset math).
            if draggingID != nil {
                trashTarget
                    .position(trashCenterLocal)
                    .zIndex(50)
            }

            if let id = draggingID, let model = modelByID[id] {
                AccountWidget(model: model, isDragging: true, isDropTarget: false)
                    .scaleEffect(magnetizedToTrash ? 0.68 : 1.07)
                    .opacity(magnetizedToTrash ? 0.9 : 1)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .position(floatCenter)
                    .zIndex(100)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.26, dampingFraction: 0.72), value: magnetizedToTrash)
            }
        }
        // Extra height so trash + float below slots stay inside the view (and hit-testable area).
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.cellH + (draggingID != nil ? Self.trashOffsetY + 36 : 0))
        .coordinateSpace(name: Self.dragSpace)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ClusterSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ClusterSizeKey.self) { clusterSize = $0 }
        .onAppear { syncOrderFromWidgets() }
        .onChange(of: widgets.map(\.id)) { ids in
            guard draggingID == nil else { return }
            orderIDs = ids
        }
        .onChange(of: draggingID) { id in
            NotificationCenter.default.post(name: .dashIslandDragActive, object: id != nil)
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
        .frame(height: Self.cellH, alignment: .top)
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

            if let oid = occupantID, let model = modelByID[oid] {
                AccountWidget(
                    model: model,
                    isDragging: false,
                    isDropTarget: isTarget && oid != draggingID
                )
                .opacity(oid == draggingID ? 0.001 : 1)
                .gesture(allowsEditing ? dragGesture(for: oid, slotIndex: index) : nil)
            }
        }
        .frame(width: AccountWidget.cellSize, height: Self.cellH)
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
                .fill(Color.red.opacity(magnetizedToTrash ? 0.6 : 0.32))
                .frame(
                    width: magnetizedToTrash ? 52 : Self.trashSize,
                    height: magnetizedToTrash ? 52 : Self.trashSize
                )
            Image(systemName: magnetizedToTrash ? "trash.fill" : "trash")
                .font(.system(size: magnetizedToTrash ? 20 : 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .shadow(color: Color.red.opacity(magnetizedToTrash ? 0.5 : 0.22), radius: magnetizedToTrash ? 14 : 7)
        .allowsHitTesting(false)
        .accessibilityLabel("Remove account")
    }

    // MARK: - Drag

    private func dragGesture(for id: AccountID, slotIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                if draggingID == nil {
                    if orderIDs.isEmpty { syncOrderFromWidgets() }
                    draggingID = id
                    homeSlot = orderIDs.firstIndex(of: id) ?? slotIndex
                    liftOrigin = slotCenter(index: homeSlot ?? slotIndex)
                    dragTranslation = .zero
                    magnetizedToTrash = false
                }
                guard draggingID == id else { return }

                dragTranslation = value.translation
                let finger = CGPoint(
                    x: liftOrigin.x + value.translation.width,
                    y: liftOrigin.y + value.translation.height
                )

                updateTrashMagnet(finger: finger)

                if magnetizedToTrash {
                    targetSlot = nil
                } else {
                    targetSlot = slotIndexAt(localX: finger.x)
                }
            }
            .onEnded { value in
                let finger = CGPoint(
                    x: liftOrigin.x + value.translation.width,
                    y: liftOrigin.y + value.translation.height
                )
                // Sticky: if we were magnetized, count as trash even if release jitter.
                let remove = magnetizedToTrash || distanceToTrash(finger) <= Self.trashMagnetEnter
                let dropSlot = remove ? nil : (targetSlot ?? slotIndexAt(localX: finger.x))
                let dragged = id
                let from = homeSlot ?? orderIDs.firstIndex(of: dragged)

                draggingID = nil
                homeSlot = nil
                dragTranslation = .zero
                targetSlot = nil
                magnetizedToTrash = false

                if remove {
                    confirmRemove(id: dragged)
                    return
                }

                if let dropSlot, let from {
                    commitMove(id: dragged, from: from, to: dropSlot)
                }
            }
    }

    private func updateTrashMagnet(finger: CGPoint) {
        let d = distanceToTrash(finger)
        if magnetizedToTrash {
            // Hysteresis — don't drop magnet until clearly away.
            if d > Self.trashMagnetExit {
                magnetizedToTrash = false
            }
        } else if d <= Self.trashMagnetEnter {
            magnetizedToTrash = true
        }
    }

    private func distanceToTrash(_ point: CGPoint) -> CGFloat {
        let c = trashCenterLocal
        let dx = point.x - c.x
        let dy = point.y - c.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func slotCenter(index: Int) -> CGPoint {
        let n = slotCount
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap
        let w = clusterSize.width > 1 ? clusterSize.width : rowW
        let leading = (w - rowW) / 2
        let x = leading + CGFloat(index) * stride + cell / 2
        let y = Self.cellH / 2
        return CGPoint(x: x, y: y)
    }

    private func slotIndexAt(localX x: CGFloat) -> Int? {
        let n = slotCount
        guard n > 0 else { return nil }
        let cell = AccountWidget.cellSize
        let stride = cell + Self.gap
        let rowW = CGFloat(n) * cell + CGFloat(max(0, n - 1)) * Self.gap
        let w = clusterSize.width > 1 ? clusterSize.width : rowW
        let leading = (w - rowW) / 2
        let localX = x - leading
        guard localX >= -cell * 0.5, localX <= rowW + cell * 0.5 else { return nil }
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)
        if orderIDs.isEmpty { return index }
        return min(index, max(orderIDs.count - 1, 0))
    }

    private func commitMove(id: AccountID, from: Int, to: Int) {
        guard from != to else { return }
        var next = orderIDs.isEmpty ? widgets.map(\.id) : orderIDs
        guard let fromIdx = next.firstIndex(of: id) else { return }
        let item = next.remove(at: fromIdx)
        let dest = min(max(0, to), next.count)
        next.insert(item, at: dest)
        orderIDs = next

        if DemoWidgets.isForced { return }

        do {
            try AccountStore.shared.applyOrder(next)
        } catch {
            syncOrderFromWidgets()
        }
    }

    private func confirmRemove(id: AccountID) {
        // Demo: drop from local order only.
        if DemoWidgets.isForced || !AccountStore.shared.accounts.contains(where: { $0.id == id }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                orderIDs.removeAll { $0 == id }
            }
            return
        }

        let label = AccountStore.shared.accounts.first(where: { $0.id == id })?.label ?? "this account"
        let alert = NSAlert()
        alert.messageText = "Remove \(label)?"
        alert.informativeText = "This removes the account from Dash Island and deletes its stored credentials."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            try? AccountStore.shared.remove(id: id)
            orderIDs.removeAll { $0 == id }
        }
        syncOrderFromWidgets()
    }

    private func syncOrderFromWidgets() {
        orderIDs = widgets.map(\.id)
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

private struct ClusterSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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
