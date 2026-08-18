import Foundation

enum GeminiAdapterError: Error, Equatable, LocalizedError {
    case geminiBinaryNotFound
    case spawnFailed(String)
    case loginTimeout(home: String)
    case credentialsMissing(home: String)
    case reauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .geminiBinaryNotFound:
            return """
            Could not find the Gemini CLI (`gemini`). Install it, then retry \
            or run login with HOME pointed at the managed account folder.
            """
        case .spawnFailed(let message):
            return "Failed to start Gemini login: \(message)"
        case .loginTimeout(let home):
            return """
            Gemini login timed out. Complete browser sign-in, or run:

              HOME='\(home)' gemini auth login

            Then choose Reauthenticate (or remove and re-add).
            """
        case .credentialsMissing(let home):
            return """
            Gemini login finished but no oauth_creds.json was found. Run:

              HOME='\(home)' gemini auth login
            """
        case .reauthFailed(let message):
            return message
        }
    }
}

/// Gemini CLI usage via `cloudcode-pa.googleapis.com` `retrieveUserQuota`.
///
/// **Credentials:** managed folder as `HOME` so the CLI writes
/// `$HOME/.gemini/oauth_creds.json` — never the user’s default `~/.gemini`.
/// Leftover-session guards match Claude: snapshot access+refresh, smoke quota,
/// wipe last-good, roll back a rejected harvest.
struct GeminiAdapter: VendorAdapter {
    let id: VendorID = "gemini"
    let displayName = "Gemini"
    let minPollSeconds = 300

    private static let quotaURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    )!
    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
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
                return AddAccountResult(vendorID: id, label: "Gemini \(short)", credentialRef: ref)
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
        do {
            let prior = Self.readCredentials(home: dir)
            Self.clearManagedCredentials(home: dir)
            try await runLogin(
                home: dir,
                priorAccessToken: prior?.accessToken,
                priorRefreshToken: prior?.refreshToken
            )
            try await Self.verifyUsageAccess(home: dir)
            _ = try Self.requireCredentials(home: dir)
            return ref
        } catch {
            Self.clearManagedCredentials(home: dir)
            if let error = error as? GeminiAdapterError { throw error }
            throw GeminiAdapterError.reauthFailed(error.localizedDescription)
        }
    }

    func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot {
        let now = Date()
        let dir = CredentialStore.directoryURL(for: ref)
        guard let creds = Self.readCredentials(home: dir) else {
            return Self.errorSnapshot(.authRequired, fetchedAt: now)
        }
        return await Self.probeUsage(token: creds.accessToken, fetchedAt: now)
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

    static func verifyUsageAccess(home: URL) async throws {
        guard let creds = readCredentials(home: home) else {
            throw GeminiAdapterError.reauthFailed("No credentials written.")
        }
        let snap = await probeUsage(token: creds.accessToken, fetchedAt: Date())
        switch usageSmokeDecision(snap) {
        case .pass:
            return
        case .softKeep:
            NSLog("DashIsland: Gemini token smoke-test soft error %@", String(describing: snap.error))
        case .reject:
            throw GeminiAdapterError.reauthFailed(
                """
                Token rejected by Google (invalid or missing Gemini CLI scopes).
                Use Reauthenticate → browser login:
                  HOME='\(home.path)' gemini auth login
                """
            )
        }
    }

    static func clearManagedCredentials(home: URL) {
        let fm = FileManager.default
        let paths = [
            home.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent(credsFileName, isDirectory: false),
            home.appendingPathComponent(credsFileName, isDirectory: false),
        ]
        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
        CredentialStore.removeLastGoodUsage(inDirectory: home)
        NSLog("DashIsland: cleared Gemini managed creds at %@", home.path)
    }

    static func isAcceptableLogin(
        _ creds: GeminiCreds,
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
        priorAccessToken: String? = nil,
        priorRefreshToken: String? = nil
    ) async throws {
        guard let binary = Self.locateGeminiBinary() else {
            throw GeminiAdapterError.geminiBinaryNotFound
        }
        let prior = Self.readCredentials(home: home)
        let priorToken = priorAccessToken ?? prior?.accessToken
        let priorRefresh = priorRefreshToken ?? prior?.refreshToken

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_API_KEY")
        task.environment = env
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        task.standardInput = Pipe()

        do {
            try task.run()
        } catch {
            throw GeminiAdapterError.spawnFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.loginTimeout)

        func isAcceptable(_ creds: GeminiCreds) -> Bool {
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
            if let creds = Self.readCredentials(home: home), isAcceptable(creds) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if task.isRunning { task.terminate() }
                return
            }
            if !task.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let creds = Self.readCredentials(home: home), isAcceptable(creds) {
                    return
                }
                throw GeminiAdapterError.credentialsMissing(home: home.path)
            }
            try await Task.sleep(nanoseconds: Self.pollNanos)
        }

        if task.isRunning { task.terminate() }
        if let creds = Self.readCredentials(home: home), isAcceptable(creds) {
            return
        }
        throw GeminiAdapterError.loginTimeout(home: home.path)
    }

    static func requireCredentials(home: URL) throws -> GeminiCreds {
        if let creds = readCredentials(home: home) {
            return creds
        }
        throw GeminiAdapterError.credentialsMissing(home: home.path)
    }

    struct GeminiCreds: Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
    }

    static func readCredentials(home: URL) -> GeminiCreds? {
        let candidates = [
            home.appendingPathComponent(".gemini", isDirectory: true)
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

    static func parseOAuthCredsJSON(_ data: Data) -> GeminiCreds? {
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
        return GeminiCreds(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiryDate: expiry
        )
    }

    static func persistCredentialsFile(_ creds: GeminiCreds, home: URL) {
        let dir = home.appendingPathComponent(".gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var blob: [String: Any] = ["access_token": creds.accessToken]
        if let refresh = creds.refreshToken { blob["refresh_token"] = refresh }
        if let expiry = creds.expiryDate {
            blob["expiry_date"] = expiry.timeIntervalSince1970 * 1000
        }
        guard let data = try? JSONSerialization.data(withJSONObject: blob, options: [.prettyPrinted]) else {
            return
        }
        let path = dir.appendingPathComponent(credsFileName, isDirectory: false)
        try? data.write(to: path, options: .atomic)
    }

    static func parseQuotaResponse(data: Data, fetchedAt: Date = Date()) -> UsageSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return errorSnapshot(.parse("parse error"), fetchedAt: fetchedAt)
        }
        let rawBuckets: [Any]
        if let arr = obj as? [Any] {
            rawBuckets = arr
        } else if let dict = obj as? [String: Any], let arr = dict["buckets"] as? [Any] {
            rawBuckets = arr
        } else {
            return errorSnapshot(.parse("missing buckets"), fetchedAt: fetchedAt)
        }

        var windows: [WindowUsage] = []
        for item in rawBuckets {
            guard let bucket = item as? [String: Any],
                  let remaining = bucket["remainingFraction"] as? Double,
                  remaining.isFinite
            else { continue }
            let used = min(1, max(0, 1 - remaining))
            let reset = parseResetTime(bucket["resetTime"])
            let model = (bucket["modelId"] as? String) ?? "gemini"
            windows.append(
                WindowUsage(
                    usedFraction: used,
                    resetAt: reset,
                    kind: .fiveHour,
                    labelOverride: shortModelLabel(model)
                )
            )
        }
        guard let primary = windows.first else {
            return UsageSnapshot(
                primary: WindowUsage(usedFraction: 0, kind: .unknown),
                plan: "gemini",
                fetchedAt: fetchedAt
            )
        }
        let extras = Array(windows.dropFirst())
        let tertiary = UsageRingLayout.preferredTertiary(from: extras)
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: tertiary,
            extras: UsageRingLayout.remainingExtras(extras: extras, tertiary: tertiary),
            plan: "gemini",
            fetchedAt: fetchedAt
        )
    }

    static func probeUsage(token: String, fetchedAt: Date) async -> UsageSnapshot {
        do {
            let project = try await loadProjectID(token: token)
            var req = URLRequest(url: quotaURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 12
            req.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return errorSnapshot(.network("bad response"), fetchedAt: fetchedAt)
            }
            switch http.statusCode {
            case 200:
                return parseQuotaResponse(data: data, fetchedAt: fetchedAt)
            case 401, 403:
                return errorSnapshot(.authRequired, fetchedAt: fetchedAt)
            case 429:
                return errorSnapshot(.rateLimited(retryAfter: nil), fetchedAt: fetchedAt)
            default:
                return errorSnapshot(.network("HTTP \(http.statusCode)"), fetchedAt: fetchedAt)
            }
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                return errorSnapshot(.network(error.localizedDescription), fetchedAt: fetchedAt)
            }
            return errorSnapshot(.unavailable(error.localizedDescription), fetchedAt: fetchedAt)
        }
    }

    private static func loadProjectID(token: String) async throws -> String {
        var req = URLRequest(url: loadCodeAssistURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeminiAdapterError.reauthFailed("loadCodeAssist failed")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = obj["cloudaicompanionProject"] as? String,
              !project.isEmpty
        else {
            throw GeminiAdapterError.reauthFailed("Gemini project ID not found")
        }
        return project
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

    static func locateGeminiBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["GEMINI_BIN"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["gemini"]
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
