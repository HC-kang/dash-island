// E2E pointer driver for the running Dash Island app. Coordinates for move/click
// are relative to the island window's top-left; warp takes global points.
// Usage: drive info | hover | away | move X Y | click X Y | rclick X Y |
//        scroll DY | shot NAME [island|detail|screen] | warp X Y | wiggle v|h
import AppKit

let shotsDir = ProcessInfo.processInfo.environment["E2E_SHOTS"] ?? NSTemporaryDirectory() + "dash-e2e-shots"

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
/// Owner name is the localized display name ("Dash Island"), so match the PID.
let dashPID = NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == "DashIsland" }
    .map { Int($0.processIdentifier) }
func windows() -> [[String: Any]] {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.filter { ($0[kCGWindowOwnerPID as String] as? Int32).map { Int($0) } == dashPID }
}
func rect(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
}
func island() -> CGRect {
    guard let w = windows().first(where: { rect($0).width > 600 && rect($0).height < 600 }) else { fail("no island window") }
    return rect(w)
}
/// The detail panel is the 400 pt wide DashIsland window.
func detail() -> CGRect? { windows().map(rect).first { abs($0.width - 400) < 1 && $0.height > 200 } }
func post(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.post(tap: .cghidEventTap)
}
func local(_ x: Double, _ y: Double) -> CGPoint { let r = island(); return CGPoint(x: r.minX + x, y: r.minY + y) }
func shot(_ name: String, _ r: CGRect) {
    try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", "\(shotsDir)/\(name).png"]
    try? p.run(); p.waitUntilExit()
    print("\(shotsDir)/\(name).png")
}

let a = Array(CommandLine.arguments.dropFirst())
switch a.first ?? "info" {
case "info":
    for w in windows() { print(rect(w), w[kCGWindowName as String] ?? "", "layer", w[kCGWindowLayer as String] ?? "") }
    print("pointer:", CGEvent(source: nil)!.location)
case "hover":
    let r = island(); post(.mouseMoved, CGPoint(x: r.midX, y: r.minY + 12)); Thread.sleep(forTimeInterval: 0.9)
case "away":
    let r = island(); post(.mouseMoved, CGPoint(x: r.midX, y: r.maxY + 300)); Thread.sleep(forTimeInterval: 0.9)
case "move":
    post(.mouseMoved, local(Double(a[1])!, Double(a[2])!)); Thread.sleep(forTimeInterval: 0.6)
case "click", "rclick":
    let p = local(Double(a[1])!, Double(a[2])!); let right = a[0] == "rclick"
    post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.25)
    post(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left); Thread.sleep(forTimeInterval: 0.04)
    post(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left); Thread.sleep(forTimeInterval: 0.6)
    print("clicked", p, "detail:", detail().map { "\($0)" } ?? "closed")
case "scroll":
    let r = detail() ?? island(); post(.mouseMoved, CGPoint(x: r.midX, y: r.midY))
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(a[1])!, wheel2: 0, wheel3: 0)!
    e.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.5)
case "shot":
    let r: CGRect
    switch a.count > 2 ? a[2] : "island" {
    case "detail": guard let d = detail() else { fail("detail closed") }; r = d
    case "screen": r = NSScreen.screens.first.map { CGRect(x: 0, y: 0, width: $0.frame.width, height: 300) }!
    default: let i = island(); r = CGRect(x: i.minX + 180, y: i.minY, width: i.width - 360, height: 260)
    }
    shot(a[1], r)
case "warp":
    CGWarpMouseCursorPosition(CGPoint(x: Double(a[1])!, y: Double(a[2])!)); CGAssociateMouseAndMouseCursorPosition(1)
case "wiggle":
    // Vertical marks the start of a control session, horizontal its end.
    let o = CGEvent(source: nil)!.location; let vertical = a[1] == "v"
    for i in 0..<10 {
        let d: CGFloat = i % 2 == 0 ? 14 : -14
        CGWarpMouseCursorPosition(vertical ? CGPoint(x: o.x, y: o.y + d) : CGPoint(x: o.x + d, y: o.y)); Thread.sleep(forTimeInterval: 0.05)
    }
    CGWarpMouseCursorPosition(o); CGAssociateMouseAndMouseCursorPosition(1)
default: fail("unknown command")
}
