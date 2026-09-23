import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var orchestrator = UsageOrchestrator.shared
    @ObservedObject private var preferences = PreferencesStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var prefsOpen = false
    @State private var dialogOpen = false
    @State private var menuTracking = false
    @State private var statusPanelOpen = false
    @State private var detailsOpen = false
    @State private var dragActive = false
    @State private var pointerInside = false
    @State private var collapseTask: Task<Void, Never>?
    /// Dwell before lazy network refresh on expand (avoids hover-flick burns).
    @State private var expandRefreshTask: Task<Void, Never>?
    /// Expanded chrome/content visibility — decoupled from `model.state` window size
    /// so the notch base never unmounts or “pops back in” after a size snap.
    @State private var showExpandedShell = false

    private let bodyOutset: CGFloat = 1.0
    /// Match add-rail dwell philosophy — intentional expand, not mouse graze.
    private let expandRefreshDwellNs: UInt64 = 400_000_000
    /// Re-ask while the island stays open. `expandInterval` is the real gate.
    private let expandRefreshRepeatNs: UInt64 = 60_000_000_000
    /// Expanded shell tuck-away before window shrinks to compact.
    private let collapseShellNs: UInt64 = 200_000_000

    /// Prefs, dialogs, menus, status popover — keep island expanded.
    private var blockingOverlay: Bool {
        prefsOpen
            || dialogOpen
            || menuTracking
            || statusPanelOpen
            || detailsOpen
            || dragActive
            || IslandDialogController.shared.isProgressOpen
    }

    var body: some View {
        if #available(macOS 15.0, *) {
            // SwiftUI gestures also need to accept the click that activates this window.
            islandContent.allowsWindowActivationEvents()
        } else {
            islandContent
        }
    }

    private var islandContent: some View {
        // Layer order (bottom → top):
        // 1) Notch base — always mounted, always drawn (never if/else with expanded).
        // 2) Expanded shell — toggled via `showExpandedShell` so size can shrink *after* it leaves.
        //
        // NSWindow is a fixed canvas (`model.canvasSize`). Hover/hit only cover the
        // black body (`hitSize`) — not drag bleed or empty canvas — so nearby
        // menu-bar / desktop clicks are not stolen.
        ZStack(alignment: .top) {
            // Must not participate in expand/collapse animations — otherwise the
            // notch fill rides the size spring and looks like it bobs vertically.
            compactNotchBase
                .allowsHitTesting(!showExpandedShell)
                .accessibilityHidden(showExpandedShell)
                .transaction { $0.animation = nil }

            if showExpandedShell {
                expandedChrome
                    .transition(shellTransition(insertY: -8, removeY: -40))
                expandedContent
                    .transition(shellTransition(insertY: -6, removeY: -44))
            }
        }
        .environment(\.islandMotion, motion)
        // Hover target = black body (not bleed). Outer frames only reserve canvas space.
        .frame(width: hoverWidth, height: hoverHeight, alignment: .top)
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandPointerInsideChanged)) { note in
            handleHover((note.object as? Bool) ?? false)
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(nil, value: model.size)
        .animation(nil, value: model.hitSize)
        .onAppear {
            syncExpandedItemCount()
            showExpandedShell = (model.state == .expanded)
        }
        .onChange(of: accountStore.accounts.count) { _ in syncExpandedItemCount() }
        .onChange(of: orchestrator.widgets.count) { _ in syncExpandedItemCount() }
        .onChange(of: model.state) { newState in
            // External compact (e.g. follow-cursor hop) must drop the shell too.
            if newState == .compact {
                showExpandedShell = false
                expandRefreshTask?.cancel()
                expandRefreshTask = nil
            } else if newState == .expanded {
                if !showExpandedShell {
                    // Shell fade only — size already applied without this animation.
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                        showExpandedShell = true
                    }
                }
                scheduleExpandRefresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandPrefsOpenChanged)) { note in
            prefsOpen = (note.object as? Bool) ?? PrefsWindowController.shared.isOpen
            handleOverlayChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandDialogOpenChanged)) { note in
            dialogOpen = (note.object as? Bool)
                ?? (IslandDialogController.shared.isOpen || IslandDialogController.shared.isProgressOpen)
            handleOverlayChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking = true
            collapseTask?.cancel()
            expandOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
            // Menu dismissed — collapse only if nothing else is holding us open.
            if !blockingOverlay {
                scheduleCollapse()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandStatusPanelOpenChanged)) { note in
            statusPanelOpen = (note.object as? Bool) ?? false
            handleOverlayChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandDetailsOpenChanged)) { note in
            detailsOpen = (note.object as? Bool) ?? false
            handleOverlayChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashIslandDragActive)) { note in
            dragActive = (note.object as? Bool) ?? false
            handleOverlayChange()
        }
    }

    private func handleOverlayChange() {
        if blockingOverlay {
            collapseTask?.cancel()
            expandOpen()
        } else if !pointerInside && (model.state == .expanded || showExpandedShell) {
            scheduleCollapse()
        }
    }

    private func openPrefs() {
        // Separate NSPanel — never `.sheet` on the island (that drags the HUD down).
        PrefsWindowController.shared.show()
    }

    private func syncExpandedItemCount() {
        if showEmptyAdd {
            model.setExpandedItemCount(0)
        } else {
            model.setExpandedItemCount(widgets.count)
        }
    }

    // MARK: - Compact notch base (always on)

    /// Physical-notch cover only. Geometry from `notch` alone — never tracks
    /// expanded panel height, so hover in/out must not move it vertically.
    private var compactNotchBase: some View {
        let nw = model.notch.width
        let nh = model.notch.height
        let bodyW = nw + bodyOutset * 2
        let bodyH = nh + bodyOutset
        let radius = cornerRadius(forHeight: bodyH)

        return ZStack {
            IslandShape(bottomRadius: radius)
                .fill(Color.black)
            NotchRimGlow(
                bottomRadius: radius,
                lineWidth: 1.35,
                peakOpacity: 0.95,
                baseOpacity: 0.28,
                accent: preferences.rimAccent.color,
                // Hidden under the expanded body while the shell is up.
                frameInterval: MotionPolicy.rimFrameInterval(
                    motion,
                    expanded: false,
                    fetching: orchestrator.loading && !showExpandedShell
                )
            )
        }
        .frame(width: bodyW, height: bodyH, alignment: .top)
        // Fill parent width only for centering; height stays notch-sized (not model.size.height).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(IslandShape(bottomRadius: radius))
        .onTapGesture {
            collapseTask?.cancel()
            expandOpen()
        }
        .accessibilityLabel("Dash Island")
        .accessibilityHint("Hover or click to show usage")
        .accessibilityValue(compactLabel)
    }

    // MARK: - Expanded (slim: gauges only + notch-ear chrome)

    /// Tight hover/hit rect — matches `model.hitSize` (black body, not canvas bleed).
    private var hoverWidth: CGFloat { model.hitSize.width }
    private var hoverHeight: CGFloat { model.hitSize.height }

    private var expandedChrome: some View {
        let radius = min(26, cornerRadius(forHeight: model.notch.height) + 8)
        let contentW = model.expandedContentWidth
        return ZStack {
            IslandShape(bottomRadius: radius)
                .fill(Color.black)
            NotchRimGlow(
                bottomRadius: radius,
                lineWidth: 1.4,
                peakOpacity: 0.92,
                baseOpacity: 0.24,
                period: 3.2,
                accent: preferences.rimAccent.color,
                frameInterval: MotionPolicy.rimFrameInterval(motion, expanded: true, fetching: false)
            )
        }
        // Black body only; parent hover frame is the same width.
        .frame(width: contentW, height: model.blackHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .allowsHitTesting(false)
    }

    private var expandedContent: some View {
        let contentW = model.expandedContentWidth
        return VStack(spacing: 0) {
            NotchBandChrome(
                notchWidth: model.notch.width,
                notchHeight: model.notch.height
            ) {
                openPrefs()
            }

            GaugeClusterView(
                widgets: widgets,
                accountCount: accountStore.accounts.count,
                showEmptyAdd: showEmptyAdd,
                showAdd: showAdd,
                allowsEditing: true,
                panelBlackHeight: model.blackHeight,
                onAddRailExpandedChange: { open in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        model.setAddRailOpen(open)
                    }
                }
            )
            .padding(.leading, 14)
            .padding(.trailing, showAdd ? 4 : 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.addRailOpen)
        }
        // Tall enough for hang-below tips; black silhouette is only the top band.
        .frame(
            width: contentW,
            height: model.blackHeight + IslandModel.tooltipHitPad,
            alignment: .top
        )
        // GaugeClusterView clips its slot row before drawing hover overlays.
        // A second mask here clips the tips where they overlap the body's edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var motion: MotionPolicy.Conditions {
        MotionPolicy.Conditions(
            reduceMotion: reduceMotion,
            lowPower: model.lowPower,
            hidden: model.windowHidden
        )
    }

    /// Reduce Motion: fade only, no slide.
    private func shellTransition(insertY: CGFloat, removeY: CGFloat) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: insertY)),
            removal: .opacity.combined(with: .offset(y: removeY))
        )
    }

    private func cornerRadius(forHeight h: CGFloat) -> CGFloat {
        min(16, max(11, h * 0.40))
    }

    private var compactLabel: String {
        if useDemoWidgets { return "Demo" }
        let n = accountStore.accounts.count
        if n == 0 { return "Dash Island" }
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    /// Demo env is ignored whenever real accounts exist on disk — never mask them.
    private var useDemoWidgets: Bool {
        DemoWidgets.isForced && accountStore.accounts.isEmpty
    }

    private var widgets: [WidgetViewModel] {
        if useDemoWidgets { return DemoWidgets.make() }
        return orchestrator.widgets
    }

    private var showEmptyAdd: Bool {
        !useDemoWidgets && accountStore.accounts.isEmpty
    }

    /// Chevron + add rail whenever under the 5-account cap (demo empty-state only hides it).
    private var showAdd: Bool {
        !useDemoWidgets
            && accountStore.accounts.count < AccountStore.maxAccounts
    }

    private func handleHover(_ hovering: Bool) {
        pointerInside = hovering
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            expandOpen()
            // Key + activate so SwiftUI Menu / contextMenu can present.
            if !detailsOpen {
                NotificationCenter.default.post(name: .dashIslandRequestKey, object: nil)
            }
        } else if !blockingOverlay {
            scheduleCollapse()
        }
    }

    /// Expand drawing size (window stays put), then fade the shell in.
    private func expandOpen() {
        // Do NOT wrap setState in withAnimation — springs on `size` shift content.
        model.setState(.expanded)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
            showExpandedShell = true
        }
    }

    /// 1) Tuck expanded shell up (notch base stays put).
    /// 2) Snap drawing size to compact (window canvas unchanged).
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, !blockingOverlay, !pointerInside else { return }

            withAnimation(.easeIn(duration: 0.20)) {
                showExpandedShell = false
            }
            try? await Task.sleep(nanoseconds: collapseShellNs)
            guard !Task.isCancelled, !blockingOverlay, !pointerInside else { return }
            model.setState(.compact)
        }
    }

    /// While expanded, keep asking the orchestrator for a lazy refresh.
    ///
    /// This used to fire once per compact→expanded transition, so watching the
    /// island for twenty minutes produced exactly one refresh. The orchestrator
    /// still debounces every call by `expandInterval`, so the extra ticks cost
    /// nothing when nothing is due. Collapse cancels the task.
    private func scheduleExpandRefresh() {
        expandRefreshTask?.cancel()
        expandRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: expandRefreshDwellNs)
            while !Task.isCancelled, model.state == .expanded {
                orchestrator.onIslandExpanded()
                try? await Task.sleep(nanoseconds: expandRefreshRepeatNs)
            }
        }
    }
}
