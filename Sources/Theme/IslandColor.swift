import SwiftUI

/// Color tokens — vendor product accents (not invented palette).
enum IslandColor {
    /// Anthropic Book Cloth
    static let claude = Color(red: 204/255, green: 120/255, blue: 92/255)
    /// OpenAI Teal (Blossom is officially mono; this is the product accent)
    static let codex = Color(red: 16/255, green: 163/255, blue: 127/255)
    /// xAI mark is black/white; keep a visible ring hue on dark chrome
    static let grok = Color(red: 232/255, green: 232/255, blue: 237/255)
    /// Google Blue — dominant leg of the official Antigravity A
    static let agy = Color(red: 66/255, green: 133/255, blue: 244/255)
    /// Live status dot.
    static let liveTeal = Color(red: 61/255, green: 214/255, blue: 140/255)
}
