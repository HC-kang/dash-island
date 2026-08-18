import Combine
import Foundation

enum AccountStoreError: Error, Equatable {
    /// Cap is `maxAccounts` (island shows `maxVisibleSlots` at once, rest scroll).
    case maxAccountsReached
}

/// Loaded account list + add/remove. Caps at `maxAccounts`.
///
/// Metadata: `~/Library/Application Support/DashIsland/accounts.json`
/// Credentials: `~/Library/Application Support/DashIsland/accounts/<uuid>/`
/// Both live outside the app bundle — rebuilds must never wipe them.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    /// Keep in lockstep with `IslandModel.maxItems` (8; viewport scrolls past 5).
    static let maxAccounts = 8

    @Published private(set) var accounts: [Account] = []

    private let persistence: AccountsPersistence

    init(persistence: AccountsPersistence = .live) {
        self.persistence = persistence
    }

    /// Load from disk (call on launch). Rehydrates orphan credential folders when possible.
    func load() {
        let path = persistence.fileURL.path
        do {
            var loaded = try persistence.load().sorted { $0.sortIndex < $1.sortIndex }
            // Only scan the live Application Support tree when this store owns it.
            // (Unit tests use temp `accounts.json` paths — never pull real orphans in.)
            if isLivePersistence {
                let recovered = recoverOrphans(existing: loaded)
                if !recovered.isEmpty {
                    loaded.append(contentsOf: recovered)
                    if loaded.count > Self.maxAccounts {
                        loaded = Array(loaded.prefix(Self.maxAccounts))
                    }
                    reindex(&loaded)
                    accounts = loaded
                    try? persistence.save(accounts)
                    NSLog(
                        "DashIsland: recovered %d orphan credential folder(s) → accounts.json",
                        recovered.count
                    )
                } else {
                    accounts = loaded
                }
            } else {
                accounts = loaded
            }
            NSLog(
                "DashIsland: loaded %d account(s) from %@",
                accounts.count,
                path
            )
        } catch {
            // Corrupt list: keep empty in-memory but do **not** overwrite the file.
            accounts = []
            NSLog(
                "DashIsland: failed to load accounts.json (%@) — left file intact at %@",
                String(describing: error),
                path
            )
            if isLivePersistence {
                let recovered = recoverOrphans(existing: [])
                if !recovered.isEmpty {
                    var loaded = recovered
                    if loaded.count > Self.maxAccounts {
                        loaded = Array(loaded.prefix(Self.maxAccounts))
                    }
                    reindex(&loaded)
                    accounts = loaded
                    try? persistence.save(accounts)
                    NSLog("DashIsland: rebuilt accounts.json from %d credential folder(s)", accounts.count)
                }
            }
        }
    }

    /// True when persistence points at the real Application Support accounts.json.
    private var isLivePersistence: Bool {
        persistence.fileURL.standardizedFileURL
            == CredentialStore.accountsFileURL.standardizedFileURL
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
        let dir = CredentialStore.directoryURL(for: removed.credentialRef)
        switch removed.vendorID {
        case "claude":
            ClaudeAdapter.clearManagedCredentials(configDir: dir)
        case "codex":
            CodexAdapter.clearManagedCredentials(codexHome: dir)
        case "grok":
            GrokAdapter.clearManagedCredentials(grokHome: dir)
        case "gemini":
            GeminiAdapter.clearManagedCredentials(home: dir)
        default:
            break
        }
        try? CredentialStore.removeDirectory(for: removed.credentialRef)
        reindex()
        // Explicit empty is allowed (user removed the last account).
        try persistence.save(accounts, allowEmptyOverwrite: true)
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
        // Append any that were missing from ids (safety — never drop rows).
        for account in accounts where !ids.contains(account.id) {
            next.append(account)
        }
        let before = accounts.map(\.id)
        let after = next.map(\.id)
        guard after != before else { return }
        accounts = next
        reindex()
        try persist()
        accounts = accounts
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
        reindex(&accounts)
    }

    private func reindex(_ list: inout [Account]) {
        for i in list.indices {
            list[i].sortIndex = i
        }
    }

    private func persist() throws {
        try persistence.save(accounts, allowEmptyOverwrite: accounts.isEmpty)
    }

    /// Folders under `accounts/` that hold valid vendor creds but are missing from the list.
    private func recoverOrphans(existing: [Account]) -> [Account] {
        let known = Set(existing.map(\.credentialRef))
        var recovered: [Account] = []
        for ref in CredentialStore.listCredentialRefs() {
            guard !known.contains(ref) else { continue }
            let dir = CredentialStore.directoryURL(for: ref)
            guard let vendor = CredentialStore.detectVendor(in: dir) else { continue }
            let id = UUID(uuidString: ref) ?? UUID()
            let label: String
            switch vendor {
            case "claude": label = "Claude"
            case "codex": label = "Codex"
            case "grok": label = "Grok"
            case "gemini": label = "Gemini"
            default: label = vendor
            }
            recovered.append(
                Account(
                    id: id,
                    vendorID: vendor,
                    label: label,
                    credentialRef: ref,
                    sortIndex: existing.count + recovered.count,
                    createdAt: Date(),
                    lastAuthenticatedAt: Date()
                )
            )
        }
        return recovered
    }
}
