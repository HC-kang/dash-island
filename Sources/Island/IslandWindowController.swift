import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class IslandWindowController {
    let window: NSWindow
    let model: IslandModel
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var sizeCancellable: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var spaceRevealTask: Task<Void, Never>?
    private var dragActiveObserver: NSObjectProtocol?
    private var requestKeyObserver: NSObjectProtocol?
    private var targetDisplayObserver: NSObjectProtocol?
    /// Occlusion + Low Power (default center) and display sleep (workspace center).
    private var motionObservers: [NSObjectProtocol] = []
    private var workspaceMotionObservers: [NSObjectProtocol] = []
    private var screensAsleep = false
    /// Last other app that was frontmost, and the app to hand focus back to
    /// when the island collapses after a click activated us.
    private var lastOtherApp: NSRunningApplication?
    private var focusReturnApp: NSRunningApplication?
    private var focusObservers: [NSObjectProtocol] = []
    private var workspaceFocusObserver: NSObjectProtocol?
    /// While true, the full window receives mouse events so drags aren't killed.
    private var dragActive = false
    private var pointerInside = false
    /// Follow-cursor hysteresis: candidate screen + pending switch task.
    private var followCandidateStableID: String?
    private var followCandidateTask: Task<Void, Never>?
    /// True while exit-up / enter-down hop is running.
    private var isFollowTransitioning = false
    /// Brief dwell so a bezel graze doesn't hop — keep short; hop animation covers the rest.
    private static let followHysteresisNs: UInt64 = 120_000_000
    private static let followExitDuration: TimeInterval = 0.14
    private static let followEnterDuration: TimeInterval = 0.18

    init() {
        let notch = NotchInfo.detect(from: DisplayInfo.currentScreen())
        model = IslandModel(notch: notch)
        Log.window.info(
            "notch width=\(notch.width) height=\(notch.height) hasNotch=\(notch.hasNotch) minX=\(notch.screenMinX.map { String(format: "%.1f", $0) } ?? "nil")"
        )

        window = BorderlessFloatingWindow(
            contentRect: NSRect(origin: .zero, size: model.canvasSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        // Not `canJoinAllSpaces` — that glues the island across Mission Control
        // swipes. Follow the active desktop; it slides away with the old space.
        window.collectionBehavior = [
            .moveToActiveSpace,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true
        window.alphaValue = 1

        let host = IslandHostingView(rootView: IslandRootView(model: model))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        window.contentView = host
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.masksToBounds = false

        // Window frame follows notch/canvas only — never compact↔expanded `size`.
        // (Resizing NSWindow on hover is what made the notch walk sideways.)
        sizeCancellable = model.$notch
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.isFollowTransitioning else { return }
                self.pinCanvas(animate: false)
            }
    }

    func show() {
        refreshNotchGeometry()
        pinCanvas(animate: false)
        window.alphaValue = 1
        window.orderFrontRegardless()
        observeScreenChanges()
        observeSpaceChanges()
        observeTargetDisplayChanges()
        observeDragActive()
        observeKeyRequests()
        observeMotionConditions()
        observeFocus()
        installMouseTracking()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = dragActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = requestKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = targetDisplayObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        motionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let observer = workspaceFocusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceMotionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        spaceRevealTask?.cancel()
        followCandidateTask?.cancel()
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
    }

    private func observeDragActive() {
        dragActiveObserver = NotificationCenter.default.addObserver(
            forName: .dashIslandDragActive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.dragActive = (note.object as? Bool) ?? false
                self?.updateMouseEventPassthrough()
            }
        }
    }

    private func observeKeyRequests() {
        requestKeyObserver = NotificationCenter.default.addObserver(
            forName: .dashIslandRequestKey,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Don't steal focus from prefs / dialog mid-edit.
                if PrefsWindowController.shared.isOpen { return }
                if IslandDialogController.shared.isOpen { return }
                if IslandDialogController.shared.isProgressOpen { return }
                // Accessory apps need a real activation for Menu / contextMenu to open.
                NSApp.activate(ignoringOtherApps: true)
                self?.window.makeKeyAndOrderFront(nil)
                self?.window.ignoresMouseEvents = false
            }
        }
    }

    /// Pause decoration nobody can see (occluded window, sleeping displays) and in Low Power Mode.
    private func observeMotionConditions() {
        let center = NotificationCenter.default
        motionObservers = [
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateWindowHidden() }
            },
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.model.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
                }
            }
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceMotionObservers = [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false)
        ].map { name, asleep in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screensAsleep = asleep
                    self?.updateWindowHidden()
                }
            }
        }
        updateWindowHidden()
    }

    private func updateWindowHidden() {
        model.setWindowHidden(screensAsleep || !window.occlusionState.contains(.visible))
    }

    /// Remember who had focus before we became active; give it back on pointer collapse.
    private func observeFocus() {
        let own = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            lastOtherApp = front
        }
        workspaceFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let app, app.processIdentifier != own else { return }
                self?.lastOtherApp = app
            }
        }
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.focusReturnApp = self?.lastOtherApp }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.focusReturnApp = nil }
            },
            center.addObserver(forName: .dashIslandPointerCollapsed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.returnFocus() }
            }
        ]
    }

    /// Collapse after a click left us active with no window of ours in use:
    /// the previous app gets keyboard focus back.
    private func returnFocus() {
        guard NSApp.isActive,
              NSApp.keyWindow == nil || NSApp.keyWindow === window,
              let app = focusReturnApp, !app.isTerminated
        else { return }
        focusReturnApp = nil
        app.activate(options: [])
        Log.window.debug("focus returned on collapse")
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNotchGeometry()
                self?.pinCanvas(animate: false)
            }
        }
    }

    private func observeTargetDisplayChanges() {
        targetDisplayObserver = NotificationCenter.default.addObserver(
            forName: .dashIslandTargetDisplayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTargetDisplayChanged()
            }
        }
    }

    private func handleTargetDisplayChanged() {
        // Follow-cursor hops: tuck up off the old screen, then drop onto the new one.
        // Sliding diagonally across the desktop feels noisy.
        if case .followCursor = TargetDisplayStore.shared.choice {
            transitionFollowCursorDisplay()
            return
        }
        refreshNotchGeometry()
        pinCanvas(animate: true)
    }

    /// Exit upward on the current monitor, reappear from above on the target.
    ///
    /// Important: do **not** collapse UI first — that fights the hop (size spring
    /// + frame animation). Exit with whatever frame is on screen, tuck compact
    /// only while off-screen, then drop in clean.
    private func transitionFollowCursorDisplay() {
        guard !isFollowTransitioning else { return }
        guard let targetScreen = DisplayInfo.currentScreen() else {
            refreshNotchGeometry()
            pinCanvas(animate: false)
            return
        }

        // Already sitting on the target display — just re-seat (no hop).
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        if targetScreen.frame.contains(center) {
            refreshNotchGeometry()
            pinCanvas(animate: true)
            return
        }

        isFollowTransitioning = true

        let from = window.frame
        let oldScreen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(from) }
        // Fully above the old screen top (AppKit y increases upward).
        let exitY = (oldScreen?.frame.maxY ?? from.maxY) + 2
        let exitRect = NSRect(x: from.origin.x, y: exitY, width: from.width, height: from.height)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.followExitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // One motion only: whole window slides up + fades. No layout morph.
            window.animator().setFrame(exitRect, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Off-screen: snap to compact so the re-entry is the small pill.
                self.model.setState(.compact)
                self.refreshNotchGeometry()
                let size = self.model.canvasSize
                guard let screen = DisplayInfo.currentScreen() else {
                    self.isFollowTransitioning = false
                    self.window.alphaValue = 1
                    self.pinCanvas(animate: false)
                    return
                }
                let x = self.model.notch.windowOriginX(windowWidth: size.width)
                let park = NSRect(
                    x: x,
                    y: screen.frame.maxY + 2,
                    width: size.width,
                    height: size.height
                )
                let seated = NSRect(
                    x: x,
                    y: screen.frame.maxY - size.height,
                    width: size.width,
                    height: size.height
                )
                self.window.setFrame(park, display: true)
                self.window.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Self.followEnterDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.window.animator().setFrame(seated, display: true)
                    self.window.animator().alphaValue = 1
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        self?.isFollowTransitioning = false
                        // Seat final canvas without a second spring fight.
                        self?.pinCanvas(animate: false)
                        self?.updateMouseEventPassthrough()
                    }
                })
            }
        })
    }

    /// Soft-hide when the user swipes desktops, then reappear compact on the new space.
    private func observeSpaceChanges() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleActiveSpaceDidChange()
            }
        }
    }

    private func handleActiveSpaceDidChange() {
        spaceRevealTask?.cancel()
        // Activating an app from the old space would swipe the user back there.
        focusReturnApp = nil

        // Drop expanded chrome immediately — never carry a wide panel across spaces.
        model.setState(.compact)

        // Fade out (notification fires when the switch settles; still softens the pop).
        // Two-arg form is synchronous (single-arg overload is async on newer SDKs).
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: nil)

        spaceRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }

            refreshNotchGeometry()
            pinCanvas(animate: false)
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    private func refreshNotchGeometry() {
        let screen = DisplayInfo.currentScreen()
        let next = NotchInfo.detect(from: screen)
        model.updateNotch(next)
        Log.window.info(
            "notch refresh width=\(next.width) height=\(next.height) minX=\(next.screenMinX.map { String(format: "%.1f", $0) } ?? "nil") screen=\(screen?.localizedName ?? "?")"
        )
    }

    /// Pin the fixed canvas window to the physical notch center.
    /// Never called for compact↔expanded — only screen/notch/display changes.
    private func pinCanvas(animate: Bool) {
        guard !isFollowTransitioning else { return }
        guard let screen = DisplayInfo.currentScreen() else { return }

        let size = model.canvasSize
        let top = screen.frame.maxY
        let midX = model.notch.anchoredCenterX
        let end = NSRect(
            x: midX - size.width * 0.5,
            y: top - size.height,
            width: size.width,
            height: size.height
        )

        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(end, display: true)
            }
        } else {
            window.setFrame(end, display: true)
        }
    }

    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.updateMouseEventPassthrough()
                self?.noteMouseMovedForFollowCursor()
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        }
        updateMouseEventPassthrough()
    }

    private func updateMouseEventPassthrough() {
        // Fully transparent during space handoff — never steal clicks mid-swipe.
        guard window.alphaValue > 0.05 else {
            window.ignoresMouseEvents = true
            return
        }
        // During widget drag the finger often leaves the black body (remove zone /
        // slot edges). If we ignore events there, DragGesture freezes.
        if dragActive {
            window.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let wf = window.frame
        // Black body only — never the full canvas / drag-bleed footprint.
        let hitSize = model.hitSize
        let hit = NSRect(
            x: wf.midX - hitSize.width * 0.5,
            y: wf.maxY - hitSize.height,
            width: hitSize.width,
            height: hitSize.height
        ).insetBy(dx: -1, dy: -1)
        let inside = hit.contains(mouse)
        // SwiftUI can miss mouseExited once the transparent window starts passing
        // events through. Use the same screen rect for both hover and passthrough.
        if inside != pointerInside {
            pointerInside = inside
            NotificationCenter.default.post(name: .dashIslandPointerInsideChanged, object: inside)
        }
        window.ignoresMouseEvents = !inside
    }

    // MARK: - Follow cursor display

    /// Cheap: only schedules work when the mouse is on a *different* display.
    private func noteMouseMovedForFollowCursor() {
        guard case .followCursor = TargetDisplayStore.shared.choice else {
            if followCandidateTask != nil {
                followCandidateTask?.cancel()
                followCandidateTask = nil
                followCandidateStableID = nil
            }
            return
        }
        // Don't thrash during space transitions, hops, or widget drags.
        guard window.alphaValue > 0.05, !dragActive, !isFollowTransitioning else { return }

        guard let under = DisplayInfo.infoContainingMouse() else { return }
        let live = TargetDisplayStore.shared.followLiveStableID
        if under.stableID == live {
            // Settled — clear any pending switch.
            if followCandidateStableID != nil {
                followCandidateTask?.cancel()
                followCandidateTask = nil
                followCandidateStableID = nil
            }
            return
        }

        // Already waiting on this candidate.
        if followCandidateStableID == under.stableID { return }

        followCandidateStableID = under.stableID
        followCandidateTask?.cancel()
        let candidateID = under.stableID
        followCandidateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.followHysteresisNs)
            guard let self, !Task.isCancelled else { return }
            guard case .followCursor = TargetDisplayStore.shared.choice else { return }
            // Mouse must still be on the candidate display.
            guard let still = DisplayInfo.infoContainingMouse(),
                  still.stableID == candidateID
            else {
                self.followCandidateStableID = nil
                return
            }
            TargetDisplayStore.shared.setFollowLive(stableID: still.stableID)
            self.followCandidateStableID = nil
            // `setFollowLive` posts target-display-changed → refresh + animate.
        }
    }
}

private final class IslandHostingView: NSHostingView<IslandRootView> {
    // Opening details makes another window key. Keep the next widget click
    // actionable instead of consuming it only to activate the island.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
