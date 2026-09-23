import Foundation

/// Persisted usage types and error classification.
enum UsageModelSuite {
    static func run() -> Int {
        print("UsageModel")
        var failures = 0

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

        return failures
    }
}
