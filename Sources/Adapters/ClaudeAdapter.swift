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
            Claude login finished but no credentials file appeared. The CLI stores \
            tokens in macOS Keychain; allow Keychain access once so Dash can copy \
            them into this account folder, or run:

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
/// `accounts/<uuid>/.credentials.json`. Poll and refresh never touch Keychain.
/// Claude CLI on macOS writes login tokens to a *scoped* Keychain item only;
/// we copy that item into the file once after Add/Reauth, then leave Keychain alone.
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
            do {
                try await runLogin(configDir: dir)
                // H2: browser add used to markAuthenticated on harvest alone.
                try await Self.verifyUsageAccess(configDir: dir)
                let creds = try Self.requireCredentials(configDir: dir)
                let short = String(ref.prefix(8))
                let label = Self.suggestedLabel(plan: creds.subscriptionType, short: short)
                return AddAccountResult(vendorID: id, label: label, credentialRef: ref)
            } catch {
                Self.clearManagedCredentials(configDir: dir)
                try? CredentialStore.removeDirectory(for: ref)
                throw error
            }
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
            do {
                try Self.installSetupToken(rawToken, configDir: dir)
                try await Self.verifyUsageAccess(configDir: dir)
                let short = String(ref.prefix(8))
                return AddAccountResult(
                    vendorID: id,
                    label: "Claude \(short)",
                    credentialRef: ref
                )
            } catch {
                Self.clearManagedCredentials(configDir: dir)
                try? CredentialStore.removeDirectory(for: ref)
                throw error
            }
        } catch {
            try? CredentialStore.removeDirectory(for: ref)
            throw error
        }
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            // Snapshot first. Claude CLI on macOS keeps the live session in
            // scoped Keychain; deleting only .credentials.json lets `auth login`
            // reopen a browser and immediately succeed with the old token.
            let prior = Self.existingCredentials(configDir: dir)
            Self.clearManagedCredentials(configDir: dir)
            await Self.runLogout(configDir: dir)
            try await runLogin(
                configDir: dir,
                priorAccessToken: prior?.accessToken,
                priorRefreshToken: prior?.refreshToken
            )
            // H2: leftover-but-valid harvest used to skip /api/oauth/usage.
            try await Self.verifyUsageAccess(configDir: dir)
            _ = try Self.requireCredentials(configDir: dir)
            return ref
        } catch {
            // Smoke-rejected or failed harvest must not stay as the live file.
            Self.clearManagedCredentials(configDir: dir)
            if let error = error as? ClaudeAdapterError { throw error }
            throw ClaudeAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    /// Replace managed creds with a pasted token (smoke-tested against usage API).
    func reauthenticateWithSetupToken(_ ref: CredentialRef, token: String) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            Self.clearManagedCredentials(configDir: dir)
            try Self.installSetupToken(token, configDir: dir)
            try await Self.verifyUsageAccess(configDir: dir)
            return ref
        } catch {
            Self.clearManagedCredentials(configDir: dir)
            throw error
        }
    }

    /// Pure policy for the usage smoke test (browser add/reauth + setup-token).
    /// 200 → pass; 401/403 (`authRequired`) → reject; 429/network/parse → soft keep.
    enum UsageSmokeDecision: Equatable {
        case pass
        case reject
        case softKeep
    }

    static func usageSmokeDecision(_ snapshot: UsageSnapshot) -> UsageSmokeDecision {
        guard let err = snapshot.error else { return .pass }
        switch err {
        case .authRequired:
            return .reject
        case .rateLimited, .network, .parse, .unavailable:
            return .softKeep
        }
    }

    /// Hit `/api/oauth/usage` once so leftover / scope-deficient tokens fail at login time.
    static func verifyUsageAccess(configDir: URL) async throws {
        guard let creds = readCredentials(configDir: configDir) else {
            throw ClaudeAdapterError.reauthFailed("No credentials written.")
        }
        let snap = await probeUsage(
            token: creds.accessToken,
            plan: creds.subscriptionType,
            fetchedAt: Date()
        )
        switch usageSmokeDecision(snap) {
        case .pass:
            return
        case .softKeep:
            if case .rateLimited = snap.error {
                NSLog("DashIsland: Claude token smoke-test rate-limited (keeping)")
            } else {
                NSLog("DashIsland: Claude token smoke-test soft error %@", String(describing: snap.error))
            }
        case .reject:
            throw ClaudeAdapterError.reauthFailed(
                """
                Token rejected by Anthropic (invalid or missing scopes).
                `claude setup-token` usually cannot read usage — it lacks user:profile.
                Use Reauthenticate → browser login instead:
                  CLAUDE_CONFIG_DIR='\(configDir.path)' claude auth login --claudeai
                """
            )
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)

        // Steady-state is the managed file. Keychain is login/ping only —
        // polling it every cycle triggers the macOS password dialog.
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

        // --- Short-lived CLI OAuth (managed file only) ---
        // Orca/Hermes lesson: local expiresAt is advisory. Always probe usage first
        // and only touch single-use refresh after an authoritative 401/403.
        // File-only adopt-before-refresh: if a CLI already rotated this managed
        // dir's .credentials.json, adopt it and skip oauth/token.

        var snap = await Self.probeUsage(
            token: creds.accessToken,
            plan: creds.subscriptionType,
            fetchedAt: now
        )
        guard Self.shouldAttemptRefresh(after: snap.error, credentials: creds, now: now) else {
            return Self.logUsage(snap, ref: ref)
        }

        snap = await Self.refreshThenProbe(
            configDir: dir,
            ref: ref,
            failedAccessToken: creds.accessToken,
            fallback: snap
        )
        return Self.logUsage(snap, ref: ref)
    }

    /// Gated recover + re-probe. Soft outcomes keep orchestrator last-good rings.
    /// This managed dir is ours: extend from the file's refresh_token via
    /// oauth/token. Do **not** spawn `claude -p` on the poll path — that hits
    /// Keychain and pops a password sheet every expiry.
    private static func refreshThenProbe(
        configDir: URL,
        ref: CredentialRef,
        failedAccessToken: String?,
        fallback: UsageSnapshot
    ) async -> UsageSnapshot {
        switch await refreshManagedCredentialsDetailed(
            configDir: configDir,
            failedAccessToken: failedAccessToken
        ) {
        case .success(let refreshed), .adopted(let refreshed):
            NSLog("DashIsland: Claude recovery ok ref=%@", String(ref.prefix(8)))
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

    /// Unused on the poll path (Keychain spam). Kept for tests / last-resort.
    static var refreshPingSpawner: ((URL) -> Bool)?

    static func pingCLIThenAdopt(
        configDir: URL,
        failedAccessToken: String?
    ) async -> ClaudeCreds? {
        let expired = readCredentials(configDir: configDir)
            .map { isExpired($0) } ?? true
        // Access ~8h; CLI login is not. Dead access retries every 15m, not 6h.
        let gap: TimeInterval = expired ? 15 * 60 : 6 * 3600
        if pingRecentlyAttempted(configDir: configDir, gap: gap) { return nil }
        markPingAttempted(configDir: configDir)
        let before = readCredentialsFile(configDir: configDir)?.accessToken
        let spawned: Bool
        if let refreshPingSpawner {
            spawned = refreshPingSpawner(configDir)
        } else {
            spawned = await spawnManagedRefreshPing(configDir: configDir)
        }
        guard spawned else { return nil }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let file = readCredentialsFile(configDir: configDir),
               !file.accessToken.isEmpty,
               file.accessToken != failedAccessToken,
               file.accessToken != before
            {
                return file
            }
        }
        if let file = readCredentialsFile(configDir: configDir),
           shouldAdopt(file, failedAccessToken: failedAccessToken)
        {
            return file
        }
        return nil
    }

    private static func pingDefaultsKey(configDir: URL) -> String {
        "DashIsland.ClaudeCLIPing.\(configDir.path)"
    }

    static func pingRecentlyAttempted(
        configDir: URL,
        now: Date = Date(),
        gap: TimeInterval = 6 * 3600
    ) -> Bool {
        let t = UserDefaults.standard.double(forKey: pingDefaultsKey(configDir: configDir))
        guard t > 0 else { return false }
        return now.timeIntervalSince(Date(timeIntervalSince1970: t)) < gap
    }

    static func markPingAttempted(configDir: URL, now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: pingDefaultsKey(configDir: configDir))
    }

    /// Hidden `claude -p ok --model haiku` with this account's CLAUDE_CONFIG_DIR.
    /// No Terminal window — the CLI refreshes and writes the scoped store.
    static func spawnManagedRefreshPing(configDir: URL) async -> Bool {
        guard let path = locateClaudeBinary() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-p", "ok", "--model", "haiku", "--strict-mcp-config"]
        task.currentDirectoryPath = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            env.removeValue(forKey: key)
        }
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("DashIsland: Claude CLI ping failed %@", error.localizedDescription)
            return false
        }
        let deadline = Date().addingTimeInterval(45)
        while task.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if task.isRunning { task.terminate() }
        NSLog("DashIsland: Claude CLI ping finished dir=%@", configDir.path)
        return true
    }

    private static func logUsage(_ snap: UsageSnapshot, ref: CredentialRef) -> UsageSnapshot {
        if snap.error == nil {
            let p = Int((snap.primary.usedFraction * 100).rounded())
            let w = Int(((snap.secondary?.usedFraction ?? 0) * 100).rounded())
            let t = snap.tertiary.map { Int(($0.usedFraction * 100).rounded()) }
            let tLabel = snap.tertiary?.displayLabel ?? "-"
            let extraN = snap.extras.count
            NSLog(
                "DashIsland: Claude usage ok ref=%@ 5h=%d%% wk=%d%% tert=%@ %d%% extras=%d",
                String(ref.prefix(8)), p, w, tLabel, t ?? -1, extraN
            )
        } else if let err = snap.error {
            NSLog("DashIsland: Claude usage error ref=%@ %@", String(ref.prefix(8)), String(describing: err))
        }
        return snap
    }

    // MARK: - Login (managed CLAUDE_CONFIG_DIR)

    /// Wipe app-owned session so the next `claude auth login` cannot succeed
    /// on leftover state. Deletes the managed file, last-good rings, and this
    /// folder's scoped Keychain item only (never the user's default
    /// `Claude Code-credentials`).
    static func clearManagedCredentials(configDir: URL) {
        let credFile = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: credFile)
        CredentialStore.removeLastGoodUsage(inDirectory: configDir)
        deleteScopedKeychainItem(configDir: configDir)
        NSLog("DashIsland: cleared Claude managed creds at %@", configDir.path)
    }

    /// Best-effort CLI logout so the next login cannot reuse the scoped session.
    static func runLogout(configDir: URL) async {
        guard let binary = locateClaudeBinary() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["auth", "logout"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        task.standardInput = Pipe()
        do {
            try task.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(8)
        while task.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if task.isRunning { task.terminate() }
    }

    /// File only. Keychain harvest is login-when-file-missing, never a poll.
    static func existingCredentials(configDir: URL) -> ClaudeCreds? {
        if let file = readCredentialsFile(configDir: configDir), !file.accessToken.isEmpty {
            return file
        }
        return nil
    }

    static func existingAccessToken(configDir: URL) -> String? {
        existingCredentials(configDir: configDir)?.accessToken
    }

    /// Reauth must mint a *new session*. Leftover CLI sessions often rotate
    /// `accessToken` while keeping the same `refreshToken` (H1).
    /// `priorAccessToken == nil` (beginAdd) still accepts any non-empty harvest.
    static func isAcceptableLogin(
        _ creds: ClaudeCreds,
        priorAccessToken: String?,
        priorRefreshToken: String? = nil
    ) -> Bool {
        guard !creds.accessToken.isEmpty else { return false }
        if let priorAccessToken, !priorAccessToken.isEmpty,
           creds.accessToken == priorAccessToken
        {
            return false
        }
        if let priorRefreshToken, !priorRefreshToken.isEmpty,
           let harvested = creds.refreshToken, harvested == priorRefreshToken
        {
            return false
        }
        return true
    }

    private func runLogin(
        configDir: URL,
        priorAccessToken: String? = nil,
        priorRefreshToken: String? = nil
    ) async throws {
        guard let binary = Self.locateClaudeBinary() else {
            throw ClaudeAdapterError.claudeBinaryNotFound
        }

        let prior = Self.existingCredentials(configDir: configDir)
        let priorToken = priorAccessToken ?? prior?.accessToken
        let priorRefresh = priorRefreshToken ?? prior?.refreshToken

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
        var allowKeychainPrompt = true

        func isAcceptable(_ creds: ClaudeCreds) -> Bool {
            Self.isAcceptableLogin(
                creds,
                priorAccessToken: priorToken,
                priorRefreshToken: priorRefresh
            )
        }

        while Date() < deadline {
            if Task.isCancelled {
                if task.isRunning { task.terminate() }
                throw CancellationError()
            }
            if let creds = Self.captureLoginCredentials(
                configDir: configDir,
                allowKeychainPrompt: allowKeychainPrompt
            ), isAcceptable(creds) {
                Self.persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning {
                    task.terminate()
                }
                return
            }
            allowKeychainPrompt = false
            if !task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let creds = Self.captureLoginCredentials(
                    configDir: configDir,
                    allowKeychainPrompt: false
                ), isAcceptable(creds) {
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
        if let creds = Self.captureLoginCredentials(
            configDir: configDir,
            allowKeychainPrompt: false
        ), isAcceptable(creds) {
            Self.persistCredentialsFile(creds: creds, configDir: configDir, overwrite: true)
            return
        }
        throw ClaudeAdapterError.loginTimeout(configDir: configDir.path)
    }

    /// File only. Do not re-harvest Keychain here — that would persist a leftover
    /// session that `runLogin` already rejected (H10).
    static func requireCredentials(configDir: URL) throws -> ClaudeCreds {
        if let creds = readCredentials(configDir: configDir) {
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

    /// Steady-state: managed file only.
    static func readCredentials(configDir: URL) -> ClaudeCreds? {
        readCredentialsFile(configDir: configDir)
    }

    static func readCredentialsFile(configDir: URL) -> ClaudeCreds? {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// File first. Keychain only on interactive login when the file is missing.
    static func captureLoginCredentials(
        configDir: URL,
        allowKeychainPrompt: Bool = false
    ) -> ClaudeCreds? {
        if let file = readCredentialsFile(configDir: configDir) {
            return file
        }
        guard allowKeychainPrompt else { return nil }
        return readScopedKeychainCredentials(
            configDir: configDir,
            allowPrompt: true
        )
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

    /// Prefer always probing (usage server is source of truth). Kept for callers/tests.
    static func shouldProbeBeforeRefresh(_ creds: ClaudeCreds, now: Date = Date()) -> Bool {
        if isLongLived(creds) { return true }
        return !creds.accessToken.isEmpty
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

    /// Refresh only after usage 401/403 — never because local expiresAt says so.
    static func shouldAttemptRefresh(
        after error: UsageError?,
        credentials: ClaudeCreds,
        now: Date = Date()
    ) -> Bool {
        guard case .authRequired = error else { return false }
        return canAttemptRefresh(credentials, now: now)
    }

    /// Managed-file adopt: access token rotated since the failed probe.
    static func shouldAdopt(_ creds: ClaudeCreds, failedAccessToken: String?) -> Bool {
        guard let failedAccessToken, !failedAccessToken.isEmpty else { return false }
        return creds.accessToken != failedAccessToken
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
        /// Managed file already has a newer access token (CLI rotated it).
        case adopted(ClaudeCreds)
        case skipped
        case rateLimited(Date?)
        case rejected
        case unavailable(String)
    }

    /// Refresh this account's managed file only. Rotates refresh_token when the
    /// server returns a new one (single-use — must persist atomically).
    /// Multi-account isolation is path-based.
    static func refreshManagedCredentials(configDir: URL) async -> ClaudeCreds? {
        switch await refreshManagedCredentialsDetailed(configDir: configDir) {
        case .success(let creds), .adopted(let creds):
            return creds
        default:
            return nil
        }
    }

    static func refreshManagedCredentialsDetailed(
        configDir: URL,
        failedAccessToken: String? = nil
    ) async -> RefreshOutcome {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let creds = parseCredentialsJSON(data)
        else { return .skipped }

        // File-only adopt-before-refresh: if this managed file already rotated, skip POST.
        if shouldAdopt(creds, failedAccessToken: failedAccessToken) {
            return .adopted(creds)
        }
        guard let refresh = creds.refreshToken, !refresh.isEmpty else { return .skipped }
        if failedAccessToken == nil, !isExpired(creds), !shouldRefresh(creds) {
            return .success(creds)
        }

        // Atomic reserve: check + book the gap so two accounts cannot double-POST.
        if let waitUntil = await refreshGate.reserveAttempt(gap: globalRefreshMinGap) {
            return .rateLimited(waitUntil)
        }

        // Fresh read after waiting — another poll may have healed the file.
        guard let data = try? Data(contentsOf: path),
              let creds = parseCredentialsJSON(data)
        else { return .skipped }

        if shouldAdopt(creds, failedAccessToken: failedAccessToken) {
            return .adopted(creds)
        }
        guard let refresh = creds.refreshToken, !refresh.isEmpty else { return .skipped }
        if failedAccessToken == nil, !isExpired(creds), !shouldRefresh(creds) {
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
    /// Login harvest only — never used for usage polling.
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-shot read after `claude auth login`. Polls pass `allowPrompt: false`
    /// so Keychain never puts up the password sheet on a timer.
    private static func readScopedKeychainCredentials(
        configDir: URL,
        allowPrompt: Bool
    ) -> ClaudeCreds? {
        let service = scopedKeychainService(for: configDir)
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: allowPrompt
                ? kSecUseAuthenticationUIAllow
                : kSecUseAuthenticationUIFail,
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
    /// Maps `five_hour` + `seven_day` rings; promotes Fable (or first scoped
    /// model limit) to the tertiary ring; remaining scopes stay hover-only.
    static func parseUsageResponse(data: Data, plan: String?, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        let primary = parseWindow(obj["five_hour"], kind: .fiveHour)
        let secondary: WindowUsage? = {
            guard obj["seven_day"] != nil else { return nil }
            return parseWindow(obj["seven_day"], kind: .weekly)
        }()
        let scoped = parseScopedLimitExtras(obj["limits"])
        let tertiary = UsageRingLayout.preferredTertiary(from: scoped)
        let extras = UsageRingLayout.remainingExtras(extras: scoped, tertiary: tertiary)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extras: extras,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    /// Model-scoped weekly limits from `limits[]` (Orca / current Anthropic shape).
    ///
    /// `is_active` only marks the *currently binding* limit — inactive Fable rows
    /// still carry a real percent/resets_at (live Max accounts often send
    /// `is_active: false` with `display_name: Fable`). Do **not** drop them.
    static func parseScopedLimitExtras(_ raw: Any?) -> [WindowUsage] {
        guard let rows = raw as? [Any] else { return [] }
        var out: [WindowUsage] = []
        var seen = Set<String>()
        for row in rows {
            guard let d = row as? [String: Any] else { continue }
            let kind = (d["kind"] as? String)?.lowercased() ?? ""
            guard kind == "weekly_scoped" else { continue }
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

/// Prevents multi-account polls from stampeding oauth/token.
/// Quiet window survives app restart via UserDefaults.
private actor ClaudeRefreshGate {
    private static let defaultsKey = "DashIsland.ClaudeRefreshNextAllowedAt"
    private let defaults: UserDefaults
    private var nextAllowedAt: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.defaultsKey)
        self.nextAllowedAt = stored > 0
            ? Date(timeIntervalSince1970: stored)
            : .distantPast
    }

    /// Atomically reserve one attempt. `nil` = reserved now; else wait until date.
    func reserveAttempt(gap: TimeInterval, now: Date = Date()) -> Date? {
        if now < nextAllowedAt { return nextAllowedAt }
        nextAllowedAt = max(nextAllowedAt, now.addingTimeInterval(gap))
        persist()
        return nil
    }

    /// Legacy name kept for any external callers.
    func blockIfCooling(now: Date = Date()) -> Date? {
        if now < nextAllowedAt { return nextAllowedAt }
        return nil
    }

    func noteAttempt(gap: TimeInterval, now: Date = Date()) {
        nextAllowedAt = max(nextAllowedAt, now.addingTimeInterval(gap))
        persist()
    }

    func noteRateLimited(until: Date) {
        nextAllowedAt = max(nextAllowedAt, until)
        persist()
    }

    private func persist() {
        defaults.set(nextAllowedAt.timeIntervalSince1970, forKey: Self.defaultsKey)
    }
}
