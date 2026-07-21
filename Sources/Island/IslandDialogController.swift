import AppKit
import SwiftUI

/// Dark modal panel for rename / confirm / alerts.
/// Same level strategy as prefs — sits above the island, never a sheet on it.
@MainActor
final class IslandDialogController: NSWindowController, NSWindowDelegate {
    static let shared = IslandDialogController()

    private(set) var isOpen = false
    /// Non-modal login wait (does not use runModal).
    private(set) var isProgressOpen = false

    private enum Outcome {
        case cancelled
        case confirmed
        case text(String)
    }

    private var outcome: Outcome = .cancelled
    private var progressCancel: (() -> Void)?
    private var progressPanel: NSPanel?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Dash Island"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Blocking text prompt. Returns `nil` if cancelled.
    @discardableResult
    func runTextPrompt(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        vendorID: VendorID? = nil
    ) -> String? {
        let view = IslandTextPromptView(
            title: title,
            message: message,
            defaultValue: defaultValue,
            confirmTitle: confirmTitle,
            vendorID: vendorID,
            onConfirm: { [weak self] text in
                self?.finish(.text(text))
            },
            onCancel: { [weak self] in
                self?.finish(.cancelled)
            }
        )
        present(view, height: vendorID == nil ? 210 : 236)
        switch outcome {
        case .text(let s): return s
        default: return nil
        }
    }

    /// Blocking confirm. Returns whether the user confirmed.
    @discardableResult
    func runConfirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        showCancel: Bool = true
    ) -> Bool {
        let view = IslandConfirmView(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            showCancel: showCancel,
            onConfirm: { [weak self] in self?.finish(.confirmed) },
            onCancel: { [weak self] in self?.finish(.cancelled) }
        )
        present(view, height: 168)
        if case .confirmed = outcome { return true }
        return false
    }

    /// Non-modal progress while CLI login runs. Cancel invokes `onCancel` once.
    func showProgress(
        title: String,
        message: String,
        vendorID: VendorID? = nil,
        onCancel: @escaping () -> Void
    ) {
        hideProgress()
        progressCancel = onCancel

        let view = IslandProgressView(
            title: title,
            message: message,
            vendorID: vendorID,
            onCancel: { [weak self] in
                let cb = self?.progressCancel
                self?.progressCancel = nil
                self?.hideProgress()
                cb?()
            }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 320, height: vendorID == nil ? 180 : 200))

        if let screen = NotchInfo.preferredScreen() {
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrame(
                NSRect(
                    x: f.midX - size.width / 2,
                    y: f.midY - size.height / 2 + 40,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        } else {
            panel.center()
        }

        progressPanel = panel
        isProgressOpen = true
        NotificationCenter.default.post(name: .dashIslandDialogOpenChanged, object: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hideProgress() {
        progressPanel?.orderOut(nil)
        progressPanel?.contentViewController = nil
        progressPanel = nil
        progressCancel = nil
        if isProgressOpen {
            isProgressOpen = false
            if !isOpen {
                NotificationCenter.default.post(name: .dashIslandDialogOpenChanged, object: false)
            }
        }
    }

    // MARK: - Presentation

    private func present<V: View>(_ view: V, height: CGFloat) {
        hideProgress()
        guard let panel = window as? NSPanel else { return }
        outcome = .cancelled

        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        panel.contentViewController = host

        let width: CGFloat = 320
        panel.setContentSize(NSSize(width: width, height: height))

        NSApp.activate(ignoringOtherApps: true)
        if let screen = NotchInfo.preferredScreen() {
            let f = screen.visibleFrame
            let size = panel.frame.size
            let x = f.midX - size.width / 2
            let y = f.midY - size.height / 2 + 20
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        } else {
            panel.center()
        }

        isOpen = true
        NotificationCenter.default.post(name: .dashIslandDialogOpenChanged, object: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Modal session — returns when finish() calls stopModal.
        NSApp.runModal(for: panel)

        panel.orderOut(nil)
        panel.contentViewController = nil
        isOpen = false
        NotificationCenter.default.post(name: .dashIslandDialogOpenChanged, object: false)
    }

    private func finish(_ outcome: Outcome) {
        self.outcome = outcome
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        if isOpen {
            finish(.cancelled)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isOpen {
            finish(.cancelled)
            return false
        }
        return true
    }
}

extension Notification.Name {
    static let dashIslandDialogOpenChanged = Notification.Name("dashIslandDialogOpenChanged")
}
