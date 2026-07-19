import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class IslandWindowController {
    let window: NSWindow
    let model = IslandModel()
    private var screenChangeObserver: NSObjectProtocol?
    private var sizeCancellable: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init() {
        window = BorderlessFloatingWindow(
            contentRect: NSRect(origin: .zero, size: IslandModel.compactSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        // Start click-through; enable hits only when cursor is over the island.
        window.ignoresMouseEvents = true

        let host = NSHostingView(rootView: IslandRootView(model: model))
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        sizeCancellable = model.$size
            .removeDuplicates { $0.width == $1.width && $0.height == $1.height }
            .sink { [weak self] size in
                self?.applySize(size, animate: true)
            }
    }

    func show() {
        applySize(model.size, animate: false)
        window.orderFrontRegardless()
        observeScreenChanges()
        installMouseTracking()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
                guard let self else { return }
                self.applySize(self.model.size, animate: false)
            }
        }
    }

    /// Prefer a notched display; fall back to main.
    private static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func applySize(_ size: CGSize, animate: Bool) {
        guard let screen = Self.preferredScreen() else { return }
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
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

    /// Click-through outside the island; re-enable hits when cursor is over window content.
    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.updateMouseEventPassthrough()
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
        let mouse = NSEvent.mouseLocation
        // Slightly generous hit pad so the compact pill is easy to catch.
        let hit = window.frame.insetBy(dx: -4, dy: -4)
        let inside = hit.contains(mouse)
        window.ignoresMouseEvents = !inside
    }
}
