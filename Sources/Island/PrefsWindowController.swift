import AppKit
import SwiftUI

/// Standalone prefs panel. Never use SwiftUI `.sheet` on the island window —
/// AppKit repositions the parent to make room for sheets and drags the notch
/// HUD down the screen.
@MainActor
final class PrefsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PrefsWindowController()

    /// Observed by the island so it can stay expanded while prefs is open.
    private(set) var isOpen = false

    private let hosting: NSHostingController<PrefsSheet>

    private init() {
        let root = PrefsSheet(preferences: PreferencesStore.shared) {
            PrefsWindowController.shared.close()
        }
        hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "Preferences"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.isFloatingPanel = true
        // Island uses `.popUpMenu`. Floating is *below* that, so prefs opened
        // under the expanded HUD and looked empty. Sit clearly above the island.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Prevent AppKit from clipping tall content under a tiny content rect.
        panel.contentMinSize = NSSize(width: 340, height: 280)
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }

        // Rebuild root so display list is fresh.
        hosting.rootView = PrefsSheet(preferences: PreferencesStore.shared) {
            PrefsWindowController.shared.close()
        }
        hosting.view.layoutSubtreeIfNeeded()
        var fit = hosting.view.fittingSize
        if fit.width < 340 { fit.width = 340 }
        if fit.height < 280 { fit.height = 280 }
        // Cap absurd heights on many monitors.
        fit.height = min(fit.height, 640)
        window.setContentSize(fit)

        // Center on the *target* screen (or main), never under the notch band.
        let screen = DisplayInfo.currentScreen() ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            let size = window.frame.size
            let x = f.midX - size.width / 2
            let y = f.midY - size.height / 2 - 20
            window.setFrame(
                NSRect(x: x, y: y, width: size.width, height: size.height),
                display: true
            )
        } else {
            window.center()
        }

        isOpen = true
        NotificationCenter.default.post(name: .dashIslandPrefsOpenChanged, object: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    override func close() {
        isOpen = false
        NotificationCenter.default.post(name: .dashIslandPrefsOpenChanged, object: false)
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        NotificationCenter.default.post(name: .dashIslandPrefsOpenChanged, object: false)
    }
}

extension Notification.Name {
    static let dashIslandPrefsOpenChanged = Notification.Name("dashIslandPrefsOpenChanged")
    static let dashIslandRequestKey = Notification.Name("dashIslandRequestKey")
}
