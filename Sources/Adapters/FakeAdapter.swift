import Foundation

/// Offline-friendly adapter for UI development and tests.
///
/// - `beginAdd` creates `accounts/<uuid>/` + a dummy `token` file.
/// - `fetchUsage` returns a deterministic used-fraction derived from `hash(ref)`.
struct FakeAdapter: VendorAdapter {
    let id: VendorID = "fake"
    let displayName = "Fake"
    let minPollSeconds = 300

    func beginAdd() async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        let dir = try CredentialStore.createDirectory(for: ref)
        let tokenURL = dir.appendingPathComponent("token", isDirectory: false)
        try Data("fake-token".utf8).write(to: tokenURL, options: .atomic)
        let short = String(ref.prefix(8))
        return AddAccountResult(
            vendorID: id,
            label: "Fake \(short)",
            credentialRef: ref
        )
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let primary = Self.fraction(from: ref)
        let secondary = Self.fraction(from: ref + ":weekly")
        let now = Date()
        return UsageSnapshot(
            primary: WindowUsage(
                usedFraction: primary,
                resetAt: now.addingTimeInterval(5 * 3600),
                usedTokens: Int64((primary * 100_000).rounded()),
                limitTokens: 100_000
            ),
            secondary: WindowUsage(
                usedFraction: secondary,
                resetAt: now.addingTimeInterval(7 * 24 * 3600),
                usedTokens: nil,
                limitTokens: nil
            ),
            plan: "fake-pro",
            fetchedAt: now,
            error: nil
        )
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        let tokenURL = dir.appendingPathComponent("token", isDirectory: false)
        try Data("fake-token-reauth".utf8).write(to: tokenURL, options: .atomic)
        return ref
    }

    /// Stable FNV-1a style fraction in `0..<1` from an opaque string.
    static func fraction(from seed: String) -> Double {
        var hash: UInt64 = 2_166_136_261
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 1_000) / 1_000.0
    }
}
