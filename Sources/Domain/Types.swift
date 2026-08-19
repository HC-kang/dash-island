import Foundation

/// Stable account identity (UUID).
typealias AccountID = UUID

/// Vendor key, e.g. `"claude"`, `"codex"`, `"grok"`, `"agy"`.
typealias VendorID = String

/// Opaque credential handle — directory name under Application Support accounts root.
typealias CredentialRef = String

/// Brand tint token for widget chrome (presentation maps to colors).
enum VendorTint: String, Equatable, Sendable {
    case claude
    case codex
    case grok
    case agy
    case neutral
}
