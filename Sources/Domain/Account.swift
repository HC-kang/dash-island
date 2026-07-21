import Foundation

struct Account: Identifiable, Equatable, Codable, Sendable {
    let id: AccountID
    var vendorID: VendorID
    var label: String
    var credentialRef: CredentialRef
    var sortIndex: Int
    var createdAt: Date
    var lastAuthenticatedAt: Date?
}
