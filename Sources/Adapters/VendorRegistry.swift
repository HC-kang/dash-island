import Foundation

/// In-process map of vendor adapters. Layout is unchanged when a vendor ships later.
enum VendorRegistry {
    /// Product vendors shown in Add menus (never includes Fake).
    static let all: [any VendorAdapter] = [
        ClaudeAdapter(),
        CodexAdapter(),
        GrokAdapter(),
    ]

    /// Full set including Fake — for tests / `adapter(for:)` only.
    static let allIncludingDev: [any VendorAdapter] = [
        FakeAdapter(),
    ] + all

    static func adapter(for id: VendorID) -> (any VendorAdapter)? {
        allIncludingDev.first { $0.id == id }
    }
}
