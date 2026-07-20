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
/// **Credentials:** after `claude auth login` we copy the access token into
/// `accounts/<uuid>/.credentials.json` and use **only that file** for polls.
/// We never call Anthropic's OAuth refresh (token rotation races the CLI) and
/// we never read the macOS Keychain on the hot path. Scoped keychain is
/// touched only once after login (seed the file) and on reauth wipe (so the
/// CLI does not short-circuit on its own leftover item).
struct ClaudeAdapter: VendorAdapter {
    let id: VendorID = "claude"
    let displayName = "Claude"
    let minPollSeconds = 300

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let credentialsFileName = ".credentials.json"
    private static let loginTimeout: TimeInterval = 180
    private static let pollNanos: UInt64 = 1_000_000_000
    private static let cliUserAgent = "claude-code/2.1.121"
    private static let betaHeader = "oauth-2025-04-20"
    private static let keychainServiceBase = "Claude Code-credentials"

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

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        // Hot path: managed file only — no Keychain.
        guard let creds = Self.readCredentials(configDir: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        // Local expiry is advisory — still probe when slightly stale metadata,
        // but hard-stop when clearly past expiry so we do not 401-spam.
        if let exp = creds.expiresAt, exp.timeIntervalSince(now) < -60 {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        var snap = await Self.probeUsage(
            token: creds.accessToken,
            plan: creds.subscriptionType,
            fetchedAt: now
        )
        if snap.error == nil,
           let exp = creds.expiresAt,
           exp.timeIntervalSince(now) > 0,
           exp.timeIntervalSince(now) < 2 * 3600
        {
            let mins = Int(exp.timeIntervalSince(now) / 60)
            snap.notice = mins < 60
                ? "token expires in \(max(1, mins))m — reauth soon"
                : "token expires in \(mins / 60)h — reauth soon"
        }
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
        var subscriptionType: String?
        /// Access-token expiry when known (Claude stores epoch **milliseconds**).
        var expiresAt: Date?
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

    /// Write app-owned credentials file (not an OAuth refresh — just capture).
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
        if let plan = creds.subscriptionType {
            oauth["subscriptionType"] = plan
        }
        if let exp = creds.expiresAt {
            oauth["expiresAt"] = Int(exp.timeIntervalSince1970 * 1000)
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
        return ClaudeCreds(
            accessToken: access,
            subscriptionType: oauth["subscriptionType"] as? String,
            expiresAt: parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"]),
            rawJSON: data
        )
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

    /// Anthropic returns `utilization` as a percentage in [0, 100] — always ÷100.
    static func parseWindow(_ obj: Any?, kind: UsageWindowKind) -> WindowUsage {
        guard let d = obj as? [String: Any] else {
            return WindowUsage(usedFraction: 0, kind: kind)
        }
        let raw = jsonNumber(d["utilization"])
            ?? jsonNumber(d["used_percent"])
            ?? 0
        let normalized = min(1, max(0, raw / 100.0))
        let resetAt = parseResetsAt(d["resets_at"])
        return WindowUsage(
            usedFraction: normalized,
            resetAt: resetAt,
            usedTokens: nil,
            limitTokens: nil,
            kind: kind
        )
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
