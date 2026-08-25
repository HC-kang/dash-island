import Foundation
import Security

enum AgyAdapterError: Error, Equatable, LocalizedError {
    case agyBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(home: String)
    case credentialsMissing(home: String)
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
            Antigravity login timed out. Complete browser sign-in, or run:

              HOME='\(home)' agy

            Then choose Reauthenticate (or remove and re-add).
            """
        case .credentialsMissing(let home):
            return """
            Antigravity login finished but no oauth_creds.json was found. Run:

              HOME='\(home)' agy
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
/// so login writes `$HOME/.gemini/oauth_creds.json`, never the user’s default
/// `~/.gemini`. Leftover-session guards match Claude.
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
    private static let pollNanos: UInt64 = 1_000_000_000

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
            try await runLogin(home: dir)
            try await Self.verifyUsageAccess(home: dir)
            _ = try Self.requireCredentials(home: dir)
            return ref
        } catch {
            if let prior {
                try? Self.persistCredentialsFile(prior, home: dir)
            }
            if let error = error as? AgyAdapterError { throw error }
            throw AgyAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        guard let creds = await Self.freshCredentials(home: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        return await Self.probeUsage(token: creds.accessToken, home: dir, fetchedAt: now)
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
        if readCredentials(home: home) == nil, let harvested = captureLoginCredentials(home: home) {
            try? persistCredentialsFile(harvested, home: home)
        }
        guard readCredentials(home: home) != nil else {
            throw AgyAdapterError.reauthFailed("No credentials written.")
        }
        guard let creds = await freshCredentials(home: home) else {
            throw AgyAdapterError.reauthFailed(
                """
                Antigravity session is expired. A Terminal window should have \
                opened — sign in with agy, then retry Reauthenticate.
                """
            )
        }
        let snap = await probeUsage(token: creds.accessToken, home: home, fetchedAt: Date())
        switch usageSmokeDecision(snap) {
        case .pass:
            return
        case .softKeep:
            NSLog("DashIsland: Agy token smoke-test soft error %@", String(describing: snap.error))
        case .reject:
            throw AgyAdapterError.reauthFailed(
                """
                Token rejected by Google. Use Reauthenticate → browser login:
                  HOME='\(home.path)' agy
                """
            )
        }
    }

    static func clearManagedCredentials(home: URL) {
        let fm = FileManager.default
        let paths = [
            home.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(credsFileName, isDirectory: false),
        ]
        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        CredentialStore.removeLastGoodUsage(inDirectory: home)
        NSLog("DashIsland: cleared Agy managed creds at %@", home.path)
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

    private func runLogin(
        home: URL,
        priorAccessToken _: String? = nil,
        priorRefreshToken _: String? = nil
    ) async throws {
        guard let binary = Self.locateAgyBinary() else {
            throw AgyAdapterError.agyBinaryNotFound
        }
        func accept(_ creds: AgyCreds) -> Bool { Self.isFresh(creds) }

        // Keychain harvest is not enough when access is already expired.
        // Claude pattern: let the CLI refresh, then re-read the store.
        if let creds = Self.captureLoginCredentials(home: home), !creds.accessToken.isEmpty {
            if accept(creds) {
                try Self.persistCredentialsFile(creds, home: home)
                return
            }
            if let pinged = await Self.pingCLIThenHarvest(
                home: home,
                failedAccessToken: creds.accessToken
            ), accept(pinged) {
                try Self.persistCredentialsFile(pinged, home: home)
                return
            }
        }

        do {
            try Self.launchVisibleLogin(binary: binary, home: home)
        } catch {
            throw AgyAdapterError.spawnFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.loginTimeout)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if let creds = Self.captureLoginCredentials(home: home), accept(creds) {
                try Self.persistCredentialsFile(creds, home: home)
                return
            }
            try await Task.sleep(nanoseconds: Self.pollNanos)
        }
        if let creds = Self.captureLoginCredentials(home: home), accept(creds) {
            try Self.persistCredentialsFile(creds, home: home)
            return
        }
        throw AgyAdapterError.loginTimeout(home: home.path)
    }

    /// File first, then the CLI's global Keychain blob (one-shot copy into the
    /// managed folder). Never writes Keychain.
    static func captureLoginCredentials(home: URL) -> AgyCreds? {
        if let file = readCredentials(home: home) { return file }
        return readKeychainCredentials()
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

    private static func readKeychainCredentials() -> AgyCreds? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return parseKeychainBlob(data)
    }

    /// TTY login in Terminal.app. Piped `agy` never shows the sign-in UI.
    static func launchVisibleLogin(binary: String, home: URL) throws {
        let script = home.appendingPathComponent(".dash-island-agy-login.command")
        let body = """
        #!/bin/zsh
        export HOME=\(shellEscape(home.path))
        unset GEMINI_API_KEY GOOGLE_API_KEY
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
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw AgyAdapterError.spawnFailed("open Terminal failed (\(task.terminationStatus))")
        }
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func requireCredentials(home: URL) throws -> AgyCreds {
        if let creds = readCredentials(home: home) {
            return creds
        }
        throw AgyAdapterError.credentialsMissing(home: home.path)
    }

    struct AgyCreds: Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
    }

    static func readCredentials(home: URL) -> AgyCreds? {
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
        try data.write(to: path, options: .atomic)
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
            return UsageSnapshot(
                primary: WindowUsage(usedFraction: 0, kind: .unknown),
                plan: "agy",
                fetchedAt: fetchedAt
            )
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
                return errorSnapshot(.rateLimited(retryAfter: nil), fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: fetchedAt)
            }
        } catch let error as AgyAdapterError {
            switch error {
            case .reauthFailed(let message) where message.contains("401") || message.contains("403"):
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.unavailable(error.localizedDescription), fetchedAt: fetchedAt)
            }
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
            }
            return errorSnapshot(.unavailable(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    /// Refresh when access is missing expiry or expires within 5 minutes.
    /// Google POST first; if that fails, Claude-style CLI ping then re-harvest.
    static func freshCredentials(home: URL) async -> AgyCreds? {
        if readCredentials(home: home) == nil, let harvested = captureLoginCredentials(home: home) {
            try? persistCredentialsFile(harvested, home: home)
        }
        guard var creds = readCredentials(home: home) else { return nil }
        if isFresh(creds, slack: 5 * 60) { return creds }
        let expired = creds.expiryDate.map { $0 <= Date() } ?? false
        if let refresh = creds.refreshToken, !refresh.isEmpty,
           let next = await refreshAccessToken(refresh)
        {
            creds.accessToken = next.access
            if let rotated = next.refresh, !rotated.isEmpty { creds.refreshToken = rotated }
            if let expiresIn = next.expiresIn {
                creds.expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            try? persistCredentialsFile(creds, home: home)
            return creds
        }
        if let pinged = await pingCLIThenHarvest(home: home, failedAccessToken: creds.accessToken) {
            try? persistCredentialsFile(pinged, home: home)
            return pinged
        }
        return expired ? nil : creds
    }

    static var refreshPingSpawner: ((URL) async -> Bool)?

    static func pingCLIThenHarvest(home: URL, failedAccessToken: String?) async -> AgyCreds? {
        if pingRecentlyAttempted(home: home) { return nil }
        markPingAttempted(home: home)
        let beforeExpiry = captureLoginCredentials(home: home)?.expiryDate
        let spawned: Bool
        if let refreshPingSpawner {
            spawned = await refreshPingSpawner(home)
        } else {
            spawned = await spawnManagedRefreshPing()
        }
        guard spawned else { return nil }
        let deadline = Date().addingTimeInterval(55)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let creds = captureLoginCredentials(home: home), isFresh(creds) {
                if creds.accessToken != failedAccessToken { return creds }
                if let exp = creds.expiryDate, let before = beforeExpiry, exp > before {
                    return creds
                }
                if creds.accessToken != failedAccessToken || beforeExpiry == nil {
                    return creds
                }
            }
        }
        if let creds = captureLoginCredentials(home: home), isFresh(creds) {
            return creds
        }
        return nil
    }

    private static func pingDefaultsKey(home: URL) -> String {
        "DashIsland.AgyCLIPing.\(home.path)"
    }

    static func pingRecentlyAttempted(home: URL, now: Date = Date()) -> Bool {
        let t = UserDefaults.standard.double(forKey: pingDefaultsKey(home: home))
        guard t > 0 else { return false }
        return now.timeIntervalSince(Date(timeIntervalSince1970: t)) < 6 * 3600
    }

    static func markPingAttempted(home: URL, now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: pingDefaultsKey(home: home))
    }

    /// `agy --print ok` refreshes the global Keychain session (Claude's
    /// `claude -p` analogue). HOME is *not* overridden so the CLI hits the
    /// same `gemini`/`antigravity` item we harvest.
    static func spawnManagedRefreshPing() async -> Bool {
        guard let path = locateAgyBinary() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--print", "ok", "--print-timeout", "45s", "--output-format", "text"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_API_KEY")
        task.environment = env
        task.currentDirectoryPath = NSHomeDirectory()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("DashIsland: Agy CLI ping failed %@", error.localizedDescription)
            return false
        }
        let deadline = Date().addingTimeInterval(50)
        while task.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if task.isRunning { task.terminate() }
        NSLog("DashIsland: Agy CLI ping finished")
        return true
    }

    private static func refreshAccessToken(_ refreshToken: String) async -> (
        access: String,
        refresh: String?,
        expiresIn: Int?
    )? {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var parts: [String] = []
        let form = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func add(_ k: String, _ v: String) {
            let ek = k.addingPercentEncoding(withAllowedCharacters: form) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: form) ?? v
            parts.append("\(ek)=\(ev)")
        }
        guard let client = oauthClientFromAgyBinary() else {
            NSLog("DashIsland: Agy OAuth client not found in agy binary")
            return nil
        }
        add("client_id", client.id)
        add("client_secret", client.secret)
        add("refresh_token", refreshToken)
        add("grant_type", "refresh_token")
        req.httpBody = parts.joined(separator: "&").data(using: .utf8)
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty
            else {
                NSLog("DashIsland: Agy token refresh failed")
                return nil
            }
            let rotated = obj["refresh_token"] as? String
            let expiresIn = obj["expires_in"] as? Int
            return (access, rotated, expiresIn)
        } catch {
            NSLog("DashIsland: Agy token refresh error %@", error.localizedDescription)
            return nil
        }
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
            throw AgyAdapterError.reauthFailed("loadCodeAssist failed")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgyAdapterError.reauthFailed("loadCodeAssist HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgyAdapterError.reauthFailed("Antigravity project ID not found")
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
            throw AgyAdapterError.reauthFailed("Antigravity project ID not found")
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

    private static func remainingFraction(_ quota: [String: Any]) -> Double? {
        if let n = quota["remainingFraction"] as? Double { return n }
        if let n = quota["remainingFraction"] as? Int { return Double(n) }
        return nil
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
        if source.contains("day") || source.contains("daily") || source.contains("24h") {
            return .fiveHour
        }
        return .fiveHour
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

    /// Installed-app OAuth client is embedded in the `agy` binary; never commit it.
    static func oauthClientFromAgyBinary() -> (id: String, secret: String)? {
        if let cachedOAuthClient { return cachedOAuthClient }
        guard let path = locateAgyBinary(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let id = scanEmbeddedClientID(data),
              let secret = scanEmbeddedClientSecret(data)
        else { return nil }
        cachedOAuthClient = (id, secret)
        return cachedOAuthClient
    }

    private static func scanEmbeddedClientID(_ data: Data) -> String? {
        let marker = Data(".apps.googleusercontent.com".utf8)
        guard let range = data.range(of: marker) else { return nil }
        var start = range.lowerBound
        while start > 0 {
            let b = data[data.index(before: start)]
            let ok = (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || b == 45
            if !ok { break }
            start = data.index(before: start)
        }
        return String(data: data[start..<range.upperBound], encoding: .ascii)
    }

    private static func scanEmbeddedClientSecret(_ data: Data) -> String? {
        let marker = Data("GOCSPX-".utf8)
        guard let range = data.range(of: marker) else { return nil }
        var end = range.upperBound
        while end < data.endIndex {
            let b = data[end]
            let ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90)
                || (b >= 97 && b <= 122) || b == 45 || b == 95
            if !ok { break }
            end = data.index(after: end)
        }
        return String(data: data[range.lowerBound..<end], encoding: .ascii)
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

    private static func errorSnapshot(_ error: UsageError, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            plan: nil,
            fetchedAt: fetchedAt,
            error: error
        )
    }
}
