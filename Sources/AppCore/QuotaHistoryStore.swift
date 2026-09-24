import Foundation

/// Keeps `QuotaHistory` per account in Application Support/DashIsland/quota-history
/// (folder 0700, files 0600) and feeds the detail panel's 7-day trend.
@MainActor
final class QuotaHistoryStore: ObservableObject {
    static let shared = QuotaHistoryStore()

    private let directory: URL
    @Published private(set) var byAccount: [AccountID: QuotaHistory] = [:]

    init(directory: URL = CredentialStore.appSupportURL.appendingPathComponent("quota-history")) {
        self.directory = directory
    }

    func history(for id: AccountID) -> QuotaHistory {
        if let cached = byAccount[id] { return cached }
        let loaded = (try? Data(contentsOf: file(id)))
            .flatMap { try? JSONDecoder().decode(QuotaHistory.self, from: $0) } ?? QuotaHistory()
        byAccount[id] = loaded
        return loaded
    }

    /// Record the account's own windows (not model-scoped extras) from a clean poll.
    func record(accountID: AccountID, snapshot: UsageSnapshot, at: Date) {
        var h = history(for: accountID)
        for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) where window.isReported {
            h.record(window: window.displayLabel, used: window.usedFraction, at: at)
        }
        byAccount[accountID] = h
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(h).write(to: file(accountID), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(accountID).path)
        } catch {
            Log.accounts.warn("quota history write failed account=\(accountID.short)")
        }
    }

    func remove(accountID: AccountID) {
        byAccount[accountID] = nil
        try? FileManager.default.removeItem(at: file(accountID))
    }

    private func file(_ id: AccountID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
