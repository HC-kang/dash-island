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
    /// Registration limit; the island uses this same cap and scrolls past 5 slots.
    static let maxAccounts = 20

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
        try persist(accounts + [copy])
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
        try persist(accounts + [account])
        return account
    }

    /// Remove metadata row and credential folder.
    func remove(id: AccountID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = accounts
        let removed = next.remove(at: index)
        // A failed metadata save must not remove the account or its credentials.
        try persist(next)
        let dir = CredentialStore.directoryURL(for: removed.credentialRef)
        switch removed.vendorID {
        case "claude":
            ClaudeAdapter.clearManagedCredentials(configDir: dir)
        case "codex":
            CodexAdapter.clearManagedCredentials(codexHome: dir)
        case "grok":
            GrokAdapter.clearManagedCredentials(grokHome: dir)
        case "agy":
            AgyAdapter.clearManagedCredentials(home: dir)
        default:
            break
        }
        try? CredentialStore.removeDirectory(for: removed.credentialRef)
    }

    func rename(id: AccountID, label: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = accounts
        next[index].label = label
        try persist(next)
    }

    /// Move `id` so it ends at `toIndex` in the final array (0-based).
    func move(id: AccountID, toIndex: Int) throws {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, toIndex), accounts.count - 1)
        guard from != target else { return }
        var list = accounts
        let item = list.remove(at: from)
        list.insert(item, at: target)
        try persist(list)
    }

    /// Replace order with an explicit id list (drag commit). Unknown ids ignored.
    func applyOrder(_ ids: [AccountID]) throws {
        let map = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var next: [Account] = []
        next.reserveCapacity(accounts.count)
        var seen = Set<AccountID>()
        // Missing IDs append in their existing order; repeated/stale IDs never
        // duplicate rows (which would crash later unique-key dictionaries).
        for id in ids + accounts.map(\.id) {
            if seen.insert(id).inserted, let account = map[id] { next.append(account) }
        }
        let before = accounts.map(\.id)
        let after = next.map(\.id)
        guard after != before else { return }
        try persist(next)
    }

    /// After adapter `reauthenticate`, stamp auth time and optionally replace credential ref.
    func markAuthenticated(id: AccountID, credentialRef: CredentialRef? = nil) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = accounts
        next[index].lastAuthenticatedAt = Date()
        if let credentialRef {
            next[index].credentialRef = credentialRef
        }
        try persist(next)
    }

    // MARK: - Private

    private func reindex(_ list: inout [Account]) {
        for i in list.indices {
            list[i].sortIndex = i
        }
    }

    private func persist(_ proposed: [Account]) throws {
        var next = proposed
        reindex(&next)
        try persistence.save(next, allowEmptyOverwrite: next.isEmpty)
        // Publish one complete, saved state, never intermediate sort indices.
        accounts = next
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
            case "agy": label = "Antigravity"
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
