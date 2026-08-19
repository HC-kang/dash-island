import Foundation

enum AgyAdapterSuite {
    static func run() -> Int {
        print("AgyAdapterSuite")
        var failures = 0

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
            AgyAdapter.persistCredentialsFile(
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

        failures += check("registry includes agy and still includes codex") {
            try assertTrue(VendorRegistry.adapter(for: "agy")?.id == "agy")
            try assertTrue(VendorRegistry.adapter(for: "codex")?.id == "codex")
            try assertTrue(VendorRegistry.adapter(for: "gemini") == nil)
        }

        return failures
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
