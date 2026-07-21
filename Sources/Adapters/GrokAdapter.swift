import Foundation

// MARK: - Errors

enum GrokAdapterError: Error, Equatable, LocalizedError {
    case grokBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(grokHome: String)
    case credentialsMissing(grokHome: String)
    case reauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .grokBinaryNotFound:
            return """
            Could not find the Grok CLI (`grok`). Install it, then either retry \
            or run login manually with GROK_HOME pointed at the managed account folder.
            """
        case .spawnFailed(let message):
            return "Failed to start Grok login: \(message)"
        case .loginTimeout(let grokHome):
            return """
            Grok login timed out. Complete browser sign-in, or run manually:

              GROK_HOME='\(grokHome)' grok login --oauth

            Then choose Reauthenticate (or remove and re-add).
            """
        case .credentialsMissing(let grokHome):
            return """
            Grok login finished but no auth.json session was found. Run:

              GROK_HOME='\(grokHome)' grok login --oauth
            """
        case .reauthFailed(let message):
            return message
        }
    }
}

// MARK: - Adapter

/// xAI Grok CLI usage via `cli-chat-proxy.grok.com/v1/billing`.
///
/// **Credentials:** per-account folder under Application Support
/// (`accounts/<uuid>/` as `GROK_HOME`). Auth lives at `$GROK_HOME/auth.json`
/// (issuer-keyed map; preferred `https://auth.x.ai…`).
///
/// Managed tokens are **refreshed by this app** via `auth.x.ai/oauth2/token`
/// (same OIDC client id stored in the session). Refresh tokens rotate —
/// write-back is atomic. We never touch the user's default `~/.grok` keychain.
struct GrokAdapter: VendorAdapter {
    let id: VendorID = "grok"
    let displayName = "Grok"
    /// Billing proxy is undocumented for rate limits — stay conservative.
    let minPollSeconds = 300

    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let defaultBillingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    /// Verified against live Grok CLI sessions (form body, not JSON).
    private static let oauthTokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let authFileName = "auth.json"
    private static let preferredIssuer = "https://auth.x.ai"
    private static let tokenAuthHeader = "xai-grok-cli"
    private static let tokenSkew: TimeInterval = 5 * 60
    private static let loginTimeout: TimeInterval = 180
    private static let pollNanos: UInt64 = 1_000_000_000

    // MARK: VendorAdapter

    func beginAdd() async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        do {
            let dir = try CredentialStore.createDirectory(for: ref)
            try await ensureCredentials(grokHome: dir)
            let session = try Self.requireSession(grokHome: dir)
            let short = String(ref.prefix(8))
            let label = Self.suggestedLabel(email: session.email, short: short)
            return AddAccountResult(vendorID: id, label: label, credentialRef: ref)
        } catch {
            try? CredentialStore.removeDirectory(for: ref)
            throw error
        }
    }

    func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef {
        let dir = try CredentialStore.createDirectory(for: ref)
        do {
            // Wipe first — runLogin otherwise returns as soon as old auth.json is seen.
            Self.clearManagedCredentials(grokHome: dir)
            try await ensureCredentials(grokHome: dir, forceLogin: true)
            _ = try Self.requireSession(grokHome: dir)
            return ref
        } catch let error as GrokAdapterError {
            throw error
        } catch {
            throw GrokAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        guard var session = Self.readSession(grokHome: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }

        // Proactive refresh when access is near/past expiry (managed folder only).
        if !Self.isAccessTokenFresh(session) {
            switch await Self.refreshManagedSession(grokHome: dir) {
            case .success(let next):
                session = next
                NSLog("DashIsland: Grok proactive refresh ok ref=%@", String(ref.prefix(8)))
            case .rateLimited(let retry):
                return Self.errorSnapshot(
                    .rateLimited(retryAfter: retry),
                    fetchedAt: now
                )
            case .rejected:
                return Self.errorSnapshot(.authRequired, fetchedAt: now)
            case .unavailable(let message):
                return Self.errorSnapshot(.unavailable(message), fetchedAt: now)
            case .skipped:
                return Self.errorSnapshot(.authRequired, fetchedAt: now)
            }
        }

        var snap = await Self.probeUsage(session: session, fetchedAt: now)

        // Reactive: billing 401/403 → one forced refresh + retry.
        if case .authRequired = snap.error {
            switch await Self.refreshManagedSession(grokHome: dir) {
            case .success(let next):
                snap = await Self.probeUsage(session: next, fetchedAt: Date())
                if snap.error == nil {
                    NSLog("DashIsland: Grok reactive refresh ok ref=%@", String(ref.prefix(8)))
                }
            case .rateLimited(let retry):
                snap = Self.errorSnapshot(
                    .rateLimited(retryAfter: retry),
                    fetchedAt: Date()
                )
            case .rejected, .skipped:
                snap = Self.errorSnapshot(.authRequired, fetchedAt: Date())
            case .unavailable(let message):
                snap = Self.errorSnapshot(.unavailable(message), fetchedAt: Date())
            }
        }
        return snap
    }

    // MARK: - Login / seed credentials

    /// Prefer interactive `grok login` under managed `GROK_HOME`. If the binary
    /// is missing, fall back to copying a usable default `~/.grok/auth.json`
    /// only for **first add** (`forceLogin == false`) — never on reauth.
    private func ensureCredentials(grokHome: URL, forceLogin: Bool = false) async throws {
        if !forceLogin, Self.readSession(grokHome: grokHome) != nil {
            return
        }
        if Self.locateGrokBinary() != nil {
            try await runLogin(grokHome: grokHome)
            _ = try Self.requireSession(grokHome: grokHome)
            return
        }
        // beginAdd only: seed from default home when CLI is absent.
        if !forceLogin, try Self.copyDefaultAuthIfPresent(into: grokHome) {
            return
        }
        throw GrokAdapterError.grokBinaryNotFound
    }

    static func clearManagedCredentials(grokHome: URL) {
        let fm = FileManager.default
        let paths = [
            grokHome.appendingPathComponent(authFileName, isDirectory: false),
            grokHome
                .appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent(authFileName, isDirectory: false),
        ]
        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        NSLog("DashIsland: cleared Grok managed creds at %@", grokHome.path)
    }

    private func runLogin(grokHome: URL) async throws {
        guard let binary = Self.locateGrokBinary() else {
            throw GrokAdapterError.grokBinaryNotFound
        }

        let priorToken = Self.readSession(grokHome: grokHome)?.accessToken

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        // `--oauth` selects auth.x.ai OAuth (same session shape Orca reads).
        task.arguments = ["login", "--oauth"]
        var env = ProcessInfo.processInfo.environment
        env["GROK_HOME"] = grokHome.path
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        // Keep stdin open so the CLI does not see immediate EOF.
        task.standardInput = Pipe()

        do {
            try task.run()
        } catch {
            throw GrokAdapterError.spawnFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.loginTimeout)

        func isAcceptable(_ session: GrokSession) -> Bool {
            if let priorToken, session.accessToken == priorToken { return false }
            return !session.accessToken.isEmpty
        }

        while Date() < deadline {
            if Task.isCancelled {
                if task.isRunning { task.terminate() }
                throw CancellationError()
            }
            if let session = Self.readSession(grokHome: grokHome), isAcceptable(session) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning {
                    task.terminate()
                }
                return
            }
            if !task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let session = Self.readSession(grokHome: grokHome), isAcceptable(session) {
                    return
                }
                throw GrokAdapterError.credentialsMissing(grokHome: grokHome.path)
            }
            try await Task.sleep(nanoseconds: Self.pollNanos)
        }

        if task.isRunning {
            task.terminate()
        }
        if let session = Self.readSession(grokHome: grokHome), isAcceptable(session) {
            return
        }
        throw GrokAdapterError.loginTimeout(grokHome: grokHome.path)
    }

    /// Copy `~/.grok/auth.json` into managed home when it already has a token.
    @discardableResult
    static func copyDefaultAuthIfPresent(into grokHome: URL) throws -> Bool {
        let defaultAuth = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent(authFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: defaultAuth.path),
              let data = try? Data(contentsOf: defaultAuth),
              parseAuthJSON(data) != nil
        else { return false }
        let dest = grokHome.appendingPathComponent(authFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest, options: .atomic)
        return true
    }

    private static func requireSession(grokHome: URL) throws -> GrokSession {
        if let session = readSession(grokHome: grokHome) {
            return session
        }
        throw GrokAdapterError.credentialsMissing(grokHome: grokHome.path)
    }

    private static func suggestedLabel(email: String?, short: String) -> String {
        if let email, !email.isEmpty {
            // Keep label short: local-part only when it looks like an email.
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return "Grok \(local)"
        }
        return "Grok \(short)"
    }

    // MARK: - Credential read

    struct GrokSession: Equatable {
        var accessToken: String
        var userId: String?
        var email: String?
        var teamId: String?
        var expiresAt: Date?
        /// For managed refresh write-back.
        var refreshToken: String? = nil
        var oidcClientID: String? = nil
        var issuerMapKey: String? = nil
        var filePath: URL? = nil
    }

    enum RefreshOutcome: Equatable {
        case success(GrokSession)
        case skipped
        case rateLimited(Date?)
        case rejected
        case unavailable(String)
    }

    /// Prefer `$GROK_HOME/auth.json`; fall back to nested `.grok/auth.json`
    /// if login was done with HOME=managed instead of GROK_HOME.
    static func readSession(grokHome: URL) -> GrokSession? {
        let candidates = [
            grokHome.appendingPathComponent(authFileName, isDirectory: false),
            grokHome
                .appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent(authFileName, isDirectory: false),
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: path),
               var session = parseAuthJSON(data)
            {
                session.filePath = path
                return session
            }
        }
        return nil
    }

    /// Decode Grok issuer-keyed `auth.json`. Prefers `https://auth.x.ai…` entries.
    static func parseAuthJSON(_ data: Data) -> GrokSession? {
        guard let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var preferredKeySeen = false
        var expiredPreferred: GrokSession?
        var fallback: GrokSession?

        for (key, value) in blob {
            let isPreferred = isPreferredIssuerKey(key)
            if isPreferred { preferredKeySeen = true }
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String,
                  !token.isEmpty
            else { continue }

            let clientID = (entry["oidc_client_id"] as? String)
                ?? issuerClientID(fromMapKey: key)
            let session = GrokSession(
                accessToken: token,
                userId: entry["user_id"] as? String,
                email: entry["email"] as? String,
                teamId: entry["team_id"] as? String,
                expiresAt: parseISODate(entry["expires_at"]),
                refreshToken: {
                    let r = entry["refresh_token"] as? String
                    return (r?.isEmpty == false) ? r : nil
                }(),
                oidcClientID: clientID,
                issuerMapKey: key
            )
            if isPreferred {
                if isAccessTokenFresh(session) {
                    return session
                }
                if expiredPreferred == nil {
                    expiredPreferred = session
                }
                continue
            }
            if fallback == nil {
                fallback = session
            }
        }

        // Alternate issuers only when no preferred key exists (matches Orca).
        // Prefer expired preferred over nil so refresh can recover.
        if let expiredPreferred {
            return expiredPreferred
        }
        if preferredKeySeen {
            return nil
        }
        return fallback
    }

    /// `https://auth.x.ai::b1a00492-…` → client id suffix.
    static func issuerClientID(fromMapKey key: String) -> String? {
        let parts = key.split(separator: "::", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// Refresh managed auth.json via OIDC token endpoint. Rotates refresh_token.
    static func refreshManagedSession(grokHome: URL) async -> RefreshOutcome {
        guard var session = readSession(grokHome: grokHome),
              let refresh = session.refreshToken, !refresh.isEmpty,
              let clientID = session.oidcClientID, !clientID.isEmpty,
              let mapKey = session.issuerMapKey,
              let path = session.filePath,
              let existing = try? Data(contentsOf: path),
              var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              var entry = root[mapKey] as? [String: Any]
        else {
            return .skipped
        }

        var req = URLRequest(url: oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        let form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", clientID),
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = form
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("token refresh: bad response")
            }
            switch http.statusCode {
            case 200..<300:
                break
            case 429:
                NSLog("DashIsland: Grok refresh HTTP 429")
                return .rateLimited(retryAfterDate(from: http))
            case 400, 401, 403:
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("DashIsland: Grok refresh rejected HTTP %d %@", http.statusCode, body)
                return .rejected
            default:
                NSLog("DashIsland: Grok refresh HTTP %d", http.statusCode)
                return .unavailable("token refresh HTTP \(http.statusCode)")
            }

            guard let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = resp["access_token"] as? String,
                  !access.isEmpty
            else {
                return .unavailable("token refresh parse failed")
            }

            entry["key"] = access
            if let newRefresh = resp["refresh_token"] as? String, !newRefresh.isEmpty {
                entry["refresh_token"] = newRefresh
            }
            let expiresIn = (resp["expires_in"] as? Double)
                ?? (resp["expires_in"] as? Int).map(Double.init)
                ?? 21_600
            let exp = Date().addingTimeInterval(expiresIn)
            entry["expires_at"] = iso8601FractionalUTC.string(from: exp)
            root[mapKey] = entry
            guard let updated = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            ) else {
                return .unavailable("token refresh encode failed")
            }
            try? updated.write(to: path, options: .atomic)

            session.accessToken = access
            session.refreshToken = (entry["refresh_token"] as? String) ?? refresh
            session.expiresAt = exp
            session.filePath = path
            return .success(session)
        } catch {
            NSLog("DashIsland: Grok refresh failed: %@", error.localizedDescription)
            return .unavailable("token refresh: \(error.localizedDescription)")
        }
    }

    private static let iso8601FractionalUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func isPreferredIssuerKey(_ key: String) -> Bool {
        key == preferredIssuer || key.hasPrefix("\(preferredIssuer)::")
    }

    static func isAccessTokenFresh(_ session: GrokSession) -> Bool {
        guard let expiresAt = session.expiresAt else {
            // No expiry on disk — billing 401 will surface a bad token.
            return true
        }
        return expiresAt.timeIntervalSinceNow > tokenSkew
    }

    // MARK: - Usage HTTP

    /// How often to hit the monthly billing URL when weekly credits already work.
    /// Weekly alone drives rings + burn; monthly is a secondary ring only.
    nonisolated static let monthlyFetchMinInterval: TimeInterval = 15 * 60

    /// Best-effort thrift cache (races only waste an occasional extra fetch).
    nonisolated(unsafe) private static var monthlyCache: [String: (at: Date, window: WindowUsage?)] = [:]

    static func probeUsage(session: GrokSession, fetchedAt: Date) async -> UsageSnapshot {
        let creditsResult = await fetchBilling(url: creditsURL, session: session)
        switch creditsResult {
        case .httpError(let snapshot):
            return snapshot.withFetchedAt(fetchedAt)
        case .data(let data):
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = resolveBillingConfig(root)
            else {
                return errorSnapshot(
                    .unavailable("Grok billing response did not include config"),
                    fetchedAt: fetchedAt
                )
            }
            let plan = config["subscriptionTier"] as? String
            let cacheKey = session.userId ?? String(session.accessToken.prefix(16))

            if let weekly = mapWeeklyCredits(config) {
                // Live Grok credits are **weekly**, not 5h. Monthly is optional
                // secondary — throttle to cut dual HTTP load (was every poll).
                let monthly = await fetchMonthlyThrottled(session: session, cacheKey: cacheKey, now: fetchedAt)
                return UsageSnapshot(
                    primary: weekly,
                    secondary: monthly,
                    plan: plan,
                    fetchedAt: fetchedAt,
                    error: nil
                )
            }

            // No weekly % — monthly-only accounts (always fetch monthly).
            let monthlyResult = await fetchBilling(url: defaultBillingURL, session: session)
            switch monthlyResult {
            case .httpError(let snapshot):
                return snapshot.withFetchedAt(fetchedAt)
            case .data(let monthlyData):
                if let monthly = mapMonthlyUsage(
                    resolveBillingConfig(
                        (try? JSONSerialization.jsonObject(with: monthlyData) as? [String: Any]) ?? [:]
                    ) ?? ((try? JSONSerialization.jsonObject(with: monthlyData) as? [String: Any]) ?? [:])
                ) {
                    storeMonthlyCache(key: cacheKey, window: monthly, at: fetchedAt)
                }
                return parseMonthlyFallback(
                    creditsData: data,
                    monthlyData: monthlyData,
                    fetchedAt: fetchedAt
                )
            }
        }
    }

    /// Monthly billing at most every `monthlyFetchMinInterval` per session key.
    private static func fetchMonthlyThrottled(
        session: GrokSession,
        cacheKey: String,
        now: Date
    ) async -> WindowUsage? {
        let cached = monthlyCache[cacheKey]
        if let cached, now.timeIntervalSince(cached.at) < monthlyFetchMinInterval {
            return cached.window
        }

        let monthlyResult = await fetchBilling(url: defaultBillingURL, session: session)
        let window: WindowUsage?
        if case .data(let monthlyData) = monthlyResult {
            let monthlyRoot = (try? JSONSerialization.jsonObject(with: monthlyData) as? [String: Any]) ?? [:]
            let monthlyConfig = resolveBillingConfig(monthlyRoot) ?? monthlyRoot
            window = mapMonthlyUsage(monthlyConfig)
        } else {
            window = cached?.window
        }
        monthlyCache[cacheKey] = (now, window)
        return window
    }

    private static func storeMonthlyCache(key: String, window: WindowUsage?, at: Date) {
        monthlyCache[key] = (at, window)
    }

    private enum BillingFetch {
        case data(Data)
        case httpError(UsageSnapshot)
    }

    private static func fetchBilling(url: URL, session: GrokSession) async -> BillingFetch {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userId = session.userId, !userId.isEmpty {
            req.setValue(userId, forHTTPHeaderField: "x-userid")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .httpError(errorSnapshot(.network("bad response"), fetchedAt: Date()))
            }
            switch http.statusCode {
            case 200:
                return .data(data)
            case 401, 403:
                return .httpError(errorSnapshot(.authRequired, fetchedAt: Date()))
            case 429:
                let retry = retryAfterDate(from: http)
                return .httpError(errorSnapshot(.rateLimited(retryAfter: retry), fetchedAt: Date()))
            default:
                return .httpError(
                    errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: Date())
                )
            }
        } catch {
            return .httpError(
                errorSnapshot(.network(error.localizedDescription), fetchedAt: Date())
            )
        }
    }

    /// Parse credits billing JSON → snapshot. Exposed for unit tests.
    static func parseCreditsResponse(data: Data, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        guard let config = resolveBillingConfig(root) else {
            return errorSnapshot(
                .unavailable("Grok billing response did not include config"),
                fetchedAt: fetchedAt
            )
        }
        let plan = config["subscriptionTier"] as? String
        if let weekly = mapWeeklyCredits(config) {
            return UsageSnapshot(
                primary: weekly,
                secondary: nil,
                plan: plan,
                fetchedAt: fetchedAt,
                error: nil
            )
        }
        // No weekly — caller may try monthly fallback. Surface as soft empty for pure parse tests.
        return UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            secondary: nil,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    /// Parse monthly-only path after credits view lacked weekly %. Exposed for tests.
    static func parseMonthlyFallback(
        creditsData: Data,
        monthlyData: Data,
        fetchedAt: Date = Date()
    ) -> UsageSnapshot {
        let creditsRoot = (try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any]) ?? [:]
        let monthlyRoot = (try? JSONSerialization.jsonObject(with: monthlyData) as? [String: Any]) ?? [:]
        let creditsConfig = resolveBillingConfig(creditsRoot) ?? [:]
        let monthlyConfig = resolveBillingConfig(monthlyRoot) ?? monthlyRoot
        let plan = (creditsConfig["subscriptionTier"] as? String)
            ?? (monthlyConfig["subscriptionTier"] as? String)

        if let monthly = mapMonthlyUsage(monthlyConfig) {
            return UsageSnapshot(
                primary: monthly, // already .monthly kind
                secondary: nil,
                plan: plan,
                fetchedAt: fetchedAt,
                error: nil
            )
        }
        return errorSnapshot(
            .unavailable("Grok billing response did not include credit usage"),
            fetchedAt: fetchedAt
        )
    }

    /// Full dual-window parse when both weekly and monthly are known (tests / future).
    static func parseBillingWindows(
        weeklyConfig: [String: Any]?,
        monthlyConfig: [String: Any]?,
        plan: String?,
        fetchedAt: Date = Date()
    ) -> UsageSnapshot {
        let weekly = weeklyConfig.flatMap(mapWeeklyCredits)
        let monthly = monthlyConfig.flatMap(mapMonthlyUsage)
        if weekly == nil && monthly == nil {
            return errorSnapshot(
                .unavailable("Grok billing response did not include credit usage"),
                fetchedAt: fetchedAt
            )
        }
        if let weekly {
            return UsageSnapshot(
                primary: weekly,
                secondary: monthly,
                plan: plan,
                fetchedAt: fetchedAt,
                error: nil
            )
        }
        return UsageSnapshot(
            primary: monthly!,
            secondary: nil,
            plan: plan,
            fetchedAt: fetchedAt,
            error: nil
        )
    }

    static func resolveBillingConfig(_ root: [String: Any]) -> [String: Any]? {
        if let config = root["config"] as? [String: Any] {
            return config
        }
        if root["creditUsagePercent"] != nil
            || root["monthlyLimit"] != nil
            || root["subscriptionTier"] != nil
        {
            return root
        }
        return nil
    }

    /// Weekly credits: `creditUsagePercent` always ÷100. Confirmed-weekly with
    /// omitted percent → 0 (protobuf zero). Kind is always `.weekly` (not 5h).
    static func mapWeeklyCredits(_ config: [String: Any]) -> WindowUsage? {
        let percent = numberValue(config["creditUsagePercent"])
        if let percent {
            let fraction = min(1, max(0, percent / 100.0))
            return WindowUsage(
                usedFraction: fraction,
                resetAt: periodEndDate(config),
                usedTokens: nil,
                limitTokens: nil,
                kind: .weekly
            )
        }
        if hasConfirmedWeeklyPeriod(config) {
            return WindowUsage(
                usedFraction: 0,
                resetAt: periodEndDate(config),
                usedTokens: nil,
                limitTokens: nil,
                kind: .weekly
            )
        }
        return nil
    }

    /// Monthly: `used.val / monthlyLimit.val` when limit > 0.
    /// Absolute counters are kept for burn (much finer than weekly whole-percent).
    static func mapMonthlyUsage(_ config: [String: Any]) -> WindowUsage? {
        guard let limit = moneyVal(config["monthlyLimit"]), limit > 0,
              let used = moneyVal(config["used"])
        else { return nil }
        let fraction = min(1, max(0, used / limit))
        return WindowUsage(
            usedFraction: fraction,
            resetAt: periodEndDate(config),
            usedTokens: Int64(used.rounded()),
            limitTokens: Int64(limit.rounded()),
            kind: .monthly
        )
    }

    static func hasConfirmedWeeklyPeriod(_ config: [String: Any]) -> Bool {
        guard let period = config["currentPeriod"] as? [String: Any],
              let type = period["type"] as? String,
              type == "USAGE_PERIOD_TYPE_WEEKLY"
        else { return false }
        return timestampsMatch(period["start"], config["billingPeriodStart"])
            && timestampsMatch(period["end"], config["billingPeriodEnd"])
    }

    private static func periodEndDate(_ config: [String: Any]) -> Date? {
        if let period = config["currentPeriod"] as? [String: Any],
           let end = parseISODate(period["end"])
        {
            return end
        }
        return parseISODate(config["billingPeriodEnd"])
    }

    static func moneyVal(_ value: Any?) -> Double? {
        guard let obj = value as? [String: Any] else { return nil }
        return numberValue(obj["val"])
    }

    static func numberValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let i = value as? Int64 { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    static func timestampsMatch(_ left: Any?, _ right: Any?) -> Bool {
        guard let l = parseISODate(left), let r = parseISODate(right) else { return false }
        return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 0.001
    }

    static func parseISODate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Orca fixtures sometimes use `+00:00` which ISO8601DateFormatter accepts
        // with internet datetime; try replacing space variants if any.
        return nil
    }

    private static func retryAfterDate(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    static func errorSnapshot(_ error: UsageError, fetchedAt: Date) -> UsageSnapshot {
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
    static func locateGrokBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.grok/bin/grok",
            "\(home)/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
            "\(home)/.npm-global/bin/grok",
            "\(home)/.bun/bin/grok",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let candidate = "\(nvmRoot)/\(version)/bin/grok"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}

// MARK: - Snapshot helper

private extension UsageSnapshot {
    func withFetchedAt(_ date: Date) -> UsageSnapshot {
        var copy = self
        copy.fetchedAt = date
        return copy
    }
}
