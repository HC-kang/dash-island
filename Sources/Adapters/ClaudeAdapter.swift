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
/// **Credentials:** per-account folder under Application Support
/// (`accounts/<uuid>/` as `CLAUDE_CONFIG_DIR`). Tokens are READ-ONLY —
/// never call the OAuth refresh endpoint (Anthropic rotates refresh tokens;
/// dual-refresh invalidates the CLI login). Managed folder is app-owned for
/// multi-account isolation; the default Claude keychain service is never written.
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
        let dir = try CredentialStore.createDirectory(for: ref)
        try await runLogin(configDir: dir)
        let creds = try Self.requireCredentials(configDir: dir)
        let short = String(ref.prefix(8))
        let label = Self.suggestedLabel(plan: creds.subscriptionType, short: short)
        return AddAccountResult(vendorID: id, label: label, credentialRef: ref)
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            try await runLogin(configDir: dir)
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
        guard let creds = Self.readCredentials(configDir: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        return await Self.probeUsage(token: creds.accessToken, plan: creds.subscriptionType, fetchedAt: now)
    }

    // MARK: - Login (managed CLAUDE_CONFIG_DIR)

    private func runLogin(configDir: URL) async throws {
        guard let binary = Self.locateClaudeBinary() else {
            throw ClaudeAdapterError.claudeBinaryNotFound
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        // `--claudeai` selects subscription OAuth (required for /api/oauth/usage).
        task.arguments = ["auth", "login", "--claudeai"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        // Avoid inheriting a parent CLAUDE_CODE_OAUTH_TOKEN that would skip file login.
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
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

        let deadline = Date().addingTimeInterval(Self.loginTimeout)
        while Date() < deadline {
            if let creds = Self.readCredentials(configDir: configDir) {
                // Persist into the managed folder so later polls are file-based.
                Self.persistCredentialsFile(creds: creds, configDir: configDir)
                // Give the CLI a moment to finish writing, then stop it if still up.
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning {
                    task.terminate()
                }
                return
            }
            if !task.isRunning {
                // Brief settle after exit, then re-check.
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let creds = Self.readCredentials(configDir: configDir) {
                    Self.persistCredentialsFile(creds: creds, configDir: configDir)
                    return
                }
                throw ClaudeAdapterError.credentialsMissing(configDir: configDir.path)
            }
            try? await Task.sleep(nanoseconds: Self.pollNanos)
        }

        if task.isRunning {
            task.terminate()
        }
        if let creds = Self.readCredentials(configDir: configDir) {
            Self.persistCredentialsFile(creds: creds, configDir: configDir)
            return
        }
        throw ClaudeAdapterError.loginTimeout(configDir: configDir.path)
    }

    private static func requireCredentials(configDir: URL) throws -> ClaudeCreds {
        if let creds = readCredentials(configDir: configDir) {
            persistCredentialsFile(creds: creds, configDir: configDir)
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

    // MARK: - Credential read (managed dir + scoped keychain only)

    struct ClaudeCreds: Equatable {
        var accessToken: String
        var subscriptionType: String?
        /// Raw JSON blob (for writing `.credentials.json` into the managed folder).
        var rawJSON: Data?
    }

    /// Prefer managed `.credentials.json`; fall back to Claude Code's
    /// CLAUDE_CONFIG_DIR-scoped keychain service. Never reads the unsuffixed
    /// default service (avoids racing / mixing the user's main CLI login).
    static func readCredentials(configDir: URL) -> ClaudeCreds? {
        if let file = readCredentialsFile(configDir: configDir) {
            return file
        }
        return readScopedKeychainCredentials(configDir: configDir)
    }

    static func readCredentialsFile(configDir: URL) -> ClaudeCreds? {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// Write app-owned credentials file (not an OAuth refresh — just capture).
    static func persistCredentialsFile(creds: ClaudeCreds, configDir: URL) {
        let path = configDir.appendingPathComponent(credentialsFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: path.path) {
            return
        }
        if let raw = creds.rawJSON {
            try? raw.write(to: path, options: .atomic)
            return
        }
        // Reconstruct minimal blob if we only have a token (unlikely for keychain path).
        var oauth: [String: Any] = ["accessToken": creds.accessToken]
        if let plan = creds.subscriptionType {
            oauth["subscriptionType"] = plan
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
            rawJSON: data
        )
    }

    /// Claude Code 2.1+ scopes Keychain service as
    /// `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>`.
    static func scopedKeychainService(for configDir: URL) -> String {
        let path = configDir.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let suffix = String(hex.prefix(8))
        return "\(keychainServiceBase)-\(suffix)"
    }

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
        guard status == errSecSuccess, let data = result as? Data else {
            return readScopedKeychainViaSecurityCLI(service: service, account: account)
        }
        return parseCredentialsJSON(data)
    }

    private static func readScopedKeychainViaSecurityCLI(service: String, account: String) -> ClaudeCreds? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty,
                let jsonData = raw.data(using: .utf8)
            else { return nil }
            return parseCredentialsJSON(jsonData)
        } catch {
            return nil
        }
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
    static func parseUsageResponse(data: Data, plan: String?, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        let primary = parseWindow(obj["five_hour"])
        let secondary = parseWindow(obj["seven_day"])
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    /// Anthropic returns `utilization` as a percentage in [0, 100] — always ÷100.
    static func parseWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else {
            return WindowUsage(usedFraction: 0, resetAt: nil, usedTokens: nil, limitTokens: nil)
        }
        let raw = (d["utilization"] as? Double)
            ?? (d["utilization"] as? Int).map(Double.init)
            ?? (d["used_percent"] as? Double)
            ?? 0
        let normalized = min(1, max(0, raw / 100.0))
        let resetAt = parseResetsAt(d["resets_at"])
        return WindowUsage(
            usedFraction: normalized,
            resetAt: resetAt,
            usedTokens: nil,
            limitTokens: nil
        )
    }

    static func parseResetsAt(_ value: Any?) -> Date? {
        if let r = value as? Double {
            return Date(timeIntervalSince1970: r)
        }
        if let r = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(r))
        }
        if let s = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
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
            primary: WindowUsage(usedFraction: 0, resetAt: nil, usedTokens: nil, limitTokens: nil),
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
