import AppKit
import SwiftUI

@MainActor
final class IslandWindowController {
    let window: NSWindow
    private var screenChangeObserver: NSObjectProtocol?

    /// Wide enough for 5×100px widgets + gaps + horizontal padding; tall enough for
    /// gauge cells + hover tooltips hanging below.
    static let windowSize = CGSize(width: 600, height: 200)

    init() {
        window = BorderlessFloatingWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
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
        // Floating accessory windows are rarely key; still need hover for tooltips.
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false

        let host = NSHostingView(rootView: IslandRootView())
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    func show() {
        repositionForCurrentScreen()
        window.orderFrontRegardless()
        observeScreenChanges()
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionForCurrentScreen() }
        }
    }

    /// Prefer a notched display (`safeAreaInsets.top > 0`); fall back to main.
    private static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func repositionForCurrentScreen() {
        guard let screen = Self.preferredScreen() else { return }
        let size = Self.windowSize
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
