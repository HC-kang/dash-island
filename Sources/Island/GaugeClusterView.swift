import AppKit
import SwiftUI

/// Slot grid (min 3). Skeleton + widget share the same cell (no dual layout).
/// Drag: long-press then move; neighbors **offset** to open a gap (drop preview).
/// Widgets keep stable cell identity so gestures/menus stay alive. Trash magnet deletes.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    var panelBlackHeight: CGFloat = 160

    /// Grows island black body when the add rail is revealed.
    var onAddRailExpandedChange: ((Bool) -> Void)?

    /// Frozen for the whole gesture.
    @State private var baseOrder: [AccountID] = []
    @State private var draggingID: AccountID?
    @State private var homeSlot: Int?
    @State private var liftOrigin: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    /// Gap index = drop preview seat (neighbors pack around it via offset).
    @State private var gapSlot: Int?
    @State private var magnetizedToTrash = false
    @State private var clusterSize: CGSize = .zero

    private static let maxSlots = IslandModel.maxItems
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap
    private static let trashMagnetEnter: CGFloat = 72
    private static let trashMagnetExit: CGFloat = 96
    private static let dragSpace = "dashIsland.dragSpace"
    private static let cell = AccountWidget.cellSize
    private static let cellH = AccountWidget.cellSize + 8
    private static let trashSize: CGFloat = 44
    private static let trashOffsetY: CGFloat = 52
    /// Short press keeps context-menu / click free; then drag to reorder.
    private static let dragLongPress: Double = 0.18

    private var slotCount: Int {
        let filled = max(baseOrder.count, widgets.count)
        return max(Self.minSlots, min(Self.maxSlots, filled))
    }

    private var modelByID: [AccountID: WidgetViewModel] {
        Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
    }

    /// Visual slot index for each account while dragging (gap is empty).
    private var visualSlotByID: [AccountID: Int] {
        guard let drag = draggingID else {
            return Dictionary(uniqueKeysWithValues: baseOrder.enumerated().map { ($0.element, $0.offset) })
        }
        let others = baseOrder.filter { $0 != drag }
        let hole = gapSlot ?? homeSlot ?? 0
        var map: [AccountID: Int] = [:]
        var oi = 0
        for i in 0..<slotCount {
            if i == hole { continue }
            guard oi < others.count else { break }
            map[others[oi]] = i
            oi += 1
        }
        if let home = homeSlot {
            map[drag] = home
        }
        return map
    }

    private var trashCenterLocal: CGPoint {
        let w = clusterSize.width > 1 ? clusterSize.width : 300
        return CGPoint(x: w / 2, y: Self.cellH + Self.trashOffsetY)
    }

    private var floatCenter: CGPoint {
        if magnetizedToTrash { return trashCenterLocal }
        return CGPoint(
            x: liftOrigin.x + dragTranslation.width,
            y: liftOrigin.y + dragTranslation.height
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                slotRow

                if showEmptyAdd && draggingID == nil {
                    CenteredAddButton { adapter in
                        AccountChromeActions.beginAdd(adapter: adapter)
                    }
                }

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
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellH, alignment: .top)
            .coordinateSpace(name: Self.dragSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ClusterSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(ClusterSizeKey.self) { clusterSize = $0 }

            if showAdd && draggingID == nil {
                AddRail(
                    onSelectVendor: { AccountChromeActions.beginAdd(adapter: $0) },
                    onExpandedChange: { onAddRailExpandedChange?($0) }
                )
                .padding(.trailing, 6)
            }
        }
        .frame(height: Self.cellH, alignment: .top)
        .onAppear { syncFromWidgets() }
        .onChange(of: widgets.map(\.id)) { ids in
            guard draggingID == nil else { return }
            baseOrder = ids
        }
        .onChange(of: draggingID) { id in
            NotificationCenter.default.post(name: .dashIslandDragActive, object: id != nil)
            if id != nil { onAddRailExpandedChange?(false) }
        }
        .onChange(of: showAdd) { can in
            if !can { onAddRailExpandedChange?(false) }
        }
    }

    private func syncFromWidgets() {
        baseOrder = widgets.map(\.id)
    }

    // MARK: - Slots

    private var slotRow: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<slotCount, id: \.self) { index in
                slotCell(index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.84), value: gapSlot)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.84), value: magnetizedToTrash)
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        let baseID: AccountID? = index < baseOrder.count ? baseOrder[index] : nil
        let isGap = draggingID != nil && !magnetizedToTrash && gapSlot == index
        let isDragHome = homeSlot == index && draggingID != nil
        // Push offset: slide this cell's widget toward its visual seat (gap layout).
        let pushX = pushOffsetX(baseIndex: index)

        ZStack {
            SlotSkeleton(
                highlighted: isGap,
                empty: baseID == nil || isDragHome || (isGap && baseID == nil)
            )

            if isGap {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1.6)
                    .padding(1)
                    .allowsHitTesting(false)
            }

            // Widget stays in its **base** cell for identity/gesture/menu continuity.
            // Visual reorder = horizontal offset only (not reparenting).
            if let oid = baseID, let model = modelByID[oid] {
                let isDragged = draggingID == oid
                AccountWidget(
                    model: model,
                    isDragging: false,
                    isDropTarget: false
                )
                .opacity(isDragged ? 0.001 : 1)
                .offset(x: isDragged ? 0 : pushX)
                .zIndex(isDragged ? 2 : 1)
                // simultaneous + long-press: right-click / menus still work.
                .simultaneousGesture(allowsEditing ? reorderGesture(for: oid, slotIndex: index) : nil)
            }
        }
        .frame(width: Self.cell, height: Self.cellH)
        // No clip — pushed neighbors may paint into adjacent cell bounds.
    }

    /// Horizontal shift so the widget lands in its gap-packed visual slot.
    private func pushOffsetX(baseIndex: Int) -> CGFloat {
        guard draggingID != nil,
              baseIndex < baseOrder.count
        else { return 0 }
        let id = baseOrder[baseIndex]
        if id == draggingID { return 0 }
        guard let visual = visualSlotByID[id] else { return 0 }
        let stride = Self.cell + Self.gap
        return CGFloat(visual - baseIndex) * stride
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

    // MARK: - Drag (long-press then pan — does not steal right-click / menus)

    private func reorderGesture(for id: AccountID, slotIndex: Int) -> some Gesture {
        LongPressGesture(minimumDuration: Self.dragLongPress)
            .sequenced(before: DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.dragSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    // Armed — wait for drag.
                    break
                case .second(true, let drag?):
                    if draggingID == nil {
                        beginDrag(id: id, slotIndex: slotIndex)
                    }
                    guard draggingID == id else { return }
                    applyDrag(drag)
                default:
                    break
                }
            }
            .onEnded { value in
                switch value {
                case .second(true, let drag?):
                    guard draggingID == id else { return }
                    endDrag(id: id, drag: drag)
                default:
                    // Long-press cancelled / no drag — leave order alone.
                    if draggingID == id {
                        cancelDrag()
                    }
                }
            }
    }

    private func beginDrag(id: AccountID, slotIndex: Int) {
        if baseOrder.isEmpty { syncFromWidgets() }
        draggingID = id
        homeSlot = baseOrder.firstIndex(of: id) ?? slotIndex
        gapSlot = homeSlot
        liftOrigin = slotCenter(index: homeSlot ?? slotIndex)
        dragTranslation = .zero
        magnetizedToTrash = false
        // Key window so drop + trash feel responsive.
        NotificationCenter.default.post(name: .dashIslandRequestKey, object: nil)
    }

    private func applyDrag(_ drag: DragGesture.Value) {
        dragTranslation = drag.translation
        let finger = CGPoint(
            x: liftOrigin.x + drag.translation.width,
            y: liftOrigin.y + drag.translation.height
        )
        updateTrashMagnet(finger: finger)
        if magnetizedToTrash {
            if gapSlot != homeSlot { gapSlot = homeSlot }
        } else if let slot = slotIndexAt(localX: finger.x), gapSlot != slot {
            gapSlot = slot
        }
    }

    private func endDrag(id: AccountID, drag: DragGesture.Value) {
        let finger = CGPoint(
            x: liftOrigin.x + drag.translation.width,
            y: liftOrigin.y + drag.translation.height
        )
        let remove = magnetizedToTrash || distanceToTrash(finger) <= Self.trashMagnetEnter
        let dropSlot = remove ? nil : (gapSlot ?? slotIndexAt(localX: finger.x))
        let from = homeSlot ?? baseOrder.firstIndex(of: id)

        cancelDrag()

        if remove {
            confirmRemove(id: id)
            return
        }
        if let to = dropSlot, let from {
            commitMove(id: id, from: from, to: to)
        }
    }

    private func cancelDrag() {
        draggingID = nil
        homeSlot = nil
        dragTranslation = .zero
        gapSlot = nil
        magnetizedToTrash = false
    }

    private func updateTrashMagnet(finger: CGPoint) {
        let d = distanceToTrash(finger)
        if magnetizedToTrash {
            if d > Self.trashMagnetExit { magnetizedToTrash = false }
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
        let stride = Self.cell + Self.gap
        let rowW = CGFloat(n) * Self.cell + CGFloat(max(0, n - 1)) * Self.gap
        let w = clusterSize.width > 1 ? clusterSize.width : rowW
        let leading = (w - rowW) / 2
        return CGPoint(
            x: leading + CGFloat(index) * stride + Self.cell / 2,
            y: Self.cellH / 2
        )
    }

    private func slotIndexAt(localX x: CGFloat) -> Int? {
        let n = slotCount
        guard n > 0 else { return nil }
        let stride = Self.cell + Self.gap
        let rowW = CGFloat(n) * Self.cell + CGFloat(max(0, n - 1)) * Self.gap
        let w = clusterSize.width > 1 ? clusterSize.width : rowW
        let leading = (w - rowW) / 2
        let localX = x - leading
        guard localX >= -Self.cell * 0.5, localX <= rowW + Self.cell * 0.5 else { return nil }
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)
        let maxFilled = max(baseOrder.count - 1, 0)
        return min(index, maxFilled)
    }

    private func commitMove(id: AccountID, from: Int, to: Int) {
        guard from != to else { return }
        var next = baseOrder.isEmpty ? widgets.map(\.id) : baseOrder
        guard let fromIdx = next.firstIndex(of: id) else { return }
        let item = next.remove(at: fromIdx)
        let dest: Int
        if to > fromIdx {
            dest = min(to, next.count)
        } else {
            dest = min(max(0, to), next.count)
        }
        next.insert(item, at: dest)
        baseOrder = next

        // Never skip persist for real accounts even if DEMO env is set.
        if DemoWidgets.isForced && !AccountStore.shared.accounts.contains(where: { $0.id == id }) {
            return
        }

        do {
            try AccountStore.shared.applyOrder(next)
        } catch {
            syncFromWidgets()
        }
    }

    private func confirmRemove(id: AccountID) {
        // Demo / unknown id: local only, still confirm-looking snap-back is fine.
        if !AccountStore.shared.accounts.contains(where: { $0.id == id }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                baseOrder.removeAll { $0 == id }
            }
            return
        }
        let label = AccountStore.shared.accounts.first(where: { $0.id == id })?.label ?? "this account"
        // Do not sync here — `remove` presents a deferred confirm. Cancel leaves order
        // intact; confirm updates via AccountStore → widgets → baseOrder onChange.
        AccountChromeActions.remove(accountID: id, label: label)
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
                        Color.white.opacity(highlighted ? 0.12 : 0.055),
                        Color.white.opacity(highlighted ? 0.07 : 0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(highlighted ? 0.32 : 0.08),
                        style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: empty ? [5, 4] : [])
                    )
            )
            .overlay {
                if empty {
                    Circle()
                        .strokeBorder(Color.white.opacity(highlighted ? 0.16 : 0.06), lineWidth: 4)
                        .frame(width: 56, height: 56)
                        .offset(y: -6)
                }
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
    /// Env-only flag. Prefer real accounts whenever any exist (see IslandRootView).
    static var isForced: Bool {
        ProcessInfo.processInfo.environment["DASHISLAND_DEMO"] == "1"
    }

    static func isEnabled(accountsEmpty: Bool) -> Bool {
        isForced && accountsEmpty
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
            vendorID: "claude",
            tint: .claude,
            primaryFraction: 0.18,
            secondaryFraction: 0.12,
            usedPrimaryFraction: 0.18,
            centerPercent: 18,
            burnRatio: 0.0,
            hoverWindows: [
                HoverWindowLine(label: "5h", usage: "1.8k / 10k", resetAt: Date().addingTimeInterval(4 * 3600)),
                HoverWindowLine(label: "wk", usage: "12k / 100k", resetAt: Date().addingTimeInterval(3 * 86_400))
            ],
            errorCaption: nil,
            isAwaitingFirstSample: false,
            health: .ok,
            healthTooltip: "ok"
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "codex · team",
            vendorID: "codex",
            tint: .codex,
            primaryFraction: 0.41,
            secondaryFraction: 0.55,
            usedPrimaryFraction: 0.41,
            centerPercent: 41,
            burnRatio: 1.0,
            hoverWindows: [
                HoverWindowLine(label: "wk", usage: "41%", resetAt: Date().addingTimeInterval(5 * 86_400 + 12 * 3600))
            ],
            errorCaption: nil,
            isAwaitingFirstSample: false,
            health: .ok,
            healthTooltip: "ok"
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            title: "claude · work",
            vendorID: "claude",
            tint: .claude,
            primaryFraction: 0.72,
            secondaryFraction: 0.41,
            usedPrimaryFraction: 0.72,
            centerPercent: 72,
            burnRatio: 1.8,
            hoverWindows: [
                HoverWindowLine(label: "5h", usage: "72%", resetAt: Date().addingTimeInterval(2 * 3600 + 15 * 60)),
                HoverWindowLine(label: "wk", usage: "41%", resetAt: Date().addingTimeInterval(4 * 86_400))
            ],
            errorCaption: nil,
            isAwaitingFirstSample: false,
            health: .warn,
            healthTooltip: "token expires soon"
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            title: "grok · play",
            vendorID: "grok",
            tint: .grok,
            primaryFraction: 0.33,
            secondaryFraction: 0.28,
            usedPrimaryFraction: 0.33,
            centerPercent: 33,
            burnRatio: 0.4,
            hoverWindows: [
                HoverWindowLine(label: "wk", usage: "33%", resetAt: Date().addingTimeInterval(2 * 86_400 + 5 * 3600)),
                HoverWindowLine(label: "mo", usage: "28k / 150k", resetAt: Date().addingTimeInterval(12 * 86_400))
            ],
            errorCaption: nil,
            isAwaitingFirstSample: false,
            health: .ok,
            healthTooltip: "ok"
        ),
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
            title: "codex · side",
            vendorID: "codex",
            tint: .codex,
            primaryFraction: 0.09,
            secondaryFraction: nil,
            usedPrimaryFraction: 0.09,
            centerPercent: 9,
            burnRatio: 0.0,
            hoverWindows: [
                HoverWindowLine(label: "wk", usage: "9%", resetAt: Date().addingTimeInterval(6 * 86_400))
            ],
            errorCaption: "reauth: codex login",
            isAwaitingFirstSample: false,
            health: .error,
            healthTooltip: "reauth: codex login"
        ),
    ]
}
