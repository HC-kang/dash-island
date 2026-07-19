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

    private init() {
        let root = PrefsSheet(preferences: PreferencesStore.shared) {
            PrefsWindowController.shared.close()
        }
        let host = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
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
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        // Center in the visible frame — never tuck under the notch island.
        if let screen = NotchInfo.preferredScreen() {
            let f = screen.visibleFrame
            let size = window.frame.size
            let x = f.midX - size.width / 2
            let y = f.midY - size.height / 2
            window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
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
