// Run against the built, running app: swift scripts/check-detail-clicks.swift 300 85
// Arguments locate a widget in island-window points. Keep the physical mouse still.
// Unlike accessibility clicks, CGEvents do not preactivate the target window.
import AppKit
import CoreGraphics

func fail(_ message: String, code: Int32 = 1) -> Never {
    print(message)
    exit(code)
}

guard CommandLine.arguments.count == 3,
      let localX = Double(CommandLine.arguments[1]),
      let localY = Double(CommandLine.arguments[2]),
      let app = NSWorkspace.shared.runningApplications.first(where: {
          $0.bundleIdentifier == "dev.dashisland.DashIsland"
      }) else { fail("Usage: swift scripts/check-detail-clicks.swift <widget-x> <widget-y>") }

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
}

func islandBounds() -> [String: Double] {
    guard let bounds = windows().compactMap({ $0[kCGWindowBounds as String] as? [String: Double] })
        .first(where: { $0["Width", default: 0] > 600 && $0["Height", default: 999] < 500 })
    else { fail("No visible island window") }
    return bounds
}

func detailIsOpen() -> Bool {
    windows().contains { ($0[kCGWindowName as String] as? String ?? "").hasSuffix(" usage") }
}

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else {
        fail("Cannot create mouse event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

let initial = islandBounds()
post(.mouseMoved, at: CGPoint(x: initial["X"]! + initial["Width"]! / 2, y: initial["Y"]! + 15))
Thread.sleep(forTimeInterval: 0.8) // Allow hover expansion and any display-follow animation.
let bounds = islandBounds()
let point = CGPoint(x: bounds["X"]! + localX, y: bounds["Y"]! + localY)
var open = detailIsOpen()
print("PID \(app.processIdentifier); initial details=\(open); focus=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown")")
for index in 1...4 {
    post(.mouseMoved, at: point)
    Thread.sleep(forTimeInterval: 0.04)
    post(.leftMouseDown, at: point)
    Thread.sleep(forTimeInterval: 0.03)
    post(.leftMouseUp, at: point)
    Thread.sleep(forTimeInterval: 0.3)
    guard let actual = CGEvent(source: nil)?.location,
          hypot(actual.x - point.x, actual.y - point.y) < 2 else {
        fail("INCONCLUSIVE: physical pointer moved during click \(index)", code: 3)
    }
    let next = detailIsOpen()
    print("Click \(index): details=\(next)")
    guard next != open else { fail("FAIL: click \(index) did not toggle details", code: 2) }
    open = next
}
print("PASS: four real clicks toggled details without preactivating the island")
