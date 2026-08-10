import CryptoKit
import Foundation
import Security

// MARK: - Errors

enum ClaudeAdapterError: Error, Equatable, LocalizedError {
    case claudeBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(configDir: String)
    case credentialsMissing(configDir: String)
    case reauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .claudeBinaryNotFound:
            return """
            Could not find the Claude Code CLI (`claude`). Install it, then either retry \
            or run login manually with CLAUDE_CONFIG_DIR pointed at the managed account folder.
            """
        case .spawnFailed(let message):
            return "Failed to start Claude login: \(message)"
        case .loginTimeout(let configDir):
            return """
            Claude login timed out. Complete browser sign-in, or run manually:

              CLAUDE_CONFIG_DIR='\(configDir)' claude auth login --claudeai

            Then choose Reauthenticate (or remove and re-add).
            """
        case .credentialsMissing(let configDir):
            return """
            Claude login finished but no credentials were found. Run:

              CLAUDE_CONFIG_DIR='\(configDir)' claude auth login --claudeai
            """
        case .reauthFailed(let message):
            return message
        }
    }
}

// MARK: - Adapter

/// Anthropic Claude Code usage via `/api/oauth/usage`.
///
/// **Credentials (multi-account safe):** each account owns
/// `accounts/<uuid>/.credentials.json` only. Steady-state never reads Keychain.
/// Scoped Keychain is used **once** at login capture (CLI may write KC first),
/// then copied into the file; reauth clears file + that scoped item only.
/// Never touch the unsuffixed global `Claude Code-credentials` item.
///
/// Two auth modes:
/// 1. **Long-lived setup-token** (`claude setup-token` → paste) — no refresh;
///    often lacks `user:profile` for usage.
/// 2. **CLI OAuth** (`claude auth login`) — short access + refresh_token. We
///    own refresh via the public Claude Code client id, with a **process-wide**
///    gate so multi-account polls do not 429-storm `oauth/token`.
struct ClaudeAdapter: VendorAdapter {
    let id: VendorID = "claude"
    let displayName = "Claude"
    /// Claude is heavy on OAuth refresh 429s — poll less often than Codex/Grok.
    let minPollSeconds = 1_800

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Proactive refresh only when this close to expiry (was 15m — too chatty → 429).
    private static let expiryBuffer: TimeInterval = 3 * 60
    /// Prefer reactive refresh (usage 401) over long proactive windows.
    /// Still allow a short proactive window so expand-poll doesn't race expiry mid-request.
    private static let maxStaleForRefresh: TimeInterval = 7 * 24 * 3600
    /// Minimum gap between *any* Claude OAuth refresh calls app-wide.
    private static let globalRefreshMinGap: TimeInterval = 20 * 60
    /// Extra quiet after HTTP 429 on the token endpoint (all accounts share this).
    private static let globalRefresh429Quiet: TimeInterval = 3 * 60 * 60
    private static let credentialsFileName = ".credentials.json"
    private static let loginTimeout: TimeInterval = 180
    private static let pollNanos: UInt64 = 1_000_000_000
    private static let cliUserAgent = "claude-code/2.1.121"
    private static let betaHeader = "oauth-2025-04-20"
    private static let keychainServiceBase = "Claude Code-credentials"
    /// Token hosts (Claude Code has moved between these; try both).
    private static let oauthTokenURLs: [URL] = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    /// Serializes OAuth refresh so two Claude accounts cannot 429 the token host.
    private static let refreshGate = ClaudeRefreshGate()

    // MARK: VendorAdapter

    func beginAdd() async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        do {
            let dir = try CredentialStore.createDirectory(for: ref)
            try await runLogin(configDir: dir)
            let creds = try Self.requireCredentials(configDir: dir)
            let short = String(ref.prefix(8))
            let label = Self.suggestedLabel(plan: creds.subscriptionType, short: short)
            return AddAccountResult(vendorID: id, label: label, credentialRef: ref)
        } catch {
            try? CredentialStore.removeDirectory(for: ref)
            throw error
        }
    }

    /// Optional advanced path: paste a token. **Must** pass a usage smoke test —
    /// plain `claude setup-token` often lacks `user:profile` and cannot read
    /// `/api/oauth/usage` (403). Prefer browser OAuth for Dash Island.
    func beginAddWithSetupToken(_ rawToken: String) async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        do {
            let dir = try CredentialStore.createDirectory(for: ref)
            try Self.installSetupToken(rawToken, configDir: dir)
            try await Self.verifyUsageAccess(configDir: dir)
            let short = String(ref.prefix(8))
            return AddAccountResult(
                vendorID: id,
                label: "Claude \(short)",
                credentialRef: ref
            )
        } catch {
            try? CredentialStore.removeDirectory(for: ref)
            throw error
        }
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            // Wipe managed session first — otherwise runLogin short-circuits on
            // the still-present .credentials.json / scoped keychain item and
            // never opens a real login.
            Self.clearManagedCredentials(configDir: dir)
            try await runLogin(configDir: dir, expectFreshAfter: Date())
            _ = try Self.requireCredentials(configDir: dir)
            return ref
        } catch let error as ClaudeAdapterError {
            throw error
        } catch {
            throw ClaudeAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    /// Replace managed creds with a pasted token (smoke-tested against usage API).
    func reauthenticateWithSetupToken(_ ref: CredentialRef, token: String) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        Self.clearManagedCredentials(configDir: dir)
        try Self.installSetupToken(token, configDir: dir)
        try await Self.verifyUsageAccess(configDir: dir)
        return ref
    }

    /// Hit `/api/oauth/usage` once so scope-deficient tokens fail at paste time.
    static func verifyUsageAccess(configDir: URL) async throws {
        guard let creds = readCredentials(configDir: configDir) else {
            throw ClaudeAdapterError.reauthFailed("No credentials written.")
        }
        let snap = await probeUsage(
            token: creds.accessToken,
            plan: creds.subscriptionType,
            fetchedAt: Date()
        )
        if let err = snap.error {
            switch err {
            case .authRequired:
                throw ClaudeAdapterError.reauthFailed(
                    """
                    Token rejected by Anthropic (invalid or missing scopes).
                    `claude setup-token` usually cannot read usage — it lacks user:profile.
                    Use Reauthenticate → browser login instead:
                      CLAUDE_CONFIG_DIR='\(configDir.path)' claude auth login --claudeai
                    """
                )
            case .rateLimited:
                // Token may still be valid; allow save during OAuth storm.
                NSLog("DashIsland: Claude token smoke-test rate-limited (keeping)")
            case .network, .parse, .unavailable:
                // Soft: network blip should not block paste of a good token.
                NSLog("DashIsland: Claude token smoke-test soft error %@", String(describing: err))
            }
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)

        // Steady-state: managed file only (one file per account — multi-account safe).
        guard let creds = Self.readCredentials(configDir: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }

        // Long-lived / pasted token: no refresh. Anthropic's setup-token is
        // model-only — `/api/oauth/usage` requires user:profile from full login.
        if Self.isLongLived(creds) {
            let snap = await Self.probeUsage(
                token: creds.accessToken,
                plan: creds.subscriptionType,
                fetchedAt: now
            )
            if case .authRequired = snap.error {
                NSLog(
                    "DashIsland: Claude long-lived token lacks usage scopes ref=%@",
                    String(ref.prefix(8))
                )
                return Self.errorSnapshot(
                    .unavailable(
                        "setup-token can’t read usage (no user:profile). Reauthenticate → browser login"
                    ),
                    fetchedAt: now
                )
            }
            return Self.logUsage(snap, ref: ref)
        }

        // --- Short-lived CLI OAuth (we own refresh for this account's file) ---
        // Probe-first: never burn oauth/token while access is still usable.
        // Live probe: personal account with hours left returns 200 even when the
        // global token host is hard-429 (refresh storms from other accounts).
        // Refresh only on expired access or usage 401/403.

        if Self.shouldProbeBeforeRefresh(creds, now: now) {
            var snap = await Self.probeUsage(
                token: creds.accessToken,
                plan: creds.subscriptionType,
                fetchedAt: now
            )
            if case .authRequired = snap.error, Self.canAttemptRefresh(creds, now: now) {
                snap = await Self.refreshThenProbe(configDir: dir, ref: ref, fallback: snap)
            }
            return Self.logUsage(snap, ref: ref)
        }

        // Access expired (or unknown) — refresh is required before a useful probe.
        guard Self.canAttemptRefresh(creds, now: now) else {
            return Self.logUsage(
                Self.errorSnapshot(
                    .unavailable("token quiet — no refresh token. Reauthenticate this account"),
                    fetchedAt: now
                ),
                ref: ref
            )
        }
        let afterRefresh = await Self.refreshThenProbe(
            configDir: dir,
            ref: ref,
            fallback: Self.errorSnapshot(
                .rateLimited(retryAfter: now.addingTimeInterval(Self.globalRefresh429Quiet)),
                fetchedAt: now
            )
        )
        return Self.logUsage(afterRefresh, ref: ref)
    }

    /// One gated refresh + usage probe. On 429/unavailable keep `fallback` severity
    /// (soft) so orchestrator can retain last-good rings.
    private static func refreshThenProbe(
        configDir: URL,
        ref: CredentialRef,
        fallback: UsageSnapshot
    ) async -> UsageSnapshot {
        switch await refreshManagedCredentialsDetailed(configDir: configDir) {
        case .success(let refreshed):
            NSLog("DashIsland: Claude refresh ok ref=%@", String(ref.prefix(8)))
            return await probeUsage(
                token: refreshed.accessToken,
                plan: refreshed.subscriptionType,
                fetchedAt: Date()
            )
        case .rateLimited(let retry):
            NSLog("DashIsland: Claude refresh quiet ref=%@", String(ref.prefix(8)))
            return errorSnapshot(
                .rateLimited(retryAfter: retry ?? Date().addingTimeInterval(globalRefresh429Quiet)),
                fetchedAt: Date()
            )
        case .rejected:
            NSLog("DashIsland: Claude refresh rejected ref=%@", String(ref.prefix(8)))
            return errorSnapshot(.authRequired, fetchedAt: Date())
        case .unavailable(let message):
            NSLog("DashIsland: Claude refresh unavailable ref=%@ %@", String(ref.prefix(8)), message)
            // Prefer explicit soft quiet over a raw 401 fallback when refresh failed softly.
            if fallback.error != nil {
                return errorSnapshot(
                    .unavailable("token quiet — \(message)"),
                    fetchedAt: Date()
                )
            }
            return fallback
        case .skipped:
            if fallback.error != nil {
                return errorSnapshot(
                    .unavailable("token quiet — no refresh token. Reauthenticate this account"),
                    fetchedAt: Date()
                )
            }
            return fallback
        }
    }

    private static func logUsage(_ snap: UsageSnapshot, ref: CredentialRef) -> UsageSnapshot {
        if snap.error == nil {
            let p = Int((snap.primary.usedFraction * 100).rounded())
            let w = Int(((snap.secondary?.usedFraction ?? 0) * 100).rounded())
            let extraN = snap.extras.count
            NSLog(
                "DashIsland: Claude usage ok ref=%@ 5h=%d%% wk=%d%% extras=%d",
                String(ref.prefix(8)), p, w, extraN
            )
        } else if let err = snap.error {
            NSLog("DashIsland: Claude usage error ref=%@ %@", String(ref.prefix(8)), String(describing: err))
        }
        return snap
    }

    // MARK: - Login (managed CLAUDE_CONFIG_DIR)

    /// Wipe app-owned session so the next `claude auth login` cannot succeed
    /// on leftover state. Deletes our credentials file, and the CLI's
    /// **scoped** keychain item for this `CLAUDE_CONFIG_DIR` only (never the
    /// default `Claude Code-credentials` used by the user's normal CLI).
    static func clearManagedCredentials(configDir: URL) {
        let fm = FileManager.default
        let credFile = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        try? fm.removeItem(at: credFile)
        deleteScopedKeychainItem(configDir: configDir)
        NSLog("DashIsland: cleared Claude managed creds at %@", configDir.path)
    }

    private func runLogin(configDir: URL, expectFreshAfter: Date? = nil) async throws {
        guard let binary = Self.locateClaudeBinary() else {
            throw ClaudeAdapterError.claudeBinaryNotFound
        }

        // Snapshot so we only accept a *new* token after the process starts.
        let priorToken = Self.readCredentials(configDir: configDir)?.accessToken

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        // `--claudeai` selects subscription OAuth (required for /api/oauth/usage).
        task.arguments = ["auth", "login", "--claudeai"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        // Avoid inheriting a parent CLAUDE_CODE_OAUTH_TOKEN that would skip file login.
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        // Don't inherit a global token that would short-circuit OAuth.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        // Keep stdin open so the CLI does not see immediate EOF.
        task.standardInput = Pipe()

        do {
            try task.run()
        } catch {
            throw ClaudeAdapterError.spawnFailed(error.localizedDescription)
        }

        let started = Date()
        let deadline = started.addingTimeInterval(Self.loginTimeout)

        func isAcceptable(_ creds: ClaudeCreds) -> Bool {
            // Must differ from whatever was present at process start (nil after wipe).
            if let priorToken, creds.accessToken == priorToken { return false }
            if let expectFreshAfter, let exp = creds.expiresAt, exp <= expectFreshAfter {
                return false
            }
            return !creds.accessToken.isEmpty
        }

        while Date() < deadline {
            if Task.isCancelled {
                if task.isRunning { task.terminate() }
                throw CancellationError()
            }
            // Login only: capture once into our file (CLI may write keychain first).
            if let creds = Self.captureLoginCredentials(configDir: configDir), isAcceptable(creds) {
                Self.persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning {
                    task.terminate()
                }
                return
            }
            if !task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let creds = Self.captureLoginCredentials(configDir: configDir), isAcceptable(creds) {
                    Self.persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
                    return
                }
                throw ClaudeAdapterError.credentialsMissing(configDir: configDir.path)
            }
            try await Task.sleep(nanoseconds: Self.pollNanos)
        }

        if task.isRunning {
            task.terminate()
        }
        if let creds = Self.captureLoginCredentials(configDir: configDir), isAcceptable(creds) {
            Self.persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
            return
        }
        throw ClaudeAdapterError.loginTimeout(configDir: configDir.path)
    }

    private static func requireCredentials(configDir: URL) throws -> ClaudeCreds {
        if let creds = readCredentials(configDir: configDir) {
            return creds
        }
        // First capture after login if only keychain was written so far.
        if let creds = captureLoginCredentials(configDir: configDir) {
            persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
            return creds
        }
        throw ClaudeAdapterError.credentialsMissing(configDir: configDir.path)
    }

    private static func suggestedLabel(plan: String?, short: String) -> String {
        if let plan, !plan.isEmpty {
            return "Claude \(plan) \(short)"
        }
        return "Claude \(short)"
    }

    // MARK: - Credential storage (file is source of truth)

    struct ClaudeCreds: Equatable {
        var accessToken: String
        var refreshToken: String?
        var subscriptionType: String?
        /// Access-token expiry when known (Claude stores epoch **milliseconds**).
        var expiresAt: Date?
        /// `claude setup-token` paste — do not call oauth/token.
        var longLived: Bool = false
        /// Raw JSON blob (for writing `.credentials.json` into the managed folder).
        var rawJSON: Data?
    }

    /// Steady-state: only our managed `.credentials.json`. No Keychain.
    static func readCredentials(configDir: URL) -> ClaudeCreds? {
        readCredentialsFile(configDir: configDir)
    }

    static func readCredentialsFile(configDir: URL) -> ClaudeCreds? {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// Login capture only: file first; if the CLI wrote the scoped keychain
    /// first, copy once into our file and stop touching Keychain.
    static func captureLoginCredentials(configDir: URL) -> ClaudeCreds? {
        if let file = readCredentialsFile(configDir: configDir) {
            return file
        }
        return readScopedKeychainCredentials(configDir: configDir)
    }

    /// Setup-token / pasted long-lived OAuth: no refresh_token (or explicit flag).
    static func isLongLived(_ creds: ClaudeCreds) -> Bool {
        if creds.longLived { return true }
        // setup-token is typically sk-ant-oat01-… and has no refresh in our store.
        let hasRefresh = creds.refreshToken.map { !$0.isEmpty } ?? false
        if !hasRefresh, looksLikeSetupToken(creds.accessToken) { return true }
        return !hasRefresh && creds.expiresAt == nil && !creds.accessToken.isEmpty
    }

    /// `claude setup-token` prints `sk-ant-oat01-…` (long-lived access).
    static func looksLikeSetupToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("sk-ant-oat")
    }

    /// Normalize pasted token (strip whitespace / accidental labels).
    /// Live tokens are typically ~100+ chars; short pastes are almost always truncated.
    static let minSetupTokenLength = 90

    static func normalizePastedToken(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // If user pasted multi-line help text, keep the sk-ant- line only.
        if let line = t.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("sk-ant-") })
        {
            t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Drop wrapping quotes if present.
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        guard t.hasPrefix("sk-ant-"), t.count >= minSetupTokenLength else { return nil }
        return t
    }

    /// Write long-lived token into managed credentials (no refresh, no short expiry).
    static func installSetupToken(_ raw: String, configDir: URL) throws {
        guard let token = normalizePastedToken(raw) else {
            throw ClaudeAdapterError.reauthFailed(
                """
                Token looks incomplete or invalid (need full sk-ant-…, typically 100+ characters).
                Run in Terminal:  claude setup-token
                Copy the entire line — truncated pastes return “Invalid bearer token”.
                """
            )
        }
        let creds = ClaudeCreds(
            accessToken: token,
            refreshToken: nil,
            subscriptionType: nil,
            expiresAt: nil,
            longLived: true,
            rawJSON: nil
        )
        persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
        NSLog(
            "DashIsland: installed Claude setup-token len=%d at %@",
            token.count,
            configDir.path
        )
    }

    /// Near expiry (within buffer) or unknown expiry — candidate for refresh.
    /// Long-lived setup-tokens never refresh. Fetch path is **probe-first**; this
    /// is used by the refresh gate skip-if-fresh path, not to pre-empt usage.
    static func needsRefresh(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        shouldRefresh(creds, now: now)
    }

    /// True when we should call `/api/oauth/usage` before touching oauth/token.
    /// Access still usable (not expired) → probe; expired → refresh first.
    static func shouldProbeBeforeRefresh(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return true }
        return !isExpired(creds, now: now)
    }

    /// Near expiry / already expired / unknown — refresh is *allowed* if canAttempt.
    static func shouldRefresh(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return false }
        guard canAttemptRefresh(creds, now: now) else { return false }
        guard let exp = creds.expiresAt else {
            return true
        }
        return now.addingTimeInterval(expiryBuffer) >= exp
    }

    /// Safe to call oauth/token when we have a refresh_token (gate handles 429).
    /// No short wall-clock cut — that left accounts permanently quiet after 429 windows.
    static func canAttemptRefresh(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return false }
        guard let refresh = creds.refreshToken, !refresh.isEmpty else { return false }
        guard let exp = creds.expiresAt else { return true }
        // Extremely old blobs (weeks) — likely revoked; don't burn the endpoint.
        return now < exp.addingTimeInterval(maxStaleForRefresh)
    }

    static func isExpired(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return false }
        guard let exp = creds.expiresAt else { return true }
        return now >= exp
    }

    /// Kept for tests / callers: access older than maxStale (days), not a short quiet cut.
    static func isHardExpired(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return false }
        guard let exp = creds.expiresAt else { return false }
        return now >= exp.addingTimeInterval(maxStaleForRefresh)
    }

    /// Outcome of a managed-folder OAuth refresh (distinguishes 429 from real reauth).
    enum RefreshOutcome: Equatable {
        case success(ClaudeCreds)
        case skipped
        case rateLimited(Date?)
        case rejected
        case unavailable(String)
    }

    /// Refresh this account's managed file only. Rotates refresh_token when the
    /// server returns a new one (single-use — must persist atomically).
    /// Never reads Keychain; multi-account isolation is path-based.
    static func refreshManagedCredentials(configDir: URL) async -> ClaudeCreds? {
        if case .success(let creds) = await refreshManagedCredentialsDetailed(configDir: configDir) {
            return creds
        }
        return nil
    }

    static func refreshManagedCredentialsDetailed(configDir: URL) async -> RefreshOutcome {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        // Re-read file under gate so concurrent multi-account polls see latest write.
        guard let data = try? Data(contentsOf: path),
              let creds = parseCredentialsJSON(data),
              let refresh = creds.refreshToken, !refresh.isEmpty
        else { return .skipped }

        // Global gate: serialize token-endpoint traffic across all Claude accounts.
        if let waitUntil = await refreshGate.blockIfCooling() {
            return .rateLimited(waitUntil)
        }
        await refreshGate.noteAttempt(gap: globalRefreshMinGap)

        // Fresh read after waiting — another account's poll may have finished.
        guard let data = try? Data(contentsOf: path),
              let creds = parseCredentialsJSON(data),
              let refresh = creds.refreshToken, !refresh.isEmpty
        else { return .skipped }

        // If file was refreshed by another of our polls while we waited, skip POST.
        if !isExpired(creds) && !shouldRefresh(creds) {
            return .success(creds)
        }

        let form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", oauthClientID),
        ]
        let body = form
            .map { "\($0.0)=\(formEncode($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)

        var lastStatus = 0
        for tokenURL in oauthTokenURLs {
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(cliUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 12
            req.httpBody = body

            do {
                let (respData, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    continue
                }
                lastStatus = http.statusCode
                switch http.statusCode {
                case 200..<300:
                    guard let updated = applyRefreshedToken(existingJSON: data, responseJSON: respData),
                          let next = parseCredentialsJSON(updated)
                    else {
                        await refreshGate.noteAttempt(gap: globalRefreshMinGap)
                        return .unavailable("token refresh parse failed")
                    }
                    try? updated.write(to: path, options: .atomic)
                    await refreshGate.noteAttempt(gap: globalRefreshMinGap)
                    return .success(next)
                case 429:
                    let retry = retryAfterDate(from: http)
                        ?? Date().addingTimeInterval(globalRefresh429Quiet)
                    await refreshGate.noteRateLimited(until: retry)
                    NSLog("DashIsland: Claude refresh HTTP 429 (global quiet)")
                    return .rateLimited(retry)
                case 400, 401, 403:
                    // Try next host only on 404-ish; auth errors are terminal for this token.
                    await refreshGate.noteAttempt(gap: globalRefreshMinGap)
                    let errBody = String(data: respData, encoding: .utf8) ?? ""
                    NSLog(
                        "DashIsland: Claude refresh rejected HTTP %d %@ %@",
                        http.statusCode,
                        tokenURL.host ?? "",
                        errBody
                    )
                    return .rejected
                default:
                    NSLog(
                        "DashIsland: Claude refresh HTTP %d host=%@",
                        http.statusCode,
                        tokenURL.host ?? ""
                    )
                    continue
                }
            } catch {
                NSLog(
                    "DashIsland: Claude refresh failed host=%@ %@",
                    tokenURL.host ?? "",
                    error.localizedDescription
                )
                continue
            }
        }
        await refreshGate.noteAttempt(gap: globalRefreshMinGap)
        if lastStatus > 0 {
            return .unavailable("token refresh HTTP \(lastStatus)")
        }
        return .unavailable("token refresh: network error")
    }

    /// Merge token-endpoint JSON into stored credentials blob. Exposed for tests.
    static func applyRefreshedToken(existingJSON: Data, responseJSON: Data, now: Date = Date()) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: existingJSON) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let resp = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              let access = resp["access_token"] as? String,
              !access.isEmpty
        else { return nil }

        oauth["accessToken"] = access
        if let expiresIn = resp["expires_in"] as? Double {
            oauth["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        } else if let expiresIn = resp["expires_in"] as? Int {
            oauth["expiresAt"] = Int((now.timeIntervalSince1970 + Double(expiresIn)) * 1000)
        }
        if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
            oauth["refreshToken"] = newRefresh
        }
        if let scope = resp["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Write app-owned credentials file.
    static func persistCredentialsFile(
        creds: ClaudeCreds,
        configDir: URL,
        overwrite: Bool = false
    ) {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        if !overwrite, FileManager.default.fileExists(atPath: path.path) {
            return
        }
        if let raw = creds.rawJSON {
            try? raw.write(to: path, options: .atomic)
            return
        }
        var oauth: [String: Any] = ["accessToken": creds.accessToken]
        if let refresh = creds.refreshToken {
            oauth["refreshToken"] = refresh
        }
        if let plan = creds.subscriptionType {
            oauth["subscriptionType"] = plan
        }
        if let exp = creds.expiresAt {
            oauth["expiresAt"] = Int(exp.timeIntervalSince1970 * 1000)
        }
        if creds.longLived {
            oauth["dashIslandLongLived"] = true
        }
        let blob: [String: Any] = ["claudeAiOauth": oauth]
        if let data = try? JSONSerialization.data(withJSONObject: blob, options: [.prettyPrinted]) {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// Decode Claude Code credential JSON (`claudeAiOauth.accessToken`, …).
    static func parseCredentialsJSON(_ data: Data) -> ClaudeCreds? {
        guard let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = blob["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty
        else { return nil }
        let refresh = oauth["refreshToken"] as? String
        let flagged = (oauth["dashIslandLongLived"] as? Bool) == true
        var creds = ClaudeCreds(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            subscriptionType: oauth["subscriptionType"] as? String,
            expiresAt: parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"]),
            longLived: flagged,
            rawJSON: data
        )
        // Infer long-lived after parse (setup-token paste without flag).
        if !creds.longLived, isLongLived(creds) {
            creds.longLived = true
        }
        return creds
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Claude Code writes `expiresAt` as epoch **milliseconds**.
    static func parseExpiresAt(_ value: Any?) -> Date? {
        if let n = value as? Double {
            let seconds = n > 1e12 ? n / 1000 : n
            return Date(timeIntervalSince1970: seconds)
        }
        if let n = value as? Int {
            let seconds = n > 1_000_000_000_000 ? Double(n) / 1000 : Double(n)
            return Date(timeIntervalSince1970: seconds)
        }
        if let n = value as? Int64 {
            let seconds = n > 1_000_000_000_000 ? Double(n) / 1000 : Double(n)
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Claude Code 2.1+ scopes Keychain as
    /// `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>`.
    /// Used only for login capture + reauth wipe — not for polling.
    static func scopedKeychainService(for configDir: URL) -> String {
        let path = configDir.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let suffix = String(hex.prefix(8))
        return "\(keychainServiceBase)-\(suffix)"
    }

    private static func deleteScopedKeychainItem(configDir: URL) {
        let service = scopedKeychainService(for: configDir)
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-shot read during login only. Never used for usage polling.
    private static func readScopedKeychainCredentials(configDir: URL) -> ClaudeCreds? {
        let service = scopedKeychainService(for: configDir)
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return parseCredentialsJSON(data)
    }

    // MARK: - Usage HTTP

    static func probeUsage(token: String, plan: String?, fetchedAt: Date) async -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic gates this endpoint on a CLI User-Agent.
        req.setValue(cliUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return errorSnapshot(.network("bad response"), fetchedAt: fetchedAt)
            }
            switch http.statusCode {
            case 200:
                break
            case 401:
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case 403:
                // Scope insufficient (e.g. missing user:profile) — only fresh login helps.
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case 429:
                let retry = retryAfterDate(from: http)
                return errorSnapshot(.rateLimited(retryAfter: retry), fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: fetchedAt)
            }

            // 200 body may still be a rate_limit_error.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let type = err["type"] as? String,
               type == "rate_limit_error"
            {
                return errorSnapshot(.rateLimited(retryAfter: nil), fetchedAt: fetchedAt)
            }

            return parseUsageResponse(data: data, plan: plan, fetchedAt: fetchedAt)
        } catch {
            return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    /// Parse `/api/oauth/usage` JSON → snapshot. Exposed for unit tests.
    ///
    /// Maps `five_hour` + `seven_day` rings, plus active model-scoped rows from
    /// `limits[]` (e.g. Fable `weekly_scoped`) as hover-only `extras`.
    static func parseUsageResponse(data: Data, plan: String?, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        let primary = parseWindow(obj["five_hour"], kind: .fiveHour)
        let secondary: WindowUsage? = {
            guard obj["seven_day"] != nil else { return nil }
            return parseWindow(obj["seven_day"], kind: .weekly)
        }()
        let extras = parseScopedLimitExtras(obj["limits"])
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extras: extras,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    /// Model-scoped weekly limits from `limits[]` (Orca / current Anthropic shape).
    /// Only `weekly_scoped` with a model display name and finite percent; skip
    /// inactive rows. Does not replace primary/secondary rings.
    static func parseScopedLimitExtras(_ raw: Any?) -> [WindowUsage] {
        guard let rows = raw as? [Any] else { return [] }
        var out: [WindowUsage] = []
        var seen = Set<String>()
        for row in rows {
            guard let d = row as? [String: Any] else { continue }
            let kind = (d["kind"] as? String)?.lowercased() ?? ""
            guard kind == "weekly_scoped" else { continue }
            if let active = d["is_active"] as? Bool, active == false { continue }
            let name = scopedModelDisplayName(d)
            guard let name, !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            guard let percent = jsonNumber(d["percent"]) ?? jsonNumber(d["utilization"]) else {
                continue
            }
            guard percent.isFinite else { continue }
            let fraction = min(1, max(0, percent / 100.0))
            let resetAt = parseResetsAt(d["resets_at"])
            seen.insert(key)
            out.append(
                WindowUsage(
                    usedFraction: fraction,
                    resetAt: resetAt,
                    kind: .weekly,
                    labelOverride: name
                )
            )
        }
        return out
    }

    private static func scopedModelDisplayName(_ d: [String: Any]) -> String? {
        if let scope = d["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String,
           !name.isEmpty
        {
            return name
        }
        if let name = d["display_name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    /// Anthropic returns `utilization` / `used_percentage` in [0, 100] (may be fractional).
    /// Prefer absolute token counters when present — finer burn Δ than whole-percent ticks.
    static func parseWindow(_ obj: Any?, kind: UsageWindowKind) -> WindowUsage {
        guard let d = obj as? [String: Any] else {
            return WindowUsage(usedFraction: 0, kind: kind)
        }
        let usedTok = jsonInt64(d["used_tokens"])
            ?? jsonInt64(d["tokens_used"])
            ?? jsonInt64(d["used"])
        let limitTok = jsonInt64(d["limit_tokens"])
            ?? jsonInt64(d["tokens_limit"])
            ?? jsonInt64(d["limit"])
        let raw = jsonNumber(d["utilization"])
            ?? jsonNumber(d["used_percentage"])
            ?? jsonNumber(d["used_percent"])
            ?? 0
        // API percent is always [0, 100] (0.5 = half a percent, not 50%).
        let fromPercent = raw / 100.0
        let fromAbs: Double? = {
            guard let u = usedTok, let lim = limitTok, lim > 0 else { return nil }
            return min(1, max(0, Double(u) / Double(lim)))
        }()
        let normalized = min(1, max(0, fromAbs ?? fromPercent))
        let resetAt = parseResetsAt(d["resets_at"])
        return WindowUsage(
            usedFraction: normalized,
            resetAt: resetAt,
            usedTokens: usedTok,
            limitTokens: limitTok,
            kind: kind
        )
    }

    static func jsonInt64(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return max(0, i) }
        if let i = value as? Int { return max(0, Int64(i)) }
        if let d = value as? Double, d.isFinite { return max(0, Int64(d.rounded())) }
        if let n = value as? NSNumber { return max(0, n.int64Value) }
        if let s = value as? String, let d = Double(s) { return max(0, Int64(d.rounded())) }
        return nil
    }

    /// JSONSerialization may box numbers as Int / Double / NSNumber.
    static func jsonNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let i = value as? Int64 { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    static func parseResetsAt(_ value: Any?) -> Date? {
        if let r = value as? Double {
            // ms vs sec heuristic
            let seconds = r > 1e12 ? r / 1000 : r
            return Date(timeIntervalSince1970: seconds)
        }
        if let r = value as? Int {
            let seconds = r > 1_000_000_000_000 ? Double(r) / 1000 : Double(r)
            return Date(timeIntervalSince1970: seconds)
        }
        if let s = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: s) { return d }
            // Some payloads use `+00:00` without a timezone form plain accepts.
            let zulu = s
                .replacingOccurrences(of: "+00:00", with: "Z")
                .replacingOccurrences(of: "+0000", with: "Z")
            if let d = fractional.date(from: zulu) { return d }
            return plain.date(from: zulu)
        }
        return nil
    }

    private static func retryAfterDate(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    private static func errorSnapshot(_ error: UsageError, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            secondary: nil,
            plan: nil,
            fetchedAt: fetchedAt,
            error: error
        )
    }

    // MARK: - CLI locate

    /// Common install locations (LaunchServices PATH is too stripped for `which`).
    static func locateClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}

// MARK: - Process-wide Claude OAuth refresh gate

/// Prevents multi-account polls from stampeding `platform.claude.com/v1/oauth/token`.
private actor ClaudeRefreshGate {
    private var nextAllowedAt: Date = .distantPast

    /// `nil` = may refresh now; otherwise wait until this date.
    func blockIfCooling(now: Date = Date()) -> Date? {
        if now < nextAllowedAt { return nextAllowedAt }
        return nil
    }

    func noteAttempt(gap: TimeInterval, now: Date = Date()) {
        nextAllowedAt = max(nextAllowedAt, now.addingTimeInterval(gap))
    }

    func noteRateLimited(until: Date) {
        nextAllowedAt = max(nextAllowedAt, until)
    }
}
