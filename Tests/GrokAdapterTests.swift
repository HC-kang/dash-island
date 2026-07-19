import Foundation

enum GrokAdapterSuite {
    static func run() -> Int {
        print("GrokAdapterSuite")
        var failures = 0

        failures += check("parse weekly creditUsagePercent → usedFraction") {
            let json = """
            {
              "config": {
                "creditUsagePercent": 42,
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-06-30T18:36:14Z",
                  "end": "2026-07-07T18:36:14Z"
                },
                "subscriptionTier": "SuperGrok"
              }
            }
            """
            let snap = GrokAdapter.parseCreditsResponse(
                data: Data(json.utf8),
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.plan, "SuperGrok")
            try assertEqual(snap.primary.usedFraction, 0.42, accuracy: 0.0001)
            // 2026-07-07T18:36:14Z
            try assertEqual(
                snap.primary.resetAt?.timeIntervalSince1970 ?? -1,
                1_783_449_374,
                accuracy: 1
            )
            try assertTrue(snap.secondary == nil)
        }

        failures += check("creditUsagePercent always ÷100 even when small") {
            let json = #"{ "config": { "creditUsagePercent": 0.5 } }"#
            let snap = GrokAdapter.parseCreditsResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 0.005, accuracy: 0.00001)
        }

        failures += check("omitted percent + confirmed weekly period → 0%") {
            let json = """
            {
              "config": {
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-17T19:38:56Z",
                  "end": "2026-07-24T19:38:56Z"
                },
                "billingPeriodStart": "2026-07-17T19:38:56Z",
                "billingPeriodEnd": "2026-07-24T19:38:56Z",
                "isUnifiedBillingUser": true
              }
            }
            """
            let snap = GrokAdapter.parseCreditsResponse(data: Data(json.utf8))
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0, accuracy: 0.0001)
            try assertTrue(snap.primary.resetAt != nil)
        }

        failures += check("ambiguous weekly without percent → no weekly window") {
            let json = """
            {
              "config": {
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-10T19:38:56Z",
                  "end": "2026-07-17T19:38:56Z"
                },
                "isUnifiedBillingUser": true,
                "subscriptionTier": "SuperGrok"
              }
            }
            """
            let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let config = GrokAdapter.resolveBillingConfig(root)!
            try assertTrue(GrokAdapter.mapWeeklyCredits(config) == nil)
            try assertEqual(config["subscriptionTier"] as? String, "SuperGrok")
        }

        failures += check("monthly used/limit → fraction") {
            let monthly = """
            {
              "config": {
                "monthlyLimit": { "val": "150000" },
                "used": { "val": "837" },
                "billingPeriodEnd": "2026-08-01T00:00:00Z"
              }
            }
            """
            let credits = #"{ "config": { "subscriptionTier": "SuperGrok" } }"#
            let snap = GrokAdapter.parseMonthlyFallback(
                creditsData: Data(credits.utf8),
                monthlyData: Data(monthly.utf8),
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.plan, "SuperGrok")
            try assertEqual(snap.primary.usedFraction, 837.0 / 150_000.0, accuracy: 0.00001)
            try assertEqual(
                snap.primary.resetAt?.timeIntervalSince1970 ?? -1,
                1_785_542_400,
                accuracy: 1
            )
        }

        failures += check("no config → unavailable") {
            let snap = GrokAdapter.parseCreditsResponse(data: Data("{}".utf8))
            try assertEqual(
                snap.error,
                UsageError.unavailable("Grok billing response did not include config")
            )
        }

        failures += check("invalid JSON → parse error") {
            let snap = GrokAdapter.parseCreditsResponse(data: Data("not-json".utf8))
            try assertEqual(snap.error, UsageError.parse("parse error"))
        }

        failures += check("clamp creditUsagePercent above 100") {
            let json = #"{ "config": { "creditUsagePercent": 150 } }"#
            let snap = GrokAdapter.parseCreditsResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 1.0, accuracy: 0.0001)
        }

        failures += check("flat (non-nested) creditUsagePercent") {
            let json = #"{ "creditUsagePercent": 10, "subscriptionTier": "Free" }"#
            let snap = GrokAdapter.parseCreditsResponse(data: Data(json.utf8))
            try assertEqual(snap.primary.usedFraction, 0.10, accuracy: 0.0001)
            try assertEqual(snap.plan, "Free")
        }

        failures += check("parse preferred auth.x.ai issuer") {
            let json = """
            {
              "https://stale.example.com::client": {
                "key": "stale-token",
                "user_id": "stale",
                "expires_at": "2099-01-01T00:00:00Z"
              },
              "https://auth.x.ai::client": {
                "key": "live-token",
                "user_id": "live-user",
                "email": "dev@example.com",
                "team_id": "team-1",
                "expires_at": "2099-06-01T00:00:00Z"
              }
            }
            """
            let session = GrokAdapter.parseAuthJSON(Data(json.utf8))
            try assertEqual(session?.accessToken, "live-token")
            try assertEqual(session?.userId, "live-user")
            try assertEqual(session?.email, "dev@example.com")
            try assertEqual(session?.teamId, "team-1")
        }

        failures += check("fallback alternate issuer when no auth.x.ai") {
            let json = """
            {
              "https://alternate.example.com::client": {
                "key": "alt-token",
                "email": "alt@example.com",
                "expires_at": "2099-01-01T00:00:00Z"
              }
            }
            """
            let session = GrokAdapter.parseAuthJSON(Data(json.utf8))
            try assertEqual(session?.accessToken, "alt-token")
            try assertEqual(session?.email, "alt@example.com")
        }

        failures += check("token-less auth file → nil") {
            let json = #"{"https://auth.x.ai::client":{"user_id":"u1"}}"#
            try assertTrue(GrokAdapter.parseAuthJSON(Data(json.utf8)) == nil)
        }

        failures += check("empty access token rejected") {
            let json = #"{"https://auth.x.ai::client":{"key":""}}"#
            try assertTrue(GrokAdapter.parseAuthJSON(Data(json.utf8)) == nil)
        }

        failures += check("expired preferred still returned (freshness separate)") {
            let json = """
            {
              "https://auth.x.ai::client": {
                "key": "stale",
                "expires_at": "2000-01-01T00:00:00Z"
              }
            }
            """
            let session = GrokAdapter.parseAuthJSON(Data(json.utf8))
            try assertEqual(session?.accessToken, "stale")
            try assertTrue(session.map(GrokAdapter.isAccessTokenFresh) == false)
        }

        failures += check("no expiry → treated fresh") {
            let session = GrokAdapter.GrokSession(
                accessToken: "t",
                userId: nil,
                email: nil,
                teamId: nil,
                expiresAt: nil
            )
            try assertTrue(GrokAdapter.isAccessTokenFresh(session))
        }

        failures += check("monthly moneyVal string + number") {
            try assertEqual(GrokAdapter.moneyVal(["val": "12.5"]) ?? -1, 12.5, accuracy: 0.0001)
            try assertEqual(GrokAdapter.moneyVal(["val": 3]) ?? -1, 3.0, accuracy: 0.0001)
            try assertTrue(GrokAdapter.moneyVal(["val": "x"]) == nil)
            try assertTrue(GrokAdapter.moneyVal("nope") == nil)
        }

        failures += check("registry includes grok") {
            try assertTrue(VendorRegistry.adapter(for: "grok") != nil)
            try assertEqual(VendorRegistry.adapter(for: "grok")?.displayName, "Grok")
            try assertEqual(VendorRegistry.adapter(for: "grok")?.minPollSeconds, 300)
        }

        failures += check("dual-window helper prefers weekly primary") {
            let weeklyCfg: [String: Any] = [
                "creditUsagePercent": 20,
                "currentPeriod": ["end": "2026-07-07T00:00:00Z"],
            ]
            let monthlyCfg: [String: Any] = [
                "monthlyLimit": ["val": 100],
                "used": ["val": 25],
            ]
            let snap = GrokAdapter.parseBillingWindows(
                weeklyConfig: weeklyCfg,
                monthlyConfig: monthlyCfg,
                plan: "SuperGrok"
            )
            try assertEqual(snap.primary.usedFraction, 0.20, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.25, accuracy: 0.0001)
            try assertEqual(snap.plan, "SuperGrok")
        }

        return failures
    }
}
