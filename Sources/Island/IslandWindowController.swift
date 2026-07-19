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

    init() {
        let notch = NotchInfo.detectPreferred()
        model = IslandModel(notch: notch)
        NSLog(
            "DashIsland: notch width=%.1f height=%.1f hasNotch=%@ minX=%@",
            notch.width,
            notch.height,
            notch.hasNotch ? "yes" : "no",
            notch.screenMinX.map { String(format: "%.1f", $0) } ?? "nil"
        )

        window = BorderlessFloatingWindow(
            contentRect: NSRect(origin: .zero, size: model.size),
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

        let host = NSHostingView(rootView: IslandRootView(model: model))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        window.contentView = host
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.masksToBounds = false

        sizeCancellable = model.$size
            .removeDuplicates { $0.width == $1.width && $0.height == $1.height }
            .sink { [weak self] size in
                self?.applySize(size, animate: true)
            }
    }

    func show() {
        refreshNotchGeometry()
        applySize(model.size, animate: false)
        window.alphaValue = 1
        window.orderFrontRegardless()
        observeScreenChanges()
        observeSpaceChanges()
        installMouseTracking()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        spaceRevealTask?.cancel()
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNotchGeometry()
                self?.applySize(self?.model.size ?? .zero, animate: false)
            }
        }
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

        // Drop expanded chrome immediately — never carry a wide panel across spaces.
        model.setState(.compact)

        // Fade out (notification fires when the switch settles; still softens the pop).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }

        spaceRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }

            refreshNotchGeometry()
            applySize(model.size, animate: false)
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    private func refreshNotchGeometry() {
        let next = NotchInfo.detect(from: NotchInfo.preferredScreen())
        model.updateNotch(next)
        NSLog(
            "DashIsland: notch refresh width=%.1f height=%.1f minX=%@",
            next.width,
            next.height,
            next.screenMinX.map { String(format: "%.1f", $0) } ?? "nil"
        )
    }

    private func applySize(_ size: CGSize, animate: Bool) {
        guard let screen = NotchInfo.preferredScreen() else { return }
        let x = model.notch.windowOriginX(windowWidth: size.width)
        let y = screen.frame.maxY - size.height
        let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(rect, display: true)
            }
        } else {
            window.setFrame(rect, display: true)
        }
    }

    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.updateMouseEventPassthrough() }
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
        let mouse = NSEvent.mouseLocation
        let wf = window.frame
        let hitW = model.state == .compact ? model.notch.width + 6 : model.size.width
        let hitH = model.blackHeight + (model.state == .compact ? 3 : 0)
        let hit = NSRect(
            x: wf.midX - hitW / 2,
            y: wf.maxY - hitH,
            width: hitW,
            height: hitH
        ).insetBy(dx: -2, dy: -2)
        window.ignoresMouseEvents = !hit.contains(mouse)
    }
}
