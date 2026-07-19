import Foundation

/// In-process map of vendor adapters. Layout is unchanged when a vendor ships later.
enum VendorRegistry {
    static let all: [any VendorAdapter] = [
        FakeAdapter(),
        ClaudeAdapter(),
    ]

    static func adapter(for id: VendorID) -> (any VendorAdapter)? {
        all.first { $0.id == id }
    }
}
