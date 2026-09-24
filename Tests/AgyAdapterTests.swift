import Foundation

enum AgyAdapterSuite {
    static func run() -> Int {
        print("AgyAdapterSuite")
        var failures = 0

        failures += check("embedded Google client IDs must start with digits") {
            let blob = Data(
                "xxit1071006060591-abc.apps.googleusercontent.comYY884354919052-def.apps.googleusercontent.com"
                    .utf8
            )
            let ids = AgyAdapter.scanEmbeddedClientIDs(blob)
            try assertEqual(ids.count, 2)
            try assertEqual(ids[0], "1071006060591-abc.apps.googleusercontent.com")
            try assertEqual(ids[1], "884354919052-def.apps.googleusercontent.com")
            try assertTrue(!ids.contains(where: { $0.hasPrefix("it") }))
        }

        failures += check("preferFresher picks later expiry across stores") {
            let stale = AgyAdapter.AgyCreds(
                accessToken: "old",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(-3600)
            )
            let live = AgyAdapter.AgyCreds(
                accessToken: "new",
                refreshToken: "rt2",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertEqual(AgyAdapter.preferFresher(stale, live)?.accessToken, "new")
            try assertEqual(AgyAdapter.preferFresher(live, stale)?.accessToken, "new")
            try assertEqual(AgyAdapter.preferFresher(stale, nil)?.accessToken, "old")
        }

        failures += check("parse nested antigravity-oauth-token JSON") {
            let json = """
            {"token":{"access_token":"ya29.t","token_type":"Bearer","refresh_token":"1//r","expiry":"2026-08-25T16:57:23Z"},"auth_method":"consumer"}
            """
            let creds = AgyAdapter.parseKeychainBlob(Data(json.utf8))
            try assertEqual(creds?.accessToken, "ya29.t")
            try assertTrue(creds?.expiryDate != nil)
        }

        failures += check("parse go-keyring-base64 keychain blob") {
            let inner = """
            {"token":{"access_token":"ya29.t","token_type":"Bearer","refresh_token":"1//r","expiry":"2026-08-19T22:50:03Z"},"auth_method":"consumer"}
            """
            let b64 = Data(inner.utf8).base64EncodedString()
            let blob = Data("go-keyring-base64:\(b64)".utf8)
            let creds = AgyAdapter.parseKeychainBlob(blob)
            try assertEqual(creds?.accessToken, "ya29.t")
            try assertEqual(creds?.refreshToken, "1//r")
        }

        failures += check("parse oauth_creds.json") {
            let json = """
            {"access_token":"ya29.a","refresh_token":"1//r","expiry_date":1780000000000}
            """
            let creds = AgyAdapter.parseOAuthCredsJSON(Data(json.utf8))
            try assertTrue(creds != nil)
            try assertEqual(creds?.accessToken, "ya29.a")
            try assertEqual(creds?.refreshToken, "1//r")
        }

        failures += check("parse fetchAvailableModels quotas") {
            let json = """
            {
              "models": {
                "gemini-2.5-pro": {
                  "displayName": "Pro",
                  "quotaInfo": {
                    "remainingFraction": 0.6,
                    "resetTime": "2026-08-18T12:00:00Z",
                    "windowLabel": "daily"
                  }
                },
                "gemini-2.5-flash": {
                  "displayName": "Flash",
                  "weeklyQuotaInfo": {
                    "remainingFraction": 0.2,
                    "resetTime": "2026-08-25T12:00:00Z",
                    "windowId": "WINDOW_WEEKLY"
                  }
                }
              }
            }
            """
            let snap = AgyAdapter.parseAvailableModelsResponse(
                data: Data(json.utf8),
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
            try assertEqual(snap.error, nil as UsageError?)
            // Flash weekly used 0.8 is more constrained than Pro daily 0.4
            try assertEqual(snap.primary.usedFraction, 0.8, accuracy: 0.0001)
            try assertEqual(snap.primary.kind, UsageWindowKind.weekly)
            try assertTrue(snap.secondary != nil || snap.tertiary != nil || !snap.extras.isEmpty)
        }

        failures += check("invalid JSON → parse error") {
            let snap = AgyAdapter.parseAvailableModelsResponse(data: Data("not-json".utf8))
            try assertTrue(snap.error != nil)
        }

        failures += check("no quotas are not reported, never a real 0%") {
            let snap = AgyAdapter.parseAvailableModelsResponse(data: Data(#"{"models":{}}"#.utf8))
            try assertEqual(snap.error, nil as UsageError?)
            try assertTrue(!snap.primary.isReported)
        }

        failures += check("daily or unlabeled quota is not a 5h window") {
            let json = """
            {"models":{
              "a":{"quotaInfo":{"remainingFraction":0.5,"windowLabel":"daily"}},
              "b":{"quotaInfo":{"remainingFraction":0.9}}
            }}
            """
            let snap = AgyAdapter.parseAvailableModelsResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.kind, UsageWindowKind.unknown)
            try assertTrue(snap.secondary?.kind != .fiveHour && snap.tertiary?.kind != .fiveHour)
        }

        failures += check("omitted remainingFraction with a reset time is exhausted") {
            // proto3 JSON drops zero values: the empty model is the important one.
            let json = """
            {"models":{"pro":{"displayName":"Pro","quotaInfo":{"resetTime":"2026-08-18T12:00:00Z"}},
                       "flash":{"quotaInfo":{}}}}
            """
            let snap = AgyAdapter.parseAvailableModelsResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 1.0, accuracy: 0.0001)
            try assertEqual(snap.primary.displayLabel, "Pro")
            try assertTrue(snap.secondary == nil && snap.tertiary == nil, "no reading → no ring")
        }

        failures += check("reauth rejects leftover access or refresh") {
            let leftover = AgyAdapter.AgyCreds(
                accessToken: "old-access",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(!AgyAdapter.isAcceptableLogin(leftover, priorAccessToken: "old-access"))
            let rotatedAccess = AgyAdapter.AgyCreds(
                accessToken: "new-access",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(
                !AgyAdapter.isAcceptableLogin(
                    rotatedAccess,
                    priorAccessToken: "old-access",
                    priorRefreshToken: "rt"
                )
            )
            let bothNew = AgyAdapter.AgyCreds(
                accessToken: "new-access",
                refreshToken: "new-rt",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(
                AgyAdapter.isAcceptableLogin(
                    bothNew,
                    priorAccessToken: "old-access",
                    priorRefreshToken: "rt"
                )
            )
        }

        failures += check("usage smoke decision") {
            let ok = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.1, kind: .fiveHour),
                plan: "agy",
                fetchedAt: Date()
            )
            try assertEqual(AgyAdapter.usageSmokeDecision(ok), AgyAdapter.UsageSmokeDecision.pass)
            try assertEqual(
                AgyAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        fetchedAt: Date(),
                        error: .authRequired
                    )
                ),
                AgyAdapter.UsageSmokeDecision.reject
            )
        }

        failures += check("clearManagedCredentials deletes file and last-good") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try AgyAdapter.persistCredentialsFile(
                AgyAdapter.AgyCreds(
                    accessToken: "tok",
                    refreshToken: "rt",
                    expiryDate: Date().addingTimeInterval(3600)
                ),
                home: dir
            )
            try assertTrue(AgyAdapter.readCredentials(home: dir) != nil)
            let lastGood = CredentialStore.lastGoodUsageURL(inDirectory: dir)
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.2, kind: .fiveHour),
                plan: "agy",
                fetchedAt: Date()
            )
            try assertTrue(UsageOrchestrator.saveLastGood(snap, to: lastGood))
            AgyAdapter.clearManagedCredentials(home: dir)
            try assertTrue(AgyAdapter.readCredentials(home: dir) == nil)
            try assertTrue(!FileManager.default.fileExists(atPath: lastGood.path))
        }

        failures += check("expired harvest is not treated as a fresh login") {
            let expired = AgyAdapter.AgyCreds(
                accessToken: "ya29.old",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(-60)
            )
            try assertTrue(!AgyAdapter.isFresh(expired))
            let live = AgyAdapter.AgyCreds(
                accessToken: "ya29.new",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(AgyAdapter.isFresh(live))
        }

        failures += check("registry includes agy and still includes codex") {
            try assertTrue(VendorRegistry.adapter(for: "agy")?.id == "agy")
            try assertTrue(VendorRegistry.adapter(for: "codex")?.id == "codex")
            try assertTrue(VendorRegistry.adapter(for: "gemini") == nil)
        }

        return failures
    }

    /// Login wait: `agy` in Terminal writes its token file into the managed HOME.
    static func runLogin() async -> Int {
        print("AgyAdapterSuite (login)")
        var failures = 0

        failures += await checkAsync("login wait accepts the new session agy writes") {
            let home = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: home) }
            let writer = Task {
                try await Task.sleep(nanoseconds: 150_000_000)
                try writeCLIToken(home: home, access: "ya29.new", refresh: "1//new")
            }
            let creds = try await AgyAdapter.waitForLogin(
                home: home,
                priorAccessToken: nil,
                priorRefreshToken: nil,
                timeout: 5,
                pollNanos: 50_000_000
            )
            try await writer.value
            try assertEqual(creds.accessToken, "ya29.new")
        }

        failures += await checkAsync("reauth login wait never accepts the unchanged session") {
            let home = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: home) }
            try writeCLIToken(home: home, access: "ya29.old", refresh: "1//old")
            var timedOut = false
            do {
                _ = try await AgyAdapter.waitForLogin(
                    home: home,
                    priorAccessToken: "ya29.old",
                    priorRefreshToken: "1//old",
                    timeout: 0.3,
                    pollNanos: 50_000_000
                )
            } catch AgyAdapterError.loginTimeout {
                timedOut = true
            }
            try assertTrue(timedOut, "old session must not finish a reauth")
        }

        // Reauth keeps the session only on `.failed`. A refused client is not a
        // busy host: no retry fixes it, so reauth must go on to sign-in.
        failures += await checkAsync("a refused OAuth client is not a busy token host") {
            let refused = await StubHTTP.with(status: 401, body: #"{"error":"invalid_client"}"#) {
                await AgyAdapter.refreshAccessToken("1//r", ids: ["1-a.apps.googleusercontent.com"], secrets: ["s"])
            }
            try assertEqual(refused, .clientRejected)
            let unauthorized = await StubHTTP.with(status: 400, body: #"{"error":"unauthorized_client"}"#) {
                await AgyAdapter.refreshAccessToken("1//r", ids: ["1-a", "2-b"], secrets: ["s", "t"])
            }
            try assertEqual(unauthorized, .clientRejected)
            let none = await AgyAdapter.refreshAccessToken("1//r", ids: [], secrets: [])
            try assertEqual(none, .clientRejected)
            let busy = await StubHTTP.with(status: 503, body: "") {
                await AgyAdapter.refreshAccessToken("1//r", ids: ["1-a"], secrets: ["s"])
            }
            try assertEqual(busy, .failed)
            let dead = await StubHTTP.with(status: 400, body: #"{"error":"invalid_grant"}"#) {
                await AgyAdapter.refreshAccessToken("1//r", ids: ["1-a"], secrets: ["s"])
            }
            try assertEqual(dead, .invalidGrant)
        }

        // Timeout ends the Terminal `agy`; a failed Add deletes the folder.
        failures += check("login timeout copy names only steps that still exist") {
            let add = AgyAdapterError.loginTimeout(reauth: false).errorDescription ?? ""
            let reauth = AgyAdapterError.loginTimeout(reauth: true).errorDescription ?? ""
            for text in [add, reauth] {
                try assertTrue(!text.contains("HOME="), "names a folder that may be gone: \(text)")
                try assertTrue(!text.contains("Terminal"), "the Terminal login was ended: \(text)")
            }
            try assertTrue(add.contains("not added"), add)
            try assertTrue(reauth.contains("Reauthenticate"), reauth)
            let mapped = AgyAdapter.reauthError(AgyAdapterError.loginTimeout(reauth: false))
            try assertEqual(mapped as? AgyAdapterError, .loginTimeout(reauth: true))
            try assertTrue(AgyAdapter.reauthError(CancellationError()) is CancellationError)
        }

        failures += check("reauth moves every session file aside so agy starts signed out") {
            let home = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: home) }
            try writeCLIToken(home: home, access: "ya29.old", refresh: "1//old")
            try AgyAdapter.persistCredentialsFile(
                AgyAdapter.AgyCreds(accessToken: "ya29.old", refreshToken: "1//old", expiryDate: nil),
                home: home
            )
            let prior = CredentialStore.PriorFiles.stash(AgyAdapter.sessionFiles(home: home))
            try assertTrue(AgyAdapter.readCredentials(home: home) == nil)
            prior.restore()
            try assertEqual(AgyAdapter.readCredentials(home: home)?.accessToken, "ya29.old")
        }

        return failures
    }

    private static func writeCLIToken(home: URL, access: String, refresh: String) throws {
        let dir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = #"{"token":{"access_token":"\#(access)","refresh_token":"\#(refresh)","expiry":"\#(expiry)"}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("antigravity-oauth-token"))
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
