import SwiftUI

/// Color tokens — aligned with the original island ring hues.
enum IslandColor {
    static let claude = Color(red: 204/255, green: 120/255, blue: 92/255)
    static let codex = Color(red: 90/255, green: 168/255, blue: 240/255)
    static let grok = Color(red: 167/255, green: 139/255, blue: 250/255)
    static let agy = Color(red: 66/255, green: 133/255, blue: 244/255)
    /// Live status dot.
    static let liveTeal = Color(red: 61/255, green: 214/255, blue: 140/255)
    /// Status text and marks. One value each, so a red caption, a red dot and a
    /// red banner match. (The rim and the burn needle keep hotter design hues.)
    static let critical = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let warning = Color(red: 0.95, green: 0.78, blue: 0.35)
    static let ok = liveTeal
}
