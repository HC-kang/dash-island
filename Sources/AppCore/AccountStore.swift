import Combine
import Foundation

enum AccountStoreError: Error, Equatable {
    /// Cap is 5 accounts (one widget each).
    case maxAccountsReached
}

/// Loaded account list + add/remove. Caps at `maxAccounts`.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    static let maxAccounts = 5

    @Published private(set) var accounts: [Account] = []

    private let persistence: AccountsPersistence

    init(persistence: AccountsPersistence = .live) {
        self.persistence = persistence
    }

    /// Load from disk (call on launch). Missing/corrupt file → empty list.
    func load() {
        do {
            accounts = try persistence.load().sorted { $0.sortIndex < $1.sortIndex }
        } catch {
            accounts = []
        }
    }

    /// Append a fully formed account. Rejects when already at cap.
    func add(_ account: Account) throws {
        guard accounts.count < Self.maxAccounts else {
            throw AccountStoreError.maxAccountsReached
        }
        var copy = account
        copy.sortIndex = accounts.count
        accounts.append(copy)
        try persist()
    }

    /// Create metadata from an adapter `beginAdd` result. Account `id` matches folder UUID when possible.
    @discardableResult
    func add(from result: AddAccountResult) throws -> Account {
        guard accounts.count < Self.maxAccounts else {
            throw AccountStoreError.maxAccountsReached
        }
        let id = UUID(uuidString: result.credentialRef) ?? UUID()
        let account = Account(
            id: id,
            vendorID: result.vendorID,
            label: result.label,
            credentialRef: result.credentialRef,
            sortIndex: accounts.count,
            createdAt: Date(),
            lastAuthenticatedAt: Date()
        )
        accounts.append(account)
        try persist()
        return account
    }

    /// Remove metadata row and credential folder.
    func remove(id: AccountID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let removed = accounts.remove(at: index)
        try? CredentialStore.removeDirectory(for: removed.credentialRef)
        reindex()
        try persist()
    }

    func rename(id: AccountID, label: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = label
        try persist()
    }

    /// Move `id` so it ends at `toIndex` in the final array (0-based).
    func move(id: AccountID, toIndex: Int) throws {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, toIndex), accounts.count - 1)
        guard from != target else { return }
        var list = accounts
        let item = list.remove(at: from)
        list.insert(item, at: target)
        accounts = list
        reindex()
        try persist()
    }

    /// Replace order with an explicit id list (drag commit). Unknown ids ignored.
    func applyOrder(_ ids: [AccountID]) throws {
        let map = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var next: [Account] = []
        next.reserveCapacity(accounts.count)
        for id in ids {
            if let account = map[id] { next.append(account) }
        }
        // Append any that were missing from ids (safety).
        for account in accounts where !ids.contains(account.id) {
            next.append(account)
        }
        guard next.map(\.id) != accounts.map(\.id) else { return }
        accounts = next
        reindex()
        try persist()
    }

    /// After adapter `reauthenticate`, stamp auth time and optionally replace credential ref.
    func markAuthenticated(id: AccountID, credentialRef: CredentialRef? = nil) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastAuthenticatedAt = Date()
        if let credentialRef {
            accounts[index].credentialRef = credentialRef
        }
        try persist()
    }

    // MARK: - Private

    private func reindex() {
        for i in accounts.indices {
            accounts[i].sortIndex = i
        }
    }

    private func persist() throws {
        try persistence.save(accounts)
    }
}
