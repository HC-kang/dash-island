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
/// (`tokens.access_token`). We refresh it via auth.openai.com and write the
/// rotated tokens back (`refreshManagedCredentials`).
struct CodexAdapter: VendorAdapter {
    let id: VendorID = "codex"
    let displayName = "Codex"
    /// Gentler than Claude; endpoint is rarely rate-limited but stay polite.
    let minPollSeconds = 120

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// OpenAI Auth0-style token endpoint used by Codex CLI.
    private static let oauthTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public Codex / ChatGPT app client id (from id_token `aud`).
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
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
        let priorToken = Self.readCredentials(codexHome: dir)?.accessToken
        // Move auth.json aside, never delete it: Cancel or a failed login used
        // to leave a healthy account with no refresh token at all.
        let prior = CredentialStore.PriorFiles.stash(Self.authFiles(codexHome: dir))
        do {
            try await runLogin(codexHome: dir, priorToken: priorToken)
            _ = try Self.requireCredentials(codexHome: dir)
            prior.discard()
            return ref
        } catch {
            prior.restore()
            if error is CancellationError { throw error }
            if let error = error as? CodexAdapterError { throw error }
            throw CodexAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        await Self.fetchUsage(codexHome: CredentialStore.directoryURL(for: ref))
    }

    /// One poll of a managed folder. Tests call it with a temp folder.
    static func fetchUsage(codexHome dir: URL) async -> UsageSnapshot {
        let now = Date()
        let ref = dir.lastPathComponent
        guard var creds = Self.readCredentials(codexHome: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        // Managed CODEX_HOME tokens — refresh before usage (no-op within 45m of
        // the last one). Any failure keeps the current access: the probe decides.
        var quiet: UsageSnapshot?
        var refreshDead = false
        switch await Self.refreshManagedCredentials(codexHome: dir, knownRefreshToken: creds.refreshToken) {
        case .success(let refreshed):
            if refreshed.accessToken != creds.accessToken {
                Log.auth.info("refresh vendor=codex outcome=ok ref=\(String(ref.prefix(8)))")
            }
            creds = refreshed
        case .unavailable(let message, let retryAt):
            quiet = TokenHostFailure.quietSnapshot(message: message, retryAt: retryAt, fetchedAt: now)
        case .rejected:
            refreshDead = true
        case .skipped:
            break
        }
        var snap = await Self.probeUsage(
            token: creds.accessToken,
            accountID: creds.accountID,
            fetchedAt: now
        )
        guard case .authRequired = snap.error, !refreshDead else { return snap }
        // A busy token host is not a dead login: soft quiet, never red "reconnect".
        if let quiet { return quiet }
        switch await Self.refreshManagedCredentials(
            codexHome: dir, force: true, knownRefreshToken: creds.refreshToken
        ) {
        case .success(let refreshed):
            snap = await Self.probeUsage(
                token: refreshed.accessToken,
                accountID: refreshed.accountID,
                fetchedAt: Date()
            )
            if snap.error == nil {
                Log.auth.info("refresh vendor=codex outcome=ok trigger=reactive ref=\(String(ref.prefix(8)))")
            }
        case .unavailable(let message, let retryAt):
            snap = TokenHostFailure.quietSnapshot(message: message, retryAt: retryAt, fetchedAt: Date())
        case .rejected, .skipped:
            break
        }
        return snap
    }

    // MARK: - Login (managed CODEX_HOME)

    /// `$CODEX_HOME/auth.json`, plus the nested copy a HOME-isolated login writes.
    static func authFiles(codexHome: URL) -> [URL] {
        [
            codexHome.appendingPathComponent(authFileName, isDirectory: false),
            codexHome
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent(authFileName, isDirectory: false),
        ]
    }

    static func clearManagedCredentials(codexHome: URL) {
        let fm = FileManager.default
        for path in authFiles(codexHome: codexHome) where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        Log.auth.info("clearCreds vendor=codex ref=\(String(codexHome.lastPathComponent.prefix(8)))")
    }

    /// `priorToken` is never accepted as the new login's result.
    private func runLogin(codexHome: URL, priorToken: String? = nil) async throws {
        guard let binary = Self.locateCodexBinary() else {
            throw CodexAdapterError.codexBinaryNotFound
        }

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

        // Cancelled while we got here: do not open a browser login nobody waits for.
        try Task.checkCancellation()
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

        // Cancel ends `codex login` too, so no orphan keeps the callback port.
        try await LoginProcess.supervise(task) {
            while Date() < deadline {
                try Task.checkCancellation()
                if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    return
                }
                if !task.isRunning {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
                        return
                    }
                    throw CodexAdapterError.credentialsMissing(codexHome: codexHome.path)
                }
                try await Task.sleep(nanoseconds: Self.pollNanos)
            }

            LoginProcess.terminate(task)
            if let creds = Self.readCredentials(codexHome: codexHome), isAcceptable(creds) {
                return
            }
            throw CodexAdapterError.loginTimeout(codexHome: codexHome.path)
        }
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
        var refreshToken: String?
        var accountID: String?
        /// Path of the auth.json we read (for write-back after refresh).
        var filePath: URL? = nil
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
               var creds = parseAuthJSON(data)
            {
                creds.filePath = path
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
        let refresh = tokens["refresh_token"] as? String
        return CodexCreds(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            accountID: tokens["account_id"] as? String
        )
    }

    enum RefreshOutcome: Equatable {
        /// Refreshed, or still fresh enough that no POST was needed.
        case success(CodexCreds)
        /// No refresh token / unreadable file: nothing to refresh with.
        case skipped
        /// Spent or revoked grant: only a new `codex login` helps.
        case rejected
        /// Token host busy / down (429, 5xx, network): keep the session.
        case unavailable(String, retryAt: Date?)
    }

    /// Refresh managed auth.json. Without `force`, skip the POST while the last
    /// refresh is under 45 minutes old (Codex does not always store expiry).
    /// `knownRefreshToken` is the one the caller read: a different one in the
    /// file means `codex` (account-cli) rotated it, so adopt and skip the POST.
    static func refreshManagedCredentials(
        codexHome: URL,
        force: Bool = false,
        knownRefreshToken: String? = nil
    ) async -> RefreshOutcome {
        guard let lock = await CredentialStore.acquireRefreshLock(in: codexHome) else {
            return .unavailable("token quiet — refresh busy", retryAt: nil)
        }
        defer { lock.release() }
        guard let creds = readCredentials(codexHome: codexHome),
              let refresh = creds.refreshToken, !refresh.isEmpty,
              let path = creds.filePath,
              let existing = try? Data(contentsOf: path)
        else { return .skipped }
        if let knownRefreshToken, refresh != knownRefreshToken {
            Log.auth.info("refresh vendor=codex outcome=adopted ref=\(String(codexHome.lastPathComponent.prefix(8)))")
            return .success(creds)
        }

        // Without force, skip network if last_refresh is very recent (< 30m)
        // and access token still works often enough — but we can't know without
        // probing. Always refresh when force; otherwise refresh if last_refresh
        // older than 45 minutes when present.
        if !force {
            if let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
               let last = root["last_refresh"] as? String
            {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                if let d = iso.date(from: last) ?? plain.date(from: last),
                   Date().timeIntervalSince(d) < 45 * 60
                {
                    return .success(creds)
                }
            }
        }

        var req = URLRequest(url: oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", oauthClientID),
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = form
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable(TokenHostFailure.quietMessage(status: nil), retryAt: nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                switch TokenHostFailure.classify(
                    status: http.statusCode,
                    body: data,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                ) {
                case .rejected, .badClient:
                    Log.auth.warn("refresh vendor=codex outcome=rejected http=\(http.statusCode)")
                    return .rejected
                case .unavailable(let retryAt):
                    Log.auth.warn("refresh vendor=codex outcome=quiet http=\(http.statusCode)")
                    return .unavailable(TokenHostFailure.quietMessage(status: http.statusCode), retryAt: retryAt)
                }
            }
            guard let updated = applyRefreshedToken(existingJSON: existing, responseJSON: data) else {
                return .unavailable("token quiet — token refresh parse failed", retryAt: nil)
            }
            do {
                try CredentialStore.writeSecret(updated, to: path)
            } catch {
                // The server already rotated: the old refresh token is spent.
                Log.auth.error("refresh vendor=codex outcome=writeFailed error=\(error.localizedDescription)")
                return .unavailable("token quiet — credential write failed", retryAt: nil)
            }
            var next = parseAuthJSON(updated)
            next?.filePath = path
            return .success(next ?? creds)
        } catch {
            Log.auth.warn("refresh vendor=codex outcome=failed error=\(error.localizedDescription)")
            return .unavailable(TokenHostFailure.quietMessage(status: nil), retryAt: nil)
        }
    }

    /// Merge OpenAI token response into auth.json. Exposed for tests.
    static func applyRefreshedToken(existingJSON: Data, responseJSON: Data, now: Date = Date()) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: existingJSON) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let resp = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              let access = resp["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        tokens["access_token"] = access
        if let idToken = resp["id_token"] as? String, !idToken.isEmpty {
            tokens["id_token"] = idToken
        }
        if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
            tokens["refresh_token"] = newRefresh
        }
        root["tokens"] = tokens
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: now)
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Usage HTTP

    static func probeUsage(token: String, accountID: String?, fetchedAt: Date) async -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        // Default is 60s; a stalled host held a poll slot that long.
        req.timeoutInterval = 20

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

            var snapshot = parseUsageResponse(data: data, fetchedAt: fetchedAt)
            if snapshot.error == nil {
                // Same account headers; a reset-credit failure must not hide quota.
                req.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
                req.timeoutInterval = 5
                if let (credits, response) = try? await URLSession.shared.data(for: req),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    snapshot.resetCreditsAvailable = parseResetCredits(credits)
                }
            }
            return snapshot
        } catch {
            return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    static func parseResetCredits(_ data: Data) -> Int? {
        struct Response: Decodable { let available_count: Int }
        guard let count = try? JSONDecoder().decode(Response.self, from: data).available_count,
              count >= 0 else { return nil }
        return count
    }

    /// Parse `/wham/usage` JSON → snapshot. Exposed for unit tests.
    ///
    /// Live Codex Pro/Plus often ships a **weekly** `primary_window`
    /// (`limit_window_seconds` = 604800) and a null `secondary_window` —
    /// not a 5h + week pair. Kind is derived from `limit_window_seconds`.
    /// Model-scoped rows under `additional_rate_limits` (e.g. Spark) become
    /// the tertiary ring + hover extras.
    static func parseUsageResponse(data: Data, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        guard let rateLimit = obj["rate_limit"] as? [String: Any] else {
            return errorSnapshot(.parse("missing rate_limit"), fetchedAt: fetchedAt)
        }
        let first = parseWindow(rateLimit["primary_window"], fetchedAt: fetchedAt)
        let second = parseWindow(rateLimit["secondary_window"], fetchedAt: fetchedAt)
        var primary = first ?? second
            ?? WindowUsage(usedFraction: 0, kind: .unknown)
        if first == nil && second == nil { primary.reported = false }
        // Null / missing secondary must stay nil — do not invent a 0% week.
        let secondary = first == nil ? nil : second
        let scoped = parseAdditionalRateLimits(obj["additional_rate_limits"], fetchedAt: fetchedAt)
        let tertiary = UsageRingLayout.preferredTertiary(from: scoped)
        let extras = UsageRingLayout.remainingExtras(extras: scoped, tertiary: tertiary)
        let plan = obj["plan_type"] as? String
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

    /// Model-specific quotas (Spark / bengalfox, …) from `additional_rate_limits[]`.
    static func parseAdditionalRateLimits(_ raw: Any?, fetchedAt: Date = Date()) -> [WindowUsage] {
        guard let rows = raw as? [Any] else { return [] }
        var out: [WindowUsage] = []
        var seen = Set<String>()
        for row in rows {
            guard let d = row as? [String: Any] else { continue }
            let name = (d["limit_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { continue }
            let rl = d["rate_limit"] as? [String: Any]
            for slot in ["primary_window", "secondary_window"] {
                guard var window = parseWindow(rl?[slot] ?? d[slot], fetchedAt: fetchedAt) else { continue }
                let key = "\(name.lowercased()):\(window.kind.rawValue)"
                guard seen.insert(key).inserted else { continue }
                let label = shortCodexLimitLabel(name)
                window.labelOverride = slot == "secondary_window" ? "\(label) \(window.kind.shortLabel)" : label
                out.append(window)
            }
        }
        return out
    }

    /// Compact ring/hover label: "GPT-5.3-Codex-Spark" → "Spark".
    static func shortCodexLimitLabel(_ name: String) -> String {
        if let last = name.split(separator: "-").last, last.count >= 3 {
            return String(last)
        }
        if name.count <= 12 { return name }
        return String(name.suffix(12))
    }

    /// Codex returns `used_percent` in [0, 100] (sometimes fractional).
    /// Prefer absolute token/credit counters when the payload includes them.
    /// `reset_at` is unix seconds; `reset_after_seconds` is a relative fallback.
    /// `limit_window_seconds` → kind (5h / wk / mo).
    /// Returns `nil` when the window object is absent (JSON null / missing).
    static func parseWindow(_ obj: Any?, fetchedAt: Date = Date()) -> WindowUsage? {
        guard let d = obj as? [String: Any] else { return nil }
        let usedTok = jsonInt64(d["used_tokens"])
            ?? jsonInt64(d["tokens_used"])
            ?? jsonInt64(d["used"])
        let limitTok = jsonInt64(d["limit_tokens"])
            ?? jsonInt64(d["tokens_limit"])
            ?? jsonInt64(d["limit"])
        let raw = (d["used_percent"] as? Double)
            ?? (d["used_percent"] as? Int).map(Double.init)
            ?? (d["used_percent"] as? Int64).map(Double.init)
        // Percent is always [0, 100] (0.5 = half a percent).
        let fromPercent = raw.map { $0 / 100.0 }
        let fromAbs: Double? = {
            guard let u = usedTok, let lim = limitTok, lim > 0 else { return nil }
            return min(1, max(0, Double(u) / Double(lim)))
        }()
        guard let fraction = fromAbs ?? fromPercent, fraction.isFinite else { return nil }
        let normalized = min(1, max(0, fraction))
        let resetAt = parseResetAt(d["reset_at"])
            ?? parseResetAfterSeconds(d["reset_after_seconds"], from: fetchedAt)
        let limitSeconds = (d["limit_window_seconds"] as? Double)
            ?? (d["limit_window_seconds"] as? Int).map(Double.init)
            ?? (d["limit_window_seconds"] as? Int64).map(Double.init)
        return WindowUsage(
            usedFraction: normalized,
            resetAt: resetAt,
            usedTokens: usedTok,
            limitTokens: limitTok,
            kind: .fromLimitSeconds(limitSeconds)
        )
    }

    /// Relative reset countdown from the fetch instant (Codex often sends both).
    static func parseResetAfterSeconds(_ value: Any?, from fetchedAt: Date) -> Date? {
        let seconds: Double?
        if let d = value as? Double { seconds = d }
        else if let i = value as? Int { seconds = Double(i) }
        else if let i = value as? Int64 { seconds = Double(i) }
        else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return fetchedAt.addingTimeInterval(seconds)
    }

    private static func jsonInt64(_ value: Any?) -> Int64? {
        JSONNumber.int64(value)
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
