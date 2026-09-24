import Foundation

/// Refresh / fetch flows of the four adapters, end to end through `StubHTTP`.
/// Temp folders only; no vendor traffic, no CLI, no Keychain.
enum AdapterRefreshSuite {
    static func run() async -> Int {
        print("AdapterRefreshSuite")
        var failures = 0
        let rotated = #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}"#
        let grant = #"{"error":"invalid_grant"}"#

        // MARK: Codex

        let codexUsage = #"{"rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":18000}}}"#
        func codexRoute(token: StubHTTP.Answer) -> (URLRequest) -> StubHTTP.Answer {
            { req in
                switch req.url?.host {
                case "auth.openai.com": return token
                case "chatgpt.com" where req.url?.lastPathComponent == "usage":
                    return bearer(req) == "Bearer at-new" ? (200, codexUsage, [:]) : (401, "", [:])
                default: return (404, "", [:])
                }
            }
        }

        failures += await checkAsync("Codex refresh writes the rotated tokens atomically, owner-only") {
            let home = try codexHome(lastRefresh: nil)
            defer { try? FileManager.default.removeItem(at: home) }
            let outcome = await StubHTTP.with(route: codexRoute(token: (200, rotated, [:]))) {
                await CodexAdapter.refreshManagedCredentials(codexHome: home, force: true)
            }
            guard case .success(let creds) = outcome else {
                throw TestFailure(description: "expected success, got \(outcome)")
            }
            try assertEqual(creds.refreshToken, "rt-new")
            let file = home.appendingPathComponent("auth.json")
            try assertEqual(CodexAdapter.readCredentials(codexHome: home)?.refreshToken, "rt-new")
            try assertEqual(mode(file), 0o600)
            try assertEqual(entries(home), [".dash-refresh.lock", "auth.json"])
        }

        failures += await checkAsync("Codex usage 401 → refresh → retry with the new access") {
            let home = try codexHome(lastRefresh: Date())
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: codexRoute(token: (200, rotated, [:]))) {
                await CodexAdapter.fetchUsage(codexHome: home)
            }
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0.125, accuracy: 0.0001)
            try assertEqual(
                StubHTTP.requestURLs.map(\.lastPathComponent),
                ["usage", "token", "usage", "rate-limit-reset-credits"]
            )
            try assertEqual(CodexAdapter.readCredentials(codexHome: home)?.refreshToken, "rt-new")
        }

        failures += await checkAsync("Codex token host 429 during a poll stays soft") {
            let home = try codexHome(lastRefresh: nil)
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: codexRoute(token: (429, "", ["Retry-After": "60"]))) {
                await CodexAdapter.fetchUsage(codexHome: home)
            }
            try assertSoftQuiet(snap)
            try assertEqual(StubHTTP.requestURLs.map(\.lastPathComponent), ["token", "usage"])
            try assertEqual(CodexAdapter.readCredentials(codexHome: home)?.refreshToken, "rt-old")
        }

        failures += await checkAsync("Codex invalid_grant needs a new login") {
            let home = try codexHome(lastRefresh: nil)
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: codexRoute(token: (400, grant, [:]))) {
                await CodexAdapter.fetchUsage(codexHome: home)
            }
            try assertEqual(snap.error, .authRequired)
            try assertEqual(StubHTTP.requestURLs.map(\.lastPathComponent), ["token", "usage"])
        }

        // MARK: Grok

        let grokCredits = #"{"config":{"creditUsagePercent":42,"subscriptionTier":"SuperGrok"}}"#
        func grokRoute(token: StubHTTP.Answer) -> (URLRequest) -> StubHTTP.Answer {
            { req in
                switch req.url?.host {
                case "auth.x.ai": return token
                case "cli-chat-proxy.grok.com":
                    return bearer(req) == "Bearer at-new" ? (200, grokCredits, [:]) : (401, "", [:])
                default: return (404, "", [:])
                }
            }
        }

        failures += await checkAsync("Grok refresh writes the rotated tokens atomically, owner-only") {
            let home = try grokHome(expiresAt: "2020-01-01T00:00:00Z")
            defer { try? FileManager.default.removeItem(at: home) }
            let outcome = await StubHTTP.with(route: grokRoute(token: (200, rotated, [:]))) {
                await GrokAdapter.refreshManagedSession(grokHome: home)
            }
            guard case .success(let session) = outcome else {
                throw TestFailure(description: "expected success, got \(outcome)")
            }
            try assertEqual(session.refreshToken, "rt-new")
            try assertEqual(GrokAdapter.readSession(grokHome: home)?.refreshToken, "rt-new")
            try assertEqual(mode(home.appendingPathComponent("auth.json")), 0o600)
            try assertEqual(entries(home), [".dash-refresh.lock", "auth.json"])
        }

        failures += await checkAsync("Grok billing 401 → refresh → retry with the new access") {
            let home = try grokHome(expiresAt: "2099-01-01T00:00:00Z")
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: grokRoute(token: (200, rotated, [:]))) {
                await GrokAdapter.fetchUsage(grokHome: home)
            }
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0.42, accuracy: 0.0001)
            try assertEqual(Array(StubHTTP.requestURLs.map { $0.host ?? "" }.prefix(3)),
                            ["cli-chat-proxy.grok.com", "auth.x.ai", "cli-chat-proxy.grok.com"])
            try assertEqual(GrokAdapter.readSession(grokHome: home)?.refreshToken, "rt-new")
        }

        failures += await checkAsync("Grok token host 429 during a poll stays soft") {
            let home = try grokHome(expiresAt: "2020-01-01T00:00:00Z")
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: grokRoute(token: (429, "", ["Retry-After": "60"]))) {
                await GrokAdapter.fetchUsage(grokHome: home)
            }
            try assertSoftQuiet(snap)
            try assertEqual(GrokAdapter.readSession(grokHome: home)?.refreshToken, "rt-old")
        }

        failures += await checkAsync("Grok invalid_grant needs a new login") {
            let home = try grokHome(expiresAt: "2020-01-01T00:00:00Z")
            defer { try? FileManager.default.removeItem(at: home) }
            let snap = await StubHTTP.with(route: grokRoute(token: (400, grant, [:]))) {
                await GrokAdapter.fetchUsage(grokHome: home)
            }
            try assertEqual(snap.error, .authRequired)
            try assertEqual(StubHTTP.requestURLs.map { $0.host ?? "" }, ["auth.x.ai"])
        }

        // MARK: Claude (refresh + re-probe; `fetchUsage` itself touches the Keychain)

        let claudeUsage = #"{"five_hour":{"utilization":42.5},"seven_day":{"utilization":10}}"#
        func claudeRoute(token: StubHTTP.Answer) -> (URLRequest) -> StubHTTP.Answer {
            { req in
                switch req.url?.host {
                case "console.anthropic.com", "platform.claude.com": return token
                case "api.anthropic.com":
                    return bearer(req) == "Bearer at-new" ? (200, claudeUsage, [:]) : (401, "", [:])
                default: return (404, "", [:])
                }
            }
        }
        let dead = UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            plan: nil,
            fetchedAt: Date(),
            error: .authRequired
        )

        failures += await checkAsync("Claude refresh writes the rotated tokens atomically, owner-only") {
            try await withClaudeSandbox { dir, _ in
                let outcome = await StubHTTP.with(route: claudeRoute(token: (200, rotated, [:]))) {
                    await ClaudeAdapter.refreshManagedCredentialsDetailed(configDir: dir, failedAccessToken: "at-old")
                }
                guard case .success(let creds) = outcome else {
                    throw TestFailure(description: "expected success, got \(outcome)")
                }
                try assertEqual(creds.refreshToken, "rt-new")
                try assertEqual(ClaudeAdapter.readCredentialsFile(configDir: dir)?.refreshToken, "rt-new")
                try assertEqual(mode(dir.appendingPathComponent(".credentials.json")), 0o600)
                try assertEqual(entries(dir), [".credentials.json", ".dash-refresh.lock"])
            }
        }

        failures += await checkAsync("Claude usage 401 → refresh → retry with the new access") {
            try await withClaudeSandbox { dir, pings in
                let snap = await StubHTTP.with(route: claudeRoute(token: (200, rotated, [:]))) {
                    await ClaudeAdapter.refreshThenProbe(
                        configDir: dir, ref: dir.lastPathComponent,
                        failedAccessToken: "at-old", fallback: dead
                    )
                }
                try assertEqual(snap.error, nil as UsageError?)
                try assertEqual(snap.primary.usedFraction, 0.425, accuracy: 0.0001)
                try assertEqual(StubHTTP.requestURLs.map { $0.host ?? "" }, ["console.anthropic.com", "api.anthropic.com"])
                try assertEqual(pings(), 0)
            }
        }

        failures += await checkAsync("Claude token host 429 stays soft and starts no real CLI") {
            try await withClaudeSandbox { dir, pings in
                let snap = await StubHTTP.with(route: claudeRoute(token: (429, "", ["Retry-After": "60"]))) {
                    await ClaudeAdapter.refreshThenProbe(
                        configDir: dir, ref: dir.lastPathComponent,
                        failedAccessToken: "at-old", fallback: dead
                    )
                }
                try assertSoftQuiet(snap)
                try assertEqual(pings(), 1)
                try assertEqual(ClaudeAdapter.readCredentialsFile(configDir: dir)?.refreshToken, "rt-old")
            }
        }

        failures += await checkAsync("Claude invalid_grant needs a new login") {
            try await withClaudeSandbox { dir, pings in
                let snap = await StubHTTP.with(route: claudeRoute(token: (400, grant, [:]))) {
                    await ClaudeAdapter.refreshThenProbe(
                        configDir: dir, ref: dir.lastPathComponent,
                        failedAccessToken: "at-old", fallback: dead
                    )
                }
                try assertEqual(snap.error, .authRequired)
                try assertEqual(pings(), 0)
            }
        }

        // MARK: Antigravity (no reactive refresh: it only extends an expiring access)

        let agyToken = #"{"access_token":"ya29.new","refresh_token":"1//new","expires_in":3600}"#
        let agyRefresh: (String) async -> AgyAdapter.TokenRefreshResult = {
            await AgyAdapter.refreshAccessToken($0, ids: ["1-a.apps.googleusercontent.com"], secrets: ["s"])
        }

        failures += await checkAsync("Antigravity refresh writes the rotated tokens atomically, owner-only") {
            let home = try agyHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let result = await StubHTTP.with(status: 200, body: agyToken) {
                await AgyAdapter.freshCredentials(home: home, refresh: agyRefresh)
            }
            guard case .ok(let creds) = result else { throw TestFailure(description: "expected ok, got \(result)") }
            try assertEqual(creds.refreshToken, "1//new")
            try assertEqual(AgyAdapter.readOAuthCredsJSONFile(home: home)?.refreshToken, "1//new")
            let gemini = home.appendingPathComponent(".gemini")
            try assertEqual(mode(gemini.appendingPathComponent("oauth_creds.json")), 0o600)
            try assertEqual(entries(gemini), ["oauth_creds.json"])
        }

        failures += await checkAsync("Antigravity token host 429 retries later and keeps the session") {
            let home = try agyHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let result = await StubHTTP.with(status: 429, body: "") {
                await AgyAdapter.freshCredentials(home: home, refresh: agyRefresh)
            }
            guard case .retryLater = result else { throw TestFailure(description: "expected retryLater, got \(result)") }
            try assertEqual(AgyAdapter.readOAuthCredsJSONFile(home: home)?.refreshToken, "1//old")
        }

        failures += await checkAsync("Antigravity invalid_grant needs a new login") {
            let home = try agyHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let result = await StubHTTP.with(status: 400, body: grant) {
                await AgyAdapter.freshCredentials(home: home, refresh: agyRefresh)
            }
            guard case .needsReauth = result else { throw TestFailure(description: "expected needsReauth, got \(result)") }
        }

        // MARK: Folder lock (adapters-02): account-cli and the app share each folder

        failures += await checkAsync("refresh lock excludes a second holder until release") {
            let dir = try tempDir("lock")
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let held = await CredentialStore.acquireRefreshLock(in: dir) else {
                throw TestFailure(description: "first holder got no lock")
            }
            let blocked = await CredentialStore.acquireRefreshLock(in: dir, timeout: 0.3)
            try assertTrue(blocked == nil, "second holder must wait")
            try assertEqual(mode(dir.appendingPathComponent(".dash-refresh.lock")), 0o600)
            held.release()
            let next = await CredentialStore.acquireRefreshLock(in: dir, timeout: 0.3)
            try assertTrue(next != nil, "free after release")
            next?.release()
        }

        failures += await checkAsync("Codex adopts a refresh token the CLI rotated since the poll read it") {
            let home = try codexHome(lastRefresh: nil)
            defer { try? FileManager.default.removeItem(at: home) }
            let outcome = await StubHTTP.with(status: 500, body: "") {
                await holdLockWhileRotating(home, file: "auth.json",
                    to: #"{"tokens":{"access_token":"at-cli","refresh_token":"rt-cli"}}"#) {
                    await CodexAdapter.refreshManagedCredentials(codexHome: home, force: true, knownRefreshToken: "rt-old")
                }
            }
            try assertEqual(outcome, .success(CodexAdapter.CodexCreds(
                accessToken: "at-cli", refreshToken: "rt-cli", accountID: nil,
                filePath: home.appendingPathComponent("auth.json")
            )))
            try assertEqual(StubHTTP.requestCount, 0)
        }

        failures += await checkAsync("Grok adopts a refresh token the CLI rotated since the poll read it") {
            let home = try grokHome(expiresAt: "2020-01-01T00:00:00Z")
            defer { try? FileManager.default.removeItem(at: home) }
            let cli = #"{"https://auth.x.ai::client-1":{"key":"at-cli","refresh_token":"rt-cli","expires_at":"2099-01-01T00:00:00Z"}}"#
            let outcome = await StubHTTP.with(status: 500, body: "") {
                await holdLockWhileRotating(home, file: "auth.json", to: cli) {
                    await GrokAdapter.refreshManagedSession(grokHome: home, knownRefreshToken: "rt-old")
                }
            }
            guard case .success(let session) = outcome else {
                throw TestFailure(description: "expected adopted session, got \(outcome)")
            }
            try assertEqual(session.accessToken, "at-cli")
            try assertEqual(StubHTTP.requestCount, 0)
        }

        failures += await checkAsync("Claude waits for the folder lock and adopts the newer file") {
            try await withClaudeSandbox { dir, pings in
                let later = Int(Date().addingTimeInterval(8 * 3600).timeIntervalSince1970 * 1000)
                let cli = #"{"claudeAiOauth":{"accessToken":"at-cli","refreshToken":"rt-cli","expiresAt":\#(later)}}"#
                let outcome = await StubHTTP.with(status: 500, body: "") {
                    await holdLockWhileRotating(dir, file: ".credentials.json", to: cli) {
                        await ClaudeAdapter.refreshManagedCredentialsDetailed(configDir: dir, failedAccessToken: "at-old")
                    }
                }
                guard case .adopted(let creds) = outcome else {
                    throw TestFailure(description: "expected adopted, got \(outcome)")
                }
                try assertEqual(creds.refreshToken, "rt-cli")
                try assertEqual(StubHTTP.requestCount, 0)
                try assertEqual(pings(), 0)
            }
        }

        return failures
    }

    /// Another holder (a second app copy) has the folder lock while `refresh`
    /// starts, rotates `file`, then lets go. Without the lock, `refresh` POSTs
    /// the spent token first.
    private static func holdLockWhileRotating<T: Sendable>(
        _ dir: URL,
        file: String,
        to json: String,
        _ refresh: @escaping @Sendable () async -> T
    ) async -> T {
        let holder = await CredentialStore.acquireRefreshLock(in: dir)
        let waiting = Task { await refresh() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? Data(json.utf8).write(to: dir.appendingPathComponent(file), options: .atomic)
        holder?.release()
        return await waiting.value
    }

    // MARK: - Helpers

    private static func bearer(_ req: URLRequest) -> String? {
        req.value(forHTTPHeaderField: "Authorization")
    }

    /// A busy token host keeps the rings: yellow "token quiet" with a retry time, never red.
    private static func assertSoftQuiet(_ snap: UsageSnapshot) throws {
        guard let error = snap.error else { throw TestFailure(description: "expected a soft error, got none") }
        try assertEqual(UsageSnapshotMerge.failureKind(error), .soft)
        try assertTrue(snap.retryAt != nil, "a 429 carries a retry time")
    }

    private static func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Everything in the folder, so a leftover temp file from a non-atomic write shows.
    private static func entries(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private static func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func codexHome(lastRefresh: Date?) throws -> URL {
        let home = try tempDir("codex")
        var root: [String: Any] = ["tokens": ["access_token": "at-old", "refresh_token": "rt-old"]]
        if let lastRefresh { root["last_refresh"] = ISO8601DateFormatter().string(from: lastRefresh) }
        try JSONSerialization.data(withJSONObject: root).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    private static func grokHome(expiresAt: String) throws -> URL {
        let home = try tempDir("grok")
        let auth = #"{"https://auth.x.ai::client-1":{"key":"at-old","refresh_token":"rt-old","expires_at":"\#(expiresAt)"}}"#
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    private static func agyHome() throws -> URL {
        let home = try tempDir("agy")
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        let expired = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let creds = #"{"access_token":"ya29.old","refresh_token":"1//old","expiry_date":\#(expired)}"#
        try Data(creds.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        return home
    }

    /// Expired Claude file, a throwaway refresh gate, and a counting CLI ping
    /// stand-in: a failed token host must never start a real `claude`.
    private static func withClaudeSandbox(
        _ body: (URL, () -> Int) async throws -> Void
    ) async throws {
        let dir = try tempDir("claude")
        let expired = Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let creds = #"{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":\#(expired),"subscriptionType":"pro"}}"#
        try Data(creds.utf8).write(to: dir.appendingPathComponent(".credentials.json"))
        let suite = "DashIsland.tests.adapterRefresh.\(UUID().uuidString)"
        let savedGate = ClaudeAdapter.refreshGate
        let savedPing = ClaudeAdapter.backgroundPing
        nonisolated(unsafe) var pings = 0
        ClaudeAdapter.refreshGate = ClaudeRefreshGate(defaults: UserDefaults(suiteName: suite)!)
        ClaudeAdapter.backgroundPing = { _, _ in pings += 1; return nil }
        defer {
            ClaudeAdapter.refreshGate = savedGate
            ClaudeAdapter.backgroundPing = savedPing
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(dir, { pings })
    }
}
