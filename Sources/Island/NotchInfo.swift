import AppKit

/// Physical / visual notch geometry for the target screen.
///
/// Width comes from the gap between `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea` (`right.minX - left.maxX`) — not a guessed constant.
/// Height matches the menu-bar visual band (codex-island rule).
struct NotchInfo: Equatable {
    /// Obstructed strip width (camera / notch), points.
    let width: CGFloat
    /// Menu-bar / notch band height, points.
    let height: CGFloat
    let hasNotch: Bool
    /// Global AppKit X of the notch’s leading edge (`left.maxX`).
    /// When unknown, treat as centered via `screenMidX - width/2`.
    let screenMinX: CGFloat?
    /// Owning screen’s `frame.midX` (for fallback centering).
    let screenMidX: CGFloat

    static let fallbackWidth: CGFloat = 180

    static func detectPreferred() -> NotchInfo {
        detect(from: preferredScreen())
    }

    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(
                width: fallbackWidth,
                height: 32,
                hasNotch: false,
                screenMinX: nil,
                screenMidX: 0
            )
        }

        let safeTop = screen.safeAreaInsets.top
        let visualHeight = menuBarHeight(
            safeTop: safeTop,
            visibleFrameDelta: screen.frame.maxY - screen.visibleFrame.maxY,
            statusBarThickness: NSStatusBar.system.thickness
        )
        let midX = screen.frame.midX

        if safeTop > 0 {
            let left = screen.auxiliaryTopLeftArea
            let right = screen.auxiliaryTopRightArea
            if let left, let right, right.minX > left.maxX {
                let width = right.minX - left.maxX
                return NotchInfo(
                    width: width,
                    height: visualHeight,
                    hasNotch: true,
                    screenMinX: left.maxX,
                    screenMidX: midX
                )
            }
            // Aux areas missing (rare) — centered fallback.
            return NotchInfo(
                width: fallbackWidth,
                height: visualHeight,
                hasNotch: true,
                screenMinX: midX - fallbackWidth / 2,
                screenMidX: midX
            )
        }

        return NotchInfo(
            width: fallbackWidth,
            height: visualHeight,
            hasNotch: false,
            screenMinX: midX - fallbackWidth / 2,
            screenMidX: midX
        )
    }

    /// Window origin X so the notch fill’s leading edge lands on `screenMinX`.
    func windowOriginX(windowWidth: CGFloat) -> CGFloat {
        if let minX = screenMinX {
            // Center the (possibly padded) window on the real notch strip.
            return minX - (windowWidth - width) / 2
        }
        return screenMidX - windowWidth / 2
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
