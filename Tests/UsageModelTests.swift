import Foundation

/// Persisted usage types, error classification and stored preferences.
enum UsageModelSuite {
    static func run() async -> Int {
        print("UsageModel")
        var failures = 0

        // Test binary's own standard domain, not the app's; restored either way.
        let keys = ["DashIsland.displayMode", "DashIsland.rimAccent"]
        let standardBefore = keys.map { UserDefaults.standard.object(forKey: $0) }
        let suite = "UsageModelTests-\(UUID().uuidString)"
        await MainActor.run {
            let prefs = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
            prefs.displayMode = .remaining
            prefs.rimAccent = .magma
        }
        let injected = UserDefaults(suiteName: suite)!
        let standardAfter = keys.map { UserDefaults.standard.object(forKey: $0) as? String }
        let injectedAfter = keys.map { injected.string(forKey: $0) }
        for (key, value) in zip(keys, standardBefore) { UserDefaults.standard.set(value, forKey: key) }
        injected.removePersistentDomain(forName: suite)
        failures += check("PreferencesStore writes to the defaults it reads from") {
            try assertEqual(injectedAfter, ["remaining", "magma"])
            try assertEqual(standardAfter, standardBefore.map { $0 as? String })
        }

        failures += check("last-good snapshot saved before a defaulted field still decodes") {
            let snapshot = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.4, kind: .fiveHour),
                secondary: WindowUsage(usedFraction: 0.1, kind: .weekly),
                extras: [WindowUsage(usedFraction: 0.2, labelOverride: "Fable")],
                plan: "max",
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let encoder = JSONEncoder()
            var object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
            object.removeValue(forKey: "extras")
            let old = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: old)
            try assertEqual(decoded.extras, [])
            try assertEqual(decoded.primary, snapshot.primary)
            try assertEqual(decoded.plan, "max")
            // Full round trip is unchanged.
            try assertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: encoder.encode(snapshot)), snapshot)
        }

        // Messages the adapters produce today. Classification must not drift.
        let hard = [
            "setup-token can’t read usage (no user:profile). Reauthenticate → browser login",
            "need browser login",
            "invalid_grant",
            "refresh token family revoked: token family",
        ]
        let quiet = ["token quiet — oauth rate limited", "token quiet — token refresh HTTP 503",
                     "oauth/token rate-limited"]
        let temporary = ["token refresh failed — retrying", "token refresh HTTP 500",
                         "Grok billing response did not include config", "The request timed out."]

        failures += check("unavailable reasons: login-family is hard, the rest soft") {
            for message in hard {
                try assertEqual(UnavailableReason(message: message), .needsLogin)
                try assertEqual(UsageSnapshotMerge.failureKind(.unavailable(message)), .hard)
            }
            for message in quiet + temporary + ["refresh pending"] {
                try assertEqual(UsageSnapshotMerge.failureKind(.unavailable(message)), .soft)
            }
            try assertEqual(UnavailableReason(message: "refresh pending"), .refreshPending)
            try assertEqual(UsageError.unavailable("refresh pending").unavailableReason, .refreshPending)
            try assertTrue(UsageError.authRequired.unavailableReason == nil)
        }

        failures += check("stale notice follows the reason, not a stray substring") {
            for message in quiet {
                try assertEqual(UsageSnapshotMerge.softStaleNotice(for: .unavailable(message)),
                                "stale · token host quiet (last-good rings)")
            }
            try assertEqual(UsageSnapshotMerge.softStaleNotice(for: .unavailable("refresh pending")),
                            "stale · refresh scheduled (last-good rings)")
            // "generate" and "separate" contain "rate" but say nothing about a rate limit.
            for message in temporary + ["could not generate usage", "separate billing unavailable"] {
                try assertEqual(UsageSnapshotMerge.softStaleNotice(for: .unavailable(message)),
                                "stale · temporary (last-good rings)")
            }
        }

        failures += check("captions follow UnavailableReason, not word matching") {
            // "refresh" in a login-family message used to read as a soft "token quiet".
            try assertEqual(UsageOrchestrator.caption(for: .unavailable("invalid_grant: refresh token revoked"), vendorID: "codex"), "need browser login")
            try assertEqual(UsageOrchestrator.caption(for: .unavailable("missing user:profile scope"), vendorID: "claude"), "need browser login")
            try assertEqual(UsageOrchestrator.caption(for: .unavailable("token quiet · retry 12m"), vendorID: "claude"), "token quiet")
            try assertTrue(UsageOrchestrator.caption(for: .unavailable("refresh pending"), vendorID: "claude") == nil)
            let detail = UsageOrchestrator.detailCaption(for: .unavailable("invalid_grant"), vendorID: "codex", credentialRef: "ABCDEF12") ?? ""
            try assertTrue(detail.contains("CODEX_HOME="), detail)
            try assertTrue(!detail.contains("CLAUDE_CONFIG_DIR"), detail)
        }
        return failures
    }
}
