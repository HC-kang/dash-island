import SwiftUI

/// Compact type scale matching codex-island hierarchy (subset).
enum Typography {
    static let providerTitle = Font.system(size: 13, weight: .semibold)
    static let chip = Font.system(size: 9, weight: .bold, design: .monospaced)
    static let label = Font.system(size: 10, weight: .medium)
    static let bodyNumber = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let button = Font.system(size: 11, weight: .medium)
    static let settingsTitle = Font.system(size: 13, weight: .semibold)
    static let settingsSection = Font.system(size: 10, weight: .semibold)
    static let settingsRow = Font.system(size: 12, weight: .medium)
}

extension Locale {
    /// UI copy is English, so dates follow it instead of the system region
    /// (a Korean system showed "9월 24일" inside English sentences).
    static let ui = Locale(identifier: "en_US")
}
