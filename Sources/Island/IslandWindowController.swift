import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class IslandWindowController {
    let window: NSWindow
    let model: IslandModel
    private var screenChangeObserver: NSObjectProtocol?
    private var sizeCancellable: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init() {
        let notch = NotchInfo.detectPreferred()
        model = IslandModel(notch: notch)

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
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true

        let host = NSHostingView(rootView: IslandRootView(model: model))
        host.autoresizingMask = [.width, .height]
        // Tooltips paint into the transparent overflow under the black silhouette.
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
                self?.refreshNotchGeometry()
                self?.applySize(self?.model.size ?? .zero, animate: false)
            }
        }
    }

    private func refreshNotchGeometry() {
        model.updateNotch(NotchInfo.detect(from: NotchInfo.preferredScreen()))
    }

    private func applySize(_ size: CGSize, animate: Bool) {
        guard let screen = NotchInfo.preferredScreen() else { return }
        let frame = screen.frame
        // Flush to top of screen so the silhouette seats into the physical notch.
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
        let mouse = NSEvent.mouseLocation
        // Hit the black silhouette only (not the full transparent tooltip tail).
        let blackH = model.blackHeight
        let wf = window.frame
        let blackFrame = NSRect(
            x: wf.midX - silhouetteWidth / 2,
            y: wf.maxY - blackH,
            width: silhouetteWidth,
            height: blackH
        ).insetBy(dx: -3, dy: -2)
        window.ignoresMouseEvents = !blackFrame.contains(mouse)
    }

    private var silhouetteWidth: CGFloat {
        model.state == .compact ? model.notch.width : model.size.width
    }
}
