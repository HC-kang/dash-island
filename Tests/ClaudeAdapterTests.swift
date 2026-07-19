import Foundation

enum ClaudeAdapterSuite {
    static func run() -> Int {
        print("ClaudeAdapterSuite")
        var failures = 0
        failures += check("parse utilization percent → usedFraction") {
            let json = """
            {
              "five_hour": { "utilization": 42.5, "resets_at": "2026-07-19T12:00:00Z" },
              "seven_day": { "utilization": 10, "resets_at": 1721404800 }
            }
            """
            let data = Data(json.utf8)
            let snap = ClaudeAdapter.parseUsageResponse(data: data, plan: "pro", fetchedAt: Date(timeIntervalSince1970: 0))
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.plan, "pro")
            try assertEqual(snap.primary.usedFraction, 0.425, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.10, accuracy: 0.0001)
            // ISO8601 without fractional seconds
            try assertEqual(snap.primary.resetAt?.timeIntervalSince1970 ?? -1, 1_784_462_400, accuracy: 1)
            // unix seconds
            try assertEqual(snap.secondary?.resetAt?.timeIntervalSince1970 ?? -1, 1_721_404_800, accuracy: 0.001)
        }
        failures += check("utilization in (0,1] is percent not already-normalized") {
            // 0.5 means 0.5% used → 0.005 fraction (not 50%).
            let json = """
            { "five_hour": { "utilization": 0.5 }, "seven_day": { "utilization": 1 } }
            """
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.primary.usedFraction, 0.005, accuracy: 0.00001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.01, accuracy: 0.00001)
        }
        failures += check("missing windows → zero fractions, no error") {
            let snap = ClaudeAdapter.parseUsageResponse(data: Data("{}".utf8), plan: nil)
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0, accuracy: 0.0001)
        }
        failures += check("invalid JSON → parse error") {
            let snap = ClaudeAdapter.parseUsageResponse(data: Data("not-json".utf8), plan: nil)
            try assertEqual(snap.error, UsageError.parse("parse error"))
        }
        failures += check("clamp utilization above 100") {
            let json = #"{ "five_hour": { "utilization": 150 } }"#
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.primary.usedFraction, 1.0, accuracy: 0.0001)
        }
        failures += check("parse credentials JSON") {
            let json = """
            {"claudeAiOauth":{"accessToken":"at-test","refreshToken":"rt","subscriptionType":"max"}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))
            try assertEqual(creds?.accessToken, "at-test")
            try assertEqual(creds?.subscriptionType, "max")
        }
        failures += check("empty access token rejected") {
            let json = #"{"claudeAiOauth":{"accessToken":""}}"#
            try assertTrue(ClaudeAdapter.parseCredentialsJSON(Data(json.utf8)) == nil)
        }
        failures += check("scoped keychain service is stable 8-hex suffix") {
            let dir = URL(fileURLWithPath: "/tmp/dash-island-test-config", isDirectory: true)
            let service = ClaudeAdapter.scopedKeychainService(for: dir)
            try assertTrue(service.hasPrefix("Claude Code-credentials-"))
            let suffix = String(service.dropFirst("Claude Code-credentials-".count))
            try assertEqual(suffix.count, 8)
            // Stable across calls
            try assertEqual(ClaudeAdapter.scopedKeychainService(for: dir), service)
        }
        failures += check("resets_at fractional ISO8601") {
            let date = ClaudeAdapter.parseResetsAt("2026-07-19T12:00:00.500Z")
            try assertTrue(date != nil)
        }
        failures += check("registry includes claude") {
            try assertTrue(VendorRegistry.adapter(for: "claude") != nil)
            try assertEqual(VendorRegistry.adapter(for: "claude")?.displayName, "Claude")
            try assertEqual(VendorRegistry.adapter(for: "claude")?.minPollSeconds, 300)
        }
        return failures
    }
}
