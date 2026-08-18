import Foundation

enum GeminiAdapterSuite {
    static func run() -> Int {
        print("GeminiAdapterSuite")
        var failures = 0

        failures += check("parse oauth_creds.json") {
            let json = """
            {"access_token":"ya29.a","refresh_token":"1//r","expiry_date":1780000000000}
            """
            let creds = GeminiAdapter.parseOAuthCredsJSON(Data(json.utf8))
            try assertTrue(creds != nil)
            try assertEqual(creds?.accessToken, "ya29.a")
            try assertEqual(creds?.refreshToken, "1//r")
            try assertTrue(creds?.expiryDate != nil)
        }

        failures += check("empty access token rejected") {
            let json = #"{"access_token":"","refresh_token":"r"}"#
            try assertTrue(GeminiAdapter.parseOAuthCredsJSON(Data(json.utf8)) == nil)
        }

        failures += check("parse retrieveUserQuota buckets") {
            let json = """
            {
              "buckets": [
                {"remainingFraction": 0.6, "resetTime": "2026-08-18T12:00:00Z", "modelId": "gemini-2.5-pro"},
                {"remainingFraction": 0.1, "resetTime": "2026-08-18T13:00:00Z", "modelId": "gemini-2.5-flash"}
              ]
            }
            """
            let snap = GeminiAdapter.parseQuotaResponse(
                data: Data(json.utf8),
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0.4, accuracy: 0.0001)
            try assertEqual(snap.primary.labelOverride, "2.5-pro")
            try assertTrue(snap.tertiary != nil)
            try assertEqual(snap.tertiary?.usedFraction ?? -1, 0.9, accuracy: 0.0001)
        }

        failures += check("invalid JSON → parse error") {
            let snap = GeminiAdapter.parseQuotaResponse(data: Data("not-json".utf8))
            try assertTrue(snap.error != nil)
        }

        failures += check("reauth rejects leftover access even with future expiry") {
            let leftover = GeminiAdapter.GeminiCreds(
                accessToken: "old-access",
                refreshToken: "rt",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(!GeminiAdapter.isAcceptableLogin(leftover, priorAccessToken: "old-access"))
            try assertTrue(GeminiAdapter.isAcceptableLogin(leftover, priorAccessToken: nil))
        }

        failures += check("reauth rejects leftover session that only rotated access") {
            let rotated = GeminiAdapter.GeminiCreds(
                accessToken: "new-access",
                refreshToken: "same-refresh",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(
                !GeminiAdapter.isAcceptableLogin(
                    rotated,
                    priorAccessToken: "old-access",
                    priorRefreshToken: "same-refresh"
                )
            )
            let bothNew = GeminiAdapter.GeminiCreds(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                expiryDate: Date().addingTimeInterval(3600)
            )
            try assertTrue(
                GeminiAdapter.isAcceptableLogin(
                    bothNew,
                    priorAccessToken: "old-access",
                    priorRefreshToken: "same-refresh"
                )
            )
        }

        failures += check("usage smoke decision: 401 reject; 429/network soft keep") {
            let ok = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.1, kind: .fiveHour),
                plan: "gemini",
                fetchedAt: Date()
            )
            try assertEqual(GeminiAdapter.usageSmokeDecision(ok), GeminiAdapter.UsageSmokeDecision.pass)
            try assertEqual(
                GeminiAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        fetchedAt: Date(),
                        error: .authRequired
                    )
                ),
                GeminiAdapter.UsageSmokeDecision.reject
            )
            try assertEqual(
                GeminiAdapter.usageSmokeDecision(
                    UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0, kind: .unknown),
                        fetchedAt: Date(),
                        error: .rateLimited(retryAfter: nil)
                    )
                ),
                GeminiAdapter.UsageSmokeDecision.softKeep
            )
        }

        failures += check("clearManagedCredentials deletes file and last-good") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            GeminiAdapter.persistCredentialsFile(
                GeminiAdapter.GeminiCreds(
                    accessToken: "tok",
                    refreshToken: "rt",
                    expiryDate: Date().addingTimeInterval(3600)
                ),
                home: dir
            )
            try assertTrue(GeminiAdapter.readCredentials(home: dir) != nil)
            let lastGood = CredentialStore.lastGoodUsageURL(inDirectory: dir)
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.2, kind: .fiveHour),
                plan: "gemini",
                fetchedAt: Date()
            )
            try assertTrue(UsageOrchestrator.saveLastGood(snap, to: lastGood))
            GeminiAdapter.clearManagedCredentials(home: dir)
            try assertTrue(GeminiAdapter.readCredentials(home: dir) == nil)
            try assertTrue(!FileManager.default.fileExists(atPath: lastGood.path))
        }

        failures += check("registry includes gemini") {
            try assertTrue(VendorRegistry.adapter(for: "gemini")?.id == "gemini")
        }

        failures += check("existingAccess prefers managed file") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertTrue(GeminiAdapter.readCredentials(home: dir) == nil)
            GeminiAdapter.persistCredentialsFile(
                GeminiAdapter.GeminiCreds(accessToken: "file-only", refreshToken: "rt", expiryDate: nil),
                home: dir
            )
            try assertEqual(GeminiAdapter.readCredentials(home: dir)?.accessToken, "file-only")
        }

        return failures
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-gemini-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
