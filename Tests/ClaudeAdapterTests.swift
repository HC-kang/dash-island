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
        failures += check("missing windows → zero primary, nil secondary") {
            let snap = ClaudeAdapter.parseUsageResponse(data: Data("{}".utf8), plan: nil)
            try assertEqual(snap.error, nil as UsageError?)
            try assertEqual(snap.primary.usedFraction, 0, accuracy: 0.0001)
            try assertEqual(snap.primary.kind, UsageWindowKind.fiveHour)
            try assertTrue(snap.secondary == nil)
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
        failures += check("limits[] weekly_scoped Fable → extras, not rings") {
            let json = """
            {
              "five_hour": { "utilization": 10 },
              "seven_day": { "utilization": 20 },
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "percent": 38,
                  "is_active": true,
                  "resets_at": "2026-07-19T20:00:00Z",
                  "scope": { "model": { "display_name": "Fable" } }
                },
                {
                  "kind": "weekly_scoped",
                  "percent": 99,
                  "is_active": false,
                  "scope": { "model": { "display_name": "Dead" } }
                }
              ]
            }
            """
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.primary.usedFraction, 0.10, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.20, accuracy: 0.0001)
            try assertEqual(Double(snap.extras.count), 1, accuracy: 0)
            try assertEqual(snap.extras[0].displayLabel, "Fable")
            try assertEqual(snap.extras[0].usedFraction, 0.38, accuracy: 0.0001)
            // Burn stays on 5h — extras excluded.
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.fiveHour)
        }
        failures += check("parse credentials JSON") {
            let json = """
            {"claudeAiOauth":{"accessToken":"at-test","refreshToken":"rt","subscriptionType":"max"}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))
            try assertEqual(creds?.accessToken, "at-test")
            try assertEqual(creds?.subscriptionType, "max")
            try assertEqual(creds?.refreshToken, "rt")
        }
        failures += check("needsRefresh respects buffer and hard-expiry") {
            let future = Date().addingTimeInterval(30 * 60)
            let near = Date().addingTimeInterval(2 * 60)
            let slightlyPast = Date().addingTimeInterval(-10 * 60)
            let longPast = Date().addingTimeInterval(-3 * 3600)
            let fresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: future, rawJSON: nil
            )
            let soon = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: near, rawJSON: nil
            )
            let softExpired = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: slightlyPast, rawJSON: nil
            )
            let hardExpired = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: "r", subscriptionType: nil, expiresAt: longPast, rawJSON: nil
            )
            let noRefresh = ClaudeAdapter.ClaudeCreds(
                accessToken: "a", refreshToken: nil, subscriptionType: nil, expiresAt: slightlyPast, rawJSON: nil
            )
            try assertTrue(ClaudeAdapter.needsRefresh(fresh) == false)
            try assertTrue(ClaudeAdapter.needsRefresh(soon))
            try assertTrue(ClaudeAdapter.needsRefresh(softExpired))
            try assertTrue(ClaudeAdapter.needsRefresh(hardExpired) == false)
            try assertTrue(ClaudeAdapter.needsRefresh(noRefresh) == false)
        }
        failures += check("applyRefreshedToken merges access + rotated refresh") {
            let existing = Data("""
            {"claudeAiOauth":{"accessToken":"old","refreshToken":"rt-old","subscriptionType":"max","expiresAt":1}}
            """.utf8)
            let response = Data("""
            {"access_token":"new-at","expires_in":3600,"refresh_token":"rt-new"}
            """.utf8)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            guard let updated = ClaudeAdapter.applyRefreshedToken(
                existingJSON: existing,
                responseJSON: response,
                now: now
            ) else {
                try assertTrue(false, "expected merge")
                return
            }
            let creds = ClaudeAdapter.parseCredentialsJSON(updated)
            try assertEqual(creds?.accessToken, "new-at")
            try assertEqual(creds?.refreshToken, "rt-new")
            try assertEqual(creds?.subscriptionType, "max")
            let exp = creds?.expiresAt?.timeIntervalSince1970 ?? -1
            try assertEqual(exp, 1_700_000_000 + 3600, accuracy: 1)
        }
        failures += check("expiresAt milliseconds epoch") {
            // Claude Code stores expiresAt in ms — we only parse and store it.
            let ms = 1_784_481_820_799
            let json = """
            {"claudeAiOauth":{"accessToken":"at","expiresAt":\(ms)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))
            let expected = Double(ms) / 1000
            try assertEqual(
                creds?.expiresAt?.timeIntervalSince1970 ?? -1,
                expected,
                accuracy: 0.001
            )
        }
        failures += check("utilization accepts integer JSON numbers") {
            let json = #"{ "five_hour": { "utilization": 20 }, "seven_day": { "utilization": 3 } }"#
            let snap = ClaudeAdapter.parseUsageResponse(data: Data(json.utf8), plan: nil)
            try assertEqual(snap.primary.usedFraction, 0.20, accuracy: 0.0001)
            try assertEqual(snap.secondary?.usedFraction ?? -1, 0.03, accuracy: 0.0001)
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
            try assertEqual(VendorRegistry.adapter(for: "claude")?.minPollSeconds, 1_800)
        }
        failures += check("hard-expired token refuses refresh attempt") {
            let expMs = Int((Date().timeIntervalSince1970 - 3 * 3600) * 1000) // 3h dead
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","refreshToken":"sk-ant-ort01-refresh-token-value-here-xxxx","expiresAt":\(expMs)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))!
            try assertTrue(ClaudeAdapter.isHardExpired(creds))
            try assertTrue(!ClaudeAdapter.canAttemptRefresh(creds))
            try assertTrue(!ClaudeAdapter.shouldRefresh(creds))
        }
        failures += check("slightly stale token may refresh") {
            let expMs = Int((Date().timeIntervalSince1970 - 10 * 60) * 1000) // 10m past
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","refreshToken":"sk-ant-ort01-refresh-token-value-here-yyyy","expiresAt":\(expMs)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))!
            try assertTrue(ClaudeAdapter.canAttemptRefresh(creds))
            try assertTrue(ClaudeAdapter.shouldRefresh(creds))
        }
        failures += check("setup-token is long-lived and skips refresh") {
            let tok = "sk-ant-oat01-" + String(repeating: "x", count: 80)
            let json = "{\"claudeAiOauth\":{\"accessToken\":\"\(tok)\",\"dashIslandLongLived\":true}}"
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))
            try assertTrue(creds != nil)
            try assertTrue(ClaudeAdapter.isLongLived(creds!))
            try assertTrue(!ClaudeAdapter.needsRefresh(creds!))
            try assertTrue(!ClaudeAdapter.isExpired(creds!))
        }
        failures += check("normalizePastedToken accepts sk-ant- line") {
            // Real tokens are ~100+ chars; short strings must fail.
            let short = "sk-ant-oat01-tooshort"
            try assertTrue(ClaudeAdapter.normalizePastedToken(short) == nil)
            let ok = "sk-ant-oat01-" + String(repeating: "a", count: 80)
            let messy = "  \(ok)  \n"
            let t = ClaudeAdapter.normalizePastedToken(messy)
            try assertTrue(t?.hasPrefix("sk-ant-oat01-") == true)
            try assertTrue(ClaudeAdapter.normalizePastedToken("not-a-token") == nil)
        }
        failures += check("CLI oauth with refresh still needs refresh near expiry") {
            let expMs = Int((Date().timeIntervalSince1970 - 60) * 1000)
            let json = """
            {"claudeAiOauth":{"accessToken":"sk-ant-oat01-short","refreshToken":"sk-ant-ort01-refresh-token-value-here","expiresAt":\(expMs)}}
            """
            let creds = ClaudeAdapter.parseCredentialsJSON(Data(json.utf8))
            try assertTrue(creds != nil)
            // Has refresh → not treated as setup-token long-lived solely by oat prefix if refresh present
            // actually access is oat but has refresh - isLongLived checks longLived flag first, then !hasRefresh && looksLike
            // has refresh so isLongLived false unless flagged
            try assertTrue(!ClaudeAdapter.isLongLived(creds!))
            try assertTrue(ClaudeAdapter.needsRefresh(creds!))
        }
        failures += check("multi-account isolation is path-based (separate config dirs)") {
            // Documented contract: each account's credentials live only under its
            // CLAUDE_CONFIG_DIR file; refresh writes that path only. Two dirs ⇒
            // two independent refresh tokens (no shared Keychain steady-state).
            let a = URL(fileURLWithPath: "/tmp/dash-claude-acct-a")
            let b = URL(fileURLWithPath: "/tmp/dash-claude-acct-b")
            try assertTrue(a.path != b.path)
            let sa = ClaudeAdapter.scopedKeychainService(for: a)
            let sb = ClaudeAdapter.scopedKeychainService(for: b)
            try assertTrue(sa != sb)
            try assertTrue(sa.hasPrefix("Claude Code-credentials-"))
            try assertTrue(sb.hasPrefix("Claude Code-credentials-"))
        }
        return failures
    }
}
