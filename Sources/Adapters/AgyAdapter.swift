import Foundation
import Security

enum AgyAdapterError: Error, Equatable, LocalizedError {
    case agyBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(home: String)
    case reauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .agyBinaryNotFound:
            return """
            Could not find the Antigravity CLI (`agy`). Install it, then retry:

              curl -fsSL https://antigravity.google/cli/install.sh | bash
            """
        case .spawnFailed(let message):
            return "Failed to start Antigravity login: \(message)"
        case .loginTimeout(let home):
            return """
            Antigravity login timed out. Finish sign-in in the Terminal window, or run:

              HOME='\(home)' agy

            Then choose Reauthenticate (or remove and re-add).
            """
        case .reauthFailed(let message):
            return message
        }
    }
}

/// Antigravity CLI (`agy`) — Gemini CLI’s replacement.
///
/// Usage: `POST daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
/// (oh-my-pi / Orca-proven). Credentials live under the managed folder as `HOME`
/// so login writes `$HOME/.gemini/…`, never the user’s default `~/.gemini`.
/// Sign-in is a visible `agy` in Terminal; reauth first extends the stored
/// session over HTTP and, like Claude, only accepts a *new* session from login.
struct AgyAdapter: VendorAdapter {
    let id: VendorID = "agy"
    let displayName = "Antigravity"
    let minPollSeconds = 300

    private static let modelsURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    )!
    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userAgent = "antigravity/hub/2.1.4 darwin/arm64"
    private static let credsFileName = "oauth_creds.json"
    private static let loginTimeout: TimeInterval = 180

    func beginAdd() async throws -> AddAccountResult {
        let accountID = UUID()
        let ref = accountID.uuidString
        do {
            let dir = try CredentialStore.createDirectory(for: ref)
            do {
                try await runLogin(home: dir)
                try await Self.verifyUsageAccess(home: dir)
                let short = String(ref.prefix(8))
                return AddAccountResult(vendorID: id, label: "Agy \(short)", credentialRef: ref)
            } catch {
                Self.clearManagedCredentials(home: dir)
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
        let prior = Self.readCredentials(home: dir)
        do {
            // Extend the stored session first: no Terminal while its refresh token works.
            if let prior, let refresh = prior.refreshToken, !refresh.isEmpty {
                switch await Self.refreshAccessToken(refresh) {
                case .success(let access, let rotated, let expiresIn):
                    let next = Self.extended(prior, access: access, rotated: rotated, expiresIn: expiresIn)
                    try Self.persistCredentialsFile(next, home: dir)
                    let snap = await Self.probeUsage(token: next.accessToken, home: dir, fetchedAt: Date())
                    if Self.usageSmokeDecision(snap) != .reject { return ref }
                    Log.auth.info("reauth vendor=agy step=login reason=usageRejected")
                case .failed:
                    // Token host busy: the session is still ours, polls retry.
                    return ref
                case .invalidGrant:
                    Log.auth.info("reauth vendor=agy step=login reason=invalidGrant")
                }
            }
            // A stored session makes `agy` start signed in, so the user could
            // never switch accounts. Keep it aside until the new one is accepted.
            let stash = CredentialStore.PriorFiles.stash(Self.sessionFiles(home: dir))
            do {
                try await runLogin(
                    home: dir,
                    priorAccessToken: prior?.accessToken,
                    priorRefreshToken: prior?.refreshToken
                )
                try await Self.verifyUsageAccess(home: dir)
                stash.discard()
                return ref
            } catch {
                stash.restore()
                throw error
            }
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? AgyAdapterError { throw error }
            throw AgyAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        switch await Self.freshCredentials(home: dir) {
        case .ok(let creds):
            return await Self.probeUsage(token: creds.accessToken, home: dir, fetchedAt: now)
        case .needsReauth:
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        case .retryLater:
            return Self.errorSnapshot(
                .unavailable("token refresh failed — retrying"),
                fetchedAt: now
            )
        }
    }

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

    static func isFresh(_ creds: AgyCreds, slack: TimeInterval = 60) -> Bool {
        guard !creds.accessToken.isEmpty else { return false }
        guard let exp = creds.expiryDate else { return true }
        return exp.timeIntervalSinceNow > slack
    }

    static func verifyUsageAccess(home: URL) async throws {
        guard readCredentials(home: home) != nil else {
            throw AgyAdapterError.reauthFailed("No credentials written.")
        }
        let creds: AgyCreds
        switch await freshCredentials(home: home) {
        case .ok(let live):
            creds = live
        case .needsReauth:
            throw AgyAdapterError.reauthFailed(
                "Google refresh token was revoked. Sign in with agy, then retry."
            )
        case .retryLater:
            throw AgyAdapterError.reauthFailed(
                "Token refresh failed. Retry Reauthenticate in a moment."
            )
        }
        let snap = await probeUsage(token: creds.accessToken, home: home, fetchedAt: Date())
        switch usageSmokeDecision(snap) {
        case .pass:
            return
        case .softKeep:
            Log.auth.info("smoke-test vendor=agy outcome=soft error=\(String(describing: snap.error))")
        case .reject:
            throw AgyAdapterError.reauthFailed(
                """
                Token rejected by Google. Use Reauthenticate → browser login:
                  HOME='\(home.path)' agy
                """
            )
        }
    }

    /// Every file that holds this account's session: ours and the CLI's.
    static func sessionFiles(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(cliTokenPath, isDirectory: false),
        ]
    }

    static func clearManagedCredentials(home: URL) {
        let fm = FileManager.default
        for path in sessionFiles(home: home) where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        CredentialStore.removeLastGoodUsage(inDirectory: home)
        Log.auth.info("clearCreds vendor=agy dir=\(home.path)")
    }

    static func isAcceptableLogin(
        _ creds: AgyCreds,
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

    /// Visible `agy` sign-in in Terminal with `HOME` = the managed folder.
    /// `agy` without a TTY never shows its sign-in UI, and the old hidden
    /// `agy --print` ran against the *global* session, so Add waited 3 minutes
    /// for a file that never came. No model request runs on this path.
    private func runLogin(
        home: URL,
        priorAccessToken: String? = nil,
        priorRefreshToken: String? = nil
    ) async throws {
        guard let binary = Self.locateAgyBinary() else {
            throw AgyAdapterError.agyBinaryNotFound
        }
        do {
            try await Self.launchVisibleLogin(binary: binary, home: home)
            let creds = try await Self.waitForLogin(
                home: home,
                priorAccessToken: priorAccessToken,
                priorRefreshToken: priorRefreshToken,
                timeout: Self.loginTimeout
            )
            try Self.persistCredentialsFile(creds, home: home)
            Self.removeLoginScript(home: home)
        } catch {
            // Cancel / timeout: end the Terminal `agy` so it cannot finish a
            // sign-in into a folder we are about to restore or delete.
            Self.stopVisibleLogin(home: home)
            throw error
        }
    }

    /// Poll the managed files until `agy` writes a *new*, unexpired session.
    /// The prior session (same access or refresh token) never counts.
    static func waitForLogin(
        home: URL,
        priorAccessToken: String?,
        priorRefreshToken: String?,
        timeout: TimeInterval,
        pollNanos: UInt64 = 1_000_000_000
    ) async throws -> AgyCreds {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let creds = readCredentials(home: home),
               isFresh(creds),
               isAcceptableLogin(
                   creds,
                   priorAccessToken: priorAccessToken,
                   priorRefreshToken: priorRefreshToken
               )
            {
                return creds
            }
            if Date() >= deadline {
                throw AgyAdapterError.loginTimeout(home: home.path)
            }
            try await Task.sleep(nanoseconds: pollNanos)
        }
    }

    static func extended(
        _ creds: AgyCreds,
        access: String,
        rotated: String?,
        expiresIn: Int?
    ) -> AgyCreds {
        var next = creds
        next.accessToken = access
        if let rotated, !rotated.isEmpty { next.refreshToken = rotated }
        if let expiresIn {
            next.expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        return next
    }

    /// Later expiry wins. CLI login writes `antigravity-oauth-token` and
    /// Keychain; `oauth_creds.json` is often a stale harvest.
    static func preferFresher(_ candidates: AgyCreds?...) -> AgyCreds? {
        candidates.compactMap { $0 }.filter { !$0.accessToken.isEmpty }
            .max { a, b in
                (a.expiryDate ?? .distantPast) < (b.expiryDate ?? .distantPast)
            }
    }

    /// Copy the freshest store (CLI file / Keychain) into oauth_creds.json.
    static func syncManagedCredentials(
        home: URL,
        includeKeychain: Bool = false,
        allowPrompt: Bool = false
    ) {
        guard let live = captureLoginCredentials(
            home: home,
            includeKeychain: includeKeychain,
            allowPrompt: allowPrompt
        ) else { return }
        if let file = readOAuthCredsJSONFile(home: home),
           file.accessToken == live.accessToken,
           (file.expiryDate ?? .distantPast) >= (live.expiryDate ?? .distantPast)
        {
            return
        }
        try? persistCredentialsFile(live, home: home)
    }

    /// Files always. Keychain only when asked — polling it pops the password sheet.
    static func captureLoginCredentials(
        home: URL,
        includeKeychain: Bool = false,
        allowPrompt: Bool = false
    ) -> AgyCreds? {
        preferFresher(
            readOAuthCredsJSONFile(home: home),
            readCLITokenFile(home: home),
            includeKeychain ? readKeychainCredentials(allowPrompt: allowPrompt) : nil
        )
    }

    static func parseKeychainBlob(_ data: Data) -> AgyCreds? {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload: Data
        if raw.hasPrefix("go-keyring-base64:") {
            let b64 = String(raw.dropFirst("go-keyring-base64:".count))
            guard let decoded = Data(base64Encoded: b64) else { return nil }
            payload = decoded
        } else if let decoded = Data(base64Encoded: raw) {
            payload = decoded
        } else {
            payload = data
        }
        if let nested = parseOAuthCredsJSON(payload) { return nested }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let token = (obj["token"] as? [String: Any]) ?? obj
        guard let access = token["access_token"] as? String, !access.isEmpty else { return nil }
        let refresh = token["refresh_token"] as? String
        let expiry: Date?
        if let s = token["expiry"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            expiry = iso.date(from: s) ?? plain.date(from: s)
        } else {
            expiry = nil
        }
        return AgyCreds(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiryDate: expiry
        )
    }

    private static func readKeychainCredentials(allowPrompt: Bool) -> AgyCreds? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: allowPrompt
                ? kSecUseAuthenticationUIAllow
                : kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return parseKeychainBlob(data)
    }

    private static let loginScriptName = ".dash-island-agy-login.command"
    private static let loginPIDName = ".dash-island-agy-login.pid"

    /// TTY login in Terminal.app. Piped `agy` never shows the sign-in UI.
    /// The script records its PID (`exec` keeps it) so Cancel can end `agy`.
    static func launchVisibleLogin(binary: String, home: URL) async throws {
        let script = home.appendingPathComponent(loginScriptName)
        let pidFile = home.appendingPathComponent(loginPIDName)
        let body = """
        #!/bin/zsh
        export HOME=\(shellEscape(home.path))
        unset GEMINI_API_KEY GOOGLE_API_KEY
        echo $$ > \(shellEscape(pidFile.path))
        echo "Dash Island — sign in to Antigravity, then close this window."
        exec \(shellEscape(binary))
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", script.path]
        do {
            try task.run()
        } catch {
            throw AgyAdapterError.spawnFailed(error.localizedDescription)
        }
        guard await LoginProcess.waitForExit(task, timeout: 15),
              task.terminationStatus == 0
        else {
            throw AgyAdapterError.spawnFailed("open Terminal failed")
        }
        Log.auth.info("login vendor=agy step=terminal")
    }

    /// End the Terminal `agy` of a cancelled or failed login.
    static func stopVisibleLogin(home: URL) {
        let pidFile = home.appendingPathComponent(loginPIDName)
        if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1
        {
            kill(pid, SIGTERM)
        }
        removeLoginScript(home: home)
    }

    private static func removeLoginScript(home: URL) {
        try? FileManager.default.removeItem(at: home.appendingPathComponent(loginPIDName))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(loginScriptName))
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct AgyCreds: Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
    }

    static func readCredentials(home: URL) -> AgyCreds? {
        preferFresher(
            readOAuthCredsJSONFile(home: home),
            readCLITokenFile(home: home)
        )
    }

    static func readOAuthCredsJSONFile(home: URL) -> AgyCreds? {
        let candidates = [
            home.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(credsFileName, isDirectory: false),
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: path),
               let creds = parseOAuthCredsJSON(data)
            {
                return creds
            }
        }
        return nil
    }

    private static let cliTokenPath = ".gemini/antigravity-cli/antigravity-oauth-token"

    static func readCLITokenFile(home: URL) -> AgyCreds? {
        let path = home.appendingPathComponent(cliTokenPath, isDirectory: false)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parseKeychainBlob(data)
    }

    static func parseOAuthCredsJSON(_ data: Data) -> AgyCreds? {
        guard let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = blob["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        let refresh = blob["refresh_token"] as? String
        let expiry: Date?
        if let ms = blob["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = blob["expiry_date"] as? Int {
            expiry = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            expiry = nil
        }
        return AgyCreds(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiryDate: expiry
        )
    }

    static func persistCredentialsFile(_ creds: AgyCreds, home: URL) throws {
        let dir = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var blob: [String: Any] = ["access_token": creds.accessToken]
        if let refresh = creds.refreshToken { blob["refresh_token"] = refresh }
        if let expiry = creds.expiryDate {
            blob["expiry_date"] = expiry.timeIntervalSince1970 * 1000
        }
        let data = try JSONSerialization.data(withJSONObject: blob, options: [.prettyPrinted])
        let path = dir.appendingPathComponent(credsFileName, isDirectory: false)
        try CredentialStore.writeSecret(data, to: path)
    }

    /// `fetchAvailableModels` → rings. Dedupes shared quota counters (oh-my-pi).
    static func parseAvailableModelsResponse(data: Data, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: Any]
        else {
            return errorSnapshot(.parse("missing models"), fetchedAt: fetchedAt)
        }

        var windows: [WindowUsage] = []
        var seen = Set<String>()
        for (modelId, raw) in models {
            guard let info = raw as? [String: Any] else { continue }
            for quota in quotaInfos(from: info) {
                guard let remaining = remainingFraction(quota), remaining.isFinite else { continue }
                let used = min(1, max(0, 1 - remaining))
                let kind = windowKind(quota)
                let reset = parseResetTime(quota["resetTime"])
                let label = (info["displayName"] as? String)
                    ?? shortModelLabel(modelId)
                let key = "\(Int((used * 1000).rounded()))-\(kind.rawValue)-\(reset?.timeIntervalSince1970 ?? 0)"
                if seen.contains(key) { continue }
                seen.insert(key)
                windows.append(
                    WindowUsage(
                        usedFraction: used,
                        resetAt: reset,
                        kind: kind,
                        labelOverride: label
                    )
                )
            }
        }
        windows.sort { $0.usedFraction > $1.usedFraction }
        guard let primary = windows.first else {
            // No quota at all is "not reported", never a real 0%.
            var empty = WindowUsage(usedFraction: 0, kind: .unknown)
            empty.reported = false
            return UsageSnapshot(primary: empty, plan: "agy", fetchedAt: fetchedAt)
        }
        let extras = Array(windows.dropFirst())
        let weekly = extras.first(where: { $0.kind == .weekly })
        let rest = extras.filter { $0 != weekly }
        let tertiary = UsageRingLayout.preferredTertiary(from: rest)
        return UsageSnapshot(
            primary: primary,
            secondary: weekly,
            tertiary: tertiary,
            extras: UsageRingLayout.remainingExtras(extras: rest, tertiary: tertiary),
            plan: "agy",
            fetchedAt: fetchedAt
        )
    }

    static func probeUsage(token: String, home: URL? = nil, fetchedAt: Date) async -> UsageSnapshot {
        do {
            let project = try await loadProjectID(token: token, home: home)
            var req = URLRequest(url: modelsURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 12
            req.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return errorSnapshot(.network("bad response"), fetchedAt: fetchedAt)
            }
            switch http.statusCode {
            case 200:
                return parseAvailableModelsResponse(data: data, fetchedAt: fetchedAt)
            case 401, 403:
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case 429:
                return errorSnapshot(.rateLimited(retryAfter: retryAfterDate(from: http)), fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: fetchedAt)
            }
        } catch let error as CodeAssistError {
            switch error {
            case .http(let status) where status == 401 || status == 403:
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case .http(let status):
                return errorSnapshot(.unavailable("loadCodeAssist HTTP \(status)"), fetchedAt: fetchedAt)
            case .noProject:
                return errorSnapshot(.unavailable("Antigravity project ID not found"), fetchedAt: fetchedAt)
            }
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
            }
            return errorSnapshot(.unavailable(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    enum FreshResult {
        case ok(AgyCreds)
        case needsReauth
        case retryLater
    }

    /// Extend from the file's refresh_token. Never spawn `agy` or touch Keychain.
    static func freshCredentials(home: URL) async -> FreshResult {
        syncManagedCredentials(home: home, includeKeychain: false)
        guard var creds = readCredentials(home: home) else { return .needsReauth }
        if isFresh(creds, slack: 5 * 60) { return .ok(creds) }
        guard let refresh = creds.refreshToken, !refresh.isEmpty else {
            return .needsReauth
        }
        switch await refreshAccessToken(refresh) {
        case .success(let access, let rotated, let expiresIn):
            creds = extended(creds, access: access, rotated: rotated, expiresIn: expiresIn)
            do {
                try persistCredentialsFile(creds, home: home)
            } catch {
                Log.auth.error("refresh vendor=agy outcome=writeFailed error=\(error.localizedDescription)")
                return .retryLater
            }
            return .ok(creds)
        case .invalidGrant:
            return .needsReauth
        case .failed:
            return .retryLater
        }
    }

    enum TokenRefreshResult {
        case success(access: String, refresh: String?, expiresIn: Int?)
        case invalidGrant
        case failed
    }

    private static func refreshAccessToken(_ refreshToken: String) async -> TokenRefreshResult {
        let ids = oauthClientIDsFromAgyBinary()
        let secrets = oauthSecretsFromAgyBinary()
        guard !ids.isEmpty, !secrets.isEmpty else {
            Log.auth.warn("refresh vendor=agy outcome=failed reason=oauthClientNotFound")
            return .failed
        }
        var last: TokenRefreshResult = .failed
        for id in ids {
            for secret in secrets {
                let result = await refreshAccessToken(
                    refreshToken,
                    clientID: id,
                    clientSecret: secret
                )
                switch result {
                case .success:
                    cachedOAuthClient = (id, secret)
                    return result
                case .invalidGrant:
                    last = .invalidGrant
                case .failed:
                    continue
                }
            }
        }
        return last
    }

    private static func refreshAccessToken(
        _ refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async -> TokenRefreshResult {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let form = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: form) ?? s
        }
        let body = [
            "client_id=\(enc(clientID))",
            "client_secret=\(enc(clientSecret))",
            "refresh_token=\(enc(refreshToken))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200,
               let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let access = obj["access_token"] as? String, !access.isEmpty
            {
                let rotated = obj["refresh_token"] as? String
                let expiresIn = obj["expires_in"] as? Int
                    ?? (obj["expires_in"] as? Double).map { Int($0) }
                return .success(access: access, refresh: rotated, expiresIn: expiresIn)
            }
            // Wrong client pair (invalid_client) tries the next one; a busy host
            // retries later. Only a dead grant asks for a new sign-in.
            switch TokenHostFailure.classify(status: status, body: data, retryAfter: nil) {
            case .rejected:
                Log.auth.warn("refresh vendor=agy outcome=invalid_grant http=\(status)")
                return .invalidGrant
            case .badClient, .unavailable:
                Log.auth.warn("refresh vendor=agy http=\(status)")
                return .failed
            }
        } catch {
            Log.auth.warn("refresh vendor=agy outcome=failed error=\(error.localizedDescription)")
            return .failed
        }
    }

    /// `loadCodeAssist` failure, typed: 401/403 used to be found by substring.
    enum CodeAssistError: Error, Equatable {
        case http(Int)
        case noProject
    }

    private static func loadProjectID(token: String, home: URL?) async throws -> String {
        if let home, let cached = readCachedProjectID(home: home) {
            return cached
        }
        var req = URLRequest(url: loadCodeAssistURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        req.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "metadata": [
                    "ideType": "ANTIGRAVITY",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ]
            ]
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CodeAssistError.http(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodeAssistError.http(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeAssistError.noProject
        }
        let project: String?
        if let s = obj["cloudaicompanionProject"] as? String, !s.isEmpty {
            project = s
        } else if let wrapped = obj["cloudaicompanionProject"] as? [String: Any],
                  let s = wrapped["id"] as? String, !s.isEmpty
        {
            project = s
        } else {
            project = nil
        }
        guard let project else {
            throw CodeAssistError.noProject
        }
        if let home { writeCachedProjectID(project, home: home) }
        return project
    }

    private static func cachedProjectURL(home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/cache/default_project_id.txt")
    }

    private static func readCachedProjectID(home: URL) -> String? {
        let raw = try? String(contentsOf: cachedProjectURL(home: home), encoding: .utf8)
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty || id == "default-cli-project" ? nil : id
    }

    private static func writeCachedProjectID(_ id: String, home: URL) {
        let url = cachedProjectURL(home: home)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? id.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func quotaInfos(from info: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func append(_ raw: Any?) {
            if let dict = raw as? [String: Any] { out.append(dict) }
            if let arr = raw as? [Any] {
                for item in arr {
                    if let dict = item as? [String: Any] { out.append(dict) }
                }
            }
        }
        append(info["quotaInfo"])
        append(info["quotaInfos"])
        append(info["dailyQuotaInfo"])
        append(info["dailyQuotaInfos"])
        append(info["weeklyQuotaInfo"])
        append(info["weeklyQuotaInfos"])
        return out
    }

    /// proto3 JSON omits zero values: a quota with a reset time but no
    /// fraction is spent — the one model that matters most.
    private static func remainingFraction(_ quota: [String: Any]) -> Double? {
        if let n = quota["remainingFraction"] as? Double { return n }
        if let n = quota["remainingFraction"] as? Int { return Double(n) }
        return quota["resetTime"] != nil ? 0 : nil
    }

    private static func windowKind(_ quota: [String: Any]) -> UsageWindowKind {
        let source = [
            quota["windowId"] as? String,
            quota["windowLabel"] as? String,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if source.contains("week") || source.contains("7d") { return .weekly }
        if source.contains("month") { return .monthly }
        // Daily or unlabeled windows are not 5h: a "5h" label and 5h burn
        // pace were wrong for them. `.unknown` has no domain kind to lie with.
        return .unknown
    }

    private static func parseResetTime(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return iso.date(from: s) ?? plain.date(from: s)
        }
        return nil
    }

    static func shortModelLabel(_ modelId: String) -> String {
        let trimmed = modelId.replacingOccurrences(of: "gemini-", with: "", options: .caseInsensitive)
        return trimmed.isEmpty ? modelId : trimmed
    }

    private static var cachedOAuthClient: (id: String, secret: String)?

    /// Installed-app OAuth clients embedded in `agy`. The binary has more than
    /// one googleusercontent id; the first hit is often the wrong one.
    static func oauthClientIDsFromAgyBinary() -> [String] {
        if let cachedOAuthClient { return [cachedOAuthClient.id] }
        return loadBinaryOAuth().ids
    }

    static func oauthSecretsFromAgyBinary() -> [String] {
        if let cachedOAuthClient { return [cachedOAuthClient.secret] }
        return loadBinaryOAuth().secrets
    }

    private static var cachedBinaryOAuth: (ids: [String], secrets: [String])?

    private static func loadBinaryOAuth() -> (ids: [String], secrets: [String]) {
        if let cachedBinaryOAuth { return cachedBinaryOAuth }
        guard let path = locateAgyBinary(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return ([], []) }
        let loaded = (
            ids: Array(scanEmbeddedClientIDs(data).reversed()),
            secrets: scanEmbeddedClientSecrets(data)
        )
        cachedBinaryOAuth = loaded
        return loaded
    }

    /// Google installed-app IDs are `{digits}-{slug}.apps.googleusercontent.com`.
    /// Walking back through letters ate a preceding `it` (`it1071006060591-…`)
    /// so HTTP refresh used a client that does not exist.
    static func scanEmbeddedClientIDs(_ data: Data) -> [String] {
        let marker = Data(".apps.googleusercontent.com".utf8)
        var ids: [String] = []
        var search = data.startIndex
        while search < data.endIndex,
              let range = data[search...].range(of: marker)
        {
            var start = range.lowerBound
            while start > data.startIndex {
                let b = data[data.index(before: start)]
                let ok = (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || b == 45
                if !ok { break }
                start = data.index(before: start)
            }
            if var id = String(data: data[start..<range.upperBound], encoding: .ascii) {
                while let first = id.first, !first.isNumber {
                    id.removeFirst()
                }
                if id.first?.isNumber == true,
                   id.contains("-"),
                   id.hasSuffix(".apps.googleusercontent.com"),
                   !ids.contains(id)
                {
                    ids.append(id)
                }
            }
            search = range.upperBound
        }
        return ids
    }

    /// Secrets are packed back-to-back (`GOCSPX-…GOCSPX-…https://`). Stop at the
    /// next marker or `http` so we don't swallow a URL.
    private static func scanEmbeddedClientSecrets(_ data: Data) -> [String] {
        let marker = Data("GOCSPX-".utf8)
        let http = Data("http".utf8)
        var secrets: [String] = []
        var search = data.startIndex
        while search < data.endIndex, let range = data[search...].range(of: marker) {
            let bodyStart = range.upperBound
            var bodyEnd = data.index(bodyStart, offsetBy: 40, limitedBy: data.endIndex) ?? data.endIndex
            if let next = data[bodyStart...].range(of: marker) {
                bodyEnd = min(bodyEnd, next.lowerBound)
            }
            if let ht = data[bodyStart...].range(of: http) {
                bodyEnd = min(bodyEnd, ht.lowerBound)
            }
            var end = bodyStart
            while end < bodyEnd {
                let b = data[end]
                let ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90)
                    || (b >= 97 && b <= 122) || b == 45 || b == 95
                if !ok { break }
                end = data.index(after: end)
            }
            if let s = String(data: data[range.lowerBound..<end], encoding: .ascii),
               s.count >= 20, s.count <= 50, !secrets.contains(s)
            {
                secrets.append(s)
            }
            search = range.upperBound
        }
        return secrets
    }

    static func locateAgyBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["AGY_BIN"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["agy"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func retryAfterDate(from http: HTTPURLResponse) -> Date? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw)
        else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private static func errorSnapshot(_ error: UsageError, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            plan: nil,
            fetchedAt: fetchedAt,
            error: error
        )
    }
}
