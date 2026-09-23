import Foundation

enum IslandGeometrySuite {
    static func run() -> Int {
        print("IslandGeometry")
        var f = 0
        typealias G = IslandGeometry

        f += check("menu bar height: notch, plain, auto-hidden") {
            // Notch: visible-frame band capped by the safe area.
            try assertEqual(G.menuBarHeight(safeTop: 32, visibleFrameDelta: 38, statusBarThickness: 24), 32)
            // No notch: visible-frame band minus the 1pt separator.
            try assertEqual(G.menuBarHeight(safeTop: 0, visibleFrameDelta: 25, statusBarThickness: 24), 24)
            // Auto-hidden menu bar (delta 0): safe area, else status bar, else 24.
            try assertEqual(G.menuBarHeight(safeTop: 32, visibleFrameDelta: 0, statusBarThickness: 24), 32)
            try assertEqual(G.menuBarHeight(safeTop: 0, visibleFrameDelta: 0, statusBarThickness: 22), 22)
            try assertEqual(G.menuBarHeight(safeTop: 0, visibleFrameDelta: 0, statusBarThickness: 0), 24)
        }
        f += check("a pointer pushed against the top edge is on that display") {
            // AppKit reports y == maxY at the top edge; `CGRect.contains` drops it,
            // so follow-cursor found no display where the island sits.
            let lower = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let upper = CGRect(x: 0, y: 982, width: 1512, height: 982)
            try assertTrue(G.pointer(CGPoint(x: 700, y: 982), isOn: lower))
            try assertTrue(G.pointer(CGPoint(x: 700, y: 1964), isOn: upper))
            try assertTrue(!G.pointer(CGPoint(x: 700, y: 1965), isOn: upper))
            // A shared edge belongs to exactly one display.
            for p in [CGPoint(x: 700, y: 982), CGPoint(x: 700, y: 981.5)] {
                try assertTrue(G.pointer(p, isOn: lower) != G.pointer(p, isOn: upper))
            }
        }
        f += check("compact: notch pill with rim pad and 80pt floor") {
            try assertEqual(G.compactSize(notchWidth: 185, notchHeight: 32, hasNotch: true), CGSize(width: 191, height: 35))
            try assertEqual(G.compactSize(notchWidth: 40, notchHeight: 32, hasNotch: true).width, 80)
        }
        f += check("compact on a non-notch display keeps the same visible pill as a notch") {
            try assertEqual(G.compactSize(notchWidth: 180, notchHeight: 29, hasNotch: false),
                            G.compactSize(notchWidth: 180, notchHeight: 29, hasNotch: true))
        }
        f += check("hit: compact equals the drawn pill; hidden compact has none") {
            let pill = G.compactSize(notchWidth: 185, notchHeight: 32, hasNotch: true)
            try assertEqual(G.hitSize(expanded: false, compactHidden: false, compact: pill, bodyWidth: 400, notchHeight: 32), pill)
            try assertEqual(G.hitSize(expanded: false, compactHidden: true, compact: pill, bodyWidth: 400, notchHeight: 32), .zero)
        }
        f += check("hit: expanded is the black body plus a tip strip, never drag bleed") {
            let body = G.expandedWidth(notchWidth: 185, itemCount: 3, canAdd: true, addRailOpen: false)
            let pill = G.compactSize(notchWidth: 185, notchHeight: 32, hasNotch: true)
            let hit = G.hitSize(expanded: true, compactHidden: true, compact: pill, bodyWidth: body, notchHeight: 32)
            try assertEqual(hit.width, body)
            try assertEqual(hit.height, 32 + G.expandedContentHeight + G.expandedHitPad)
            let drawn = G.expandedSize(bodyWidth: body, notchHeight: 32)
            try assertTrue(hit.width < drawn.width && hit.height < drawn.height)
        }
        f += check("canvas holds every expanded footprint, and is exactly the widest one") {
            let canvas = G.canvasSize(notchWidth: 185, notchHeight: 32)
            for n in 0...20 {
                for canAdd in [false, true] {
                    for rail in [false, true] {
                        let body = G.expandedWidth(notchWidth: 185, itemCount: n, canAdd: canAdd, addRailOpen: rail)
                        let drawn = G.expandedSize(bodyWidth: body, notchHeight: 32)
                        try assertTrue(drawn.width <= canvas.width && drawn.height <= canvas.height,
                                       "n=\(n) add=\(canAdd) rail=\(rail) \(drawn) > \(canvas)")
                    }
                }
            }
            let widest = G.expandedWidth(notchWidth: 185, itemCount: G.maxVisibleSlots, canAdd: true, addRailOpen: true)
            try assertEqual(canvas, G.expandedSize(bodyWidth: widest, notchHeight: 32))
        }
        f += check("full screen: a window covering the whole display, in CG coordinates") {
            let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            try assertTrue(G.hasFullScreenWindow(screenFrame: primary, primaryScreenHeight: 1080,
                                                 windowBounds: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]))
            // Zoomed window under the menu bar is not full screen.
            try assertTrue(!G.hasFullScreenWindow(screenFrame: primary, primaryScreenHeight: 1080,
                                                  windowBounds: [CGRect(x: 0, y: 25, width: 1920, height: 1055)]))
            // Secondary display to the right and higher: Cocoa y-up vs CG y-down.
            let side = CGRect(x: 1920, y: 200, width: 2560, height: 1440)
            try assertTrue(G.hasFullScreenWindow(screenFrame: side, primaryScreenHeight: 1080,
                                                 windowBounds: [CGRect(x: 1920, y: -560, width: 2560, height: 1440)]))
            try assertTrue(!G.hasFullScreenWindow(screenFrame: side, primaryScreenHeight: 1080,
                                                  windowBounds: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]))
        }
        return f
    }
}
