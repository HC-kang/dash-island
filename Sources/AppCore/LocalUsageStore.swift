import Foundation
import Combine

@MainActor
final class LocalUsageStore: ObservableObject {
    static let shared = LocalUsageStore()
    @Published private(set) var snapshots: [String: LocalUsageArchive.Snapshot] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var updated: [String: Date] = [:]
    @Published private(set) var catalog: UsagePriceCatalog?
    private var priceTask: Task<Void, Never>?
    private var priceCheckedAt: Date?
    static let catalogURL = URL(string: "https://ericjypark.github.io/codex-island-model-catalog/v1/models.json")!
    private init() {
        catalog = AccountUsageReader.loadPrices()
    }

    nonisolated static func sourceKey(provider: String, accountID: AccountID?, transcriptHistory: Bool = false) -> String {
        if transcriptHistory { return "\(provider)-transcripts" }
        return accountID.map { "\(provider)-\($0.uuidString)" } ?? provider
    }

    func load(provider: String, accountID: AccountID? = nil, transcriptHistory: Bool = false) async {
        let key = Self.sourceKey(provider: provider, accountID: accountID, transcriptHistory: transcriptHistory)
        guard ["claude", "codex", "grok", "agy"].contains(provider), !loading.contains(key) else { return }
        refreshPrices()
        if !transcriptHistory, ["codex", "claude"].contains(provider) {
            // Every captured scope is published from the same read and refresh cadence.
            guard !loading.contains(provider), updated[provider].map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { return }
            loading.insert(provider)
            defer { loading.remove(provider) }
            let started = Date()
            let captured = await Task.detached(priority: .utility) {
                AccountUsageReader.readAccounts(provider: provider)
            }.value
            let date = Date()
            snapshots[provider] = .init(events: captured.accounts.values.flatMap { $0 }, notice: captured.notice)
            updated[provider] = date
            for account in AccountStore.shared.accounts where account.vendorID == provider {
                let key = Self.sourceKey(provider: provider, accountID: account.id)
                let identity = AccountUsageReader.identity(provider: provider, home: CredentialStore.directoryURL(for: account.credentialRef))
                snapshots[key] = .init(events: identity.flatMap { captured.accounts[$0] } ?? [],
                    notice: identity == nil ? "Account identity unavailable. Reauthenticate this account to reconnect tracking." : captured.notice)
                updated[key] = date
            }
            // debug: the detail panel reloads every ~15 s.
            Log.local.debug("load provider=\(provider) scope=captured events=\(captured.accounts.values.reduce(0) { $0 + $1.count }) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return
        }
        if let date = updated[key], Date().timeIntervalSince(date) < 120 { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let started = Date()
        // Keep the existing transcript archive, separate from captured-call totals.
        let archiveScope = transcriptHistory ? provider : key
        if snapshots[key] == nil {
            snapshots[key] = await LocalUsageArchive.shared.cached(provider: provider, scope: archiveScope)
        }
        let roots = roots(provider: provider, accountID: accountID)
        snapshots[key] = await LocalUsageArchive.shared.refresh(provider: provider, roots: roots, scope: archiveScope)
        updated[key] = Date()
        // debug: the detail panel reloads every ~15 s.
        Log.local.debug("load provider=\(provider) scope=\(transcriptHistory ? "history" : "archive") account=\(accountID?.short ?? "-") ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    private func roots(provider: String, accountID: AccountID?) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        var roots: [URL]
        if accountID != nil {
            roots = [] // Shared CLI history cannot be assigned to the current login.
        } else if provider == "agy" {
            roots = [home.appendingPathComponent(".gemini/antigravity-cli/conversations")]
        } else if provider == "grok" {
            roots = [home.appendingPathComponent(".grok/sessions")]
            if let custom = env["GROK_HOME"], !custom.isEmpty {
                roots.append(URL(fileURLWithPath: custom).appendingPathComponent("sessions"))
            }
        } else if provider == "codex" {
            roots = [home.appendingPathComponent(".codex/sessions")]
            if let custom = env["CODEX_HOME"], !custom.isEmpty {
                roots.append(URL(fileURLWithPath: custom).appendingPathComponent("sessions"))
            }
        } else {
            roots = [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
            for custom in (env["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",") {
                roots.append(URL(fileURLWithPath: String(custom).trimmingCharacters(in: .whitespaces)).appendingPathComponent("projects"))
            }
        }
        if accountID == nil { roots += Self.orcaRoots(provider: provider, home: home) }
        for account in AccountStore.shared.accounts where account.vendorID == provider && (accountID == nil || account.id == accountID) {
            let directory = CredentialStore.rootURL.appendingPathComponent(account.credentialRef)
            let paths: [String]
            switch provider {
            case "agy": paths = [".gemini/antigravity-cli/conversations"]
            case "grok": paths = ["sessions", ".grok/sessions"]
            case "codex": paths = ["sessions", ".codex/sessions"]
            default: paths = ["projects", ".claude/projects"]
            }
            roots += paths.map { directory.appendingPathComponent($0) }
        }
        return roots
    }

    // Orca keeps transcripts outside the default CLI home. These are machine-wide
    // sources only: Codex bridges the same history across different account homes.
    nonisolated static func orcaRoots(provider: String, home: URL) -> [URL] {
        guard ["codex", "claude"].contains(provider) else { return [] }
        let orca = home.appendingPathComponent("Library/Application Support/orca")
        let accounts = orca.appendingPathComponent("\(provider)-accounts")
        let homes = (try? FileManager.default.contentsOfDirectory(at: accounts,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var roots = homes.map { $0.appendingPathComponent(provider == "codex" ? "home/sessions" : "auth/projects") }
        if provider == "codex" { roots.append(orca.appendingPathComponent("codex-runtime-home/home/sessions")) }
        return roots
    }

    private func refreshPrices() {
        guard priceTask == nil, priceCheckedAt.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true else { return }
        priceTask = Task {
            defer { priceTask = nil }
            priceCheckedAt = Date()
            var request = URLRequest(url: Self.catalogURL)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
                  let value = try? JSONDecoder().decode(UsagePriceCatalog.self, from: data), value.valid else { return }
            catalog = value
            try? data.write(to: AccountUsageReader.priceCacheURL, options: .atomic)
        }
    }
}
