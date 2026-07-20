import Foundation

// MARK: - Errors

enum CodexAdapterError: Error, Equatable, LocalizedError {
    case codexBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(codexHome: String)
    case credentialsMissing(codexHome: String)
    case reauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexBinaryNotFound:
            return """
            Could not find the Codex CLI (`codex`). Install it, then either retry \
            or run login manually with CODEX_HOME pointed at the managed account folder.
            """
        case .spawnFailed(let message):
            return "Failed to start Codex login: \(message)"
        case .loginTimeout(let codexHome):
            return """
            Codex login timed out. Complete browser sign-in, or run manually:

              CODEX_HOME='\(codexHome)' codex login

            Then choose Reauthenticate (or remove and re-add).
            """
        case .credentialsMissing(let codexHome):
            return """
            Codex login finished but no auth.json was found. Run:

              CODEX_HOME='\(codexHome)' codex login
            """
        case .reauthFailed(let message):
            return message
        }
    }
}

// MARK: - Adapter

/// OpenAI Codex / ChatGPT usage via `/backend-api/wham/usage`.
///
/// **Credentials:** per-account folder under Application Support
/// (`accounts/<uuid>/` as `CODEX_HOME`). Auth lives at `$CODEX_HOME/auth.json`
/// (`tokens.access_token`). Codex CLI rotates tokens itself — we only read.
struct CodexAdapter: VendorAdapter {
    let id: VendorID = "codex"
    let displayName = "Codex"
    /// Gentler than Claude; endpoint is rarely rate-limited but stay polite.
    let minPollSeconds = 120

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authFileName = "auth.json"
    private static let loginTimeout: TimeInterval = 180
    private static let pollNanos: UInt64 = 1_000_000_000

    // MARK: VendorAdapter

    func beginAdd() async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        do {
            let dir = try CredentialStore.createDirectory(for: ref)
            try await runLogin(codexHome: dir)
            _ = try Self.requireCredentials(codexHome: dir)
            // Plan lives on the usage endpoint, not auth.json — label is vendor + short ref.
            let short = String(ref.prefix(8))
            let label = Self.suggestedLabel(plan: nil, short: short)
            return AddAccountResult(vendorID: id, label: label, credentialRef: ref)
        } catch {
            try? CredentialStore.removeDirectory(for: ref)
            throw error
        }
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            // Wipe first — existing auth.json makes runLogin return immediately.
            Self.clearManagedCredentials(codexHome: dir)
            try await runLogin(codexHome: dir)
            _ = try Self.requireCredentials(codexHome: dir)
            return ref
        } catch let error as CodexAdapterError {
            throw error
        } catch {
            throw CodexAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        guard let creds = Self.readCredentials(codexHome: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        return await Self.probeUsage(token: creds.accessToken, accountID: creds.accountID, fetchedAt: now)
    }

    // MARK: - Login (managed CODEX_HOME)

    static func clearManagedCredentials(codexHome: URL) {
        let fm = FileManager.default
        let paths = [
            codexHome.appendingPathComponent(authFileName, isDirectory: false),
            codexHome
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent(authFileName, isDirectory: false),
        ]
        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        NSLog("DashIsland: cleared Codex managed creds at %@", codexHome.path)
    }

    private func runLogin(codexHome: URL) async throws {
        guard let binary = Self.locateCodexBinary() else {
            throw CodexAdapterError.codexBinaryNotFound
        }

        let priorToken = Self.readCredentials(codexHome: codexHome)?.accessToken

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["login"]
        var env = ProcessInfo.processInfo.environment
        // Codex resolves config + auth under CODEX_HOME (default ~/.codex).
        env["CODEX_HOME"] = codexHome.path
        // Avoid env API keys bypassing file-based ChatGPT OAuth login.
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_API_KEY")
        env.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        // Keep stdin open so the CLI does not see immediate EOF.
        task.standardInput = Pipe()

        do {
            try task.run()
        } catch {
            throw CodexAdapterError.spawnFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.loginTimeout)

        func isAcceptable(_ creds: CodexCreds) -> Bool {
            if let priorToken, creds.accessToken == priorToken { return false }
            return !creds.accessToken.isEmpty
        }

        while Date() < deadline {
            if Task.isCancelled {
                if task.isRunning { task.terminate() }
                throw CancellationError()
            }
            if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning {
                    task.terminate()
                }
                return
            }
            if !task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
                    return
                }
                throw CodexAdapterError.credentialsMissing(codexHome: codexHome.path)
            }
            try await Task.sleep(nanoseconds: Self.pollNanos)
        }

        if task.isRunning {
            task.terminate()
        }
        if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
            return
        }
        throw CodexAdapterError.loginTimeout(codexHome: codexHome.path)
    }

    private static func requireCredentials(codexHome: URL) throws -> CodexCreds {
        if let creds = readCredentials(codexHome: codexHome) {
            return creds
        }
        throw CodexAdapterError.credentialsMissing(codexHome: codexHome.path)
    }

    private static func suggestedLabel(plan: String?, short: String) -> String {
        if let plan, !plan.isEmpty {
            return "Codex \(plan) \(short)"
        }
        return "Codex \(short)"
    }

    // MARK: - Credential read

    struct CodexCreds: Equatable {
        var accessToken: String
        var accountID: String?
    }

    /// Prefer `$CODEX_HOME/auth.json`; fall back to nested `.codex/auth.json`
    /// if login was done with HOME=managed instead of CODEX_HOME.
    static func readCredentials(codexHome: URL) -> CodexCreds? {
        let candidates = [
            codexHome.appendingPathComponent(authFileName, isDirectory: false),
            codexHome
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent(authFileName, isDirectory: false),
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: path),
               let creds = parseAuthJSON(data)
            {
                return creds
            }
        }
        return nil
    }

    /// Decode Codex `auth.json` (`tokens.access_token`, optional `tokens.account_id`).
    static func parseAuthJSON(_ data: Data) -> CodexCreds? {
        guard let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = blob["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        return CodexCreds(
            accessToken: access,
            accountID: tokens["account_id"] as? String
        )
    }

    // MARK: - Usage HTTP

    static func probeUsage(token: String, accountID: String?, fetchedAt: Date) async -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return errorSnapshot(.network("bad response"), fetchedAt: fetchedAt)
            }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                // Access token expired/rejected — Codex CLI rotates on its own via `codex login`.
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case 429:
                let retry = retryAfterDate(from: http)
                return errorSnapshot(.rateLimited(retryAfter: retry), fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: fetchedAt)
            }

            return parseUsageResponse(data: data, fetchedAt: fetchedAt)
        } catch {
            return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    /// Parse `/wham/usage` JSON → snapshot. Exposed for unit tests.
    ///
    /// Live Codex Pro/Plus often ships a **weekly** `primary_window`
    /// (`limit_window_seconds` = 604800) and a null `secondary_window` —
    /// not a 5h + week pair. Kind is derived from `limit_window_seconds`.
    static func parseUsageResponse(data: Data, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        guard let rateLimit = obj["rate_limit"] as? [String: Any] else {
            return errorSnapshot(.parse("missing rate_limit"), fetchedAt: fetchedAt)
        }
        let primary = parseWindow(rateLimit["primary_window"])
            ?? WindowUsage(usedFraction: 0, kind: .unknown)
        // Null / missing secondary must stay nil — do not invent a 0% week.
        let secondary = parseWindow(rateLimit["secondary_window"])
        let plan = obj["plan_type"] as? String
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    /// Codex returns `used_percent` in [0, 100] — always ÷100.
    /// `reset_at` is unix seconds. `limit_window_seconds` → kind (5h / wk / mo).
    /// Returns `nil` when the window object is absent (JSON null / missing).
    static func parseWindow(_ obj: Any?) -> WindowUsage? {
        guard let d = obj as? [String: Any] else { return nil }
        let raw = (d["used_percent"] as? Double)
            ?? (d["used_percent"] as? Int).map(Double.init)
            ?? 0
        let normalized = min(1, max(0, raw / 100.0))
        let resetAt = parseResetAt(d["reset_at"])
        let limitSeconds = (d["limit_window_seconds"] as? Double)
            ?? (d["limit_window_seconds"] as? Int).map(Double.init)
            ?? (d["limit_window_seconds"] as? Int64).map(Double.init)
        return WindowUsage(
            usedFraction: normalized,
            resetAt: resetAt,
            usedTokens: nil,
            limitTokens: nil,
            kind: .fromLimitSeconds(limitSeconds)
        )
    }

    static func parseResetAt(_ value: Any?) -> Date? {
        if let r = value as? Double {
            return Date(timeIntervalSince1970: r)
        }
        if let r = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(r))
        }
        if let r = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(r))
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
    static func locateCodexBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/codex"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
