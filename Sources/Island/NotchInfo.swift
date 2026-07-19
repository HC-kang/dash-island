import AppKit

/// Physical / visual notch geometry for the target screen.
struct NotchInfo: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static let fallbackWidth: CGFloat = 200

    /// Prefer notched screen; then main.
    static func detectPreferred() -> NotchInfo {
        detect(from: preferredScreen())
    }

    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// `safeAreaInsets.top` = physical notch. Menu-bar visual height uses
    /// frame/visibleFrame (with 1pt correction) so the silhouette sits flush
    /// with the menu bar bottom — same rule as codex-island.
    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(width: fallbackWidth, height: 32, hasNotch: false)
        }
        let safeTop = screen.safeAreaInsets.top
        let visualHeight = menuBarHeight(
            safeTop: safeTop,
            visibleFrameDelta: screen.frame.maxY - screen.visibleFrame.maxY,
            statusBarThickness: NSStatusBar.system.thickness
        )

        if safeTop > 0 {
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            let width: CGFloat = (leftW > 0 && rightW > 0)
                ? screen.frame.width - leftW - rightW
                : fallbackWidth
            return NotchInfo(width: width, height: visualHeight, hasNotch: true)
        }
        return NotchInfo(width: fallbackWidth, height: visualHeight, hasNotch: false)
    }

    static func menuBarHeight(
        safeTop: CGFloat,
        visibleFrameDelta: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        let fromVisibleFrame = visibleFrameDelta - 1
        if fromVisibleFrame > 0 {
            return safeTop > 0 ? min(fromVisibleFrame, safeTop) : fromVisibleFrame
        }
        if safeTop > 0 { return safeTop }
        return statusBarThickness > 0 ? statusBarThickness : 24
    }
}
