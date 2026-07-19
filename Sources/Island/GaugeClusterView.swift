import AppKit
import SwiftUI

/// Fixed **slots** (default 3). Widgets sit in slots like macOS/iOS home-screen.
/// Dragging lifts the widget onto the cursor; the home slot shows a gray skeleton.
struct GaugeClusterView: View {
    let widgets: [WidgetViewModel]
    var accountCount: Int = 0
    var showEmptyAdd: Bool = false
    var showAdd: Bool = false
    var allowsEditing: Bool = true
    var panelBlackHeight: CGFloat = 160

    @State private var draggingID: AccountID?
    /// Global cursor during drag (for the floating lift layer).
    @State private var dragGlobalPoint: CGPoint?
    @State private var inRemoveZone = false
    @State private var clusterGlobalFrame: CGRect = .zero
    @State private var hoveredSlot: Int?

    private static let maxSlots = IslandModel.maxItems
    private static let minSlots = 3
    private static let gap: CGFloat = IslandModel.cellGap

    /// Always at least 3 slots; grow to match accounts up to 5.
    private var slotCount: Int {
        max(Self.minSlots, min(Self.maxSlots, max(widgets.count, showEmptyAdd ? 0 : widgets.count)))
    }

    var body: some View {
        ZStack {
            slotRow

            if showAdd && draggingID == nil {
                trailingAdd
            }

            // Lifted widget follows the mouse (not an in-slot offset).
            if let id = draggingID,
               let model = widgets.first(where: { $0.id == id }),
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

    // MARK: - Slots

    private var slotRow: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<slotCount, id: \.self) { index in
                slotCell(index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: widgets.map(\.id))
        .animation(.easeOut(duration: 0.15), value: draggingID)
    }

    @ViewBuilder
    private func slotCell(index: Int) -> some View {
        let occupant = index < widgets.count ? widgets[index] : nil
        let isHomeOfDrag = occupant?.id == draggingID
        let isHoverTarget = hoveredSlot == index && draggingID != nil && !inRemoveZone

        ZStack {
            // Always paint a slot chassis.
            SlotSkeleton(
                highlighted: isHoverTarget,
                empty: occupant == nil && !isHomeOfDrag
            )

            if let occupant, !isHomeOfDrag {
                AccountWidget(model: occupant, isDragging: false, isDropTarget: isHoverTarget)
                    .highPriorityGesture(allowsEditing ? dragGesture(for: occupant.id) : nil)
            } else if isHomeOfDrag {
                // Home slot while lifted — skeleton only (already drawn).
                Color.clear
            } else if showEmptyAdd || (showAdd && occupant == nil) {
                // Empty slot acts as an add target when under cap.
                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { /* menu via overlay button if needed */ }
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

    /// Drawn in an overlay using global→local conversion via preference + fixed position.
    @ViewBuilder
    private func floatingWidget(model: WidgetViewModel, globalPoint: CGPoint) -> some View {
        // Position relative to cluster: convert global → local of this ZStack.
        let local = CGPoint(
            x: globalPoint.x - clusterGlobalFrame.minX,
            y: globalPoint.y - clusterGlobalFrame.minY
        )
        AccountWidget(model: model, isDragging: true, isDropTarget: false)
            .scaleEffect(1.07)
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .position(
                x: local.x,
                y: local.y
            )
            .zIndex(100)
            .allowsHitTesting(false)
    }

    // MARK: - Drag

    private func dragGesture(for id: AccountID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = id
                }
                guard draggingID == id else { return }

                dragGlobalPoint = value.location
                let remove = isInRemoveZone(value.location)
                if remove != inRemoveZone { inRemoveZone = remove }

                if !remove {
                    let slot = slotIndex(atGlobal: value.location)
                    hoveredSlot = slot
                    if let slot {
                        try? AccountStore.shared.move(id: id, toIndex: slot)
                    }
                } else {
                    hoveredSlot = nil
                }
            }
            .onEnded { value in
                let remove = isInRemoveZone(value.location)
                let dragged = id
                if !remove, let slot = slotIndex(atGlobal: value.location) {
                    try? AccountStore.shared.move(id: dragged, toIndex: slot)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    draggingID = nil
                    dragGlobalPoint = nil
                    inRemoveZone = false
                    hoveredSlot = nil
                }
                if remove {
                    confirmRemove(id: dragged)
                }
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
        guard localX >= -cell * 0.35, localX <= rowW + cell * 0.35 else { return nil }
        var index = Int(floor(localX / stride))
        index = min(max(0, index), n - 1)
        // Don't target empty trailing slots past last widget + 1 (allow append).
        let maxIndex = min(n - 1, max(widgets.count, 0))
        return min(index, max(0, maxIndex))
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
        // Below black expanded body (transparent overflow).
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
    }
}

// MARK: - Slot skeleton

/// Gray chassis for empty slots and for a widget's home slot while lifted.
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
                // Soft inner disc hint (gauge silhouette).
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
