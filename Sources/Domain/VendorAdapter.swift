import Foundation

/// Result of an interactive add-account flow for a vendor.
struct AddAccountResult: Equatable, Sendable {
    var vendorID: VendorID
    var label: String
    var credentialRef: CredentialRef
}

/// In-process vendor integration. Domain has no URLSession; adapters own HTTP.
protocol VendorAdapter: Sendable {
    var id: VendorID { get }
    var displayName: String { get }
    var minPollSeconds: Int { get }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot
    func beginAdd() async throws -> AddAccountResult
    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef
}
