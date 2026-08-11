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
    /// Live width of the drag overlay (slot band). Used for trash centering.
    @State private var bandWidth: CGFloat = 0
    /// Active hover chrome (usage / caption / status) — tips drawn outside ScrollView.
    @State private var elevatedChrome: WidgetHoverChrome?
    /// Half-height of the floating tip for correct `position` anchoring.
    @State private var floatingTipHalfHeight: CGFloat = 28
    /// Leading edge of the slot row in `dragSpace` (tracks scroll).
    @State private var rowOriginX: CGFloat = 0
    /// Viewport width of the scroll/clip region.
    @State private var viewportWidth: CGFloat = 0

    private static let maxSlots = IslandModel.maxItems
    private static let maxVisible = IslandModel.maxVisibleSlots
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap
    private static let trashMagnetEnter: CGFloat = 72
    private static let trashMagnetExit: CGFloat = 96
    private static let dragSpace = "dashIsland.dragSpace"
    private static let cell = AccountWidget.cellSize
    private static let cellH = AccountWidget.cellHeight
    private static let trashSize: CGFloat = 44
    /// Vertical band under the slot row reserved for the trash magnet while dragging.
    /// Must be included in the named coordinate space or `.position` lands off-canvas.
    private static let trashZoneH: CGFloat = 88
    /// Soft edge fade when content overflows the viewport.
    private static let edgeFadeWidth: CGFloat = 22
    /// Ignore tiny pointer jitter so click / context menu still work; past this, reorder.
    private static let dragMinDistance: CGFloat = 6

    private var slotCount: Int {
        let filled = max(baseOrder.count, widgets.count)
        return max(Self.minSlots, min(Self.maxSlots, filled))
    }

    private var needsHorizontalScroll: Bool {
        slotCount > Self.maxVisible
    }

    private var contentRowWidth: CGFloat {
        IslandModel.rowWidth(slotCount: slotCount)
    }

    private var viewportRowWidth: CGFloat {
        IslandModel.rowWidth(slotCount: min(slotCount, Self.maxVisible))
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

    /// Horizontal center of the slot band (not the whole island — AddRail is outside).
    /// Prefer live `bandWidth` from the drag overlay GeometryReader; never the
    /// stale 300pt fallback that parked the trash under the 2nd widget.
    private var trashCenterLocal: CGPoint {
        let w = bandWidth > 1 ? bandWidth : (clusterSize.width > 1 ? clusterSize.width : 400)
        return CGPoint(x: w * 0.5, y: Self.cellH + Self.trashZoneH * 0.42)
    }

    private var floatCenter: CGPoint {
        if magnetizedToTrash { return trashCenterLocal }
        return CGPoint(
            x: liftOrigin.x + dragTranslation.width,
            y: liftOrigin.y + dragTranslation.height
        )
    }

    var body: some View {
        // Width is always the parent proposal — never the ideal width of 6–8
        // gauge cells (ScrollView must not blow the island out).
        // Height stays `cellH` always — never expand on drag (that hung the UI).
        //
        // CRITICAL: while dragging, do not remove AddRail, close the rail, or
        // animate island width. Those layout storms froze the whole app.
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                slotRow

                if showEmptyAdd && draggingID == nil {
                    CenteredAddButton { adapter in
                        AccountChromeActions.beginAdd(adapter: adapter)
                    }
                }
            }
            // Flexible band: eats remaining width after AddRail, never grows past it.
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: Self.cellH, alignment: .top)
            .coordinateSpace(name: Self.dragSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ClusterSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(ClusterSizeKey.self) { next in
                // Freeze geometry writes mid-drag (preference storms hang main).
                guard draggingID == nil else { return }
                if abs(next.width - clusterSize.width) > 0.5 || clusterSize.width < 1 {
                    clusterSize = CGSize(width: next.width, height: Self.cellH)
                }
            }
            // Trash + lightweight float (not full AccountWidget / TimelineView).
            // GeometryReader gives the true band width so trash is centered —
            // frozen clusterSize (or 300 fallback) was parking it under widget #2.
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    let midX = geo.size.width * 0.5
                    let trashY = Self.cellH + Self.trashZoneH * 0.42
                    let trashPt = CGPoint(x: midX, y: trashY)
                    ZStack(alignment: .top) {
                        if draggingID != nil {
                            trashTarget
                                .position(trashPt)
                                .zIndex(50)
                        }
                        if let id = draggingID, let model = modelByID[id] {
                            dragFloatCard(model: model)
                                .scaleEffect(magnetizedToTrash ? 0.68 : 1.06)
                                .opacity(magnetizedToTrash ? 0.9 : 1)
                                .shadow(color: .black.opacity(0.45), radius: 14, y: 7)
                                .position(
                                    magnetizedToTrash
                                        ? trashPt
                                        : CGPoint(
                                            x: liftOrigin.x + dragTranslation.width,
                                            y: liftOrigin.y + dragTranslation.height
                                        )
                                )
                                .zIndex(100)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .onAppear {
                        if abs(geo.size.width - bandWidth) > 0.5 {
                            bandWidth = geo.size.width
                        }
                    }
                    .onChange(of: geo.size.width) { w in
                        if abs(w - bandWidth) > 0.5 { bandWidth = w }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.cellH + Self.trashZoneH, alignment: .top)
                .allowsHitTesting(false)
            }
            // Tips: never hit-test (full-size frame was eating drag gestures).
            .overlay(alignment: .top) {
                floatingHangTips
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            // Keep AddRail *mounted* while dragging so HStack width is stable.
            // Only hide visually — removing it resized the slot band and hung layout.
            if showAdd {
                AddRail(
                    onSelectVendor: { AccountChromeActions.beginAdd(adapter: $0) },
                    onExpandedChange: { onAddRailExpandedChange?($0) }
                )
                .padding(.trailing, 6)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(draggingID == nil ? 1 : 0)
                .allowsHitTesting(draggingID == nil)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Self.cellH, alignment: .top)
        .transaction { txn in
            // Never inherit island width springs into the cluster mid-drag.
            if draggingID != nil { txn.animation = nil }
        }
        .onAppear { syncFromWidgets() }
        .onChange(of: widgets.map(\.id)) { ids in
            guard draggingID == nil else { return }
            baseOrder = ids
        }
        .onChange(of: draggingID) { id in
            // Mouse passthrough only — do NOT close add rail / resize island here.
            NotificationCenter.default.post(name: .dashIslandDragActive, object: id != nil)
            if id != nil {
                elevatedChrome = nil
            }
        }
        .onChange(of: showAdd) { can in
            if !can { onAddRailExpandedChange?(false) }
        }
    }

    /// Cheap float: no TimelineView / hover prefs / context menus.
    private func dragFloatCard(model: WidgetViewModel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
            // Static rings only — burn motion TimelineView was part of the freeze cost.
            GaugeRingView(
                primaryFraction: model.primaryFraction,
                secondaryFraction: model.secondaryFraction,
                tertiaryFraction: model.tertiaryFraction,
                centerPercent: model.centerPercent,
                burnRatio: 0,
                tint: model.tint,
                size: 80,
                phaseOffset: 0
            )
            .offset(y: -6)
        }
        .frame(width: Self.cell, height: Self.cellH)
    }

    private func syncFromWidgets() {
        baseOrder = widgets.map(\.id)
    }

    // MARK: - Slots

    private var slotRow: some View {
        // Layout size comes only from the parent band (GeometryReader proposal).
        // Scroll content ideal width must never enlarge this.
        GeometryReader { geo in
            let available = max(0, geo.size.width)
            let contentW = contentRowWidth
            let scroll = IslandClusterLayout.needsScroll(
                contentWidth: Double(contentW),
                availableWidth: Double(available)
            )

            Group {
                if scroll {
                    scrollableSlotRow(availableWidth: available)
                } else {
                    centeredSlotRow(availableWidth: available)
                }
            }
            .frame(width: available, height: Self.cellH, alignment: .center)
            // Hard clip: widgets must not puncture the black island horizontally.
            .clipped()
            .onAppear { viewportWidth = available }
            .onChange(of: available) { w in
                guard draggingID == nil else { return }
                if abs(w - viewportWidth) > 0.5 { viewportWidth = w }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Self.cellH)
        // Implicit animations on the whole GeometryReader during drag = layout hang.
        // Neighbors still slide via `offset` without wrapping the reader.
        .onPreferenceChange(WidgetHoverElevatePreference.self) { list in
            guard draggingID == nil else { return }
            elevatedChrome = list.first(where: \.isActive)
        }
    }

    /// Usage / caption tips drawn in an overlay so they never affect row layout width.
    @ViewBuilder
    private var floatingHangTips: some View {
        if draggingID == nil,
           let chrome = elevatedChrome,
           chrome.showUsage || chrome.showCaption,
           let model = modelByID[chrome.accountID],
           let index = baseOrder.firstIndex(of: chrome.accountID)
        {
            let center = slotCenter(index: index)
            let tipTop = CGFloat(
                IslandClusterLayout.hangTipTopY(
                    cellHeight: Double(Self.cellH),
                    tipGap: Double(AccountWidget.tipGap)
                )
            )
            Group {
                if chrome.showUsage {
                    AccountHoverTips.usageCard(model: model)
                } else if chrome.showCaption {
                    AccountHoverTips.captionCard(model: model)
                }
            }
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: FloatingTipSizeKey.self, value: geo.size)
                }
            )
            .position(x: center.x, y: tipTop + floatingTipHalfHeight)
            .allowsHitTesting(false)
            .transition(.opacity)
            .onPreferenceChange(FloatingTipSizeKey.self) { size in
                if size.height > 1 {
                    floatingTipHalfHeight = size.height / 2
                }
            }
        }
    }

    /// Content fits: pin intrinsic row width and center in the available band.
    private func centeredSlotRow(availableWidth: CGFloat) -> some View {
        // Clear anchors layout size; row is drawn centered inside and cannot expand parent.
        Color.clear
            .frame(width: availableWidth, height: Self.cellH)
            .overlay {
                HStack(spacing: Self.gap) {
                    ForEach(0..<slotCount, id: \.self) { index in
                        slotCell(index: index)
                    }
                }
                .background(rowGeometryProbe)
                .fixedSize(horizontal: true, vertical: false)
            }
            .clipped()
    }

    /// Content wider than the island: scroll inside a fixed-size band.
    ///
    /// Critical: layout size is `Color.clear` only. Putting `ScrollView` in the
    /// primary layout tree lets its content ideal width (6–8 cells) blow the
    /// island open and shove gauges past the black body to the right.
    private func scrollableSlotRow(availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: availableWidth, height: Self.cellH)
            .overlay(alignment: .topLeading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.gap) {
                        ForEach(0..<slotCount, id: \.self) { index in
                            slotCell(index: index)
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(rowGeometryProbe)
                    .fixedSize(horizontal: true, vertical: false)
                }
                // Do not .disabled mid-drag — toggling ScrollView rebuilds layout and hung the UI.
                .frame(width: availableWidth, height: Self.cellH, alignment: .leading)
            }
            .overlay {
                scrollEdgeFades(availableWidth: availableWidth)
            }
            .clipped()
    }

    /// Tracks the slot row’s leading edge in drag space (scroll + center).
    private var rowGeometryProbe: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.dragSpace))
            Color.clear
                .preference(
                    key: SlotRowFrameKey.self,
                    value: CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: frame.height
                    )
                )
        }
        .onPreferenceChange(SlotRowFrameKey.self) { rect in
            // Freeze mid-drag — scroll/center probes during gesture hung the UI.
            guard draggingID == nil else { return }
            guard rect.width > 1 else { return }
            if abs(rect.minX - rowOriginX) > 0.5 {
                rowOriginX = rect.minX
            }
        }
    }

    /// Soft black edge fades when more content exists past that edge.
    @ViewBuilder
    private func scrollEdgeFades(availableWidth: CGFloat) -> some View {
        let pad: CGFloat = 4
        let rowW = contentRowWidth + pad
        let origin = rowOriginX
        let showLeading = origin < -1
        let showTrailing = origin + rowW > availableWidth + 1

        HStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black.opacity(showLeading ? 0.9 : 0), Color.black.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.edgeFadeWidth)
            .opacity(showLeading ? 1 : 0)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(showTrailing ? 0.9 : 0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.edgeFadeWidth)
            .opacity(showTrailing ? 1 : 0)
        }
        .frame(width: availableWidth, height: Self.cellH)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: showLeading)
        .animation(.easeOut(duration: 0.16), value: showTrailing)
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        let baseID: AccountID? = index < baseOrder.count ? baseOrder[index] : nil
        let isGap = draggingID != nil && !magnetizedToTrash && gapSlot == index
        let isDragHome = homeSlot == index && draggingID != nil
        // Push offset: slide this cell's widget toward its visual seat (gap layout).
        let pushX = pushOffsetX(baseIndex: index)
        let isElevated = baseID != nil && baseID == isElevatedAccount

        let cell = ZStack {
            SlotSkeleton(
                highlighted: isGap,
                empty: baseID == nil || isDragHome || (isGap && baseID == nil)
            )

            if isGap {
                // Drop preview: dashed seat + soft fill so the landing slot is obvious.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(0.72),
                                style: StrokeStyle(lineWidth: 1.8, dash: [5, 4])
                            )
                    )
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
                    isDropTarget: isGap && !isDragged,
                    // Cluster owns hang-below tips (ScrollView would clip them).
                    embedHangTips: false
                )
                .opacity(isDragged ? 0.001 : 1)
                .offset(x: isDragged ? 0 : pushX)
                .animation(
                    draggingID == nil
                        ? nil
                        : .interactiveSpring(response: 0.28, dampingFraction: 0.84),
                    value: pushX
                )
            }
        }
        .frame(width: Self.cell, height: Self.cellH)
        .contentShape(Rectangle())

        // Cell-level drag (not on AccountWidget): tip overlay was swallowing
        // gestures. Plain DragGesture + min distance keeps menus/clicks usable.
        if allowsEditing, let oid = baseID {
            cell.gesture(reorderGesture(for: oid, slotIndex: index))
                .zIndex(slotZIndex(isElevated: isElevated, isDragHome: isDragHome, index: index))
        } else {
            cell.zIndex(slotZIndex(isElevated: isElevated, isDragHome: isDragHome, index: index))
        }
    }

    /// Hovered tip > drag-home ghost > natural left-to-right stack.
    private func slotZIndex(isElevated: Bool, isDragHome: Bool, index: Int) -> Double {
        if isElevated { return 80 }
        if isDragHome { return 2 }
        return Double(index)
    }

    private var isElevatedAccount: AccountID? {
        elevatedChrome?.isActive == true ? elevatedChrome?.accountID : nil
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
                .fill(Color.red.opacity(magnetizedToTrash ? 0.62 : 0.28))
                .frame(
                    width: magnetizedToTrash ? 54 : Self.trashSize,
                    height: magnetizedToTrash ? 54 : Self.trashSize
                )
            // Soft ring so the magnet reads even over dark bleed.
            Circle()
                .strokeBorder(Color.white.opacity(magnetizedToTrash ? 0.35 : 0.14), lineWidth: 1.2)
                .frame(
                    width: magnetizedToTrash ? 54 : Self.trashSize,
                    height: magnetizedToTrash ? 54 : Self.trashSize
                )
            Image(systemName: magnetizedToTrash ? "trash.fill" : "trash")
                .font(.system(size: magnetizedToTrash ? 20 : 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .shadow(color: Color.red.opacity(magnetizedToTrash ? 0.55 : 0.28), radius: magnetizedToTrash ? 14 : 8)
        .allowsHitTesting(false)
        .accessibilityLabel("Remove account")
    }

    // MARK: - Drag (plain DragGesture — right-click context menu stays separate)

    private func reorderGesture(for id: AccountID, slotIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: Self.dragMinDistance, coordinateSpace: .named(Self.dragSpace))
            .onChanged { drag in
                if draggingID == nil {
                    beginDrag(id: id, slotIndex: slotIndex, start: drag.startLocation)
                }
                guard draggingID == id else { return }
                applyDrag(drag)
            }
            .onEnded { drag in
                guard draggingID == id else { return }
                endDrag(id: id, drag: drag)
            }
    }

    private func beginDrag(id: AccountID, slotIndex: Int, start: CGPoint) {
        if baseOrder.isEmpty { syncFromWidgets() }
        // Prefer live overlay band width for trash magnet; fall back to cluster.
        if bandWidth < 1, clusterSize.width > 1 {
            bandWidth = clusterSize.width
        }
        // No island resize / no NSApp.activate here — both caused main-thread freezes.
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            draggingID = id
            homeSlot = baseOrder.firstIndex(of: id) ?? slotIndex
            gapSlot = homeSlot
            liftOrigin = start
            dragTranslation = .zero
            magnetizedToTrash = false
            elevatedChrome = nil
        }
    }

    private func applyDrag(_ drag: DragGesture.Value) {
        // Translation-only: stable if layout height never changes mid-gesture.
        dragTranslation = drag.translation
        let finger = CGPoint(
            x: liftOrigin.x + drag.translation.width,
            y: liftOrigin.y + drag.translation.height
        )
        updateTrashMagnet(finger: finger)
        // No withAnimation here — slotRow already springs on `gapSlot`.
        // Animating every mouse-move + preference updates hung the main thread.
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
        let stride = Self.cell + Self.gap
        // `rowOriginX` is the live leading edge of the slot row in drag space
        // (centered when ≤5, scroll-offset when >5).
        let leading = rowOriginX
        return CGPoint(
            x: leading + CGFloat(index) * stride + Self.cell / 2,
            y: Self.cellH / 2
        )
    }

    private func slotIndexAt(localX x: CGFloat) -> Int? {
        let n = slotCount
        guard n > 0 else { return nil }
        let stride = Self.cell + Self.gap
        let leading = rowOriginX
        let localX = x - leading
        let rowW = contentRowWidth
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

/// Live frame of the slot HStack in drag space (scroll + center).
private struct SlotRowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct FloatingTipSizeKey: PreferenceKey {
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
           (1...IslandModel.maxItems).contains(n) {
            return n
        }
        return 3
    }

    static func make(count: Int? = nil) -> [WidgetViewModel] {
        let n = min(IslandModel.maxItems, max(1, count ?? Self.count))
        let base = samples
        if n <= base.count { return Array(base.prefix(n)) }
        // Extend demo pool for scroll testing (stable UUIDs).
        var out = base
        var i = base.count
        while out.count < n {
            i += 1
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!
            out.append(
                WidgetViewModel(
                    id: id,
                    title: "demo \(i)",
                    vendorID: "fake",
                    tint: .neutral,
                    primaryFraction: Double((i * 17) % 80) / 100,
                    secondaryFraction: nil,
                    usedPrimaryFraction: Double((i * 17) % 80) / 100,
                    centerPercent: (i * 17) % 80,
                    burnRatio: 0,
                    hoverWindows: [
                        HoverWindowLine(label: "5h", usage: "demo", resetAt: nil)
                    ],
                    errorCaption: nil,
                    isAwaitingFirstSample: false,
                    health: .ok,
                    healthTooltip: "ok"
                )
            )
        }
        return out
    }

    private static let samples: [WidgetViewModel] = [
        WidgetViewModel(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "claude · home",
            vendorID: "claude",
            tint: .claude,
            primaryFraction: 0.18,
            secondaryFraction: 0.12,
            tertiaryFraction: 0.38,
            usedPrimaryFraction: 0.18,
            centerPercent: 18,
            burnRatio: 0.0,
            hoverWindows: [
                HoverWindowLine(label: "5h", usage: "1.8k / 10k", resetAt: Date().addingTimeInterval(4 * 3600)),
                HoverWindowLine(label: "wk", usage: "12k / 100k", resetAt: Date().addingTimeInterval(3 * 86_400)),
                HoverWindowLine(label: "Fable", usage: "38%", resetAt: Date().addingTimeInterval(2 * 86_400))
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
            secondaryFraction: nil,
            tertiaryFraction: 0.22,
            usedPrimaryFraction: 0.41,
            centerPercent: 41,
            burnRatio: 1.0,
            hoverWindows: [
                HoverWindowLine(label: "wk", usage: "41%", resetAt: Date().addingTimeInterval(5 * 86_400 + 12 * 3600)),
                HoverWindowLine(label: "Spark", usage: "22%", resetAt: Date().addingTimeInterval(6 * 86_400))
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
