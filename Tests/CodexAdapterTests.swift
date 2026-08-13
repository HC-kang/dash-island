import Foundation

enum CodexAdapterSuite {
    static func run() -> Int {
        print("CodexAdapterSuite")
        var failures = 0
        failures += check("parse used_percent → usedFraction") {
            let json = """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": { "used_percent": 12.5, "reset_at": 1800000000, "limit_window_seconds": 18000 },
                "secondary_window": { "used_percent": 34, "reset_at": 1800100000, "limit_window_seconds": 604800 }
              }
            }
            """
            let snap = CodexAdapter.parseUsageResponse(
                data: Data(json.utf8),
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.plan, "plus")
            try assertEqual(snap.primary.usedFraction, 0.125, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.34, accuracy: 0.0001)
            try assertEqual(snap.primary.resetAt?.timeIntervalSince1970 ?? -1, 1_800_000_000, accuracy: 0.001)
            try assertEqual(snap.secondary?.resetAt?.timeIntervalSince1970 ?? -1, 1_800_100_000, accuracy: 0.001)
            try assertEqual(snap.primary.kind, UsageWindowKind.fiveHour)
            try assertEqual(snap.secondary?.kind, UsageWindowKind.weekly)
        }
        failures += check("live pro: weekly primary, null secondary stays nil") {
            // Real 2026 Codex Pro/Plus: primary is 7d (604800s), secondary null.
            let json = """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 5,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 491914,
                  "reset_at": 1784952032
                },
                "secondary_window": null
              }
            }
            """
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8))
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0.05, accuracy: 0.0001)
            try assertEqual(snap.primary.kind, UsageWindowKind.weekly)
            try assertTrue(snap.secondary == nil, "null secondary_window must not become 0% wk")
        }
        failures += check("additional_rate_limits Spark → tertiary ring + short label") {
            let json = """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 4,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786838411
                },
                "secondary_window": null
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 22,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 3600
                    }
                  }
                }
              ]
            }
            """
            let fetched = Date(timeIntervalSince1970: 1_700_000_000)
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8), fetchedAt: fetched)
            try assertEqual(snap.primary.usedFraction, 0.04, accuracy: 0.0001)
            try assertTrue(snap.secondary == nil)
            try assertEqual(snap.tertiary?.displayLabel, "Spark")
            try assertEqual(snap.tertiary?.usedFraction ?? -1, 0.22, accuracy: 0.0001)
            try assertEqual(
                snap.tertiary?.resetAt?.timeIntervalSince1970 ?? -1,
                1_700_000_000 + 3600,
                accuracy: 0.001
            )
            try assertEqual(Double(snap.extras.count), 0, accuracy: 0)
        }
        failures += check("reset_after_seconds fallback when reset_at missing") {
            let fetched = Date(timeIntervalSince1970: 1_000)
            let json = """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 10,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 120
                }
              }
            }
            """
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8), fetchedAt: fetched)
            try assertEqual(
                snap.primary.resetAt?.timeIntervalSince1970 ?? -1,
                1_120,
                accuracy: 0.001
            )
        }
        failures += check("used_percent in (0,1] is percent not already-normalized") {
            // 0.5 means 0.5% used → 0.005 fraction (not 50%).
            let json = """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 0.5 },
                "secondary_window": { "used_percent": 1 }
              }
            }
            """
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 0.005, accuracy: 0.00001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.01, accuracy: 0.00001)
        }
        failures += check("missing windows → zero primary, nil secondary") {
            let json = #"{ "plan_type": "free", "rate_limit": {} }"#
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8))
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0, accuracy: 0.0001)
            try assertTrue(snap.secondary == nil)
            try assertEqual(snap.plan, "free")
        }
        failures += check("missing rate_limit → parse error") {
            let snap = CodexAdapter.parseUsageResponse(data: Data("{}".utf8))
            try assertEqual(snap.error, UsageError.parse("missing rate_limit"))
        }
        failures += check("invalid JSON → parse error") {
            let snap = CodexAdapter.parseUsageResponse(data: Data("not-json".utf8))
            try assertEqual(snap.error, UsageError.parse("parse error"))
        }
        failures += check("clamp used_percent above 100") {
            let json = #"{ "rate_limit": { "primary_window": { "used_percent": 150 } } }"#
            let snap = CodexAdapter.parseUsageResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 1.0, accuracy: 0.0001)
        }
        failures += check("parse auth.json tokens.access_token") {
            let json = """
            {
              "tokens": {
                "access_token": "at-test",
                "refresh_token": "rt",
                "account_id": "acct-1"
              }
            }
            """
            let creds = CodexAdapter.parseAuthJSON(Data(json.utf8))
            try assertEqual(creds?.accessToken, "at-test")
            try assertEqual(creds?.accountID, "acct-1")
        }
        failures += check("empty access token rejected") {
            let json = #"{"tokens":{"access_token":""}}"#
            try assertTrue(CodexAdapter.parseAuthJSON(Data(json.utf8)) == nil)
        }
        failures += check("missing tokens rejected") {
            let json = #"{"auth_mode":"chatgpt"}"#
            try assertTrue(CodexAdapter.parseAuthJSON(Data(json.utf8)) == nil)
        }
        failures += check("registry includes codex") {
            try assertTrue(VendorRegistry.adapter(for: "codex") != nil)
            try assertEqual(VendorRegistry.adapter(for: "codex")?.displayName, "Codex")
            try assertEqual(VendorRegistry.adapter(for: "codex")?.minPollSeconds, 120)
        }
        return failures
    }
}
